namespace TokenChat.Core.Tests;

public class RecentProjectsTests
{
    [Fact]
    public void NewestFirstFromTheTranscriptCwdSkippingTempAndMissingFolders()
    {
        var root = Directory.CreateTempSubdirectory("recent-").FullName;
        try
        {
            var older = AppContext.BaseDirectory.TrimEnd('\\');
            var newer = Path.GetDirectoryName(older)!;
            var now = DateTime.UtcNow;
            Project("a", older, now.AddHours(-3));
            Project("b", newer, now.AddHours(-1));
            Project("c", Path.Combine(Path.GetTempPath(), "scratchpad"), now);
            Project("d", @"C:\no\such\folder", now);
            File.WriteAllText(Path.Combine(Directory.CreateDirectory(Path.Combine(root, "e")).FullName, "s.jsonl"), "{\"type\":\"summary\"}\n");

            var recents = RecentProjects.Load(root);
            Assert.Equal([newer, older], recents.Select(r => r.Path));
            Assert.Equal(Path.GetFileName(older), recents[1].Name);
        }
        finally { Directory.Delete(root, recursive: true); }

        void Project(string name, string cwd, DateTime lastUsed)
        {
            var dir = Directory.CreateDirectory(Path.Combine(root, name)).FullName;
            var file = Path.Combine(dir, "s.jsonl");
            File.WriteAllLines(file,
            [
                "{\"type\":\"file-history-snapshot\"}",
                "{\"type\":\"user\",\"cwd\":" + System.Text.Json.JsonSerializer.Serialize(cwd) + "}",
            ]);
            File.SetLastWriteTimeUtc(file, lastUsed);
        }
    }
}
