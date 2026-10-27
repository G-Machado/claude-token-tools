using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.IO;
using System.ComponentModel;
using System.Text.Json.Nodes;
using System.Windows;
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
    /// <summary>The tab's State (starting, idle, working, exited), or waiting while it waits on the user; a session
    /// elsewhere is idle or working.</summary>
    public string State { get; private set; } = "";
    /// <summary>The widget's figures for the session, null until a collect has it.</summary>
    public FooterRow? Row { get; private set; }
    /// <summary>The session's entry in the last collect, which the controls read and patch; null until a collect has it.</summary>
    public JsonObject? Session { get; private set; }
    public string Sid => Tab?.SessionId ?? Key as string ?? "";
    public bool Blocked => Num(Session, "blocked") == 1;
    public bool HasSession => Session is not null;
    /// <summary>A session elsewhere has a window to bring forward; one here is its tab.</summary>
    public bool CanOpen => !Here && Session is not null;
    public string Cwd => Tab?.Options.WorkingDirectory ?? Str(Session, "cwd");
    public bool HasSid => Sid.Length > 0;
    /// <summary>The named group the session was moved into, "" under its folder.</summary>
    public string Group { get; private set; } = "";
    /// <summary>A group's header row: Name is the group's, Count its sessions, Folded hides them.</summary>
    public bool IsHeader => Key is GroupKey;
    public bool Named => Key is GroupKey { Id: ['#', ..] };
    public int Count { get; private set; }
    public bool Folded { get; private set; }
    /// <summary>A delegate nests under the session that launched it: Depth levels in, its name led by an arrow.</summary>
    public int Depth { get; private set; }
    public Thickness Indent => new(Depth * 14, 0, 0, 0);
    public string Arrow => Depth > 0 ? "↳ " : "";
    /// <summary>The delegates nested under it, folded away or shown.</summary>
    public int Children { get; private set; }
    public bool HasChildren => Children > 0;
    public bool ChildrenFolded { get; private set; }
    public string ChildLabel => (ChildrenFolded ? "▸ " : "▾ ") + Children + (Children == 1 ? " delegate" : " delegates");
    /// <summary>A delegate whose report has landed; its row stays until it is closed.</summary>
    public bool Reported { get; private set; }
    /// <summary>Master plan mode: a master's row carries an M and its summary ("2 delegates · 1 ask"); a delegate's dot
    /// shows running / asking (waiting on the master) / done / unlocked.</summary>
    public bool IsMaster { get; private set; }
    public string MasterSummary { get; private set; } = "";
    public string DelegateState { get; private set; } = "";

    public event PropertyChangedEventHandler? PropertyChanged;

    internal static string Str(JsonObject? o, string k) => o?[k] is JsonValue v && v.TryGetValue(out string? s) ? s : "";
    /// <summary>A parsed number reads as any numeric type, but one a control patched in keeps its own: an int written by
    /// Patch does not read as a double, and read as 0 it made the next mark click count up from nothing.</summary>
    internal static double Num(JsonObject? o, string k) => o?[k] is not JsonValue v ? 0
        : v.TryGetValue(out double d) ? d : v.TryGetValue(out int i) ? i : v.TryGetValue(out long l) ? l : 0;

    internal void Set(string name, string project, Brush? brush, string state, FooterRow? row, JsonObject? session, string group,
        int depth = 0, int children = 0, bool childrenFolded = false, bool reported = false,
        bool master = false, string masterSummary = "", string delegateState = "")
    {
        (Name, Project, ProjectBrush, State, Row, Session, Group) = (name, project, brush, state, row, session, group);
        (Depth, Children, ChildrenFolded, Reported) = (depth, children, childrenFolded, reported);
        (IsMaster, MasterSummary, DelegateState) = (master, masterSummary, delegateState);
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null)); // every binding re-reads
    }

    /// <summary>State is "waiting" only while folded with a session inside waiting, else "": the row's storyboards key
    /// on State and a header has no dot to animate.</summary>
    internal void SetHeader(string name, Brush? brush, string state, int count, bool folded)
    {
        (Name, ProjectBrush, State, Count, Folded) = (name, brush, state, count, folded);
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
    }
}

/// <summary>A header row's key: a SessionGroups id, "#name" or "P:" and the project key.</summary>
public sealed record GroupKey(string Id);

/// <summary>The sidebar's rows: a header per group, then its tabs in their order. Rebuilt on a collect (it names the
/// sessions), a tab change and a clock tick.</summary>
public sealed class Sidebar
{
    readonly ObservableCollection<SessionTab> _tabs;
    readonly Dispatcher _ui = Dispatcher.CurrentDispatcher;
    bool _queued;
    /// <summary>Delegate sids whose report has landed: those already in reports/ at start, then each one Landed.</summary>
    readonly HashSet<string> _reported = new(StringComparer.OrdinalIgnoreCase);

    public ObservableCollection<SidebarItem> Items { get; } = [];
    public UsageHeader Usage { get; } = new();
    /// <summary>Every project's checkpoints, newest first; replaced whole by RefreshParkedAsync.</summary>
    public ObservableCollection<Checkpoint> Parked { get; } = [];
    bool _listingParked;
    /// <summary>After every rebuild, on the UI thread.</summary>
    public event Action? Refreshed;

    public Sidebar(ObservableCollection<SessionTab> tabs)
    {
        _tabs = tabs;
        tabs.CollectionChanged += OnTabs;
        foreach (var t in tabs) t.PropertyChanged += OnTab;
        SessionTab.Feed.Value.Changed += Schedule;
        try
        {
            foreach (var f in Directory.EnumerateFiles(DelegateReport.Dir, "*.md"))
                if (DelegateReport.Parse(f, File.ReadAllText(f))?.Sid is { } s) _reported.Add(s);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        DelegateReports.Landed += r => _ui.BeginInvoke(() => { if (r.Sid is { } s && _reported.Add(s)) Schedule(); });
        // a running timer is held by its dispatcher
        _ = new DispatcherTimer(TimeSpan.FromSeconds(15), DispatcherPriority.Background, (_, _) => Schedule(), _ui);
        // the widget re-lists its Parked tab every five minutes and on opening it; the view asks for the second
        _ = new DispatcherTimer(TimeSpan.FromMinutes(5), DispatcherPriority.Background, (_, _) => _ = RefreshParkedAsync(), _ui);
        Refresh();
        _ = RefreshParkedAsync();
    }

    /// <summary>One listing at a time. A failed one keeps the last list. UI thread.</summary>
    public async Task RefreshParkedAsync()
    {
        if (_listingParked) return;
        _listingParked = true;
        try
        {
            if (await SessionControl.CheckpointsAsync() is not { } list) return;
            Parked.Clear();
            foreach (var c in list) Parked.Add(c);
        }
        finally { _listingParked = false; }
    }

    void OnTabs(object? sender, NotifyCollectionChangedEventArgs e)
    {
        foreach (var t in e.OldItems?.OfType<SessionTab>() ?? []) t.PropertyChanged -= OnTab;
        foreach (var t in e.NewItems?.OfType<SessionTab>() ?? []) t.PropertyChanged += OnTab;
        Schedule();
    }

    void OnTab(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(SessionTab.Row) or nameof(SessionTab.State) or nameof(SessionTab.Waiting)
            or nameof(SessionTab.IsMaster) or nameof(SessionTab.MasterSummary) or nameof(SessionTab.DelegateState)
            or nameof(SessionTab.HandedFrom) or nameof(SessionTab.AutoTitle)) Schedule();
    }

    /// <summary>Every tab sets its Row on its own clock and the feed lands on a pool thread: one rebuild per burst.</summary>
    void Schedule()
    {
        if (_queued) return;
        _queued = true;
        _ui.BeginInvoke(DispatcherPriority.Background, () => { _queued = false; Refresh(); });
    }

    /// <summary>This window's tabs only: the rows of sessions in other windows never loaded right (2026-10-26). Grouped:
    /// a session moved into a named group sits under it, the rest under their folder; groups in the order of their first
    /// tab, so a new tab's project opens where its tabs already are. A folded group keeps its header. A delegate whose
    /// parent is a tab here sits right under the parent's row, whatever its folder; the parent closed, it is back in its own.</summary>
    void Refresh()
    {
        var feed = SessionTab.Feed.Value.Snapshot;
        Usage.Set(feed);
        Record();
        var parents = ParentTabs();
        var kids = _tabs.Where(parents.ContainsKey).ToLookup(t => parents[t]);
        IEnumerable<SessionTab> Below(SessionTab t) => kids[t].SelectMany(c => Below(c).Prepend(c));
        var want = new List<(object Key, Action<SidebarItem> Set)>();
        foreach (var g in _tabs.Where(t => !parents.ContainsKey(t)).GroupBy(GroupOf))
        {
            var first = g.First();
            var named = g.Key.StartsWith('#');
            var name = named ? g.Key[1..] : Path.GetFileName(first.Options.WorkingDirectory.TrimEnd('\\', '/'));
            var folded = Groups.Folded.Contains(g.Key);
            var all = g.SelectMany(t => Below(t).Prepend(t)).ToList();
            var waits = folded && all.Any(t => t.Waiting);
            var count = all.Count;
            want.Add((new GroupKey(g.Key), i => i.SetHeader(name, named ? null : first.ProjectBrush, waits ? "waiting" : "", count, folded)));
            if (folded) continue;
            foreach (var t in g) Emit(t, 0);

            void Emit(SessionTab t, int depth)
            {
                JsonObject? s = null;
                if (t.SessionId is { } sid) feed?.Sessions.TryGetValue(sid, out s);
                // Haiku's title, else the topic, names the session; the tab's title (its folder) is then the project
                var nick = t.AutoTitle ?? Str(s, "nick");
                var children = kids[t].ToList();
                var shut = children.Count > 0 && t.SessionId is { } id && Groups.Folded.Contains(SessionGroups.SubId(id));
                // folded, the parent goes yellow while a delegate under it waits, as a folded group's header does; a card
                // that went up to the master is the master's to answer, not the user's
                bool Yours(SessionTab c) => c.Waiting && !c.AsksMaster;
                var waiting = Yours(t) || (shut && Below(t).Any(Yours));
                var reported = t.SessionId is { } rs && _reported.Contains(rs);
                want.Add((t, i => i.Set(nick.Length > 0 ? nick : t.Title, nick.Length > 0 ? t.Title : "", t.ProjectBrush,
                    waiting ? "waiting" : t.State, t.Row, s, named ? name : "", depth, children.Count, shut, reported,
                    t.IsMaster, t.MasterSummary, t.DelegateState)));
                if (!shut) foreach (var c in children) Emit(c, depth + 1);
            }
        }

        for (var i = 0; i < want.Count; i++)
        {
            var at = IndexOf(want[i].Key, i);
            if (at < 0) Items.Insert(i, new SidebarItem(want[i].Key));
            else if (at != i) Items.Move(at, i);
            want[i].Set(Items[i]);
        }
        while (Items.Count > want.Count) Items.RemoveAt(Items.Count - 1);
        Refreshed?.Invoke();
    }

    public SessionGroups Groups { get; } = SessionGroups.Load(SessionGroups.DefaultPath);

    /// <summary>Each tab's launching tab, when that is open here. A loop (never written, but the file is hand-editable)
    /// is cut where it closes.</summary>
    Dictionary<SessionTab, SessionTab> ParentTabs()
    {
        var map = new Dictionary<SessionTab, SessionTab>();
        foreach (var t in _tabs)
            if (t.SessionId is { } sid && Groups.Parents.TryGetValue(sid, out var p)
                && _tabs.FirstOrDefault(o => o != t && string.Equals(o.SessionId, p, StringComparison.OrdinalIgnoreCase)) is { } parent)
                map[t] = parent;
        foreach (var t in map.Keys.ToList())
        {
            var seen = new HashSet<SessionTab> { t };
            for (var p = map.GetValueOrDefault(t); p is not null; p = map.GetValueOrDefault(p))
                if (!seen.Add(p)) { map.Remove(t); break; }
        }
        return map;
    }

    /// <summary>A tab's parent and topic come from its first prompt, which a --resume after a restart does not repeat:
    /// kept by session id as soon as the tab has one.</summary>
    void Record()
    {
        var changed = false;
        foreach (var t in _tabs)
        {
            if (t.SessionId is not { } sid) continue;
            // a master that handed off: its delegates nest under the window that took over
            if (t.HandedFrom is { } old && !string.Equals(old, sid, StringComparison.OrdinalIgnoreCase))
                foreach (var k in Groups.Parents.Where(p => string.Equals(p.Value, old, StringComparison.OrdinalIgnoreCase)).Select(p => p.Key).ToList())
                {
                    Groups.Parents[k] = sid;
                    changed = true;
                }
            if (t.ParentSid is { } p0 && Heir(p0) is var p && Groups.Parents.GetValueOrDefault(sid) != p) { Groups.Parents[sid] = p; changed = true; }
            if (t.Topic is null && Groups.Topics.TryGetValue(sid, out var known)) t.Topic = known;
            else if (t.Topic is { } topic && Groups.Topics.GetValueOrDefault(sid) != topic) { Groups.Topics[sid] = topic; changed = true; }
            if (t.AutoTitle is null && Groups.Titles.TryGetValue(sid, out var title)) t.AutoTitle = title;
            else if (t.AutoTitle is { } at && Groups.Titles.GetValueOrDefault(sid) != at) { Groups.Titles[sid] = at; changed = true; }
        }
        if (changed) Write();
    }

    /// <summary>A parent sid, or the sid of the tab here that took it over by handover.</summary>
    string Heir(string sid) => _tabs.FirstOrDefault(t => string.Equals(t.HandedFrom, sid, StringComparison.OrdinalIgnoreCase))?.SessionId ?? sid;

    string GroupOf(SessionTab t) => t.SessionId is { } sid && Groups.Members.TryGetValue(sid, out var name)
        ? SessionGroups.NamedId(name) : SessionGroups.ProjectId(t.Options.WorkingDirectory);

    /// <summary>Into a named group, or back under its folder with null.</summary>
    public void Move(string sid, string? name) { Groups.Move(sid, name); Save(); }
    public void Rename(string from, string to) { Groups.Rename(from, to); Save(); }
    public void Ungroup(string name) { Groups.Ungroup(name); Save(); }

    public void Toggle(string id)
    {
        if (!Groups.Folded.Remove(id)) Groups.Folded.Add(id);
        Save();
    }

    public void FoldAll(bool fold)
    {
        foreach (var h in Items.Select(i => i.Key).OfType<GroupKey>())
            if (fold) Groups.Folded.Add(h.Id); else Groups.Folded.Remove(h.Id);
        Save();
    }

    /// <summary>A tab picked while its group is folded: open the group so its row can be selected. False when it was
    /// open, so a caller retrying on a missing row cannot loop.</summary>
    public bool Unfold(SessionTab tab)
    {
        // a delegate's row is also hidden by a folded parent, and its group is its top parent's
        var parents = ParentTabs();
        var root = tab;
        var any = false;
        for (var p = parents.GetValueOrDefault(tab); p is not null; root = p, p = parents.GetValueOrDefault(p))
            any |= p.SessionId is { } sid && Groups.Folded.Remove(SessionGroups.SubId(sid));
        any |= Groups.Folded.Remove(GroupOf(root));
        if (!any) return false;
        Save();
        return true;
    }

    void Save()
    {
        Write();
        Refresh();
    }

    /// <summary>A file that will not write keeps the change for this run.</summary>
    void Write()
    {
        try { Groups.Save(SessionGroups.DefaultPath); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    int IndexOf(object key, int from)
    {
        for (var j = from; j < Items.Count; j++) if (Equals(Items[j].Key, key)) return j;
        return -1;
    }

    static string Str(JsonObject? o, string k) => SidebarItem.Str(o, k);
}
