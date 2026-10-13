using System.Globalization;

namespace TokenChat.Core.Analytics;

/// <summary>How a set of cycles spent. Weighted per cycle is the headline; the shares say where it went.</summary>
/// <param name="OutputShare">output's part of the weighted spend: the work itself, against reading and re-caching</param>
/// <param name="ChurnShare">cache writes of context already there (a lapsed or rewritten window)</param>
/// <param name="OverRate">cycles over every CLAUDE.md budget class</param>
public sealed record Efficiency(int Cycles, double PerCycle, double OutputShare, double ChurnShare, double OverRate,
    long MedianContext, double UsdPerCycle)
{
    public static Efficiency Of(IReadOnlyCollection<CycleRow> rows)
    {
        if (rows.Count == 0) return new(0, 0, 0, 0, 0, 0, 0);
        var w = rows.Sum(r => UsageOverview.Weigh(r.Usage));
        var priced = rows.Where(r => r.CostUsd is not null).ToList();
        var contexts = rows.Select(r => r.Cycle!.Context).OrderBy(c => c).ToList();
        return new(rows.Count, w / rows.Count,
            w > 0 ? rows.Sum(r => r.Usage.Output * 5.0) / w : 0,
            w > 0 ? rows.Sum(r => r.Cycle!.Churn * 2.0) / w : 0,
            (double)rows.Count(r => r.Class == BudgetClass.Over) / rows.Count,
            contexts[contexts.Count / 2],
            priced.Count > 0 ? priced.Sum(r => r.CostUsd!.Value) / priced.Count : 0);
    }
}

public sealed record WeekEfficiency(DateOnly Monday, Efficiency Terminal, Efficiency TokenChat);

/// <param name="Adopted">the first TokenChat cycle's day; null if there is none yet</param>
/// <param name="Before">every cycle before that day</param>
public sealed record Progress(DateOnly? Adopted, Efficiency Before, Efficiency SinceTokenChat, Efficiency SinceTerminal,
    IReadOnlyList<WeekEfficiency> Weeks);

/// <summary>Whether the tooling made the chat cheaper: always over the whole history, whatever the page's range,
/// split at the first TokenChat cycle and by week. Cycles that sent nothing are left out; they cost nothing and
/// would flatter every average.</summary>
public static class ProgressReport
{
    public static Progress Build(IEnumerable<SessionSummary> sessions)
    {
        var rows = sessions.SelectMany(s => s.Rows.Select(r => (s.TokenChat, Row: r)))
            .Where(x => x.Row.Cycle?.Started is not null && x.Row.Usage != default).ToList();
        DateOnly Day(CycleRow r) => DateOnly.FromDateTime(r.Cycle!.Started!.Value.LocalDateTime.Date);
        var adopted = rows.Where(x => x.TokenChat).Select(x => Day(x.Row)).DefaultIfEmpty().Min();
        DateOnly? since = rows.Any(x => x.TokenChat) ? adopted : null;

        List<CycleRow> Pick(Func<(bool TokenChat, CycleRow Row), bool> f) => rows.Where(f).Select(x => x.Row).ToList();
        var weeks = rows.GroupBy(x => Monday(Day(x.Row))).OrderBy(g => g.Key)
            .Select(g => new WeekEfficiency(g.Key,
                Efficiency.Of(g.Where(x => !x.TokenChat).Select(x => x.Row).ToList()),
                Efficiency.Of(g.Where(x => x.TokenChat).Select(x => x.Row).ToList())))
            .ToList();
        return new Progress(since,
            Efficiency.Of(Pick(x => since is null || Day(x.Row) < since)),
            Efficiency.Of(Pick(x => since is not null && x.TokenChat && Day(x.Row) >= since)),
            Efficiency.Of(Pick(x => since is not null && !x.TokenChat && Day(x.Row) >= since)),
            weeks);
    }

    static DateOnly Monday(DateOnly d) => d.AddDays(-(((int)d.DayOfWeek + 6) % 7));

    /// <summary>"-26%": the change from before to after, as a share of before.</summary>
    public static string Change(double before, double after) =>
        before == 0 ? "" : ((after - before) / before).ToString("+0%;-0%;0%", CultureInfo.InvariantCulture);
}
