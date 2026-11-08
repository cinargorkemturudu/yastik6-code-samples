using FluentAssertions;
using Yastık6.Api.Infrastructure.RateLimiting;

namespace Yastık6.Api.Tests.Infrastructure;

public class PublicDemoLimiterTests
{
    [Fact]
    public void TryClaimAlert_AllowsOneAlertPerHour()
    {
        var limiter = new PublicDemoLimiter(permitPerVisitorPerMinute: 1, sharedPermitPerMinute: 1);
        var start = new DateTimeOffset(2026, 10, 25, 12, 0, 0, TimeSpan.Zero);

        limiter.TryClaimAlert(start).Should().BeTrue();
        limiter.TryClaimAlert(start.AddMinutes(59)).Should().BeFalse();
        limiter.TryClaimAlert(start.AddMinutes(61)).Should().BeTrue();
    }
}
