using TokenChat.Core;
using TokenChat.Core.Protocol;

namespace TokenChat.Core.Tests;

public class UsageLedgerTests
{
    /// The CLI's own per-turn sum is the oracle: deduplicated messages must add up to it exactly.
    [Theory, MemberData(nameof(Fixture.All), MemberType = typeof(Fixture))]
    public void TurnSumsMatchEverySuccessfulResult(string fixture)
    {
        var ledger = new UsageLedger();
        var compared = 0;
        foreach (var e in Fixture.Lines(fixture).Select(EventParser.Parse))
        {
            ledger.Apply(e);
            if (e is ResultEvent { IsError: false } r)
            {
                Assert.Equal(r.Usage, ledger.Snapshot.LastTurn);
                if (r.Usage != default) compared++;
            }
        }
        Assert.True(compared > 0, "no non-empty result to compare against");
    }

    [Fact]
    public void RepeatedAssistantEventsCountOnceAndDeltaSetsFinalOutput()
    {
        var ledger = new UsageLedger();
        foreach (var line in new[]
        {
            """{"type":"stream_event","event":{"type":"message_start","message":{"id":"m1","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":7}}},"parent_tool_use_id":null}""",
            """{"type":"assistant","message":{"id":"m1","content":[],"usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":7}},"parent_tool_use_id":null}""",
            """{"type":"assistant","message":{"id":"m1","content":[],"usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":7}},"parent_tool_use_id":null}""",
            """{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":196}},"parent_tool_use_id":null}""",
        })
            ledger.Apply(EventParser.Parse(line));

        Assert.Equal(new TokenUsage(2, 100, 1000, 196), ledger.Snapshot.Session);
        Assert.Equal(1102, ledger.Snapshot.Context);
        Assert.Equal(1, ledger.Snapshot.Requests);
    }

    [Fact]
    public void SubagentMessagesCountButDoNotMoveContext()
    {
        var ledger = new UsageLedger();
        ledger.Apply(EventParser.Parse("""{"type":"assistant","message":{"id":"main","content":[],"usage":{"input_tokens":1,"cache_read_input_tokens":50000,"output_tokens":10}},"parent_tool_use_id":null}"""));
        ledger.Apply(EventParser.Parse("""{"type":"assistant","message":{"id":"sub","content":[],"usage":{"input_tokens":1,"cache_creation_input_tokens":9000,"output_tokens":5}},"parent_tool_use_id":"toolu_x"}"""));

        ledger.Apply(EventParser.Parse("""{"type":"assistant","message":{"id":"main2","content":[],"usage":{"input_tokens":3,"cache_read_input_tokens":50100,"output_tokens":4}},"parent_tool_use_id":null}"""));

        Assert.Equal(50103, ledger.Snapshot.Context);
        Assert.Equal(50001, ledger.Snapshot.Floor);
        Assert.Equal(new TokenUsage(5, 9000, 100100, 19), ledger.Snapshot.Session);
        Assert.Equal(2, ledger.Snapshot.Requests);
    }

    [Fact]
    public void CompactResetsContextToPostTokens()
    {
        var ledger = new UsageLedger();
        foreach (var e in Fixture.Lines("full").Select(EventParser.Parse))
        {
            ledger.Apply(e);
            if (e is CompactBoundaryEvent)
            {
                Assert.Equal(2475, ledger.Snapshot.Context);
                return;
            }
        }
        Assert.Fail("no compact_boundary in full fixture");
    }
}
