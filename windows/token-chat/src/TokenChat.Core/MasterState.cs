using System.Text.Json;
using System.Text.Json.Nodes;
using TokenChat.Core.Protocol;

namespace TokenChat.Core;

/// <summary>Master plan mode (commands/master.md): ~/.claude/token-master/&lt;sid&gt;.json, written by token-master.js and
/// by the caption's pills. Live keeps the window warm for good: token-sessions.sh reads <c>"live": true</c> from the same
/// file and never runs its marks out. A delegate names its master in its park header (master=).</summary>
public sealed record MasterState(string Sid, bool Live, string? Plan, IReadOnlyList<string> Delegates, string? HandedFrom = null,
    IReadOnlyList<string>? Lineage = null)
{
    public static readonly string Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "token-master");
    public static readonly string AnswersDir = Path.Combine(Dir, "answers");

    static string FileOf(string sid) => Path.Combine(Dir, sid + ".json");

    /// <summary>Null when the session is not a master, or its file will not read.</summary>
    public static MasterState? Load(string sid)
    {
        if (Read(sid) is not { } o) return null;
        return new(sid, Json.Bool(o["live"]), Json.Str(o["plan"]),
            (o["delegates"] as JsonArray ?? []).Select(d => Json.Str(d)).OfType<string>().ToList(), Json.Str(o["handedFrom"]),
            (o["lineage"] as JsonArray ?? []).Select(d => Json.Str(d)).OfType<string>().ToList());
    }

    /// <summary>Every earlier sid of this master: the lineage token-master.js handover keeps, plus the one handedFrom of a
    /// file written before it did.</summary>
    public IEnumerable<string> Held => (Lineage ?? []).Concat(HandedFrom is null ? [] : [HandedFrom]).Distinct(StringComparer.OrdinalIgnoreCase);

    /// <summary>True for this master's own sid and for any sid it took over, however many handovers ago.</summary>
    public bool Holds(string? sid) =>
        sid is { Length: > 0 } && (string.Equals(sid, Sid, StringComparison.OrdinalIgnoreCase) || Held.Contains(sid, StringComparer.OrdinalIgnoreCase));

    /// <summary>The master now holding a sid's plan (token-master.js resolve), read from the folder so it works with no tab
    /// open and after a TokenChat restart; null when no master lists it.</summary>
    public static MasterState? Resolve(string? sid) => Resolve(sid, All());

    /// <summary>Its own file wins over a lineage entry, so a sid that is a master itself never resolves elsewhere.</summary>
    public static MasterState? Resolve(string? sid, IEnumerable<MasterState> masters)
    {
        if (sid is not { Length: > 0 }) return null;
        var list = masters.ToList();
        return list.FirstOrDefault(m => string.Equals(m.Sid, sid, StringComparison.OrdinalIgnoreCase)) ?? list.FirstOrDefault(m => m.Holds(sid));
    }

    static IEnumerable<MasterState> All()
    {
        string[] files;
        try { files = Directory.Exists(Dir) ? Directory.GetFiles(Dir, "*.json") : []; }
        catch (IOException) { yield break; }
        foreach (var f in files)
            if (Load(Path.GetFileNameWithoutExtension(f)) is { } m) yield return m;
    }

    /// <summary>On creates the file (not live, no plan yet: /master on fills that in); off deletes it.</summary>
    public static void SetMaster(string sid, bool on)
    {
        if (!on) { try { File.Delete(FileOf(sid)); } catch (IOException) { } return; }
        if (Read(sid) is not null) return;
        Write(sid, new JsonObject
        {
            ["sid"] = sid, ["master"] = true, ["live"] = false, ["plan"] = null, ["delegates"] = new JsonArray(),
            ["since"] = DateTime.UtcNow.ToString("o"),
        });
    }

    /// <summary>False when the session is not a master.</summary>
    public static bool SetLive(string sid, bool live)
    {
        if (Read(sid) is not { } o) return false;
        o["live"] = live;
        o["liveSince"] = live ? DateTime.UtcNow.ToString("o") : null;
        Write(sid, o);
        return true;
    }

    /// <summary>The same file token-master.js answer writes; the delegate's tab picks it up through <see cref="MasterAnswers"/>.</summary>
    public static void WriteAnswer(string slug, string masterSid, string text)
    {
        Directory.CreateDirectory(AnswersDir);
        WriteAtomic(Path.Combine(AnswersDir, slug + ".json"),
            new JsonObject { ["slug"] = slug, ["master"] = masterSid, ["text"] = text, ["at"] = DateTime.UtcNow.ToString("o") });
    }

    /// <summary>What a text answer means for each question: an option label it names (case aside) or the text itself, which
    /// AskUserQuestion takes as a typed answer. Several questions take "a | b | c" in order; one text answers all.</summary>
    public static Dictionary<string, string> AnswersFor(IReadOnlyList<Question> questions, string text)
    {
        var parts = text.Split(" | ");
        if (parts.Length != questions.Count) parts = [.. questions.Select(_ => text)];
        var answers = new Dictionary<string, string>();
        for (var i = 0; i < questions.Count; i++)
        {
            var t = parts[i].Trim();
            answers[questions[i].Text] = questions[i].Options.FirstOrDefault(o => o.Label.Equals(t, StringComparison.OrdinalIgnoreCase))?.Label ?? t;
        }
        return answers;
    }

    static JsonObject? Read(string sid)
    {
        try { return File.Exists(FileOf(sid)) ? JsonNode.Parse(File.ReadAllText(FileOf(sid))) as JsonObject : null; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { return null; }
    }

    static void Write(string sid, JsonObject o)
    {
        Directory.CreateDirectory(Dir);
        WriteAtomic(FileOf(sid), o);
    }

    /// <summary>A temp file and a rename, so a watcher or token-sessions.sh never reads half of one.</summary>
    static void WriteAtomic(string path, JsonObject o)
    {
        var tmp = path + "." + Environment.ProcessId + ".tmp";
        File.WriteAllText(tmp, o.ToJsonString(new JsonSerializerOptions { WriteIndented = true }) + "\n");
        File.Move(tmp, path, overwrite: true);
    }
}

/// <summary>An answer to a delegate's question: token-master/answers/&lt;slug&gt;.json.</summary>
public sealed record MasterAnswer(string Path, string Slug, string? Master, string Text)
{
    /// <summary>Taken: the delegate's tab has sent it on.</summary>
    public void Consume()
    {
        try { File.Delete(Path); } catch (IOException) { }
    }
}

/// <summary>One watcher on token-master/answers/ for every tab, as <see cref="DelegateReports"/> is for reports/. Landed fires
/// on a pool thread; files already there when the first tab subscribes fire too (an answer written while TokenChat was
/// closed). The tab that holds the question consumes the file; one no tab holds stays for the next start.</summary>
public static class MasterAnswers
{
    static readonly object Gate = new();
    static FileSystemWatcher? _watcher;
    static event Action<MasterAnswer>? _landed;

    public static event Action<MasterAnswer> Landed
    {
        add { lock (Gate) { _landed += value; Start(); } }
        remove { lock (Gate) _landed -= value; }
    }

    /// <summary>Every answer waiting on disk, for a tab whose question arrives after its answer did.</summary>
    public static IEnumerable<MasterAnswer> Pending()
    {
        string[] files;
        try { files = Directory.Exists(MasterState.AnswersDir) ? Directory.GetFiles(MasterState.AnswersDir, "*.json") : []; }
        catch (IOException) { yield break; }
        foreach (var f in files)
            if (Parse(f) is { } a) yield return a;
    }

    static void Start()
    {
        if (_watcher is not null) return;
        try
        {
            Directory.CreateDirectory(MasterState.AnswersDir);
            _watcher = new FileSystemWatcher(MasterState.AnswersDir, "*.json") { NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName };
            _watcher.Created += (_, e) => OnFile(e.FullPath);
            _watcher.Renamed += (_, e) => OnFile(e.FullPath);
            _watcher.Changed += (_, e) => OnFile(e.FullPath);
            _watcher.EnableRaisingEvents = true;
        }
        catch (IOException) { _watcher = null; }
    }

    static void OnFile(string path)
    {
        if (Parse(path) is not { } a) return;
        Action<MasterAnswer>? h;
        lock (Gate) h = _landed;
        h?.Invoke(a);
    }

    static MasterAnswer? Parse(string path)
    {
        for (var i = 0; i < 5; i++)
        {
            try
            {
                if (!File.Exists(path) || JsonNode.Parse(File.ReadAllText(path)) is not JsonObject o) return null;
                var slug = Json.Str(o["slug"]) ?? System.IO.Path.GetFileNameWithoutExtension(path);
                return Json.Str(o["text"]) is { Length: > 0 } text ? new MasterAnswer(path, slug, Json.Str(o["master"]), text) : null;
            }
            catch (IOException) { Thread.Sleep(100); }
            catch (JsonException) { Thread.Sleep(100); }
        }
        return null;
    }
}

/// <summary>token-master/log/&lt;master sid&gt;.jsonl: every answered delegate question, one <c>{ at, slug, q, options, a, by }</c>
/// row each. A repeat of a logged question is answered from here with no master turn; token-master.js decided prints it
/// for delegates to read before they ask, and handover moves it to the new sid.</summary>
public static class MasterLog
{
    public static readonly string Dir = Path.Combine(MasterState.Dir, "log");

    public static string FileOf(string masterSid) => Path.Combine(Dir, masterSid + ".jsonl");

    public static void Append(string masterSid, string? slug, IReadOnlyList<Question> questions, IReadOnlyDictionary<string, string> answers, string by)
    {
        var rows = new System.Text.StringBuilder();
        foreach (var q in questions)
            if (answers.TryGetValue(q.Text, out var a))
                rows.Append(new JsonObject
                {
                    ["at"] = DateTime.UtcNow.ToString("o"), ["slug"] = slug, ["q"] = q.Text,
                    ["options"] = new JsonArray([.. q.Options.Select(o => (JsonNode?)JsonValue.Create(o.Label))]), ["a"] = a, ["by"] = by,
                }.ToJsonString()).Append('\n');
        try
        {
            Directory.CreateDirectory(Dir);
            File.AppendAllText(FileOf(masterSid), rows.ToString());
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>An answer for every question when each repeats a logged one word for word (case, spacing and punctuation
    /// aside) with the same option labels, the newest row winning; null when any question is new.</summary>
    public static Dictionary<string, string>? Lookup(string masterSid, IReadOnlyList<Question> questions)
    {
        if (questions.Count == 0) return null;
        string[] lines;
        try { lines = File.Exists(FileOf(masterSid)) ? File.ReadAllLines(FileOf(masterSid)) : []; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
        var known = new Dictionary<string, string>();
        foreach (var l in lines)
        {
            try
            {
                if (JsonNode.Parse(l) is not JsonObject o || Json.Str(o["q"]) is not { } q || Json.Str(o["a"]) is not { } a) continue;
                known[Key(q, (o["options"] as JsonArray ?? []).Select(x => Json.Str(x) ?? ""))] = a;
            }
            catch (JsonException) { }
        }
        var answers = new Dictionary<string, string>();
        foreach (var q in questions)
        {
            if (!known.TryGetValue(Key(q.Text, q.Options.Select(o => o.Label)), out var a)) return null;
            answers[q.Text] = a;
        }
        return answers;
    }

    static string Key(string question, IEnumerable<string> options) =>
        string.Join("\u0001", options.Select(Norm).Order().Prepend(Norm(question)));

    static string Norm(string s) =>
        string.Join(' ', new string([.. s.ToLowerInvariant().Select(c => char.IsLetterOrDigit(c) ? c : ' ')])
            .Split(' ', StringSplitOptions.RemoveEmptyEntries));
}
