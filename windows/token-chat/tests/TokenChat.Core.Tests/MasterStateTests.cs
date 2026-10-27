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
