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
}
