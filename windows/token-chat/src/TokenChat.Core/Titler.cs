using System.Diagnostics;
using System.Text.Json.Nodes;
using TokenChat.Core.Protocol;

namespace TokenChat.Core;

/// <summary>The sidebar's per-session title. Headless sessions never get the CLI's ai-title (0 of every sdk-cli
/// transcript, 2026-10-27), so TokenChat asks Haiku: after the first real prompt, then every <see cref="Every"/> prompts,
/// with the current title and the recent prompts; Haiku answers SAME or a new title. One call is a fresh claude -p with
/// no tools, no hooks and no session file: measured 2026-10-27 at ~6.6k cache write, 0 read, ~15 out, ~$0.0013, ~3s.</summary>
public static class Titler
{
    public const int Every = 5;
    const int Keep = 5, PromptChars = 300, TitleChars = 60;

    const string System = "You name chat sessions in a sidebar. Output only the title or SAME, nothing else.";

    /// <summary>Due on the first prompt while untitled, then once <see cref="Every"/> prompts have passed since the last ask.</summary>
    public static bool Due(string? title, int promptsSinceAsk) => promptsSinceAsk >= (title is null ? 1 : Every);

    public static string Prompt(string? title, string? topic, IReadOnlyList<string> prompts)
    {
        var lines = new List<string>();
        if (topic is { Length: > 0 }) lines.Add($"Checkpoint topic: {topic}");
        lines.Add(title is null ? "Current title: (none)" : $"Current title: {title}");
        lines.Add("Recent user prompts, oldest first:");
        foreach (var p in prompts.TakeLast(Keep))
        {
            var one = string.Join(' ', p.Split((char[])['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)).Trim();
            lines.Add("- " + (one.Length > PromptChars ? one[..PromptChars] + "…" : one));
        }
        lines.Add(title is null
            ? "Reply with a 3-7 word title naming what this session works on."
            : "If the current title still names what the session works on now, reply SAME. Otherwise reply with a new 3-7 word title.");
        return string.Join('\n', lines);
    }

    /// <summary>The new title, or null for SAME, an empty reply or one that only repeats the current title.</summary>
    public static string? Parse(string reply, string? title)
    {
        var t = reply.Trim().Split('\n')[0].Trim().Trim('"', '\'', '`', '*', '#', ' ').TrimEnd('.');
        if (t.Length == 0 || t.Equals("SAME", StringComparison.OrdinalIgnoreCase)) return null;
        if (t.Length > TitleChars) t = t[..TitleChars].TrimEnd() + "…";
        return string.Equals(t, title, StringComparison.OrdinalIgnoreCase) ? null : t;
    }

    public static async Task<string?> AskAsync(string? title, string? topic, IReadOnlyList<string> prompts, CancellationToken ct = default)
    {
        var psi = new ProcessStartInfo(ClaudeLauncher.LocateExe())
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true,
            RedirectStandardError = true, WorkingDirectory = Path.GetTempPath(),
        };
        foreach (var a in (string[])["-p", "--model", "haiku", "--system-prompt", System, "--tools", "", "--no-session-persistence",
                     "--strict-mcp-config", "--disable-slash-commands", "--settings", """{"disableAllHooks":true}""", "--output-format", "json"])
            psi.ArgumentList.Add(a);
        foreach (var name in psi.Environment.Keys.Where(ClaudeLauncher.IsSessionMarker).ToList()) psi.Environment.Remove(name);
        try
        {
            using var p = Process.Start(psi) ?? throw new InvalidOperationException("claude.exe did not start");
            await p.StandardInput.WriteAsync(Prompt(title, topic, prompts));
            p.StandardInput.Close();
            var err = p.StandardError.ReadToEndAsync(ct);
            var stdout = await p.StandardOutput.ReadToEndAsync(ct);
            await err;
            await p.WaitForExitAsync(ct);
            if (JsonNode.Parse(stdout) is not JsonObject j || j["is_error"]?.GetValue<bool>() == true) return null;
            return Parse(Json.Str(j["result"]) ?? "", title);
        }
        catch (Exception e) when (e is not OperationCanceledException) { return null; }
    }
}
