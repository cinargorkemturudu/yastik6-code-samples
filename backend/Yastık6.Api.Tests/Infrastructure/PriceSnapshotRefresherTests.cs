using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using Xunit;
using FluentAssertions;
using Yastık6.Api.Application.Common.Interfaces;
using Yastık6.Api.Application.Features.Prices;
using Yastık6.Api.Infrastructure.Alerts;
using Yastık6.Api.Infrastructure.BackgroundJobs;
using Yastık6.Api.Infrastructure.Caching;
using Yastık6.Api.Infrastructure.Providers.Base;

namespace Yastık6.Api.Tests.Infrastructure.BackgroundJobs;

public class PriceSnapshotRefresherTests
{
    private static LatestPriceResponse Price(string code, string source) => new(
        ProductCode: code,
        Name: code,
        Type: "FOREX",
        Bid: 40m,
        Ask: 41m,
        LastPrice: null,
        ChangeRate: 0m,
        FormattedBid: "40,00",
        FormattedAsk: "41,00",
        AsOfUtc: DateTimeOffset.UtcNow,
        ValidUntilUtc: DateTimeOffset.UtcNow.AddMinutes(5),
        Source: source
    );

    // Switch the test uses to control when the primary provider fails and when it recovers.
    private sealed class OutageSwitch
    {
        public volatile bool IsDown = true;
    }

    // PriceSnapshotRefresher maps the fallback by type NAME ("FreeCurrencyClient" -> "YahooForexClient"),
    // so the test doubles carry the same names as the real clients.
    private sealed class FreeCurrencyClient(OutageSwitch outage) : IPriceProvider
    {
        public string ProviderName => "FreeCurrencyAPI";
        public bool IsMarketOpen() => true;
        public TimeSpan RefreshInterval => TimeSpan.FromMinutes(10);
        public TimeSpan MarketCloseTime => TimeSpan.Zero;

        public Task<List<LatestPriceResponse>> GetMarketOverviewAsync(CancellationToken ct = default)
            => outage.IsDown
                ? throw new ProviderFetchException(ProviderName, new HttpRequestException("Connection refused"))
                : Task.FromResult(new List<LatestPriceResponse> { Price("USDTRY", "FreeCurrencyAPI") });
    }

    private sealed class YahooForexClient : IPriceProvider
    {
        public string ProviderName => "YahooForex";
        public bool IsMarketOpen() => true;
        public TimeSpan RefreshInterval => TimeSpan.FromMinutes(10);
        public TimeSpan MarketCloseTime => TimeSpan.Zero;

        public Task<List<LatestPriceResponse>> GetMarketOverviewAsync(CancellationToken ct = default)
            => Task.FromResult(new List<LatestPriceResponse> { Price("USDTRY", "YahooForex") });
    }

    private sealed class FakeSystemClock : ISystemClock
    {
        public DateTime UtcNow => DateTime.UtcNow;
    }

    private sealed record Harness(PriceSnapshotRefresher Refresher, PriceSnapshotStore Store, OutageSwitch Outage, AlertTracker Tracker, Func<int, Task<IReadOnlyList<string>>> WaitForAlerts, ServiceProvider Services);

    private static Harness CreateHarness()
    {
        var snapshotStore = new PriceSnapshotStore();
        var outage = new OutageSwitch();
        var tracker = new AlertTracker();

        var processor = new Mock<IPriceProcessor>();
        processor
            .Setup(p => p.ProcessPricesAsync(It.IsAny<List<LatestPriceResponse>>(), It.IsAny<string>(), It.IsAny<bool>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync((List<LatestPriceResponse> raw, string _, bool _, CancellationToken _) => raw);

        var sentAlerts = new List<string>();
        var alerts = new Mock<IAlertService>();
        alerts
            .Setup(a => a.SendAlertAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()))
            .Callback((string message, string cacheKey, CancellationToken _) =>
            {
                // Like the real TelegramAlertService: keyed alerts are recorded in the tracker as "active".
                if (!string.IsNullOrEmpty(cacheKey)) tracker.ShouldSendAlert(cacheKey);
                lock (sentAlerts) sentAlerts.Add(message);
            })
            .Returns(Task.CompletedTask);

        async Task<IReadOnlyList<string>> WaitForAlerts(int count)
        {
            var deadline = DateTime.UtcNow.AddSeconds(5);
            while (DateTime.UtcNow < deadline)
            {
                lock (sentAlerts) if (sentAlerts.Count >= count) return sentAlerts.ToList();
                await Task.Delay(20);
            }
            lock (sentAlerts) return sentAlerts.ToList();
        }

        var services = new ServiceCollection();
        services.AddSingleton(outage);
        services.AddTransient<IPriceProvider, FreeCurrencyClient>();
        services.AddTransient<IPriceProvider, YahooForexClient>();
        services.AddSingleton<ISystemClock, FakeSystemClock>();
        services.AddSingleton(Mock.Of<IPriceHistoryRepository>());
        var provider = services.BuildServiceProvider();

        var refresher = new PriceSnapshotRefresher(
            snapshotStore,
            processor.Object,
            NullLogger<PriceSnapshotRefresher>.Instance,
            provider.GetRequiredService<IServiceScopeFactory>(),
            alerts.Object,
            tracker)
        {
            CrashBackoff = TimeSpan.FromMilliseconds(200)
        };

        return new Harness(refresher, snapshotStore, outage, tracker, WaitForAlerts, provider);
    }

    [Fact]
    public async Task ProviderFailure_TriggersFallback_AndSendsTelegramAlert()
    {
        var h = CreateHarness();

        await h.Refresher.StartAsync(CancellationToken.None);
        var alerts = await h.WaitForAlerts(1);
        await h.Refresher.StopAsync(CancellationToken.None);
        h.Services.Dispose();

        alerts.Should().NotBeEmpty();
        alerts[0].Should().Contain("Fallback Activated").And.Contain("YahooForexClient");
        h.Store.Current.Should().NotBeNull();
        h.Store.Current!.Items.Should().Contain(p => p.ProductCode == "USDTRY" && p.Source == "YahooForex");
    }

    [Fact]
    public async Task PrimaryComingBack_SendsRecoveredAlert_Once_AndClearsOutageAlert()
    {
        var h = CreateHarness();

        await h.Refresher.StartAsync(CancellationToken.None);
        (await h.WaitForAlerts(1)).Should().ContainSingle(a => a.Contains("Fallback Activated"));

        // Primary geri geliyor; bir sonraki denemede "Recovered" bildirimi gitmeli.
        h.Outage.IsDown = false;
        var alerts = await h.WaitForAlerts(2);

        // Recovery must be reported only once (later successful fetches stay silent).
        await Task.Delay(500);
        alerts = await h.WaitForAlerts(2);
        await h.Refresher.StopAsync(CancellationToken.None);
        h.Services.Dispose();

        alerts.Should().HaveCount(2);
        alerts[1].Should().Contain("Provider Recovered").And.Contain("FreeCurrencyClient").And.Contain("back on the primary provider");
        h.Tracker.GetCurrentSnapshot().Active.Should().NotContainKey("Fallback_FreeCurrencyClient_YahooForexClient");
        h.Store.Current!.Items.Should().Contain(p => p.ProductCode == "USDTRY" && p.Source == "FreeCurrencyAPI");
    }
}
