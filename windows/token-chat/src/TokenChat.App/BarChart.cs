using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace TokenChat.App;

public sealed record Segment(double Value, Brush Brush);

/// <param name="Label">the category axis label; blank to leave that slot unlabelled</param>
/// <param name="Tip">what hovering the bar says</param>
public sealed record Bar(string Label, IReadOnlyList<Segment> Segments, string Tip, string? Note = null)
{
    public double Total => Segments.Sum(s => s.Value);
}

/// <summary>Stacked bars, drawn rather than templated: a vertical chart (days, a histogram) puts the scale on the
/// left and every label that fits underneath; a horizontal one (projects) puts each label left of its bar and the
/// note after it. One marker line can stand on the category axis, between two slots.</summary>
public sealed class BarChart : FrameworkElement
{
    const double Axis = 40, Under = 16, Row = 20, LabelColumn = 130;

    IReadOnlyList<Bar> _bars = [];
    int _hover = -1;

    public BarChart()
    {
        ToolTipService.SetInitialShowDelay(this, 0);
        ToolTip = new ToolTip { Visibility = Visibility.Collapsed };
        MouseLeave += (_, _) => Hover(-1);
    }

    public IReadOnlyList<Bar> Bars
    {
        get => _bars;
        set
        {
            _bars = value;
            _hover = -1;
            if (Horizontal) Height = Math.Max(Row, value.Count * Row);
            InvalidateVisual();
        }
    }

    public bool Horizontal { get; set; }
    /// <summary>Segments side by side from the baseline instead of stacked: two series compared per slot.</summary>
    public bool Grouped { get; set; }
    /// <summary>The marker's place in slots from the left edge, e.g. 12.1 lands a tenth into the thirteenth bar.</summary>
    public double? Marker { get; set; }
    public string? MarkerLabel { get; set; }
    public Func<double, string> Format { get; set; } = v => v.ToString("0", CultureInfo.InvariantCulture);

    Brush Res(string key) => (Brush)FindResource(key);

    FormattedText Text(string s, Brush brush, double size = 9.5) =>
        new(s, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            new Typeface((FontFamily)FindResource("Mono"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal),
            size, brush, VisualTreeHelper.GetDpi(this).PixelsPerDip);

    protected override void OnRender(DrawingContext dc)
    {
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(RenderSize)); // hit-testable across the gaps
        if (_bars.Count == 0) return;
        if (Horizontal) RenderRows(dc);
        else RenderColumns(dc);
    }

    void RenderColumns(DrawingContext dc)
    {
        var plot = new Rect(Axis, 4, Math.Max(1, ActualWidth - Axis), Math.Max(1, ActualHeight - Under - 4));
        var max = Math.Max(_bars.Max(b => Grouped ? b.Segments.Select(s => s.Value).DefaultIfEmpty(0).Max() : b.Total), 1e-9);
        var line = new Pen(Res("Line"), 1);
        foreach (var f in new[] { 0, 0.5, 1 })
        {
            var y = Math.Round(plot.Bottom - f * plot.Height) + 0.5;
            dc.DrawLine(line, new Point(plot.Left, y), new Point(plot.Right, y));
            var t = Text(Format(max * f), Res("Faint"));
            dc.DrawText(t, new Point(Axis - 6 - t.Width, y - t.Height / 2));
        }

        var slot = plot.Width / _bars.Count;
        var width = Math.Max(1, slot * 0.72);
        var lastLabel = double.NegativeInfinity;
        for (var i = 0; i < _bars.Count; i++)
        {
            var x = plot.Left + i * slot + (slot - width) / 2;
            var y = plot.Bottom;
            var segments = _bars[i].Segments;
            for (var k = 0; k < segments.Count; k++)
            {
                var h = segments[k].Value / max * plot.Height;
                if (h <= 0) continue;
                if (Grouped)
                {
                    var each = width / segments.Count;
                    dc.DrawRectangle(segments[k].Brush, null, new Rect(x + k * each, plot.Bottom - h, Math.Max(1, each - 1), h));
                    continue;
                }
                dc.DrawRectangle(segments[k].Brush, null, new Rect(x, y - h, width, h));
                y -= h;
            }
            if (i == _hover) dc.DrawRectangle(Res("Ghost"), new Pen(Res("Text"), 1), new Rect(x - 1, plot.Top, width + 2, plot.Height));
            // labels that would collide are skipped, not squeezed
            if (_bars[i].Label is { Length: > 0 } label)
            {
                var t = Text(label, Res("Faint"));
                var lx = x + width / 2 - t.Width / 2;
                if (lx > lastLabel + 6)
                {
                    dc.DrawText(t, new Point(lx, plot.Bottom + 3));
                    lastLabel = lx + t.Width;
                }
            }
        }

        if (Marker is { } m)
        {
            var mx = Math.Round(plot.Left + m * slot) + 0.5;
            dc.DrawLine(new Pen(Res("Red"), 1) { DashStyle = DashStyles.Dash }, new Point(mx, plot.Top), new Point(mx, plot.Bottom));
            if (MarkerLabel is { } ml) dc.DrawText(Text(ml, Res("Red")), new Point(mx + 4, plot.Top));
        }
    }

    void RenderRows(DrawingContext dc)
    {
        var max = Math.Max(_bars.Max(b => b.Total), 1e-9);
        var area = Math.Max(1, ActualWidth - LabelColumn - 110);
        for (var i = 0; i < _bars.Count; i++)
        {
            var top = i * Row;
            if (i == _hover) dc.DrawRectangle(Res("Sel"), null, new Rect(0, top, ActualWidth, Row));
            var label = Text(_bars[i].Label, Res("Text"), 11);
            label.MaxTextWidth = LabelColumn - 10;
            label.MaxLineCount = 1;
            label.Trimming = TextTrimming.CharacterEllipsis;
            dc.DrawText(label, new Point(0, top + (Row - label.Height) / 2));
            var x = LabelColumn;
            foreach (var s in _bars[i].Segments)
            {
                var w = s.Value / max * area;
                if (w <= 0) continue;
                dc.DrawRectangle(s.Brush, null, new Rect(x, top + 4, w, Row - 8));
                x += w;
            }
            if (_bars[i].Note is { } note)
            {
                var t = Text(note, Res("Dim"));
                dc.DrawText(t, new Point(x + 6, top + (Row - t.Height) / 2));
            }
        }
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        var p = e.GetPosition(this);
        int at;
        if (Horizontal) at = (int)(p.Y / Row);
        else
        {
            var slot = Math.Max(1, ActualWidth - Axis) / Math.Max(1, _bars.Count);
            at = p.X < Axis ? -1 : (int)((p.X - Axis) / slot);
        }
        Hover(at >= 0 && at < _bars.Count ? at : -1);
    }

    void Hover(int at)
    {
        if (at == _hover) return;
        _hover = at;
        var tip = (ToolTip)ToolTip;
        tip.Content = at >= 0 ? _bars[at].Tip : null;
        tip.Visibility = at >= 0 ? Visibility.Visible : Visibility.Collapsed;
        tip.IsOpen = at >= 0;
        InvalidateVisual();
    }
}
