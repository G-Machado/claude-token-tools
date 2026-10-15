namespace TokenChat.Core.Analytics;

/// <summary>List price in $ per million tokens. CacheWrite is the 1-hour rate: the main chain's, the only chain a
/// cycle counts (subagents write at 5 minutes).</summary>
public sealed record Prices(double Input, double CacheWrite, double CacheRead, double Output)
{
    public double Cost(TokenUsage u) =>
        (u.Input * Input + u.CacheWrite * CacheWrite + u.CacheRead * CacheRead + u.Output * Output) / 1e6;

    // Solved from the CLI's own modelUsage costUSD (costBasis "list") in the test fixtures, which PricesTests re-check
    // against every result. ~/.claude/pricing-reference.md (Opus 5: $5/$25, read 0.1x) does not match Opus 5.5.
    static readonly Dictionary<string, Prices> Known = new()
    {
        ["claude-opus-5-5"] = new(4, 8, 0.2, 20),
        // Looked up, not measured: pricing-reference.md's $5/$25 list rate, 1-hour write 2x, read 0.1x.
        ["claude-opus-5"] = new(5, 10, 0.5, 25),
    };

    public static Prices? For(string? model) => model is not null && Known.TryGetValue(model, out var p) ? p : null;
}

/// <summary>The smallest CLAUDE.md budget class a cycle fits. scene is an opt-in merge tier, never assigned.</summary>
public enum BudgetClass { Recon, Change, Feature, Over }

public static class Budget
{
    // output, growth: the table in CLAUDE.md and token-cycles.sh resolve_budget / resolve_growth.
    static readonly (BudgetClass Class, long Output, long Growth)[] Tiers =
        [(BudgetClass.Recon, 5000, 8000), (BudgetClass.Change, 10000, 15000), (BudgetClass.Feature, 20000, 25000)];

    /// <summary>Cycle 1's growth is the cold load, which no prompt chose, so it is scored on output alone.</summary>
    public static BudgetClass Of(CycleStats c)
    {
        foreach (var t in Tiers)
            if (c.Usage.Output <= t.Output && (c.Index == 1 || c.Growth <= t.Growth)) return t.Class;
        return BudgetClass.Over;
    }
}
