using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows;
using TokenChat.Core;

namespace TokenChat.App;

public partial class MainWindow : Window
{
    readonly ObservableCollection<SessionTab> _tabs = [];

    public MainWindow()
    {
        InitializeComponent();
        Tabs.ItemsSource = _tabs;
        Tabs.SelectionChanged += (_, e) =>
        {
            if (e.OriginalSource == Tabs && _tabs.Count > 0) Start.Visibility = Visibility.Collapsed;
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

    public void Open(string directory)
    {
        var tab = new SessionTab(new LaunchOptions
        {
            WorkingDirectory = directory,
            Profile = LiteBox.IsChecked == true ? Profile.Lite : Profile.Full,
            Model = Model,
        });
        _tabs.Add(tab);
        Tabs.SelectedItem = tab;
        Start.Visibility = Visibility.Collapsed;
        _ = tab.StartAsync();
    }

    void OnNewTab(object sender, RoutedEventArgs e) => ShowStart();

    void ShowStart() => Start.Show(RecentProjects.Load(RecentProjects.DefaultRoot), canCancel: _tabs.Count > 0);

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
