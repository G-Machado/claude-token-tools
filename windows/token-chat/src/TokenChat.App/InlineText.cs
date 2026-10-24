using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;

namespace TokenChat.App;

/// <summary>One line of markdown on a TextBlock, inline only: `code` in the mono face, **bold** bold. For a Done
/// item, where a whole MdXaml viewer per checkbox would bring its paragraph margins along.</summary>
public static class InlineText
{
    public static readonly DependencyProperty MarkdownProperty = DependencyProperty.RegisterAttached(
        "Markdown", typeof(string), typeof(InlineText), new PropertyMetadata(null, (d, e) => Fill((TextBlock)d, e.NewValue as string)));

    public static string? GetMarkdown(DependencyObject d) => (string?)d.GetValue(MarkdownProperty);
    public static void SetMarkdown(DependencyObject d, string? value) => d.SetValue(MarkdownProperty, value);

    static void Fill(TextBlock block, string? text)
    {
        block.Inlines.Clear();
        if (string.IsNullOrEmpty(text)) return;
        var code = false;
        foreach (var part in text.Split('`'))
        {
            if (code) block.Inlines.Add(new Run(part) { FontFamily = (System.Windows.Media.FontFamily)block.FindResource("Mono"), FontSize = 12 });
            else
            {
                var bold = false;
                foreach (var piece in part.Split("**"))
                {
                    if (piece.Length > 0) block.Inlines.Add(bold ? new Bold(new Run(piece)) : new Run(piece));
                    bold = !bold;
                }
            }
            code = !code;
        }
    }
}
