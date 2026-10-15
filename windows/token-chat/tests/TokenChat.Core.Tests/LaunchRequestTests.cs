using System.Text.Json;

namespace TokenChat.Core.Tests;

public class LaunchRequestTests
{
    [Fact]
    public void StandaloneIsAFlagAndNotADirectory()
    {
        var r = LaunchRequest.Parse(["--standalone"]);
        Assert.True(r.Standalone);
        Assert.Null(r.Directory);
        Assert.Null(r.Preview);
        Assert.False(LaunchRequest.Parse([]).Standalone);
    }

    [Fact]
    public void ParsesResumeWithAnAbsoluteDirectory()
    {
        var r = LaunchRequest.Parse(["--lite", "--resume", "9ec328d3", "--model", "haiku", "."]);
        Assert.Equal(Path.GetFullPath("."), r.Directory);
        Assert.True(r.Lite);
        Assert.Equal("haiku", r.Model);
        Assert.Equal("9ec328d3", r.ResumeSessionId);
        Assert.Null(r.Error);
    }

    [Fact]
    public void ParsesAnUnparkLaunch()
    {
        var r = LaunchRequest.Parse(["--model", "sonnet", "--effort", "medium", "--prompt", "/unpark token-chat-link", @"C:\work"]);
        Assert.Equal(@"C:\work", r.Directory);
        Assert.Equal("medium", r.Effort);
        Assert.Equal("/unpark token-chat-link", r.Prompt);
        Assert.Null(r.ResumeSessionId);
        Assert.Null(r.Error);
    }

    [Fact]
    public void ParsesAHandoffThatTakesOverTheOldTab()
    {
        var r = LaunchRequest.Parse(["--replace", "eb25c90a", "--prompt", "/unpark x --handoff", @"C:\work"]);
        Assert.Equal("eb25c90a", r.Replace);
        Assert.Equal(@"C:\work", r.Directory);
        Assert.Null(r.Error);
    }

    [Fact]
    public void PromptWithoutADirectoryIsAnError() =>
        Assert.Contains("--prompt needs a directory", LaunchRequest.Parse(["--prompt", "/unpark"]).Error);

    [Fact]
    public void NoArgumentsMeansTheStartScreen() => Assert.Equal(new LaunchRequest(null), LaunchRequest.Parse([]));

    [Fact]
    public void PreviewRepeatsForATabPerFixture()
    {
        var a = Path.GetTempFileName();
        var r = LaunchRequest.Parse(["--preview", a, "--preview", "missing.jsonl"]);
        Assert.Equal([a, Path.GetFullPath("missing.jsonl")], r.Preview!);
        Assert.Contains("--preview: no file", r.Error);
        File.Delete(a);
    }

    [Fact]
    public void ResumeWithoutADirectoryIsAnError() =>
        Assert.Contains("needs the session's directory", LaunchRequest.Parse(["--resume", "abc"]).Error);

    [Fact]
    public void SurvivesThePipe()
    {
        var r = new LaunchRequest(@"C:\work", true, "haiku", "abc", "xhigh", "/unpark topic");
        Assert.Equal(r, JsonSerializer.Deserialize<LaunchRequest>(JsonSerializer.Serialize(r)));
    }

    [Theory]
    [InlineData("CLAUDE_CODE_CHILD_SESSION", true)]
    [InlineData("CLAUDECODE", true)]
    [InlineData("claude_pid", true)]
    [InlineData("AI_AGENT", true)]
    [InlineData("TOKEN_CHAT_CLAUDE_EXE", false)]
    [InlineData("PATH", false)]
    public void ScrubsTheSessionMarkers(string name, bool scrubbed) => Assert.Equal(scrubbed, ClaudeLauncher.IsSessionMarker(name));

    /// token-poke.ps1 builds this with ConvertTo-Json: PascalCase, no Directory.
    [Fact]
    public void APokeFromPowerShellParsesWithNoError()
    {
        var r = JsonSerializer.Deserialize<LaunchRequest>("""{"Poke":{"SessionId":"7cef843d","Text":"[auto-renew: 12m left] reply with only: ok"}}""")!;
        Assert.Equal(new PokeRequest("7cef843d", "[auto-renew: 12m left] reply with only: ok"), r.Poke);
        Assert.Null(r.Error);
    }
}
