using System.Text.Json.Nodes;
using TokenChat.Core.Protocol;
using TokenChat.Core.Transcript;

namespace TokenChat.Core.Tests;

public class PermissionPreviewTests
{
    static string Lines(int from, int to) => string.Join("\n", Enumerable.Range(from, to - from + 1));

    [Fact]
    public void DiffFoldsUnchangedRunsToThreeLinesOfContext()
    {
        var before = Lines(1, 20);
        var after = before.Replace("\n10\n", "\nten\n");
        var rows = LineDiff.Compute(before, after);
        Assert.Equal(
            [DiffKind.Gap, DiffKind.Same, DiffKind.Same, DiffKind.Same, DiffKind.Removed, DiffKind.Added,
             DiffKind.Same, DiffKind.Same, DiffKind.Same, DiffKind.Gap],
            rows.Select(r => r.Kind));
        Assert.Equal("⋯ 6 unchanged lines", rows[0].Text);
        Assert.Equal(["7", "8", "9", "10", "ten", "11", "12", "13"], rows[1..9].Select(r => r.Text));
        Assert.Equal("⋯ 7 unchanged lines", rows[^1].Text);
    }

    [Fact]
    public void DiffKeepsCommonLinesBetweenChanges()
    {
        var rows = LineDiff.Compute("a\r\nb\r\nc\r\nd", "a\nx\nc\ny\nd");
        Assert.Equal(["=a", "-b", "+x", "=c", "+y", "=d"],
            rows.Select(r => (r.Kind switch { DiffKind.Added => "+", DiffKind.Removed => "-", _ => "=" }) + r.Text));
    }

    [Fact]
    public void NewFileIsAllAddedAndCappedAtMaxLines()
    {
        Assert.Equal([DiffKind.Added, DiffKind.Added], LineDiff.Compute("", "a\nb\n").Select(r => r.Kind));
        var rows = LineDiff.Compute("", Lines(1, 500));
        Assert.Equal(LineDiff.MaxLines + 1, rows.Count);
        Assert.Equal("⋯ 100 more lines", rows[^1].Text);
    }

    [Fact]
    public void SessionRulesRetargetSuggestionsAndNameWhatTheyGrant()
    {
        var suggestions = (JsonArray)JsonNode.Parse("""
            [{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm test:*"}],"behavior":"allow","destination":"localSettings"},
             {"type":"setMode","mode":"acceptEdits","destination":"session"},
             {"type":"removeRules","rules":[{"toolName":"Bash"}],"behavior":"deny","destination":"session"}]
            """)!;
        var (rules, label) = PermissionRules.ForSession(suggestions)!.Value;
        Assert.Equal(2, rules.Count);
        Assert.All(rules, r => Assert.Equal("session", (string?)r!["destination"]));
        Assert.Equal("Allow Bash(npm test:*), edits this session", label);
        Assert.Equal("localSettings", (string?)suggestions[0]!["destination"]); // the request's own copy is untouched
        Assert.Null(PermissionRules.ForSession(null));
        Assert.Null(PermissionRules.ForSession([]));
    }

    [Fact]
    public void AllowCarriesUpdatedPermissionsOnlyWhenGiven()
    {
        var input = new JsonObject { ["command"] = "ls" };
        var plain = JsonNode.Parse(Outbound.Allow("r1", input))!["response"]!["response"]!;
        Assert.Null(plain["updatedPermissions"]);
        var rules = new JsonArray(new JsonObject { ["type"] = "setMode", ["mode"] = "acceptEdits", ["destination"] = "session" });
        var withRules = JsonNode.Parse(Outbound.Allow("r1", input, rules))!["response"]!["response"]!;
        Assert.Equal("acceptEdits", (string?)withRules["updatedPermissions"]![0]!["mode"]);
    }

    [Fact]
    public void ProjectorPreviewsWriteAgainstTheFileOnDisk()
    {
        var projector = new TranscriptProjector { ReadFile = p => p == "C:/x.txt" ? "one\ntwo" : null };
        var write = new JsonObject { ["file_path"] = "C:/x.txt", ["content"] = "one\n2" };
        projector.Apply(new PermissionRequest("r1", "Write", write, null, "tu1", null));
        projector.Apply(new PermissionRequest("r2", "Write", new JsonObject { ["file_path"] = "C:/new.txt", ["content"] = "hi" }, null, "tu2", null));
        projector.Apply(new PermissionRequest("r3", "Bash", new JsonObject { ["command"] = "ls" }, null, "tu3", null));
        var cards = projector.Items.OfType<PermissionItem>().ToList();
        Assert.Equal("overwrites the file", cards[0].DiffNote);
        Assert.Equal([DiffKind.Same, DiffKind.Removed, DiffKind.Added], cards[0].Diff!.Select(r => r.Kind));
        Assert.Equal("new file", cards[1].DiffNote);
        Assert.Null(cards[2].Diff);
        Assert.Null(cards[2].SessionLabel);
    }
}
