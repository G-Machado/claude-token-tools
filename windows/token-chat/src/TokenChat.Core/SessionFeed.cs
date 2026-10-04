using System.Text.Json;
using System.Text.Json.Nodes;

namespace TokenChat.Core;

/// <summary>One collect of token-sessions.sh --json: its constants (bands, budgets), plan limits and live sessions by id.</summary>
public sealed record FeedSnapshot(DateTimeOffset Generated, JsonObject Constants, JsonObject? Limits,
    IReadOnlyDictionary<string, JsonObject> Sessions)
{
    /// <summary>The sessions in the collector's order, which the widget draws its rows in.</summary>
    public IReadOnlyList<JsonObject> Ordered { get; init; } = [];
    /// <summary>The account-wide figures: grades, spend over five hours, seven days and today.</summary>
    public JsonObject? Overall { get; init; }

    public static FeedSnapshot? Parse(string json)
    {
        try
        {
            if (JsonNode.Parse(json) is not JsonObject root || root["sessions"] is not JsonArray list) return null;
            var sessions = new Dictionary<string, JsonObject>(StringComparer.OrdinalIgnoreCase);
            var ordered = new List<JsonObject>();
            foreach (var s in list.OfType<JsonObject>())
                if (s["sid"] is JsonValue v && v.TryGetValue(out string? sid) && sessions.TryAdd(sid, s)) ordered.Add(s);
            var generated = root["generated"] is JsonValue g && g.TryGetValue(out long unix) ? unix : 0;
            return new FeedSnapshot(DateTimeOffset.FromUnixTimeSeconds(generated), root["constants"] as JsonObject ?? [],
                root["limits"] as JsonObject, sessions) { Ordered = ordered, Overall = root["overall"] as JsonObject };
        }
        catch (JsonException) { return null; }
    }
}

/// <summary>The token widget's last collect, which it replaces whole at ~/.claude/token-sessions.json after every
/// refresh. One watcher for the app, never a poll per tab; tabs look their session up by id, so the sidebar shows the
/// widget's own figures rather than a second computation of them. Given a collect, the app runs one itself whenever
/// the file goes stale, so the widget is optional: while it runs (every 30s) the file never gets that old.</summary>
public sealed class SessionFeed : IDisposable
{
    const int SettleMs = 150;
    const int CheckMs = 15_000;
    /// <summary>Older than this and nobody is collecting: two and a half of the widget's refreshes missed.</summary>
    public static readonly TimeSpan StaleAfter = TimeSpan.FromSeconds(75);

    public static bool IsStale(FeedSnapshot? snapshot, DateTimeOffset now) =>
        snapshot is null || now - snapshot.Generated > StaleAfter;

    public static string DefaultPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "token-sessions.json");

    readonly string _path;
    readonly FileSystemWatcher? _watcher;
    readonly Timer _settle;
    readonly Func<Task<string?>>? _collect;
    readonly Timer? _check;
    int _collecting;

    public FeedSnapshot? Snapshot { get; private set; }
    /// <summary>Raised on a thread-pool thread after a new snapshot lands.</summary>
    public event Action? Changed;

    /// <param name="collect">token-sessions.sh --json's output, or null when it failed; run when the file is stale.</param>
    public SessionFeed(string? path = null, Func<Task<string?>>? collect = null)
    {
        _path = path ?? DefaultPath;
        _settle = new Timer(_ => Reload());
        Snapshot = Read(_path);
        _collect = collect;
        if (collect is not null) _check = new Timer(_ => _ = CollectIfStaleAsync(DateTimeOffset.UtcNow), null, 0, CheckMs);
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

    /// <summary>A control's effect on the last collect at once, the way the widget redraws on the keystroke; the next
    /// collect replaces it with what the script wrote. UI thread.</summary>
    public void Patch(string sid, Action<JsonObject> change)
    {
        if (Session(sid) is not { } s) return;
        change(s);
        Changed?.Invoke();
    }

    /// <summary>One collect at a time; true when it ran and wrote the file. The watcher picks the write up, as it does
    /// the widget's.</summary>
    public async Task<bool> CollectIfStaleAsync(DateTimeOffset now)
    {
        if (_collect is null || !IsStale(Snapshot, now) || Interlocked.Exchange(ref _collecting, 1) == 1) return false;
        try
        {
            // a collect that does not parse is never written over a good file
            if (await _collect() is not { } json || FeedSnapshot.Parse(json) is null) return false;
            Save(_path, json);
            Reload();
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
        finally { Volatile.Write(ref _collecting, 0); }
    }

    /// <summary>The widget's Save-Feed: written beside and swapped in, so a reader never sees half a file. Its own
    /// .tmp name, so a widget saving at the same moment cannot write into this one.</summary>
    static void Save(string path, string json)
    {
        var tmp = path + ".app.tmp";
        File.WriteAllText(tmp, json, new System.Text.UTF8Encoding(false));
        if (File.Exists(path)) File.Replace(tmp, path, null);
        else File.Move(tmp, path);
    }

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
        _check?.Dispose();
        _watcher?.Dispose();
        _settle.Dispose();
    }
}
