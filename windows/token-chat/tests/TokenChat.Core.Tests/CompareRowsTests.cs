using TokenChat.Core.Analytics;

namespace TokenChat.Core.Tests;

public class CompareRowsTests
{
    static CycleRow Row(int cycle, long output, double? cost, CostSource source = CostSource.Cli, long growth = 0) =>
        new(new CycleStats(cycle, $"p{cycle}", new TokenUsage(0, 0, 0, output), 0, growth, 0, 1, [], "claude-opus-5-5"),
            new TokenUsage(0, 0, 0, output), cost, source, output > 20_000 ? BudgetClass.Over : BudgetClass.Recon);

    static CycleRow Side(long output) => new(null, new TokenUsage(0, 0, 0, output), 0.01, CostSource.Cli, null);

    [Fact]
    public void RowsAlignByCycleAndASideRequestKeepsItsPlace()
    {
        var rows = CompareRows.Align([Row(1, 1, 0.1), Row(2, 2, 0.1), Row(3, 3, 0.1)],
            [Row(1, 1, 0.1), Row(2, 2, 0.1), Side(9), Row(3, 3, 0.1), Row(4, 4, 0.1)]);
        Assert.Equal(["1", "2", "side", "3", "4"], rows.Select(r => r.Label));
        Assert.Null(rows[2].A);
        Assert.Equal(9, rows[2].B!.Usage.Output);
        Assert.Null(rows[4].A);
        Assert.Equal(3, rows[3].A!.Cycle!.Index);
    }

    [Fact]
    public void TotalsSkipUnpricedRowsAndMarkTheMix()
    {
        var t = CycleTotals.Of([Row(1, 30_000, 0.5, growth: 7), Row(2, 10, null, CostSource.None, growth: 5), Side(4)]);
        Assert.Equal(2, t.Cycles);
        Assert.Equal(30_014, t.Usage.Output);
        Assert.Equal(12, t.Growth);
        Assert.Equal(0.51, t.CostUsd!.Value, 9);
        Assert.Equal(CostSource.Mixed, t.Source);
        Assert.Equal(1, t.Over);
        Assert.Null(CycleTotals.Of([Row(1, 1, null, CostSource.None)]).CostUsd);
    }

    [Fact]
    public void IndexListsNewestFirstTitlesFromTheTailAndSkipsSubagents()
    {
        var root = Directory.CreateTempSubdirectory("tc-index").FullName;
        try
        {
            var project = Directory.CreateDirectory(Path.Combine(root, "C--work-proj")).FullName;
            Directory.CreateDirectory(Path.Combine(project, "s1", "subagents"));
            File.WriteAllText(Path.Combine(project, "s1", "subagents", "agent.jsonl"), "{}\n");
            File.WriteAllLines(Path.Combine(project, "s1.jsonl"),
                ["""{"cwd":"C:\\work\\proj"}""", """{"type":"ai-title","aiTitle":"Old"}""", """{"type":"ai-title","aiTitle":"Say \"hi\""}"""]);
            File.WriteAllLines(Path.Combine(project, "s2.jsonl"),
                ["{\"type\":\"ai-title\",\"aiTitle\":\"Auto\"}", "{\"type\":\"custom-title\",\"customTitle\":\"Mine\"}"]);
            File.SetLastWriteTimeUtc(Path.Combine(project, "s1.jsonl"), DateTime.UtcNow.AddHours(-1));

            var files = TranscriptIndex.Recent(root);
            Assert.Equal(["s2", "s1"], files.Select(f => f.SessionId));
            Assert.Equal("Mine", files[0].Title);
            Assert.Equal("Say \"hi\"", files[1].Title);
            Assert.Equal("proj", files[1].Project);
            Assert.Equal("C--work-proj", files[0].Project);
            Assert.Equal(Path.Combine(project, "s1.jsonl"), TranscriptIndex.Find(root, "s1"));
            Assert.Null(TranscriptIndex.Find(root, "nope"));
        }
        finally { Directory.Delete(root, true); }
    }
}
