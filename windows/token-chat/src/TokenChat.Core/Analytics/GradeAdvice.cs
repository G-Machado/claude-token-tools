using System.Globalization;
using System.Text.Json.Nodes;

namespace TokenChat.Core.Analytics;

/// <param name="Value">the raw figure the letter is graded off, already formatted with its unit</param>
/// <param name="Raw">that figure as a number, and <paramref name="PreviousRaw"/> the 7 days before's</param>
public sealed record Grade(string Axis, string Letter, string? Previous, string Value, string Meaning, double Raw = 0,
    double? PreviousRaw = null)
{
    /// <summary>Where the figure sits on its ladder: 0 to 5, the whole part the band (A = 0), the fraction how far
    /// through it. E runs one band-width past its cut, then stops.</summary>
    public static double Position(string axis, double v)
    {
        if (!Ladders.TryGetValue(axis, out var cuts)) return 0;
        var lo = 0.0;
        for (var i = 0; i < cuts.Length; i++)
        {
            if (v <= cuts[i]) return i + (cuts[i] > lo ? (v - lo) / (cuts[i] - lo) : 0);
            lo = cuts[i];
        }
        var width = cuts[^1] - cuts[^2];
        return Math.Min(4.999, 4 + (v - cuts[^1]) / width);
    }

    // The OVERALL ladders in token-sessions.sh (heldgrade, shortgrade, churngrade, ctlgrade, ~:2780): A up to the
    // first cut, E past the last. They only place the marker; the letter is always the feed's.
    static readonly Dictionary<string, double[]> Ladders = new()
    {
        ["held"] = [10, 25, 45, 65],
        ["short"] = [5, 10, 20, 35],
        ["churn"] = [2, 5, 10, 33],
        ["control"] = [0.05, 0.2, 0.45, 0.8],
    };
}

/// <summary>The four OVERALL grades token-sessions.sh puts in the feed (this 7 days and the 7 before), and what to do
/// about the worst. The letters come from the script's ladders; nothing is re-graded here.</summary>
public static class GradeAdvice
{
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    public static IReadOnlyList<Grade> Read(JsonObject? overall)
    {
        if (overall?["grades"] is not JsonObject g) return [];
        var prev = overall["prev_grades"] as JsonObject;
        var cut = Num(overall["cut_k"]);
        var before = overall["prev"] as JsonObject;
        double? Was(string k) => before?[k] is JsonValue ? Num(before[k]) : null;
        string? L(JsonObject? o, string k) => o?[k]?.GetValue<string>();
        return
        [
            new("held", L(g, "held") ?? "?", L(prev, "held"), $"{Num(overall["held"]):0.#}%",
                $"of spend paid past the {cut:0}k cut bar", Num(overall["held"]), Was("held")),
            new("short", L(g, "short") ?? "?", L(prev, "short"), $"{Num(overall["short"]):0.#}%",
                "of spend on the cold floor of sessions that stopped at two cycles", Num(overall["short"]), Was("short")),
            new("churn", L(g, "churn") ?? "?", L(prev, "churn"), $"{Num(overall["churn"]):0.#}%",
                "of spend rewriting a window whose cache had lapsed", Num(overall["churn"]), Was("churn")),
            new("control", L(g, "control") ?? "?", L(prev, "control"), Num(overall["ctl"]).ToString("0.00", Inv),
                "over-budget prompts per cycle", Num(overall["ctl"]), Was("ctl")),
        ];
    }

    /// <summary>The worst grades at C or below, worst first, at most two: one concrete fix each.</summary>
    public static IReadOnlyList<string> Suggest(IReadOnlyList<Grade> grades) =>
        grades.Where(g => g.Letter is "C" or "D" or "E")
            .OrderByDescending(g => g.Letter).ThenBy(g => g.Axis == "held" ? 0 : 1)
            .Take(2)
            .Select(g => $"{g.Axis} {g.Letter} ({g.Value} {g.Meaning}): " + g.Axis switch
            {
                "held" => "past the cut bar, finish the task and /handoff at the next topic change instead of carrying the window.",
                "short" => "a small question goes in a warm window that is already open (the start hint names one), not a fresh session.",
                "churn" => "leaving for over an hour: /park while the cache is warm, then /clear; or give the window a poke mark.",
                _ => "a prompt that bundles investigation, design and implementation gets split: investigate, report, then build.",
            })
            .ToList();

    static double Num(JsonNode? n) => n is JsonValue v && v.TryGetValue<double>(out var d) ? d : 0;
}
