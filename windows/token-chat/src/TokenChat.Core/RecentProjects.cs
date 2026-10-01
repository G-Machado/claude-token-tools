using System.Text.Json;
using System.Text.Json.Nodes;

namespace TokenChat.Core;

public sealed record RecentProject(string Path, DateTime LastUsedUtc)
{
    public string Name => System.IO.Path.GetFileName(Path.TrimEnd('\\', '/')) is { Length: > 0 } n ? n : Path;
}

/// <summary>Folders claude has run in, newest first, from ~/.claude/projects. Each project dir's newest transcript
/// gives the time (its mtime) and the real path (its cwd field, by about line 6; the dir name is lossy).
/// Headless sessions write transcripts too, so token-chat's own tabs count.</summary>
public static class RecentProjects
{
    const int HeadLines = 50;

    public static string DefaultRoot =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "projects");

    /// <summary>Scratchpads and other temp folders, and folders that no longer exist, are left out.</summary>
    public static List<RecentProject> Load(string root, int max = 12)
    {
        if (!Directory.Exists(root)) return [];
        var temp = Path.GetFullPath(Path.GetTempPath());
        var byPath = new Dictionary<string, RecentProject>(StringComparer.OrdinalIgnoreCase);
        foreach (var dir in Directory.EnumerateDirectories(root))
        {
            var newest = new DirectoryInfo(dir).EnumerateFiles("*.jsonl").MaxBy(f => f.LastWriteTimeUtc);
            if (newest is null || Cwd(newest.FullName) is not { } cwd) continue;
            if (cwd.StartsWith(temp, StringComparison.OrdinalIgnoreCase) || !Directory.Exists(cwd)) continue;
            if (!byPath.TryGetValue(cwd, out var seen) || seen.LastUsedUtc < newest.LastWriteTimeUtc)
                byPath[cwd] = new RecentProject(cwd, newest.LastWriteTimeUtc);
        }
        return byPath.Values.OrderByDescending(p => p.LastUsedUtc).Take(max).ToList();
    }

    static string? Cwd(string transcript)
    {
        try
        {
            // a live session may be appending to it
            using var s = new FileStream(transcript, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var r = new StreamReader(s);
            for (var i = 0; i < HeadLines && r.ReadLine() is { } line; i++)
            {
                if (!line.Contains("\"cwd\":")) continue;
                try
                {
                    if (JsonNode.Parse(line)?["cwd"] is JsonValue v && v.TryGetValue(out string? cwd) && cwd.Length > 0) return cwd;
                }
                catch (JsonException) { }
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        return null;
    }
}
