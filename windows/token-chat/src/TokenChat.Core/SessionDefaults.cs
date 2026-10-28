using System.Text.Json;

namespace TokenChat.Core;

/// <summary>The model and effort a new session starts on, picked from the sidebar row menu; null leaves the account
/// default. A resumed session keeps what it ran on (a model switch rewrites its cache), and a checkpoint's own model and
/// effort win over these. ~/.claude/tokenchat-defaults.json, rewritten whole on every change; a missing or broken file
/// is no defaults.</summary>
public sealed class SessionDefaults
{
    public static string DefaultPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "tokenchat-defaults.json");

    public static readonly string[] Models = ["opus", "sonnet", "haiku"];
    public static readonly string[] Efforts = ["low", "medium", "high", "xhigh", "max"];

    public string? Model { get; set; }
    public string? Effort { get; set; }

    public static SessionDefaults Load(string path)
    {
        try
        {
            if (File.Exists(path) && JsonSerializer.Deserialize<SessionDefaults>(File.ReadAllText(path)) is { } d) return d;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { }
        return new();
    }

    public void Save(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, JsonSerializer.Serialize(this));
    }
}
