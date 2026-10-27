namespace TokenChat.Core.Tests;

public class TitlerTests
{
    [Fact]
    public void DueOnTheFirstPromptThenEveryFifth()
    {
        Assert.False(Titler.Due(null, 0));
        Assert.True(Titler.Due(null, 1));
        Assert.False(Titler.Due("Sidebar titles", 4));
        Assert.True(Titler.Due("Sidebar titles", Titler.Every));
    }

    [Fact]
    public void PromptCarriesTitleTopicAndTheLastPromptsOnOneLineEach()
    {
        var prompts = Enumerable.Range(1, 7).Select(i => $"prompt {i}\nsecond line").ToList();
        prompts.Add(new string('x', 400));
        var p = Titler.Prompt("Old title", "session-titles", prompts);
        Assert.Contains("Checkpoint topic: session-titles", p);
        Assert.Contains("Current title: Old title", p);
        Assert.DoesNotContain("prompt 3", p);
        Assert.Contains("- prompt 4 second line", p);
        Assert.Contains("- " + new string('x', 300) + "…", p);
        Assert.Contains("reply SAME", p);
        Assert.DoesNotContain("SAME", Titler.Prompt(null, null, ["hi"]));
    }

    [Theory]
    [InlineData("SAME", "Old", null)]
    [InlineData(" same \n", "Old", null)]
    [InlineData("", "Old", null)]
    [InlineData("\"old\"", "Old", null)]
    [InlineData("\"Plan popup step titles.\"\nextra", "Old", "Plan popup step titles")]
    [InlineData("**Fix sidebar project truncation**", null, "Fix sidebar project truncation")]
    public void ParseKeepsOnlyANewTitle(string reply, string? title, string? want) => Assert.Equal(want, Titler.Parse(reply, title));

    [Fact]
    public void ParseCapsALongTitle() => Assert.Equal(61, Titler.Parse(new string('a', 90), null)!.Length);
}

public class PlanStepTests
{
    [Theory]
    [InlineData("Sidebar row: give the project its own place.", "Sidebar row", "give the project its own place.")]
    [InlineData("Read memory `x` (records). Check the grep.", "Read memory `x` (records)", "Check the grep.")]
    [InlineData("Build to bin/Fresh — then run the tests", "Build to bin/Fresh", "then run the tests")]
    [InlineData("Build to bin/Fresh, run tests.", "Build to bin/Fresh, run tests", "")]
    [InlineData("DONE — Commit it. Then push.", "Commit it", "Then push.")]
    [InlineData("~~Old step~~", "Old step", "")]
    public void TitleIsTheLeadClause(string text, string title, string detail) =>
        Assert.Equal((title, detail), PlanStep.Split(text));

    [Fact]
    public void ALongLeadIsCutAndTheWholeStepIsTheDetail()
    {
        var text = string.Join(' ', Enumerable.Repeat("word", 30));
        var (title, detail) = PlanStep.Split(text);
        Assert.True(title.Length <= 81 && title.EndsWith('…'));
        Assert.Equal(text, detail);
    }

    [Fact]
    public void IndentedLinesBelongToTheirStep()
    {
        var plan = Plan.FromCheckpoint("t.md", "## Next\n1. First: a\n   b c\n2. Second\nStop after: x\n## Goal\n")!;
        Assert.Equal("First: a b c", plan.Steps[0].Text);
        Assert.Equal("a b c", plan.Steps[0].Detail);
        Assert.Equal("Second", plan.Steps[1].Title);
    }
}
