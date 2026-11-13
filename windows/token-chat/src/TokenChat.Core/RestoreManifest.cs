using System.Text.Json;

namespace TokenChat.Core;

/// <summary>One open tab as it was when TokenChat closed for an update or restart: enough to open it again in the same
/// place, on the same model, effort and permission mode, with the unsent draft and its master link back.
/// Sid null (or a sid with no transcript yet: no first prompt) reopens as a fresh session in the same folder.</summary>
public sealed record RestoreTab(string Cwd, string? Sid = null, bool Lite = false, string? Model = null, string? Effort = null,
    string? Mode = null, string? Draft = null, string? Topic = null, string? MasterSid = null, bool Locked = false);

/// <summary>~/.claude/tokenchat-restore.json, written by the app just before it closes for an update; the relaunch
/// (<c>--restore</c>, or any plain launch while it is still pending) reopens every tab in order and moves the file to
/// tokenchat-restore.last.json, so a crash between the two still comes back on the next start, and only once.</summary>
public sealed record RestoreManifest(DateTimeOffset Created, IReadOnlyList<RestoreTab> Tabs, int Current = 0, bool Maximized = false,
    string Reason = "restart")
{
    public static string DefaultPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "tokenchat-restore.json");

    /// <summary>Where a restored manifest goes; kept for the record (which sessions came back from what).</summary>
    public static string DonePath(string path) => Path.ChangeExtension(path, ".last.json");

    /// <summary>A pending manifest older than this is set aside unrestored: sessions from days ago are not what a plain
    /// launch should bring back.</summary>
    public static readonly TimeSpan MaxAge = TimeSpan.FromDays(2);

    public void Save(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(this, Options));
        File.Move(tmp, path, overwrite: true);
    }

    public static RestoreManifest? Load(string path)
    {
        try { return File.Exists(path) ? JsonSerializer.Deserialize<RestoreManifest>(File.ReadAllText(path)) : null; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { return null; }
    }

    /// <summary>The manifest still waiting to be restored, or null; one past <see cref="MaxAge"/> is set aside.</summary>
    public static string? Pending(string path, DateTimeOffset now)
    {
        if (Load(path) is not { } m) return null;
        if (now - m.Created <= MaxAge) return path;
        MarkDone(path);
        return null;
    }

    /// <summary>Restored: out of the way, so the next launch does not reopen the same sessions a second time.</summary>
    public static void MarkDone(string path)
    {
        try { if (File.Exists(path)) File.Move(path, DonePath(path), overwrite: true); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>claude --resume needs the transcript: ~/.claude/projects/&lt;project&gt;/&lt;sid&gt;.jsonl, written from the first
    /// prompt on. A tab that never sent one has a sid but nothing to resume.</summary>
    public static bool TranscriptExists(string sid, string? projectsDir = null)
    {
        projectsDir ??= Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "projects");
        try
        {
            return Directory.Exists(projectsDir)
                && Directory.EnumerateDirectories(projectsDir).Any(d => File.Exists(Path.Combine(d, sid + ".jsonl")));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
    }

    static readonly JsonSerializerOptions Options = new() { WriteIndented = true };
}
