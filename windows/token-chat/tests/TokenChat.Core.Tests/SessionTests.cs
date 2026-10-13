using TokenChat.Core;
using TokenChat.Core.Protocol;

namespace TokenChat.Core.Tests;

public class SessionTests
{
    static readonly TimeSpan Timeout = TimeSpan.FromSeconds(10);

    [Fact]
    public async Task HandshakeIsSentFirstAndExposesAccount()
    {
        var transport = Fixture.Replay("perm");
        await using var session = new ClaudeSession(transport);
        await session.HandshakeAsync(Timeout);

        var first = transport.Sent[0];
        Assert.Equal(("control_request", "initialize"), ((string?)first["type"], (string?)first["request"]!["subtype"]));
        Assert.Null(first["request"]!["hooks"]);
        Assert.Equal("Claude Pro", (string?)session.InitializeInfo!["account"]!["subscriptionType"]);
    }

    [Fact]
    public async Task PermissionAndQuestionAreAnsweredAndCleanPointFollows()
    {
        var transport = Fixture.Replay("perm");
        await using var session = new ClaudeSession(transport);
        await session.HandshakeAsync(Timeout);

        var answered = new List<string>();
        await foreach (var e in session.Events.ReadAllAsync().WithCancellation(new CancellationTokenSource(Timeout).Token))
        {
            switch (e)
            {
                case PermissionRequest p:
                    Assert.False(session.AtCleanPoint);
                    await session.AllowAsync(p);
                    answered.Add(p.RequestId);
                    break;
                case QuestionRequest q:
                    await session.AnswerAsync(q, new Dictionary<string, string> { [q.Questions[0].Text] = "Blue" });
                    answered.Add(q.RequestId);
                    break;
            }
        }

        Assert.Equal(2, answered.Count);
        var replies = transport.Sent.Where(s => (string?)s["type"] == "control_response").ToList();
        Assert.Equal(answered, replies.Select(r => (string?)r["response"]!["request_id"]));
        Assert.All(replies, r => Assert.Equal("allow", (string?)r["response"]!["response"]!["behavior"]));
        Assert.Equal("hi", (string?)replies[0]["response"]!["response"]!["updatedInput"]!["content"]);
        Assert.True(session.AtCleanPoint);
        Assert.NotNull(session.RateLimit?.FiveHour);
        Assert.Equal(session.Init!.SessionId, session.SessionId);
        Assert.True(session.Usage.Session.Prompt > 0);
    }

    [Fact]
    public async Task InterruptCompletesOnControlResponse()
    {
        var transport = Fixture.Replay("full");
        await using var session = new ClaudeSession(transport);
        session.Start();
        await session.InterruptAsync().WaitAsync(Timeout);

        var sent = Assert.Single(transport.Sent);
        Assert.Equal("interrupt", (string?)sent["request"]!["subtype"]);
    }

    [Fact]
    public async Task UnhandledControlRequestIsRefusedNotIgnored()
    {
        var transport = new ReplayTransport(["""{"type":"control_request","request_id":"r9","request":{"subtype":"mcp_message"}}"""]);
        await using var session = new ClaudeSession(transport);
        session.Start();
        await foreach (var _ in session.Events.ReadAllAsync().WithCancellation(new CancellationTokenSource(Timeout).Token)) { }

        var reply = Assert.Single(transport.Sent)["response"]!;
        Assert.Equal(("error", "r9"), ((string?)reply["subtype"], (string?)reply["request_id"]));
    }

    [Fact]
    public async Task EveryMainRequestRewritesTheSessionUsagePayload()
    {
        var dir = Directory.CreateTempSubdirectory("tc-usage-").FullName;
        try
        {
            var file = new SessionUsageFile(dir);
            await using var session = new ClaudeSession(Fixture.Replay("perm"), file);
            var before = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            await session.HandshakeAsync(Timeout);
            await foreach (var _ in session.Events.ReadAllAsync().WithCancellation(new CancellationTokenSource(Timeout).Token)) { }

            var path = Assert.Single(Directory.GetFiles(dir));
            Assert.Equal(file.PathFor(session.SessionId!), path);
            var text = File.ReadAllText(path);
            Assert.Contains($"\"total_input_tokens\":{session.Usage.Context}", text);
            Assert.Contains($"\"requests\":{session.Usage.Requests}", text);
            Assert.Contains("\"ttl\":\"1h\"", text);
            var expires = (long)System.Text.Json.Nodes.JsonNode.Parse(text)!["prompt_cache"]!["expires_at"]!;
            Assert.InRange(expires, before + 3600, DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 3600);
            Assert.True(session.Usage.Requests > 0);
        }
        finally { Directory.Delete(dir, recursive: true); }
    }

    [Fact]
    public void TouchKeepsAPayloadLiveButNeverCreatesOne()
    {
        var dir = Directory.CreateTempSubdirectory("tc-usage-").FullName;
        try
        {
            var file = new SessionUsageFile(dir);
            file.Touch("s1");
            Assert.Empty(Directory.GetFiles(dir));

            file.Write("s1", "C:\\p", 1000, 1, DateTimeOffset.UtcNow);
            File.SetLastWriteTimeUtc(file.PathFor("s1"), DateTime.UtcNow.AddMinutes(-10));
            file.Touch("s1");
            Assert.InRange(DateTime.UtcNow - File.GetLastWriteTimeUtc(file.PathFor("s1")), TimeSpan.Zero, TimeSpan.FromSeconds(30));
        }
        finally { Directory.Delete(dir, recursive: true); }
    }

    [Fact]
    public async Task SendWritesOneUserLineAndOpensATurn()
    {
        var transport = new ReplayTransport([]);
        await using var session = new ClaudeSession(transport);
        await session.SendAsync("hello");

        var sent = Assert.Single(transport.Sent);
        Assert.Equal(("user", "user", "hello"),
            ((string?)sent["type"], (string?)sent["message"]!["role"], (string?)sent["message"]!["content"]));
        Assert.False(session.AtCleanPoint);
    }
}
