namespace TokenChat.Core.Tests;

public class SessionFeedTests
{
    static string Collect(long generated, double contextK) =>
        $$"""
        {"generated":{{generated}},"constants":{"cut_no":155.4,"gbud":40000},"limits":{"active":2},"overall":{"spend_day":7866},
         "sessions":[{"sid":"f8d13707-d94e","context_k":{{contextK.ToString(System.Globalization.CultureInfo.InvariantCulture)}},"model":"claude-opus-5-5"},{"nick":"no sid"}]}
        """;

    [Fact]
    public void ParsesSessionsByIdAndKeepsConstants()
    {
        var s = FeedSnapshot.Parse(Collect(1790952551, 81.7))!;
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1790952551), s.Generated);
        Assert.Equal(155.4, (double)s.Constants["cut_no"]!);
        Assert.Equal(7866, (double)s.Overall!["spend_day"]!);
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

    [Fact]
    public void StaleAfterSeventyFiveSecondsOrNoFile()
    {
        var at = DateTimeOffset.FromUnixTimeSeconds(1790952551);
        var s = FeedSnapshot.Parse(Collect(at.ToUnixTimeSeconds(), 10));
        Assert.False(SessionFeed.IsStale(s, at.AddSeconds(75)));
        Assert.True(SessionFeed.IsStale(s, at.AddSeconds(76)));
        Assert.True(SessionFeed.IsStale(null, at));
    }

    [Fact]
    public async Task CollectsOnlyWhenStaleAndNeverWritesABadCollect()
    {
        var dir = Directory.CreateTempSubdirectory("feed-").FullName;
        try
        {
            var path = Path.Combine(dir, "token-sessions.json");
            // generated now, so the constructor's own first check finds it fresh and leaves the counting to the test
            var at = DateTimeOffset.FromUnixTimeSeconds(DateTimeOffset.UtcNow.ToUnixTimeSeconds());
            File.WriteAllText(path, Collect(at.ToUnixTimeSeconds(), 10));
            var answer = Collect(200, 20);
            var runs = 0;
            using var feed = new SessionFeed(path, () => { runs++; return Task.FromResult<string?>(answer); });

            Assert.False(await feed.CollectIfStaleAsync(at.AddSeconds(30)));
            Assert.Equal(0, runs);

            answer = "{\"sessions\":";
            Assert.False(await feed.CollectIfStaleAsync(at.AddSeconds(90)));
            Assert.Equal(10, (double)feed.Session("f8d13707-d94e")!["context_k"]!);

            answer = Collect(200, 20);
            Assert.True(await feed.CollectIfStaleAsync(at.AddSeconds(90)));
            Assert.Equal(2, runs);
            Assert.Equal(20, (double)feed.Session("f8d13707-d94e")!["context_k"]!);
            Assert.Equal(20, (double)SessionFeed.Read(path)!.Sessions["f8d13707-d94e"]["context_k"]!);
            Assert.False(File.Exists(path + ".app.tmp"));
        }
        finally { Directory.Delete(dir, true); }
    }
}
