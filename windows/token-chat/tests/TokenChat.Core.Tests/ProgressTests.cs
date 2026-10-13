using TokenChat.Core.Analytics;

namespace TokenChat.Core.Tests;

public class ProgressTests
{
    static string Prompt(string pid, DateTimeOffset at, string entrypoint) =>
        $$$"""{"type":"user","promptId":"{{{pid}}}","timestamp":"{{{at:O}}}","entrypoint":"{{{entrypoint}}}","message":{"role":"user","content":"go"}}""";

    static string Reply(string id, long write, long output) =>
        $$$"""{"type":"assistant","message":{"id":"{{{id}}}","model":"claude-opus-5-5","usage":{"input_tokens":0,"cache_creation_input_tokens":{{{write}}},"cache_read_input_tokens":0,"output_tokens":{{{output}}}}}""" + "}";

    static SessionSummary One(string sid, string entrypoint, DateTimeOffset at, long write, long output) =>
        UsageOverview.Parse(sid, sid, [Prompt("p", at, entrypoint), Reply("m" + sid, write, output)]);

    static readonly DateTimeOffset Oct1 = new(2026, 10, 1, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void SplitsAtTheFirstTokenChatCycle()
    {
        var p = ProgressReport.Build([
            One("a", "cli", Oct1.AddDays(-10), 1000, 100),  // 2500 weighted
            One("b", "sdk-cli", Oct1, 500, 100),           // 1500
            One("c", "cli", Oct1.AddDays(2), 2000, 0),     // 4000
        ]);

        Assert.Equal(DateOnly.FromDateTime(Oct1.LocalDateTime.Date), p.Adopted);
        Assert.Equal(2500, p.Before.PerCycle, 6);
        Assert.Equal(1500, p.SinceTokenChat.PerCycle, 6);
        Assert.Equal(4000, p.SinceTerminal.PerCycle, 6);
        Assert.Equal(500.0 / 1500, p.SinceTokenChat.OutputShare, 6);
        Assert.Equal(2, p.Weeks.Count);
        Assert.Equal(0, p.Weeks[0].TokenChat.Cycles);
        Assert.Equal(1, p.Weeks[1].TokenChat.Cycles);
    }

    [Fact]
    public void NoTokenChatYetPutsEverythingBefore()
    {
        var p = ProgressReport.Build([One("a", "cli", Oct1, 1000, 100)]);
        Assert.Null(p.Adopted);
        Assert.Equal(1, p.Before.Cycles);
        Assert.Equal(0, p.SinceTokenChat.Cycles);
    }

    [Fact]
    public void ChangeIsAShareOfBefore() => Assert.Equal("-25%", ProgressReport.Change(200, 150));

    [Fact]
    public void HoursBucketByLocalWeekdayAndHour()
    {
        var at = new DateTimeOffset(2026, 10, 5, 9, 30, 0, TimeZoneInfo.Local.GetUtcOffset(new DateTime(2026, 10, 5, 9, 30, 0)));
        var o = UsageOverview.Build([One("a", "cli", at, 1000, 0)], OverviewRange.All, at.AddHours(1));
        Assert.Equal(2000, o.Hours[0 * 24 + 9], 6); // 2026-10-05 is a Monday
        Assert.Equal(2000, o.Hours.Sum(), 6);
    }
}
