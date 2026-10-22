using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Input;
using TokenChat.Core;
using TokenChat.Core.Transcript;

namespace TokenChat.App;

public partial class MainWindow : Window
{
    /// <summary>This window's sessions, in the sidebar's order: each after the last of its project.</summary>
    readonly ObservableCollection<SessionTab> _tabs = [];
    readonly Sidebar _sidebar;
    // the session whose row the sidebar should select once its rebuild has the row (a new one is shown before that)
    SessionTab? _syncTo;
    bool _syncing;

    public MainWindow()
    {
        InitializeComponent();
        var tray = new Tray(this);
        Closed += (_, _) => tray.Dispose();
        _sidebar = new Sidebar(_tabs);
        _sidebar.Refreshed += SyncSidebar;
        Side.List.ItemsSource = _sidebar.Items;
        Side.Usage.DataContext = _sidebar.Usage;
        Side.ParkedPane.DataContext = _sidebar;
        Side.OpenedParked += () => _ = _sidebar.RefreshParkedAsync();
        Side.Unpark += Unpark;
        // a row of this window shows its chat; a row elsewhere only opens to its controls
        Side.List.SelectionChanged += (_, _) =>
        {
            if (!_syncing && Side.List.SelectedItem is SidebarItem { Tab: { } tab }) Select(tab);
        };
        Side.NewSession += ShowStart;
        Side.ShowAnalytics += ShowAnalytics;
        Side.CloseSession += CloseSession;
        PreviewKeyDown += (_, e) =>
        {
            // ctrl+tab as the tab strip had it: the next session of this window, with shift the one before
            if (e.Key != Key.Tab || (Keyboard.Modifiers & ModifierKeys.Control) == 0 || _tabs.Count < 2 || Current is not { } now) return;
            var step = (Keyboard.Modifiers & ModifierKeys.Shift) != 0 ? -1 : 1;
            Select(_tabs[(_tabs.IndexOf(now) + step + _tabs.Count) % _tabs.Count]);
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

    SessionTab? Current => Chat.Content as SessionTab;

    /// <summary>Shows a session's chat and selects its row.</summary>
    void Select(SessionTab tab)
    {
        Chat.Content = tab;
        Start.Visibility = Visibility.Collapsed;
        Analytics.Visibility = Visibility.Collapsed;
        Chat.Visibility = Visibility.Visible;
        Side.AnalyticsRow.IsChecked = false;
        _syncTo = tab;
        SyncSidebar();
    }

    /// <summary>The analytics row: no session row stays selected, so clicking the one that was showing goes back to it.</summary>
    void ShowAnalytics()
    {
        Side.AnalyticsRow.IsChecked = true;
        Analytics.Visibility = Visibility.Visible;
        Chat.Visibility = Visibility.Collapsed; // the view has no ground of its own: the chat would show through
        Start.Visibility = Visibility.Collapsed;
        _syncTo = null;
        _syncing = true;
        Side.List.SelectedItem = null;
        _syncing = false;
    }

    void SyncSidebar()
    {
        if (_syncTo is not { } tab || _sidebar?.Items.FirstOrDefault(i => i.Tab == tab) is not { } item) return;
        _syncTo = null;
        _syncing = true;
        Side.List.SelectedItem = item;
        _syncing = false;
    }

    /// <summary>--model from the command line, for every session this window opens.</summary>
    public string? Model { get; set; }

    public bool Lite { set => Side.LiteBox.IsChecked = value; }

    void OnMinimise(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;

    void OnMaximise(object sender, RoutedEventArgs e) =>
        WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;

    void OnClose(object sender, RoutedEventArgs e) => Close();

    /// <summary>A launch, this process's or one forwarded by a later launch: come to the front, then show the session
    /// already open here, or open one. A poke goes to its session without raising the window, and its answer is returned
    /// for the pipe; null for everything else.</summary>
    public string? Handle(LaunchRequest r)
    {
        if (r.Poke is { } poke)
            return _tabs.FirstOrDefault(t => t.SessionId == poke.SessionId) is { } tab ? tab.Poke(poke.Text) : "no-tab";
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
        if (r.Error is { } error)
        {
            MessageBox.Show(this, error, "token-chat", MessageBoxButton.OK, MessageBoxImage.Warning);
            return null;
        }
        if (r.ResumeSessionId is { } sid && _tabs.FirstOrDefault(t => t.SessionId == sid) is { } open)
        {
            Select(open);
            return null;
        }
        if (r.Replace is { } old && r.Directory is { } dir
            && _tabs.FirstOrDefault(t => string.Equals(t.SessionId, old, StringComparison.OrdinalIgnoreCase)) is { } prev)
        {
            HandOver(prev, Create(dir, null, false, r.Model, r.Effort, r.Prompt));
            return null;
        }
        if (r.Preview is { } fixtures)
            foreach (var fixture in fixtures)
                Show(new SessionTab(new LaunchOptions { WorkingDirectory = Path.GetDirectoryName(fixture)! },
                    replay: new ReplayTransport(File.ReadLines(fixture).Where(l => l.Length > 0).ToList(), holdOpen: true)));
        else if (r.Directory is { } directory) Open(directory, r.ResumeSessionId, r.Lite, r.Model, r.Effort, r.Prompt);
        return null;
    }

    public void Open(string directory) => Open(directory, null, false, null, null, null);

    /// <summary>The widget's Parked enter, in this window: a new tab in the checkpoint's folder, on the model and effort
    /// it was parked on, whose first message is the /unpark. A window still holding the strand is brought forward
    /// instead: unparking beside it would make two windows on one strand.</summary>
    async void Unpark(Checkpoint c)
    {
        var here = c.Sid.Length > 0
            ? _tabs.FirstOrDefault(t => string.Equals(t.SessionId, c.Sid, StringComparison.OrdinalIgnoreCase)) : null;
        if (here is not null) { Select(here); Side.Say($"{c.Topic} is still open here"); return; }
        if (c.Alive && SessionTab.Feed.Value.Session(c.Sid) is { } s)
        {
            Side.Say($"{c.Topic} is still open elsewhere - bringing it forward");
            Side.Say(await SessionControl.OpenAsync(c.Sid, c.Cwd, (int)SidebarItem.Num(s, "pid")));
            return;
        }
        if (!Directory.Exists(c.Cwd)) { Side.Say($"{c.Topic}: the folder is gone"); return; }
        Open(c.Cwd, null, false, c.Model.Length > 0 ? c.Model : null, c.Effort.Length > 0 ? c.Effort : null, c.UnparkPrompt);
        Side.Say(c.BehindMin > 0 ? $"unparking {c.Topic} - its window worked {c.BehindMin}m past the checkpoint"
            : $"unparking {c.Topic}");
    }

    void Open(string directory, string? resume, bool lite, string? model, string? effort, string? prompt) =>
        Show(Create(directory, resume, lite, model, effort, prompt));

    SessionTab Create(string directory, string? resume, bool lite, string? model, string? effort, string? prompt)
    {
        var tab = new SessionTab(new LaunchOptions
        {
            WorkingDirectory = directory,
            Profile = lite || Side.LiteBox.IsChecked == true ? Profile.Lite : Profile.Full,
            Model = model ?? Model,
            Effort = effort,
            ResumeSessionId = resume,
        }, prompt);
        // a resumed session that took others over by /handoff gets their folds back, empty like its own history
        if (resume is not null)
        {
            var olds = HandoffChain.Olds(HandoffChain.DefaultPath, resume);
            for (var i = 0; i < olds.Count; i++)
                tab.Items.Insert(i, new SegmentItem(olds[i],
                    [new NoteItem(NoteKind.Info, "Resumed after a restart", "its turns are in the session but not shown here")]) { State = "ended" });
        }
        return tab;
    }

    /// <summary>A /handoff's new session takes the old one's tab: the old transcript folds above it, earlier hand-offs
    /// stay folds of their own. The old session finishes its /handoff turn out of sight (its --block and reply), then
    /// goes; one that has not ended its turn in 2 minutes is closed anyway.</summary>
    void HandOver(SessionTab prev, SessionTab tab)
    {
        while (prev.Items.Count > 0 && prev.Items[0] is SegmentItem earlier)
        {
            prev.Items.RemoveAt(0);
            tab.Items.Add(earlier);
        }
        var segment = new SegmentItem(prev.SessionId ?? "unknown", prev.Items);
        tab.Items.Add(segment);
        prev.HandedOff = true;
        _tabs[_tabs.IndexOf(prev)] = tab;
        Select(tab);
        _ = tab.StartAsync();
        Retire(prev, segment);
        // recorded once the new session has an id, which init brings before its first turn ends
        var olds = tab.Items.OfType<SegmentItem>().Select(s => s.SessionId).Where(s => s != "unknown").ToList();
        void Record()
        {
            tab.TurnEnded -= Record;
            if (tab.SessionId is { } sid) HandoffChain.Record(HandoffChain.DefaultPath, sid, olds);
        }
        tab.TurnEnded += Record;
    }

    async void Retire(SessionTab prev, SegmentItem segment)
    {
        var ended = new TaskCompletionSource();
        prev.TurnEnded += () => ended.TrySetResult();
        var done = prev.State != "working"
            || await Task.WhenAny(ended.Task, Task.Delay(TimeSpan.FromMinutes(2))) == ended.Task;
        prev.StopRendering();
        await prev.DisposeAsync();
        segment.State = done ? "ended" : "cut short after 2 min";
    }

    /// <summary>After the last session of its project, else at the end.</summary>
    void Show(SessionTab tab)
    {
        var last = -1;
        for (var i = 0; i < _tabs.Count; i++) if (_tabs[i].ProjectKey == tab.ProjectKey) last = i;
        _tabs.Insert(last < 0 ? _tabs.Count : last + 1, tab);
        Select(tab);
        _ = tab.StartAsync();
    }

    void ShowStart() => Start.Show(RecentProjects.Load(RecentProjects.DefaultRoot), canCancel: _tabs.Count > 0);

    /// <summary>The row's close: the session's process goes; the chat moves to the session that took its place.</summary>
    async void CloseSession(SessionTab tab)
    {
        var at = _tabs.IndexOf(tab);
        if (at < 0) return;
        _tabs.Remove(tab);
        if (Current == tab)
        {
            if (_tabs.Count > 0) Select(_tabs[Math.Min(at, _tabs.Count - 1)]);
            else
            {
                Chat.Content = null;
                ShowStart();
            }
        }
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
