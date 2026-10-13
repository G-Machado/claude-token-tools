using TokenChat.Core.Protocol;
using TokenChat.Core.Transcript;

namespace TokenChat.Core.Tests;

public class ReplyTextTests
{
    [Theory]
    [InlineData("- one\n  - two", "* one\n  * two")]
    [InlineData("- **`-Probe`:** connects", "* **-Probe:** connects")]
    [InlineData("- Confirmed: the script parses", "* ✓ the script parses")]
    [InlineData("- Confirmed by `Get-CimInstance`: a child", "* ✓ `Get-CimInstance`: a child")]
    [InlineData("- verified (transcripts): no origin", "* ✓ (transcripts): no origin")]
    [InlineData("- Assumed: the old build", "* ? the old build")]
    [InlineData("Confirmed: not a list item", "Confirmed: not a list item")]
    [InlineData("```\n- kept\n**`kept`**\n```\n- after", "```\n- kept\n**`kept`**\n```\n* after")]
    [InlineData("a `**x**` code span", "a `**x**` code span")]
    public void TidyFixesWhatMdXamlMisdraws(string markdown, string expected) =>
        Assert.Equal(expected, ReplyText.Tidy(markdown));

    [Fact]
    public void DoneLineIsPlainWords()
    {
        var turn = new TurnItem(new ResultEvent("success", false, null, 24, new TokenUsage(44, 76_156, 1_460_000, 15_100), 1.2, 218_300, null, new Dictionary<string, ModelUsage>()));
        Assert.Equal("done in 3m 38s · 24 steps · Claude wrote 15.1k tokens · re-read 1.46M from cache · added 76.2k · ≈$1.20", turn.Summary);
    }
}
