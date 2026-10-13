using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using TokenChat.Core.Analytics;

namespace TokenChat.App;

/// <summary>The four grades on one shared A to E scale: a column per letter, tinted that letter's colour, and a row
/// per axis. This week is a dot in its letter's colour, the week before a ring, joined by the way it moved.</summary>
public sealed class GradeBands : FrameworkElement
{
    const double Left = 150, Head = 22, Row = 34;
    public static readonly string[] Letters = ["A", "B", "C", "D", "E"];
    public static readonly string[] Colours = ["Green", "Blue", "Yellow", "Orange", "Red"];

    IReadOnlyList<Grade> _grades = [];
    int _hover = -1;

    public GradeBands()
    {
        ToolTipService.SetInitialShowDelay(this, 0);
        ToolTip = new ToolTip { Visibility = Visibility.Collapsed };
        MouseLeave += (_, _) => Hover(-1);
    }

    public IReadOnlyList<Grade> Grades
    {
        get => _grades;
        set { _grades = value; _hover = -1; Height = Head + Math.Max(1, value.Count) * Row + 4; InvalidateVisual(); }
    }

    public static Brush BrushOf(FrameworkElement owner, string letter) =>
        (Brush)owner.FindResource(Array.IndexOf(Letters, letter) is >= 0 and var i ? Colours[i] : "Faint");

    Brush Res(string key) => (Brush)FindResource(key);

    FormattedText Text(string s, Brush brush, double size, FontWeight? weight = null, string font = "Ui") =>
        new(s, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            new Typeface((FontFamily)FindResource(font), FontStyles.Normal, weight ?? FontWeights.Normal, FontStretches.Normal),
            size, brush, VisualTreeHelper.GetDpi(this).PixelsPerDip);

    protected override void OnRender(DrawingContext dc)
    {
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(RenderSize));
        var band = Math.Max(1, (ActualWidth - Left) / 5);
        var bottom = Head + _grades.Count * Row;
        for (var i = 0; i < 5; i++)
        {
            var colour = ((SolidColorBrush)Res(Colours[i])).Color;
            var x = Left + i * band;
            dc.DrawRoundedRectangle(new SolidColorBrush(Color.FromArgb(34, colour.R, colour.G, colour.B)), null,
                new Rect(x + 1, Head - 2, band - 2, bottom - Head + 4), 4, 4);
            var t = Text(Letters[i], new SolidColorBrush(colour), 12, FontWeights.SemiBold, "Mono");
            dc.DrawText(t, new Point(x + band / 2 - t.Width / 2, 2));
        }

        for (var r = 0; r < _grades.Count; r++)
        {
            var g = _grades[r];
            var mid = Head + r * Row + Row / 2;
            if (r == _hover) dc.DrawRectangle(Res("Ghost"), new Pen(Res("Line"), 1), new Rect(0, mid - Row / 2 + 1, ActualWidth, Row - 2));
            var name = Text(g.Axis, Res("Text"), 12, FontWeights.SemiBold);
            dc.DrawText(name, new Point(0, mid - name.Height / 2 - 6));
            var value = Text(g.Value, Res("Dim"), 10.5, font: "Mono");
            dc.DrawText(value, new Point(0, mid + 1));
            var letterMark = Text(g.Letter, BrushOf(this, g.Letter), 15, FontWeights.SemiBold, "Mono");
            dc.DrawText(letterMark, new Point(Left - 22 - letterMark.Width / 2, mid - letterMark.Height / 2));

            var now = new Point(Left + Grade.Position(g.Axis, g.Raw) * band, mid);
            if (g.PreviousRaw is { } was)
            {
                var then = new Point(Left + Grade.Position(g.Axis, was) * band, mid);
                dc.DrawLine(new Pen(Res("Dim"), 1.5), then, now);
                dc.DrawEllipse(Res("Card"), new Pen(BrushOf(this, g.Previous ?? ""), 1.5), then, 5, 5);
            }
            dc.DrawEllipse(BrushOf(this, g.Letter), new Pen(Res("Text"), 1.5), now, 7, 7);
        }
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        var y = e.GetPosition(this).Y - Head;
        var at = y < 0 ? -1 : (int)(y / Row);
        Hover(at < _grades.Count ? at : -1);
    }

    void Hover(int at)
    {
        if (at == _hover) return;
        _hover = at;
        var tip = (ToolTip)ToolTip;
        if (at >= 0)
        {
            var g = _grades[at];
            tip.Content = $"{g.Axis} {g.Letter}: {g.Value} {g.Meaning}" + (g.Previous is { } p ? $"\nthe period before: {p}" : "");
        }
        tip.Visibility = at >= 0 ? Visibility.Visible : Visibility.Collapsed;
        tip.IsOpen = at >= 0;
        InvalidateVisual();
    }
}
