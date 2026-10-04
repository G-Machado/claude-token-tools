using System.Diagnostics;
using System.Globalization;

namespace TokenChat.Core;

/// <summary>The widget's session controls, through the same scripts it calls: token-sessions.sh for the extension
/// marks, the input block and the name (each writes the state file the hooks read; the next collect shows it), and
/// token-open.ps1 to bring a session's own window forward.</summary>
public static class SessionControl
{
    static string Claude => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude");

    /// <summary>The widget's e / E: one mark more or fewer. Never under the marks already spent - a hollow mark is a
    /// crossing the window made, and taking it back would hand out a free extension - and never over the cap.</summary>
    public static int NextMarks(int allowed, int used, int cap, int delta) =>
        Math.Min(cap, Math.Max(Math.Max(0, used), allowed + delta));

    public static IReadOnlyList<string> Extend(string sid, int marks) =>
        ["--extend", sid.Length > 8 ? sid[..8] : sid, marks.ToString(CultureInfo.InvariantCulture)];

    public static IReadOnlyList<string> Unblock(string sid) => ["--unblock", sid];

    /// <summary>The widget's y: the command that resumes the session in a terminal.</summary>
    public static string ResumeCommand(string cwd, string sid) => $"cd \"{cwd}\" && claude -r {sid}";

    /// <summary>Git Bash, where the widget looks for it; null when it is not installed.</summary>
    public static string? FindBash()
    {
        string?[] candidates =
        [
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs"),
        ];
        return candidates.Select(c => Path.Combine(c ?? "", "Git", "bin", "bash.exe")).FirstOrDefault(File.Exists);
    }

    /// <summary>token-sessions.sh with args; null when it ran clean, else what went wrong in a line.</summary>
    public static async Task<string?> RunAsync(IReadOnlyList<string> args)
    {
        if (FindBash() is not { } bash) return "Git Bash not found";
        // the args go through "$@", so a name with quotes or spaces arrives as typed
        return await RunAsync(bash, ["-lc", "\"$HOME/.claude/token-sessions.sh\" \"$@\"", "token-sessions", .. args]) is (0, _)
            ? null : "token-sessions.sh " + args[0] + " failed";
    }

    /// <summary>The widget's collect: token-sessions.sh --json, or null when it failed or said nothing. Checks the
    /// poke-due task on the way, as the widget does on every collect.</summary>
    public static async Task<string?> CollectAsync()
    {
        if (FindBash() is not { } bash) return null;
        await EnsurePokeDueAsync();
        var (code, output) = await RunAsync(bash, ["-lc", "\"$HOME/.claude/token-sessions.sh\" --json --no-update-check 2>/dev/null"]);
        return code == 0 && output.Trim().Length > 0 ? output : null;
    }

    static DateTime _pokeDueCheckedAt = DateTime.MinValue;

    /// <summary>The widget's Ensure-PokeDue, once an hour: re-arm the ClaudeTokenPokeDue task when it has gone missing,
    /// unless token-pokedue.off says it was turned off on purpose. Never fatal.</summary>
    static async Task EnsurePokeDueAsync()
    {
        if (DateTime.UtcNow - _pokeDueCheckedAt < TimeSpan.FromMinutes(60)) return;
        _pokeDueCheckedAt = DateTime.UtcNow;
        try
        {
            if (File.Exists(Path.Combine(Claude, "token-pokedue.off"))) return;
            if (await RunAsync("schtasks.exe", ["/Query", "/TN", "ClaudeTokenPokeDue"]) is (0, _)) return;
            var install = Path.Combine(Claude, "token-pokedue-install.ps1");
            if (!File.Exists(install)) return;
            await RunAsync("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", install]);
            File.AppendAllText(Path.Combine(Claude, "token-pokedue.log"),
                $"{DateTime.Now:yyyy-MM-ddTHH:mm:ss}\tre-armed by TokenChat - the task was missing\n");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>token-open.ps1's Open-Session: focus the window holding a live session (a terminal, an IDE, TokenChat).
    /// Returns its one-line answer.</summary>
    public static async Task<string> OpenAsync(string sid, string cwd, int pid)
    {
        var script = Path.Combine(Claude, "token-open.ps1");
        if (!File.Exists(script)) return "token-open.ps1 is not installed";
        var (code, output) = await RunAsync("powershell.exe",
            ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script, sid, cwd, pid.ToString(CultureInfo.InvariantCulture), "1"]);
        return output.Trim() is { Length: > 0 } said ? said : code == 0 ? "opened" : "token-open.ps1 failed";
    }

    static async Task<(int Code, string Output)> RunAsync(string exe, IEnumerable<string> args)
    {
        var info = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true };
        foreach (var a in args) info.ArgumentList.Add(a);
        try
        {
            using var p = Process.Start(info)!;
            var output = await p.StandardOutput.ReadToEndAsync();
            await p.WaitForExitAsync();
            return (p.ExitCode, output);
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException) { return (-1, ""); }
    }
}
