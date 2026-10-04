using System.Collections.Concurrent;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Runtime.CompilerServices;
using System.Windows.Media;
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

    /// <summary>Project colours: hues no state uses (the dot's green, blue and red; the question card's yellow).
    /// violet, pink, teal, lime, fuchsia, sand.</summary>
    internal static readonly Brush[] ProjectBrushes =
        [.. new[] { "#A78BFA", "#F472B6", "#2DD4BF", "#A3E635", "#D946EF", "#CBB994" }.Select(Frozen)];

    static Brush Frozen(string hex)
    {
        var b = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
        b.Freeze();
        return b;
    }

    readonly ConcurrentQueue<ClaudeEvent> _inbox = new();
    /// <summary>The widget's collect, one watcher for every tab.</summary>
    internal static readonly Lazy<SessionFeed> Feed = new(() => new SessionFeed());

    readonly DispatcherTimer _render;
    readonly DispatcherTimer _clock;
    ClaudeSession? _session;
    FooterRow? _row;
    string? _activity;
    string _status = "starting claude…";
    string _state = "starting";
    string _mode = "";
    bool _isReady, _exitNoted, _disposed;
    volatile bool _readerDone;
    string? _firstPrompt;
    readonly IClaudeTransport? _replay;

    /// <summary>firstPrompt goes out as the first message once claude is up: the Parked tab's /unpark. replay stands in
    /// for claude (--preview).</summary>
    public SessionTab(LaunchOptions options, string? firstPrompt = null, IClaudeTransport? replay = null)
    {
        Options = options;
        _firstPrompt = firstPrompt;
        _replay = replay;
        var name = Path.GetFileName(options.WorkingDirectory.TrimEnd('\\', '/'));
        Title = options.Profile == Profile.Lite ? name + " · lite" : name;
        ProjectKey = Project.Key(options.WorkingDirectory);
        ProjectBrush = ProjectBrushes[Project.Slot(options.WorkingDirectory, ProjectBrushes.Length)];
        _render = new DispatcherTimer(RenderInterval, DispatcherPriority.Normal, (_, _) => Drain(), Dispatcher.CurrentDispatcher);
        Attachments.CollectionChanged += (_, _) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(AttachmentsTotal)));
        // the cache clock runs down between collects
        _clock = new DispatcherTimer(TimeSpan.FromSeconds(15), DispatcherPriority.Background, (_, _) => UpdateStatus(), Dispatcher.CurrentDispatcher);
        Feed.Value.Changed += OnFeed;
        // The stream starts at the next turn; claude has the history, this tab does not.
        if (options.ResumeSessionId is { } sid)
            Transcript.AddNote(NoteKind.Info, $"Resumed {sid[..Math.Min(8, sid.Length)]}", "earlier turns are in the session but not shown here");
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public LaunchOptions Options { get; }
    /// <summary>The session this tab holds: the one it resumed, else claude's own once init has arrived.
    /// A resume keeps its id (measured 2026-10-01), so the two never disagree.</summary>
    public string? SessionId => Options.ResumeSessionId ?? _session?.SessionId;
    public string Title { get; }
    /// <summary>Tabs of one project sit together: a new one opens after its project's last.</summary>
    public string ProjectKey { get; }
    /// <summary>The stripe on the tab's top edge.</summary>
    public Brush ProjectBrush { get; }
    public TranscriptProjector Transcript { get; } = new() { ReadFile = ReadFileOrNull };
    public ObservableCollection<TranscriptItem> Items => Transcript.Items;
    public string Status { get => _status; private set => Set(ref _status, value); }
    /// <summary>This session's row from the widget's collect; null until the widget has listed it.</summary>
    public FooterRow? Row { get => _row; private set => Set(ref _row, value); }
    public bool IsReady { get => _isReady; private set => Set(ref _isReady, value); }
    /// <summary>starting, idle, working or exited: the colour of the tab's dot.</summary>
    public string State { get => _state; private set => Set(ref _state, value); }
    /// <summary>The permission mode as the footer shows it.</summary>
    public string Mode { get => _mode; private set => Set(ref _mode, value); }

    public async Task StartAsync()
    {
        try
        {
            var session = await (_replay is { } replay ? ClaudeSession.StartAsync(replay) : ClaudeSession.StartAsync(Options));
            if (_disposed)
            {
                await session.DisposeAsync();
                return;
            }
            _session = session;
            _ = Task.Run(ReadAsync);
            IsReady = true;
            UpdateStatus();
            if (_firstPrompt is { } prompt)
            {
                _firstPrompt = null;
                await SendAsync(prompt);
            }
        }
        catch (Exception ex)
        {
            Transcript.AddNote(NoteKind.Error, "claude did not start", ex.Message);
            Status = "not started";
            State = "exited";
        }
    }

    /// <summary>Typed while a turn runs; sent as one message when it ends, or handed back to the input by stop.</summary>
    public ObservableCollection<QueuedMessage> Queued { get; } = [];

    /// <summary>Files dropped or pasted into the input, going out with the next message.</summary>
    public ObservableCollection<Attachment> Attachments { get; } = [];

    /// <summary>"3 files ≈ 7.2k tokens" over the chips; empty with none.</summary>
    public string AttachmentsTotal => Attachments.Count == 0 ? ""
        : $"{Attachments.Count} file{(Attachments.Count == 1 ? "" : "s")} ≈ {Tokens.K(Attachments.Sum(a => a.Tokens))} tokens";

    /// <summary>Goes out now at a clean point; otherwise waits in <see cref="Queued"/>. Takes the pending attachments.</summary>
    public async Task SendAsync(string text)
    {
        if (_session is not { } s || !IsReady) return;
        var m = new QueuedMessage(text, [.. Attachments]);
        Attachments.Clear();
        if (!s.AtCleanPoint)
        {
            Queued.Add(m);
            return;
        }
        await SendNowAsync(s, m);
    }

    async Task SendNowAsync(ClaudeSession s, QueuedMessage m)
    {
        Transcript.AddUser(m.Text, m.Files.Select(f => f.Label).ToList());
        try { await (m.Files.Count == 0 ? s.SendAsync(m.Text) : s.SendAsync(Core.Attachments.Blocks(m.Text, m.Files))); }
        catch (Exception ex) { Transcript.AddNote(NoteKind.Error, "send failed", ex.Message); }
        UpdateStatus();
    }

    /// <summary>A poke (<see cref="PokeRequest"/>): "ok" once handed to claude, "busy" while a turn, prompt or queued message
    /// is open (that turn renews the cache anyway), "no-tab" once claude has exited. Leaves the input, queue and attachments
    /// alone. A renewal renders dimmed; a /park renders like any message.</summary>
    public string Poke(string text)
    {
        if (_exitNoted || _disposed) return "no-tab";
        if (_session is not { AtCleanPoint: true } s || !IsReady || Queued.Count > 0) return "busy";
        Transcript.AddUser(text, renewal: !text.StartsWith('/'));
        _ = PokeNowAsync(s, text);
        return "ok";
    }

    /// <summary>The footer's effort menu: /effort for this session only (settings.json untouched), sent the way a poke is.
    /// Local, so no request and no tokens; the footer label follows on the next reply.</summary>
    public void SetEffort(string level)
    {
        if (Poke("/effort " + level) == "busy")
            Transcript.AddNote(NoteKind.Info, $"Effort unchanged: a turn is open. Pick {level} again once it ends.");
    }

    async Task PokeNowAsync(ClaudeSession s, string text)
    {
        try { await s.SendAsync(text); }
        catch (Exception ex) { Transcript.AddNote(NoteKind.Error, "poke failed", ex.Message); }
        UpdateStatus();
    }

    /// <summary>The queued messages as one, oldest first, and an empty queue; null if there were none.</summary>
    public QueuedMessage? TakeQueued()
    {
        if (Queued.Count == 0) return null;
        var m = new QueuedMessage(string.Join("\n\n", Queued.Select(q => q.Text).Where(t => t.Length > 0)), [.. Queued.SelectMany(q => q.Files)]);
        Queued.Clear();
        return m;
    }

    public void Attach(Attachment a) => Attachments.Add(a);

    public void Detach(Attachment a) => Attachments.Remove(a);

    public void Unqueue(QueuedMessage m) => Queued.Remove(m);

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
    public void StopRendering()
    {
        _render.Stop();
        _clock.Stop();
        Feed.Value.Changed -= OnFeed;
    }

    void OnFeed() => _clock.Dispatcher.BeginInvoke(UpdateStatus);

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
        if (Queued.Count > 0 && IsReady && _session is { AtCleanPoint: true } s) _ = SendNowAsync(s, TakeQueued()!);
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
        Row = SessionId is { } sid && Feed.Value.Snapshot is { } feed && feed.Sessions.TryGetValue(sid, out var row)
            ? FooterRow.From(row, feed, u.Context, DateTimeOffset.Now)
            : null;
        var state = _exitNoted ? "exited" : s.AtCleanPoint ? "idle" : _activity ?? "working";
        // headless claude has no id until its first prompt, so the widget can't list it yet; its zeros say less than this
        if (SessionId is null)
        {
            Status = string.Join("  ·  ", Options.Profile.ToString().ToLowerInvariant(), "row after first prompt", state);
            return;
        }
        string? Pct(RateWindow? w) => w is null ? null : (w.Utilization * 100).ToString("0", CultureInfo.InvariantCulture) + "%";
        // model and ctx are on the row's line once the widget has this session
        string?[] parts =
        [
            Row is null ? s.Init?.Model : null,
            Options.Profile.ToString().ToLowerInvariant(),
            Row is null ? $"ctx {Tokens.K(u.Context)}" : null,
            $"floor {Tokens.K(u.Floor)}",
            $"out {Tokens.K(u.Session.Output)}",
            Pct(s.RateLimit?.FiveHour) is { } five ? "5h " + five : null,
            Pct(s.RateLimit?.SevenDay) is { } seven ? "7d " + seven : null,
            state,
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

/// <summary>A class, not a record: two identical messages are still two rows.</summary>
public sealed class QueuedMessage(string text, IReadOnlyList<Attachment> files)
{
    public string Text { get; } = text;
    public IReadOnlyList<Attachment> Files { get; } = files;
    public string Preview { get; } = text.ReplaceLineEndings(" ⏎ ")
        + (files.Count == 0 ? "" : $"{(text.Length == 0 ? "" : "  ")}+{files.Count} file{(files.Count == 1 ? "" : "s")}");
}
