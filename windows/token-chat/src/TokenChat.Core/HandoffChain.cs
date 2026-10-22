namespace TokenChat.Core;

/// <summary>Which sessions a session took over by /handoff, oldest first, so a resume (a restart's, or any later one) can
/// fold them above it again and restart.ps1 can leave the old ones closed. One line per handoff, "new\told1,old2";
/// a later line for the same session wins. The file keeps its last 200 lines.</summary>
public static class HandoffChain
{
    public static string DefaultPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "tokenchat-handoffs.tsv");

    const int Keep = 200;

    public static void Record(string path, string sessionId, IReadOnlyList<string> olds)
    {
        if (olds.Count == 0) return;
        var lines = File.Exists(path) ? File.ReadAllLines(path).ToList() : [];
        lines.Add($"{sessionId}\t{string.Join(',', olds)}");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllLines(path, lines.Skip(Math.Max(0, lines.Count - Keep)));
    }

    /// <summary>The sessions sessionId took over, oldest first; empty when it took over none.</summary>
    public static IReadOnlyList<string> Olds(string path, string sessionId)
    {
        if (!File.Exists(path)) return [];
        IReadOnlyList<string> olds = [];
        foreach (var line in File.ReadLines(path))
            if (line.Split('\t') is [var sid, var list] && string.Equals(sid, sessionId, StringComparison.OrdinalIgnoreCase))
                olds = list.Split(',', StringSplitOptions.RemoveEmptyEntries);
        return olds;
    }
}
