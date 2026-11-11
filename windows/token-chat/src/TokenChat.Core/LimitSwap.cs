using TokenChat.Core.Protocol;
using System.Text.Json.Nodes;

namespace TokenChat.Core;

/// <summary>A delegate that hits the 5-hour limit: switch to the spare account, then tell the session to write partial
/// output first and resume (2026-11-11). This is the hand procedure of 2026-11-10, when four delegates hit the limit at
/// 22:32 and each waited for a cswap and a nudge. Pure decisions here; SessionTab owns the once-per-tab rule.</summary>
public static class LimitSwap
{
    /// <summary>The CLI's rate_limit_event status once a request has been refused.</summary>
    public static bool IsRejected(RateLimitEvent? r) =>
        r?.Status is { } s && (s.Equals("rejected", StringComparison.OrdinalIgnoreCase) || s.Contains("exceeded", StringComparison.OrdinalIgnoreCase)
            || (r.FiveHour is { } w && w.Utilization >= 1.0));

    /// <summary>The account with the most 5-hour headroom that is not the active one and is signed in; null when
    /// none has at least <paramref name="minRoomPct"/> left. Reads the widget's limits block (cswap's poll).</summary>
    public static string? SpareAccount(JsonObject? limits, double minRoomPct = 20)
    {
        string? best = null; double bestPct = 100;
        foreach (var a in (limits?["accounts"] as JsonArray)?.OfType<JsonObject>() ?? [])
        {
            if (Num(a, "active") == 1 || Str(a, "status") != "ok") continue;
            var pct = Num(a, "five_hour_pct");
            if (100 - pct < minRoomPct || pct >= bestPct) continue;
            best = Str(a, "n"); bestPct = pct;
        }
        return best;
    }

    public const string ResumeText =
        "[token-chat] this account hit its 5-hour limit; TokenChat switched to the spare account. "
        + "Write your partial output to the report path first (status=partial, what is verified so far), then carry on with the brief.";

    public sealed record Outcome(string Title, string Detail, string? Error);

    /// <summary>Switch, then send the resume line. The send goes even when no spare exists: the partial report is the
    /// part that saves the work, and the master reads it either way.</summary>
    public static async Task<Outcome> SwitchAndResumeAsync(FeedSnapshot? feed, Func<string, Task> send)
    {
        var spare = SpareAccount(feed?.Limits);
        string? error = null;
        if (spare is null) error = "no spare account with 20% of its 5-hour window left";
        else error = await SessionControl.SwitchAccountAsync(spare);
        try { await send(ResumeText); } catch (Exception e) when (e is IOException or InvalidOperationException) { error ??= e.Message; }
        return error is null
            ? new Outcome($"5-hour limit: switched to account {spare}", "the delegate was told to write partial output first, then resume", null)
            : new Outcome("5-hour limit hit", error + " - the delegate was told to write partial output; switch from the sidebar header", error);
    }

    static string Str(JsonObject o, string k) => o[k] is JsonValue v ? v.ToString() : "";
    static double Num(JsonObject o, string k) => o[k] is JsonValue v && double.TryParse(v.ToString(), System.Globalization.NumberStyles.Float,
        System.Globalization.CultureInfo.InvariantCulture, out var d) ? d : 0;
}
