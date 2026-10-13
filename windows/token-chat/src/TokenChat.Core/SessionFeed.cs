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

/// <summary>The last collect at ~/.claude/token-sessions.json, replaced whole by whoever ran it. One watcher for the
/// app, never a poll per tab; tabs look their session up by id. Given a collect, the app keeps the file fresh itself
/// on its own cadence (a start every 20s), and stands down only while collects it did not write keep landing,
/// so the widget is optional and the two never collect side by side: duplicate collectors are what slowed a collect
/// from six seconds to 140 (token-widget.ps1, 2026-09-03).</summary>
public sealed class SessionFeed : IDisposable
{
    const int SettleMs = 150;
    const int CheckMs = 5_000;
    /// <summary>Between the starts of two of the app's collects. Tighter than the widget's 30s $Every; a collect takes
    /// ~21s, so this keeps one running nearly all the time.</summary>
    public static readonly TimeSpan Every = TimeSpan.FromSeconds(20);
    /// <summary>Longer than this since a collect the app did not write landed and nobody else is collecting: one and a
    /// half of the widget's refreshes missed.</summary>
    public static readonly TimeSpan OtherQuiet = TimeSpan.FromSeconds(45);

    public static string DefaultPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "token-sessions.json");

    readonly string _path;
    readonly FileSystemWatcher? _watcher;
    readonly Timer _settle;
    readonly Func<Task<string?>>? _collect;
    readonly Timer? _check;
    int _collecting;
    DateTimeOffset _startedAt = DateTimeOffset.MinValue;
    DateTimeOffset _otherAt = DateTimeOffset.MinValue;
    /// <summary>`generated` of the last collect the app wrote, so its own write coming back through the watcher is not
    /// taken for someone else collecting.</summary>
    long _mine = long.MinValue;

    public FeedSnapshot? Snapshot { get; private set; }
    /// <summary>Raised on a thread-pool thread after a new snapshot lands.</summary>
    public event Action? Changed;

    /// <param name="collect">token-sessions.sh --json's output, or null when it failed; run on the cadence.</param>
    /// <param name="usageDir">session-usage/, read between collects for every window's live context and cache clock.</param>
    public SessionFeed(string? path = null, Func<Task<string?>>? collect = null, string? usageDir = null)
    {
        _path = path ?? DefaultPath;
        _settle = new Timer(_ => Reload());
        Snapshot = Read(_path);
        // a file written moments ago may be a running widget's: give it the quiet period before collecting over it
        if (Snapshot is not null) _otherAt = new DateTimeOffset(File.GetLastWriteTimeUtc(_path), TimeSpan.Zero);
        _collect = collect;
        if (collect is not null) _check = new Timer(_ => _ = CollectIfDueAsync(DateTimeOffset.UtcNow), null, 0, CheckMs);
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
        if (usageDir is null || !Directory.Exists(usageDir)) return;
        _usageDir = usageDir;
        _usageSettle = new Timer(_ => ReadUsage());
        _usageWatcher = new FileSystemWatcher(usageDir, "*.json") { NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName };
        FileSystemEventHandler usage = (_, _) => _usageSettle.Change(SettleMs, Timeout.Infinite);
        _usageWatcher.Changed += usage;
        _usageWatcher.Created += usage;
        _usageWatcher.Renamed += (_, _) => _usageSettle.Change(SettleMs, Timeout.Infinite);
        _usageWatcher.EnableRaisingEvents = true;
    }

    // ----- live usage: the widget's Live-Tick -----

    string? _usageDir;
    FileSystemWatcher? _usageWatcher;
    Timer? _usageSettle;
    /// <summary>Per session: the payload's mtime and what it said, so an untouched file is one stat.</summary>
    readonly Dictionary<string, (DateTime At, double Context, long Expires)> _usage = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>A window's status line (or a TokenChat tab) rewrites session-usage/&lt;sid&gt;.json on every request,
    /// so its context and cache expiry move seconds after a turn rather than a collect later. Overlaid on the last
    /// collect; the cache clock as minutes left at <see cref="FeedSnapshot.Generated"/>, which is how its readers run it
    /// down.</summary>
    void ReadUsage()
    {
        if (_usageDir is null || Snapshot is not { } snap) return;
        var moved = false;
        lock (_usage)
            foreach (var (sid, s) in snap.Sessions)
            {
                var f = Path.Combine(_usageDir, sid + ".json");
                DateTime at;
                try { if (!File.Exists(f)) continue; at = File.GetLastWriteTimeUtc(f); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { continue; }
                if (_usage.TryGetValue(sid, out var seen) && seen.At == at) continue;
                if (ParseUsage(f) is not { } u) continue;
                _usage[sid] = (at, u.Context, u.Expires);
                moved |= Overlay(s, at, u.Context, u.Expires, snap.Generated);
            }
        if (moved) Changed?.Invoke();
    }

    /// <summary>Only a payload newer than the collect, and only what it changes: the context, and the cache clock
    /// when a request has pushed the expiry on.</summary>
    public static bool Overlay(JsonObject s, DateTime at, double context, long expires, DateTimeOffset generated)
    {
        if (at <= generated.UtcDateTime || context <= 0) return false;
        var k = Math.Round(context / 1000, 1);
        var changed = Num(s, "context_k") != k;
        s["context"] = context;
        s["context_k"] = k;
        if (expires > 0)
        {
            var left = (int)Math.Max(0, Math.Floor((expires - generated.ToUnixTimeSeconds()) / 60.0));
            changed |= Num(s, "cache_left_min") != left;
            s["cache_left_min"] = left;
        }
        return changed;
    }

    static double Num(JsonObject s, string key) =>
        s[key] is JsonValue v && double.TryParse(v.ToString(), System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture, out var d) ? d : double.NaN;

    static (double Context, long Expires)? ParseUsage(string path)
    {
        try
        {
            using var f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            if (JsonNode.Parse(f) is not JsonObject o) return null;
            var ctx = o["context_window"]?["total_input_tokens"] is JsonValue c && c.TryGetValue(out double d) ? d : 0;
            var exp = o["prompt_cache"]?["expires_at"] is JsonValue e && e.TryGetValue(out long x) ? x : 0;
            return (ctx, exp);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { return null; }
    }

    /// <summary>A new collect: the payloads already read that are newer than it go back on.</summary>
    void ReapplyUsage(FeedSnapshot next)
    {
        lock (_usage)
            foreach (var (sid, u) in _usage)
                if (next.Sessions.TryGetValue(sid, out var s)) Overlay(s, u.At, u.Context, u.Expires, next.Generated);
    }

    public JsonObject? Session(string? sid) =>
        sid is not null && Snapshot?.Sessions.TryGetValue(sid, out var s) == true ? s : null;

    sealed class Pending(string sid, Action<JsonObject> change)
    {
        public readonly string Sid = sid;
        public readonly Action<JsonObject> Change = change;
        public readonly DateTimeOffset Made = DateTimeOffset.UtcNow;
        public DateTimeOffset? Done;
    }

    static readonly TimeSpan PatchLimit = TimeSpan.FromMinutes(5);
    readonly List<Pending> _pending = [];

    /// <summary>A control's effect on the last collect at once, the way the widget redraws on the keystroke. Kept until
    /// a collect stamped after the script call returned arrives: one already running when the click landed read the
    /// state file before the write, and would put the old count back for a whole collect. Call the returned action
    /// when the script call has finished, whether it worked or not. UI thread.</summary>
    public Action Patch(string sid, Action<JsonObject> change)
    {
        var p = new Pending(sid, change);
        lock (_pending) _pending.Add(p);
        if (Session(sid) is { } s)
        {
            change(s);
            Changed?.Invoke();
        }
        return () => { lock (_pending) p.Done = DateTimeOffset.UtcNow; };
    }

    /// <summary>Re-applies the patches this collect cannot have seen, in the order they were made, and forgets the rest.
    /// `generated` is whole seconds, floored, and stamped just before the state file is read, so a collect stamped at or
    /// after the call's end read what it wrote.</summary>
    void Reapply(FeedSnapshot next)
    {
        lock (_pending)
        {
            _pending.RemoveAll(p => p.Done is { } done && next.Generated >= done
                || DateTimeOffset.UtcNow - p.Made > PatchLimit);
            foreach (var p in _pending)
                if (next.Sessions.TryGetValue(p.Sid, out var s)) p.Change(s);
        }
    }

    /// <summary>Due when the last start was a cadence ago and no other writer has landed a collect within the quiet
    /// period.</summary>
    public bool IsDue(DateTimeOffset now) => now - _startedAt >= Every && now - _otherAt > OtherQuiet;

    /// <summary>Something the last collect cannot know about changed (an account switch): collect at the next check
    /// rather than a cadence from the last start. Still stands down while another writer is landing collects.</summary>
    public void Soon() => _startedAt = DateTimeOffset.MinValue;

    /// <summary>One collect at a time; true when it ran and wrote the file. A failed one waits out the cadence like
    /// any other.</summary>
    public async Task<bool> CollectIfDueAsync(DateTimeOffset now)
    {
        if (_collect is null || !IsDue(now) || Interlocked.Exchange(ref _collecting, 1) == 1) return false;
        try
        {
            _startedAt = now;
            // a collect that does not parse is never written over a good file
            if (await _collect() is not { } json || FeedSnapshot.Parse(json) is not { } parsed) return false;
            _mine = parsed.Generated.ToUnixTimeSeconds();
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
        var stamp = next.Generated.ToUnixTimeSeconds();
        if (stamp != _mine && stamp != Snapshot?.Generated.ToUnixTimeSeconds()) _otherAt = DateTimeOffset.UtcNow;
        Reapply(next);
        ReapplyUsage(next);
        Snapshot = next;
        Changed?.Invoke();
        // a session new to this collect may have a payload nobody has read yet
        if (_usageSettle is not null) _usageSettle.Change(SettleMs, Timeout.Infinite);
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
        _usageWatcher?.Dispose();
        _usageSettle?.Dispose();
        _settle.Dispose();
    }
}
