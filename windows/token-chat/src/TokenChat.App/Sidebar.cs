using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;
using System.Text.Json.Nodes;
using System.Windows.Media;
using System.Windows.Threading;
using TokenChat.Core;

namespace TokenChat.App;

/// <summary>One sidebar row: a session in this window (its tab) or one the widget's collect lists elsewhere, a terminal
/// or another front end. Updated in place, so the selection and the scroll survive every collect.</summary>
public sealed class SidebarItem(object key) : INotifyPropertyChanged
{
    /// <summary>The tab for a session in this window, else the session id.</summary>
    public object Key { get; } = key;
    public SessionTab? Tab => Key as SessionTab;
    public bool Here => Tab is not null;
    public string Name { get; private set; } = "";
    public string Project { get; private set; } = "";
    public Brush? ProjectBrush { get; private set; }
    /// <summary>The tab's State (starting, idle, working, exited); a session elsewhere is idle or working.</summary>
    public string State { get; private set; } = "";
    /// <summary>The widget's figures for the session, null until a collect has it.</summary>
    public FooterRow? Row { get; private set; }
    /// <summary>Heads the sessions elsewhere, so the template draws the label between the two groups.</summary>
    public bool FirstElsewhere { get; private set; }

    public event PropertyChangedEventHandler? PropertyChanged;

    internal void Set(string name, string project, Brush? brush, string state, FooterRow? row, bool firstElsewhere)
    {
        (Name, Project, ProjectBrush, State, Row, FirstElsewhere) = (name, project, brush, state, row, firstElsewhere);
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null)); // every binding re-reads
    }
}

/// <summary>The sidebar's rows: this window's tabs in their order, then every other live session in the widget's last
/// collect, in the collector's order. Rebuilt on a collect, a tab change and a clock tick, since the cache clock of a
/// session elsewhere runs down between collects (a tab's own Row already does).</summary>
public sealed class Sidebar
{
    readonly ObservableCollection<SessionTab> _tabs;
    readonly Dispatcher _ui = Dispatcher.CurrentDispatcher;
    bool _queued;

    public ObservableCollection<SidebarItem> Items { get; } = [];
    /// <summary>After every rebuild, on the UI thread.</summary>
    public event Action? Refreshed;

    public Sidebar(ObservableCollection<SessionTab> tabs)
    {
        _tabs = tabs;
        tabs.CollectionChanged += OnTabs;
        foreach (var t in tabs) t.PropertyChanged += OnTab;
        SessionTab.Feed.Value.Changed += Schedule;
        // a running timer is held by its dispatcher
        _ = new DispatcherTimer(TimeSpan.FromSeconds(15), DispatcherPriority.Background, (_, _) => Schedule(), _ui);
        Refresh();
    }

    void OnTabs(object? sender, NotifyCollectionChangedEventArgs e)
    {
        foreach (var t in e.OldItems?.OfType<SessionTab>() ?? []) t.PropertyChanged -= OnTab;
        foreach (var t in e.NewItems?.OfType<SessionTab>() ?? []) t.PropertyChanged += OnTab;
        Schedule();
    }

    void OnTab(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(SessionTab.Row) or nameof(SessionTab.State)) Schedule();
    }

    /// <summary>Every tab sets its Row on its own clock and the feed lands on a pool thread: one rebuild per burst.</summary>
    void Schedule()
    {
        if (_queued) return;
        _queued = true;
        _ui.BeginInvoke(DispatcherPriority.Background, () => { _queued = false; Refresh(); });
    }

    void Refresh()
    {
        var feed = SessionTab.Feed.Value.Snapshot;
        var want = new List<(object Key, string Name, string Project, Brush? Brush, string State, FooterRow? Row)>();
        var here = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var t in _tabs)
        {
            JsonObject? s = null;
            if (t.SessionId is { } sid && here.Add(sid)) feed?.Sessions.TryGetValue(sid, out s);
            // the topic names the session; the tab's title (its folder) is then the project
            var nick = Str(s, "nick");
            want.Add((t, nick.Length > 0 ? nick : t.Title, nick.Length > 0 ? t.Title : "", t.ProjectBrush, t.State, t.Row));
        }
        if (feed is not null)
        {
            var now = DateTimeOffset.Now;
            // live windows only, as the widget's Get-Visible
            foreach (var s in feed.Ordered.Where(s => Num(s, "alive") == 1 && !here.Contains(Str(s, "sid"))))
            {
                var nick = Str(s, "nick");
                var cwd = Str(s, "cwd");
                want.Add((Str(s, "sid"), nick.Length > 0 ? nick : Str(s, "name"), Str(s, "project"),
                    cwd.Length > 0 ? SessionTab.ProjectBrushes[Project.Slot(cwd, SessionTab.ProjectBrushes.Length)] : null,
                    Num(s, "running") == 1 ? "working" : "idle", FooterRow.From(s, feed, 0, now)));
            }
        }

        for (var i = 0; i < want.Count; i++)
        {
            var w = want[i];
            var at = IndexOf(w.Key, i);
            if (at < 0) Items.Insert(i, new SidebarItem(w.Key));
            else if (at != i) Items.Move(at, i);
            Items[i].Set(w.Name, w.Project, w.Brush, w.State, w.Row, w.Key is string && (i == 0 || want[i - 1].Key is SessionTab));
        }
        while (Items.Count > want.Count) Items.RemoveAt(Items.Count - 1);
        Refreshed?.Invoke();
    }

    int IndexOf(object key, int from)
    {
        for (var j = from; j < Items.Count; j++) if (Equals(Items[j].Key, key)) return j;
        return -1;
    }

    static string Str(JsonObject? o, string k) => o?[k] is JsonValue v && v.TryGetValue(out string? s) ? s : "";
    static double Num(JsonObject o, string k) => o[k] is JsonValue v && v.TryGetValue(out double d) ? d : 0;
}
