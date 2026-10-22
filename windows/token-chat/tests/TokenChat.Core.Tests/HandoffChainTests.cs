namespace TokenChat.Core.Tests;

public class HandoffChainTests
{
    static string TempFile() => Path.Combine(Path.GetTempPath(), $"handoffs-{Guid.NewGuid():N}.tsv");

    [Fact]
    public void A_session_with_no_line_took_nothing_over()
    {
        Assert.Empty(HandoffChain.Olds(TempFile(), "b"));
    }

    [Fact]
    public void Olds_come_back_oldest_first_and_the_latest_line_wins()
    {
        var path = TempFile();
        HandoffChain.Record(path, "b", ["a"]);
        HandoffChain.Record(path, "c", ["a", "b"]);
        HandoffChain.Record(path, "B", ["a2"]);
        Assert.Equal(["a", "b"], HandoffChain.Olds(path, "c"));
        Assert.Equal(["a2"], HandoffChain.Olds(path, "b"));
        File.Delete(path);
    }

    [Fact]
    public void An_empty_chain_is_not_recorded_and_the_file_keeps_its_tail()
    {
        var path = TempFile();
        HandoffChain.Record(path, "x", []);
        Assert.False(File.Exists(path));
        for (var i = 0; i < 205; i++) HandoffChain.Record(path, $"s{i}", ["o"]);
        Assert.Equal(200, File.ReadAllLines(path).Length);
        Assert.Empty(HandoffChain.Olds(path, "s0"));
        Assert.Equal(["o"], HandoffChain.Olds(path, "s204"));
        File.Delete(path);
    }
}
