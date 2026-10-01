namespace TokenChat.Core;

/// <summary>TokenChat.App [--lite] [--model name] [--effort level] [--resume sid] [--prompt text] [directory]. Parsed in
/// whichever instance was launched; a second instance hands it to the running one as JSON over the pipe, so Directory is
/// already absolute. Prompt is the new tab's first message, sent once claude is up (the Parked tab's /unpark).</summary>
public sealed record LaunchRequest(string? Directory, bool Lite = false, string? Model = null, string? ResumeSessionId = null,
    string? Effort = null, string? Prompt = null)
{
    /// <summary>Why the request cannot be carried out, or null. A resume needs the session's directory: claude looks the
    /// transcript up under the project folder of its working directory.</summary>
    public string? Error => ResumeSessionId is not null && Directory is null
        ? $"--resume {ResumeSessionId} needs the session's directory"
        : Prompt is not null && Directory is null ? "--prompt needs a directory to open the tab in" : null;

    public static LaunchRequest Parse(IReadOnlyList<string> args)
    {
        string? directory = null, model = null, resume = null, effort = null, prompt = null;
        var lite = false;
        for (var i = 0; i < args.Count; i++)
        {
            switch (args[i])
            {
                case "--lite": lite = true; break;
                case "--model" when i + 1 < args.Count: model = args[++i]; break;
                case "--effort" when i + 1 < args.Count: effort = args[++i]; break;
                case "--resume" when i + 1 < args.Count: resume = args[++i]; break;
                case "--prompt" when i + 1 < args.Count: prompt = args[++i]; break;
                default: directory = Path.GetFullPath(args[i]); break;
            }
        }
        return new LaunchRequest(directory, lite, model, resume, effort, prompt);
    }
}
