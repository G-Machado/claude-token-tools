using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using TokenChat.Core.Protocol;
using TokenChat.Core.Transcript;

namespace TokenChat.Core;

public enum AttachmentKind { Image, Pdf, Text, Path }

/// <summary>A file going out with the next message: its content block and what it should cost in prompt tokens.</summary>
public sealed class Attachment(string name, AttachmentKind kind, int tokens, JsonObject block, string? detail = null)
{
    public string Name { get; } = name;
    public AttachmentKind Kind { get; } = kind;
    /// <summary>An estimate: the measured rates in <see cref="Attachments"/>, not a count from the API.</summary>
    public int Tokens { get; } = tokens;
    public JsonObject Block { get; } = block;
    /// <summary>"1568×1176", "3 pages", "120 lines", "path only: 2400 lines".</summary>
    public string? Detail { get; } = detail;
    public string Label => $"{Name} · ≈{Transcript.Tokens.K(Tokens)}";
}

/// <summary>Turns files into content blocks. Rates measured on claude-opus-5-5 over headless stream-json, 2026-10-01
/// (memory headless-attachments.md): images ~255 + w·h/772 and no server downscale, PDF ~1.6k a page,
/// a text document block ~150 overhead (so text goes as a plain text block).</summary>
public static class Attachments
{
    /// <summary>Longer images are scaled down to this edge before sending; 2000×1500 costs ~4.1k, ~2.6k at 1568.</summary>
    public const int ImageMaxEdge = 1568;
    /// <summary>Assumed API limit: 5 MB of base64 a picture, so 3.75 MB of bytes.</summary>
    public const int ImageMaxBytes = 3_750_000;
    /// <summary>Assumed API limits for one PDF.</summary>
    public const int PdfMaxPages = 100, PdfMaxBytes = 32 << 20;
    /// <summary>Longer text goes as its path for Claude to read in ranges (the CLAUDE.md 500-line rule);
    /// the character cap catches minified one-line files.</summary>
    public const int InlineMaxLines = 500, InlineMaxChars = 80_000;
    const int PdfPageTokens = 1600;

    public static readonly IReadOnlySet<string> ImageTypes = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        { ".png", ".jpg", ".jpeg", ".gif", ".webp" };

    public static int ImageTokens(int width, int height) => 255 + (int)((long)width * height / 772);

    /// <summary>The size an image is sent at: unchanged unless its long edge is over <paramref name="maxEdge"/>.</summary>
    public static (int Width, int Height) FitWithin(int width, int height, int maxEdge = ImageMaxEdge)
    {
        var edge = Math.Max(width, height);
        if (edge <= maxEdge) return (width, height);
        var k = (double)maxEdge / edge;
        return (Math.Max(1, (int)Math.Round(width * k)), Math.Max(1, (int)Math.Round(height * k)));
    }

    public static string MediaType(string extension) => extension.ToLowerInvariant() switch
    {
        ".jpg" or ".jpeg" => "image/jpeg",
        ".gif" => "image/gif",
        ".webp" => "image/webp",
        _ => "image/png",
    };

    /// <summary>Bytes already sized for sending (see <see cref="FitWithin"/>).</summary>
    public static Attachment Image(string name, string mediaType, byte[] data, int width, int height)
    {
        if (data.Length > ImageMaxBytes) throw new AttachmentException($"{name}: {data.Length / 1_000_000.0:0.#} MB after scaling, over the {ImageMaxBytes / 1_000_000.0:0.##} MB limit");
        return new(name, AttachmentKind.Image, ImageTokens(width, height), Outbound.ImageBlock(mediaType, data), $"{width}×{height}");
    }

    public static Attachment Pdf(string name, byte[] data)
    {
        if (data.Length > PdfMaxBytes) throw new AttachmentException($"{name}: over the {PdfMaxBytes >> 20} MB PDF limit");
        var pages = PdfPages(data);
        if (pages > PdfMaxPages) throw new AttachmentException($"{name}: {pages} pages, over the {PdfMaxPages}-page PDF limit");
        var known = Math.Max(pages, 1);
        return new(name, AttachmentKind.Pdf, known * PdfPageTokens, Outbound.DocumentBlock("application/pdf", data),
            pages == 0 ? "pages unknown" : pages == 1 ? "1 page" : $"{pages} pages");
    }

    /// <summary>Page objects, or the page tree's count when they hide in compressed object streams; 0 if neither shows.</summary>
    public static int PdfPages(byte[] data)
    {
        var s = Encoding.Latin1.GetString(data);
        var pages = Regex.Count(s, @"/Type\s*/Page(?![a-zA-Z])");
        var counts = Regex.Matches(s, @"/Type\s*/Pages\b[^>]*?/Count\s+(\d+)|/Count\s+(\d+)[^>]*?/Type\s*/Pages\b")
            .Select(m => int.Parse(m.Groups[1].Success ? m.Groups[1].Value : m.Groups[2].Value));
        return Math.Max(pages, counts.DefaultIfEmpty(0).Max());
    }

    /// <summary>Inline as a plain text block when short; otherwise the path, for Claude to read the parts it needs.
    /// Binary files (a NUL in the first 8000 bytes) are always the path.</summary>
    public static Attachment File(string path, byte[] data)
    {
        var name = System.IO.Path.GetFileName(path);
        if (data.AsSpan(0, Math.Min(data.Length, 8000)).Contains((byte)0))
            return PathOnly(name, path, "binary file", "path only: binary");
        var text = DecodeText(data);
        var lines = text.Length == 0 ? 0 : text.TrimEnd('\n', '\r').Split('\n').Length;
        if (lines > InlineMaxLines || text.Length > InlineMaxChars)
            return PathOnly(name, path, $"{lines} lines, too long to inline; read the parts you need", $"path only: {lines} lines");
        var body = $"<file path=\"{path}\">\n{text.TrimEnd('\n', '\r')}\n</file>";
        return new(name, AttachmentKind.Text, TextTokens(body), Outbound.TextBlock(body), lines == 1 ? "1 line" : $"{lines} lines");
    }

    static Attachment PathOnly(string name, string path, string note, string detail)
    {
        var body = $"<file path=\"{path}\">{note}</file>";
        return new(name, AttachmentKind.Path, TextTokens(body), Outbound.TextBlock(body), detail);
    }

    /// <summary>UTF-8 unless a BOM says otherwise.</summary>
    static string DecodeText(byte[] data)
    {
        using var reader = new StreamReader(new MemoryStream(data), Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
        return reader.ReadToEnd();
    }

    /// <summary>~3.5 characters a token for code and prose; an estimate, leaning high.</summary>
    public static int TextTokens(string text) => (int)Math.Ceiling(text.Length / 3.5);

    /// <summary>The message's content: files first (the API's advice for images and documents), then the typed text.</summary>
    public static JsonArray Blocks(string text, IEnumerable<Attachment> files)
    {
        var blocks = new JsonArray();
        foreach (var f in files) blocks.Add(f.Block.DeepClone());
        if (text.Length > 0) blocks.Add(Outbound.TextBlock(text));
        return blocks;
    }
}

/// <summary>A file that cannot go out: too big, too many pages, unreadable.</summary>
public sealed class AttachmentException(string message) : Exception(message);
