using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Animation;

namespace TokenChat.App;

/// <summary>A folding question's options: full height while <see cref="IsOpen"/>, none while not, sliding between
/// the two. The child keeps its full layout and is clipped, so it slides rather than squashes; shut, it is Hidden, so
/// it keeps its width (the card doesn't narrow as questions fold) and tabbing skips its boxes. A change before it is
/// loaded snaps: a row appears in its state instead of playing its way there.</summary>
public sealed class Reveal : Decorator
{
    static readonly Duration Slide = TimeSpan.FromMilliseconds(200);

    public static readonly DependencyProperty IsOpenProperty = DependencyProperty.Register(
        nameof(IsOpen), typeof(bool), typeof(Reveal), new PropertyMetadata(false, (d, _) => ((Reveal)d).Move()));

    /// <summary>How much of the child shows, 0 to 1: what the slide animates.</summary>
    static readonly DependencyProperty AmountProperty = DependencyProperty.Register(
        "Amount", typeof(double), typeof(Reveal),
        new FrameworkPropertyMetadata(0.0, FrameworkPropertyMetadataOptions.AffectsMeasure, (d, _) => ((Reveal)d).Shown()));

    public Reveal() => ClipToBounds = true;

    public bool IsOpen { get => (bool)GetValue(IsOpenProperty); set => SetValue(IsOpenProperty, value); }
    double Amount => (double)GetValue(AmountProperty);

    void Move()
    {
        var to = IsOpen ? 1.0 : 0.0;
        if (!IsLoaded)
        {
            BeginAnimation(AmountProperty, null);
            SetValue(AmountProperty, to);
            return;
        }
        if (IsOpen && Child is not null) Child.Visibility = Visibility.Visible;
        BeginAnimation(AmountProperty, new DoubleAnimation(to, Slide) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseInOut } });
    }

    void Shown()
    {
        Opacity = Amount;
        if (Child is not null) Child.Visibility = Amount == 0 && !IsOpen ? Visibility.Hidden : Visibility.Visible;
    }

    protected override void OnVisualChildrenChanged(DependencyObject added, DependencyObject removed)
    {
        base.OnVisualChildrenChanged(added, removed);
        Shown();
    }

    protected override Size MeasureOverride(Size constraint)
    {
        if (Child is null) return default;
        Child.Measure(new Size(constraint.Width, double.PositiveInfinity));
        return new Size(Child.DesiredSize.Width, Child.DesiredSize.Height * Amount);
    }

    protected override Size ArrangeOverride(Size size)
    {
        Child?.Arrange(new Rect(0, 0, size.Width, Child.DesiredSize.Height));
        return size;
    }
}
