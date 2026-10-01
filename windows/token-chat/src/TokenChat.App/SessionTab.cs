using System.Collections.Concurrent;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Runtime.CompilerServices;
using System.Windows.Threading;
using TokenChat.Core;
using TokenChat.Core.Protocol;
using TokenChat.Core.Transcript;

namespace TokenChat.App;

/// <summary>One tab: a headless session, its transcript and status line. A background reader moves events
/// into an inbox; a 10 Hz dispatcher timer drains it on the UI thread, which is also the streaming throttle.</summary>
public sealed class SessionTab : INotifyPropertyChanged, IAsyncDisposable
{
    static readonly TimeSpan RenderInterval = TimeSpan.FromMilliseconds(100);

    readonly ConcurrentQueue<ClaudeEvent> _inbox = new();
    readonly DispatcherTimer _render;
    ClaudeSession? _session;
    string? _activity;
    string _status = "starting claude…";
    string _state = "starting";
    string _mode = "";
    bool _isReady, _exitNoted, _disposed;
    volatile bool _readerDone;

    public SessionTab(LaunchOptions options)
    {
        Options = options;
        var name = Path.GetFileName(options.WorkingDirectory.TrimEnd('\\', '/'));
        Title = options.Profile == Profile.Lite ? name + " · lite" : name;
        _render = new DispatcherTimer(RenderInterval, DispatcherPriority.Normal, (_, _) => Drain(), Dispatcher.CurrentDispatcher);
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public LaunchOptions Options { get; }
    public string Title { get; }
    public TranscriptProjector Transcript { get; } = new() { ReadFile = ReadFileOrNull };
    public ObservableCollection<TranscriptItem> Items => Transcript.Items;
    public string Status { get => _status; private set => Set(ref _status, value); }
    public bool IsReady { get => _isReady; private set => Set(ref _isReady, value); }
    /// <summary>starting, idle, working or exited: the colour of the tab's dot.</summary>
    public string State { get => _state; private set => Set(ref _state, value); }
    /// <summary>The permission mode as the footer shows it.</summary>
    public string Mode { get => _mode; private set => Set(ref _mode, value); }

    public async Task StartAsync()
    {
        try
        {
            var session = await ClaudeSession.StartAsync(Options);
            if (_disposed)
            {
                await session.DisposeAsync();
                return;
            }
            _session = session;
            _ = Task.Run(ReadAsync);
            IsReady = true;
            UpdateStatus();
        }
        catch (Exception ex)
        {
            Transcript.AddNote(NoteKind.Error, "claude did not start", ex.Message);
            Status = "not started";
            State = "exited";
        }
    }

    public async Task SendAsync(string text)
    {
        if (_session is not { } s || !IsReady) return;
        Transcript.AddUser(text);
        try { await s.SendAsync(text); }
        catch (Exception ex) { Transcript.AddNote(NoteKind.Error, "send failed", ex.Message); }
        UpdateStatus();
    }

    public async Task InterruptAsync()
    {
        if (_session is not { AtCleanPoint: false } s) return;
        try { await s.InterruptAsync(); }
        catch (Exception ex) { Transcript.AddNote(NoteKind.Error, "interrupt failed", ex.Message); }
    }

    public async Task DecideAsync(PermissionItem p, PermissionState decision)
    {
        if (_session is not { } s || p.State != PermissionState.Pending || decision == PermissionState.Pending) return;
        p.State = decision;
        try
        {
            switch (decision)
            {
                case PermissionState.Allowed: await s.AllowAsync(p.Request); break;
                case PermissionState.AllowedForSession: await s.AllowAsync(p.Request, updatedPermissions: p.SessionRules); break;
                default: await s.DenyAsync(p.Request.RequestId, "The user denied this tool call."); break;
            }
        }
        catch (Exception ex) { Transcript.AddNote(NoteKind.Error, "permission reply failed", ex.Message); }
        UpdateStatus(); // a setMode rule moves the mode
    }

    public async Task AnswerAsync(QuestionItem q)
    {
        if (_session is not { } s || !q.CanSubmit) return;
        var answers = q.Answers();
        q.State = QuestionState.Answered;
        try { await s.AnswerAsync(q.Request, answers); }
        catch (Exception ex) { Transcript.AddNote(NoteKind.Error, "answer failed", ex.Message); }
        UpdateStatus();
    }

    public async Task DeclineAsync(QuestionItem q)
    {
        if (_session is not { } s || q.State != QuestionState.Pending) return;
        q.State = QuestionState.Declined;
        try { await s.DenyAsync(q.Request.RequestId, "The user declined to answer. Ask in plain text if you still need to know."); }
        catch (Exception ex) { Transcript.AddNote(NoteKind.Error, "decline failed", ex.Message); }
        UpdateStatus();
    }

    /// <summary>shift+tab: the next mode in <see cref="ClaudeLauncher.PermissionModes"/>, applied to the running process.</summary>
    public async Task CycleModeAsync()
    {
        if (_session is not { } s || !IsReady) return;
        try { await s.SetPermissionModeAsync(ClaudeLauncher.NextPermissionMode(s.PermissionMode ?? Options.PermissionMode)); }
        catch (Exception ex) { Transcript.AddNote(NoteKind.Error, "mode change failed", ex.Message); }
        UpdateStatus();
    }

    /// <summary>UI thread only; call before <see cref="DisposeAsync"/>, which may run on any thread.</summary>
    public void StopRendering() => _render.Stop();

    public async ValueTask DisposeAsync()
    {
        _disposed = true;
        if (_session is { } s) await s.DisposeAsync();
    }

    async Task ReadAsync()
    {
        try
        {
            await foreach (var e in _session!.Events.ReadAllAsync()) _inbox.Enqueue(e);
        }
        catch (Exception ex)
        {
            _inbox.Enqueue(new InformationalEvent("session failed: " + ex.Message, "error"));
        }
        finally { _readerDone = true; }
    }

    void Drain()
    {
        var changed = false;
        while (_inbox.TryDequeue(out var e))
        {
            Handle(e);
            changed = true;
        }
        Transcript.Flush();
        if (_readerDone && _inbox.IsEmpty && !_exitNoted)
        {
            _exitNoted = true;
            IsReady = false;
            Transcript.AddNote(NoteKind.Error, "claude exited");
            _render.Stop();
            changed = true;
        }
        if (changed) UpdateStatus();
    }

    void Handle(ClaudeEvent e)
    {
        Transcript.Apply(e);
        switch (e)
        {
            case StatusEvent s: _activity = s.Status; break;
            case ResultEvent: _activity = null; break;
        }
    }

    /// <summary>Write previews diff against this; a missing, locked or huge file previews as new.</summary>
    static string? ReadFileOrNull(string path)
    {
        try
        {
            var f = new FileInfo(path);
            return f.Exists && f.Length <= 4 << 20 ? File.ReadAllText(path) : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return null;
        }
    }

    void UpdateStatus()
    {
        if (_session is not { } s) return;
        var u = s.Usage;
        State = _exitNoted ? "exited" : s.AtCleanPoint ? "idle" : "working";
        Mode = (s.PermissionMode ?? Options.PermissionMode) switch { "acceptEdits" => "accept edits", var m => m } + " mode";
        string? Pct(RateWindow? w) => w is null ? null : (w.Utilization * 100).ToString("0", CultureInfo.InvariantCulture) + "%";
        string?[] parts =
        [
            s.Init?.Model,
            Options.Profile.ToString().ToLowerInvariant(),
            $"ctx {Tokens.K(u.Context)}",
            $"floor {Tokens.K(u.Floor)}",
            $"out {Tokens.K(u.Session.Output)}",
            Pct(s.RateLimit?.FiveHour) is { } five ? "5h " + five : null,
            Pct(s.RateLimit?.SevenDay) is { } seven ? "7d " + seven : null,
            _exitNoted ? "exited" : s.AtCleanPoint ? "idle" : _activity ?? "working",
        ];
        Status = string.Join("  ·  ", parts.Where(p => p is not null));
    }

    void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
