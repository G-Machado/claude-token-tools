using System.Text.Json.Nodes;
using TokenChat.Core.Protocol;
using TokenChat.Core.Remote;
using TokenChat.Core.Transcript;

namespace TokenChat.Core.Tests;

public class RemoteProjectionTests
{
    /// The page's model: rows by id plus the order. Applying every patch must end where a fresh snapshot is.
    sealed class Page
    {
        readonly Dictionary<int, string> _rows = [];
        List<int> _order = [];

        public void Apply(JsonObject msg)
        {
            foreach (var row in msg["items"]?.AsArray() ?? [])
            {
                var id = (int)row!["id"]!;
                _rows[id] = row.ToJsonString();
                if (msg["type"]!.GetValue<string>() == "snapshot") _order.Add(id);
            }
            if (msg["order"] is JsonArray order) _order = [.. order.Select(n => (int)n!)];
        }

        public string Render() => string.Join("\n", _order.Select(id => _rows[id]));
    }

    [Theory, MemberData(nameof(Fixture.All), MemberType = typeof(Fixture))]
    public void PatchesRebuildTheSnapshot(string fixture)
    {
        var projector = new TranscriptProjector();
        using var remote = new RemoteProjection(projector.Items);
        var page = new Page();
        page.Apply(remote.Snapshot());
        var patches = 0;
        foreach (var e in Fixture.Lines(fixture).Select(EventParser.Parse))
        {
            projector.Apply(e);
            projector.Flush();
            if (remote.Flush() is { } patch) { page.Apply(patch); patches++; }
        }
        Assert.True(patches > 0, "no patches from " + fixture);
        Assert.Null(remote.Flush());

        var fresh = new Page();
        fresh.Apply(remote.Snapshot());
        Assert.Equal(fresh.Render(), page.Render());
    }

    [Theory, MemberData(nameof(Fixture.All), MemberType = typeof(Fixture))]
    public void EveryRowHasAKnownKindAndFindsBack(string fixture)
    {
        var projector = new TranscriptProjector();
        foreach (var e in Fixture.Lines(fixture).Select(EventParser.Parse)) { projector.Apply(e); projector.Flush(); }
        using var remote = new RemoteProjection(projector.Items);
        var items = remote.Snapshot()["items"]!.AsArray();
        Assert.Equal(projector.Items.Count, items.Count);
        for (var i = 0; i < items.Count; i++)
        {
            Assert.NotEqual("unknown", items[i]!["k"]!.GetValue<string>());
            Assert.Same(projector.Items[i], remote.Find((int)items[i]!["id"]!));
        }
    }

    [Fact]
    public void AStateChangeResendsOnlyThatRow()
    {
        var projector = new TranscriptProjector();
        var card = new CardItem("block", "t", "x", [new CardAction("Lift", "lift", true)]);
        projector.Items.Add(new NoteItem(NoteKind.Info, "hi"));
        projector.Items.Add(card);
        using var remote = new RemoteProjection(projector.Items);
        remote.Snapshot();
        card.Outcome = "lifted";
        var patch = remote.Flush()!;
        Assert.Null(patch["order"]);
        var row = Assert.Single(patch["items"]!.AsArray())!;
        Assert.Equal("lifted", row["outcome"]!.GetValue<string>());
    }
}
