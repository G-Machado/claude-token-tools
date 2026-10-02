using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using TokenChat.Core.Protocol;

namespace TokenChat.Core.Transcript;

/// <summary>A tool call as a phrase: what it does to what (Verb, Subject), where (Detail), and for a shell call
/// the command itself on a line of its own, since the subject is then its description.</summary>
public sealed record ToolHeadline(string Verb, string Subject, string? Detail = null, string? Command = null);

/// <summary>The words a tool row shows: the call, what came back, what it cost.</summary>
public static partial class ToolText
{
    /// <summary>Growth that earns a yellow mark: a third of a `change` cycle's 15k growth budget for one call,
    /// the whole budget for one folded run.</summary>
    public const long BigCall = 5_000, BigRun = 15_000;

    /// <summary>Chars per token of a tool result, for the estimate shown until the next request measures it.
    /// Code and listings measured 2.0–2.6 (this repo's transcripts, 2026-10-02); prose runs nearer 4.</summary>
    const double CharsPerToken = 2.5;

    static readonly HashSet<string> ShellLooks = new(StringComparer.OrdinalIgnoreCase)
    {
        "cd", "pushd", "popd", "cat", "head", "tail", "sed", "awk", "grep", "egrep", "rg", "ls", "wc", "find", "file", "stat",
        "du", "tree", "echo", "printf", "sort", "uniq", "cut", "tr", "diff", "cmp", "jq", "which", "pwd", "realpath",
        "basename", "dirname", "nl", "column", "xxd", "od",
        "set-location", "get-content", "gc", "type", "get-childitem", "gci", "dir", "select-string", "sls", "test-path",
        "get-item", "gi", "measure-object", "select-object", "select", "where-object", "where", "sort-object",
        "format-table", "ft", "format-list", "fl", "out-string", "write-output",
    };
    static readonly HashSet<string> GitLooks = ["status", "diff", "log", "show", "blame", "grep", "ls-files", "rev-parse", "cat-file"];

    /// <summary>Calls that only look: reads, searches, and shell commands made only of reading verbs. A run of
    /// them folds into one row. A misread costs only a fold, so anything unclear counts as doing.</summary>
    public static bool IsLook(string tool, JsonObject? input) => tool switch
    {
        "Read" or "Grep" or "Glob" or "LS" or "NotebookRead" => true,
        "Bash" or "PowerShell" => Json.Str(input?["command"]) is { } command && IsLookingShell(command),
        _ => false,
    };

    /// <summary>Shell tools are only known to look once their input is in; the rest by name alone.</summary>
    public static bool NeedsInput(string tool) => tool is "Bash" or "PowerShell";

    static bool IsLookingShell(string command)
    {
        var bare = Quiet().Replace(Quoted().Replace(command, "Q"), "");
        if (bare.Contains('>') || bare.Contains('`') || bare.Contains("$(")) return false;
        foreach (var raw in Segment().Split(bare))
        {
            var words = raw.Trim().TrimStart('(').Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (words.Length == 0) continue;
            var ok = words[0] switch
            {
                "git" => words.Length > 1 && GitLooks.Contains(words[1]),
                "sed" => !words.Any(w => w.StartsWith("-i", StringComparison.Ordinal)),
                "find" => !words.Any(w => w is "-delete" or "-exec" or "-execdir" or "-ok"),
                var w => ShellLooks.Contains(w),
            };
            if (!ok) return false;
        }
        return true;
    }

    public static ToolHeadline Describe(string tool, JsonObject? input, string? cwd)
    {
        if (input is null) return new(tool, "");
        string? S(string key) => Json.Str(input[key]) is { Length: > 0 } s ? s : null;
        switch (tool)
        {
            case "Read" or "NotebookRead" when (S("file_path") ?? S("notebook_path")) is { } path:
                return new("Read", Path.GetFileName(path), Folder(path, cwd));
            case "Grep" when S("pattern") is { } pattern:
                return new("Search", "\"" + TranscriptProjector.OneLine(pattern, 80) + "\"",
                    Join(Place(S("path"), cwd), S("glob") ?? S("type"), S("output_mode") is { } mode and not "content" ? mode.Replace('_', ' ') : null));
            case "Glob" when S("pattern") is { } pattern:
                return new("Find", pattern, Place(S("path"), cwd));
            case "Edit" or "MultiEdit" or "Write" or "NotebookEdit" when (S("file_path") ?? S("notebook_path")) is { } path:
                return new(tool == "Write" ? "Write" : "Edit", Path.GetFileName(path), Folder(path, cwd));
            case "Bash" or "PowerShell" when S("command") is { } command:
                return S("description") is { } why
                    ? new(tool, TranscriptProjector.OneLine(why, 120), null, TranscriptProjector.OneLine(command, 200))
                    : new(tool, TranscriptProjector.OneLine(command, 200));
            case "WebFetch" when S("url") is { } url: return new("Fetch", TranscriptProjector.OneLine(url, 120));
            case "WebSearch" when S("query") is { } query: return new("Web search", TranscriptProjector.OneLine(query, 120));
            case "Agent" or "Task": return new("Agent", TranscriptProjector.OneLine(S("description") ?? S("prompt") ?? "", 120), S("subagent_type"));
            case "Skill" when S("skill") is { } skill: return new("Skill", skill, S("args") is { } args ? TranscriptProjector.OneLine(args, 80) : null);
            case "ToolSearch" when S("query") is { } query: return new("Tool search", query);
            case "TodoWrite" when input["todos"] is JsonArray todos: return new("Todos", Count(todos.Count, "item"));
        }
        var name = tool.StartsWith("mcp__", StringComparison.Ordinal) ? tool[(tool.LastIndexOf("__", StringComparison.Ordinal) + 2)..] : tool;
        return new(name, TranscriptProjector.Summarize(input));
    }

    /// <summary>What came back, in the tool's own terms: a line range, hits and files, a diff size.</summary>
    public static string Outcome(string tool, JsonObject? input, string result, bool isError)
    {
        if (isError)
        {
            var why = ErrorTag().Replace(result, "").Trim();
            return why.Length == 0 ? "failed" : "failed: " + TranscriptProjector.OneLine(why.Split('\n')[0], 90);
        }
        switch (tool)
        {
            case "Read":
                var numbered = NumberedLine().Matches(result);
                if (numbered.Count == 0) return result.Length == 0 ? "empty" : Lines(result);
                var first = int.Parse(numbered[0].Groups[1].Value, CultureInfo.InvariantCulture);
                var last = int.Parse(numbered[^1].Groups[1].Value, CultureInfo.InvariantCulture);
                var whole = input?["offset"] is null && input?["limit"] is null && first == 1 && numbered.Count < 2000;
                return whole ? "all " + Count(numbered.Count, "line") : $"lines {first}–{last}";
            case "Grep":
                var text = result.Trim();
                if (text.Length == 0 || text.StartsWith("No matches", StringComparison.Ordinal) || text.StartsWith("No files", StringComparison.Ordinal))
                    return "no matches";
                if (FoundTotal().Match(text) is { Success: true } total)
                    return Count(int.Parse(total.Groups[1].Value, CultureInfo.InvariantCulture), "hit") + " · "
                        + Count(int.Parse(total.Groups[2].Value, CultureInfo.InvariantCulture), "file");
                if (FoundFiles().Match(text) is { Success: true } files)
                    return Count(int.Parse(files.Groups[1].Value, CultureInfo.InvariantCulture), "file");
                var hits = text.Split('\n').Count(l => l.Trim().Length > 0 && l.Trim() != "--" && !l.StartsWith("[Showing", StringComparison.Ordinal));
                return Count(hits, "line") + (text.Contains("[Showing results with pagination", StringComparison.Ordinal) ? " (capped)" : "");
            case "Glob":
                if (result.Trim().StartsWith("No files", StringComparison.Ordinal)) return "no files";
                var paths = result.Split('\n').Count(l => l.Trim().Length > 0 && !l.StartsWith('('));
                return Count(paths, "file") + (result.Contains("truncated", StringComparison.OrdinalIgnoreCase) ? " (capped)" : "");
            case "Edit" when input is not null:
                return Churn(LineDiff.Compute(Json.Str(input["old_string"]) ?? "", Json.Str(input["new_string"]) ?? ""));
            case "MultiEdit" when input is not null && input["edits"] is JsonArray edits:
                return Count(edits.Count, "edit") + " · " + Churn(edits.OfType<JsonObject>()
                    .SelectMany(e => LineDiff.Compute(Json.Str(e["old_string"]) ?? "", Json.Str(e["new_string"]) ?? "")));
            case "Write" when Json.Str(input?["content"]) is { } content:
                return Lines(content);
            case "Bash" or "PowerShell":
                var output = result.Trim();
                if (output.Length == 0) return "no output";
                return !output.Contains('\n') && output.Length <= 60 ? "→ " + output : Lines(output);
        }
        return result.Length == 0 ? "no output" : Lines(result);
    }

    /// <summary>Why a run of calls happened, from the thinking before it: its last sentence, the step about to be
    /// taken, without the "Let me" in front. Null when the thinking is empty (redacted, or none).</summary>
    public static string? Intent(string thinking)
    {
        var paragraph = thinking.Split("\n\n").Select(p => p.Trim()).LastOrDefault(p => p.Length > 0);
        if (paragraph is null) return null;
        var sentence = SentenceEnd().Split(paragraph).Select(s => s.Trim()).LastOrDefault(s => s.Length > 0);
        if (sentence is null) return null;
        sentence = LeadIn().Replace(sentence, "").TrimEnd('.', ':', ' ');
        if (sentence.Length == 0) return null;
        return TranscriptProjector.OneLine(char.ToUpperInvariant(sentence[0]) + sentence[1..], 110);
    }

    /// <summary>A result's growth: "+1.2k" measured, "≈1.2k" estimated.</summary>
    public static string Cost(long tokens, bool exact) => (exact ? "+" : "≈") + Tokens.K(tokens);

    public static long Estimate(int resultChars) => (long)Math.Ceiling(resultChars / CharsPerToken);

    /// <summary>A run's shape: "3 reads · 2 searches".</summary>
    public static string Counts(IEnumerable<ToolUseItem> tools) => string.Join(" · ", tools
        .GroupBy(t => t.Line.Verb switch { "Read" => "read", "Search" => "search", "Find" => "find", "Bash" or "PowerShell" => "command", _ => "call" })
        .Select(g => Count(g.Count(), g.Key)));

    /// <summary>What a run touched, when no thinking says why: its files, patterns and command descriptions.</summary>
    public static string Subjects(IEnumerable<ToolUseItem> tools) =>
        TranscriptProjector.OneLine(string.Join(", ", tools.Select(t => t.Line.Subject).Where(s => s.Length > 0).Distinct()), 110);

    /// <summary>A file's folder, relative to the session's directory when inside it, else ~-shortened.</summary>
    static string? Folder(string path, string? cwd) => Place(Path.GetDirectoryName(path), cwd) is { Length: > 0 } dir ? dir : null;

    static string? Place(string? path, string? cwd)
    {
        if (path is null) return null;
        var p = path.Replace('/', '\\').TrimEnd('\\');
        if (cwd is { Length: > 0 } && cwd.Replace('/', '\\').TrimEnd('\\') is var root)
        {
            if (p.Equals(root, StringComparison.OrdinalIgnoreCase)) return "";
            if (p.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase)) return p[(root.Length + 1)..].Replace('\\', '/');
        }
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile).TrimEnd('\\');
        if (home.Length > 0 && p.StartsWith(home + "\\", StringComparison.OrdinalIgnoreCase)) return "~/" + p[(home.Length + 1)..].Replace('\\', '/');
        return path;
    }

    static string? Join(params string?[] parts) =>
        parts.Where(p => !string.IsNullOrEmpty(p)).ToList() is { Count: > 0 } kept ? string.Join(" · ", kept) : null;

    static string Churn(IEnumerable<DiffLine> diff)
    {
        var lines = diff.ToList();
        return $"+{lines.Count(l => l.Kind == DiffKind.Added)} −{lines.Count(l => l.Kind == DiffKind.Removed)}";
    }

    static string Lines(string s) => Count(s.TrimEnd('\n').Split('\n').Length, "line");

    static string Count(int n, string noun) =>
        n.ToString(CultureInfo.InvariantCulture) + " " + (n == 1 ? noun : noun.EndsWith("ch", StringComparison.Ordinal) ? noun + "es" : noun + "s");

    /// <summary>Quoted arguments, so a pattern's | or ; is not read as a pipe.</summary>
    [GeneratedRegex(@"""(?:[^""\\]|\\.)*""|'[^']*'")]
    private static partial Regex Quoted();

    [GeneratedRegex(@"\s*(?:2>\s*&1|[12]?>\s*(?:/dev/null|\$null))")]
    private static partial Regex Quiet();

    [GeneratedRegex(@"&&|\|\||[;|\n]")]
    private static partial Regex Segment();

    [GeneratedRegex(@"^\s*(\d+)(?:\t|→)", RegexOptions.Multiline)]
    private static partial Regex NumberedLine();

    [GeneratedRegex(@"Found (\d+) total occurrences? across (\d+) files?")]
    private static partial Regex FoundTotal();

    [GeneratedRegex(@"^Found (\d+) files?\b")]
    private static partial Regex FoundFiles();

    [GeneratedRegex(@"</?tool_use_error>")]
    private static partial Regex ErrorTag();

    [GeneratedRegex(@"(?<=[.!?:])\s+")]
    private static partial Regex SentenceEnd();

    [GeneratedRegex(@"^(?:(?:ok(?:ay)?|now|next|first|then|so|good|great|right)[,.]?\s+)*(?:let me|let's|i'll|i will|i need to|i should|i want to|i'm going to)\s+", RegexOptions.IgnoreCase)]
    private static partial Regex LeadIn();
}
