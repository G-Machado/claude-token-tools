using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace TokenChat.App;

/// <summary>Weekday rows by hour columns, each cell's strength its share of the busiest cell. The square root keeps a
/// light hour visible next to a heavy one: linear, most of the week reads as empty.</summary>
public sealed class HeatMap : FrameworkElement
{
    const double Left = 34, Under = 16, Gap = 2;
    static readonly string[] Days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

    double[] _values = new double[7 * 24];
    int _hover = -1;

    public HeatMap()
    {
        ToolTipService.SetInitialShowDelay(this, 0);
        ToolTip = new ToolTip { Visibility = Visibility.Collapsed };
        MouseLeave += (_, _) => Hover(-1);
    }

    /// <summary>[weekday * 24 + hour], Monday 0.</summary>
    public double[] Values
    {
        get => _values;
        set { _values = value; _hover = -1; InvalidateVisual(); }
    }

    public Func<double, string> Format { get; set; } = v => v.ToString("0", CultureInfo.InvariantCulture);

    Brush Res(string key) => (Brush)FindResource(key);

    FormattedText Text(string s) =>
        new(s, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            new Typeface((FontFamily)FindResource("Mono"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal),
            9.5, Res("Faint"), VisualTreeHelper.GetDpi(this).PixelsPerDip);

    (double W, double H) Cell => ((ActualWidth - Left) / 24, (ActualHeight - Under) / 7);

    protected override void OnRender(DrawingContext dc)
    {
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(RenderSize));
        var (cw, ch) = Cell;
        if (cw <= Gap || ch <= Gap) return;
        var max = Math.Max(_values.Max(), 1e-9);
        var hot = ((SolidColorBrush)Res("Blue")).Color;
        for (var d = 0; d < 7; d++)
        {
            var label = Text(Days[d]);
            dc.DrawText(label, new Point(0, d * ch + (ch - label.Height) / 2));
            for (var h = 0; h < 24; h++)
            {
                var v = _values[d * 24 + h];
                var rect = new Rect(Left + h * cw, d * ch, cw - Gap, ch - Gap);
                Brush fill = v <= 0 ? Res("Inset") : new SolidColorBrush(Color.FromArgb((byte)(40 + 215 * Math.Sqrt(v / max)), hot.R, hot.G, hot.B));
                dc.DrawRoundedRectangle(fill, d * 24 + h == _hover ? new Pen(Res("Text"), 1) : null, rect, 2, 2);
            }
        }
        for (var h = 0; h < 24; h += 3)
            dc.DrawText(Text(h.ToString("00", CultureInfo.InvariantCulture)), new Point(Left + h * cw, 7 * ch + 2));
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        var p = e.GetPosition(this);
        var (cw, ch) = Cell;
        var h = (int)((p.X - Left) / cw);
        var d = (int)(p.Y / ch);
        Hover(p.X >= Left && h is >= 0 and < 24 && d is >= 0 and < 7 ? d * 24 + h : -1);
    }

    void Hover(int at)
    {
        if (at == _hover) return;
        _hover = at;
        var tip = (ToolTip)ToolTip;
        tip.Content = at >= 0 ? $"{Days[at / 24]} {at % 24:00}:00–{at % 24 + 1:00}:00 · {Format(_values[at])} weighted" : null;
        tip.Visibility = at >= 0 ? Visibility.Visible : Visibility.Collapsed;
        tip.IsOpen = at >= 0;
        InvalidateVisual();
    }
}
