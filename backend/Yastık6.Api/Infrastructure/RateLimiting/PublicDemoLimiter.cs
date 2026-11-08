using System.Threading.RateLimiting;

namespace Yastık6.Api.Infrastructure.RateLimiting;

// Rate limits for everything under /api/public (the JSON endpoints and the Swagger page's files).
// Runs as the app's global limiter, so it also covers the docs, which aren't controller endpoints.
// Mobile app routes always get a no-op limiter here and keep their own [EnableRateLimiting] policy.
public sealed class PublicDemoLimiter
{
    private readonly PartitionedRateLimiter<HttpContext> _sharedCeiling;

    public PublicDemoLimiter(int permitPerVisitorPerMinute, int sharedPermitPerMinute)
    {
        var perVisitor = PartitionedRateLimiter.Create<HttpContext, string>(context =>
            IsPublic(context)
                ? RateLimitPartition.GetFixedWindowLimiter(ClientIpResolver.PartitionKey(context), _ => PerMinute(permitPerVisitorPerMinute))
                : RateLimitPartition.GetNoLimiter(string.Empty));

        // A shared ceiling across all visitors, so many IPs (or a forged CF-Connecting-IP) can't add
        // up to real load. This is the number that bounds the server's bandwidth and CPU.
        _sharedCeiling = PartitionedRateLimiter.Create<HttpContext, string>(context =>
            IsPublic(context)
                ? RateLimitPartition.GetFixedWindowLimiter("public-all", _ => PerMinute(sharedPermitPerMinute))
                : RateLimitPartition.GetNoLimiter(string.Empty));

        // Per-visitor first: someone already over their own limit is rejected without
        // also spending the shared budget that other visitors need.
        Limiter = PartitionedRateLimiter.CreateChained(perVisitor, _sharedCeiling);
    }

    public PartitionedRateLimiter<HttpContext> Limiter { get; }

    public bool IsSharedCeilingExhausted(HttpContext context) =>
        _sharedCeiling.GetStatistics(context)?.CurrentAvailablePermits <= 0;

    // At most one "shared ceiling hit" alert per hour, however long the flood lasts.
    private static readonly TimeSpan AlertSilence = TimeSpan.FromHours(1);
    private long _lastAlertTicks;

    public bool TryClaimAlert(DateTimeOffset now)
    {
        var last = Interlocked.Read(ref _lastAlertTicks);
        if (now.UtcTicks - last < AlertSilence.Ticks) return false;
        return Interlocked.CompareExchange(ref _lastAlertTicks, now.UtcTicks, last) == last;
    }

    public static bool IsPublic(HttpContext context) =>
        context.Request.Path.StartsWithSegments(RateLimitPolicies.PublicPathPrefix);

    private static FixedWindowRateLimiterOptions PerMinute(int permits) => new()
    {
        Window = TimeSpan.FromMinutes(1),
        PermitLimit = permits,
        QueueLimit = 0
    };
}
