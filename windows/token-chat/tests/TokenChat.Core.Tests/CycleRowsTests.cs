using TokenChat.Core;
using TokenChat.Core.Analytics;
using TokenChat.Core.Protocol;

namespace TokenChat.Core.Tests;

public class CycleRowsTests
{
    static IReadOnlyList<TurnRecord> Turns(string fixture)
    {
        var recorder = new TurnRecorder();
        foreach (var line in Fixture.Lines(fixture)) recorder.Apply(EventParser.Parse(line));
        return recorder.Turns;
    }

    static IReadOnlyList<CycleStats> Cycles(string fixture) => TranscriptCycles.Parse(Fixture.Lines(fixture + ".transcript"));

    /// The CLI's own cost is the oracle for the price table: every model of every result, to the nano-dollar.
    [Theory, MemberData(nameof(Fixture.All), MemberType = typeof(Fixture))]
    public void PricesReproduceTheCliCost(string fixture)
    {
        var results = Fixture.Lines(fixture).Select(EventParser.Parse).OfType<ResultEvent>().ToList();
        Assert.All(results.SelectMany(r => r.ModelUsage), kv =>
            Assert.Equal(kv.Value.CostUsd, Prices.For(kv.Key)!.Cost(kv.Value.Tokens), 9));
        Assert.Contains(results, r => r.ModelUsage.Count > 0);
    }

    [Fact]
    public void ClassIsTheSmallestTierThatFitsAndCycleOneIgnoresGrowth()
    {
        static CycleStats C(int index, long output, long growth) =>
            new(index, "p", new TokenUsage(0, 0, 0, output), 0, growth, 0, 0, [], null);

        Assert.Equal(BudgetClass.Recon, Budget.Of(C(1, 5000, 60000)));
        Assert.Equal(BudgetClass.Change, Budget.Of(C(2, 5000, 8001)));
        Assert.Equal(BudgetClass.Feature, Budget.Of(C(2, 10001, 0)));
        Assert.Equal(BudgetClass.Over, Budget.Of(C(2, 0, 25001)));
    }

    /// full: ok, a Write, an interrupted count, /compact (side request, no cycle), the continued-session cycle, ok.
    [Fact]
    public void LiveRowsAddInterruptedRequestsAndKeepSideRequestsAsTheirOwnRow()
    {
        var turns = Turns("full");
        var rows = CycleRows.Live(Cycles("full"), turns, "claude-opus-5-5");

        Assert.Equal([1, 2, 3, 0, 4, 5], rows.Select(r => r.Cycle?.Index ?? 0));
        Assert.Equal([CostSource.Cli, CostSource.Cli, CostSource.Mixed, CostSource.Cli, CostSource.Priced, CostSource.Cli],
            rows.Select(r => r.Source));
        Assert.Equal(0.0074108, rows[2].CostUsd!.Value, 9); // (2·4 + 149·8 + 30754·0.2 + 3·20) / 1e6
        Assert.Equal(0.0591554, rows[3].CostUsd!.Value, 7);
        Assert.Equal(turns.Sum(t => t.CostUsd) + 0.0074108, rows.Sum(r => r.CostUsd!.Value), 9);
    }

    [Theory, MemberData(nameof(Fixture.All), MemberType = typeof(Fixture))]
    public void PricedRowsEqualTheCliCostWhenNothingWasInterrupted(string fixture)
    {
        var turns = Turns(fixture);
        if (turns.Any(t => t.Subtype == "error_during_execution" || (t.MainMessages.Count == 0 && t.CostUsd != 0))) return;

        var rows = CycleRows.Priced(Cycles(fixture), "claude-opus-5-5");

        Assert.All(rows, r => Assert.Equal(CostSource.Priced, r.Source));
        Assert.Equal(turns.Sum(t => t.CostUsd), rows.Sum(r => r.CostUsd!.Value), 9);
    }
}
