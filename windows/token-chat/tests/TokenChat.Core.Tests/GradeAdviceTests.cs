using System.Text.Json.Nodes;
using TokenChat.Core.Analytics;

namespace TokenChat.Core.Tests;

public class GradeAdviceTests
{
    static JsonObject Overall(string held, string shortG, string churn, string control) => JsonNode.Parse($$$"""
        {"held":52,"short":7.3,"churn":8.8,"ctl":0.087,"cut_k":241.8,
         "grades":{"held":"{{{held}}}","short":"{{{shortG}}}","churn":"{{{churn}}}","control":"{{{control}}}"},
         "prev_grades":{"held":"A","short":"B","churn":"C","control":"B"}}
        """)!.AsObject();

    [Fact]
    public void ReadsLettersValuesAndThePreviousWeek()
    {
        var g = GradeAdvice.Read(Overall("D", "B", "C", "A"));
        Assert.Equal(["held", "short", "churn", "control"], g.Select(x => x.Axis));
        Assert.Equal("D", g[0].Letter);
        Assert.Equal("A", g[0].Previous);
        Assert.Equal("52%", g[0].Value);
        Assert.Contains("242k", g[0].Meaning);
        Assert.Equal("0.09", g[3].Value);
    }

    [Fact]
    public void SuggestsTheWorstTwoAtCOrBelow()
    {
        var s = GradeAdvice.Suggest(GradeAdvice.Read(Overall("C", "E", "D", "A")));
        Assert.Equal(2, s.Count);
        Assert.StartsWith("short E", s[0]);
        Assert.StartsWith("churn D", s[1]);
    }

    [Fact]
    public void NothingToSayWhenAllAreBOrBetter() =>
        Assert.Empty(GradeAdvice.Suggest(GradeAdvice.Read(Overall("A", "B", "B", "A"))));

    [Fact]
    public void NoGradesWithoutAFeed() => Assert.Empty(GradeAdvice.Read(null));

    [Theory]
    [InlineData("churn", 0, 0)]
    [InlineData("churn", 2, 1)]       // the A cut is A's right edge
    [InlineData("churn", 7.5, 2.5)]   // halfway through C (5 to 10)
    [InlineData("held", 52, 3.35)]    // D runs 45 to 65
    [InlineData("control", 9, 4.999)] // far past E stops at the edge
    public void PositionsSitInsideTheirLetterBand(string axis, double v, double at) =>
        Assert.Equal(at, Grade.Position(axis, v), 3);

    [Fact]
    public void CarriesRawValuesForThisWeekAndTheLast()
    {
        var o = Overall("A", "B", "C", "B");
        o["prev"] = JsonNode.Parse("""{"held":1.4,"short":5.7,"churn":7.2,"ctl":0.149}""");
        var g = GradeAdvice.Read(o);
        Assert.Equal(8.8, g[2].Raw);
        Assert.Equal(7.2, g[2].PreviousRaw);
        Assert.Equal(0.149, g[3].PreviousRaw);
    }
}
