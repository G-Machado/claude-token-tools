namespace TokenChat.Core;

public enum Profile
{
    /// <summary>Claude Code defaults: all tools, MCP, skills. ~30-31.5k floor.</summary>
    Full,
    /// <summary>Six core tools plus AskUserQuestion, no MCP. ~15.7k floor (measured without AskUserQuestion).</summary>
    Lite,
}

public sealed record LaunchOptions
{
    public required string WorkingDirectory { get; init; }
    public Profile Profile { get; init; } = Profile.Full;
    public string? ResumeSessionId { get; init; }
    public string? Model { get; init; }
    /// <summary>--permission-mode. auto lets the classifier pass safe calls without a card; manual asks for every one.</summary>
    public string PermissionMode { get; init; } = "auto";
    public IReadOnlyList<string> ExtraArguments { get; init; } = [];
}

public sealed record LaunchSpec(string Exe, IReadOnlyList<string> Arguments, string WorkingDirectory,
    IReadOnlyDictionary<string, string> Environment);

public static class ClaudeLauncher
{
    /// <summary>Overrides the claude.exe location.</summary>
    public const string ExeVariable = "TOKEN_CHAT_CLAUDE_EXE";

    public static readonly IReadOnlyList<string> LiteTools = ["Read", "Edit", "Write", "Bash", "Grep", "Glob", "AskUserQuestion"];

    /// <summary>The shift+tab cycle. bypassPermissions and dontAsk are left out on purpose.</summary>
    public static readonly IReadOnlyList<string> PermissionModes = ["auto", "manual", "acceptEdits", "plan"];

    /// <summary>The mode after current in <see cref="PermissionModes"/>; auto for anything outside the cycle.</summary>
    public static string NextPermissionMode(string? current)
    {
        var i = current is null ? -1 : ((List<string>)[.. PermissionModes]).IndexOf(current);
        return PermissionModes[(i + 1) % PermissionModes.Count];
    }

    /// <summary>The real claude.exe, not the npm claude.cmd shim, so arguments and kill reach the process.</summary>
    public static string LocateExe()
    {
        var tried = new List<string>();
        var overridden = Environment.GetEnvironmentVariable(ExeVariable);
        if (!string.IsNullOrEmpty(overridden))
        {
            if (File.Exists(overridden)) return overridden;
            tried.Add(overridden);
        }
        var npm = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "npm", "node_modules", "@anthropic-ai", "claude-code", "bin", "claude.exe");
        if (File.Exists(npm)) return npm;
        tried.Add(npm);
        throw new FileNotFoundException($"claude.exe not found. Tried: {string.Join("; ", tried)}. Set {ExeVariable}.");
    }

    /// <summary>Variables a claude.exe child must not inherit. Started from inside a session (the widget, --watch, a
    /// terminal), it would come up in child-session mode: transcript saving off, no sessions/&lt;pid&gt;.json, invisible to
    /// the token tooling. Same wildcard as token-unpark-launch.cmd, because the marker set has grown before.</summary>
    public static bool IsSessionMarker(string name) =>
        name.StartsWith("CLAUDE", StringComparison.OrdinalIgnoreCase) || name.Equals("AI_AGENT", StringComparison.OrdinalIgnoreCase);

    public static LaunchSpec Build(LaunchOptions o, string? exe = null)
    {
        List<string> args =
        [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json",
            "--verbose", "--include-partial-messages", "--include-hook-events",
            "--permission-prompts", "host", "--permission-mode", o.PermissionMode,
            "--permission-prompt-tool", "stdio", // hidden flag; with the initialize handshake, prompts reach the host
        ];
        if (o.Profile == Profile.Lite) args.AddRange(["--tools", string.Join(",", LiteTools), "--strict-mcp-config"]);
        if (o.Model is { } model) args.AddRange(["--model", model]);
        if (o.ResumeSessionId is { } sid) args.AddRange(["--resume", sid]);
        args.AddRange(o.ExtraArguments);
        // Hooks see TOKEN_CHAT=1 so the token tooling can tell an app session from a terminal one (assumed: hooks inherit the child env).
        return new LaunchSpec(exe ?? LocateExe(), args, o.WorkingDirectory, new Dictionary<string, string> { ["TOKEN_CHAT"] = "1" });
    }
}
