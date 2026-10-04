using System.Text;
using System.Text.RegularExpressions;

namespace TokenChat.Core.Transcript;

/// <summary>Reply markdown tidied for MdXaml 1.27, line by line, leaving code fences alone:
/// - "- item" becomes "* item": MdXaml draws a dash list with hollow circles, which read as radio buttons.
/// - Backticks inside **bold** are dropped: MdXaml cuts code spans out first, so the bold never closes and its
///   asterisks show.
/// - A list item that opens "Confirmed:", "Confirmed by `x`:", "Verified …" or "Assumed …" opens with ✓ or ? instead.</summary>
public static partial class ReplyText
{
    public static string Tidy(string markdown)
    {
        if (markdown.Length == 0) return markdown;
        var sb = new StringBuilder(markdown.Length);
        var fenced = false;
        foreach (var line in markdown.Split('\n'))
        {
            if (sb.Length > 0) sb.Append('\n');
            var fence = line.TrimStart().StartsWith("```", StringComparison.Ordinal);
            if (fence) fenced = !fenced;
            sb.Append(fence || fenced ? line : TidyLine(line));
        }
        return sb.ToString();
    }

    static string TidyLine(string line)
    {
        line = DashItem().Replace(line, "$1* ");
        line = Tag().Replace(line, m => m.Groups[1].Value + (char.ToLowerInvariant(m.Groups[2].Value[0]) == 'a' ? "? " : "✓ "));
        return line.Contains("**", StringComparison.Ordinal) && line.Contains('`')
            ? Bold().Replace(line, m => m.Value.Replace("`", "", StringComparison.Ordinal))
            : line;
    }

    [GeneratedRegex(@"^(\s*)- ")]
    private static partial Regex DashItem();

    /// <summary>"* Confirmed by `x`: rest" → "* ✓ `x`: rest"; "* Assumed: rest" → "* ? rest".</summary>
    [GeneratedRegex(@"^(\s*\* )(confirmed|verified|assumed)(?:\s+(?:by|with|in)\b)?\s*:?\s*", RegexOptions.IgnoreCase)]
    private static partial Regex Tag();

    [GeneratedRegex(@"\*\*(?=\S)[^*\n]+?(?<=\S)\*\*")]
    private static partial Regex Bold();
}
