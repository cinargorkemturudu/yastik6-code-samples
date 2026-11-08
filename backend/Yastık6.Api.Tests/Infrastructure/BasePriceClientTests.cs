using Microsoft.Extensions.Logging.Abstractions;
using Xunit;
using FluentAssertions;
using Yastık6.Api.Application.Common.Interfaces;
using Yastık6.Api.Application.Features.Prices;
using Yastık6.Api.Infrastructure.Alerts;
using Yastık6.Api.Infrastructure.Providers.Base;

namespace Yastık6.Api.Tests.Infrastructure.Providers;

public class BasePriceClientTests
{
    private sealed class FakeSystemClock : ISystemClock
    {
        public DateTime UtcNow { get; set; } = new(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc);
    }

    // Test double: RefreshInterval is deliberately tiny (15s) so it's obviously different
    // from the mapper's own multi-minute ValidUntilUtc window below — if BasePriceClient
    // ever goes back to overwriting ValidUntilUtc with now+RefreshInterval, this test catches it.
    private sealed class TestPriceClient : BasePriceClient
    {
        private readonly List<LatestPriceResponse> _results;

        public TestPriceClient(List<LatestPriceResponse> results, ISystemClock clock)
            : base(NullLogger.Instance, new AlertTracker(), clock)
        {
            _results = results;
        }

        public override string ProviderName => "TestProvider";
        public override TimeSpan RefreshInterval => TimeSpan.FromSeconds(15);

        protected override Task<List<LatestPriceResponse>> FetchDataAsync(CancellationToken ct)
            => Task.FromResult(_results);
    }

    private sealed class FailingPriceClient : BasePriceClient
    {
        private readonly Func<Exception> _exceptionFactory;

        public FailingPriceClient(Func<Exception> exceptionFactory)
            : base(NullLogger.Instance, new AlertTracker(), new FakeSystemClock())
        {
            _exceptionFactory = exceptionFactory;
        }

        public int FetchAttempts { get; private set; }

        public override string ProviderName => "TestProvider";
        public override TimeSpan RefreshInterval => TimeSpan.FromSeconds(15);

        protected override Task<List<LatestPriceResponse>> FetchDataAsync(CancellationToken ct)
        {
            FetchAttempts++;
            throw _exceptionFactory();
        }
    }

    [Fact]
    public async Task GetMarketOverviewAsync_Throws_ProviderFetchException_AfterRetriesExhausted()
    {
        // This used to return an empty list, so PriceSnapshotRefresher's fallback/Telegram path never triggered.
        var client = new FailingPriceClient(() => new HttpRequestException("Connection refused"));

        var act = () => client.GetMarketOverviewAsync();

        var thrown = await act.Should().ThrowAsync<ProviderFetchException>();
        thrown.Which.ProviderName.Should().Be("TestProvider");
        thrown.Which.InnerException.Should().BeOfType<HttpRequestException>();
        client.FetchAttempts.Should().Be(3); // 1 deneme + 2 Polly retry
    }

    [Fact]
    public async Task GetMarketOverviewAsync_Wraps_HttpTimeout_SoRefresherDoesNotMistakeItForShutdown()
    {
        // An HttpClient timeout surfaces as TaskCanceledException; if it were thrown as-is,
        // the refresher would mistake it for shutdown and stop the provider loop forever.
        var client = new FailingPriceClient(() => new TaskCanceledException("The request timed out."));

        var act = () => client.GetMarketOverviewAsync(CancellationToken.None);

        var thrown = await act.Should().ThrowAsync<ProviderFetchException>();
        thrown.Which.InnerException.Should().BeOfType<TaskCanceledException>();
    }

    [Fact]
    public async Task GetMarketOverviewAsync_LetsCancellationThrough_WhenAppIsShuttingDown()
    {
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        var client = new FailingPriceClient(() => new OperationCanceledException(cts.Token));

        var act = () => client.GetMarketOverviewAsync(cts.Token);

        await act.Should().ThrowAsync<OperationCanceledException>();
    }

    [Fact]
    public async Task GetMarketOverviewAsync_DoesNotOverwrite_MapperComputedValidUntilUtc()
    {
        // Arrange: mapper decided this asset (e.g. Harem outside trading hours) stays valid
        // for 35 minutes — far outside the provider's own 15s RefreshInterval.
        var mapperComputedValidUntil = new DateTimeOffset(2026, 1, 1, 12, 35, 0, TimeSpan.Zero);
        var mapperPrice = new LatestPriceResponse(
            ProductCode: "GRAM_ALTIN",
            Name: "Gram Altın",
            Type: "METAL",
            Bid: 100m,
            Ask: 101m,
            LastPrice: null,
            ChangeRate: 0m,
            FormattedBid: "100,00",
            FormattedAsk: "101,00",
            AsOfUtc: DateTimeOffset.UtcNow,
            ValidUntilUtc: mapperComputedValidUntil,
            Source: "Harem"
        );

        var client = new TestPriceClient(new List<LatestPriceResponse> { mapperPrice }, new FakeSystemClock());

        // Act
        var results = await client.GetMarketOverviewAsync();

        // Assert
        results.Should().ContainSingle();
        results[0].ValidUntilUtc.Should().Be(mapperComputedValidUntil);
    }
}
