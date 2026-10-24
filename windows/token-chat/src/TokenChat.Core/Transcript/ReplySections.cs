using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace TokenChat.Core.Transcript;

/// <summary>A reply's "**Done**" and "**Basis**" lists, cut from its markdown into folds: Done is a checklist
/// ("- [x] `a.cs:12` — what changed") the user ticks as they review it, open when the reply lands; Basis is the
/// refs, folded to a count. Either may be missing; a reply with neither has no sections.</summary>
public sealed partial class ReplySections
{
    ReplySections(string body, ReplySection? done, ReplySection? basis) => (Body, Done, Basis) = (body, done, basis);

    /// <summary>The markdown without the sections: the folds are where they show.</summary>
    public string Body { get; }
    public ReplySection? Done { get; }
    public ReplySection? Basis { get; }

    /// <summary>A section is its heading line ("**Done**", "**Basis:**", "### Done") and the list under it, blank lines
    /// between items included; the first line that is neither a list item nor indented ends it. Outside code fences.</summary>
    public static ReplySections? Parse(string markdown)
    {
        var kept = new List<string>();
        var found = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        List<string>? into = null;
        var fenced = false;
        foreach (var line in markdown.Split('\n'))
        {
            var fence = line.TrimStart().StartsWith("```", StringComparison.Ordinal);
            if (into is not null && !fenced && !fence)
            {
                if (line.Trim().Length == 0 || ListLine().IsMatch(line))
                {
                    into.Add(line);
                    continue;
                }
                into = null;
            }
            if (fence) fenced = !fenced;
            if (!fenced && !fence && Heading().Match(line) is { Success: true } m && !found.ContainsKey(Name(m)))
            {
                found[Name(m)] = into = [];
                continue;
            }
            kept.Add(line);
        }
        if (found.Count == 0) return null;
        var done = found.TryGetValue("Done", out var d) ? Section("Done", d, checklist: true) : null;
        var basis = found.TryGetValue("Basis", out var b) ? Section("Basis", b, checklist: false) : null;
        return done is null && basis is null ? null : new ReplySections(string.Join('\n', kept).TrimEnd(), done, basis);
    }

    static string Name(Match m) => char.ToUpperInvariant(m.Groups["n"].Value[0]) + m.Groups["n"].Value[1..].ToLowerInvariant();

    static ReplySection? Section(string name, List<string> lines, bool checklist)
    {
        var raw = string.Join('\n', lines).Trim();
        if (raw.Length == 0) return null;
        var key = Convert.ToHexString(SHA1.HashData(Encoding.UTF8.GetBytes(raw)))[..12];
        var items = new List<CheckItem>();
        if (checklist)
            foreach (var line in lines)
            {
                if (line.Trim().Length == 0) continue;
                if (TopItem().Match(line) is { Success: true } m)
                    items.Add(new CheckItem($"{key}/{items.Count}", m.Groups["t"].Value.Trim(), m.Groups["c"].Value is "x" or "X"));
                else if (items.Count > 0) items[^1].Text += " " + line.Trim().TrimStart('-', '*', '+').Trim();
            }
        return new ReplySection(name, raw, items) { IsExpanded = checklist };
    }

    [GeneratedRegex(@"^\s*(?:#{1,4}\s+)?(?:\*\*)?(?<n>done|basis)(?:\*\*)?\s*:?\s*(?:\*\*)?\s*$", RegexOptions.IgnoreCase)]
    private static partial Regex Heading();

    [GeneratedRegex(@"^(?:\s*[-*+]\s|\s{2,}\S)")]
    private static partial Regex ListLine();

    [GeneratedRegex(@"^[-*+]\s+(?:\[(?<c>[ xX])\]\s+)?(?<t>.*)$")]
    private static partial Regex TopItem();
}

public sealed class ReplySection : Bindable, IFoldingQuestion
{
    bool _isExpanded;

    internal ReplySection(string name, string markdown, IReadOnlyList<CheckItem> items)
    {
        Name = name;
        Markdown = ReplyText.Tidy(markdown);
        Items = items;
        foreach (var i in items) i.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(CheckItem.IsChecked)) Notify(nameof(Count)); };
    }

    public string Name { get; }
    /// <summary>The list as markdown, for a section that is not a checklist.</summary>
    public string Markdown { get; }
    /// <summary>One box per top-level item when the section is a checklist; empty otherwise.</summary>
    public IReadOnlyList<CheckItem> Items { get; }
    public bool IsChecklist => Items.Count > 0;
    public bool IsExpanded { get => _isExpanded; set => Set(ref _isExpanded, value); }
    public bool IsAnswered => false;

    /// <summary>"3/4" ticked for a checklist, "3 refs" otherwise.</summary>
    public string Count => IsChecklist
        ? $"{Items.Count(i => i.IsChecked)}/{Items.Count}"
        : $"{Markdown.Split('\n').Count(l => l.TrimStart().StartsWith("* ", StringComparison.Ordinal))} refs";
}

/// <summary>One Done item. Starts as the reply marked it; a tick the user makes is kept in <see cref="TickStore"/>
/// under <see cref="Key"/>, the section's hash and the item's place, so a resumed tab shows it again.</summary>
public sealed class CheckItem(string key, string text, bool isChecked) : Bindable
{
    bool _isChecked = isChecked;

    public string Key { get; } = key;
    public string Text { get; internal set; } = text;
    public bool IsChecked { get => _isChecked; set => Set(ref _isChecked, value); }
}
