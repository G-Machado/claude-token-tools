using System.Text.Json;

namespace TokenChat.Core;

/// <summary>The sidebar's groups the user made: a session moved into a named group, by session id, and the groups folded
/// shut, by id ("#name" for a named group, "P:" and the project key for a folder). A group exists while a session is in
/// it. Parents nests a /delegate session under the one that launched it (child sid to parent sid), Topics names a session's
/// checkpoint (sid to slug); both recorded once the tab has its id, since a --resume after a restart has no /unpark to read.
/// ~/.claude/tokenchat-groups.json, rewritten whole on every change; a missing or broken file is no groups.</summary>
public sealed class SessionGroups
{
    public static string DefaultPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "tokenchat-groups.json");

    public Dictionary<string, string> Members { get; set; } = [];
    public HashSet<string> Folded { get; set; } = [];
    public Dictionary<string, string> Parents { get; set; } = [];
    public Dictionary<string, string> Topics { get; set; } = [];
    /// <summary>A session's sidebar title from <see cref="Titler"/>, sid to title.</summary>
    public Dictionary<string, string> Titles { get; set; } = [];

    public static string NamedId(string name) => "#" + name;
    /// <summary>A parent's delegates folded under its row.</summary>
    public static string SubId(string sid) => "S:" + sid;
    public static string ProjectId(string cwd) => "P:" + (cwd.Length > 0 ? Project.Key(cwd) : "");

    public static SessionGroups Load(string path)
    {
        try
        {
            if (File.Exists(path) && JsonSerializer.Deserialize<SessionGroups>(File.ReadAllText(path)) is { } g) return g;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { }
        return new();
    }

    public void Save(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, JsonSerializer.Serialize(this));
    }

    public IEnumerable<string> Names => Members.Values.Distinct().Order(StringComparer.CurrentCultureIgnoreCase);

    /// <summary>Into a named group, or back under its folder with null.</summary>
    public void Move(string sid, string? name)
    {
        if (name is null) Members.Remove(sid);
        else Members[sid] = name;
    }

    /// <summary>Onto an existing name merges the two; a fold carries over.</summary>
    public void Rename(string from, string to)
    {
        foreach (var sid in Members.Where(m => m.Value == from).Select(m => m.Key).ToList()) Members[sid] = to;
        if (Folded.Remove(NamedId(from))) Folded.Add(NamedId(to));
    }

    public void Ungroup(string name)
    {
        foreach (var sid in Members.Where(m => m.Value == name).Select(m => m.Key).ToList()) Members.Remove(sid);
        Folded.Remove(NamedId(name));
    }
}
