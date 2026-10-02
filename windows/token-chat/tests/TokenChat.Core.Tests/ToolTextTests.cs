using System.Text.Json.Nodes;
using TokenChat.Core.Protocol;
using TokenChat.Core.Transcript;

namespace TokenChat.Core.Tests;

public class ToolTextTests
{
    const string Cwd = @"C:\work\repo";

    static JsonObject In(string json) => (JsonObject)JsonNode.Parse(json)!;

    [Fact]
    public void ReadNamesTheFileAndItsFolderRelativeToTheSession()
    {
        var line = ToolText.Describe("Read", In("""{"file_path":"C:\\work\\repo\\src\\Core\\Projector.cs","offset":95,"limit":36}"""), Cwd);
        Assert.Equal(new ToolHeadline("Read", "Projector.cs", "src/Core"), line);
    }

    [Fact]
    public void ShellShowsItsDescriptionWithTheCommandBeneath()
    {
        var line = ToolText.Describe("Bash", In("""{"command":"dotnet test tests","description":"Run the core tests"}"""), Cwd);
        Assert.Equal(new ToolHeadline("Bash", "Run the core tests", null, "dotnet test tests"), line);
    }

    [Fact]
    public void SearchSaysWhereAndHow()
    {
        var line = ToolText.Describe("Grep", In("""{"pattern":"ToolUse","path":"C:\\work\\repo\\src","glob":"*.cs","output_mode":"count"}"""), Cwd);
        Assert.Equal(new ToolHeadline("Search", "\"ToolUse\"", "src · *.cs · count"), line);
    }

    [Theory]
    [InlineData("""{"file_path":"a.cs","offset":95,"limit":3}""", "    95\tx\n    96\ty\n    97\tz", "lines 95–97")]
    [InlineData("""{"file_path":"a.cs"}""", "     1→x\n     2→y", "all 2 lines")]
    public void ReadOutcomeIsTheRangeItGot(string input, string result, string expected) =>
        Assert.Equal(expected, ToolText.Outcome("Read", In(input), result, false));

    [Theory]
    [InlineData("src\\a.cs:3\nsrc\\b.cs:5\n\nFound 8 total occurrences across 2 files.", "8 hits · 2 files")]
    [InlineData("Found 3 files\nsrc\\a.cs\nsrc\\b.cs\nsrc\\c.cs", "3 files")]
    [InlineData("No matches found", "no matches")]
    [InlineData("12:var a\n40:var b\n\n[Showing results with pagination = limit: 2]", "2 lines (capped)")]
    public void SearchOutcomeCountsHits(string result, string expected) =>
        Assert.Equal(expected, ToolText.Outcome("Grep", In("{}"), result, false));

    [Fact]
    public void EditOutcomeIsItsDiffSizeAndErrorsSayWhy()
    {
        Assert.Equal("+2 −1", ToolText.Outcome("Edit", In("""{"old_string":"a\nb","new_string":"a\nc\nd"}"""), "ok", false));
        Assert.Equal("failed: File does not exist.", ToolText.Outcome("Read", null, "<tool_use_error>File does not exist.</tool_use_error>", true));
    }

    [Theory]
    [InlineData("""cd /c/repo; grep -n "a\|b" src/x.cs | head -20""", true)]
    [InlineData("git diff --stat && ls 2>/dev/null", true)]
    [InlineData("sed -i 's/a/b/' x.cs", false)]
    [InlineData("echo hi > out.txt", false)]
    [InlineData("dotnet test", false)]
    [InlineData("git commit -m x", false)]
    [InlineData("find . -name '*.tmp' -delete", false)]
    public void ShellLooksOnlyWhenEverySegmentReads(string command, bool looks) =>
        Assert.Equal(looks, ToolText.IsLook("Bash", new JsonObject { ["command"] = command }));

    [Theory]
    [InlineData("The row has two parts.\n\nNow let me look at the projector.", "Look at the projector")]
    [InlineData("I'll check the XAML template:", "Check the XAML template")]
    [InlineData("", null)]
    public void IntentIsTheLastSentenceOfTheThinking(string thinking, string? expected) =>
        Assert.Equal(expected, ToolText.Intent(thinking));

    static void Think(TranscriptProjector p, int index, string text)
    {
        p.Apply(new BlockStartEvent(index, "thinking", null, null, null));
        p.Apply(new DeltaEvent(index, DeltaKind.Thinking, text, null));
        p.Apply(new BlockStopEvent(index, null));
    }

    static ToolUseItem Call(TranscriptProjector p, int index, string name, string id, string input)
    {
        p.Apply(new BlockStartEvent(index, "tool_use", name, id, null));
        p.Apply(new DeltaEvent(index, DeltaKind.InputJson, input, null));
        p.Apply(new BlockStopEvent(index, null));
        return p.Tools.Single(t => t.ToolUseId == id);
    }

    static void Result(TranscriptProjector p, string id, string content) =>
        p.Apply(new UserEvent(new JsonArray(new JsonObject { ["type"] = "tool_result", ["tool_use_id"] = id, ["content"] = content }), null));

    [Fact]
    public void LookingCallsFoldIntoOneRunWithTheThinkingBetween()
    {
        var p = new TranscriptProjector();
        p.Apply(new MessageStartEvent("m1", null, new TokenUsage(), null));
        Think(p, 0, "Let me see how rows render.");
        Call(p, 1, "Read", "t1", """{"file_path":"a.cs"}""");
        Think(p, 2, "Now the template.");
        Call(p, 3, "Grep", "t2", """{"pattern":"Row"}""");
        Call(p, 4, "Bash", "t3", """{"command":"ls src","description":"List sources"}""");
        Call(p, 5, "Bash", "t4", """{"command":"dotnet build","description":"Build"}""");
        Call(p, 6, "Read", "t5", """{"file_path":"b.cs"}""");

        Assert.Equal(3, p.Items.Count);
        var run = Assert.IsType<ToolGroupItem>(p.Items[0]);
        Assert.Equal("See how rows render", run.Title);
        Assert.Equal("1 read · 1 search · 1 command", run.Counts);
        Assert.Equal(5, run.Children.Count);
        Assert.Equal("Build", Assert.IsType<ToolUseItem>(p.Items[1]).Line.Subject);
        Assert.Equal("b.cs", Assert.IsType<ToolGroupItem>(p.Items[2]).Title);
    }

    [Fact]
    public void GrowthBetweenRequestsPricesTheResults()
    {
        var p = new TranscriptProjector();
        p.Apply(new MessageStartEvent("m1", null, new TokenUsage(0, 0, 1000, 1), null));
        var read = Call(p, 0, "Read", "t1", """{"file_path":"a.cs"}""");
        p.Apply(new MessageDeltaEvent("tool_use", new TokenUsage(0, 0, 0, 200), null));
        Result(p, "t1", new string('x', 2500));
        Assert.Equal("≈1k", read.TokensText);

        p.Apply(new MessageStartEvent("m2", null, new TokenUsage(0, 1100, 1200, 1), null));
        Assert.Equal("+1.1k", read.TokensText);

        var a = Call(p, 0, "Read", "t2", """{"file_path":"b.cs"}""");
        var b = Call(p, 1, "Read", "t3", """{"file_path":"c.cs"}""");
        p.Apply(new MessageDeltaEvent("tool_use", new TokenUsage(0, 0, 0, 100), null));
        Result(p, "t2", new string('x', 3000));
        Result(p, "t3", new string('x', 1000));
        p.Apply(new MessageStartEvent("m3", null, new TokenUsage(0, 0, 3200, 1), null));
        Assert.Equal((600L, false), (a.Tokens!.Value, a.TokensExact));
        Assert.Equal(200L, b.Tokens);
        Assert.Equal("≈1.9k", Assert.IsType<ToolGroupItem>(Assert.Single(p.Items)).TokensText); // one run across requests
    }
}
