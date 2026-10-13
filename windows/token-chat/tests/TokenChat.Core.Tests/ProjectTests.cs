namespace TokenChat.Core.Tests;

public class ProjectTests
{
    [Fact]
    public void SpellingsOfOneFolderAreOneProject()
    {
        Assert.Equal(Project.Key(@"C:\Work\token-chat"), Project.Key(@"c:/work/TOKEN-CHAT/"));
        Assert.Equal(Project.Slot(@"C:\Work\token-chat", 6), Project.Slot(@"c:/work/TOKEN-CHAT/", 6));
    }

    [Fact]
    public void TheRootKeepsItsSeparator() => Assert.Equal(@"C:\", Project.Key(@"c:\"));

    // Pinned: the slot must not move between runs, which string.GetHashCode would.
    [Fact]
    public void SlotIsStableAcrossRuns() => Assert.Equal(3, Project.Slot(@"C:\Work\token-chat", 6));

    [Fact]
    public void SlotsSpread()
    {
        var slots = new[] { "alpha", "gamma", "omega" }.Select(n => Project.Slot(@"C:\work\" + n, 6)).ToHashSet();
        Assert.All(slots, s => Assert.InRange(s, 0, 5));
        Assert.True(slots.Count > 1);
    }
}
