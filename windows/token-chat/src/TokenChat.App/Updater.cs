using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Threading;
using TokenChat.Core;

namespace TokenChat.App;

/// <summary>The daily update check and the update itself. Once a day (and from the tray on demand) it fetches the clone
/// and, with commits to pull, shows the caption's update pill and a tray balloon. Taking the update waits until no tab
/// is busy, writes the <see cref="RestoreManifest"/>, starts update.ps1 outside this process (pull, install.sh, build,
/// relaunch with --restore) and closes the window; every tab reopens in the new build where it was.
/// A restart is the same without the pull: deploy a local build.</summary>
sealed class Updater : INotifyPropertyChanged
{
    readonly Window _owner;
    readonly IList<SessionTab> _tabs;
    readonly Func<string, RestoreManifest> _snapshot;
    readonly DispatcherTimer _daily, _wait;
    UpdateState _state = UpdateState.Load(UpdateState.DefaultPath);
    UpdateStatus? _status;
    bool _checking, _pull;
    string _pill = "", _tip = "";

    /// <summary>A balloon worth showing: title, text, and what clicking it does.</summary>
    public event Action<string, string, Action>? Notify;

    public Updater(Window owner, IList<SessionTab> tabs, Func<string, RestoreManifest> snapshot)
    {
        _owner = owner;
        _tabs = tabs;
        _snapshot = snapshot;
        Repo = AppUpdate.FindRepo();
        // first look a minute after startup (claude processes are spawning then), then hourly to see whether a day passed
        _daily = new DispatcherTimer(TimeSpan.FromMinutes(1), DispatcherPriority.Background, async (_, _) =>
        {
            _daily!.Interval = TimeSpan.FromHours(1);
            if (_state.Due(DateTimeOffset.Now)) await CheckAsync(manual: false);
        }, owner.Dispatcher);
        _wait = new DispatcherTimer(TimeSpan.FromSeconds(2), DispatcherPriority.Background, (_, _) => Tick(), owner.Dispatcher) { IsEnabled = false };
    }

    public string? Repo { get; }

    /// <summary>The caption pill: empty hides it.</summary>
    public string Pill { get => _pill; private set => Set(ref _pill, value); }
    public string Tip { get => _tip; private set => Set(ref _tip, value); }
    /// <summary>Waiting for busy tabs before closing for the update or restart.</summary>
    public bool Pending => _wait.IsEnabled;

    public async Task CheckAsync(bool manual)
    {
        if (_checking || Pending) return;
        if (Repo is null)
        {
            if (manual) Say("No claude-token-tools clone found (install.sh records it in ~/.claude/token-tools-src).", MessageBoxImage.Warning);
            return;
        }
        _checking = true;
        try
        {
            _status = await AppUpdate.CheckAsync(Repo);
            _state.LastCheck = DateTimeOffset.Now;
            _state.Save(UpdateState.DefaultPath);
        }
        finally { _checking = false; }
        ShowPill();
        if (_status.Error is { } error)
        {
            if (manual) Say($"Update check failed: {error}", MessageBoxImage.Warning);
            return;
        }
        if (!_status.Available)
        {
            if (manual) Say(_status.Ahead > 0 ? $"Up to date with {_status.Upstream} ({_status.Ahead} local commit{(_status.Ahead == 1 ? "" : "s")} not pushed)."
                : $"Up to date with {_status.Upstream}.", MessageBoxImage.Information);
            return;
        }
        if (manual) { Offer(); return; }
        if (_state.Snoozed(_status.UpstreamSha, DateTimeOffset.Now)) return;
        Notify?.Invoke("TokenChat update", $"{_status.Behind} new commit{(_status.Behind == 1 ? "" : "s")} on {_status.Upstream}. Click to update and restart.", Offer);
    }

    void ShowPill()
    {
        if (Pending)
        {
            var busy = Busy();
            Pill = busy.Count == 0 ? (_pull ? "UPDATING" : "RESTARTING") : $"{(_pull ? "UPDATE" : "RESTART")} · WAITING ON {busy.Count}";
            Tip = busy.Count == 0 ? "closing; every session reopens in the new build"
                : "restarts once these finish:\n" + string.Join("\n", busy.Select(Describe)) + "\n\nclick to restart now or cancel";
            return;
        }
        if (_status is not { Available: true } s) { Pill = ""; Tip = ""; return; }
        Pill = s.Blocker is not null ? "UPDATE (BY HAND)" : s.AppChanged ? $"UPDATE · {s.Behind}" : $"UPDATE · {s.Behind} · NO RESTART";
        Tip = string.Join("\n", s.Commits) + (s.Behind > s.Commits.Count ? "\n..." : "") + "\n\nclick to update";
    }

    /// <summary>The prompt: what is new, what the update will do, and the user's yes. No is "later": not offered again
    /// for this commit until tomorrow's check. The default button is No, so an Enter meant for the composer cannot take it.</summary>
    public void Offer()
    {
        if (Pending) { WhileWaiting(); return; }
        if (_status is not { Available: true } s) { _ = CheckAsync(manual: true); return; }
        var news = string.Join("\n", s.Commits.Select(c => "  " + c)) + (s.Behind > s.Commits.Count ? $"\n  ... {s.Behind - s.Commits.Count} more" : "");
        if (s.Blocker is { } blocker)
        {
            Say($"{s.Behind} new commit{(s.Behind == 1 ? "" : "s")} on {s.Upstream}:\n{news}\n\nThe update can't run from here: {blocker}.\n\n" +
                $"In {s.Repo}: git pull, then ./install.sh, then use Restart TokenChat in the tray menu.", MessageBoxImage.Warning);
            return;
        }
        if (!s.AppChanged) { OfferInPlace(s, news); return; }
        var open = Reopenable().Count;
        var drift = Drift(s);
        var busy = Busy().Count;
        var answer = MessageBox.Show(_owner,
            $"{s.Behind} new commit{(s.Behind == 1 ? "" : "s")} on {s.Upstream}:\n{news}\n\n" +
            $"Update pulls them, runs install.sh, rebuilds TokenChat and restarts it. " +
            $"{(open == 0 ? "No sessions are open." : $"The {open} open session{(open == 1 ? "" : "s")} reopen{(open == 1 ? "s" : "")} where {(open == 1 ? "it is" : "they are")}.")}" +
            (busy > 0 ? $" It waits for the {busy} busy one{(busy == 1 ? "" : "s")} to finish first." : "") + drift +
            "\n\nUpdate now? (No: remind me tomorrow)",
            "TokenChat update", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No);
        if (answer == MessageBoxResult.Yes) Begin(pull: true);
        else Snooze(s);
    }

    /// <summary>Nothing of TokenChat's own changes: pull and install while everything stays open, no restart.</summary>
    async void OfferInPlace(UpdateStatus s, string news)
    {
        var answer = MessageBox.Show(_owner,
            $"{s.Behind} new commit{(s.Behind == 1 ? "" : "s")} on {s.Upstream}:\n{news}\n\n" +
            "None of them change TokenChat itself: Update pulls them and runs install.sh, with no restart. Your sessions stay " +
            "as they are; scripts and hooks take effect on their next run, slash commands on their next use." + Drift(s) +
            "\n\nUpdate now? (No: remind me tomorrow)",
            "TokenChat update", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No);
        if (answer != MessageBoxResult.Yes) { Snooze(s); return; }
        Pill = "UPDATING";
        var (ok, text) = await AppUpdate.PullAndInstallAsync(s.Repo);
        _status = null;
        ShowPill();
        Say(text, ok ? MessageBoxImage.Information : MessageBoxImage.Warning);
    }

    /// <summary>Live ~/.claude files install.sh would overwrite: hot-fixes made there and never copied back.</summary>
    static string Drift(UpdateStatus s) => s.LiveDrift.Count == 0 ? ""
        : $"\n\ninstall.sh will replace {s.LiveDrift.Count} live file{(s.LiveDrift.Count == 1 ? "" : "s")} in ~/.claude that differ from the repo " +
          $"(a .bak of each is kept): {string.Join(", ", s.LiveDrift.Take(6))}{(s.LiveDrift.Count > 6 ? ", ..." : "")}";

    void Snooze(UpdateStatus s)
    {
        _state.SnoozedSha = s.UpstreamSha;
        _state.SnoozedAt = DateTimeOffset.Now;
        _state.Save(UpdateState.DefaultPath);
    }

    /// <summary>The tray's Restart TokenChat: the same close and reopen, on a fresh build of this clone, no pull.</summary>
    public void Restart()
    {
        if (Pending) { WhileWaiting(); return; }
        if (Repo is null) { Say("No claude-token-tools clone found to build from.", MessageBoxImage.Warning); return; }
        Begin(pull: false);
    }

    void Begin(bool pull)
    {
        _pull = pull;
        _wait.Start();
        Tick();
    }

    /// <summary>The pill clicked while waiting: restart now (the busy turns are cut short and resumed), keep waiting, or cancel.</summary>
    void WhileWaiting()
    {
        var busy = Busy();
        var answer = MessageBox.Show(_owner,
            $"Waiting for:\n{string.Join("\n", busy.Select(t => "  " + Describe(t)))}\n\n" +
            "Yes: restart now (their turns stop here; the sessions still reopen).\nNo: keep waiting.\nCancel: don't restart.",
            "TokenChat", MessageBoxButton.YesNoCancel, MessageBoxImage.Question, MessageBoxResult.No);
        if (answer == MessageBoxResult.Yes) Go();
        else if (answer == MessageBoxResult.Cancel) { _wait.Stop(); ShowPill(); }
    }

    void Tick()
    {
        ShowPill();
        if (Busy().Count == 0) Go();
    }

    List<SessionTab> Busy() => Reopenable().Where(t => t.Busy).ToList();

    List<SessionTab> Reopenable() => _tabs.Where(t => !t.HandedOff && !t.IsReplay).ToList();

    static string Describe(SessionTab t) =>
        (t.AutoTitle ?? t.Title) + (t.Waiting ? " (waits on your answer)" : t.Queued.Count > 0 ? " (messages queued)" : " (working)");

    /// <summary>Manifest first, then the helper; the window closes only once the helper is running, so a failed start
    /// leaves everything open as it was.</summary>
    void Go()
    {
        _wait.Stop();
        var script = Repo is null ? null : Path.Combine(Repo, "windows", "token-chat", "update.ps1");
        if (script is null || !File.Exists(script)) { Fail($"update.ps1 not found in {Repo}"); return; }
        var path = RestoreManifest.DefaultPath;
        try { _snapshot(_pull ? "update" : "restart").Save(path); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { Fail("could not write the restore manifest: " + e.Message); return; }
        var line = $"powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{script}\" -Repo \"{Repo}\" " +
                   $"-AppPid {Environment.ProcessId} -Manifest \"{path}\"" + (_pull ? " -Pull" : "");
        if (StartDetached(line) is { } error)
        {
            RestoreManifest.MarkDone(path);
            Fail(error);
            return;
        }
        Pill = _pull ? "UPDATING" : "RESTARTING";
        _owner.Close();
    }

    void Fail(string why)
    {
        ShowPill();
        Say($"The {(_pull ? "update" : "restart")} did not start: {why}\nNothing was closed.", MessageBoxImage.Warning);
    }

    /// <summary>Through WMI, as preview/restart.ps1 learned: the helper's parent is WmiPrvSE, not this process, so it is
    /// outside any job this process runs in and survives the close. Null when it started; else why not.</summary>
    static string? StartDetached(string commandLine)
    {
        var info = new ProcessStartInfo("powershell.exe") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true };
        foreach (var a in new[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
                     "$si = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }; " +
                     "$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $env:TOKENCHAT_UPDATE_CMD; ProcessStartupInformation = $si }; " +
                     "exit [int]$r.ReturnValue" })
            info.ArgumentList.Add(a);
        info.Environment["TOKENCHAT_UPDATE_CMD"] = commandLine;
        try
        {
            using var p = Process.Start(info)!;
            var err = p.StandardError.ReadToEnd();
            if (!p.WaitForExit(30_000)) return "the WMI launch did not answer in 30 s";
            return p.ExitCode == 0 ? null : $"Win32_Process.Create returned {p.ExitCode} {err.Trim()}";
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException) { return e.Message; }
    }

    void Say(string text, MessageBoxImage icon) => MessageBox.Show(_owner, text, "TokenChat update", MessageBoxButton.OK, icon);

    public event PropertyChangedEventHandler? PropertyChanged;

    void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    /// <summary>The note update.ps1 leaves for the relaunched app (~/.claude/tokenchat-update-result.txt): first line
    /// "ok ..." or what failed, the rest detail. Read once, then deleted.</summary>
    public static (bool Ok, string Text)? TakeResult()
    {
        var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "tokenchat-update-result.txt");
        try
        {
            if (!File.Exists(path)) return null;
            var text = File.ReadAllText(path).Trim();
            File.Delete(path);
            return (text.StartsWith("ok", StringComparison.Ordinal), text);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }
}
