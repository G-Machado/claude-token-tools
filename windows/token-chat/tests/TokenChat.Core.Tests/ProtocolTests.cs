using System.Text.Json.Nodes;
using TokenChat.Core;
using TokenChat.Core.Protocol;

namespace TokenChat.Core.Tests;

public class ProtocolTests
{
    static List<ClaudeEvent> Parse(string fixture) => Fixture.Lines(fixture).Select(EventParser.Parse).ToList();

    [Theory, MemberData(nameof(Fixture.All), MemberType = typeof(Fixture))]
    public void EveryRecordedLineIsModelled(string fixture)
    {
        var unknown = Parse(fixture).OfType<UnknownEvent>().Select(u => $"{u.Type}:{u.Subtype}").ToList();
        Assert.Empty(unknown);
    }

    [Fact]
    public void AskUserQuestionBecomesQuestionRequest()
    {
        var q = Assert.Single(Parse("perm").OfType<QuestionRequest>());
        var question = Assert.Single(q.Questions);
        Assert.Equal("Do you prefer red or blue?", question.Text);
        Assert.Equal(new[] { "Red", "Blue" }, question.Options.Select(o => o.Label));
        Assert.False(question.MultiSelect);
    }

    [Fact]
    public void WriteBecomesPermissionRequestWithSuggestion()
    {
        var p = Assert.Single(Parse("perm").OfType<PermissionRequest>());
        Assert.Equal("Write", p.ToolName);
        Assert.Equal("hi", (string?)p.Input["content"]);
        Assert.StartsWith("toolu_", p.ToolUseId);
        Assert.Equal("acceptEdits", (string?)p.Suggestions?[0]?["mode"]);
    }

    [Fact]
    public void RateLimitCarriesBothWindows()
    {
        var r = Parse("perm").OfType<RateLimitEvent>().First();
        Assert.InRange(r.FiveHour!.Utilization, 0, 1);
        Assert.InRange(r.SevenDay!.Utilization, 0, 1);
        Assert.True(r.SevenDay.ResetsAt > r.FiveHour.ResetsAt);
    }

    [Fact]
    public void CompactBoundaryCarriesTokenCounts()
    {
        var c = Assert.Single(Parse("full").OfType<CompactBoundaryEvent>());
        Assert.Equal(("manual", 30915L, 2475L), (c.Trigger, c.PreTokens, c.PostTokens));
    }

    [Fact]
    public void InterruptedTurnEndsInErrorResult()
    {
        var r = Assert.Single(Parse("full").OfType<ResultEvent>(), r => r.IsError);
        Assert.Equal("error_during_execution", r.Subtype);
        Assert.Equal(default, r.Usage);
    }

    [Fact]
    public void NonJsonLineIsUnparsableNotAnException()
    {
        var u = Assert.IsType<UnknownEvent>(EventParser.Parse("not json"));
        Assert.Equal("unparsable", u.Type);
        Assert.Equal("not json", (string?)u.Raw["line"]);
    }

    [Fact]
    public void AnswerKeepsInputAndAddsAnswers()
    {
        var q = Parse("perm").OfType<QuestionRequest>().Single();
        var line = JsonNode.Parse(Outbound.Answer(q, new Dictionary<string, string> { [q.Questions[0].Text] = "Blue" }))!;
        var response = line["response"]!;
        Assert.Equal(("success", q.RequestId, "allow"),
            ((string?)response["subtype"], (string?)response["request_id"], (string?)response["response"]!["behavior"]));
        var input = response["response"]!["updatedInput"]!;
        Assert.Equal("Blue", (string?)input["answers"]!["Do you prefer red or blue?"]);
        Assert.NotNull(input["questions"]);
        Assert.Null(q.Input["answers"]); // the parsed request is not mutated
    }

    [Fact]
    public void LiteProfileArguments()
    {
        var spec = ClaudeLauncher.Build(new LaunchOptions { WorkingDirectory = ".", Profile = Profile.Lite, Model = "opus", Effort = "xhigh" }, exe: "claude.exe");
        var args = string.Join(" ", spec.Arguments);
        Assert.Contains("--input-format stream-json --output-format stream-json", args);
        Assert.Contains("--permission-prompt-tool stdio", args);
        Assert.Contains("--tools Read,Edit,Write,Bash,Grep,Glob,AskUserQuestion --strict-mcp-config", args);
        Assert.Contains("--model opus", args);
        Assert.Contains("--effort xhigh", args);
        Assert.Equal("1", spec.Environment["TOKEN_CHAT"]);
        var bare = string.Join(" ", ClaudeLauncher.Build(new LaunchOptions { WorkingDirectory = "." }, "x").Arguments);
        Assert.DoesNotContain("--tools", bare);
        Assert.DoesNotContain("--effort", bare);
    }
}
