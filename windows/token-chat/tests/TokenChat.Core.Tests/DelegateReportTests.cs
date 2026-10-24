namespace TokenChat.Core.Tests;

public class DelegateReportTests
{
    [Fact]
    public void ParsesHeaderAndDoneList()
    {
        var r = DelegateReport.Parse("r.md", """
            <!-- report: for=deb49ef3-0a36 sid=1234abcd topic=test-delegate branch=delegate/test-delegate worktree=C:\w\repo-test-delegate -->
            # token-chat — test-delegate report

            **Done**
            - [x] `scratch.txt:1` — added a line
            - [ ] `b.cs:9` — unverified

            **Basis**
            - `cat scratch.txt` — confirmed
            """)!;
        Assert.Equal(("deb49ef3-0a36", "1234abcd", "test-delegate"), (r.For, r.Sid, r.Topic));
        Assert.Equal(("delegate/test-delegate", @"C:\w\repo-test-delegate"), (r.Branch, r.Worktree));
        Assert.Equal(["`scratch.txt:1` — added a line", "`b.cs:9` — unverified"], r.Done);
    }

    [Theory]
    [InlineData("<!-- park: session=x topic=y -->\n**Done**\n- a")]
    [InlineData("<!-- report: sid=x topic=y -->")]
    [InlineData("")]
    public void RejectsNonReports(string text) => Assert.Null(DelegateReport.Parse("r.md", text));

    [Fact]
    public void HeaderWithoutSpaceBeforeCloser()
    {
        var r = DelegateReport.Parse("r.md", "<!-- report: for=abc topic=t-->\n## Done\n- one\n## Merge\n- two")!;
        Assert.Equal(("abc", "t"), (r.For, r.Topic));
        Assert.Equal(["one"], r.Done);
    }
}
