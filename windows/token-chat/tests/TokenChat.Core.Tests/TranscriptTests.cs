using TokenChat.Core.Protocol;
using TokenChat.Core.Transcript;

namespace TokenChat.Core.Tests;

public class TranscriptTests
{
    static (TranscriptProjector Projector, List<ClaudeEvent> Events) Replay(string fixture)
    {
        var projector = new TranscriptProjector();
        var events = Fixture.Lines(fixture).Select(EventParser.Parse).ToList();
        foreach (var e in events)
        {
            projector.Apply(e);
            projector.Flush();
        }
        return (projector, events);
    }

    /// The CLI's result text is the oracle for what the streamed text rows must end up showing.
    [Theory, MemberData(nameof(Fixture.All), MemberType = typeof(Fixture))]
    public void LastTextRowOfEachTurnMatchesResultText(string fixture)
    {
        var items = Replay(fixture).Projector.Items;
        var turns = 0;
        var turnStart = 0;
        for (var i = 0; i < items.Count; i++)
        {
            if (items[i] is not TurnItem turn) continue;
            // A local slash command ends a turn with result text but no assistant message.
            var last = items.Skip(turnStart).Take(i - turnStart).OfType<AssistantTextItem>().LastOrDefault();
            turnStart = i + 1;
            if (turn.Result is not { Subtype: "success", Text: { Length: > 0 } expected } || last is null) continue;
            Assert.Equal(expected.Trim(), last.Text.Trim());
            Assert.False(last.IsStreaming);
            turns++;
        }
        Assert.True(turns > 0, "no successful turn with text in " + fixture);
    }

    [Theory, MemberData(nameof(Fixture.All), MemberType = typeof(Fixture))]
    public void EveryToolRowGetsSummaryAndResult(string fixture)
    {
        var tools = Replay(fixture).Projector.Tools.ToList();
        Assert.All(tools, t =>
        {
            Assert.NotEmpty(t.Summary);
            Assert.NotNull(t.Result);
        });
    }

    [Fact]
    public void PermissionRequestsBecomePendingCards()
    {
        // the recording answered every prompt; replayed without those replies, a turn end would cancel the cards
        var projector = new TranscriptProjector();
        var events = Fixture.Lines("perm").Select(EventParser.Parse).ToList();
        foreach (var e in events.Where(e => e is not ResultEvent)) projector.Apply(e);
        var cards = projector.Items.OfType<PermissionItem>().ToList();
        Assert.Equal(events.OfType<PermissionRequest>().Count(), cards.Count);
        Assert.NotEmpty(cards);
        Assert.All(cards, c => Assert.Equal(PermissionState.Pending, c.State));
    }

    [Fact]
    public void DeltasStayInvisibleUntilFlush()
    {
        var projector = new TranscriptProjector();
        // Stop before the block stop, which flushes on purpose.
        var text = Fixture.Lines("slim").Select(EventParser.Parse)
            .TakeWhile(e => e is not BlockStopEvent).ToList();
        foreach (var e in text) projector.Apply(e);
        var row = projector.Items.OfType<AssistantTextItem>().First();
        var deltas = text.OfType<DeltaEvent>().Where(d => d.Kind == DeltaKind.Text).ToList();
        Assert.NotEmpty(deltas);
        Assert.Equal("", row.Text);
        projector.Flush();
        Assert.Equal(string.Concat(deltas.Select(d => d.Text)), row.Text);
    }

    [Fact]
    public void SubagentTrafficIsSkipped()
    {
        var projector = new TranscriptProjector();
        projector.Apply(new BlockStartEvent(0, "text", null, null, ParentToolUseId: "toolu_x"));
        Assert.Empty(projector.Items);
    }

    [Fact]
    public void ToolWithoutResultAtTurnEndIsStopped()
    {
        var projector = new TranscriptProjector();
        projector.Apply(new MessageStartEvent("m1", null, new TokenUsage(), null));
        projector.Apply(new BlockStartEvent(0, "tool_use", "Bash", "toolu_1", null));
        projector.Apply(new BlockStopEvent(0, null));
        var tool = Assert.Single(projector.Items.OfType<ToolUseItem>());
        Assert.False(tool.IsInterrupted);
        projector.Apply(new ResultEvent("error_during_execution", true, null, 1, new TokenUsage(), 0, 10, null));
        Assert.True(tool.IsInterrupted);
        var late = System.Text.Json.Nodes.JsonNode.Parse("""[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"}]""");
        projector.Apply(new UserEvent(late, null));
        Assert.False(tool.IsInterrupted);
        Assert.Equal("ok", tool.Result);
    }

    /// Stop while cards wait: the CLI withdraws them and ends the turn with error_during_execution.
    [Fact]
    public void StopCancelsPendingCardsAndIsNoError()
    {
        var projector = new TranscriptProjector();
        var input = new System.Text.Json.Nodes.JsonObject();
        projector.Apply(new PermissionRequest("p1", "Edit", input, null, "toolu_1", null));
        projector.Apply(new PermissionRequest("p2", "Bash", input, null, "toolu_2", null));
        projector.Apply(new QuestionRequest("q1", "toolu_3", input, []));
        var cards = projector.Items.OfType<PermissionItem>().ToList();
        cards[1].State = PermissionState.Allowed;
        Assert.IsType<PromptCancelledEvent>(EventParser.Parse("""{"type":"control_cancel_request","request_id":"p1"}"""));
        projector.Apply(EventParser.Parse("""{"type":"control_cancel_request","request_id":"p1"}"""));
        Assert.Equal(PermissionState.Cancelled, cards[0].State);
        Assert.Equal(QuestionState.Pending, projector.Items.OfType<QuestionItem>().Single().State);

        projector.Apply(new UserEvent(System.Text.Json.Nodes.JsonValue.Create("[Request interrupted by user]"), null));
        projector.Apply(new ResultEvent("error_during_execution", true, null, 1, new TokenUsage(), 0, 10, "aborted_streaming"));
        Assert.Equal(PermissionState.Allowed, cards[1].State);
        Assert.Equal(QuestionState.Cancelled, projector.Items.OfType<QuestionItem>().Single().State);
        var turn = projector.Items.OfType<TurnItem>().Single();
        Assert.True(turn.IsStopped);
        Assert.False(turn.IsError);
        Assert.StartsWith("stopped ·", turn.Summary);
    }
}
