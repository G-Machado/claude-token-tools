namespace TokenChat.Core;

/// <summary>The Done boxes the user ticked or unticked, by <see cref="Transcript.CheckItem.Key"/>. One line per change,
/// "key\t1" or "key\t0"; a later line for the same key wins. The file keeps its last 2000 lines.</summary>
public static class TickStore
{
    public static string DefaultPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "tokenchat-ticks.tsv");

    const int Keep = 2000;

    public static void Record(string path, string key, bool isChecked)
    {
        var lines = File.Exists(path) ? File.ReadAllLines(path).ToList() : [];
        lines.Add($"{key}\t{(isChecked ? 1 : 0)}");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllLines(path, lines.Skip(Math.Max(0, lines.Count - Keep)));
    }

    public static Dictionary<string, bool> Load(string path)
    {
        var ticks = new Dictionary<string, bool>(StringComparer.Ordinal);
        if (!File.Exists(path)) return ticks;
        foreach (var line in File.ReadLines(path))
            if (line.Split('\t') is [var key, var v]) ticks[key] = v == "1";
        return ticks;
    }
}
