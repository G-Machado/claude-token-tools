using System.Text;
using System.Text.RegularExpressions;

namespace TokenChat.Core.Analytics;

public sealed record TranscriptFile(string Path, string SessionId, string? Cwd, string? Title, DateTime LastWriteUtc, long Bytes)
{
    public string Project => Cwd is { } c && System.IO.Path.GetFileName(c.TrimEnd('\\', '/')) is { Length: > 0 } n ? n
        : System.IO.Path.GetFileName(System.IO.Path.GetDirectoryName(Path)) ?? "";
}

/// <summary>Session transcripts under ~/.claude/projects/&lt;project&gt;/&lt;sid&gt;.jsonl, terminal and TokenChat
/// alike. Subagent transcripts live a folder deeper and are left out.</summary>
public static partial class TranscriptIndex
{
    const int TailBytes = 64 * 1024;

    public static List<TranscriptFile> Recent(string root, int max = 40)
    {
        if (!Directory.Exists(root)) return [];
        return Directory.EnumerateDirectories(root)
            .SelectMany(d => new DirectoryInfo(d).EnumerateFiles("*.jsonl"))
            .OrderByDescending(f => f.LastWriteTimeUtc).Take(max)
            .Select(f => new TranscriptFile(f.FullName, System.IO.Path.GetFileNameWithoutExtension(f.Name),
                RecentProjects.Cwd(f.FullName), Title(f.FullName), f.LastWriteTimeUtc, f.Length))
            .ToList();
    }

    /// <summary>Every session transcript, without titles: the overview reads the whole corpus and titles only its top rows.</summary>
    public static List<TranscriptFile> All(string root) =>
        !Directory.Exists(root) ? [] : Directory.EnumerateDirectories(root)
            .SelectMany(d => new DirectoryInfo(d).EnumerateFiles("*.jsonl"))
            .Select(f => new TranscriptFile(f.FullName, System.IO.Path.GetFileNameWithoutExtension(f.Name),
                null, null, f.LastWriteTimeUtc, f.Length))
            .ToList();

    public static string? Find(string root, string sessionId) =>
        Directory.Exists(root)
            ? Directory.EnumerateDirectories(root).Select(d => System.IO.Path.Combine(d, sessionId + ".jsonl")).FirstOrDefault(File.Exists)
            : null;

    /// <summary>/rename's custom-title, else the CLI's ai-title; both are re-appended near the tail.</summary>
    public static string? Title(string path)
    {
        try
        {
            using var s = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            s.Seek(Math.Max(0, s.Length - TailBytes), SeekOrigin.Begin);
            var buffer = new byte[s.Length - s.Position];
            s.ReadExactly(buffer);
            var tail = Encoding.UTF8.GetString(buffer);
            string? Last(Regex r) => r.Matches(tail) is { Count: > 0 } m ? Regex.Unescape(m[^1].Groups[1].Value) : null;
            return Last(CustomTitle()) ?? Last(AiTitle());
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }

    [GeneratedRegex("""
        "customTitle":"((?:[^"\\]|\\.)*)"
        """)]
    private static partial Regex CustomTitle();

    [GeneratedRegex("""
        "aiTitle":"((?:[^"\\]|\\.)*)"
        """)]
    private static partial Regex AiTitle();
}
