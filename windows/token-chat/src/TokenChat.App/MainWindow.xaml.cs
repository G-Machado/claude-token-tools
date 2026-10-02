using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using TokenChat.Core;

namespace TokenChat.App;

public partial class MainWindow : Window
{
    readonly ObservableCollection<SessionTab> _tabs = [];
    // Drag to reorder: past the system threshold the pressed tab follows the pointer along the strip and trades places
    // with a neighbour once the pointer crosses that neighbour's midpoint; the tabs it passes slide to their new places,
    // and on release it settles into its own. Esc puts it back.
    static readonly Duration Slide = TimeSpan.FromMilliseconds(150);
    SessionTab? _pressed;
    Point _pressedAt;
    int _pressedFrom;
    double _grab;
    bool _dragging;

    public MainWindow()
    {
        InitializeComponent();
        Tabs.ItemsSource = _tabs;
        Tabs.SelectionChanged += (_, e) =>
        {
            if (e.OriginalSource == Tabs && _tabs.Count > 0) Start.Visibility = Visibility.Collapsed;
        };
        Tabs.PreviewMouseLeftButtonDown += OnTabPress;
        Tabs.PreviewMouseMove += OnTabDrag;
        Tabs.PreviewMouseLeftButtonUp += OnTabRelease;
        Tabs.LostMouseCapture += (_, e) => { if (e.OriginalSource == Tabs) EndDrag(); };
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Escape || !_dragging || _pressed is not { } tab) return;
            MoveTab(_tabs.IndexOf(tab), _pressedFrom, held: null);
            EndDrag();
            e.Handled = true;
        };
        Start.Chosen += Open;
        Start.Cancelled += () => Start.Visibility = Visibility.Collapsed;
        StateChanged += (_, _) =>
        {
            var max = WindowState == WindowState.Maximized;
            MaxGlyph.Content = max ? "❐" : "□";
            MaxGlyph.ToolTip = max ? "restore" : "maximise";
        };
        ShowStart();
    }

    /// <summary>--model from the command line, for every tab this window opens.</summary>
    public string? Model { get; set; }

    public bool Lite { set => LiteBox.IsChecked = value; }

    void OnMinimise(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;

    void OnMaximise(object sender, RoutedEventArgs e) =>
        WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;

    void OnClose(object sender, RoutedEventArgs e) => Close();

    /// <summary>A launch, this process's or one forwarded by a later launch: come to the front, then focus the tab already
    /// holding the session, or open one.</summary>
    public void Handle(LaunchRequest r)
    {
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
        if (r.Error is { } error)
        {
            MessageBox.Show(this, error, "token-chat", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        if (r.ResumeSessionId is { } sid && _tabs.FirstOrDefault(t => t.SessionId == sid) is { } open)
        {
            Tabs.SelectedItem = open;
            Start.Visibility = Visibility.Collapsed;
            return;
        }
        if (r.Preview is { } fixtures)
            foreach (var fixture in fixtures)
                Show(new SessionTab(new LaunchOptions { WorkingDirectory = Path.GetDirectoryName(fixture)! },
                    replay: new ReplayTransport(File.ReadLines(fixture).Where(l => l.Length > 0).ToList(), holdOpen: true)));
        else if (r.Directory is { } directory) Open(directory, r.ResumeSessionId, r.Lite, r.Model, r.Effort, r.Prompt);
    }

    public void Open(string directory) => Open(directory, null, false, null, null, null);

    void Open(string directory, string? resume, bool lite, string? model, string? effort, string? prompt) =>
        Show(new SessionTab(new LaunchOptions
        {
            WorkingDirectory = directory,
            Profile = lite || LiteBox.IsChecked == true ? Profile.Lite : Profile.Full,
            Model = model ?? Model,
            Effort = effort,
            ResumeSessionId = resume,
        }, prompt));

    /// <summary>After the last tab of its project, else at the end.</summary>
    void Show(SessionTab tab)
    {
        var last = -1;
        for (var i = 0; i < _tabs.Count; i++) if (_tabs[i].ProjectKey == tab.ProjectKey) last = i;
        // An insert ahead of the selected tab before the strip has generated its tabs loses the selection to the first
        // (several --preview fixtures at startup); generate them first.
        Tabs.UpdateLayout();
        _tabs.Insert(last < 0 ? _tabs.Count : last + 1, tab);
        Tabs.SelectedItem = tab;
        Start.Visibility = Visibility.Collapsed;
        _ = tab.StartAsync();
    }

    void OnNewTab(object sender, RoutedEventArgs e) => ShowStart();

    void ShowStart() => Start.Show(RecentProjects.Load(RecentProjects.DefaultRoot), canCancel: _tabs.Count > 0);

    void OnTabPress(object sender, MouseButtonEventArgs e)
    {
        if (TabAt(e.OriginalSource as DependencyObject) is not { DataContext: SessionTab tab }) return;
        _pressed = tab;
        _pressedAt = e.GetPosition(Tabs);
        _pressedFrom = _tabs.IndexOf(tab);
    }

    /// <summary>The tab a press landed in, unless it landed on a button there (the close glyph). Text hits can be a Run,
    /// which has no visual parent.</summary>
    static TabItem? TabAt(DependencyObject? o)
    {
        for (; o is not null; o = o is Visual ? VisualTreeHelper.GetParent(o) : LogicalTreeHelper.GetParent(o))
        {
            if (o is ButtonBase) return null;
            if (o is TabItem t) return t;
        }
        return null;
    }

    void OnTabDrag(object sender, MouseEventArgs e)
    {
        if (_pressed is not { } tab) return;
        if (e.LeftButton != MouseButtonState.Pressed)
        {
            EndDrag();
            return;
        }
        if (Container(tab) is not { } dragged || VisualTreeHelper.GetParent(dragged) is not Panel strip) return;
        var at = e.GetPosition(strip);
        if (!_dragging)
        {
            var moved = e.GetPosition(Tabs) - _pressedAt;
            if (Math.Abs(moved.X) < SystemParameters.MinimumHorizontalDragDistance
                && Math.Abs(moved.Y) < SystemParameters.MinimumVerticalDragDistance) return;
            if (!(_dragging = Tabs.CaptureMouse())) return;
            _grab = Tabs.TranslatePoint(_pressedAt, strip).X - Slot(dragged).Left;
            Panel.SetZIndex(dragged, 1);
        }
        // The tab laid out under the pointer's x, in the row nearest its y: off the strip still drags, a wrapped strip
        // picks a row. Layout slots, not drawn positions, so tabs mid-slide do not shift the target.
        var from = _tabs.IndexOf(tab);
        var (over, overBox, gap) = (-1, Rect.Empty, double.MaxValue);
        for (var i = 0; i < _tabs.Count; i++)
        {
            if (Container(_tabs[i]) is not { IsVisible: true } item) continue;
            var box = Slot(item);
            var dy = Math.Abs(at.Y - (box.Top + box.Height / 2));
            if (at.X >= box.Left && at.X < box.Right && dy < gap) (over, overBox, gap) = (i, box, dy);
        }
        var mid = overBox.Left + overBox.Width / 2;
        if (over >= 0 && over != from && (over > from ? at.X > mid : at.X < mid)) MoveTab(from, over, held: tab);
        Follow(tab, at.X);
    }

    /// <summary>The dragged tab drawn under the pointer, held between the strip's first and last tab.</summary>
    void Follow(SessionTab tab, double x)
    {
        if (Container(tab) is not { } item || Container(_tabs[0]) is not { } first || Container(_tabs[^1]) is not { } last) return;
        var slot = Slot(item);
        var left = Math.Clamp(x - _grab, Slot(first).Left, Math.Max(Slot(first).Left, Slot(last).Right - slot.Width));
        var shift = Shift(item);
        shift.BeginAnimation(TranslateTransform.XProperty, null);
        shift.X = left - slot.Left;
    }

    /// <summary>Moves a tab; every tab whose place changed, but the one held under the pointer, slides there from where it
    /// was drawn.</summary>
    void MoveTab(int from, int to, SessionTab? held)
    {
        var drawn = _tabs.Select(Container).OfType<TabItem>().ToDictionary(t => t, t => Slot(t).Left + Shift(t).X);
        _tabs.Move(from, to);
        Tabs.UpdateLayout(); // the next move measures against the new order
        foreach (var (item, was) in drawn)
            if (item.DataContext != held && Math.Abs(was - Slot(item).Left) > 0.5) SlideHome(item, was - Slot(item).Left);
    }

    static void SlideHome(UIElement item, double from)
    {
        var shift = Shift(item);
        shift.X = 0;
        shift.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(from, 0, Slide)
        {
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
            FillBehavior = FillBehavior.Stop,
        });
    }

    static TranslateTransform Shift(UIElement e) =>
        e.RenderTransform as TranslateTransform ?? (TranslateTransform)(e.RenderTransform = new TranslateTransform());

    /// <summary>Where layout put the tab in the strip, whatever it is drawn shifted by.</summary>
    static Rect Slot(TabItem t) => new((Point)VisualTreeHelper.GetOffset(t), t.RenderSize);

    TabItem? Container(SessionTab t) => Tabs.ItemContainerGenerator.ContainerFromItem(t) as TabItem;

    void OnTabRelease(object sender, MouseButtonEventArgs e)
    {
        if (_dragging) e.Handled = true;
        EndDrag();
    }

    void EndDrag()
    {
        var tab = _pressed;
        _pressed = null;
        if (!_dragging) return;
        _dragging = false;
        Tabs.ReleaseMouseCapture();
        if (tab is null || Container(tab) is not { } item) return;
        item.ClearValue(Panel.ZIndexProperty);
        SlideHome(item, Shift(item).X);
    }

    async void OnCloseTab(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not SessionTab tab) return;
        _tabs.Remove(tab);
        if (_tabs.Count == 0) ShowStart();
        tab.StopRendering();
        await tab.DisposeAsync();
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        foreach (var tab in _tabs) tab.StopRendering();
        // Off the UI thread, so nothing in the session's shutdown waits on the dispatcher this call blocks.
        var all = _tabs.ToList();
        Task.Run(() => Task.WhenAll(all.Select(t => t.DisposeAsync().AsTask()))).Wait(TimeSpan.FromSeconds(5));
        base.OnClosing(e);
    }
}
