using TokenChat.Core;
using TokenChat.Core.Analytics;

namespace TokenChat.Core.Tests;

public class UsageOverviewTests
{
    static readonly DateTimeOffset Now = new(2026, 10, 13, 12, 0, 0, TimeSpan.Zero);

    static string Prompt(string pid, DateTimeOffset at, string entrypoint = "cli") =>
        $$$"""{"type":"user","promptId":"{{{pid}}}","timestamp":"{{{at:O}}}","entrypoint":"{{{entrypoint}}}","cwd":"C:\\work\\proj","message":{"role":"user","content":"go"}}""";

    static string Reply(string id, long write, long read, long output) =>
        $$$"""{"type":"assistant","message":{"id":"{{{id}}}","model":"claude-opus-5-5","usage":{"input_tokens":1,"cache_creation_input_tokens":{{{write}}},"cache_read_input_tokens":{{{read}}},"output_tokens":{{{output}}}}}""" + "}";

    static SessionSummary Session(string sid, string entrypoint, params DateTimeOffset[] prompts) =>
        UsageOverview.Parse($"C:\\t\\{sid}.jsonl", sid,
            prompts.SelectMany((at, i) => new[] { Prompt($"p{i}", at, entrypoint), Reply($"m{sid}{i}", 1000, 10_000, 100) }).ToList());

    [Fact]
    public void ReadsCwdEntrypointAndCycleTimes()
    {
        var s = Session("a", "sdk-cli", Now.AddHours(-1));
        Assert.Equal(@"C:\work\proj", s.Cwd);
        Assert.Equal("proj", s.Project);
        Assert.True(s.TokenChat);
        Assert.Equal(Now.AddHours(-1), s.Rows[0].Cycle!.Started);
    }

    [Fact]
    public void RangeKeepsOnlyCyclesThatStartedInside()
    {
        var old = Session("a", "cli", Now.AddDays(-20), Now.AddDays(-1));
        var week = UsageOverview.Build([old], OverviewRange.Week, Now);
        var all = UsageOverview.Build([old], OverviewRange.All, Now);

        Assert.Equal(1, week.Cycles);
        Assert.Equal(2, all.Cycles);
        Assert.Equal(1, week.Sessions);
        Assert.Equal(21, all.Days.Count); // every day from the first cycle to today
        Assert.Equal(2, all.Days.Count(d => d.Weighted > 0));
        Assert.Equal(8, week.Days.Count);
    }

    [Fact]
    public void CountsWindowCommandsInsideTheRange()
    {
        string Cmd(string name, DateTimeOffset at) =>
            $$$"""{"type":"user","timestamp":"{{{at:O}}}","message":{"role":"user","content":"<command-name>/{{{name}}}</command-name>"}}""";
        var s = UsageOverview.Parse("x.jsonl", "x", [
            Prompt("p0", Now.AddDays(-1)), Reply("m0", 1000, 10_000, 100),
            Cmd("park", Now.AddDays(-1)), Cmd("park", Now.AddDays(-12)), Cmd("effort", Now.AddDays(-1)),
        ]);
        var o = UsageOverview.Build([s], OverviewRange.Week, Now);

        Assert.Equal(1, o.Commands["park"]);
        Assert.Equal(0, o.Commands["handoff"]);
        Assert.False(o.Commands.ContainsKey("effort"));
    }

    [Fact]
    public void WeighsSharesAndPrices()
    {
        var o = UsageOverview.Build([Session("a", "cli", Now.AddHours(-2)), Session("b", "sdk-cli", Now.AddHours(-1))],
            OverviewRange.Week, Now);

        // per cycle: 1 + 1000*2 + 10000*0.05 + 100*5
        Assert.Equal(2 * 3001, o.Weighted, 6);
        Assert.Equal(0.5, o.TokenChatShare, 6);
        Assert.Equal(20_000.0 / 22_002, o.HitRate, 6);
        Assert.Equal(0, o.Unpriced);
        Assert.Equal(2 * (1 * 4 + 1000 * 8 + 10_000 * 0.2 + 100 * 20) / 1e6, o.CostUsd, 9);
        Assert.Equal(2, o.Classes[BudgetClass.Recon]);
        Assert.Single(o.Projects);
    }
}
