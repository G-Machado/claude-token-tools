using System.Globalization;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Media;
using TokenChat.Core;

namespace TokenChat.App;

/// <summary>A tab's row from the token widget's last collect, the widget's compact row laid on one line since the
/// window is wide enough: verdict, model, growth, cycles, heat, then marks, the hour, spend and grades. Every rule and
/// colour here is the widget's (token-widget.ps1 New-Row and its *-Color helpers), so the footer and the card read the same.
/// Context is the one live figure: the ledger has it every turn, the widget only every collect.</summary>
public sealed class FooterRow
{
    public sealed record Bar(double Width, double Height, Brush Fill, bool Live);
    public sealed record Grade(string Letter, Brush Fill);

    // the widget's $SpendBands, and its spend bar's width
    const double SpendOk = 500e3, SpendWatch = 2.0e6, SpendHeavy = 3.0e6, SpendFull = 3.5e6, SpendWidth = 66;
    const double SparkWidth = 46, SparkHeight = 13;

    static Brush B(string key) => (Brush)Application.Current.Resources[key];

    public required string Mark { get; init; }
    public required Brush MarkBrush { get; init; }
    public required string Model { get; init; }
    public required string Effort { get; init; }
    public required Brush EffortBrush { get; init; }
    public required bool Parked { get; init; }
    public required Brush ParkedBrush { get; init; }
    public required string MarksLeft { get; init; }
    public required string MarksSpent { get; init; }
    public required bool Blocked { get; init; }
    public bool HasState => MarksLeft.Length + MarksSpent.Length > 0 || Blocked;
    public required string Ctx { get; init; }
    public required Brush CtxBrush { get; init; }
    public required string Clock { get; init; }
    public required Brush ClockBrush { get; init; }
    public required bool Cold { get; init; }

    public required IReadOnlyList<Bar> Spark { get; init; }
    public bool SparkEmpty => Spark.Count == 0;
    public required string Growth { get; init; }
    public required Brush GrowthBrush { get; init; }
    public required string Cycles { get; init; }
    public required string Pokes { get; init; }
    public required string Heat { get; init; }
    public required Brush HeatBrush { get; init; }
    public required string Spend { get; init; }
    public required Brush SpendBrush { get; init; }
    public required double SpendFill { get; init; }
    public required double TickOk { get; init; }
    public required double TickWatch { get; init; }
    public required double TickHeavy { get; init; }
    public required IReadOnlyList<Grade> Grades { get; init; }

    /// <summary>Tick x positions on the spend bar, fixed because the bands and the width are.</summary>
    public static Thickness TickOkAt => new(SpendWidth * SpendOk / SpendFull, -2, 0, -2);
    public static Thickness TickWatchAt => new(SpendWidth * SpendWatch / SpendFull, -2, 0, -2);
    public static Thickness TickHeavyAt => new(SpendWidth * SpendHeavy / SpendFull, -2, 0, -2);

    /// <summary>liveContext: the ledger's context in tokens, 0 before the first turn (the row's figure stands in).</summary>
    public static FooterRow From(JsonObject s, FeedSnapshot feed, long liveContext, DateTimeOffset now)
    {
        var c = feed.Constants;
        double gbud = D(c, "gbud");
        var verdict = S(s, "verdict");

        var extAllowed = I(s, "ext_allowed"); var extLeft = I(s, "ext_left");
        var extSpent = Math.Min(I(s, "ext_used"), extAllowed);
        string marksLeft = "", marksSpent = "";
        if (extAllowed > 0 || extSpent > 0)
        {
            if (extAllowed <= 6) { marksLeft = new string('↻', extLeft); marksSpent = new string('↻', extSpent); }
            else if (extLeft > 0) marksLeft = $"{extLeft}/{extAllowed}";
            else marksSpent = $"{extLeft}/{extAllowed}";
        }

        var ctxK = liveContext > 0 ? liveContext / 1000.0 : D(s, "context_k");
        // the clock was true at the collect; it has run down since
        var left = I(s, "cache_left_min") - (int)Math.Floor((now - feed.Generated).TotalMinutes);
        var model = S(s, "model");
        model = System.Text.RegularExpressions.Regex.Replace(model.StartsWith("claude-") ? model[7..] : model, @"-\d{8}$", "");
        var effort = S(s, "effort");

        var recent = (s["recent"] as JsonArray)?.OfType<JsonObject>().Select(r => D(r, "growth")).ToList() ?? [];
        var live = I(s, "live") == 1;
        if (live) recent.Add(D(s, "live_growth"));
        var each = Math.Max(2, Math.Floor(SparkWidth / Math.Max(recent.Count, 3)) - 1);
        var spark = recent.Select((g, i) =>
        {
            var ratio = gbud > 0 ? g / gbud : 0;
            return new Bar(each, Math.Max(1.5, Math.Min(1.0, ratio) * SparkHeight), GrowthColor(ratio), live && i == recent.Count - 1);
        }).ToList();
        var lastG = recent.Count > 0 ? recent[^1] : 0;

        var hot = D(s, "hot");
        var pokes = I(s, "pokes");
        var cost = s["cost"] as JsonObject;
        var spend = cost is null ? 0 : D(cost, "total");
        var grades = s["grades"] as JsonObject;

        return new FooterRow
        {
            Mark = verdict switch { "now" or "soon" => "▲", "cut" => "△", "ok" => "○", _ => "·" },
            MarkBrush = B(verdict switch { "now" => "Red", "soon" => "Orange", "cut" => "Yellow", "ok" => "Green", _ => "Faint" }),
            Model = model,
            Effort = model.Length > 0 && effort.Length > 0 ? "  " + effort : effort,
            EffortBrush = B(effort == "xhigh" ? "Orange" : "Faint"),
            Parked = I(s, "parked") == 1,
            ParkedBrush = B(I(s, "ck_stale") == 1 ? "Orange" : "Blue"),
            MarksLeft = marksLeft,
            MarksSpent = marksSpent,
            Blocked = I(s, "blocked") == 1,
            Ctx = ctxK.ToString("0.0", CultureInfo.InvariantCulture) + "k",
            CtxBrush = B(D(c, "max_at") > 0 && ctxK >= D(c, "max_at") ? "Red" : ctxK >= D(c, "cut_pk") ? "Yellow" : "Green"),
            Clock = left <= 0 ? "COLD" : $"{left}m",
            ClockBrush = B(left <= 0 ? "Red" : left <= 10 ? "Orange" : left <= 20 ? "Yellow" : "Dim"),
            Cold = left <= 0,
            Spark = spark,
            Growth = "  +" + Tok(lastG),
            GrowthBrush = GrowthColor(gbud > 0 ? lastG / gbud : 0),
            Cycles = I(s, "cycles").ToString(CultureInfo.InvariantCulture),
            Pokes = pokes > 0 ? $"+{pokes}↻" : "",
            Heat = hot > 0 ? hot.ToString("0.0", CultureInfo.InvariantCulture) + "x" : "",
            HeatBrush = B(hot >= 1.5 ? "Red" : hot >= 1.0 ? "Orange" : hot >= 0.7 ? "Yellow" : "Green"),
            Spend = Tok(spend),
            SpendBrush = B(spend >= SpendHeavy ? "Red" : spend >= SpendWatch ? "Orange" : spend >= SpendOk ? "Yellow" : "Green"),
            SpendFill = Math.Clamp(spend / SpendFull, 0, 1),
            TickOk = SpendOk <= spend ? 0.25 : 0.55,
            TickWatch = SpendWatch <= spend ? 0.25 : 0.55,
            TickHeavy = SpendHeavy <= spend ? 0.25 : 0.55,
            Grades = [.. new[] { "held", "short", "churn", "control" }.Select(k => grades is null ? "" : S(grades, k))
                .Select(g => new Grade(g.Length > 0 ? g : "·", B(g switch { "A" or "B" => "Green", "C" => "Blue", "D" => "Yellow", "E" => "Red", _ => "Faint" })))],
        };
    }

    static Brush GrowthColor(double ratio) => B(ratio >= 1.0 ? "Red" : ratio >= 0.6 ? "Orange" : ratio >= 0.3 ? "Yellow" : "Green");

    /// <summary>The widget's Tok: 81664 → "82k", 1234 → "1.2k", 2.1e6 → "2.10M".</summary>
    static string Tok(double v) => v switch
    {
        >= 1e7 => (v / 1e6).ToString("N1", CultureInfo.InvariantCulture) + "M",
        >= 1e6 => (v / 1e6).ToString("N2", CultureInfo.InvariantCulture) + "M",
        >= 1e4 => (v / 1e3).ToString("N0", CultureInfo.InvariantCulture) + "k",
        >= 1000 => (v / 1e3).ToString("N1", CultureInfo.InvariantCulture) + "k",
        _ => v.ToString("N0", CultureInfo.InvariantCulture),
    };

    static string S(JsonObject o, string k) => o[k] is JsonValue v && v.TryGetValue(out string? s) ? s : "";
    static double D(JsonObject o, string k) => SidebarItem.Num(o, k);
    static int I(JsonObject o, string k) => (int)D(o, k);
}
