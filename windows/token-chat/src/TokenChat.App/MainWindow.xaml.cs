using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Input;
using TokenChat.Core;

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
        _sidebar = new Sidebar(_tabs);
        _sidebar.Refreshed += SyncSidebar;
        Side.List.ItemsSource = _sidebar.Items;
        // a row of this window shows its chat; a row elsewhere only opens to its controls
        Side.List.SelectionChanged += (_, _) =>
        {
            if (!_syncing && Side.List.SelectedItem is SidebarItem { Tab: { } tab }) Select(tab);
        };
        Side.NewSession += ShowStart;
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
        _syncTo = tab;
        SyncSidebar();
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
        if (r.Preview is { } fixtures)
            foreach (var fixture in fixtures)
                Show(new SessionTab(new LaunchOptions { WorkingDirectory = Path.GetDirectoryName(fixture)! },
                    replay: new ReplayTransport(File.ReadLines(fixture).Where(l => l.Length > 0).ToList(), holdOpen: true)));
        else if (r.Directory is { } directory) Open(directory, r.ResumeSessionId, r.Lite, r.Model, r.Effort, r.Prompt);
        return null;
    }

    public void Open(string directory) => Open(directory, null, false, null, null, null);

    void Open(string directory, string? resume, bool lite, string? model, string? effort, string? prompt) =>
        Show(new SessionTab(new LaunchOptions
        {
            WorkingDirectory = directory,
            Profile = lite || Side.LiteBox.IsChecked == true ? Profile.Lite : Profile.Full,
            Model = model ?? Model,
            Effort = effort,
            ResumeSessionId = resume,
        }, prompt));

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
