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
        var tools = Replay(fixture).Projector.Items.OfType<ToolUseItem>().ToList();
        Assert.All(tools, t =>
        {
            Assert.NotEmpty(t.Summary);
            Assert.NotNull(t.Result);
        });
    }

    [Fact]
    public void PermissionRequestsBecomePendingCards()
    {
        var (projector, events) = Replay("perm");
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
}
