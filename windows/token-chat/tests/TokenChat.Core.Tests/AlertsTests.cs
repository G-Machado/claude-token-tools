namespace TokenChat.Core.Tests;

public class AlertsTests
{
    static FeedSnapshot Feed(long generated, int left, int marks, int blocked, string verdict, double ctx, double fivePct) =>
        FeedSnapshot.Parse($$$"""
            {"generated":{{{generated}}},"constants":{},"limits":{"accounts":[{"n":1,"active":1,"five_hour_pct":{{{fivePct}}},"five_hour_in":"1h 2m"}]},
             "sessions":[{"sid":"aaaaaaaa-1","nick":"repo","alive":1,"cache_left_min":{{{left}}},"ext_left":{{{marks}}},"blocked":{{{blocked}}},
                          "verdict":"{{{verdict}}}","context":{{{ctx}}}},
                         {"sid":"bbbbbbbb-2","nick":"gone","alive":0,"cache_left_min":3,"ext_left":0,"blocked":1,"context":200000}]}
            """)!;

    [Fact]
    public void EachAlertFiresOnceAndAgainOnlyAfterItCleared()
    {
        var a = new Alerts();
        var now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
        // already true at startup: not news
        Assert.Empty(a.Check(Feed(1_800_000_000, 5, 0, 1, "ok", 120_000, 95), now));
        Assert.Empty(a.Check(Feed(1_800_000_000, 5, 0, 1, "ok", 120_000, 95), now));

        // block lifted, limit eased, cache renewed; then each comes back
        Assert.Empty(a.Check(Feed(1_800_000_000, 50, 0, 0, "ok", 120_000, 40), now));
        var said = a.Check(Feed(1_800_000_000, 6, 0, 1, "ok", 120_000, 92), now);
        Assert.Equal(["repo is blocked", "5h limit at 92%"], said.Select(s => s.Title));

        // a blocked window's lapse is not news; unblocked with no marks it is, the clock run down since the collect
        said = a.Check(Feed(1_800_000_000, 9, 0, 0, "ok", 120_000, 92), now.AddMinutes(2));
        Assert.Equal(["repo: cache lapses in 7m"], said.Select(s => s.Title));
        // a mark left, or a window under the floor: the poke task has it, or it is cheap to lose
        Assert.Empty(a.Check(Feed(1_800_000_000, 9, 1, 0, "ok", 120_000, 92), now.AddMinutes(2)));
        Assert.Empty(a.Check(Feed(1_800_000_000, 5, 0, 0, "ok", 40_000, 92), now));

        // the cut bar: once per 50k band, never again for the same band
        Assert.Equal(["repo is past the cut bar"], a.Check(Feed(1_800_000_000, 50, 0, 0, "cut", 245_000, 92), now).Select(s => s.Title));
        Assert.Empty(a.Check(Feed(1_800_000_000, 50, 0, 0, "ok", 245_000, 92), now));
        Assert.Empty(a.Check(Feed(1_800_000_000, 50, 0, 0, "cut", 248_000, 92), now));
        Assert.Single(a.Check(Feed(1_800_000_000, 50, 0, 0, "cut", 251_000, 92), now));
    }
}
