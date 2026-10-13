namespace TokenChat.Core.Tests;

public class CheckpointTests
{
    [Fact]
    public void ParsesTheListingNewestFirst()
    {
        var list = Checkpoint.Parse("""
            {"checkpoints":[
              {"project":"token-chat","topic":"tokenchat-sidebar","cwd":"C:\\w\\token-chat","model":"claude-opus-5-5","effort":"high",
               "task":"sidebar","sid":"9780a5da-8253","age_min":104,"alive":0,"behind_min":0},
              {"project":"Pancreas-Trial-LFS","topic":"doctor-walk","cwd":"C:\\u\\p","age_min":3000,"alive":1,"behind_min":12},
              {"project":"x"}],
             "n":3,"now":1,"stale_after":10080}
            """)!;
        Assert.Equal(2, list.Count);
        Assert.Equal("/unpark tokenchat-sidebar", list[0].UnparkPrompt);
        Assert.Equal(@"C:\w\token-chat", list[0].Cwd);
        Assert.Equal(("claude-opus-5-5", "high", false), (list[0].Model, list[0].Effort, list[0].Alive));
        Assert.Equal((true, 12, ""), (list[1].Alive, list[1].BehindMin, list[1].Model));
        Assert.Null(Checkpoint.Parse("{\"sessions\":[]}"));
        Assert.Null(Checkpoint.Parse("not json"));
    }

    [Theory]
    [InlineData(0, "0m")]
    [InlineData(59, "59m")]
    [InlineData(60, "1h")]
    [InlineData(47 * 60 + 59, "47h")]
    [InlineData(48 * 60, "2d")]
    public void AgeReadsLikeTheWidget(int minutes, string age) =>
        Assert.Equal(age, new Checkpoint("", "t", "", "", "", "", "", minutes, false, 0).Age);
}
