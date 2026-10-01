using System.Text.Json.Nodes;

namespace TokenChat.Core.Protocol;

/// <summary>"Allow for session": the CLI's own permission_suggestions, re-aimed at the session so nothing is
/// written to a settings file (Bash rules arrive with destination localSettings).</summary>
public static class PermissionRules
{
    /// <summary>The suggestions that grant something, each with destination session, and a button label
    /// naming what they grant; null when there is nothing to grant.</summary>
    public static (JsonArray Rules, string Label)? ForSession(JsonArray? suggestions)
    {
        var rules = new JsonArray();
        var grants = new List<string>();
        foreach (var s in suggestions?.OfType<JsonObject>() ?? [])
        {
            var grant = Json.Str(s["type"]) switch
            {
                "setMode" => Json.Str(s["mode"]) is "acceptEdits" ? "edits" : Json.Str(s["mode"]) + " mode",
                "addRules" when Json.Str(s["behavior"]) is null or "allow" => string.Join(", ",
                    (s["rules"] as JsonArray ?? []).OfType<JsonObject>().Select(r =>
                        Json.Str(r["ruleContent"]) is { } c ? $"{Json.Str(r["toolName"])}({c})" : Json.Str(r["toolName"]))),
                "addDirectories" => string.Join(", ", Json.Strings(s["directories"])),
                _ => null,
            };
            if (string.IsNullOrEmpty(grant)) continue;
            var rule = (JsonObject)s.DeepClone();
            rule["destination"] = "session";
            rules.Add(rule);
            grants.Add(grant);
        }
        if (rules.Count == 0) return null;
        var label = string.Join(", ", grants);
        if (label.Length > 60) label = label[..60] + "…";
        return (rules, $"Allow {label} this session");
    }
}
