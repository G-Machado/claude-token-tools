using System.Drawing;
using System.Windows;
using System.Windows.Forms;
using TokenChat.Core;

namespace TokenChat.App;

/// <summary>The tray icon: the app's notifications land here, and a click brings the window back. Closing the window
/// still quits; the icon goes with it.</summary>
sealed class Tray : IDisposable
{
    readonly NotifyIcon _icon;
    readonly Window _window;
    readonly Alerts _alerts = new();

    readonly ToolStripMenuItem _remote = new("Remote access: off");

    public Tray(Window window, RemoteServer remote)
    {
        _window = window;
        var menu = new ContextMenuStrip();
        menu.Items.Add("Open TokenChat", null, (_, _) => Bring());
        // the page on the LAN: a click turns it on and shows where and the code; on, a click turns it off
        _remote.Click += async (_, _) =>
        {
            if (remote.IsOn) { await remote.StopAsync(); _remote.Text = "Remote access: off"; return; }
            try { await remote.StartAsync(); }
            catch (Exception ex) { System.Windows.MessageBox.Show($"Remote access failed to start: {ex.Message}", "TokenChat"); return; }
            ShowRemote(remote);
        };
        remote.CodeChanged += () => { if (remote.IsOn) ShowRemote(remote, quiet: true); };
        menu.Items.Add(_remote);
        menu.Items.Add("Quit", null, (_, _) => _window.Close());
        _icon = new NotifyIcon
        {
            Icon = Environment.ProcessPath is { } exe ? Icon.ExtractAssociatedIcon(exe) : SystemIcons.Application,
            Text = "TokenChat",
            ContextMenuStrip = menu,
            Visible = true,
        };
        _icon.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) Bring(); };
        _icon.BalloonTipClicked += (_, _) => Bring();
        SessionTab.Feed.Value.Changed += OnFeed;
    }

    void OnFeed() => _window.Dispatcher.BeginInvoke(() =>
    {
        if (SessionTab.Feed.Value.Snapshot is not { } feed) return;
        // Windows shows one balloon at a time; the newest wins, so several at once go out as one
        var said = _alerts.Check(feed, DateTimeOffset.UtcNow);
        if (said.Count == 0) return;
        var title = said.Count == 1 ? said[0].Title : $"{said.Count} things need you";
        var text = said.Count == 1 ? said[0].Text : string.Join("\n", said.Select(s => s.Title));
        _icon.ShowBalloonTip(10_000, title, text, ToolTipIcon.Warning);
    });

    void ShowRemote(RemoteServer remote, bool quiet = false)
    {
        _remote.Text = $"Remote access: on · code {remote.Code} (click to stop)";
        if (quiet) return;
        var urls = RemoteServer.Urls();
        System.Windows.MessageBox.Show($"Open on the Quest or phone:\n\n{string.Join("\n", urls)}\n\nPairing code: {remote.Code}\n\n" +
                        "Paired devices remember it. The code stays in the tray menu.", "TokenChat remote access");
    }

    void Bring()
    {
        if (_window.WindowState == WindowState.Minimized) _window.WindowState = WindowState.Normal;
        _window.Show();
        _window.Activate();
    }

    public void Dispose()
    {
        SessionTab.Feed.Value.Changed -= OnFeed;
        _icon.Visible = false;
        _icon.Dispose();
    }
}
