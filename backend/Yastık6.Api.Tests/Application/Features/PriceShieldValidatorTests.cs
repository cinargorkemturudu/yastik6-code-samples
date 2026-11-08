using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using Xunit;
using FluentAssertions;
using Yastık6.Api.Application.Features.Prices;
using Yastık6.Api.Infrastructure.Alerts;

namespace Yastık6.Api.Tests.Application.Features;

public class PriceShieldValidatorTests
{
    private static LatestPriceResponse MakePrice(string productCode, decimal bid, decimal ask, string source = "Harem")
        => new(
            ProductCode: productCode,
            Name: productCode,
            Type: "METAL",
            Bid: bid,
            Ask: ask,
            LastPrice: null,
            ChangeRate: 0m,
            FormattedBid: bid.ToString(),
            FormattedAsk: ask.ToString(),
            AsOfUtc: DateTimeOffset.UtcNow,
            ValidUntilUtc: DateTimeOffset.UtcNow.AddMinutes(5),
            Source: source
        );

    private static PriceShieldValidator CreateValidator(out Mock<IAlertService> alertServiceMock)
    {
        alertServiceMock = new Mock<IAlertService>();
        return new PriceShieldValidator(
            NullLogger<PriceShieldValidator>.Instance,
            alertServiceMock.Object,
            new AlertTracker());
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-5)]
    public async Task ValidatePriceAsync_RejectsZeroOrNegativeAsk(decimal badAsk)
    {
        var validator = CreateValidator(out var alertServiceMock);
        var price = MakePrice("GRAM_ALTIN", bid: 100m, ask: badAsk);

        var result = await validator.ValidatePriceAsync(price, existingPrice: null, ct: default);

        result.Should().BeFalse();
        alertServiceMock.Verify(a => a.SendAlertAsync(
            It.IsAny<string>(), "ZeroPrice_GRAM_ALTIN", It.IsAny<CancellationToken>()), Times.Once);
    }

    [Fact]
    public async Task ValidatePriceAsync_AcceptsValidPrice_WithNoExistingPrice()
    {
        var validator = CreateValidator(out var alertServiceMock);
        var price = MakePrice("GRAM_ALTIN", bid: 100m, ask: 101m);

        var result = await validator.ValidatePriceAsync(price, existingPrice: null, ct: default);

        result.Should().BeTrue();
        alertServiceMock.Verify(a => a.SendAlertAsync(
            It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task ValidatePriceAsync_RejectsFlashCrash_WhenDeviationExceeds40Percent()
    {
        var validator = CreateValidator(out var alertServiceMock);
        var existingPrice = MakePrice("GRAM_ALTIN", bid: 100m, ask: 100m);
        // 41% below the existing Ask
        var crashedPrice = MakePrice("GRAM_ALTIN", bid: 59m, ask: 59m);

        var result = await validator.ValidatePriceAsync(crashedPrice, existingPrice, ct: default);

        result.Should().BeFalse();
        alertServiceMock.Verify(a => a.SendAlertAsync(
            It.IsAny<string>(), "FlashCrash_GRAM_ALTIN", It.IsAny<CancellationToken>()), Times.Once);
    }

    [Fact]
    public async Task ValidatePriceAsync_AcceptsPrice_AtExactly40PercentDeviation()
    {
        var validator = CreateValidator(out var alertServiceMock);
        var existingPrice = MakePrice("GRAM_ALTIN", bid: 100m, ask: 100m);
        // Exactly 40% below — boundary is "> 40", so this must still pass
        var borderlinePrice = MakePrice("GRAM_ALTIN", bid: 60m, ask: 60m);

        var result = await validator.ValidatePriceAsync(borderlinePrice, existingPrice, ct: default);

        result.Should().BeTrue();
    }

    [Fact]
    public async Task ValidatePriceAsync_DoesNotSpamAlerts_ForRepeatedZeroPriceWithinSilenceWindow()
    {
        var validator = CreateValidator(out var alertServiceMock);
        var price = MakePrice("GRAM_ALTIN", bid: 100m, ask: 0m);

        await validator.ValidatePriceAsync(price, existingPrice: null, ct: default);
        await validator.ValidatePriceAsync(price, existingPrice: null, ct: default);

        // AlertTracker silences repeat alerts for the same cacheKey within its 1-hour window
        alertServiceMock.Verify(a => a.SendAlertAsync(
            It.IsAny<string>(), "ZeroPrice_GRAM_ALTIN", It.IsAny<CancellationToken>()), Times.Once);
    }

    [Fact]
    public async Task ValidatePriceAsync_ReanchorsAfterConsistentReadings_InsteadOfFreezingForever()
    {
        var validator = CreateValidator(out var alertServiceMock);
        var existingPrice = MakePrice("BTC-USD", bid: 100m, ask: 100m, source: "Binance");

        // A real 50% crash that persists: the first readings are rejected as a possible glitch...
        (await validator.ValidatePriceAsync(MakePrice("BTC-USD", 50m, 50m, "Binance"), existingPrice, default)).Should().BeFalse();
        (await validator.ValidatePriceAsync(MakePrice("BTC-USD", 51m, 51m, "Binance"), existingPrice, default)).Should().BeFalse();
        // ...and the third consistent reading is accepted as the new reality
        (await validator.ValidatePriceAsync(MakePrice("BTC-USD", 50.5m, 50.5m, "Binance"), existingPrice, default)).Should().BeTrue();

        alertServiceMock.Verify(a => a.SendAlertAsync(
            It.IsAny<string>(), "Reanchor_BTC-USD", It.IsAny<CancellationToken>()), Times.Once);
    }

    [Fact]
    public async Task ValidatePriceAsync_SingleSpike_IsNotReanchored_AndNormalReadingResetsTheCount()
    {
        var validator = CreateValidator(out _);
        var existingPrice = MakePrice("GRAM_ALTIN", bid: 100m, ask: 100m);

        (await validator.ValidatePriceAsync(MakePrice("GRAM_ALTIN", 10m, 10m), existingPrice, default)).Should().BeFalse();
        (await validator.ValidatePriceAsync(MakePrice("GRAM_ALTIN", 10m, 10m), existingPrice, default)).Should().BeFalse();
        // A normal reading in between clears the suspicion...
        (await validator.ValidatePriceAsync(MakePrice("GRAM_ALTIN", 101m, 101m), existingPrice, default)).Should().BeTrue();
        // ...so the next glitch starts counting from zero again
        (await validator.ValidatePriceAsync(MakePrice("GRAM_ALTIN", 10m, 10m), existingPrice, default)).Should().BeFalse();
    }

    [Fact]
    public async Task ValidatePriceAsync_InconsistentGarbage_NeverReanchors()
    {
        var validator = CreateValidator(out _);
        var existingPrice = MakePrice("GRAM_ALTIN", bid: 100m, ask: 100m);

        foreach (var glitch in new[] { 10m, 300m, 20m, 500m, 5m, 250m })
        {
            (await validator.ValidatePriceAsync(MakePrice("GRAM_ALTIN", glitch, glitch), existingPrice, default))
                .Should().BeFalse($"{glitch} does not agree with the previous reading");
        }
    }
}
