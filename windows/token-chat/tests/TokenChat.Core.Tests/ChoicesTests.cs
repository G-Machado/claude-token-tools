using System.Text.Json.Nodes;
using TokenChat.Core.Protocol;
using TokenChat.Core.Transcript;

namespace TokenChat.Core.Tests;

public class ChoicesTests
{
    static QuestionItem Ask(params Question[] questions) => new(new QuestionRequest("r1", "toolu_1", new JsonObject(), questions));

    static Question Q(string text, bool multi, params string[] labels) =>
        new(text, null, multi, labels.Select(l => new QuestionOption(l, null)).ToList());

    [Fact]
    public void QuestionRequestBecomesPendingCard()
    {
        var projector = new TranscriptProjector();
        foreach (var e in Fixture.Lines("perm").Select(EventParser.Parse)) projector.Apply(e);
        var q = Assert.Single(projector.Items.OfType<QuestionItem>());
        Assert.Equal(QuestionState.Pending, q.State);
        Assert.True(q.AnswersOnPick);
        Assert.False(q.CanSubmit);
        q.Questions[0].Options[1].Pick();
        Assert.True(q.CanSubmit);
        Assert.Equal("Blue", q.Answers()["Do you prefer red or blue?"]);
        // the AskUserQuestion tool row names the question, not the raw input json
        Assert.Contains(projector.Items.OfType<ToolUseItem>(), t => t.Summary == "Do you prefer red or blue?");
    }

    [Fact]
    public void SingleSelectPicksOneAndTypingReplacesIt()
    {
        var q = Ask(Q("Colour?", false, "Red", "Blue"));
        var pick = q.Questions[0];
        pick.Options[0].Pick();
        pick.Options[1].Pick();
        Assert.Equal("Blue", pick.Answer);
        pick.Options[1].Pick(); // a second click clears it
        Assert.Null(pick.Answer);
        Assert.False(q.CanSubmit);
        pick.Options[0].Pick();
        pick.Other = "green";
        Assert.False(pick.Options[0].IsSelected);
        Assert.Equal("green", pick.Answer);
        pick.Options[1].Pick();
        Assert.Equal("", pick.Other);
        Assert.Equal("Blue", pick.Answer);
    }

    [Fact]
    public void MultiSelectJoinsPicksAndTypedText()
    {
        var q = Ask(Q("Which?", true, "A", "B", "C"), Q("Colour?", false, "Red"));
        Assert.False(q.AnswersOnPick);
        var multi = q.Questions[0];
        multi.Options[2].Pick();
        multi.Options[0].Pick();
        multi.Other = " also D ";
        Assert.Equal("A, C, also D", multi.Answer);
        Assert.False(q.CanSubmit); // the second question is unanswered
        var changed = new List<string?>();
        q.PropertyChanged += (_, e) => changed.Add(e.PropertyName);
        q.Questions[1].Options[0].Pick();
        Assert.Contains(nameof(QuestionItem.CanSubmit), changed);
        Assert.True(q.CanSubmit);
        q.State = QuestionState.Answered;
        Assert.False(q.CanSubmit);
        Assert.Equal("answered · A, C, also D · Red", q.Outcome);
    }

    [Fact]
    public void OpenBlockParsesAsksAndComposesTheReply()
    {
        const string text = """
            Done.

            ```
            ▶ 9 inside a fence — no / buttons
            ```
            ▶ 1 Close TokenChat so I can rebuild? — closed / later
            ▶ 2 Which name — the old one? — keep / rename it
            ▶ 3 Anything else?
            ▶ Run the tests? — yes / no
            """;
        var b = OpenBlock.Parse(text)!;
        Assert.Equal(new[] { "1", "2", "4" }, b.Asks.Select(a => a.Number));
        Assert.Equal("Which name — the old one?", b.Asks[1].Text);
        Assert.Equal(new[] { "keep", "rename it" }, b.Asks[1].Options.Select(o => o.Label));
        Assert.Null(b.Reply);
        Assert.False(b.CanSend);
        b.Asks[2].Options[0].Pick();
        b.Asks[0].Options[1].Pick();
        b.Asks[0].Options[0].Pick();
        Assert.Equal("1 closed, 4 yes", b.Reply);
        Assert.True(b.CanSend);
        Assert.Null(OpenBlock.Parse("no asks here\n▶ 1 nothing to press"));
    }

    [Fact]
    public void SendingAnyMessageClosesOpenBlocks()
    {
        var projector = new TranscriptProjector();
        projector.Apply(new MessageStartEvent("m1", null, new TokenUsage(), null));
        projector.Apply(new BlockStartEvent(0, "text", null, null, null));
        projector.Apply(new DeltaEvent(0, DeltaKind.Text, "Ok.\n\n▶ 1 Go? — go / stop", null));
        projector.Apply(new BlockStopEvent(0, null));
        var block = Assert.Single(projector.Items.OfType<AssistantTextItem>()).Open!;
        block.Asks[0].Options[0].Pick();
        Assert.True(block.CanSend);
        projector.AddUser(block.Reply!);
        Assert.True(block.IsClosed);
        Assert.False(block.CanSend);
        block.Asks[0].Options[1].Pick();
        Assert.Equal("1 go", block.Reply); // closed blocks ignore picks
    }
}
