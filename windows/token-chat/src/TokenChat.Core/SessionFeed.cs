using System.Text.Json;
using System.Text.Json.Nodes;

namespace TokenChat.Core;

/// <summary>One collect of token-sessions.sh --json: its constants (bands, budgets), plan limits and live sessions by id.</summary>
public sealed record FeedSnapshot(DateTimeOffset Generated, JsonObject Constants, JsonObject? Limits,
    IReadOnlyDictionary<string, JsonObject> Sessions)
{
    public static FeedSnapshot? Parse(string json)
    {
        try
        {
            if (JsonNode.Parse(json) is not JsonObject root || root["sessions"] is not JsonArray list) return null;
            var sessions = new Dictionary<string, JsonObject>(StringComparer.OrdinalIgnoreCase);
            foreach (var s in list.OfType<JsonObject>())
                if (s["sid"] is JsonValue v && v.TryGetValue(out string? sid)) sessions[sid] = s;
            var generated = root["generated"] is JsonValue g && g.TryGetValue(out long unix) ? unix : 0;
            return new FeedSnapshot(DateTimeOffset.FromUnixTimeSeconds(generated), root["constants"] as JsonObject ?? [],
                root["limits"] as JsonObject, sessions);
        }
        catch (JsonException) { return null; }
    }
}

/// <summary>The token widget's last collect, which it replaces whole at ~/.claude/token-sessions.json after every
/// refresh. One watcher for the app, never a poll per tab; tabs look their session up by id, so the footer shows the
/// widget's own figures rather than a second computation of them. Nothing here while the widget isn't running.</summary>
public sealed class SessionFeed : IDisposable
{
    const int SettleMs = 150;

    public static string DefaultPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "token-sessions.json");

    readonly string _path;
    readonly FileSystemWatcher? _watcher;
    readonly Timer _settle;

    public FeedSnapshot? Snapshot { get; private set; }
    /// <summary>Raised on a thread-pool thread after a new snapshot lands.</summary>
    public event Action? Changed;

    public SessionFeed(string? path = null)
    {
        _path = path ?? DefaultPath;
        _settle = new Timer(_ => Reload());
        Snapshot = Read(_path);
        var dir = Path.GetDirectoryName(_path)!;
        if (!Directory.Exists(dir)) return;
        _watcher = new FileSystemWatcher(dir, Path.GetFileName(_path))
        {
            NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.Size,
        };
        // the widget writes beside and swaps in, which arrives as a burst of events
        FileSystemEventHandler poke = (_, _) => _settle.Change(SettleMs, Timeout.Infinite);
        _watcher.Changed += poke;
        _watcher.Created += poke;
        _watcher.Renamed += (_, _) => _settle.Change(SettleMs, Timeout.Infinite);
        _watcher.EnableRaisingEvents = true;
    }

    public JsonObject? Session(string? sid) =>
        sid is not null && Snapshot?.Sessions.TryGetValue(sid, out var s) == true ? s : null;

    void Reload()
    {
        // a half-swapped or unreadable file keeps the last good snapshot
        if (Read(_path) is not { } next) return;
        Snapshot = next;
        Changed?.Invoke();
    }

    public static FeedSnapshot? Read(string path)
    {
        try
        {
            using var s = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var r = new StreamReader(s);
            return FeedSnapshot.Parse(r.ReadToEnd());
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }

    public void Dispose()
    {
        _watcher?.Dispose();
        _settle.Dispose();
    }
}
