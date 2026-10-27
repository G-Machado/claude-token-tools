using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using TokenChat.Core;

namespace TokenChat.App;

/// <summary>Every session as the widget lists it, this window's first; Sidebar fills it, MainWindow syncs it with the
/// tabs. The widget's row keys act on the selected row - e / shift+e marks, u the block, y, o, enter - from the keyboard,
/// the row's menu and, for the two used most, buttons on the selected row.</summary>
public partial class SidebarView : UserControl
{
    readonly DispatcherTimer _flash = new() { Interval = TimeSpan.FromSeconds(4) };

    public SidebarView()
    {
        InitializeComponent();
        _flash.Tick += (_, _) => { _flash.Stop(); Note.Text = "sessions"; Note.Foreground = (Brush)FindResource("Faint"); };
        List.PreviewKeyDown += OnKey;
        List.MouseDoubleClick += (_, _) => { if (List.SelectedItem is SidebarItem item) Open(item); };
        // a header folds on a click and is never selected
        List.PreviewMouseLeftButtonDown += (_, e) =>
        {
            if (ItemsControl.ContainerFromElement(List, e.OriginalSource as DependencyObject) is not ListBoxItem { DataContext: SidebarItem { IsHeader: true } h }) return;
            Toggle(h);
            e.Handled = true;
        };
        ParkedList.MouseDoubleClick += (_, _) => { if (ParkedList.SelectedItem is Checkpoint c) Unpark?.Invoke(c); };
        ParkedList.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Enter || ParkedList.SelectedItem is not Checkpoint c) return;
            Unpark?.Invoke(c);
            e.Handled = true;
        };
        ParkedBox.Checked += (_, _) => OpenedParked?.Invoke();
    }

    /// <summary>A checkpoint's enter: MainWindow resumes it, or brings forward the window still holding it.</summary>
    public event Action<Checkpoint>? Unpark;
    /// <summary>The section opened: re-list, as the widget does on opening its Parked tab.</summary>
    public event Action? OpenedParked;

    /// <summary>The rows' model, for the group actions; MainWindow sets it.</summary>
    public Sidebar? Model { get; set; }

    /// <summary>The header's line, for what MainWindow's unpark has to say.</summary>
    public void Say(string text) => Flash(text);

    /// <summary>The widget's flash: a line in the header for a few seconds, then the label again.</summary>
    void Flash(string text)
    {
        Note.Text = text;
        Note.Foreground = (Brush)FindResource("Dim");
        _flash.Interval = TimeSpan.FromSeconds(4);
        _flash.Stop();
        _flash.Start();
    }

    /// <summary>"+": the start page, to open a session in a folder.</summary>
    public event Action? NewSession;
    /// <summary>A row's close: MainWindow ends the session and moves the chat on.</summary>
    public event Action<SessionTab>? CloseSession;

    static SidebarItem? ItemOf(object sender) => (sender as FrameworkElement)?.DataContext as SidebarItem;

    /// <summary>The pinned analytics row: MainWindow swaps the chat for the analytics view.</summary>
    public event Action? ShowAnalytics;

    void OnNew(object sender, RoutedEventArgs e) => NewSession?.Invoke();
    void OnAnalytics(object sender, RoutedEventArgs e) => ShowAnalytics?.Invoke();
    void OnCloseRow(object sender, RoutedEventArgs e) { if (ItemOf(sender)?.Tab is { } tab) CloseSession?.Invoke(tab); }

    /// <summary>/park as a poke: the composer's text and attachments stay, and a session mid-turn says so.</summary>
    void OnPark(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is not { Tab: { } tab } item) return;
        Flash(tab.Poke("/park") switch
        {
            "ok" => $"{item.Name}: /park sent",
            "busy" => $"{item.Name} is mid-turn - park it once the turn ends",
            _ => $"{item.Name} has exited",
        });
    }

    void OnMarkUp(object sender, RoutedEventArgs e) { if (ItemOf(sender) is { } item) Mark(item, 1); }
    void OnMarkDown(object sender, RoutedEventArgs e) { if (ItemOf(sender) is { } item) Mark(item, -1); }
    void OnUnblock(object sender, RoutedEventArgs e) { if (ItemOf(sender) is { } item) Unblock(item); }
    void OnOpen(object sender, RoutedEventArgs e) { if (ItemOf(sender) is { } item) Open(item); }
    void OnCopy(object sender, RoutedEventArgs e) { if (ItemOf(sender) is { } item) Copy(item); }
    void OnFolder(object sender, RoutedEventArgs e) { if (ItemOf(sender) is { } item) Folder(item); }

    void Toggle(SidebarItem header) => Model?.Toggle(((GroupKey)header.Key).Id);

    /// <summary>A parent's "N delegates": folds them under its row, or shows them.</summary>
    void OnToggleChildren(object sender, MouseButtonEventArgs e)
    {
        if (ItemOf(sender) is not { Sid: { Length: > 0 } sid }) return;
        Model?.Toggle(SessionGroups.SubId(sid));
        e.Handled = true;
    }

    /// <summary>The row menu's "move to group", built as it opens so it lists the groups as they are now.</summary>
    void OnGroupMenu(object sender, RoutedEventArgs e)
    {
        if (e.OriginalSource != sender || sender is not MenuItem menu || ItemOf(menu) is not { } item || Model is not { } model) return;
        menu.Items.Clear();
        foreach (var name in model.Groups.Names.Where(n => n != item.Group))
        {
            var to = name;
            menu.Items.Add(Entry(to, () => model.Move(item.Sid, to)));
        }
        menu.Items.Add(Entry("new group…", () =>
        {
            if (AskName("new group", "") is { } name) model.Move(item.Sid, name);
        }));
        if (item.Group.Length > 0) menu.Items.Add(Entry("back to its folder", () => model.Move(item.Sid, null)));
    }

    static MenuItem Entry(string header, Action act)
    {
        var m = new MenuItem { Header = header };
        m.Click += (_, _) => act();
        return m;
    }

    void OnRenameGroup(object sender, RoutedEventArgs e)
    {
        if (ItemOf(sender) is { Named: true } h && AskName("rename the group", h.Name) is { } name && name != h.Name)
            Model?.Rename(h.Name, name);
    }

    void OnUngroup(object sender, RoutedEventArgs e) { if (ItemOf(sender) is { Named: true } h) Model?.Ungroup(h.Name); }
    void OnFoldAll(object sender, RoutedEventArgs e) => Model?.FoldAll(true);
    void OnUnfoldAll(object sender, RoutedEventArgs e) => Model?.FoldAll(false);

    /// <summary>A one-line prompt over the window: enter keeps the trimmed text, esc or an empty line is null.</summary>
    string? AskName(string title, string initial)
    {
        var box = new TextBox { Text = initial, MinWidth = 220, Margin = new Thickness(12), Padding = new Thickness(4, 3, 4, 3),
            Background = (Brush)FindResource("Inset"), Foreground = (Brush)FindResource("Text"), BorderBrush = (Brush)FindResource("Line"),
            CaretBrush = (Brush)FindResource("Text") };
        var win = new Window
        {
            Title = title, Content = box, Owner = Window.GetWindow(this), SizeToContent = SizeToContent.WidthAndHeight,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ResizeMode = ResizeMode.NoResize,
            WindowStyle = WindowStyle.ToolWindow, ShowInTaskbar = false, Background = (Brush)FindResource("Card"),
        };
        box.KeyDown += (_, k) =>
        {
            if (k.Key == Key.Enter) win.DialogResult = true;
            else if (k.Key == Key.Escape) win.DialogResult = false;
        };
        win.Loaded += (_, _) => { box.Focus(); box.SelectAll(); };
        return win.ShowDialog() == true && box.Text.Trim() is { Length: > 0 } name ? name : null;
    }

    void OnKey(object sender, KeyEventArgs e)
    {
        if (List.SelectedItem is not SidebarItem item || (Keyboard.Modifiers & (ModifierKeys.Control | ModifierKeys.Alt)) != 0) return;
        if (item.IsHeader)
        {
            if (e.Key is not (Key.Enter or Key.Space or Key.Left or Key.Right)) return;
            // left folds, right unfolds, enter and space flip
            if (e.Key switch { Key.Left => !item.Folded, Key.Right => item.Folded, _ => true }) Toggle(item);
            e.Handled = true;
            return;
        }
        switch (e.Key)
        {
            case Key.E: Mark(item, (Keyboard.Modifiers & ModifierKeys.Shift) != 0 ? -1 : 1); break;
            case Key.U: Unblock(item); break;
            case Key.Y: Copy(item); break;
            case Key.O: Folder(item); break;
            case Key.Enter: Open(item); break;
            default: return;
        }
        e.Handled = true;
    }

    /// <summary>The widget's e: the absolute count goes to the script, so held keys cannot apply out of order, and the
    /// row shows it on the keystroke.</summary>
    void Mark(SidebarItem item, int delta)
    {
        var feed = SessionTab.Feed.Value;
        if (item.Session is not { } s) { Flash("no collect has this session yet"); return; }
        var cap = (int)SidebarItem.Num(feed.Snapshot?.Constants, "ext_max") is > 0 and var c ? c : 5;
        var used = (int)SidebarItem.Num(s, "ext_used");
        var marks = SessionControl.NextMarks((int)SidebarItem.Num(s, "ext_allowed"), used, cap, delta);
        var done = feed.Patch(item.Sid, o => { o["ext_allowed"] = marks; o["ext_left"] = Math.Max(0, marks - used); });
        Run(SessionControl.Extend(item.Sid, marks), done,
            delta < 0 && marks > 0 && marks == used ? $"{item.Name}: those {marks} are spent - a hollow mark cannot be removed"
            : delta > 0 && marks == cap ? $"{item.Name}: {marks} marks, the cap - past this the answer is /park"
            : $"{item.Name}: {marks} extension mark{(marks == 1 ? "" : "s")}");
    }

    /// <summary>The widget's u. Lifted, but the checkpoint is still the point, so the flash says what was skipped.</summary>
    void Unblock(SidebarItem item)
    {
        if (!item.Blocked) { Flash($"{item.Name} is not blocked"); return; }
        var done = SessionTab.Feed.Value.Patch(item.Sid, o => o["blocked"] = 0);
        Run(SessionControl.Unblock(item.Sid), done, $"{item.Name}: block lifted - it re-arms at the next lapse with no marks left");
    }

    async void Run(IReadOnlyList<string> args, Action done, string said)
    {
        Flash(said);
        var error = await SessionControl.RunAsync(args);
        done();
        if (error is not null) Flash(error);
    }

    string? _switchArmed;
    DateTime _switchArmedAt;

    /// <summary>The widget's w, on any other account's row: the first click prices the switch for the warm windows
    /// (the cache is per account), a second one inside the window makes it. Longer to answer when there is a bill to
    /// read.</summary>
    async void OnAccount(object sender, MouseButtonEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not AccountRow { Active: false } row || row.N == "-") return;
        var (windows, tokens, unparked) = SessionControl.SwitchBurn(SessionTab.Feed.Value.Snapshot);
        var wait = TimeSpan.FromSeconds(windows > 0 ? 15 : 5);
        if (_switchArmed != row.N || DateTime.UtcNow - _switchArmedAt > wait)
        {
            _switchArmed = row.N;
            _switchArmedAt = DateTime.UtcNow;
            var said = $"click again to switch to account {row.N} (5h at {row.FiveHour.Pct})";
            if (windows > 0) said += $" - burns {tokens / 1000:0}k across {windows} warm window{(windows == 1 ? "" : "s")}";
            if (unparked.Count > 0) said += $". UNPARKED: {string.Join(", ", unparked)} - /park then /clear there first";
            Flash(said);
            _flash.Interval = wait;
            _flash.Stop();
            _flash.Start();
            return;
        }
        _switchArmed = null;
        Flash($"switching to account {row.N}…");
        var error = await SessionControl.SwitchAccountAsync(row.N);
        if (error is not null) { Flash(error); return; }
        SessionTab.Feed.Value.Soon();
        Flash($"switched to account {row.N} - the header follows at the next collect");
    }

    /// <summary>Enter on a session elsewhere brings its window forward; a row here already shows its tab.</summary>
    async void Open(SidebarItem item)
    {
        if (!item.CanOpen || item.Session is not { } s) return;
        Flash($"opening {item.Name}…");
        Flash(await SessionControl.OpenAsync(item.Sid, item.Cwd, (int)SidebarItem.Num(s, "pid")));
    }

    void Copy(SidebarItem item)
    {
        if (item.Sid.Length == 0) { Flash("no session id until the first prompt"); return; }
        try
        {
            Clipboard.SetText(SessionControl.ResumeCommand(item.Cwd, item.Sid));
            Flash($"copied: claude -r {item.Sid[..Math.Min(8, item.Sid.Length)]}");
        }
        catch (System.Runtime.InteropServices.COMException) { Flash("could not reach the clipboard"); }
    }

    void Folder(SidebarItem item)
    {
        if (!Directory.Exists(item.Cwd)) { Flash("the folder is gone"); return; }
        Process.Start("explorer.exe", item.Cwd);
        Flash($"opened {Path.GetFileName(item.Cwd.TrimEnd('\\', '/'))}");
    }
}
