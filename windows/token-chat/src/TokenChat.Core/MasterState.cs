using System.Text.Json;
using System.Text.Json.Nodes;
using TokenChat.Core.Protocol;

namespace TokenChat.Core;

/// <summary>Master plan mode (commands/master.md): ~/.claude/token-master/&lt;sid&gt;.json, written by token-master.js and
/// by the caption's pills. Live keeps the window warm for good: token-sessions.sh reads <c>"live": true</c> from the same
/// file and never runs its marks out. A delegate names its master in its park header (master=).</summary>
public sealed record MasterState(string Sid, bool Live, string? Plan, IReadOnlyList<string> Delegates, string? HandedFrom = null)
{
    public static readonly string Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "token-master");
    public static readonly string AnswersDir = Path.Combine(Dir, "answers");

    static string FileOf(string sid) => Path.Combine(Dir, sid + ".json");

    /// <summary>Null when the session is not a master, or its file will not read.</summary>
    public static MasterState? Load(string sid)
    {
        if (Read(sid) is not { } o) return null;
        return new(sid, Json.Bool(o["live"]), Json.Str(o["plan"]),
            (o["delegates"] as JsonArray ?? []).Select(d => Json.Str(d)).OfType<string>().ToList(), Json.Str(o["handedFrom"]));
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
