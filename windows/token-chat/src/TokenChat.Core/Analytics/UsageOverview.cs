using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using TokenChat.Core.Protocol;

namespace TokenChat.Core.Analytics;

public enum OverviewRange { Week, Month, All }

/// <summary>One transcript, read once per size and write time.</summary>
/// <param name="Entrypoint">"cli" is terminal claude; "sdk-cli" is TokenChat, or a headless -p run</param>
/// <param name="Commands">the window-management commands typed in it, with when</param>
public sealed record SessionSummary(string Path, string SessionId, string? Cwd, string? Entrypoint, IReadOnlyList<CycleRow> Rows,
    IReadOnlyList<(string Name, DateTimeOffset At)> Commands)
{
    public bool TokenChat => Entrypoint == "sdk-cli";
    public string Project => Cwd is { } c && System.IO.Path.GetFileName(c.TrimEnd('\\', '/')) is { Length: > 0 } n ? n
        : System.IO.Path.GetFileName(System.IO.Path.GetDirectoryName(Path)) ?? "";
}

/// <summary>A session's share of the range: only its cycles that started inside it.</summary>
public sealed record SessionTotal(SessionSummary Session, int Cycles, TokenUsage Usage, double CostUsd, double Weighted,
    DateTimeOffset? Last);

/// <param name="Classes">cycles per budget class, indexed by <see cref="BudgetClass"/></param>
/// <param name="Churn">weighted cost of cache writes that rewrote context already there</param>
public sealed record DayTotal(DateOnly Day, TokenUsage Usage, double Weighted, double CostUsd, int[] Classes, double Churn);

public sealed record ProjectTotal(string Project, double Weighted, double CostUsd, int Sessions);

/// <param name="Unpriced">cycles on a model with no measured price: in the weighted figures, not in $</param>
/// <param name="TokenChatShare">share of the weighted spend that ran through sdk-cli</param>
/// <param name="HitRate">cache read over everything sent as prompt</param>
/// <param name="Contexts">each cycle's window at its end, for the context histogram</param>
/// <param name="Days">every day from the range's start (or the first cycle) to today, empty days included</param>
/// <param name="Commands">count per command in <see cref="UsageOverview.Tracked"/>, all of them present</param>
/// <param name="Hours">weighted spend by local start time, [weekday * 24 + hour] with Monday as 0</param>
public sealed record Overview(OverviewRange Range, DateTimeOffset? Since, int Sessions, int Cycles, TokenUsage Usage,
    double CostUsd, int Unpriced, double Weighted, double TokenChatShare, double HitRate, double MedianCycleUsd,
    IReadOnlyDictionary<BudgetClass, int> Classes, IReadOnlyList<SessionTotal> Top, IReadOnlyList<DayTotal> Days,
    IReadOnlyList<ProjectTotal> Projects, IReadOnlyList<long> Contexts, IReadOnlyDictionary<string, int> Commands, double[] Hours);

/// <summary>The analytics page's figures, from every transcript on disk. A cycle belongs to the range its prompt
/// started in; a cycle with no timestamp counts only under All.</summary>
public static partial class UsageOverview
{
    public static readonly string[] Tracked = ["park", "handoff", "compact", "clear", "unpark"];

    static readonly ConcurrentDictionary<string, (long Bytes, DateTime Write, SessionSummary Summary)> Cache = new();

    /// <summary>The CLAUDE.md weights against an uncached input token: input 1, cache write 2, read 0.05, output 5.</summary>
    public static double Weigh(TokenUsage u) => u.Input + u.CacheWrite * 2 + u.CacheRead * 0.05 + u.Output * 5;

    public static DateTimeOffset? Since(OverviewRange range, DateTimeOffset now) => range switch
    {
        OverviewRange.Week => now.AddDays(-7),
        OverviewRange.Month => now.AddDays(-30),
        _ => null,
    };

    public static List<SessionSummary> Load(string root) =>
        TranscriptIndex.All(root).AsParallel().Select(Load).OfType<SessionSummary>().ToList();

    public static SessionSummary? Load(TranscriptFile f)
    {
        if (Cache.TryGetValue(f.Path, out var hit) && hit.Bytes == f.Bytes && hit.Write == f.LastWriteUtc) return hit.Summary;
        try
        {
            // The CLI may be appending to it right now.
            using var stream = new FileStream(f.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream);
            var lines = new List<string>();
            while (reader.ReadLine() is { } line) lines.Add(line);
            var summary = Parse(f.Path, f.SessionId, lines);
            Cache[f.Path] = (f.Bytes, f.LastWriteUtc, summary);
            return summary;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }

    public static SessionSummary Parse(string path, string sessionId, IReadOnlyList<string> lines)
    {
        string? cwd = null, entrypoint = null;
        var commands = new List<(string, DateTimeOffset)>();
        foreach (var line in lines)
        {
            if (Command().Match(line) is { Success: true } m && Stamp().Match(line) is { Success: true } t
                && DateTimeOffset.TryParse(t.Groups[1].Value, out var at))
                commands.Add((m.Groups[1].Value, at));
        }
        // Every user line carries both; the first one that parses is enough.
        foreach (var line in lines)
        {
            if (!line.Contains("\"entrypoint\"")) continue;
            try
            {
                var o = JsonNode.Parse(line);
                cwd = Json.Str(o?["cwd"]);
                entrypoint = Json.Str(o?["entrypoint"]);
                break;
            }
            catch (JsonException) { }
        }
        return new SessionSummary(path, sessionId, cwd, entrypoint, CycleRows.Priced(TranscriptCycles.Parse(lines)), commands);
    }

    [GeneratedRegex("<command-name>/(park|handoff|compact|clear|unpark)</command-name>")]
    private static partial Regex Command();

    [GeneratedRegex("\"timestamp\":\"([^\"]+)\"")]
    private static partial Regex Stamp();

    public static Overview Build(IEnumerable<SessionSummary> sessions, OverviewRange range, DateTimeOffset now, int top = 10)
    {
        var since = Since(range, now);
        bool Inside(CycleRow r) => r.Cycle is { } c && (since is null || c.Started is { } at && at >= since);

        var totals = new List<SessionTotal>();
        var classes = Enum.GetValues<BudgetClass>().ToDictionary(c => c, _ => 0);
        var days = new Dictionary<DateOnly, (TokenUsage Usage, double Weighted, double Cost, int[] Classes, double Churn)>();
        var commands = Tracked.ToDictionary(c => c, _ => 0);
        var hours = new double[7 * 24];
        var contexts = new List<long>();
        var cycleCosts = new List<double>();
        var unpriced = 0;
        double weighted = 0, viaSdk = 0;

        foreach (var s in sessions)
        {
            var rows = s.Rows.Where(Inside).ToList();
            if (rows.Count == 0) continue;
            TokenUsage usage = default;
            double cost = 0, w = 0;
            foreach (var r in rows)
            {
                var rw = Weigh(r.Usage);
                usage += r.Usage;
                w += rw;
                if (r.CostUsd is { } usd) { cost += usd; cycleCosts.Add(usd); }
                else if (r.Usage != default) unpriced++; // an interrupted cycle sent nothing: free, not unknown
                if (r.Class is { } k) classes[k]++;
                contexts.Add(r.Cycle!.Context);
                if (r.Cycle.Started is { } at)
                {
                    var local = at.ToLocalTime();
                    hours[((int)local.DayOfWeek + 6) % 7 * 24 + local.Hour] += rw;
                    var day = DateOnly.FromDateTime(local.Date);
                    var d = days.TryGetValue(day, out var had) ? had : (default, 0, 0, new int[4], 0);
                    if (r.Class is { } dk) d.Classes[(int)dk]++;
                    days[day] = (d.Usage + r.Usage, d.Weighted + rw, d.Cost + (r.CostUsd ?? 0), d.Classes, d.Churn + r.Cycle.Churn * 2);
                }
            }
            foreach (var (name, at) in s.Commands)
                if (since is null || at >= since) commands[name]++;
            weighted += w;
            if (s.TokenChat) viaSdk += w;
            totals.Add(new SessionTotal(s, rows.Count, usage, cost, w, rows.Max(r => r.Cycle!.Started)));
        }

        var sum = totals.Aggregate(default(TokenUsage), (a, t) => a + t.Usage);
        cycleCosts.Sort();
        // Empty days stay in, so a bar chart's gaps are real gaps.
        var today = DateOnly.FromDateTime(now.LocalDateTime.Date);
        var first = since is { } from ? DateOnly.FromDateTime(from.LocalDateTime.Date) : days.Count > 0 ? days.Keys.Min() : today;
        var calendar = new List<DayTotal>();
        for (var day = first; day <= today; day = day.AddDays(1))
            calendar.Add(days.TryGetValue(day, out var d)
                ? new DayTotal(day, d.Usage, d.Weighted, d.Cost, d.Classes, d.Churn)
                : new DayTotal(day, default, 0, 0, new int[4], 0));
        return new Overview(range, since, totals.Count, totals.Sum(t => t.Cycles), sum,
            totals.Sum(t => t.CostUsd), unpriced, weighted,
            weighted > 0 ? viaSdk / weighted : 0,
            sum.Prompt > 0 ? (double)sum.CacheRead / sum.Prompt : 0,
            cycleCosts.Count > 0 ? cycleCosts[cycleCosts.Count / 2] : 0,
            classes,
            totals.OrderByDescending(t => t.Weighted).Take(top).ToList(),
            calendar,
            totals.GroupBy(t => t.Session.Project)
                .Select(g => new ProjectTotal(g.Key, g.Sum(t => t.Weighted), g.Sum(t => t.CostUsd), g.Count()))
                .OrderByDescending(p => p.Weighted).ToList(),
            contexts, commands, hours);
    }
}
