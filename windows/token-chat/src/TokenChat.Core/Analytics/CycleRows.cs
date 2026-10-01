namespace TokenChat.Core.Analytics;

/// <summary>Where a row's $ comes from. Cli: Δtotal_cost_usd. Priced: usage x <see cref="Prices"/>.
/// Mixed: the CLI's cost plus interrupted requests it never billed, priced. None: unknown model.</summary>
public enum CostSource { None, Cli, Priced, Mixed }

/// <summary>One row of the Analytics tab: a transcript cycle, or a turn with no cycle of its own (Cycle null: side
/// requests such as /compact, which the stream and the transcript never show).</summary>
public sealed record CycleRow(CycleStats? Cycle, TokenUsage Usage, double? CostUsd, CostSource Source, BudgetClass? Class);

public static class CycleRows
{
    /// <summary>A session read from its transcript alone: a terminal one, or TokenChat before this process.</summary>
    public static IReadOnlyList<CycleRow> Priced(IReadOnlyList<CycleStats> cycles, string? fallbackModel = null) =>
        cycles.Select(c => PricedRow(c, fallbackModel)).ToList();

    /// <summary>A live TokenChat session: cycles from its transcript, $ from this process's results. Cycles from
    /// before the process (a resumed session) are priced instead.</summary>
    public static IReadOnlyList<CycleRow> Live(IReadOnlyList<CycleStats> cycles, IReadOnlyList<TurnRecord> turns,
        string? fallbackModel = null)
    {
        var matches = TurnRecorder.Match(turns, cycles);
        var turnsOf = matches.Where(m => m.Cycle is not null).ToLookup(m => m.Cycle!, m => m.Turn);
        var rows = new List<CycleRow>();
        var next = 0; // cycles before this index are emitted

        void EmitThrough(int index)
        {
            for (; next < cycles.Count && cycles[next].Index <= index; next++)
            {
                var c = cycles[next];
                var mine = turnsOf[c].ToList();
                rows.Add(mine.Count == 0 ? PricedRow(c, fallbackModel) : LiveRow(c, mine, fallbackModel));
            }
        }

        foreach (var m in matches)
        {
            if (m.Cycle is not null) EmitThrough(m.Cycle.Index);
            else if (m.Turn.CostUsd != 0 || m.Turn.ModelTokens != default)
                rows.Add(new CycleRow(null, m.Turn.ModelTokens, m.Turn.CostUsd, CostSource.Cli, null));
        }
        EmitThrough(int.MaxValue);
        return rows;
    }

    static CycleRow PricedRow(CycleStats c, string? fallbackModel)
    {
        var cost = Prices.For(c.Model ?? fallbackModel)?.Cost(c.Usage);
        return new CycleRow(c, c.Usage, cost, cost is null ? CostSource.None : CostSource.Priced, Budget.Of(c));
    }

    static CycleRow LiveRow(CycleStats c, List<TurnRecord> turns, string? fallbackModel)
    {
        var prices = Prices.For(c.Model ?? fallbackModel);
        double cost = 0;
        var source = CostSource.Cli;
        foreach (var t in turns)
        {
            cost += t.CostUsd;
            var unbilled = Unbilled(t);
            if (unbilled == default) continue;
            if (prices is null) return new CycleRow(c, c.Usage, null, CostSource.None, Budget.Of(c));
            cost += prices.Cost(unbilled);
            source = CostSource.Mixed;
        }
        return new CycleRow(c, c.Usage, cost, source, Budget.Of(c));
    }

    /// <summary>An interrupted request is on the stream but never in the CLI's cost (TurnRecorderTests): what the
    /// stream saw beyond what was billed, field by field.</summary>
    static TokenUsage Unbilled(TurnRecord t)
    {
        if (t.Subtype != "error_during_execution") return default;
        var (seen, billed) = (t.Ledger, t.ModelTokens);
        return new(Math.Max(0, seen.Input - billed.Input), Math.Max(0, seen.CacheWrite - billed.CacheWrite),
            Math.Max(0, seen.CacheRead - billed.CacheRead), Math.Max(0, seen.Output - billed.Output));
    }
}
