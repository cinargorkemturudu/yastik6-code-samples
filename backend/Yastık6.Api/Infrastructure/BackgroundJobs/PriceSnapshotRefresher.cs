using System.Collections.Concurrent;
using Yastık6.Api.Application.Common.Interfaces;
using Yastık6.Api.Application.Features.Prices;
using Yastık6.Api.Domain.Entities;
using Yastık6.Api.Infrastructure.Alerts;
using Yastık6.Api.Infrastructure.Caching;

namespace Yastık6.Api.Infrastructure.BackgroundJobs;

public sealed class PriceSnapshotRefresher : BackgroundService
{
    private readonly IPriceSnapshotStore _snapshotStore;
    private readonly IPriceProcessor _priceProcessor;
    private readonly ILogger<PriceSnapshotRefresher> _logger;
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly IAlertService _alertService;
    private readonly AlertTracker _tracker;

    private static readonly object CacheLock = new object();

    // Failed providers: since when they have been down, and the key of the alert that was sent.
    // When a provider returns data again it is removed from here and a "Recovered" notice is sent.
    private readonly ConcurrentDictionary<Type, (DateTimeOffset Since, string AlertKey)> _downProviders = new();

    // A failed provider waits this long before the next attempt. Settable via init so tests can shorten it.
    public TimeSpan CrashBackoff { get; init; } = TimeSpan.FromMinutes(5);

    public PriceSnapshotRefresher(
        IPriceSnapshotStore snapshotStore,
        IPriceProcessor priceProcessor,
        ILogger<PriceSnapshotRefresher> logger,
        IServiceScopeFactory scopeFactory,
        IAlertService alertService,
        AlertTracker tracker)
    {
        _snapshotStore = snapshotStore;
        _priceProcessor = priceProcessor;
        _logger = logger;
        _scopeFactory = scopeFactory;
        _alertService = alertService;
        _tracker = tracker;
    }

    protected override Task ExecuteAsync(CancellationToken stoppingToken)
    {
        List<Type> providerTypes;

        using (var scope = _scopeFactory.CreateScope())
        {
            var providers = scope.ServiceProvider.GetServices<IPriceProvider>();

            // .Distinct() guards against duplicate DI registrations.
            providerTypes = providers
                .Select(p => p.GetType())
                .Distinct()
                .Where(t => t.Name != "YahooForexClient" && t.Name != "YahooCryptoClient")
                .ToList();

            _logger.LogInformation("Price refresh service started. Active main providers: {Count}", providerTypes.Count);
        }

        var providerTasks = providerTypes.Select(type => RunProviderLoopAsync(type, stoppingToken));

        return Task.WhenAll(providerTasks);
    }

    private async Task RunProviderLoopAsync(Type providerType, CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                using var scope = _scopeFactory.CreateScope();

                var provider = scope.ServiceProvider.GetServices<IPriceProvider>()
                                    .FirstOrDefault(p => p.GetType() == providerType);

                if (provider == null)
                {
                    _logger.LogWarning("Provider {ProviderType} could not be resolved. Skipping iteration.", providerType.Name);
                    await Task.Delay(TimeSpan.FromSeconds(5), stoppingToken);
                    continue;
                }

                var clock = scope.ServiceProvider.GetRequiredService<ISystemClock>();
                var repository = scope.ServiceProvider.GetRequiredService<IPriceHistoryRepository>();

                bool isMarketOpen = provider.IsMarketOpen();

                // While the market is closed the provider keeps polling at its own (usually longer) RefreshInterval,
                // so AsOfUtc advances together with real data.
                var rawPrices = await provider.GetMarketOverviewAsync(stoppingToken);

                if (rawPrices.Count > 0)
                {
                    await NotifyRecoveryIfNeededAsync(providerType, stoppingToken);

                    var verifiedPrices = await _priceProcessor.ProcessPricesAsync(rawPrices, provider.ProviderName, isMarketOpen, stoppingToken);

                    if (verifiedPrices.Count == 0)
                    {
                        await Task.Delay(provider.RefreshInterval, stoppingToken);
                        continue;
                    }

                    var recordsToInsert = new List<PriceRecord>();

                    lock (CacheLock)
                    {
                        var currentSnapshot = _snapshotStore.Current;
                        var currentDict = currentSnapshot?.Items.ToDictionary(p => p.ProductCode)
                                           ?? new Dictionary<string, LatestPriceResponse>();

                        foreach (var newPrice in verifiedPrices)
                        {
                            // ValidUntilUtc is already computed in the mapper from the market state; leave it alone.
                            var safePrice = newPrice with
                            {
                                IsMarketOpen = isMarketOpen
                            };

                            bool hasPriceChanged = true;

                            if (currentDict.TryGetValue(safePrice.ProductCode, out var existingPrice))
                            {
                                if (existingPrice.Ask == safePrice.Ask && existingPrice.Bid == safePrice.Bid)
                                {
                                    hasPriceChanged = false;
                                }
                            }

                            if (hasPriceChanged)
                            {
                                recordsToInsert.Add(new PriceRecord
                                {
                                    Id = Guid.NewGuid(),
                                    ProductCode = safePrice.ProductCode,
                                    Source = safePrice.Source,
                                    AskPrice = safePrice.Ask,
                                    BidPrice = safePrice.Bid,
                                    LastPrice = safePrice.LastPrice,
                                    TimestampUtc = clock.UtcNow
                                });
                            }

                            currentDict[safePrice.ProductCode] = safePrice;
                        }

                        _snapshotStore.Set(new LatestPricesResponse(
                            Items: currentDict.Values.ToList(),
                            ComputedAtUtc: DateTimeOffset.UtcNow
                        ));
                    }

                    if (recordsToInsert.Count > 0)
                    {
                        await repository.AddPriceRecordsAsync(recordsToInsert, stoppingToken);
                    }
                }

                await Task.Delay(provider.RefreshInterval, stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "A critical error occurred while fetching prices for provider {ProviderType}.", providerType.Name);

                string? fallbackProviderName = providerType.Name switch
                {
                    "FreeCurrencyClient" => "YahooForexClient",
                    "BinanceClient" => "YahooCryptoClient",
                    _ => null
                };

                if (fallbackProviderName != null)
                {
                    _downProviders.TryAdd(providerType, (DateTimeOffset.UtcNow, $"Fallback_{providerType.Name}_{fallbackProviderName}"));

                    _logger.LogWarning("{Provider} failed! Triggering immediate fallback to {Fallback}...", providerType.Name, fallbackProviderName);

                    await _alertService.SendAlertAsync(
                        $"🔄 *Fallback Activated*\n`{providerType.Name}` crashed. Routing traffic to `{fallbackProviderName}`.\nError: `{ex.Message}`",
                        $"Fallback_{providerType.Name}_{fallbackProviderName}",
                        stoppingToken);

                    try
                    {
                        await ExecuteFallbackAsync(fallbackProviderName, stoppingToken);
                    }
                    catch (Exception fallbackEx)
                    {
                        _logger.LogCritical(fallbackEx, "Fatal: Fallback provider {Fallback} also failed!", fallbackProviderName);
                        await _alertService.SendAlertAsync($"🚨 *DOUBLE CRASH*\nBoth `{providerType.Name}` and fallback `{fallbackProviderName}` failed!", $"DoubleCrash_{providerType.Name}", stoppingToken);
                    }
                }
                else
                {
                    _downProviders.TryAdd(providerType, (DateTimeOffset.UtcNow, $"Snapshot_{providerType.Name}_{ex.GetType().Name}"));

                    await _alertService.SendAlertAsync(
                        $"⚠️ *Provider Crashed: {providerType.Name}*\nTime: `{DateTime.UtcNow:HH:mm:ss} UTC`\nError: `{ex.Message}`",
                        $"Snapshot_{providerType.Name}_{ex.GetType().Name}",
                        stoppingToken);
                }

                await Task.Delay(CrashBackoff, stoppingToken);
            }
        }
    }

    private async Task NotifyRecoveryIfNeededAsync(Type providerType, CancellationToken stoppingToken)
    {
        if (!_downProviders.TryRemove(providerType, out var outage)) return;

        var downtime = DateTimeOffset.UtcNow - outage.Since;

        // Reset the throttle so the first alert goes out immediately if the provider fails again.
        _tracker.MarkAsResolved(outage.AlertKey);

        _logger.LogInformation("{Provider} recovered after {DowntimeSeconds:F0}s of downtime.",
            providerType.Name, downtime.TotalSeconds);

        var trafficNote = outage.AlertKey.StartsWith("Fallback_") ? " Traffic is back on the primary provider." : string.Empty;

        await _alertService.SendAlertAsync(
            $"✅ *Provider Recovered*\n`{providerType.Name}` is back online after `{(int)downtime.TotalMinutes}m {downtime.Seconds}s` of downtime.{trafficNote}",
            null,
            stoppingToken);
    }

    private async Task ExecuteFallbackAsync(string fallbackProviderName, CancellationToken stoppingToken)
    {
        using var fallbackScope = _scopeFactory.CreateScope();

        var fallbackProvider = fallbackScope.ServiceProvider.GetServices<IPriceProvider>()
            .FirstOrDefault(p => p.GetType().Name == fallbackProviderName);

        if (fallbackProvider == null) return;

        var clock = fallbackScope.ServiceProvider.GetRequiredService<ISystemClock>();
        var repository = fallbackScope.ServiceProvider.GetRequiredService<IPriceHistoryRepository>();

        bool isMarketOpen = fallbackProvider.IsMarketOpen();

        var fallbackRawPrices = await fallbackProvider.GetMarketOverviewAsync(stoppingToken);

        if (fallbackRawPrices.Count > 0)
        {
            var verifiedPrices = await _priceProcessor.ProcessPricesAsync(fallbackRawPrices, fallbackProvider.ProviderName, isMarketOpen, stoppingToken);

            if (verifiedPrices.Count > 0)
            {
                var recordsToInsert = new List<PriceRecord>();

                lock (CacheLock)
                {
                    var currentSnapshot = _snapshotStore.Current;
                    var currentDict = currentSnapshot?.Items.ToDictionary(p => p.ProductCode)
                                       ?? new Dictionary<string, LatestPriceResponse>();

                    foreach (var newPrice in verifiedPrices)
                    {
                        // ValidUntilUtc is already computed in the mapper from the market state; leave it alone.
                        var safePrice = newPrice with
                        {
                            IsMarketOpen = isMarketOpen
                        };

                        bool hasPriceChanged = true;

                        if (currentDict.TryGetValue(safePrice.ProductCode, out var existingPrice))
                        {
                            if (existingPrice.Ask == safePrice.Ask && existingPrice.Bid == safePrice.Bid)
                            {
                                hasPriceChanged = false;
                            }
                        }

                        if (hasPriceChanged)
                        {
                            recordsToInsert.Add(new PriceRecord
                            {
                                Id = Guid.NewGuid(),
                                ProductCode = safePrice.ProductCode,
                                Source = safePrice.Source,
                                AskPrice = safePrice.Ask,
                                BidPrice = safePrice.Bid,
                                LastPrice = safePrice.LastPrice,
                                TimestampUtc = clock.UtcNow
                            });
                        }

                        currentDict[safePrice.ProductCode] = safePrice;
                    }

                    _snapshotStore.Set(new LatestPricesResponse(
                        Items: currentDict.Values.ToList(),
                        ComputedAtUtc: DateTimeOffset.UtcNow
                    ));
                }

                if (recordsToInsert.Count > 0)
                {
                    await repository.AddPriceRecordsAsync(recordsToInsert, stoppingToken);
                }

                _logger.LogInformation("Fallback to {FallbackProvider} completed successfully and data saved.", fallbackProviderName);
            }
        }
    }
}
