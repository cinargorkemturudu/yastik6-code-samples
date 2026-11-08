using System.Diagnostics;
using Polly;
using Yastık6.Api.Application.Common.Interfaces;
using Yastık6.Api.Application.Features.Prices;
using Yastık6.Api.Infrastructure.Alerts;

namespace Yastık6.Api.Infrastructure.Providers.Base;

/// <summary>
/// Common base that every price provider client builds on.
/// It standardizes error handling, Polly retries, the AlertTracker and clock handling.
/// </summary>
public abstract class BasePriceClient : IPriceProvider
{
    protected readonly ILogger Logger;
    protected readonly AlertTracker Tracker;
    protected readonly ISystemClock Clock;

    protected BasePriceClient(ILogger logger, AlertTracker tracker, ISystemClock clock)
    {
        Logger = logger;
        Tracker = tracker;
        Clock = clock;
    }

    public abstract string ProviderName { get; }

    public virtual bool IsMarketOpen() => true;

    public abstract TimeSpan RefreshInterval { get; }

    public virtual TimeSpan MarketCloseTime => TimeSpan.Zero;

    public async Task<List<LatestPriceResponse>> GetMarketOverviewAsync(CancellationToken ct = default)
    {
        // NOTE: the "if (!IsMarketOpen()) return empty;" block was removed on purpose.
        // Even when the market is closed we want to poll the latest data at the longer RefreshInterval (e.g. 30 min).

        var retryPolicy = Policy
            .Handle<Exception>()
            .WaitAndRetryAsync(
                retryCount: 2,
                sleepDurationProvider: attempt => TimeSpan.FromSeconds(2 * attempt),
                onRetry: (Exception exception, TimeSpan timeSpan, int retryCount, Context context) =>
                {
                    Logger.LogWarning("{Provider} API returned a transient error ({Message}). Retrying in {Delay}s (attempt {RetryCount}).",
                        ProviderName, exception.Message, timeSpan.TotalSeconds, retryCount);
                });

        var stopwatch = Stopwatch.StartNew();

        try
        {
            var results = await retryPolicy.ExecuteAsync(() => FetchDataAsync(ct));
            stopwatch.Stop();

            if (results == null || !results.Any())
            {
                Logger.LogWarning("{Provider} API returned no data. Success={Success} ItemCount={ItemCount} DurationMs={DurationMs}",
                    ProviderName, false, 0, stopwatch.ElapsedMilliseconds);
                Tracker.ShouldSendAlert($"SYS_{ProviderName}_Empty_Data");
                return new List<LatestPriceResponse>();
            }

            if (Tracker.MarkAsResolved($"SYS_{ProviderName}_Api_Down") ||
                Tracker.MarkAsResolved($"SYS_{ProviderName}_Empty_Data"))
            {
                Logger.LogInformation("{Provider} API connection restored, fetch succeeded.", ProviderName);
            }

            Logger.LogInformation("{Provider} fetch succeeded. Success={Success} ItemCount={ItemCount} DurationMs={DurationMs}",
                ProviderName, true, results.Count, stopwatch.ElapsedMilliseconds);

            // ValidUntilUtc as computed by the mappers (adjusted for market open/closed, weekends, etc.)
            // is returned here unchanged; it is now computed in a single place.
            return results;
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            // Application is shutting down; not an error.
            throw;
        }
        catch (Exception ex)
        {
            stopwatch.Stop();
            Logger.LogError(ex, "{Provider} fetch failed permanently. Success={Success} DurationMs={DurationMs}",
                ProviderName, false, stopwatch.ElapsedMilliseconds);
            Tracker.ShouldSendAlert($"SYS_{ProviderName}_Api_Down");

            // If we returned an empty list, PriceSnapshotRefresher would never see the failure: fallback and the Telegram alert
            // would not trigger. We rethrow so the refresher's own catch block takes over.
            throw new ProviderFetchException(ProviderName, ex);
        }
    }

    protected abstract Task<List<LatestPriceResponse>> FetchDataAsync(CancellationToken ct);
}
