using System.Text;
using System.Text.Json.Nodes;

namespace TokenChat.Core.Tests;

public class AttachmentTests
{
    [Fact]
    public void ImageTokensMatchTheProbe()
    {
        // measured on claude-opus-5-5: ~1.55k and ~4.13k
        Assert.InRange(Attachments.ImageTokens(1000, 1000), 1500, 1600);
        Assert.InRange(Attachments.ImageTokens(2000, 1500), 4080, 4180);
    }

    [Theory]
    [InlineData(1000, 800, 1000, 800)]
    [InlineData(2000, 1500, 1568, 1176)]
    [InlineData(1500, 3000, 784, 1568)]
    [InlineData(1568, 10, 1568, 10)]
    public void FitWithinScalesOnlyTheLongEdgeOver(int w, int h, int fw, int fh) =>
        Assert.Equal((fw, fh), Attachments.FitWithin(w, h));

    [Fact]
    public void ImageOverTheLimitIsRefused() =>
        Assert.Throws<AttachmentException>(() => Attachments.Image("big.png", "image/png", new byte[Attachments.ImageMaxBytes + 1], 10, 10));

    [Fact]
    public void PdfCountsPagesAndBecomesADocumentBlock()
    {
        var a = Attachments.Pdf("doc.pdf", Pdf(3));
        Assert.Equal(AttachmentKind.Pdf, a.Kind);
        Assert.Equal("3 pages", a.Detail);
        Assert.Equal(3 * 1600, a.Tokens);
        Assert.Equal("document", (string?)a.Block["type"]);
        Assert.Equal("application/pdf", (string?)a.Block["source"]!["media_type"]);
    }

    [Fact]
    public void PdfPagesFallsBackToThePageTreeCount() =>
        Assert.Equal(12, Attachments.PdfPages(Encoding.Latin1.GetBytes("%PDF-1.7\n1 0 obj << /Type /Pages /Kids [3 0 R] /Count 12 >>")));

    [Fact]
    public void ShortTextIsInlinedWithItsPath()
    {
        var a = Attachments.File(@"C:\p\notes.md", Encoding.UTF8.GetBytes("one\ntwo\n"));
        Assert.Equal(AttachmentKind.Text, a.Kind);
        Assert.Equal("notes.md", a.Name);
        Assert.Equal("2 lines", a.Detail);
        Assert.Equal("<file path=\"C:\\p\\notes.md\">\none\ntwo\n</file>", (string?)a.Block["text"]);
    }

    [Fact]
    public void LongTextGoesAsItsPath()
    {
        var text = string.Join("\n", Enumerable.Range(1, Attachments.InlineMaxLines + 1));
        var a = Attachments.File(@"C:\p\big.cs", Encoding.UTF8.GetBytes(text));
        Assert.Equal(AttachmentKind.Path, a.Kind);
        Assert.Equal($"path only: {Attachments.InlineMaxLines + 1} lines", a.Detail);
        Assert.DoesNotContain("\n250\n", (string?)a.Block["text"]);
        Assert.True(a.Tokens < 50);
    }

    [Fact]
    public void MinifiedOneLinerGoesAsItsPath() =>
        Assert.Equal(AttachmentKind.Path, Attachments.File("app.min.js", Encoding.UTF8.GetBytes(new string('x', Attachments.InlineMaxChars + 1))).Kind);

    [Fact]
    public void BinaryGoesAsItsPath() =>
        Assert.Equal("path only: binary", Attachments.File("a.bin", [1, 2, 0, 3]).Detail);

    [Fact]
    public void BlocksPutFilesBeforeTheText()
    {
        var file = Attachments.File("a.txt", "hi"u8.ToArray());
        var blocks = Attachments.Blocks("look", [file]);
        Assert.Equal(2, blocks.Count);
        Assert.StartsWith("<file", (string?)blocks[0]!["text"]);
        Assert.Equal("look", (string?)blocks[1]!["text"]);
        Assert.Single(Attachments.Blocks("", [file]));
    }

    /// <summary>A minimal PDF with n page objects.</summary>
    static byte[] Pdf(int n)
    {
        var sb = new StringBuilder("%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n");
        sb.Append($"2 0 obj << /Type /Pages /Count {n} /Kids [] >> endobj\n");
        for (var i = 0; i < n; i++) sb.Append($"{i + 3} 0 obj << /Type /Page /Parent 2 0 R >> endobj\n");
        return Encoding.Latin1.GetBytes(sb.ToString());
    }
}
