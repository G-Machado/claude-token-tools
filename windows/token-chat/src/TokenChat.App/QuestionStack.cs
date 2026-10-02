using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using TokenChat.Core.Transcript;

namespace TokenChat.App;

/// <summary>The question card's list. Stacked while the card fits the transcript's viewport; past that every
/// question shares one cell and the card's tabs show the current one (the others are Hidden, not Collapsed).
/// Every question is measured either way, and a tabbed card is as tall as its tallest question: switching tabs
/// doesn't move what is under it.</summary>
public sealed class QuestionStack : Panel
{
    /// <summary>The card's padding, tabs and buttons, counted against the viewport with the questions.</summary>
    const double Chrome = 110;
    /// <summary>More than a header pill's row, per question.</summary>
    const double Slack = 26;
    ScrollViewer? _viewport;
    bool _tabbed;

    public QuestionStack()
    {
        Loaded += (_, _) =>
        {
            for (DependencyObject? d = this; d is not null && _viewport is null; d = VisualTreeHelper.GetParent(d))
                _viewport = d as ScrollViewer;
            if (_viewport is not null) _viewport.SizeChanged += OnViewportSize;
            InvalidateMeasure();
        };
        Unloaded += (_, _) =>
        {
            if (_viewport is not null) _viewport.SizeChanged -= OnViewportSize;
            _viewport = null;
        };
    }

    void OnViewportSize(object sender, SizeChangedEventArgs e)
    {
        if (e.HeightChanged) InvalidateMeasure();
    }

    protected override Size MeasureOverride(Size available)
    {
        double sum = 0, tallest = 0, widest = 0;
        foreach (UIElement child in InternalChildren)
        {
            child.Measure(new Size(available.Width, double.PositiveInfinity));
            sum += child.DesiredSize.Height;
            tallest = Math.Max(tallest, child.DesiredSize.Height);
            widest = Math.Max(widest, child.DesiredSize.Width);
        }
        // tabbed drops each question's header pill, so the stacked sum shrinks a little once tabbed: going back
        // takes that much spare room, or a card on the edge would flip on every pass
        var need = sum + Chrome + (_tabbed ? Slack * InternalChildren.Count : 0);
        _tabbed = InternalChildren.Count > 1 && _viewport is { ViewportHeight: > 0 } v && need > v.ViewportHeight;
        if (DataContext is QuestionItem item) item.IsTabbed = _tabbed;
        return new Size(widest, _tabbed ? tallest : sum);
    }

    protected override Size ArrangeOverride(Size final)
    {
        double y = 0;
        foreach (UIElement child in InternalChildren)
        {
            var h = _tabbed ? final.Height : child.DesiredSize.Height;
            child.Arrange(new Rect(0, y, final.Width, h));
            if (!_tabbed) y += h;
        }
        return final;
    }
}
