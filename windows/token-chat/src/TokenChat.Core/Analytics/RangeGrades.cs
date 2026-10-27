namespace TokenChat.Core.Analytics;

/// <summary>The four OVERALL grades over any range, from the transcripts: a port of measure_overall in
/// token-sessions.sh (~:543), which grades only the last 7 days off token-history.csv. Same formulas, three
/// differences, all on the side of the transcript: spend is the real usage (actual cache reads, not context x
/// reads/cycle), a breach is judged against one fixed budget (the transcript does not know the class a prompt was
/// given), and renewal pokes and parks are not told apart from typed cycles.</summary>
public static class RangeGrades
{
    /// <summary>Output and growth past the feature tier: what the Stop hook flags on this machine (every 7d row with
    /// output over 20k carries "o", and none at or under it, 2026-10-13).</summary>
    const long OutputBudget = 40000, GrowthBudget = 50000; // doubled 2026-10-26 with token-cycles.sh

    /// <summary>The raw figures for cycles that started in [from, until); from null = since the beginning.</summary>
    public sealed record Figures(double Held, double Short, double Churn, double Control, int Cycles);

    public static Figures Measure(IEnumerable<SessionSummary> sessions, DateTimeOffset? from, DateTimeOffset until,
        DateTimeOffset now, double cutK)
    {
        double spend = 0, held = 0, shorts = 0, churn = 0;
        int n = 0, bad = 0;
        foreach (var s in sessions)
        {
            var cycles = s.Rows.Where(r => r.Cycle is not null).Select(r => (r.Cycle!, r.Usage)).ToList();
            var rows = cycles.Where(c => c.Item1.Started is { } at && at < until && (from is null || at >= from)).ToList();
            if (rows.Count == 0) continue;
            double w = 0;
            foreach (var (c, u) in rows)
            {
                var rw = UsageOverview.Weigh(u);
                w += rw;
                n++;
                if (c.Context > cutK * 1000) held += rw;
                // Cycle 1 rewrites nothing: its write is the cold load, the floor.
                if (c.Index > 1) churn += c.Churn * 2;
                if (u.Output > OutputBudget || (c.Index > 1 && c.Growth > GrowthBudget)) bad++;
            }
            spend += w;
            // Short: stopped at two cycles, and only once its cache has lapsed, or every session reads short for
            // its first two prompts.
            var last = cycles.Max(c => c.Item1.Started);
            if (cycles.Count <= 2 && last is { } l && now - l > TimeSpan.FromHours(1)) shorts += w;
        }
        return spend <= 0 ? new(0, 0, 0, 0, n)
            : new(held * 100 / spend, shorts * 100 / spend, churn * 100 / spend, n > 0 ? (double)bad / n : 0, n);
    }

    /// <summary>The grades for a range, with the equal-length period before as the ring (none under All, and none
    /// when that period has under 5 cycles: a swing measured off two cycles says nothing).</summary>
    public static IReadOnlyList<Grade> Build(IReadOnlyList<SessionSummary> sessions, OverviewRange range,
        DateTimeOffset now, double cutK)
    {
        var since = UsageOverview.Since(range, now);
        var cur = Measure(sessions, since, now, now, cutK);
        if (cur.Cycles == 0) return [];
        var prev = since is { } s ? Measure(sessions, s - (now - s), s, now, cutK) : null;
        if (prev is { Cycles: < 5 }) prev = null;
        Grade G(string axis, double v, double? was, string value) =>
            new(axis, Grade.LetterOf(axis, v), was is { } p ? Grade.LetterOf(axis, p) : null, value,
                GradeAdvice.Meaning(axis, cutK), v, was);
        return
        [
            G("held", cur.Held, prev?.Held, $"{cur.Held:0.#}%"),
            G("short", cur.Short, prev?.Short, $"{cur.Short:0.#}%"),
            G("churn", cur.Churn, prev?.Churn, $"{cur.Churn:0.#}%"),
            G("control", cur.Control, prev?.Control, cur.Control.ToString("0.00", System.Globalization.CultureInfo.InvariantCulture)),
        ];
    }
}
