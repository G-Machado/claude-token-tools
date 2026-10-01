using TokenChat.Core;
using TokenChat.Core.Analytics;

namespace TokenChat.Core.Tests;

public class TranscriptCyclesTests
{
    static string Prompt(string pid) =>
        $$$"""{"type":"user","promptId":"{{{pid}}}","message":{"role":"user","content":"go"}}""";

    static string ToolResult(string pid) =>
        $$$"""{"type":"user","promptId":"{{{pid}}}","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}""";

    static string Reply(string id, long input, long write, long read, long output, bool sidechain = false) =>
        $$$"""{"type":"assistant","isSidechain":{{{(sidechain ? "true" : "false")}}},"message":{"id":"{{{id}}}","usage":{"input_tokens":{{{input}}},"cache_creation_input_tokens":{{{write}}},"cache_read_input_tokens":{{{read}}},"output_tokens":{{{output}}},"service_tier":"standard"}}""" + "}";

    [Fact]
    public void PromptIdChangeStartsACycleAndToolResultsDoNot()
    {
        var cycles = TranscriptCycles.Parse([
            Prompt("p1"), Reply("msg_a", 2, 100, 0, 10), ToolResult("p1"), Reply("msg_b", 2, 50, 100, 20),
            Prompt("p2"), Reply("msg_c", 2, 30, 150, 5),
        ]);

        Assert.Equal(2, cycles.Count);
        Assert.Equal(new TokenUsage(4, 150, 100, 30), cycles[0].Usage);
        Assert.Equal(2, cycles[0].Requests);
        Assert.Equal(new TokenUsage(2, 30, 150, 5), cycles[1].Usage);
    }

    [Fact]
    public void RepeatedMessageCountsOnceAndSidechainNotAtAll()
    {
        var cycles = TranscriptCycles.Parse([
            Prompt("p1"), Reply("msg_a", 2, 100, 0, 10), Reply("msg_a", 2, 100, 0, 10),
            Reply("msg_s", 5, 500, 0, 50, sidechain: true),
        ]);

        Assert.Equal(new TokenUsage(2, 100, 0, 10), Assert.Single(cycles).Usage);
        Assert.Equal(1, cycles[0].Requests);
    }

    [Fact]
    public void GrowthIsTheContextDeltaAndChurnTheRestOfTheWrite()
    {
        var cycles = TranscriptCycles.Parse([
            Prompt("p1"), Reply("msg_a", 2, 1000, 0, 1),          // cold load: context 1002
            Prompt("p2"), Reply("msg_b", 2, 300, 1000, 1),        // +300, all of it growth
            Prompt("p3"), Reply("msg_c", 2, 1500, 0, 1),          // cache lapsed: 1502 rewritten, 200 of it new
            Prompt("p4"), Reply("msg_d", 2, 100, 400, 1),         // compacted to 502: no growth, all churn
        ]);

        Assert.Equal(new long[] { 1002, 1302, 1502, 502 }, cycles.Select(c => c.Context));
        Assert.Equal(new long[] { 1002, 300, 200, 0 }, cycles.Select(c => c.Growth));
        Assert.Equal(new long[] { 0, 0, 1300, 100 }, cycles.Select(c => c.Churn));
    }

    [Fact]
    public void ACycleWithNoReplyEndsAtZeroLikeTheScript()
    {
        var cycles = TranscriptCycles.Parse([
            Prompt("p1"), Reply("msg_a", 2, 1000, 0, 1),
            Prompt("p2"),
            Prompt("p3"), Reply("msg_b", 2, 10, 1000, 1),
        ]);

        Assert.Equal(new long[] { 1002, 0, 1012 }, cycles.Select(c => c.Context));
        Assert.Equal(new long[] { 1002, 0, 1012 }, cycles.Select(c => c.Growth));
    }

    [Fact]
    public void UsageBeforeTheFirstPromptAndBrokenLinesAreSkipped()
    {
        var cycles = TranscriptCycles.Parse([
            Reply("msg_0", 2, 900, 0, 9),
            Prompt("p1"), Reply("msg_0", 2, 900, 0, 9), Reply("msg_a", 2, 100, 0, 10),
            """{"type":"assistant","message":{"id":"msg_b","usage":{"output_tokens":""",
        ]);

        Assert.Equal(new TokenUsage(2, 100, 0, 10), Assert.Single(cycles).Usage);
    }
}
