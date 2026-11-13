using System.Diagnostics;
using System.Globalization;
using System.Text.Json;

namespace TokenChat.Core;

/// <summary>What a fetch found in the clone TokenChat runs from: commits on the upstream it has not pulled, and what
/// would stop a fast-forward pull. Error is set when the check itself failed (no git, no network, no upstream).</summary>
public sealed record UpdateStatus(string Repo, string Upstream, string UpstreamSha, int Behind, int Ahead,
    IReadOnlyList<string> Commits, IReadOnlyList<string> Conflicts, IReadOnlyList<string> LiveDrift, string? Error = null,
    bool AppChanged = false)
{
    /// <summary>TokenChat's own sources change: only a rebuild and restart takes those. Scripts and commands alone are
    /// a pull and install.sh, with the app left running.</summary>
    public static bool TouchesApp(IEnumerable<string> files) =>
        files.Any(f => f.StartsWith("windows/token-chat/src/", StringComparison.OrdinalIgnoreCase));

    public bool Available => Error is null && Behind > 0;

    /// <summary>Why the update cannot be taken from the app (a pull by hand can), or null.</summary>
    public string? Blocker =>
        Ahead > 0 ? $"this clone has {Ahead} commit{(Ahead == 1 ? "" : "s")} not on {Upstream}: a fast-forward pull is not possible"
        : Conflicts.Count > 0 ? $"uncommitted changes in {string.Join(", ", Conflicts.Take(5))}{(Conflicts.Count > 5 ? ", ..." : "")} would be overwritten by the pull"
        : null;

    public static UpdateStatus Failed(string repo, string error) => new(repo, "", "", 0, 0, [], [], [], error);
}

/// <summary>~/.claude/tokenchat-update.json: when the last check ran (at most one a day), and the upstream commit the
/// user said "later" to, so the same update is not offered again until the next day's check.</summary>
public sealed class UpdateState
{
    public static string DefaultPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "tokenchat-update.json");

    public DateTimeOffset LastCheck { get; set; }
    public string? SnoozedSha { get; set; }
    public DateTimeOffset SnoozedAt { get; set; }

    public static readonly TimeSpan Every = TimeSpan.FromHours(24);

    public bool Due(DateTimeOffset now) => now - LastCheck >= Every;

    /// <summary>"Later" holds for this upstream commit until a day has passed; a newer commit is offered at once.</summary>
    public bool Snoozed(string sha, DateTimeOffset now) => sha.Length > 0 && SnoozedSha == sha && now - SnoozedAt < Every;

    public static UpdateState Load(string path)
    {
        try
        {
            if (File.Exists(path) && JsonSerializer.Deserialize<UpdateState>(File.ReadAllText(path)) is { } s) return s;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { }
        return new();
    }

    public void Save(string path)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, JsonSerializer.Serialize(this));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}

/// <summary>The daily update check: git fetch in the claude-token-tools clone, then how far behind its upstream it is,
/// whether the pull can fast-forward, and which live ~/.claude files install.sh would replace (a hot-fix made there
/// and never copied back to the repo). Read-only: nothing is pulled here, update.ps1 does that.</summary>
public static class AppUpdate
{
    static readonly string Claude = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude");

    /// <summary>The clone install.sh recorded in ~/.claude/token-tools-src, else the one this exe was built in.</summary>
    public static string? FindRepo(string? baseDir = null, string? srcFile = null)
    {
        srcFile ??= Path.Combine(Claude, "token-tools-src");
        try
        {
            if (File.Exists(srcFile) && File.ReadLines(srcFile).FirstOrDefault()?.Trim() is { Length: > 0 } recorded
                && WindowsPath(recorded) is var dir && Directory.Exists(Path.Combine(dir, ".git"))
                && File.Exists(Path.Combine(dir, "windows", "token-chat", "update.ps1")))
                return dir;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        for (var d = new DirectoryInfo(baseDir ?? AppContext.BaseDirectory); d is not null; d = d.Parent)
            if (Directory.Exists(Path.Combine(d.FullName, ".git")) && File.Exists(Path.Combine(d.FullName, "install.sh")))
                return d.FullName;
        return null;
    }

    /// <summary>install.sh writes the clone as Git Bash sees it: /c/Users/... is C:\Users\...</summary>
    public static string WindowsPath(string p) =>
        p.Length >= 3 && p[0] == '/' && char.IsLetter(p[1]) && p[2] == '/'
            ? char.ToUpperInvariant(p[1]) + ":" + p[2..].Replace('/', '\\')
            : p.Replace('/', '\\');

    public static async Task<UpdateStatus> CheckAsync(string repo, CancellationToken ct = default)
    {
        var (code, output) = await GitAsync(repo, ["fetch", "--quiet", "origin"], TimeSpan.FromSeconds(60), ct);
        if (code != 0) return UpdateStatus.Failed(repo, "git fetch failed: " + LastLine(output));
        (code, var upstream) = await GitAsync(repo, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], ct: ct);
        if (code != 0) return UpdateStatus.Failed(repo, "the current branch has no upstream");
        upstream = upstream.Trim();
        var (_, sha) = await GitAsync(repo, ["rev-parse", "@{u}"], ct: ct);
        var (_, counts) = await GitAsync(repo, ["rev-list", "--left-right", "--count", "HEAD...@{u}"], ct: ct);
        var (ahead, behind) = ParseCounts(counts);
        if (behind == 0) return new(repo, upstream, sha.Trim(), 0, ahead, [], [], []);
        var (_, log) = await GitAsync(repo, ["log", "--format=%h %s", "--max-count=12", "HEAD..@{u}"], ct: ct);
        var (_, incoming) = await GitAsync(repo, ["diff", "--name-only", "HEAD", "@{u}"], ct: ct);
        var (_, status) = await GitAsync(repo, ["status", "--porcelain", "--untracked-files=no"], ct: ct);
        var drift = await LiveDriftAsync(repo, ct);
        var files = Lines(incoming);
        return new(repo, upstream, sha.Trim(), behind, ahead, Lines(log), Conflicts(status, files), drift,
            AppChanged: UpdateStatus.TouchesApp(files));
    }

    /// <summary>An update that leaves TokenChat's sources alone: git pull --ff-only, then install.sh, in the running app.
    /// The text is the outcome in one line, then detail.</summary>
    public static async Task<(bool Ok, string Text)> PullAndInstallAsync(string repo, CancellationToken ct = default)
    {
        var (code, output) = await GitAsync(repo, ["pull", "--ff-only"], TimeSpan.FromSeconds(120), ct);
        if (code != 0) return (false, "git pull failed - nothing was installed\n" + output.Trim());
        var (_, head) = await GitAsync(repo, ["log", "-1", "--format=%h %s"], ct: ct);
        if (SessionControl.FindBash() is not { } bash) return (false, $"pulled to {head.Trim()}, but Git Bash was not found to run install.sh");
        (code, output) = await RunAsync(bash, ["-lc", "bash \"$1\" 2>&1", "install", Path.Combine(repo, "install.sh").Replace('\\', '/')],
            repo, TimeSpan.FromSeconds(120), ct);
        var replaced = Lines(output).Count(l => l.TrimStart().StartsWith("backup ", StringComparison.Ordinal));
        return code == 0
            ? (true, $"ok: updated to {head.Trim()}, installed" + (replaced > 0 ? $" ({replaced} live file{(replaced == 1 ? "" : "s")} replaced, .bak kept)" : ""))
            : (false, $"pulled to {head.Trim()}, but install.sh failed (exit {code})\n" + string.Join("\n", Lines(output).TakeLast(8)));
    }

    /// <summary>rev-list --left-right --count HEAD...@{u}: "ahead\tbehind".</summary>
    public static (int Ahead, int Behind) ParseCounts(string s)
    {
        var parts = s.Split(['\t', ' '], StringSplitOptions.RemoveEmptyEntries);
        return parts.Length == 2 && int.TryParse(parts[0], CultureInfo.InvariantCulture, out var a)
            && int.TryParse(parts[1], CultureInfo.InvariantCulture, out var b) ? (a, b) : (0, 0);
    }

    /// <summary>Files changed in the working tree (status --porcelain) that the pull would also change: git refuses those.</summary>
    public static IReadOnlyList<string> Conflicts(string porcelain, IReadOnlyList<string> incoming)
    {
        var mine = Lines(porcelain).Where(l => l.Length > 3).Select(l => l[3..])
            .Select(p => p.Contains(" -> ") ? p[(p.IndexOf(" -> ", StringComparison.Ordinal) + 4)..] : p)
            .Select(p => p.Trim('"'));
        return mine.Intersect(incoming, StringComparer.OrdinalIgnoreCase).ToList();
    }

    /// <summary>install.sh --dry-run's "backup" lines: a live file that differs from the repo's and would be replaced
    /// (with a .bak beside it).</summary>
    public static IReadOnlyList<string> ParseDryRun(string output) =>
        Lines(output).Select(l => l.Trim()).Where(l => l.StartsWith("backup ", StringComparison.Ordinal))
            .Select(l => l["backup ".Length..].Trim().Split(" -> ")[0]).ToList();

    static async Task<IReadOnlyList<string>> LiveDriftAsync(string repo, CancellationToken ct)
    {
        if (SessionControl.FindBash() is not { } bash) return [];
        var (code, output) = await RunAsync(bash, ["-lc", "bash \"$1\" --dry-run 2>&1", "install",
            Path.Combine(repo, "install.sh").Replace('\\', '/')], repo, TimeSpan.FromSeconds(60), ct);
        return code == 0 ? ParseDryRun(output).Distinct().ToList() : [];
    }

    static IReadOnlyList<string> Lines(string s) =>
        s.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(l => l.TrimEnd('\r')).Where(l => l.Length > 0).ToList();

    static string LastLine(string s) => Lines(s).LastOrDefault() ?? "no output";

    /// <summary>git on PATH, else the one beside Git Bash.</summary>
    static string Git()
    {
        if (SessionControl.FindBash() is { } bash
            && Path.Combine(Path.GetDirectoryName(bash)!, "git.exe") is var beside && File.Exists(beside)
            && !(Environment.GetEnvironmentVariable("PATH") ?? "").Split(';').Any(d => File.Exists(Path.Combine(d, "git.exe"))))
            return beside;
        return "git";
    }

    static Task<(int Code, string Output)> GitAsync(string repo, string[] args, TimeSpan? timeout = null, CancellationToken ct = default) =>
        RunAsync(Git(), ["-C", repo, .. args], repo, timeout ?? TimeSpan.FromSeconds(20), ct);

    static async Task<(int Code, string Output)> RunAsync(string exe, IEnumerable<string> args, string cwd, TimeSpan timeout, CancellationToken ct)
    {
        var info = new ProcessStartInfo(exe)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
            WorkingDirectory = cwd,
        };
        foreach (var a in args) info.ArgumentList.Add(a);
        // never a credential prompt from a background check
        info.Environment["GIT_TERMINAL_PROMPT"] = "0";
        info.Environment["GCM_INTERACTIVE"] = "never";
        try
        {
            using var p = Process.Start(info)!;
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(timeout);
            var stdout = p.StandardOutput.ReadToEndAsync(cts.Token);
            var stderr = p.StandardError.ReadToEndAsync(cts.Token);
            try { await p.WaitForExitAsync(cts.Token); }
            catch (OperationCanceledException)
            {
                try { p.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
                return (-1, "timed out");
            }
            return (p.ExitCode, await stdout + await stderr);
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException) { return (-1, e.Message); }
    }
}
