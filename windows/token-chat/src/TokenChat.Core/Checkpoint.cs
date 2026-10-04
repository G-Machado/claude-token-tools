using System.Text.Json;
using System.Text.Json.Nodes;

namespace TokenChat.Core;

/// <summary>One /park checkpoint as token-sessions.sh --checkpoints --json lists it: where to resume it (folder, model,
/// effort), what it was doing, and the two facts that change what unparking does - the window that wrote it is still
/// open (unparking makes two windows on one strand), or it kept working after it parked (unparking resumes from
/// behind).</summary>
public sealed record Checkpoint(string Project, string Topic, string Cwd, string Model, string Effort, string Task,
    string Sid, int AgeMin, bool Alive, int BehindMin)
{
    /// <summary>The new session's first message.</summary>
    public string UnparkPrompt => "/unpark " + Topic;

    /// <summary>The widget's age column: minutes under an hour, hours under two days, then days.</summary>
    public string Age => AgeMin < 60 ? $"{Math.Max(0, AgeMin)}m" : AgeMin < 48 * 60 ? $"{AgeMin / 60}h" : $"{AgeMin / 1440}d";

    /// <summary>Newest first, as the collector writes them; null when the output is not the listing.</summary>
    public static IReadOnlyList<Checkpoint>? Parse(string json)
    {
        try
        {
            if (JsonNode.Parse(json) is not JsonObject root || root["checkpoints"] is not JsonArray list) return null;
            return [.. list.OfType<JsonObject>().Select(c => new Checkpoint(Str(c, "project"), Str(c, "topic"), Str(c, "cwd"),
                    Str(c, "model"), Str(c, "effort"), Str(c, "task"), Str(c, "sid"), (int)Num(c, "age_min"),
                    Num(c, "alive") == 1, (int)Num(c, "behind_min")))
                .Where(c => c.Topic.Length > 0)];
        }
        catch (JsonException) { return null; }
    }

    static string Str(JsonObject o, string k) => o[k] is JsonValue v && v.TryGetValue(out string? s) ? s : "";
    static double Num(JsonObject o, string k) => o[k] is JsonValue v && v.TryGetValue(out double d) ? d : 0;
}
