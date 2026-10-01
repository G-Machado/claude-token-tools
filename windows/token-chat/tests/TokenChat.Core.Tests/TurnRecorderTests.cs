using TokenChat.Core;
using TokenChat.Core.Analytics;
using TokenChat.Core.Protocol;

namespace TokenChat.Core.Tests;

/// Fixtures/<name>.transcript.jsonl is the transcript the CLI wrote for the session recorded in <name>.jsonl, cut to
/// the fields TranscriptCycles reads (type, promptId, isSidechain, message id and usage): the repo is public.
public class TurnRecorderTests
{
    static IReadOnlyList<TurnRecord> Replay(string fixture)
    {
        var recorder = new TurnRecorder();
        foreach (var line in Fixture.Lines(fixture)) recorder.Apply(EventParser.Parse(line));
        return recorder.Turns;
    }

    static TokenUsage Sum(IEnumerable<TokenUsage> usages) => usages.Aggregate(default(TokenUsage), (a, b) => a + b);

    [Theory, MemberData(nameof(Fixture.All), MemberType = typeof(Fixture))]
    public void OneRecordPerResultAndDeltasSumToTheProcessTotal(string fixture)
    {
        var results = Fixture.Lines(fixture).Select(EventParser.Parse).OfType<ResultEvent>().ToList();
        var turns = Replay(fixture);

        Assert.Equal(results.Count, turns.Count);
        Assert.Equal(results[^1].TotalCostUsd, turns.Sum(t => t.CostUsd), 9);
        Assert.Equal(Sum(results[^1].ModelUsage.Values.Select(m => m.Tokens)), Sum(turns.Select(t => t.ModelTokens)));
    }

    /// The stream and the transcript must count the same main-chain requests with the same usage.
    [Theory, MemberData(nameof(Fixture.All), MemberType = typeof(Fixture))]
    public void MainChainAgreesWithTheTranscriptCycle(string fixture)
    {
        var cycles = TranscriptCycles.Parse(Fixture.Lines(fixture + ".transcript"));
        var matches = TurnRecorder.Match(Replay(fixture), cycles).Where(m => m.Turn.MainMessages.Count > 0).ToList();

        Assert.NotEmpty(matches);
        Assert.All(matches, m =>
        {
            Assert.True(m.SameRequests, $"turn {m.Turn.Index}: cycle {m.Cycle?.Index}");
            Assert.True(m.Diff == default, $"turn {m.Turn.Index} {m.Turn.Subtype}: diff {m.Diff}, stream {m.Turn.Main}");
        });
    }

    /// /compact: no request on the stream, num_turns 0, yet the summarising request is billed.
    [Fact]
    public void SideRequestShowsOnlyInModelUsageAndCost()
    {
        var turn = Replay("full")[3];

        Assert.Equal(0, turn.NumTurns);
        Assert.Equal(0, turn.Requests);
        Assert.Equal(default, turn.Ledger);
        Assert.Equal(new TokenUsage(2041, 0, 30857, 2241), turn.ModelTokens);
        Assert.Equal(0.0591554, turn.CostUsd, 7);
    }

    /// The reverse: an interrupted request is on the stream and in the transcript, and never in the CLI's cost.
    [Fact]
    public void InterruptedRequestIsMissingFromCost()
    {
        var turn = Replay("full")[2];

        Assert.Equal("error_during_execution", turn.Subtype);
        Assert.Equal(new TokenUsage(2, 149, 30754, 3), turn.Main);
        Assert.Equal(default, turn.ModelTokens);
        Assert.Equal(0, turn.CostUsd);
    }
}
