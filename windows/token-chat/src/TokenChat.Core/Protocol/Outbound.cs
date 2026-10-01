using System.Text.Json.Nodes;

namespace TokenChat.Core.Protocol;

/// <summary>Lines written to claude.exe stdin. Each returns one JSON object without a newline.</summary>
public static class Outbound
{
    /// <summary>Must precede the first user message: without it permissions are auto-denied,
    /// AskUserQuestion is missing and turn 2 rewrites the message tier (docs/token-chat-spike.md).</summary>
    public static string Initialize(string requestId) =>
        ControlRequest(requestId, new JsonObject { ["subtype"] = "initialize", ["hooks"] = null });

    public static string Interrupt(string requestId) =>
        ControlRequest(requestId, new JsonObject { ["subtype"] = "interrupt" });

    public static string SetPermissionMode(string requestId, string mode) =>
        ControlRequest(requestId, new JsonObject { ["subtype"] = "set_permission_mode", ["mode"] = mode });

    public static string UserText(string text) => User(JsonValue.Create(text));

    /// <summary>content is a string or an array of content blocks (text, image, document).</summary>
    public static string User(JsonNode content) => new JsonObject
    {
        ["type"] = "user",
        ["message"] = new JsonObject { ["role"] = "user", ["content"] = content },
        ["parent_tool_use_id"] = null,
    }.ToJsonString();

    public static JsonObject TextBlock(string text) => new() { ["type"] = "text", ["text"] = text };

    public static JsonObject ImageBlock(string mediaType, byte[] data) => new()
    {
        ["type"] = "image",
        ["source"] = new JsonObject { ["type"] = "base64", ["media_type"] = mediaType, ["data"] = Convert.ToBase64String(data) },
    };

    /// <summary>updatedPermissions: permission updates applied with the allow, e.g. <see cref="PermissionRules.ForSession"/>.</summary>
    public static string Allow(string requestId, JsonObject updatedInput, JsonArray? updatedPermissions = null)
    {
        var r = new JsonObject { ["behavior"] = "allow", ["updatedInput"] = updatedInput.DeepClone() };
        if (updatedPermissions is { Count: > 0 }) r["updatedPermissions"] = updatedPermissions.DeepClone();
        return ControlSuccess(requestId, r);
    }

    public static string Deny(string requestId, string message) =>
        ControlSuccess(requestId, new JsonObject { ["behavior"] = "deny", ["message"] = message });

    /// <summary>answers maps question text to the chosen option label.</summary>
    public static string Answer(QuestionRequest q, IReadOnlyDictionary<string, string> answers)
    {
        var input = (JsonObject)q.Input.DeepClone();
        var a = new JsonObject();
        foreach (var (question, label) in answers) a[question] = label;
        input["answers"] = a;
        return Allow(q.RequestId, input);
    }

    public static string ControlError(string requestId, string error) => new JsonObject
    {
        ["type"] = "control_response",
        ["response"] = new JsonObject { ["subtype"] = "error", ["request_id"] = requestId, ["error"] = error },
    }.ToJsonString();

    static string ControlRequest(string requestId, JsonObject request) => new JsonObject
    {
        ["type"] = "control_request", ["request_id"] = requestId, ["request"] = request,
    }.ToJsonString();

    static string ControlSuccess(string requestId, JsonObject response) => new JsonObject
    {
        ["type"] = "control_response",
        ["response"] = new JsonObject { ["subtype"] = "success", ["request_id"] = requestId, ["response"] = response },
    }.ToJsonString();
}
