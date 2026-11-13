using TokenChat.Core.Protocol;

namespace TokenChat.Core.Tests;

public class MasterStateTests
{
    static Question Q(string text, params string[] labels) => new(text, null, false, labels.Select(l => new QuestionOption(l, null)).ToList());

    [Fact]
    public void A_label_matches_whatever_its_case()
    {
        var a = MasterState.AnswersFor([Q("Pick a colour?", "Red", "Blue")], "blue");
        Assert.Equal("Blue", a["Pick a colour?"]);
    }

    [Fact]
    public void Free_text_goes_in_as_typed()
    {
        var a = MasterState.AnswersFor([Q("Pick a colour?", "Red", "Blue")], "green, the brand one");
        Assert.Equal("green, the brand one", a["Pick a colour?"]);
    }

    [Fact]
    public void Several_questions_take_bar_separated_answers_in_order()
    {
        var a = MasterState.AnswersFor([Q("A?", "x", "y"), Q("B?", "p", "q")], "y | Q");
        Assert.Equal("y", a["A?"]);
        Assert.Equal("q", a["B?"]);
    }

    [Fact]
    public void A_count_mismatch_answers_every_question_with_the_whole_text()
    {
        var a = MasterState.AnswersFor([Q("A?", "x"), Q("B?", "p")], "skip both");
        Assert.Equal("skip both", a["A?"]);
        Assert.Equal("skip both", a["B?"]);
    }
}

public class MasterLogTests
{
    static Question Q(string text, params string[] labels) => new(text, null, false, labels.Select(l => new QuestionOption(l, null)).ToList());

    [Fact]
    public void A_repeat_is_answered_from_the_log_and_a_new_question_is_not()
    {
        var sid = "test-" + Guid.NewGuid().ToString("N");
        try
        {
            MasterLog.Append(sid, "a", [Q("Keep the old API?", "Yes", "No")], new Dictionary<string, string> { ["Keep the old API?"] = "No" }, "the master");
            MasterLog.Append(sid, "b", [Q("Keep the old API?", "Yes", "No")], new Dictionary<string, string> { ["Keep the old API?"] = "Yes" }, "the master");
            Assert.Equal("Yes", MasterLog.Lookup(sid, [Q("keep the old  API", "No", "Yes")])!["keep the old  API"]);
            Assert.Null(MasterLog.Lookup(sid, [Q("Keep the old API?", "Yes", "No", "Ask me later")]));
            Assert.Null(MasterLog.Lookup(sid, [Q("Keep the old API?", "Yes", "No"), Q("Rename it?", "Yes", "No")]));
        }
        finally { File.Delete(MasterLog.FileOf(sid)); }
    }
}

public class MasterLineageTests
{
    static MasterState M(string sid, string? from = null, params string[] lineage) => new(sid, false, null, [], from, lineage);

    [Fact]
    public void A_sid_from_two_handovers_ago_resolves_to_the_current_master()
    {
        var c = M("C", "B", "A", "B");
        Assert.Equal("C", MasterState.Resolve("A", [c])!.Sid);
        Assert.Equal("C", MasterState.Resolve("B", [c])!.Sid);
        Assert.Equal("C", MasterState.Resolve("c", [c])!.Sid);
        Assert.True(c.Holds("A") && c.Holds("B") && c.Holds("C"));
    }

    [Fact]
    public void A_file_with_only_handedFrom_still_resolves_one_hop()
    {
        var b = M("B", "A");
        Assert.Equal("B", MasterState.Resolve("A", [b])!.Sid);
        Assert.Null(MasterState.Resolve("Z", [b]));
        Assert.Null(MasterState.Resolve(null, [b]));
    }

    [Fact]
    public void A_master_that_is_its_own_file_never_resolves_to_another()
    {
        var x = M("X"); var y = M("Y", "X", "X");
        Assert.Equal("X", MasterState.Resolve("X", [y, x])!.Sid);
    }

    [Fact]
    public void A_report_for_an_old_sid_is_held_by_the_current_master()
    {
        var r = DelegateReport.Parse("p.md", "<!-- report: for=A sid=d topic=t branch=b worktree=w status=done stop=met -->\n**Done**\n- x\n")!;
        Assert.True(M("C", "B", "A", "B").Holds(r.For));
        Assert.False(M("C", "B", "B").Holds(r.For));
    }
}
