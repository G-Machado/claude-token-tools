namespace TokenChat.Core.Tests;

public class SessionControlTests
{
    [Theory]
    [InlineData(2, 0, 5, 1, 3)]   // one more
    [InlineData(2, 0, 5, -1, 1)]  // one fewer
    [InlineData(5, 1, 5, 1, 5)]   // the cap holds
    [InlineData(2, 2, 5, -1, 2)]  // spent marks cannot be taken back
    [InlineData(0, 0, 5, -1, 0)]  // never below none
    public void MarksStayBetweenSpentAndTheCap(int allowed, int used, int cap, int delta, int want) =>
        Assert.Equal(want, SessionControl.NextMarks(allowed, used, cap, delta));

    [Fact]
    public void ExtendTakesTheShortId()
    {
        Assert.Equal(["--extend", "6252e5c7", "3"], SessionControl.Extend("6252e5c7-6caa-4cd4-aa7b-f6e7415e54eb", 3));
        Assert.Equal(["--unblock", "6252e5c7-6caa"], SessionControl.Unblock("6252e5c7-6caa"));
    }

    [Fact]
    public void ASwitchBurnsEveryWarmWindowOverTheFloorAndNamesTheUnparkedBigOnes()
    {
        var feed = FeedSnapshot.Parse("""
            {"generated":1,"constants":{"park_at":86.1},"sessions":[
              {"sid":"a","nick":"big","alive":1,"cache_left_min":30,"context":120000,"context_k":120,"parked":0},
              {"sid":"b","nick":"parked","alive":1,"cache_left_min":10,"context":100000,"context_k":100,"parked":1},
              {"sid":"c","nick":"cold","alive":1,"cache_left_min":0,"context":150000,"context_k":150,"parked":0},
              {"sid":"d","nick":"small","alive":1,"cache_left_min":50,"context":15000,"context_k":15,"parked":0},
              {"sid":"e","nick":"closed","alive":0,"cache_left_min":50,"context":90000,"context_k":90,"parked":0}]}
            """);
        var (windows, tokens, unparked) = SessionControl.SwitchBurn(feed);
        Assert.Equal(2, windows);
        Assert.Equal((100_000 + 80_000) * 2, tokens);
        Assert.Equal(["big"], unparked);
        Assert.Equal(0, SessionControl.SwitchBurn(null).Windows);
    }
}
