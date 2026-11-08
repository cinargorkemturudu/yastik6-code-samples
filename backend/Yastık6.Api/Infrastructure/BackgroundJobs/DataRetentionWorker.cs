using Yastık6.Api.Application.Common.Interfaces;
using Yastık6.Api.Domain.Entities;
using Yastık6.Api.Infrastructure.Alerts;

namespace Yastık6.Api.Infrastructure.BackgroundJobs;

public sealed class DataRetentionWorker(
    IServiceScopeFactory scopeFactory, 
    ILogger<DataRetentionWorker> logger,
    IAlertService alertService) : BackgroundService
{
    private readonly TimeSpan _runInterval = TimeSpan.FromDays(1);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        logger.LogInformation("Data Retention and Compression worker started.");

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await CompressOldDataAsync(stoppingToken);
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "An error occurred during the data compression cycle!");
                
                // cacheKey lets the alert service throttle repeated alerts
                await alertService.SendAlertAsync(
                    $"🗑️ *VERİTABANI BAKIM HATASI*\nGeçmiş veriler temizlenemedi/sıkıştırılamadı. DB boyutu kontrolsüz büyüyebilir!\nHata: `{ex.Message}`", 
                    $"DataRetention_{ex.GetType().Name}",
                    stoppingToken);
            }

            await Task.Delay(_runInterval, stoppingToken);
        }
    }

    private async Task CompressOldDataAsync(CancellationToken ct)
    {
        using var scope = scopeFactory.CreateScope();
        var repository = scope.ServiceProvider.GetRequiredService<IPriceHistoryRepository>();
        var clock = scope.ServiceProvider.GetRequiredService<ISystemClock>();

        var now = clock.UtcNow;

        var weekAgo = now.AddDays(-7);
        var monthAgo = now.AddDays(-30);
        
        var currentChunkStart = monthAgo;
        while (currentChunkStart < weekAgo)
        {
            var currentChunkEnd = currentChunkStart.AddDays(1);
            if (currentChunkEnd > weekAgo) currentChunkEnd = weekAgo;

            await ProcessTimeRangeAsync(repository, currentChunkStart, currentChunkEnd, TimeSpan.FromHours(2), ct);
            currentChunkStart = currentChunkEnd;
        }

        var fiveYearsAgo = now.AddYears(-5); 
        currentChunkStart = fiveYearsAgo;
        
        while (currentChunkStart < monthAgo)
        {
            var currentChunkEnd = currentChunkStart.AddMonths(1);
            if (currentChunkEnd > monthAgo) currentChunkEnd = monthAgo;

            await ProcessTimeRangeAsync(repository, currentChunkStart, currentChunkEnd, TimeSpan.FromDays(1), ct);
            currentChunkStart = currentChunkEnd;
        }
        
        logger.LogInformation("Daily database cleanup and compression cycle completed successfully. Memory limits preserved.");
    }

    private async Task ProcessTimeRangeAsync(
        IPriceHistoryRepository repository, 
        DateTimeOffset start, 
        DateTimeOffset end, 
        TimeSpan bucketSize, 
        CancellationToken ct)
    {
        var oldRecords = await repository.GetPricesBetweenAsync(start, end, ct);

        if (oldRecords.Count == 0) return;

        var compressedRecords = oldRecords
            .GroupBy(r => new 
            { 
                r.ProductCode, 
                BucketKey = r.TimestampUtc.Ticks / bucketSize.Ticks 
            })
            .Select(g => new PriceRecord
            {
                Id = Guid.NewGuid(),
                ProductCode = g.Key.ProductCode,
                Source = g.First().Source, 
                AskPrice = g.Average(r => r.AskPrice),
                BidPrice = g.Average(r => r.BidPrice),
                
                // Keep LastPrice from being lost during downsampling.
                // Average the group's LastPrice values too and store them on the new record.
                LastPrice = g.Average(r => r.LastPrice), 
                
                TimestampUtc = new DateTimeOffset(g.Key.BucketKey * bucketSize.Ticks, TimeSpan.Zero)
            })
            .ToList();

        if (compressedRecords.Count >= oldRecords.Count) return;

        await repository.AddPriceRecordsAsync(compressedRecords, ct);
        await repository.DeletePriceRecordsAsync(oldRecords, ct);
        
        logger.LogInformation(
            "[{Start} - {End}]: {OldCount} raw rows deleted, {NewCount} compressed buckets inserted.", 
            start.ToString("dd/MM/yyyy"), end.ToString("dd/MM/yyyy"), oldRecords.Count, compressedRecords.Count);
    }
}