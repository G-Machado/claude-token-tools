using System.Text.Json;

namespace TokenChat.Core.Tests;

public class LaunchRequestTests
{
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
    public void NoArgumentsMeansTheStartScreen() => Assert.Equal(new LaunchRequest(null), LaunchRequest.Parse([]));

    [Fact]
    public void ResumeWithoutADirectoryIsAnError() =>
        Assert.Contains("needs the session's directory", LaunchRequest.Parse(["--resume", "abc"]).Error);

    [Fact]
    public void SurvivesThePipe()
    {
        var r = new LaunchRequest(@"C:\work", true, "haiku", "abc");
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
}
