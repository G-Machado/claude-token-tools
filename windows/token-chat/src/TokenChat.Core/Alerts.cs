using System.Globalization;
using System.Text.Json.Nodes;

namespace TokenChat.Core;

/// <summary>The tray's notifications, read off each collect: what the widget and the prompt hook would say, for
/// whoever is not looking at either. Each fires once, and again only after its condition has cleared.</summary>
public sealed class Alerts
{
    /// <summary>The poke task's own window: it renews in a cache's last eight minutes, and leaves windows under 60k to
    /// die (CLAUDE.md, ClaudeTokenPokeDue).</summary>
    public const int LapseMinutes = 8;
    public const double LapseFloor = 60_000;
    public const double LimitPct = 90;

    readonly HashSet<string> _told = [];
    bool _primed;

    /// <summary>What to say about this collect. The first call only takes note: the states already true when the app
    /// starts are not news.</summary>
    public IReadOnlyList<(string Title, string Text)> Check(FeedSnapshot feed, DateTimeOffset now)
    {
        var said = new List<(string, string)>();
        var live = new HashSet<string>();
        void Once(string key, string title, string text)
        {
            live.Add(key);
            if (_told.Add(key) && _primed) said.Add((title, text));
        }

        var since = (int)Math.Floor((now - feed.Generated).TotalMinutes);
        foreach (var s in feed.Ordered.Where(s => Num(s, "alive") == 1))
        {
            var sid = Str(s, "sid");
            var name = Str(s, "nick") is { Length: > 0 } n ? n : sid.Length > 8 ? sid[..8] : sid;
            var ctx = Num(s, "context");
            var left = (int)Num(s, "cache_left_min") - since;
            if (left is > 0 and <= LapseMinutes && Num(s, "ext_left") <= 0 && ctx >= LapseFloor && Num(s, "blocked") != 1)
                Once("lapse:" + sid, $"{name}: cache lapses in {left}m",
                    $"{K(ctx)} window, no extension marks left. Send it something, add a mark, or /park it.");
            if (Num(s, "blocked") == 1)
                Once("block:" + sid, $"{name} is blocked", "It refuses every prompt until the block is lifted (u on its row).");
            if (Str(s, "verdict") == "cut")
            {
                var band = Math.Floor(ctx / 50_000) * 50;
                Once($"cut:{sid}:{band}", $"{name} is past the cut bar",
                    $"{K(ctx)} - finish the current task, then /park + /clear (or /handoff) at the next stopping point.");
            }
        }
        foreach (var a in (feed.Limits?["accounts"] as JsonArray)?.OfType<JsonObject>() ?? [])
            if (Num(a, "active") == 1 && Num(a, "five_hour_pct") >= LimitPct)
                Once("limit:" + Str(a, "n"), $"5h limit at {Num(a, "five_hour_pct"):0}%",
                    $"Resets in {Str(a, "five_hour_in")}. Another account can take over from the sidebar header.");

        // cleared conditions may fire again; a cut band is told once for good, as token-told/<sid> keeps it
        _told.RemoveWhere(k => !live.Contains(k) && !k.StartsWith("cut:", StringComparison.Ordinal));
        _primed = true;
        return said;
    }

    static string K(double tokens) => (tokens / 1000).ToString("0", CultureInfo.InvariantCulture) + "k";

    static string Str(JsonObject o, string k) => o[k] is JsonValue v ? v.ToString() : "";

    static double Num(JsonObject o, string k) =>
        o[k] is JsonValue v && double.TryParse(v.ToString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? d : 0;
}
