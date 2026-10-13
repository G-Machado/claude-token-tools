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
    public async Task CollectsEveryTwentySecondsWhileNobodyElseDoes()
    {
        var dir = Directory.CreateTempSubdirectory("feed-").FullName;
        try
        {
            var path = Path.Combine(dir, "token-sessions.json");
            var runs = 0;
            var stamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds() - 600;
            var t0 = DateTimeOffset.UtcNow;
            // no file: nobody has collected, so the first check runs one at once
            using var feed = new SessionFeed(path, () => { runs++; return Task.FromResult<string?>(Collect(++stamp, runs)); });
            await Task.Delay(400);
            Assert.Equal(1, runs);
            // its own write coming back through the watcher is not someone else collecting
            Assert.False(await feed.CollectIfDueAsync(t0.AddSeconds(19)));
            Assert.True(await feed.CollectIfDueAsync(t0.AddSeconds(21)));
            await Task.Delay(400);
            Assert.False(await feed.CollectIfDueAsync(t0.AddSeconds(40)));
            Assert.True(await feed.CollectIfDueAsync(t0.AddSeconds(41)));
            Assert.Equal(3, runs);
            Assert.Equal(3, (double)feed.Session("f8d13707-d94e")!["context_k"]!);
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public async Task StandsDownWhileAnotherWritersCollectsLand()
    {
        var dir = Directory.CreateTempSubdirectory("feed-").FullName;
        try
        {
            var path = Path.Combine(dir, "token-sessions.json");
            var stamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds() - 600;
            File.WriteAllText(path, Collect(stamp, 10));
            File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddMinutes(-10));
            var runs = 0;
            using var feed = new SessionFeed(path, () => { runs++; return Task.FromResult<string?>(Collect(++stamp, 20)); });
            await Task.Delay(400);
            Assert.Equal(1, runs);

            // the widget's collect lands: the app leaves the collecting to it for the quiet period
            File.WriteAllText(path, Collect(stamp + 100, 77));
            await Task.Delay(400);
            var landed = DateTimeOffset.UtcNow;
            Assert.Equal(77, (double)feed.Session("f8d13707-d94e")!["context_k"]!);
            Assert.False(await feed.CollectIfDueAsync(landed.AddSeconds(40)));
            Assert.True(await feed.CollectIfDueAsync(landed.AddSeconds(46)));
            Assert.Equal(2, runs);
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public async Task WaitsOutAFreshFileAndNeverWritesABadCollect()
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

            Assert.False(await feed.CollectIfDueAsync(at.AddSeconds(30)));
            Assert.Equal(0, runs);

            answer = "{\"sessions\":";
            Assert.False(await feed.CollectIfDueAsync(at.AddSeconds(90)));
            Assert.Equal(10, (double)feed.Session("f8d13707-d94e")!["context_k"]!);

            // a failed collect waits out the cadence like any other
            answer = Collect(200, 20);
            Assert.False(await feed.CollectIfDueAsync(at.AddSeconds(109)));
            Assert.True(await feed.CollectIfDueAsync(at.AddSeconds(110)));
            Assert.Equal(2, runs);
            Assert.Equal(20, (double)feed.Session("f8d13707-d94e")!["context_k"]!);
            Assert.Equal(20, (double)SessionFeed.Read(path)!.Sessions["f8d13707-d94e"]["context_k"]!);
            Assert.False(File.Exists(path + ".app.tmp"));
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public async Task AClickSurvivesACollectThatStartedBeforeItsScriptCallEnded()
    {
        var dir = Directory.CreateTempSubdirectory("feed-").FullName;
        try
        {
            var path = Path.Combine(dir, "token-sessions.json");
            var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            File.WriteAllText(path, Collect(now, 10));
            var answer = "";
            using var feed = new SessionFeed(path, () => Task.FromResult<string?>(answer));
            double Shown() => (double)feed.Session("f8d13707-d94e")!["context_k"]!;
            var hours = 0;
            async Task Lands(long generated, double contextK)
            {
                answer = Collect(generated, contextK);
                Assert.True(await feed.CollectIfDueAsync(DateTimeOffset.UtcNow.AddHours(++hours)));
            }

            // what broke the mark buttons: a patched int is not a double to System.Text.Json, so the app's readers take any
            Assert.False(System.Text.Json.Nodes.JsonValue.Create(2).TryGetValue(out double _));
            var done = feed.Patch("f8d13707-d94e", o => o["context_k"] = 99.0);
            Assert.Equal(99, Shown());
            // in flight while the call runs, then one stamped before it returned: both read the old state file
            await Lands(now - 30, 10);
            Assert.Equal(99, Shown());
            done();
            await Lands(now - 5, 10);
            Assert.Equal(99, Shown());
            // stamped after the call returned: the script's answer, and the patch is gone for good
            await Lands(now + 5, 42);
            Assert.Equal(42, Shown());
            await Lands(now - 30, 10);
            Assert.Equal(10, Shown());
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public async Task AWindowsUsagePayloadMovesItsContextAndCacheClockBetweenCollects()
    {
        var dir = Directory.CreateTempSubdirectory("feed-").FullName;
        try
        {
            var path = Path.Combine(dir, "token-sessions.json");
            var usage = Directory.CreateDirectory(Path.Combine(dir, "session-usage")).FullName;
            var generated = DateTimeOffset.UtcNow.ToUnixTimeSeconds() - 120;
            File.WriteAllText(path, Collect(generated, 10));
            // a payload older than the collect says nothing the collect did not
            var payload = Path.Combine(usage, "f8d13707-d94e.json");
            File.WriteAllText(payload, $$$"""{"context_window":{"total_input_tokens":33000},"prompt_cache":{"expires_at":{{{generated + 600}}}}}""");
            File.SetLastWriteTimeUtc(payload, DateTimeOffset.FromUnixTimeSeconds(generated - 60).UtcDateTime);
            using var feed = new SessionFeed(path, usageDir: usage);
            var changed = 0;
            feed.Changed += () => Interlocked.Increment(ref changed);
            await Task.Delay(400);
            Assert.Equal(10, (double)feed.Session("f8d13707-d94e")!["context_k"]!);

            // a request lands: the status line rewrites it
            File.WriteAllText(payload, $$$"""{"context_window":{"total_input_tokens":55432},"prompt_cache":{"expires_at":{{{generated + 3720}}}}}""");
            await Task.Delay(500);
            var s = feed.Session("f8d13707-d94e")!;
            Assert.Equal(55.4, (double)s["context_k"]!);
            Assert.Equal(62, (int)s["cache_left_min"]!);
            Assert.True(changed >= 1);

            // the next collect, stamped before that request, keeps the live figure
            File.WriteAllText(path, Collect(generated + 1, 12));
            await Task.Delay(500);
            Assert.Equal(55.4, (double)feed.Session("f8d13707-d94e")!["context_k"]!);
        }
        finally { Directory.Delete(dir, true); }
    }
}
