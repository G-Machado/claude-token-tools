namespace TokenChat.Core;

/// <summary>Tabs group by project: the working directory, compared as Windows compares paths. The colour slot is a stable
/// hash of that key (string.GetHashCode is seeded per process), so a project keeps its colour in every window and every
/// run; with a handful of slots, two projects can share one.</summary>
public static class Project
{
    public static string Key(string directory) =>
        Path.TrimEndingDirectorySeparator(Path.GetFullPath(directory)).ToUpperInvariant();

    /// <summary>FNV-1a over the key's UTF-16 code units, reduced to 0..slots-1.</summary>
    public static int Slot(string directory, int slots)
    {
        var h = 2166136261u;
        foreach (var c in Key(directory)) h = (h ^ c) * 16777619u;
        return (int)(h % (uint)slots);
    }
}
