using System.Text.Json.Nodes;
using TokenChat.Core.Protocol;

namespace TokenChat.Core;

/// <summary>Token counts of one request, or a sum of requests.</summary>
public readonly record struct TokenUsage(long Input, long CacheWrite, long CacheRead, long Output)
{
    /// <summary>Prompt size of a single request: what the window holds when it was sent.</summary>
    public long Prompt => Input + CacheWrite + CacheRead;

    public static TokenUsage From(JsonNode? u) => new(
        Json.Long(u?["input_tokens"]), Json.Long(u?["cache_creation_input_tokens"]),
        Json.Long(u?["cache_read_input_tokens"]), Json.Long(u?["output_tokens"]));

    public static TokenUsage operator +(TokenUsage a, TokenUsage b) =>
        new(a.Input + b.Input, a.CacheWrite + b.CacheWrite, a.CacheRead + b.CacheRead, a.Output + b.Output);

    public static TokenUsage operator -(TokenUsage a, TokenUsage b) =>
        new(a.Input - b.Input, a.CacheWrite - b.CacheWrite, a.CacheRead - b.CacheRead, a.Output - b.Output);

    public static TokenUsage Max(TokenUsage a, TokenUsage b) => new(Math.Max(a.Input, b.Input),
        Math.Max(a.CacheWrite, b.CacheWrite), Math.Max(a.CacheRead, b.CacheRead), Math.Max(a.Output, b.Output));
}

/// <summary>Immutable view, swapped whole so another thread never reads a half-updated ledger.</summary>
/// <param name="Session">every request this process made, subagents included</param>
/// <param name="Turn">requests since the last result</param>
/// <param name="LastTurn">the turn that the last result closed</param>
/// <param name="Context">main-chain window size: prompt of the latest request, or post_tokens after a compact</param>
/// <param name="Floor">prompt of the first main-chain request: F in the auto-handoff bar (docs/token-chat-design.md)</param>
public sealed record UsageSnapshot(TokenUsage Session, TokenUsage Turn, TokenUsage LastTurn, long Context, long Floor);

/// <summary>Counts each API message once. assistant events repeat per content block and carry the
/// message_start usage (stale output count); message_delta carries the final output. Every sighting
/// is merged by field-wise max, so only growth is added.</summary>
public sealed class UsageLedger
{
    readonly Dictionary<string, TokenUsage> _messages = [];
    readonly Dictionary<string, string> _streaming = []; // parent tool use id ("" = main) -> message id
    string? _firstMainMessage;

    public UsageSnapshot Snapshot { get; private set; } = new(default, default, default, 0, 0);

    public void Apply(ClaudeEvent e)
    {
        switch (e)
        {
            case MessageStartEvent m:
                _streaming[m.ParentToolUseId ?? ""] = m.MessageId;
                Record(m.MessageId, m.Usage, m.ParentToolUseId);
                break;
            case AssistantEvent a:
                Record(a.MessageId, a.Usage, a.ParentToolUseId);
                break;
            case MessageDeltaEvent d when _streaming.TryGetValue(d.ParentToolUseId ?? "", out var id):
                Record(id, d.Usage, d.ParentToolUseId);
                break;
            case CompactBoundaryEvent c:
                Snapshot = Snapshot with { Context = c.PostTokens };
                break;
            case ResultEvent:
                Snapshot = Snapshot with { LastTurn = Snapshot.Turn, Turn = default };
                break;
        }
    }

    void Record(string messageId, TokenUsage usage, string? parentToolUseId)
    {
        if (messageId.Length == 0) return;
        var old = _messages.GetValueOrDefault(messageId);
        var merged = TokenUsage.Max(old, usage);
        _messages[messageId] = merged;
        var growth = merged - old;
        if (parentToolUseId is null) _firstMainMessage ??= messageId;
        Snapshot = Snapshot with
        {
            Session = Snapshot.Session + growth,
            Turn = Snapshot.Turn + growth,
            Context = parentToolUseId is null ? merged.Prompt : Snapshot.Context,
            Floor = messageId == _firstMainMessage ? merged.Prompt : Snapshot.Floor,
        };
    }
}
