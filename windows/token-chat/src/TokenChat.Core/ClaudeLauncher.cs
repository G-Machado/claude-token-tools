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
    public IReadOnlyList<string> ExtraArguments { get; init; } = [];
}

public sealed record LaunchSpec(string Exe, IReadOnlyList<string> Arguments, string WorkingDirectory,
    IReadOnlyDictionary<string, string> Environment);

public static class ClaudeLauncher
{
    /// <summary>Overrides the claude.exe location.</summary>
    public const string ExeVariable = "TOKEN_CHAT_CLAUDE_EXE";

    public static readonly IReadOnlyList<string> LiteTools = ["Read", "Edit", "Write", "Bash", "Grep", "Glob", "AskUserQuestion"];

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

    public static LaunchSpec Build(LaunchOptions o, string? exe = null)
    {
        List<string> args =
        [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json",
            "--verbose", "--include-partial-messages", "--include-hook-events",
            "--permission-prompts", "host", "--permission-mode", "manual",
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
