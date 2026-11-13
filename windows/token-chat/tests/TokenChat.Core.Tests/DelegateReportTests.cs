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

    [Fact]
    public void A_clean_report_goes_to_the_master_inline()
    {
        var r = DelegateReport.Parse("r.md", """
            <!-- report: for=abc sid=d1 topic=t branch=delegate/t worktree=C:\w status=done stop=met -->
            **Done**
            - [x] `a.cs:1` — one
            - [x] `b.cs:2` — two

            **Merge**: `git merge delegate/t`, then `git worktree remove C:\w`
            """)!;
        Assert.True(r.Clean);
        Assert.Equal(@"`git merge delegate/t`, then `git worktree remove C:\w`", r.Merge);
        Assert.StartsWith("[delegate t done, stop criteria met] Done: `a.cs:1` — one; `b.cs:2` — two. Merge: `git merge", r.Brief());
    }

    [Fact]
    public void A_blocked_or_old_report_is_read_in_full()
    {
        var blocked = DelegateReport.Parse("r.md", "<!-- report: for=abc topic=t status=blocked stop=unmet -->\n## Done\n- one\n## Merge\n- `git merge delegate/t`")!;
        Assert.Equal("`git merge delegate/t`", blocked.Merge);
        Assert.StartsWith("Read the delegate report at r.md (status=blocked, stop=unmet)", blocked.Brief());
        var old = DelegateReport.Parse("r.md", "<!-- report: for=abc topic=t -->\n## Done\n- one")!;
        Assert.False(old.Clean);
        Assert.StartsWith("Read the delegate report", old.Brief());
    }
}
