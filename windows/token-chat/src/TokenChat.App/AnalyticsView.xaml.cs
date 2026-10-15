using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using TokenChat.Core;
using TokenChat.Core.Analytics;

namespace TokenChat.App;

public sealed record Tile(string Label, string Value, string Note);

public sealed record ProgressRow(string Metric, string Tip, string Before, string Chat, string ChatChange, Brush ChatBrush,
    string Term, string TermChange, Brush TermBrush);

public sealed record GradeCell(string Axis, string Letter, string Was, string Value, string Meaning, Brush Brush);

public partial class AnalyticsView : UserControl
{
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
    static readonly string Root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "projects");

    List<SessionSummary> _sessions = [];
    Progress? _progress;
    int _version;

    public AnalyticsView()
    {
        InitializeComponent();
        // shown from the sidebar row: transcripts and the feed may have moved since the last showing
        IsVisibleChanged += async (_, e) => { if ((bool)e.NewValue) await Reload(); };
    }

    OverviewRange Range => Month.IsChecked == true ? OverviewRange.Month : All.IsChecked == true ? OverviewRange.All : OverviewRange.Week;

    // Checked fires for the XAML default inside InitializeComponent, before the parts below it exist.
    void OnRange(object sender, RoutedEventArgs e) { if (Tiles is not null && HourMap is not null) Render(); }

    async Task Reload()
    {
        var version = ++_version;
        var watch = Stopwatch.StartNew();
        // Unchanged transcripts come from the cache, so a second showing costs the directory walk.
        var sessions = await Task.Run(() => UsageOverview.Load(Root));
        if (version != _version) return;
        _sessions = sessions;
        _progress = ProgressReport.Build(sessions);
        Status.Text = $"{sessions.Count} transcripts read in {watch.Elapsed.TotalSeconds:0.0}s · terminal and TokenChat alike";
        Render();
    }

    void Render()
    {
        var o = UsageOverview.Build(_sessions, Range, DateTimeOffset.Now);
        Tiles.ItemsSource = TilesOf(o);

        // The feed's cut bar when there is one; 242k is where it sat when this was written.
        var cutK = SessionTab.Feed.Value.Snapshot?.Overall?["cut_k"] is System.Text.Json.Nodes.JsonValue c
            && c.TryGetValue<double>(out var k) && k > 0 ? k : 242;
        var grades = RangeGrades.Build(_sessions, Range, DateTimeOffset.Now, cutK);
        GradesLabel.Text = Range switch
        {
            OverviewRange.Week => "grades � this 7 days; the ring is the 7 before",
            OverviewRange.Month => "grades � this 30 days; the ring is the 30 before",
            _ => "grades � everything on disk",
        };
        Grades.ItemsSource = grades.Select(g => new GradeCell(g.Axis, g.Letter, g.Previous is { } p ? $"was {p}" : "",
            g.Value, g.Meaning, GradeBrush(g.Letter))).ToList();
        Bands.Grades = grades;
        Bands.Visibility = grades.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        NoGrades.Visibility = grades.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        var advice = GradeAdvice.Suggest(grades);
        Suggestions.ItemsSource = advice;
        AllGood.Visibility = grades.Count > 0 && advice.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (_progress is { } progress) ShowProgress(progress);
        HourMap.Format = Tokens;
        HourMap.Values = o.Hours;
        Charts(o, Num(SessionTab.Feed.Value.Snapshot?.Overall?["cut_k"]) is > 0 and var cut ? cut * 1000 : 242_000);
    }

    void ShowProgress(Progress p)
    {
        ProgressTitle.Text = p.Adopted is { } on
            ? $"before and since TokenChat ({on:MMM d}) · {p.Before.Cycles} / {p.SinceTokenChat.Cycles} / {p.SinceTerminal.Cycles} cycles"
            : "no TokenChat cycles yet: everything counts as before";
        var (good, bad, flat) = ((Brush)FindResource("Green"), (Brush)FindResource("Red"), (Brush)FindResource("Faint"));
        string Pct(double v) => v.ToString("0%", Inv);
        // lowerIsBetter decides the colour; under 3% either way reads as no change
        ProgressRow Row(string metric, string tip, Func<Efficiency, double> pick, Func<double, string> show, bool lowerIsBetter = true)
        {
            var before = pick(p.Before);
            (string, Brush) Delta(Efficiency e)
            {
                if (e.Cycles == 0 || p.Before.Cycles == 0) return ("", flat);
                var after = pick(e);
                var change = before == 0 ? 0 : (after - before) / before;
                var brush = Math.Abs(change) < 0.03 ? flat : (change < 0) == lowerIsBetter ? good : bad;
                return (ProgressReport.Change(before, after), brush);
            }
            var (cc, cb) = Delta(p.SinceTokenChat);
            var (tc, tb) = Delta(p.SinceTerminal);
            string Val(Efficiency e) => e.Cycles == 0 ? "-" : show(pick(e));
            return new(metric, tip, Val(p.Before), Val(p.SinceTokenChat), cc, cb, Val(p.SinceTerminal), tc, tb);
        }
        ProgressRows.ItemsSource = new List<ProgressRow>
        {
            Row("weighted / cycle", "the CLAUDE.md weights: input 1, write 2, read 0.05, output 5", e => e.PerCycle, Tokens),
            Row("$ / cycle", "API-equivalent, priced cycles only", e => e.UsdPerCycle, Usd),
            Row("output share", "output's part of the weighted spend: the work, against reading and re-caching", e => e.OutputShare, Pct, lowerIsBetter: false),
            Row("re-cache share", "cache writes of context already there: lapsed or rewritten windows", e => e.ChurnShare, Pct),
            Row("over budget", "cycles past the feature class (20k output or 25k growth)", e => e.OverRate, Pct),
            Row("median window", "context at a cycle's end", e => e.MedianContext, Tokens),
        };

        string Week(DateOnly monday) => monday.ToString("MMM d", Inv);
        var (term, chat) = ((Brush)FindResource("Dim"), (Brush)FindResource("Blue"));
        Bar WeekBar(WeekEfficiency w, Func<Efficiency, double> pick, Func<double, string> show) =>
            new(Week(w.Monday), [new(pick(w.Terminal), term), new(pick(w.TokenChat), chat)],
                $"week of {Week(w.Monday)}: terminal {(w.Terminal.Cycles > 0 ? show(pick(w.Terminal)) : "-")} ({w.Terminal.Cycles} cycles)" +
                $" · TokenChat {(w.TokenChat.Cycles > 0 ? show(pick(w.TokenChat)) : "-")} ({w.TokenChat.Cycles} cycles)");
        WeekCostChart.Format = Tokens;
        WeekCostChart.Bars = p.Weeks.Select(w => WeekBar(w, e => e.PerCycle, Tokens)).ToList();
        WeekOverChart.Format = Pct;
        WeekOverChart.Bars = p.Weeks.Select(w => WeekBar(w, e => e.OverRate, Pct)).ToList();
        WeekChurnChart.Format = Pct;
        WeekChurnChart.Bars = p.Weeks.Select(w => WeekBar(w, e => e.ChurnShare, Pct)).ToList();
        var at = p.Adopted is { } a ? p.Weeks.ToList().FindIndex(w => w.Monday.AddDays(7) > a) : -1;
        foreach (var chart in new[] { WeekCostChart, WeekOverChart, WeekChurnChart })
        {
            chart.Marker = at >= 0 ? at : null;
            chart.MarkerLabel = at >= 0 ? "TokenChat" : null;
        }
    }

    void Charts(Overview o, double cut)
    {
        Brush B(string key) => (Brush)FindResource(key);
        var (output, write, read, input) = (B("Blue"), B("Orange"), B("Green"), B("Faint"));
        var classBrushes = new[] { B("Green"), B("Blue"), B("Yellow"), B("Red") };
        string Day(DateOnly d) => o.Days.Count <= 31 ? d.Day.ToString(Inv) : d.ToString("MMM d", Inv);

        DailyChart.Format = Tokens;
        DailyChart.Bars = o.Days.Select(d => new Bar(Day(d.Day),
        [
            new(d.Usage.Input, input), new(d.Usage.CacheRead * 0.05, read), new(d.Usage.CacheWrite * 2.0, write),
            new(d.Usage.Output * 5.0, output),
        ], $"{d.Day:ddd MMM d}: {Tokens(d.Weighted)} weighted, {Usd(d.CostUsd)}\n" +
           $"output {Tokens(d.Usage.Output * 5.0)} · write {Tokens(d.Usage.CacheWrite * 2.0)} · read {Tokens(d.Usage.CacheRead * 0.05)}")).ToList();

        ClassChart.Bars = o.Days.Select(d => new Bar(Day(d.Day),
            d.Classes.Select((n, i) => new Segment(n, classBrushes[i])).ToList(),
            $"{d.Day:ddd MMM d}: recon {d.Classes[0]} · change {d.Classes[1]} · feature {d.Classes[2]} · over {d.Classes[3]}")).ToList();

        // 20k buckets out to the larger of the biggest window and two past the cut bar; the last holds the rest
        const double step = 20_000;
        var buckets = (int)Math.Ceiling(Math.Min(Math.Max(o.Contexts.DefaultIfEmpty(0).Max(), cut + 2 * step), 400_000) / step);
        var counts = new int[buckets];
        foreach (var c in o.Contexts) counts[Math.Min(buckets - 1, (int)(c / step))]++;
        ContextChart.Marker = cut / step;
        ContextChart.MarkerLabel = $"cut {cut / 1000:0}k";
        ContextChart.Bars = counts.Select((n, i) => new Bar(i % 5 == 0 ? $"{i * step / 1000:0}k" : "", [new(n, n == 0 ? input : i * step >= cut ? B("Red") : output)],
            $"{i * step / 1000:0}k–{(i + 1) * step / 1000:0}k{(i == buckets - 1 ? "+" : "")}: {n} cycles")).ToList();

        ChurnChart.Format = Tokens;
        ChurnChart.Bars = o.Days.Select(d => new Bar(Day(d.Day), [new(d.Churn, write)],
            $"{d.Day:ddd MMM d}: {Tokens(d.Churn)} weighted rewriting context already there")).ToList();
        CommandsText.Text = "in range: " + string.Join(" · ", o.Commands.Select(c => $"/{c.Key} {c.Value}"));

        ProjectChart.Bars = o.Projects.Take(12).Select(p => new Bar(p.Project, [new(p.Weighted, output)],
            $"{p.Project}: {Tokens(p.Weighted)} weighted, {Usd(p.CostUsd)}, {p.Sessions} sessions",
            $"{Tokens(p.Weighted)} · {Usd(p.CostUsd)} · {p.Sessions}s")).ToList();
    }

    static double Num(System.Text.Json.Nodes.JsonNode? n) =>
        n is System.Text.Json.Nodes.JsonValue v && v.TryGetValue<double>(out var d) ? d : 0;

    static List<Tile> TilesOf(Overview o)
    {
        var u = o.Usage;
        var w = new[] { u.Input * 1.0, u.CacheWrite * 2.0, u.CacheRead * 0.05, u.Output * 5.0 };
        string Share(int i) => o.Weighted > 0 ? $"{w[i] / o.Weighted:P0}" : "-";
        var today = o.Days.FirstOrDefault(d => d.Day == DateOnly.FromDateTime(DateTime.Now));
        var cap = double.TryParse(Environment.GetEnvironmentVariable("TOKEN_DAY_CAP"), Inv, out var c) ? c : 3_500_000;
        var span = o.Since is null ? "since the first transcript" : $"since {o.Since.Value.LocalDateTime:MMM d}";
        return
        [
            new("spend", (o.Unpriced > 0 ? "≈" : "") + Usd(o.CostUsd),
                o.Unpriced > 0 ? $"API-equivalent; {o.Unpriced} cycles on unpriced models left out" : $"API-equivalent, {span}"),
            new("weighted tokens", Tokens(o.Weighted), $"today {Tokens(today?.Weighted ?? 0)} of the {Tokens(cap)} day cap"),
            new("where it went", $"out {Share(3)}", $"cache write {Share(1)} · read {Share(2)} · input {Share(0)}"),
            new("sessions", o.Sessions.ToString(Inv), $"{o.Cycles} cycles, {span}"),
            new("median cycle", Usd(o.MedianCycleUsd),
                $"recon {o.Classes[BudgetClass.Recon]} · change {o.Classes[BudgetClass.Change]} · feature {o.Classes[BudgetClass.Feature]} · over {o.Classes[BudgetClass.Over]}"),
            new("cache hit", $"{o.HitRate:P1}", $"read {Tokens(u.CacheRead)} · written {Tokens(u.CacheWrite)}"),
            new("TokenChat", $"{o.TokenChatShare:P0}", "of weighted spend; the rest ran in terminal claude"),
        ];
    }

    Brush GradeBrush(string letter) => GradeBands.BrushOf(this, letter);

    static string Usd(double v) => v >= 100 ? $"${v:0}" : $"${v:0.00}".Replace(',', '.');

    static string Tokens(double v) => v >= 1e6 ? (v / 1e6).ToString("0.0", Inv) + "M"
        : v >= 1e3 ? (v / 1e3).ToString("0", Inv) + "k" : v.ToString("0", Inv);
}
