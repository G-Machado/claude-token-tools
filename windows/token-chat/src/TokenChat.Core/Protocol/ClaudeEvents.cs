using System.Text.Json.Nodes;

namespace TokenChat.Core.Protocol;

/// <summary>One stdout line of a headless claude.exe (stream-json), typed. <see cref="Raw"/> keeps
/// the parsed line for anything the record does not lift.</summary>
public abstract record ClaudeEvent
{
    public JsonObject Raw { get; init; } = new();
}

public sealed record InitEvent(string SessionId, string Cwd, string Model, string PermissionMode,
    IReadOnlyList<string> Tools, string? Version) : ClaudeEvent;

/// <summary>system:status, e.g. "requesting" while a request is in flight.</summary>
public sealed record StatusEvent(string? Status) : ClaudeEvent;

/// <summary>system:hook_started / hook_progress / hook_response. Phase is "started", "progress" or "response".</summary>
public sealed record HookEvent(string Phase, string HookName, string HookEventName, string? Output,
    int? ExitCode, string? Outcome) : ClaudeEvent;

public sealed record PermissionDeniedEvent(string ToolName, string? ToolUseId, string? Message) : ClaudeEvent;

public sealed record CompactBoundaryEvent(string? Trigger, long PreTokens, long PostTokens) : ClaudeEvent;

public sealed record ThinkingTokensEvent(long Estimated) : ClaudeEvent;

public sealed record InformationalEvent(string? Content, string? Level) : ClaudeEvent;

/// <summary>system:commands_changed: slash commands finished loading after init; the list is in Raw.</summary>
public sealed record CommandsChangedEvent : ClaudeEvent;

// stream_event: Anthropic SSE events. ParentToolUseId is null on the main chain, set inside a subagent.

public sealed record MessageStartEvent(string MessageId, string? Model, TokenUsage Usage, string? ParentToolUseId) : ClaudeEvent;

/// <summary>BlockType is "text", "thinking", "tool_use", ...; ToolName and ToolUseId only for tool_use.</summary>
public sealed record BlockStartEvent(int Index, string BlockType, string? ToolName, string? ToolUseId, string? ParentToolUseId) : ClaudeEvent;

public enum DeltaKind { Text, Thinking, InputJson, Signature, Other }

public sealed record DeltaEvent(int Index, DeltaKind Kind, string Text, string? ParentToolUseId) : ClaudeEvent;

public sealed record BlockStopEvent(int Index, string? ParentToolUseId) : ClaudeEvent;

/// <summary>Carries the final output token count of the message being streamed.</summary>
public sealed record MessageDeltaEvent(string? StopReason, TokenUsage Usage, string? ParentToolUseId) : ClaudeEvent;

public sealed record MessageStopEvent(string? ParentToolUseId) : ClaudeEvent;

/// <summary>Repeated once per content block with the same id. Its usage is the message_start
/// snapshot, so the output count is stale; the ledger takes the final one from message_delta.</summary>
public sealed record AssistantEvent(string MessageId, string? Model, JsonArray Content, TokenUsage Usage, string? ParentToolUseId) : ClaudeEvent;

/// <summary>Tool results, interrupt markers, compact summaries and local command output.</summary>
public sealed record UserEvent(JsonNode? Content, string? ParentToolUseId) : ClaudeEvent;

/// <summary>End of a turn. Usage is the sum over the turn's requests; zero after an interrupt.</summary>
public sealed record ResultEvent(string Subtype, bool IsError, string? Text, int NumTurns, TokenUsage Usage,
    double TotalCostUsd, long DurationMs, string? TerminalReason) : ClaudeEvent;

public sealed record RateWindow(double Utilization, DateTimeOffset ResetsAt);

/// <summary>Live subscription headroom: utilization is 0..1 of the five-hour and seven-day windows.</summary>
public sealed record RateLimitEvent(string? Status, RateWindow? FiveHour, RateWindow? SevenDay) : ClaudeEvent;

/// <summary>can_use_tool for any tool except AskUserQuestion. Waits for Allow or Deny.</summary>
public sealed record PermissionRequest(string RequestId, string ToolName, JsonObject Input, string? Description,
    string? ToolUseId, JsonArray? Suggestions) : ClaudeEvent;

public sealed record QuestionOption(string Label, string? Description);

public sealed record Question(string Text, string? Header, bool MultiSelect, IReadOnlyList<QuestionOption> Options);

/// <summary>can_use_tool for AskUserQuestion. Answered by allowing with input.answers = {question: label}.</summary>
public sealed record QuestionRequest(string RequestId, string? ToolUseId, JsonObject Input, IReadOnlyList<Question> Questions) : ClaudeEvent;

/// <summary>control_cancel_request: the CLI withdrew a prompt it was waiting on, e.g. after an interrupt.</summary>
public sealed record PromptCancelledEvent(string RequestId) : ClaudeEvent;

/// <summary>A control_request subtype token-chat does not handle; the session replies with an error so the CLI never hangs.</summary>
public sealed record UnhandledControlRequest(string RequestId, string? Subtype) : ClaudeEvent;

public sealed record ControlResponseEvent(string RequestId, bool Success, JsonObject? Response, string? Error) : ClaudeEvent;

/// <summary>A line whose type or subtype is not modelled (or not JSON: Type "unparsable", Raw["line"]).</summary>
public sealed record UnknownEvent(string Type, string? Subtype) : ClaudeEvent;
