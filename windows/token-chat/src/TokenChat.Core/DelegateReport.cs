using System.Text.RegularExpressions;

namespace TokenChat.Core;

/// <summary>The report a /delegate session writes to checkpoints/reports/ when it stops (commands/unpark.md, --delegate).
/// Line 1 is <c>&lt;!-- report: for=&lt;parent sid&gt; sid=&lt;delegate sid&gt; topic= branch= worktree= --&gt;</c>.</summary>
public sealed record DelegateReport(string Path, string For, string? Sid, string? Topic, string? Branch, string? Worktree, IReadOnlyList<string> Done)
{
    static readonly Regex Field = new(@"(\w+)=(\S+)", RegexOptions.Compiled);

    public static readonly string Dir = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "checkpoints", "reports");

    /// <summary>Null unless line 1 is a report header with a for=; Done is the list under a "Done" heading, at most 5.</summary>
    public static DelegateReport? Parse(string path, string text)
    {
        var lines = text.Replace("\r", "").Split('\n');
        if (lines.Length == 0 || !lines[0].TrimStart().StartsWith("<!-- report:", StringComparison.Ordinal)) return null;
        var f = Field.Matches(lines[0]).ToDictionary(m => m.Groups[1].Value, m => m.Groups[2].Value.TrimEnd('-', '>'));
        if (!f.TryGetValue("for", out var parent) || parent.Length == 0) return null;
        var done = new List<string>();
        var inDone = false;
        foreach (var raw in lines.Skip(1))
        {
            var l = raw.Trim();
            if (l.StartsWith('#') || (l.StartsWith("**") && l.EndsWith("**")))
            {
                if (inDone) break;
                inDone = l.Trim('#', '*', ' ').StartsWith("Done", StringComparison.OrdinalIgnoreCase);
                continue;
            }
            if (inDone && l.StartsWith("- ") && done.Count < 5) done.Add(l[2..].Replace("[x] ", "").Replace("[ ] ", ""));
        }
        return new DelegateReport(path, parent, f.GetValueOrDefault("sid"), f.GetValueOrDefault("topic"),
            f.GetValueOrDefault("branch"), f.GetValueOrDefault("worktree"), done);
    }

    /// <summary>Raw events for later fact-checking (open / report / card / read / dismiss), one TSV row each:
    /// time, event, topic, parent sid, delegate sid, extra. token-unpark-new.ps1 writes "open" to the same file.</summary>
    public static readonly string LogPath = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "token-delegate.log");

    /// <summary>The parent sid in the newest <c>&lt;proj&gt;.&lt;topic&gt;.md</c> checkpoint's park header (delegate-of=),
    /// null when there is none or no file reads.</summary>
    public static string? ParentOf(string topic) => HeaderField(topic, "delegate-of");

    /// <summary>A <c>name=value</c> from the park header of the newest <c>&lt;proj&gt;.&lt;topic&gt;.md</c> that has it:
    /// delegate-of=, or master= on a master's delegate (commands/delegate.md).</summary>
    public static string? HeaderField(string topic, string name)
    {
        var field = new Regex(@"(?:^|\s)" + Regex.Escape(name) + @"=([^\s>-][^\s>]*)");
        try
        {
            var dir = System.IO.Path.GetDirectoryName(Dir)!;
            foreach (var f in new DirectoryInfo(dir).GetFiles("*." + topic + ".md").OrderByDescending(f => f.LastWriteTimeUtc))
            {
                using var r = f.OpenText();
                if (field.Match(r.ReadLine() ?? "") is { Success: true } m) return m.Groups[1].Value;
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        return null;
    }

    public static void Log(string evt, string? topic, string? parent, string? sid, string? extra = null)
    {
        try { File.AppendAllText(LogPath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss}\t{evt}\t{topic}\t{parent}\t{sid}\t{extra}\n"); }
        catch (IOException) { }
    }
}

/// <summary>One watcher on checkpoints/reports/ for every tab; Landed fires (on a pool thread) once per report path
/// per process, after logging a "report" event.</summary>
public static class DelegateReports
{
    static readonly HashSet<string> Seen = new(StringComparer.OrdinalIgnoreCase);
    static FileSystemWatcher? _watcher;
    static event Action<DelegateReport>? _landed;

    public static event Action<DelegateReport> Landed
    {
        add { lock (Seen) { _landed += value; Start(); } }
        remove { lock (Seen) _landed -= value; }
    }

    static void Start()
    {
        if (_watcher is not null) return;
        try
        {
            Directory.CreateDirectory(DelegateReport.Dir);
            _watcher = new FileSystemWatcher(DelegateReport.Dir, "*.md") { NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName };
            _watcher.Created += (_, e) => OnFile(e.FullPath);
            _watcher.Changed += (_, e) => OnFile(e.FullPath);
            _watcher.Renamed += (_, e) => OnFile(e.FullPath);
            _watcher.EnableRaisingEvents = true;
        }
        catch (IOException) { _watcher = null; }
    }

    static void OnFile(string path)
    {
        // The writer may still hold it: a few short retries, then give up until the next change event.
        string? text = null;
        for (var i = 0; i < 5 && text is null; i++)
        {
            try { text = File.ReadAllText(path); }
            catch (IOException) { Thread.Sleep(100); }
        }
        if (text is null || DelegateReport.Parse(path, text) is not { } r) return;
        Action<DelegateReport>? h;
        lock (Seen)
        {
            if (!Seen.Add(path)) return;
            h = _landed;
        }
        DelegateReport.Log("report", r.Topic, r.For, r.Sid, r.Branch);
        h?.Invoke(r);
    }
}
