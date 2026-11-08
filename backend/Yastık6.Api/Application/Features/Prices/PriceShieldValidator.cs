using System.Collections.Concurrent;
using Yastık6.Api.Infrastructure.Alerts;

namespace Yastık6.Api.Application.Features.Prices;

/// <summary>
/// Price Shield: checks incoming prices for anomalies before they enter the system.
/// </summary>
public sealed class PriceShieldValidator
{
    private readonly ILogger<PriceShieldValidator> _logger;
    private readonly IAlertService _alertService;
    private readonly AlertTracker _tracker; // Tracks which alerts were already sent, to throttle duplicates

    // A >40% jump is rejected as a glitch, but if the next readings keep agreeing on the new level
    // it is a real move (e.g. a crypto crash, or a cached price that went stale). Without this the
    // symbol would stay frozen on the old price until the app restarts.
    public const int ConfirmationsToReanchor = 3;
    public const decimal ConfirmationTolerancePercent = 5m;
    private readonly ConcurrentDictionary<string, (decimal Ask, int Count)> _pendingMoves = new();

    public PriceShieldValidator(ILogger<PriceShieldValidator> logger, IAlertService alertService, AlertTracker tracker)
    {
        _logger = logger;
        _alertService = alertService;
        _tracker = tracker;
    }

    public async Task<bool> ValidatePriceAsync(
        LatestPriceResponse newPrice,
        LatestPriceResponse? existingPrice,
        CancellationToken ct)
    {
        // --- SHIELD 1: ZERO OR NEGATIVE PRICE ---
        if (newPrice.Ask <= 0 || newPrice.Bid <= 0)
        {
            var cacheKey = $"ZeroPrice_{newPrice.ProductCode}";

            // Ask the tracker whether this was already reported within the last hour
            if (_tracker.ShouldSendAlert(cacheKey))
            {
                _logger.LogWarning("[SHIELD REJECT] {Code} returned a zero/negative price! Source: {Source}, Price: {Price}",
                    newPrice.ProductCode, newPrice.Source, newPrice.Ask);

                await _alertService.SendAlertAsync(
                    $"⚠️ *ZERO PRICE REJECTED*\nSymbol: `{newPrice.ProductCode}`\nSource: `{newPrice.Source}`\nPrice: `{newPrice.Ask}`\n_Sistem mevcut geçerli fiyatı korudu._",
                    cacheKey,
                    ct);
            }

            return false;
        }

        // --- SHIELD 2: FLASH CRASH / SPIKE ---
        if (existingPrice != null && existingPrice.Ask > 0)
        {
            var instantChange = Math.Abs((newPrice.Ask - existingPrice.Ask) / existingPrice.Ask * 100m);

            if (instantChange > 40m)
            {
                if (ConfirmsPendingMove(newPrice))
                {
                    _pendingMoves.TryRemove(newPrice.ProductCode, out _);
                    _logger.LogWarning("[SHIELD RE-ANCHOR] {Code} moved %{Rate:N2} and held for {Count} readings; accepting the new price. Old: {Old}, New: {New}",
                        newPrice.ProductCode, instantChange, ConfirmationsToReanchor, existingPrice.Ask, newPrice.Ask);

                    await _alertService.SendAlertAsync(
                        $"♻️ *PRICE RE-ANCHORED*\nSymbol: `{newPrice.ProductCode}`\nOld: `{existingPrice.Ask}`\nNew: `{newPrice.Ask}`\n_{ConfirmationsToReanchor} tutarlı okuma sonrası yeni fiyat kabul edildi._",
                        $"Reanchor_{newPrice.ProductCode}",
                        ct);
                    return true;
                }

                var cacheKey = $"FlashCrash_{newPrice.ProductCode}";

                // The spike report is also throttled to one alert per hour
                if (_tracker.ShouldSendAlert(cacheKey))
                {
                    _logger.LogCritical("[SHIELD FLASH CRASH] Abnormal deviation detected for {Code}! Old: {Old}, New: {New}, Deviation: %{Rate}",
                        newPrice.ProductCode, existingPrice.Ask, newPrice.Ask, instantChange);

                    await _alertService.SendAlertAsync(
                        $"🚨 *FLASH CRASH DETECTED*\nSymbol: `{newPrice.ProductCode}`\nOld: `{existingPrice.Ask}`\nNew: `{newPrice.Ask}`\nDeviation: `%{instantChange:N2}`\nSource: `{newPrice.Source}`",
                        cacheKey,
                        ct);
                }

                return false;
            }
        }

        _pendingMoves.TryRemove(newPrice.ProductCode, out _);
        return true;
    }

    /// <summary>
    /// Records a rejected jump and returns true once <see cref="ConfirmationsToReanchor"/> consecutive
    /// readings have landed within <see cref="ConfirmationTolerancePercent"/> of each other.
    /// </summary>
    private bool ConfirmsPendingMove(LatestPriceResponse newPrice)
    {
        var pending = _pendingMoves.AddOrUpdate(
            newPrice.ProductCode,
            _ => (newPrice.Ask, 1),
            (_, previous) => Math.Abs((newPrice.Ask - previous.Ask) / previous.Ask * 100m) <= ConfirmationTolerancePercent
                ? (newPrice.Ask, previous.Count + 1)
                : (newPrice.Ask, 1));

        return pending.Count >= ConfirmationsToReanchor;
    }
}
