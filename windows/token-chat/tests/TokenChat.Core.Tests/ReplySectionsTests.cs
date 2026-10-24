using TokenChat.Core.Transcript;

namespace TokenChat.Core.Tests;

public class ReplySectionsTests
{
    const string Reply = """
        **Pushed 11 commits.**

        **Done**
        - [x] `a.cs:12` — parser added
        - [ ] `b.xaml:40` — fold template,
          not run yet

        **Basis**
        - Confirmed by `git push`: master moved
        - Assumed: the tab picks it up

        ▶ 1 Restart now? — yes / later
        """;

    [Fact]
    public void DoneAndBasisLeaveTheBody()
    {
        var s = ReplySections.Parse(Reply)!;
        Assert.Equal("**Pushed 11 commits.**\n\n▶ 1 Restart now? — yes / later", s.Body);
        Assert.Equal(["`a.cs:12` — parser added", "`b.xaml:40` — fold template, not run yet"], s.Done!.Items.Select(i => i.Text));
        Assert.Equal([true, false], s.Done.Items.Select(i => i.IsChecked));
        Assert.Equal("1/2", s.Done.Count);
        Assert.True(s.Done.IsExpanded);
        Assert.False(s.Basis!.IsExpanded);
        Assert.False(s.Basis.IsChecklist);
        Assert.Equal("2 refs", s.Basis.Count);
        Assert.StartsWith("* ✓ `git push`", s.Basis.Markdown, StringComparison.Ordinal);
    }

    [Fact]
    public void TickingCounts()
    {
        var done = ReplySections.Parse(Reply)!.Done!;
        done.Items[1].IsChecked = true;
        Assert.Equal("2/2", done.Count);
    }

    [Theory]
    [InlineData("Just an answer.")]
    [InlineData("```\n**Done**\n- [x] in a fence\n```")]
    [InlineData("**Done**\n\nprose, no list")]
    public void NoSectionsLeavesNothing(string markdown) => Assert.Null(ReplySections.Parse(markdown));

    [Fact]
    public void TicksComeBackFromTheStore()
    {
        var path = Path.GetTempFileName();
        try
        {
            var key = ReplySections.Parse(Reply)!.Done!.Items[1].Key;
            TickStore.Record(path, key, true);
            Assert.True(TickStore.Load(path)[key]);
            TickStore.Record(path, key, false);
            Assert.False(TickStore.Load(path)[key]);
        }
        finally { File.Delete(path); }
    }
}
