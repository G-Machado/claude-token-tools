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
    /// <summary>The widget's collect, one watcher for every tab; the app collects itself when the widget is not running.</summary>
    internal static readonly Lazy<SessionFeed> Feed = new(() => new SessionFeed(collect: SessionControl.CollectAsync, usageDir: SessionUsageFile.DefaultDir));

    readonly DispatcherTimer _render;
    readonly DispatcherTimer _clock;
    ClaudeSession? _session;
    FooterRow? _row;
    string? _activity;
    string _status = "starting claude…";
    string _state = "starting";
    bool _waiting;
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
        DelegateReports.Landed += OnDelegateReport;
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
    public TranscriptProjector Transcript { get; } = new() { ReadFile = ReadFileOrNull, TicksPath = TickStore.DefaultPath };
    public ObservableCollection<TranscriptItem> Items => Transcript.Items;
    public string Status { get => _status; private set => Set(ref _status, value); }
    /// <summary>This session's row from the widget's collect; null until the widget has listed it.</summary>
    public FooterRow? Row { get => _row; private set => Set(ref _row, value); }
    public bool IsReady { get => _isReady; private set => Set(ref _isReady, value); }
    /// <summary>starting, idle, working or exited: the colour of the tab's dot.</summary>
    public string State { get => _state; private set => Set(ref _state, value); }
    /// <summary>Claude waits on the user (<see cref="TranscriptProjector.AwaitsAnswer"/>): the sidebar's yellow row.
    /// Beside State, not in it, since a pending card can sit inside a turn that is still working.</summary>
    public bool Waiting { get => _waiting; private set => Set(ref _waiting, value); }
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

    /// <summary>What the composer held when the window last showed another tab; the view puts it back.</summary>
    public string Draft { get; set; } = "";
    public int DraftCaret { get; set; }

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

    /// <summary>The aside button: the question goes to a throwaway fork (<see cref="Aside"/>), so the answer shows here
    /// while this session's window, queue and turn stay untouched. Works mid-turn too: the fork reads the transcript.</summary>
    public async Task AsideAsync(string question)
    {
        if (_session is not { Init: { } init }) { Transcript.AddNote(NoteKind.Warning, "aside: the session has not started yet"); return; }
        Transcript.AddNote(NoteKind.Info, "aside: " + question);
        var r = await Aside.AskAsync(Options, init, question);
        if (r.Error is { } error) { Transcript.AddNote(NoteKind.Error, "aside failed", error); return; }
        Transcript.AddAside(r.Text);
        Transcript.AddNote(NoteKind.Info, $"aside · ${r.CostUsd:0.000} · cache read {r.CacheRead / 1000.0:0.#}k, written {r.CacheWrite / 1000.0:0.#}k" +
                                          " · forked and discarded, not in this session's context");
    }

    /// <summary>A mark from token-sessions --poke-due. An open question or permission card holds the turn with no request
    /// going out, so "busy" there let the cache lapse behind it. Decline the cards instead: claude's reply to the decline
    /// is the renewal, so a renew mark ends there ("ok"); a /park stays "busy" and goes once the window is due again.</summary>
    public string PokeMark(string text)
    {
        var said = Poke(text);
        if (said != "busy" || _session is not { } s || Transcript.PendingPrompts is not { Count: > 0 } open) return said;
        const string away = "The user is away: a cache keep-alive closed this unanswered. Don't act on an assumed answer - " +
                            "end your reply by restating the question in one short line, then stop.";
        foreach (var card in open)
        {
            if (card is QuestionItem q) { q.State = QuestionState.Declined; _ = DenyQuietlyAsync(s, q.Request.RequestId); }
            else if (card is PermissionItem p) { p.State = PermissionState.Denied; _ = DenyQuietlyAsync(s, p.Request.RequestId); }
        }
        Transcript.AddNote(NoteKind.Info, $"Keep-alive mark: closed {open.Count} open question(s) so the cache renews - answer again when you're back.");
        UpdateStatus();
        return text.StartsWith('/') ? "busy" : "ok";

        async Task DenyQuietlyAsync(ClaudeSession session, string requestId)
        {
            try { await session.DenyAsync(requestId, away); }
            catch (Exception ex) { Transcript.AddNote(NoteKind.Error, "keep-alive decline failed", ex.Message); }
        }
    }

    /// <summary>A card's button. A block: lift it the way the widget's u does, then send the refused prompt again; or
    /// /park or /compact, which pass it. One button per card; a poke refused as busy leaves the card open.</summary>
    public async Task ActAsync(CardItem card, string key)
    {
        if (!card.IsOpen) return;
        switch (key)
        {
            case "lift" when SessionId is { } sid:
                card.Outcome = "lifting…";
                if (await SessionControl.RunAsync(SessionControl.Unblock(sid)) is { } error) { card.Outcome = null; Transcript.AddNote(NoteKind.Error, error); return; }
                Feed.Value.Patch(sid, o => o["blocked"] = 0)();
                card.Outcome = card.Payload is null ? "block lifted" : "block lifted - prompt sent again";
                if (card.Payload is { } prompt) await SendAsync(prompt);
                break;
            case "park" or "compact" or "handoff":
                var said = Poke("/" + key);
                if (said == "ok") card.Outcome = $"/{key} sent";
                else Transcript.AddNote(NoteKind.Warning, said == "busy" ? $"mid-turn - /{key} once the turn ends" : "claude has exited");
                break;
            case "read" when card.Payload is { } report:
                card.Outcome = "sent";
                DelegateReport.Log("read", Path.GetFileNameWithoutExtension(report), SessionId, null);
                await SendAsync($"Read the delegate report at {report} and summarise it: what changed, what is verified, how to merge.");
                break;
            case "dismiss":
                card.Outcome = "dismissed";
                if (card.Kind == "delegate") DelegateReport.Log("dismiss", Path.GetFileNameWithoutExtension(card.Payload), SessionId, null);
                break;
        }
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

    /// <summary>Sends a queued message into the running turn instead of after it; claude reads it at its next tool result.</summary>
    public async Task InjectAsync(QueuedMessage m)
    {
        if (_session is not { } s || !Queued.Remove(m)) return;
        if (s.AtCleanPoint) { await SendNowAsync(s, m); return; } // the turn ended meanwhile
        Transcript.AddInjected(m.Text, m.Files.Select(f => f.Label).ToList());
        try { await s.InjectAsync(m.Text, m.Files.Count == 0 ? null : Core.Attachments.Blocks(m.Text, m.Files)); }
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
    public void StopRendering()
    {
        _render.Stop();
        _clock.Stop();
        Feed.Value.Changed -= OnFeed;
        DelegateReports.Landed -= OnDelegateReport;
    }

    /// <summary>A /delegate this session launched has written its report: a card, one per report.</summary>
    void OnDelegateReport(DelegateReport r) => _clock.Dispatcher.BeginInvoke(() =>
    {
        if (_disposed || SessionId is not { } sid || !string.Equals(r.For, sid, StringComparison.OrdinalIgnoreCase)) return;
        var done = r.Done.Count == 0 ? "No Done list in the report." : string.Join("\n", r.Done.Select(d => "· " + d));
        Transcript.Items.Add(new CardItem("delegate", "DELEGATE DONE",
            $"{r.Topic ?? Path.GetFileNameWithoutExtension(r.Path)} on {r.Branch ?? "its branch"}:\n{done}",
            [new CardAction("Read it in", "read", Primary: true), new CardAction("Later", "dismiss")], r.Path));
        DelegateReport.Log("card", r.Topic, r.For, r.Sid);
    });

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
            case ResultEvent: _activity = null; TurnEnded?.Invoke(); if (!HandedOff) OfferHandoff(); break;
        }
    }

    double _offeredAtK;

    /// <summary>Per tab, from the model pill menu: "ask" (the card), "auto" (/handoff unasked) or "off". Not persisted;
    /// a new or resumed tab starts at ask.</summary>
    public string HandoffMode { get; set; } = "ask";

    /// <summary>Its tab went to the session a /handoff opened: it finishes its turn out of sight, then goes.</summary>
    public bool HandedOff { get; set; }
    /// <summary>A turn's result has arrived; the handed-off session waits on this before it is disposed.</summary>
    public event Action? TurnEnded;

    static readonly string AutoHandoffLog = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "token-auto-handoff.log");

    /// <summary>Auto-handoff: at a turn's end, once the context is past the collect's cut bar (cut_no, where carrying the
    /// window costs more per cycle than a restart). Ask mode adds a one-click card for /handoff, once per 50k band as the
    /// hook's ACTION line, so "not now" holds until the window has grown again. Auto mode sends a bare /handoff itself
    /// and logs it; a busy poke leaves the band open, so the next turn end tries again.</summary>
    void OfferHandoff()
    {
        if (HandoffMode == "off" || _session is not { } s || Feed.Value.Snapshot is not { } feed) return;
        var cut = SidebarItem.Num(feed.Constants, "cut_no");
        var ctxK = s.Usage.Context / 1000.0;
        if (cut <= 0 || ctxK < cut || (_offeredAtK > 0 && ctxK < _offeredAtK + 50)) return;
        if (HandoffMode == "auto")
        {
            var said = Poke("/handoff");
            try { File.AppendAllText(AutoHandoffLog, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss}\t{SessionId}\t{ctxK:0}\t{cut:0}\t{said}\n"); }
            catch (IOException) { }
            if (said != "ok") return;
            _offeredAtK = ctxK;
            Transcript.AddNote(NoteKind.Info, $"Context {ctxK:0}k is past the cut bar ({cut:0}k): /handoff sent (handoff: auto).");
            return;
        }
        _offeredAtK = ctxK;
        Transcript.Items.Add(new CardItem("handoff", "HAND OFF",
            $"Context {ctxK:0}k is past the cut bar ({cut:0}k): this window now costs more to carry per cycle than a fresh "
            + "one does to start. /handoff parks it and carries on in a new tab.",
            [new CardAction("Hand off", "handoff", Primary: true), new CardAction("Not now", "dismiss")]));
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
        Waiting = !_exitNoted && Transcript.AwaitsAnswer;
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
