namespace TokenChat.Core.Tests;

public class SessionFeedTests
{
    static string Collect(long generated, double contextK) =>
        $$"""
        {"generated":{{generated}},"constants":{"cut_no":155.4,"gbud":40000},"limits":{"active":2},
         "sessions":[{"sid":"f8d13707-d94e","context_k":{{contextK.ToString(System.Globalization.CultureInfo.InvariantCulture)}},"model":"claude-opus-5-5"},{"nick":"no sid"}]}
        """;

    [Fact]
    public void ParsesSessionsByIdAndKeepsConstants()
    {
        var s = FeedSnapshot.Parse(Collect(1790952551, 81.7))!;
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1790952551), s.Generated);
        Assert.Equal(155.4, (double)s.Constants["cut_no"]!);
        Assert.Single(s.Sessions);
        Assert.Equal(81.7, (double)s.Sessions["F8D13707-d94e"]["context_k"]!);
        Assert.Null(FeedSnapshot.Parse("{\"sessions\":"));
        Assert.Null(FeedSnapshot.Parse("{}"));
    }

    [Fact]
    public void KeepsTheCollectorsOrder()
    {
        var s = FeedSnapshot.Parse("""{"sessions":[{"sid":"c"},{"sid":"a"},{"nick":"no sid"},{"sid":"b"},{"sid":"A"}]}""")!;
        // the sidebar draws rows in this order; a repeated id keeps its first place
        Assert.Equal(["c", "a", "b"], s.Ordered.Select(o => (string)o["sid"]!));
    }

    [Fact]
    public async Task PicksUpTheFileTheWidgetSwapsIn()
    {
        var dir = Directory.CreateTempSubdirectory("feed-").FullName;
        try
        {
            var path = Path.Combine(dir, "token-sessions.json");
            File.WriteAllText(path, Collect(1, 10));
            using var feed = new SessionFeed(path);
            Assert.Equal(10, (double)feed.Session("f8d13707-d94e")!["context_k"]!);

            var landed = new TaskCompletionSource();
            feed.Changed += () => landed.TrySetResult();
            // what Save-Feed does: write beside, then Replace while a reader may hold it open
            using (new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                File.WriteAllText(path + ".tmp", Collect(2, 20));
                File.Replace(path + ".tmp", path, null);
            }
            await landed.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Assert.Equal(20, (double)feed.Session("f8d13707-d94e")!["context_k"]!);
            Assert.Null(feed.Session("nope"));
            Assert.Null(feed.Session(null));
        }
        finally { Directory.Delete(dir, recursive: true); }
    }
}
