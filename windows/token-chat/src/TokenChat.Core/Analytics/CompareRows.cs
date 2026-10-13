namespace TokenChat.Core.Analytics;

/// <summary>One line of the side-by-side view: cycle n of each side, or a side request on one side only.</summary>
public sealed record CompareRow(string Label, CycleRow? A, CycleRow? B);

public sealed record CycleTotals(int Cycles, TokenUsage Usage, long Growth, double? CostUsd, CostSource Source, int Over)
{
    public static CycleTotals Of(IReadOnlyList<CycleRow> rows)
    {
        var usage = rows.Aggregate(default(TokenUsage), (sum, r) => sum + r.Usage);
        var priced = rows.Where(r => r.CostUsd is not null).ToList();
        var sources = rows.Select(r => r.Source).Distinct().ToList();
        var source = sources.Count == 1 ? sources[0] : priced.Count == 0 ? CostSource.None : CostSource.Mixed;
        return new CycleTotals(rows.Count(r => r.Cycle is not null), usage, rows.Sum(r => r.Cycle?.Growth ?? 0),
            priced.Count == 0 ? null : priced.Sum(r => r.CostUsd!.Value), source, rows.Count(r => r.Class == BudgetClass.Over));
    }
}

public static class CompareRows
{
    /// <summary>Aligned by cycle number, the same prompt run on both sides; a side request (/compact) keeps
    /// its place after the cycle it followed.</summary>
    public static IReadOnlyList<CompareRow> Align(IReadOnlyList<CycleRow> a, IReadOnlyList<CycleRow> b)
    {
        var left = Keyed(a);
        var right = Keyed(b);
        return left.Keys.Union(right.Keys).Order()
            .Select(k => new CompareRow(k.Side == 0 ? k.Cycle.ToString() : "side",
                left.GetValueOrDefault(k), right.GetValueOrDefault(k)))
            .ToList();
    }

    static Dictionary<(int Cycle, int Side), CycleRow> Keyed(IReadOnlyList<CycleRow> rows)
    {
        var keyed = new Dictionary<(int, int), CycleRow>();
        int cycle = 0, side = 0;
        foreach (var r in rows)
        {
            if (r.Cycle is { } c) { cycle = c.Index; side = 0; }
            else side++;
            keyed[(cycle, side)] = r;
        }
        return keyed;
    }
}
