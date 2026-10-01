using System.Text.Json;
using System.Text.Json.Nodes;

namespace TokenChat.Core.Protocol;

/// <summary>stream-json line to <see cref="ClaudeEvent"/>. Never throws on an unknown shape:
/// unmodelled types become <see cref="UnknownEvent"/>, non-JSON becomes UnknownEvent("unparsable").</summary>
public static class EventParser
{
    public static ClaudeEvent Parse(string line)
    {
        JsonObject? o;
        try { o = JsonNode.Parse(line) as JsonObject; }
        catch (JsonException) { o = null; }
        if (o is null) return new UnknownEvent("unparsable", null) { Raw = new JsonObject { ["line"] = line } };
        return ParseObject(o) with { Raw = o };
    }

    static ClaudeEvent ParseObject(JsonObject o)
    {
        var type = Json.Str(o["type"]) ?? "";
        var sub = Json.Str(o["subtype"]);
        var parent = Json.Str(o["parent_tool_use_id"]);
        switch (type)
        {
            case "system":
                return sub switch
                {
                    "init" => new InitEvent(Json.Str(o["session_id"]) ?? "", Json.Str(o["cwd"]) ?? "",
                        Json.Str(o["model"]) ?? "", Json.Str(o["permissionMode"]) ?? "",
                        Json.Strings(o["tools"]), Json.Str(o["claude_code_version"])),
                    "status" => new StatusEvent(Json.Str(o["status"])),
                    "hook_started" or "hook_progress" or "hook_response" => new HookEvent(sub["hook_".Length..],
                        Json.Str(o["hook_name"]) ?? "", Json.Str(o["hook_event"]) ?? "", Json.Str(o["output"]),
                        o["exit_code"] is null ? null : (int)Json.Long(o["exit_code"]), Json.Str(o["outcome"])),
                    "permission_denied" => new PermissionDeniedEvent(Json.Str(o["tool_name"]) ?? "",
                        Json.Str(o["tool_use_id"]), Json.Str(o["message"])),
                    "compact_boundary" => new CompactBoundaryEvent(Json.Str(o["compact_metadata"]?["trigger"]),
                        Json.Long(o["compact_metadata"]?["pre_tokens"]), Json.Long(o["compact_metadata"]?["post_tokens"])),
                    "thinking_tokens" => new ThinkingTokensEvent(Json.Long(o["estimated_tokens"])),
                    "informational" => new InformationalEvent(Json.Str(o["content"]), Json.Str(o["level"])),
                    "commands_changed" => new CommandsChangedEvent(),
                    _ => new UnknownEvent(type, sub),
                };
            case "stream_event":
                return ParseStream(o["event"] as JsonObject, parent);
            case "assistant":
            {
                var m = o["message"];
                return new AssistantEvent(Json.Str(m?["id"]) ?? "", Json.Str(m?["model"]),
                    m?["content"] as JsonArray ?? [], TokenUsage.From(m?["usage"]), parent);
            }
            case "user":
                return new UserEvent(o["message"]?["content"], parent);
            case "result":
                return new ResultEvent(sub ?? "", Json.Bool(o["is_error"]), Json.Str(o["result"]),
                    (int)Json.Long(o["num_turns"]), TokenUsage.From(o["usage"]), Json.Double(o["total_cost_usd"]),
                    Json.Long(o["duration_ms"]), Json.Str(o["terminal_reason"]));
            case "rate_limit_event":
            {
                var info = o["rate_limit_info"];
                var windows = info?["unifiedWindows"];
                return new RateLimitEvent(Json.Str(info?["status"]), Window(windows?["five_hour"]), Window(windows?["seven_day"]));
            }
            case "control_request":
                return ParseControlRequest(Json.Str(o["request_id"]) ?? "", o["request"] as JsonObject);
            case "control_response":
            {
                var r = o["response"];
                return new ControlResponseEvent(Json.Str(r?["request_id"]) ?? "", Json.Str(r?["subtype"]) == "success",
                    r?["response"] as JsonObject, Json.Str(r?["error"]));
            }
            default:
                return new UnknownEvent(type, sub);
        }
    }

    static ClaudeEvent ParseStream(JsonObject? ev, string? parent)
    {
        var t = Json.Str(ev?["type"]);
        var index = (int)Json.Long(ev?["index"]);
        switch (t)
        {
            case "message_start":
            {
                var m = ev!["message"];
                return new MessageStartEvent(Json.Str(m?["id"]) ?? "", Json.Str(m?["model"]), TokenUsage.From(m?["usage"]), parent);
            }
            case "content_block_start":
            {
                var b = ev!["content_block"];
                return new BlockStartEvent(index, Json.Str(b?["type"]) ?? "", Json.Str(b?["name"]), Json.Str(b?["id"]), parent);
            }
            case "content_block_delta":
            {
                var d = ev!["delta"];
                var (kind, field) = Json.Str(d?["type"]) switch
                {
                    "text_delta" => (DeltaKind.Text, "text"),
                    "thinking_delta" => (DeltaKind.Thinking, "thinking"),
                    "input_json_delta" => (DeltaKind.InputJson, "partial_json"),
                    "signature_delta" => (DeltaKind.Signature, "signature"),
                    _ => (DeltaKind.Other, "type"),
                };
                return new DeltaEvent(index, kind, Json.Str(d?[field]) ?? "", parent);
            }
            case "content_block_stop":
                return new BlockStopEvent(index, parent);
            case "message_delta":
                return new MessageDeltaEvent(Json.Str(ev!["delta"]?["stop_reason"]), TokenUsage.From(ev["usage"]), parent);
            case "message_stop":
                return new MessageStopEvent(parent);
            default:
                return new UnknownEvent("stream_event", t);
        }
    }

    static ClaudeEvent ParseControlRequest(string requestId, JsonObject? r)
    {
        var sub = Json.Str(r?["subtype"]);
        if (sub != "can_use_tool" || r is null) return new UnhandledControlRequest(requestId, sub);
        var tool = Json.Str(r["tool_name"]) ?? "";
        var input = r["input"] as JsonObject ?? [];
        var toolUseId = Json.Str(r["tool_use_id"]);
        if (tool == "AskUserQuestion")
        {
            var questions = (input["questions"] as JsonArray ?? []).OfType<JsonObject>().Select(q => new Question(
                Json.Str(q["question"]) ?? "", Json.Str(q["header"]), Json.Bool(q["multiSelect"]),
                (q["options"] as JsonArray ?? []).OfType<JsonObject>()
                    .Select(x => new QuestionOption(Json.Str(x["label"]) ?? "", Json.Str(x["description"]))).ToList())).ToList();
            return new QuestionRequest(requestId, toolUseId, input, questions);
        }
        return new PermissionRequest(requestId, tool, input, Json.Str(r["description"]), toolUseId,
            r["permission_suggestions"] as JsonArray);
    }

    static RateWindow? Window(JsonNode? w) => w is JsonObject
        ? new RateWindow(Json.Double(w["utilization"]), DateTimeOffset.FromUnixTimeSeconds(Json.Long(w["resetsAt"])))
        : null;
}

/// <summary>Lenient readers: a missing or mistyped field is null / 0 / false, never an exception.</summary>
internal static class Json
{
    public static string? Str(JsonNode? n) => n is JsonValue v && v.TryGetValue(out string? s) ? s : null;

    public static long Long(JsonNode? n) => n is JsonValue v
        ? v.TryGetValue(out long l) ? l : v.TryGetValue(out double d) ? (long)d : 0
        : 0;

    public static double Double(JsonNode? n) => n is JsonValue v && v.TryGetValue(out double d) ? d : 0;

    public static bool Bool(JsonNode? n) => n is JsonValue v && v.TryGetValue(out bool b) && b;

    public static IReadOnlyList<string> Strings(JsonNode? n) =>
        n is JsonArray a ? a.Select(Str).OfType<string>().ToList() : [];
}
