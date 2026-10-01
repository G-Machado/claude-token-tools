using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows;
using Microsoft.Win32;
using TokenChat.Core;

namespace TokenChat.App;

public partial class MainWindow : Window
{
    readonly ObservableCollection<SessionTab> _tabs = [];

    public MainWindow()
    {
        InitializeComponent();
        Tabs.ItemsSource = _tabs;
        StateChanged += (_, _) =>
        {
            var max = WindowState == WindowState.Maximized;
            MaxGlyph.Content = max ? "❐" : "□";
            MaxGlyph.ToolTip = max ? "restore" : "maximise";
        };
    }

    void OnMinimise(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;

    void OnMaximise(object sender, RoutedEventArgs e) =>
        WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;

    void OnClose(object sender, RoutedEventArgs e) => Close();

    public void Open(LaunchOptions options)
    {
        var tab = new SessionTab(options);
        _tabs.Add(tab);
        Tabs.SelectedItem = tab;
        _ = tab.StartAsync();
    }

    void OnNewTab(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = "Working directory for the new session" };
        if (dialog.ShowDialog(this) != true) return;
        Open(new LaunchOptions
        {
            WorkingDirectory = dialog.FolderName,
            Profile = LiteBox.IsChecked == true ? Profile.Lite : Profile.Full,
        });
    }

    async void OnCloseTab(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not SessionTab tab) return;
        _tabs.Remove(tab);
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
