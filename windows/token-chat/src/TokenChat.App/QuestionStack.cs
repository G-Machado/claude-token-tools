using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using TokenChat.Core.Transcript;

namespace TokenChat.App;

/// <summary>A question list, the card's questions or a reply's ▶ asks: one rule for both. Stacked while it fits the
/// transcript's viewport; past that every question shares one cell and the tabs above show the current one (the
/// others are Hidden, not Collapsed). Every question is measured either way, and a tabbed list is as tall as its
/// tallest question: switching tabs doesn't move what is under it.</summary>
public sealed class QuestionStack : Panel
{
    /// <summary>The padding, tabs and buttons round the list, counted against the viewport with the questions.</summary>
    const double Chrome = 110;
    /// <summary>More than a header pill's row, per question; 0 where tabbing drops nothing (the ▶ bar).</summary>
    public double Slack { get; set; } = 26;
    ScrollViewer? _viewport;
    bool _tabbed;

    public QuestionStack()
    {
        Loaded += (_, _) =>
        {
            for (DependencyObject? d = this; d is not null && _viewport is null; d = VisualTreeHelper.GetParent(d))
                _viewport = d as ScrollViewer;
            if (_viewport is not null) _viewport.ScrollChanged += OnViewportScroll;
            InvalidateMeasure();
        };
        Unloaded += (_, _) =>
        {
            if (_viewport is not null) _viewport.ScrollChanged -= OnViewportScroll;
            _viewport = null;
        };
    }

    // ScrollChanged, not SizeChanged: on a resize SizeChanged comes first, and a measure then still read the old
    // ViewportHeight. Text boxes and markdown bubble their own ScrollChanged through here: only the viewport's counts.
    void OnViewportScroll(object sender, ScrollChangedEventArgs e)
    {
        if (e.OriginalSource == _viewport && e.ViewportHeightChange != 0) InvalidateMeasure();
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
        // a tabbed card drops each question's header pill, so the stacked sum shrinks a little once tabbed: going back
        // takes that much spare room, or a card on the edge would flip on every pass
        var need = sum + Chrome + (_tabbed ? Slack * InternalChildren.Count : 0);
        _tabbed = InternalChildren.Count > 1 && _viewport is { ViewportHeight: > 0 } v && need > v.ViewportHeight;
        if (DataContext is ITabbedQuestions list) list.IsTabbed = _tabbed;
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
