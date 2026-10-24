using System.Diagnostics;
using System.Text.Json.Nodes;
using TokenChat.Core.Protocol;

namespace TokenChat.Core;

/// <summary>The aside button: one question asked in a throwaway fork of a session (claude -p --resume sid --fork-session),
/// so it reads the parent's cache and nothing lands in the parent's window. Measured 2026-10-23 on a warm 127k window:
/// 126.6k read, 1.6k written, $0.038; the same with hooks off. Every flag that shapes the prompt prefix (model, tools,
/// permission mode, extras) must match the parent's, or the fork misses and rewrites the window at 2x. Hooks are off: a
/// fork's Stop must not score a cycle or start a build. The fork's transcript is deleted after.</summary>
public static class Aside
{
    public sealed record Result(string Text, double CostUsd, long CacheRead, long CacheWrite, string? Error);

    const string Framing = "\n\n(Aside, asked in a throwaway fork of this session: answer briefly from what you already know. " +
                           "Read if you must; don't edit files or run anything that changes state.)";

    public static async Task<Result> AskAsync(LaunchOptions o, InitEvent init, string question, CancellationToken ct = default)
    {
        var psi = new ProcessStartInfo(ClaudeLauncher.LocateExe())
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
            WorkingDirectory = init.Cwd,
        };
        List<string> args =
        [
            "-p", question + Framing, "--resume", init.SessionId, "--fork-session", "--output-format", "json",
            "--model", init.Model, "--permission-mode", init.PermissionMode, "--max-turns", "4",
            "--settings", """{"disableAllHooks":true}""",
        ];
        if (o.Profile == Profile.Lite) args.AddRange(["--tools", string.Join(",", ClaudeLauncher.LiteTools), "--strict-mcp-config"]);
        if (o.Effort is { } effort) args.AddRange(["--effort", effort]);
        args.AddRange(o.ExtraArguments);
        foreach (var a in args) psi.ArgumentList.Add(a);
        foreach (var name in psi.Environment.Keys.Where(ClaudeLauncher.IsSessionMarker).ToList()) psi.Environment.Remove(name);

        string stdout, stderr;
        try
        {
            using var p = Process.Start(psi) ?? throw new InvalidOperationException("claude.exe did not start");
            var err = p.StandardError.ReadToEndAsync(ct);
            stdout = await p.StandardOutput.ReadToEndAsync(ct);
            stderr = await err;
            await p.WaitForExitAsync(ct);
        }
        catch (Exception e) when (e is not OperationCanceledException) { return new("", 0, 0, 0, e.Message); }

        JsonObject? j = null;
        try { j = JsonNode.Parse(stdout) as JsonObject; } catch (System.Text.Json.JsonException) { }
        if (j is null) return new("", 0, 0, 0, (stderr.Trim() is { Length: > 0 } s ? s : stdout.Trim()) is { Length: > 0 } m ? m[..Math.Min(m.Length, 400)] : "no output");

        if (Json.Str(j["session_id"]) is { } fork && fork != init.SessionId) Discard(fork);
        var u = j["usage"];
        long N(string k) => u?[k]?.GetValue<long>() ?? 0;
        var text = Json.Str(j["result"]) ?? "";
        var error = j["is_error"]?.GetValue<bool>() == true ? (text.Length > 0 ? text : Json.Str(j["subtype"]) ?? "error") : null;
        return new(text, j["total_cost_usd"]?.GetValue<double>() ?? 0, N("cache_read_input_tokens"), N("cache_creation_input_tokens"), error);
    }

    /// <summary>The fork's transcript, wherever its project folder is: an aside is not a session to list or resume.</summary>
    static void Discard(string forkSessionId)
    {
        var projects = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "projects");
        try
        {
            foreach (var dir in Directory.EnumerateDirectories(projects))
                if (Path.Combine(dir, forkSessionId + ".jsonl") is var f && File.Exists(f)) File.Delete(f);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}
