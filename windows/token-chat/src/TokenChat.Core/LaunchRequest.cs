namespace TokenChat.Core;

/// <summary>TokenChat.App [--lite] [--model name] [--effort level] [--resume sid] [--prompt text] [--replace sid] [--preview fixture.jsonl]...
/// [--standalone] [directory]. Parsed in whichever instance was launched; a second instance hands it to the running one as JSON over the
/// pipe, so Directory is already absolute. Prompt is the new tab's first message, sent once claude is up (the Parked tab's
/// /unpark). Replace is a /handoff's old session: the new tab takes the slot of the tab holding it and carries its transcript
/// folded above the new one. Preview is a dev mode: a tab per fixture replaying recorded stdout, no claude process, in a window of its own.
/// Standalone is the other dev mode: a real window beside a running TokenChat, neither claiming the instance nor
/// forwarding to it, so a fresh build can be tried without closing the live one.</summary>
public sealed record LaunchRequest(string? Directory, bool Lite = false, string? Model = null, string? ResumeSessionId = null,
    string? Effort = null, string? Prompt = null, IReadOnlyList<string>? Preview = null, PokeRequest? Poke = null, string? Replace = null,
    bool Standalone = false)
{
    /// <summary>Why the request cannot be carried out, or null. A resume needs the session's directory: claude looks the
    /// transcript up under the project folder of its working directory.</summary>
    public string? Error => ResumeSessionId is not null && Directory is null
        ? $"--resume {ResumeSessionId} needs the session's directory"
        : Prompt is not null && Directory is null ? "--prompt needs a directory to open the tab in"
        : Preview?.FirstOrDefault(f => !File.Exists(f)) is { } missing ? $"--preview: no file {missing}" : null;

    public static LaunchRequest Parse(IReadOnlyList<string> args)
    {
        string? directory = null, model = null, resume = null, effort = null, prompt = null, replace = null;
        List<string>? preview = null;
        bool lite = false, standalone = false;
        for (var i = 0; i < args.Count; i++)
        {
            switch (args[i])
            {
                case "--lite": lite = true; break;
                case "--standalone": standalone = true; break;
                case "--model" when i + 1 < args.Count: model = args[++i]; break;
                case "--effort" when i + 1 < args.Count: effort = args[++i]; break;
                case "--resume" when i + 1 < args.Count: resume = args[++i]; break;
                case "--prompt" when i + 1 < args.Count: prompt = args[++i]; break;
                case "--replace" when i + 1 < args.Count: replace = args[++i]; break;
                case "--preview" when i + 1 < args.Count: (preview ??= []).Add(Path.GetFullPath(args[++i])); break;
                default: directory = Path.GetFullPath(args[i]); break;
            }
        }
        return new LaunchRequest(directory, lite, model, resume, effort, prompt, preview, Replace: replace, Standalone: standalone);
    }
}

/// <summary>An extension-mark poke from token-poke.ps1, over the pipe only (no command line): Text goes to the open tab
/// holding SessionId as a user message, without raising the window. The pipe answers ok, busy or no-tab.</summary>
public sealed record PokeRequest(string SessionId, string Text);
