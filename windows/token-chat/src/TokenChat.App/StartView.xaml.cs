using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;
using TokenChat.Core;

namespace TokenChat.App;

public sealed record RecentRow(string Name, string Path, string Ago);

/// <summary>What the window shows with no tab open, and over the tabs after "+": recent folders and a folder picker.</summary>
public partial class StartView : UserControl
{
    public StartView() => InitializeComponent();

    /// <summary>The folder to open a session in.</summary>
    public event Action<string>? Chosen;
    public event Action? Cancelled;

    /// <summary>canCancel: a tab is open to go back to.</summary>
    public void Show(IReadOnlyList<RecentProject> recents, bool canCancel)
    {
        Recents.ItemsSource = recents.Select(r => new RecentRow(r.Name, r.Path, Ago(r.LastUsedUtc))).ToList();
        Empty.Visibility = recents.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        CancelButton.Visibility = canCancel ? Visibility.Visible : Visibility.Collapsed;
        Visibility = Visibility.Visible;
        Focus();
    }

    static string Ago(DateTime utc)
    {
        var d = DateTime.UtcNow - utc;
        return d.TotalHours < 1 ? $"{Math.Max(0, (int)d.TotalMinutes)}m" : d.TotalDays < 1 ? $"{(int)d.TotalHours}h" : $"{(int)d.TotalDays}d";
    }

    void OnRecent(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is RecentRow r) Chosen?.Invoke(r.Path);
    }

    void OnBrowse(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = "Folder for the new session" };
        if (dialog.ShowDialog(Window.GetWindow(this)) == true) Chosen?.Invoke(dialog.FolderName);
    }

    void OnCancel(object sender, RoutedEventArgs e) => Cancelled?.Invoke();

    void OnKey(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Escape || CancelButton.Visibility != Visibility.Visible) return;
        e.Handled = true;
        Cancelled?.Invoke();
    }
}
