using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using System.Threading.Channels;
using TokenChat.Core.Protocol;

namespace TokenChat.Core;

public sealed class ClaudeProtocolException(string message) : Exception(message);

/// <summary>One headless claude process: a pump reads stdout into <see cref="Events"/> after updating
/// usage, rate limit and pending state; the methods write stdin. One session, one front end.</summary>
public sealed class ClaudeSession : IAsyncDisposable
{
    readonly IClaudeTransport _transport;
    readonly Channel<ClaudeEvent> _events = Channel.CreateUnbounded<ClaudeEvent>(new UnboundedChannelOptions { SingleReader = true });
    readonly ConcurrentDictionary<string, TaskCompletionSource<ControlResponseEvent>> _pending = new();
    readonly ConcurrentDictionary<string, byte> _openPrompts = new(); // can_use_tool requests awaiting an answer
    readonly UsageLedger _ledger = new();
    readonly CancellationTokenSource _cts = new();
    Task? _pump;
    int _nextRequest;
    int _turnsInFlight;

    public ClaudeSession(IClaudeTransport transport) => _transport = transport;

    /// <summary>Single reader. Completes when the process exits, faulted if the pump failed.</summary>
    public ChannelReader<ClaudeEvent> Events => _events.Reader;

    public UsageSnapshot Usage => _ledger.Snapshot;
    public RateLimitEvent? RateLimit { get; private set; }
    public InitEvent? Init { get; private set; }
    /// <summary>initialize response: account, models, commands, agents, pid.</summary>
    public JsonObject? InitializeInfo { get; private set; }
    public string? SessionId => Init?.SessionId;
    /// <summary>From each turn's init, else the last <see cref="SetPermissionModeAsync"/>; null before either.
    /// init says default for what --permission-mode calls manual.</summary>
    public string? PermissionMode { get; private set; }

    /// <summary>No turn running and no permission or question waiting: safe to hand off, compact or park.</summary>
    public bool AtCleanPoint => Volatile.Read(ref _turnsInFlight) == 0 && _openPrompts.IsEmpty;

    public static Task<ClaudeSession> StartAsync(LaunchOptions options, TimeSpan? handshakeTimeout = null, CancellationToken ct = default) =>
        StartAsync(new ProcessTransport(ClaudeLauncher.Build(options)), handshakeTimeout, ct);

    /// <summary>Over any transport: a <see cref="ReplayTransport"/> for --preview.</summary>
    public static async Task<ClaudeSession> StartAsync(IClaudeTransport transport, TimeSpan? handshakeTimeout = null, CancellationToken ct = default)
    {
        var session = new ClaudeSession(transport);
        try
        {
            await session.HandshakeAsync(handshakeTimeout ?? TimeSpan.FromSeconds(60), ct);
            return session;
        }
        catch
        {
            await session.DisposeAsync();
            throw;
        }
    }

    /// <summary>Starts the stdout pump. Idempotent; <see cref="HandshakeAsync"/> calls it.</summary>
    public void Start() => _pump ??= Task.Run(PumpAsync);

    public async Task HandshakeAsync(TimeSpan timeout, CancellationToken ct = default)
    {
        Start();
        var r = await RequestAsync(Outbound.Initialize, ct).WaitAsync(timeout, ct);
        if (!r.Success) throw new ClaudeProtocolException("initialize failed: " + r.Error);
        InitializeInfo = r.Response;
    }

    public Task SendAsync(string text, CancellationToken ct = default) => SendLineAsync(Outbound.UserText(text), ct);

    /// <summary>Content blocks, e.g. <see cref="Outbound.TextBlock"/> and <see cref="Outbound.ImageBlock"/>.</summary>
    public Task SendAsync(JsonArray blocks, CancellationToken ct = default) => SendLineAsync(Outbound.User(blocks), ct);

    /// <summary>Stops the running turn; a result with subtype error_during_execution follows.</summary>
    public async Task InterruptAsync(CancellationToken ct = default)
    {
        var r = await RequestAsync(Outbound.Interrupt, ct);
        if (!r.Success) throw new ClaudeProtocolException("interrupt failed: " + r.Error);
    }

    /// <summary>Switches mode in the running process, mid-turn included, like shift+tab in the terminal.</summary>
    public async Task SetPermissionModeAsync(string mode, CancellationToken ct = default)
    {
        var r = await RequestAsync(id => Outbound.SetPermissionMode(id, mode), ct);
        if (!r.Success) throw new ClaudeProtocolException("set_permission_mode failed: " + r.Error);
        PermissionMode = mode;
    }

    /// <summary>updatedPermissions as from <see cref="PermissionRules.ForSession"/>; a setMode among them moves <see cref="PermissionMode"/>.</summary>
    public async Task AllowAsync(PermissionRequest p, JsonObject? updatedInput = null, JsonArray? updatedPermissions = null,
        CancellationToken ct = default)
    {
        await ReplyAsync(p.RequestId, Outbound.Allow(p.RequestId, updatedInput ?? p.Input, updatedPermissions), ct);
        if (updatedPermissions?.OfType<JsonObject>().LastOrDefault(u => Json.Str(u["type"]) == "setMode") is { } m)
            PermissionMode = Json.Str(m["mode"]) ?? PermissionMode;
    }

    public Task DenyAsync(string requestId, string message, CancellationToken ct = default) =>
        ReplyAsync(requestId, Outbound.Deny(requestId, message), ct);

    /// <summary>answers maps question text to the chosen option label.</summary>
    public Task AnswerAsync(QuestionRequest q, IReadOnlyDictionary<string, string> answers, CancellationToken ct = default) =>
        ReplyAsync(q.RequestId, Outbound.Answer(q, answers), ct);

    async Task SendLineAsync(string line, CancellationToken ct)
    {
        Interlocked.Increment(ref _turnsInFlight);
        await _transport.WriteLineAsync(line, ct);
    }

    async Task ReplyAsync(string requestId, string line, CancellationToken ct)
    {
        await _transport.WriteLineAsync(line, ct);
        _openPrompts.TryRemove(requestId, out _);
    }

    async Task<ControlResponseEvent> RequestAsync(Func<string, string> build, CancellationToken ct)
    {
        var id = "tc-" + Interlocked.Increment(ref _nextRequest);
        var tcs = new TaskCompletionSource<ControlResponseEvent>(TaskCreationOptions.RunContinuationsAsynchronously);
        _pending[id] = tcs;
        try
        {
            await _transport.WriteLineAsync(build(id), ct);
            return await tcs.Task.WaitAsync(ct);
        }
        finally { _pending.TryRemove(id, out _); }
    }

    async Task PumpAsync()
    {
        Exception? fault = null;
        try
        {
            await foreach (var line in _transport.ReadLinesAsync(_cts.Token))
            {
                var e = EventParser.Parse(line);
                await ObserveAsync(e);
                await _events.Writer.WriteAsync(e, _cts.Token);
            }
        }
        catch (OperationCanceledException) when (_cts.IsCancellationRequested) { }
        catch (Exception ex) { fault = ex; }
        finally
        {
            _events.Writer.TryComplete(fault);
            foreach (var p in _pending.Values) p.TrySetException(fault ?? new ClaudeProtocolException("claude exited"));
        }
    }

    async ValueTask ObserveAsync(ClaudeEvent e)
    {
        _ledger.Apply(e);
        switch (e)
        {
            case InitEvent i:
                Init = i;
                PermissionMode = i.PermissionMode == "default" ? "manual" : i.PermissionMode;
                break;
            case RateLimitEvent r: RateLimit = r; break;
            case PermissionRequest p: _openPrompts[p.RequestId] = 0; break;
            case QuestionRequest q: _openPrompts[q.RequestId] = 0; break;
            case PromptCancelledEvent c: _openPrompts.TryRemove(c.RequestId, out _); break;
            case ResultEvent:
                if (Interlocked.Decrement(ref _turnsInFlight) < 0) Interlocked.Exchange(ref _turnsInFlight, 0);
                _openPrompts.Clear(); // a prompt left open when its turn ends was withdrawn by an interrupt
                break;
            case ControlResponseEvent c when _pending.TryGetValue(c.RequestId, out var tcs):
                tcs.TrySetResult(c);
                break;
            case UnhandledControlRequest u:
                await _transport.WriteLineAsync(Outbound.ControlError(u.RequestId, $"token-chat does not handle {u.Subtype}"), _cts.Token);
                break;
        }
    }

    public async ValueTask DisposeAsync()
    {
        await _cts.CancelAsync();
        await _transport.DisposeAsync();
        if (_pump is not null) await _pump;
        _cts.Dispose();
    }
}
