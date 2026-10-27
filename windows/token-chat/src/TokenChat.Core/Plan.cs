using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace TokenChat.Core;

/// <summary>One step of a session's plan: State is done, now (the one under way) or todo. The popup shows Title and
/// folds Detail under it.</summary>
public sealed record PlanStep(string Text, string State)
{
    public string Mark => State switch { "done" => "✓", "now" => "▸", _ => "○" };
    public string Title => Split(Text).Title;
    public string Detail => Split(Text).Detail;

    const int TitleChars = 80;
    static readonly Regex Done = new(@"^(DONE\b[\s:—-]*|\[x\]\s*)", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    /// <summary>The lead clause: up to " — ", else to the first ". " or ": ", else the whole step; a lead over 80
    /// characters is cut at a word and the whole step becomes the detail.</summary>
    public static (string Title, string Detail) Split(string text)
    {
        var t = Done.Replace(text.Replace("~~", ""), "").Trim();
        int at = t.IndexOf(" — ", StringComparison.Ordinal), skip = 3;
        if (at < 0)
        {
            var dot = t.IndexOf(". ", StringComparison.Ordinal);
            var colon = t.IndexOf(": ", StringComparison.Ordinal);
            at = dot < 0 ? colon : colon < 0 ? dot : Math.Min(dot, colon);
            skip = 2;
        }
        var (title, detail) = at < 0 ? (t, "") : (t[..at], t[(at + skip)..].Trim());
        title = title.TrimEnd('.', ' ');
        if (title.Length <= TitleChars) return (title, detail);
        var cut = title.LastIndexOf(' ', TitleChars);
        return (title[..(cut > 40 ? cut : TitleChars)] + "…", t);
    }
}

/// <summary>The caption chip's plan for a tab: its checkpoint's ## Next (a numbered item starting DONE, [x] or ~~ is
/// done, the first other one is under way) and Stop after:, or the session's last TodoWrite, which stands in for it until
/// the checkpoint is rewritten.</summary>
public sealed record Plan(IReadOnlyList<PlanStep> Steps, string? StopAfter, string Source)
{
    static readonly Regex Item = new(@"^\s{0,3}\d+\.\s+(.*)$", RegexOptions.Compiled);

    public static readonly string Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "checkpoints");

    /// <summary>"plan 2/5": the step under way, of all of them; all done reads 5/5.</summary>
    public string Chip
    {
        get
        {
            var at = Steps.ToList().FindIndex(s => s.State == "now");
            return $"plan {(at < 0 ? Steps.Count : at + 1)}/{Steps.Count}";
        }
    }

    /// <summary>The newest <c>&lt;proj&gt;.&lt;topic&gt;.md</c>; null when there is none or the folder will not list.</summary>
    public static string? CheckpointPath(string topic)
    {
        try
        {
            return new DirectoryInfo(Dir).GetFiles("*." + topic + ".md").OrderByDescending(f => f.LastWriteTimeUtc).FirstOrDefault()?.FullName;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException) { return null; }
    }

    /// <summary>Null when ## Next has no numbered item. An item is its first line and the indented lines under it.</summary>
    public static Plan? FromCheckpoint(string path, string text)
    {
        var steps = new List<PlanStep>();
        string? stop = null;
        var inNext = false;
        foreach (var raw in text.Replace("\r", "").Split('\n'))
        {
            if (raw.StartsWith("## ", StringComparison.Ordinal))
            {
                if (inNext) break;
                inNext = raw[3..].Trim().Equals("Next", StringComparison.OrdinalIgnoreCase);
                continue;
            }
            if (!inNext) continue;
            if (raw.StartsWith("Stop after:", StringComparison.Ordinal)) stop = raw["Stop after:".Length..].Trim();
            else if (Item.Match(raw) is { Success: true } m)
            {
                var item = m.Groups[1].Value.Trim();
                var done = item.StartsWith("DONE", StringComparison.Ordinal) || item.StartsWith("[x]", StringComparison.OrdinalIgnoreCase)
                    || item.StartsWith("~~", StringComparison.Ordinal);
                steps.Add(new(item, done ? "done" : "todo"));
            }
            else if (steps.Count > 0 && raw.Length > 0 && char.IsWhiteSpace(raw[0]) && raw.Trim() is { Length: > 0 } more)
                steps[^1] = steps[^1] with { Text = steps[^1].Text + " " + more };
        }
        return steps.Count == 0 ? null : new(UnderWay(steps), stop, Path.GetFileName(path));
    }

    /// <summary>Null when the list is empty. No in_progress item: the first not completed is under way.</summary>
    public static Plan? FromTodos(JsonArray todos)
    {
        var steps = todos.OfType<JsonObject>()
            .Select(t => new PlanStep(Str(t, "content"), Str(t, "status") switch { "completed" => "done", "in_progress" => "now", _ => "todo" }))
            .Where(s => s.Text.Length > 0).ToList();
        return steps.Count == 0 ? null : new(steps.Any(s => s.State == "now") ? steps : UnderWay(steps), null, "the session's todo list");
    }

    static List<PlanStep> UnderWay(List<PlanStep> steps)
    {
        var at = steps.FindIndex(s => s.State != "done");
        if (at >= 0) steps[at] = steps[at] with { State = "now" };
        return steps;
    }

    static string Str(JsonObject o, string k) => o[k] is JsonValue v && v.TryGetValue(out string? s) ? s : "";
}
