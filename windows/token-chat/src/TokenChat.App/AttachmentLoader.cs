using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using TokenChat.Core;

namespace TokenChat.App;

/// <summary>Files and clipboard images into <see cref="Attachment"/>s. Images are decoded here (WPF), scaled to
/// <see cref="Attachments.ImageMaxEdge"/> and re-encoded only when they are too big as they are.</summary>
static class AttachmentLoader
{
    static int _pasted;

    public static Attachment FromFile(string path)
    {
        var ext = Path.GetExtension(path);
        byte[] data;
        try { data = File.ReadAllBytes(path); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { throw new AttachmentException($"{Path.GetFileName(path)}: {e.Message}"); }
        if (Attachments.ImageTypes.Contains(ext)) return Image(Path.GetFileName(path), data, Attachments.MediaType(ext));
        if (ext.Equals(".pdf", StringComparison.OrdinalIgnoreCase)) return Attachments.Pdf(Path.GetFileName(path), data);
        return Attachments.File(path, data);
    }

    /// <summary>The clipboard's image: its PNG stream when the source put one there (keeps the pixels exact),
    /// else the bitmap WPF reads, flattened to opaque since screenshot DIBs often carry a zero alpha.</summary>
    public static Attachment? FromClipboard()
    {
        var name = $"pasted image {++_pasted}.png";
        if (Clipboard.GetData("PNG") is MemoryStream png) return Image(name, png.ToArray(), "image/png");
        if (Clipboard.GetImage() is not { } bitmap) return null;
        return Encode(name, new FormatConvertedBitmap(bitmap, PixelFormats.Bgr24, null, 0), "image/png");
    }

    static Attachment Image(string name, byte[] data, string mediaType)
    {
        BitmapFrame frame;
        try { frame = BitmapDecoder.Create(new MemoryStream(data), BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad).Frames[0]; }
        catch (Exception e) when (e is NotSupportedException or FileFormatException or ArgumentException or IOException)
        {
            throw new AttachmentException($"{name}: not an image Windows can read ({e.Message})");
        }
        var (w, h) = (frame.PixelWidth, frame.PixelHeight);
        if (Attachments.FitWithin(w, h) == (w, h) && data.Length <= Attachments.ImageMaxBytes)
            return Attachments.Image(name, mediaType, data, w, h);
        return Encode(name, frame, mediaType);
    }

    /// <summary>Scales to fit, then PNG for screenshots and drawings; JPEG for photos, or when the PNG is over the limit.</summary>
    static Attachment Encode(string name, BitmapSource source, string mediaType)
    {
        var (w, h) = Attachments.FitWithin(source.PixelWidth, source.PixelHeight);
        BitmapSource scaled = (w, h) == (source.PixelWidth, source.PixelHeight) ? source
            : new TransformedBitmap(source, new ScaleTransform((double)w / source.PixelWidth, (double)h / source.PixelHeight));
        if (mediaType != "image/jpeg")
        {
            var png = Save(new PngBitmapEncoder(), scaled);
            if (png.Length <= Attachments.ImageMaxBytes) return Attachments.Image(name, "image/png", png, w, h);
        }
        // JPEG has no alpha: flatten onto white rather than black
        var opaque = new FormatConvertedBitmap(scaled, PixelFormats.Bgr24, null, 0);
        return Attachments.Image(name, "image/jpeg", Save(new JpegBitmapEncoder { QualityLevel = 88 }, Flatten(scaled) ?? opaque), w, h);
    }

    static BitmapSource? Flatten(BitmapSource source)
    {
        if (!source.Format.Equals(PixelFormats.Bgra32) && !source.Format.Equals(PixelFormats.Pbgra32)) return null;
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            var rect = new Rect(0, 0, source.PixelWidth, source.PixelHeight);
            dc.DrawRectangle(Brushes.White, null, rect);
            dc.DrawImage(source, rect);
        }
        var target = new RenderTargetBitmap(source.PixelWidth, source.PixelHeight, 96, 96, PixelFormats.Pbgra32);
        target.Render(visual);
        return new FormatConvertedBitmap(target, PixelFormats.Bgr24, null, 0);
    }

    static byte[] Save(BitmapEncoder encoder, BitmapSource source)
    {
        encoder.Frames.Add(BitmapFrame.Create(source));
        using var ms = new MemoryStream();
        encoder.Save(ms);
        return ms.ToArray();
    }
}
