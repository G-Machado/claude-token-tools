using System.Collections.ObjectModel;
using System.Text.Json;
using System.Text.Json.Nodes;
using TokenChat.Core.Protocol;

namespace TokenChat.Core.Transcript;

/// <summary>Folds session events into transcript rows. Main chain only: subagent traffic
/// (ParentToolUseId set) is skipped. Not thread-safe; feed it from the thread that owns <see cref="Items"/>.</summary>
public sealed class TranscriptProjector
{
    const int ResultPreviewChars = 600;
    static readonly string[] SummaryKeys = ["command", "file_path", "pattern", "path", "url", "query", "description", "prompt"];

    readonly Dictionary<int, TranscriptItem> _blocks = []; // content block index → row, current message
    readonly Dictionary<string, ToolUseItem> _tools = [];
    readonly HashSet<StreamedItem> _dirty = [];

    public ObservableCollection<TranscriptItem> Items { get; } = [];

    public void AddUser(string text) => Items.Add(new UserItem(text));

    public void AddNote(NoteKind kind, string text, string? detail = null) => Items.Add(new NoteItem(kind, text, detail));

    public void Apply(ClaudeEvent e)
    {
        switch (e)
        {
            case MessageStartEvent { ParentToolUseId: null }: _blocks.Clear(); break;
            case BlockStartEvent { ParentToolUseId: null } b: StartBlock(b); break;
            case DeltaEvent { ParentToolUseId: null } d when _blocks.TryGetValue(d.Index, out var row): Append(row, d); break;
            case BlockStopEvent { ParentToolUseId: null } s when _blocks.TryGetValue(s.Index, out var row): StopBlock(row); break;
            case UserEvent { ParentToolUseId: null } u: ApplyUser(u.Content); break;
            case ResultEvent r: EndTurn(r); break;
            case PermissionRequest p: Items.Add(new PermissionItem(p, Summarize(p.Input))); break;
            case PermissionDeniedEvent d: AddNote(NoteKind.Warning, $"{d.ToolName} denied", d.Message); break;
            case CompactBoundaryEvent c: AddNote(NoteKind.Compact, $"Compacted ({c.Trigger}): {Tokens.K(c.PreTokens)} → {Tokens.K(c.PostTokens)}"); break;
            case InformationalEvent { Content: { Length: > 0 } text } i: AddNote(i.Level == "error" ? NoteKind.Error : NoteKind.Info, text); break;
        }
    }

    /// <summary>Publishes buffered deltas. Call at the render rate (~10 Hz), not per event.</summary>
    public void Flush()
    {
        foreach (var row in _dirty) row.Flush();
        _dirty.Clear();
    }

    void StartBlock(BlockStartEvent b)
    {
        TranscriptItem? row = b.BlockType switch
        {
            "text" => new AssistantTextItem(),
            "thinking" => new ThinkingItem(),
            "tool_use" => new ToolUseItem(b.ToolName ?? "?", b.ToolUseId),
            _ => null,
        };
        if (row is null) return;
        if (row is ToolUseItem { ToolUseId: { } id } tool) _tools[id] = tool;
        _blocks[b.Index] = row;
        Items.Add(row);
    }

    void Append(TranscriptItem row, DeltaEvent d)
    {
        if (row is AssistantTextItem && d.Kind == DeltaKind.Text || row is ThinkingItem && d.Kind == DeltaKind.Thinking)
        {
            var s = (StreamedItem)row;
            s.Append(d.Text);
            _dirty.Add(s);
        }
        else if (row is ToolUseItem t && d.Kind == DeltaKind.InputJson)
        {
            t.InputJson.Append(d.Text);
        }
    }

    void StopBlock(TranscriptItem row)
    {
        switch (row)
        {
            case StreamedItem s:
                s.Flush();
                _dirty.Remove(s);
                s.IsStreaming = false;
                break;
            case ToolUseItem t:
                t.Summary = Summarize(t.InputJson.ToString());
                break;
        }
    }

    void ApplyUser(JsonNode? content)
    {
        switch (content)
        {
            case JsonValue v when v.TryGetValue<string>(out var text):
                AddUserText(text);
                break;
            case JsonArray blocks:
                foreach (var block in blocks.OfType<JsonObject>())
                {
                    var type = (string?)block["type"];
                    if (type == "tool_result" && (string?)block["tool_use_id"] is { } id && _tools.TryGetValue(id, out var tool))
                    {
                        var result = ResultText(block["content"]);
                        tool.ResultLines = result.Length == 0 ? 0 : result.Split('\n').Length;
                        tool.Result = result.Length <= ResultPreviewChars ? result : result[..ResultPreviewChars] + "…";
                        tool.IsError = block["is_error"] is JsonValue e && e.TryGetValue<bool>(out var isError) && isError;
                    }
                    else if (type == "text" && (string?)block["text"] is { Length: > 0 } t)
                    {
                        AddUserText(t);
                    }
                }
                break;
        }
    }

    /// <summary>Text the CLI injects as the user: interrupt markers, slash command output, compact summaries.</summary>
    void AddUserText(string text)
    {
        const string stdout = "<local-command-stdout>";
        if (text.StartsWith("[Request interrupted", StringComparison.Ordinal))
            AddNote(NoteKind.Warning, "Interrupted");
        else if (text.StartsWith(stdout, StringComparison.Ordinal))
            AddNote(NoteKind.Command, text[stdout.Length..].Replace("</local-command-stdout>", "").Trim());
        else
            AddNote(NoteKind.Info, OneLine(text, 120), text);
    }

    void EndTurn(ResultEvent r)
    {
        foreach (var row in _blocks.Values.OfType<StreamedItem>())
        {
            row.Flush();
            row.IsStreaming = false;
        }
        _dirty.Clear();
        _blocks.Clear();
        Items.Add(new TurnItem(r));
    }

    static string ResultText(JsonNode? content) => content switch
    {
        JsonValue v when v.TryGetValue<string>(out var s) => s,
        JsonArray a => string.Join("\n", a.OfType<JsonObject>().Select(b => (string?)b["text"]).OfType<string>()),
        _ => "",
    };

    /// <summary>One line naming what a tool call touches: the command, path or pattern if there is one.</summary>
    public static string Summarize(string inputJson)
    {
        try
        {
            if (JsonNode.Parse(inputJson) is JsonObject o) return Summarize(o);
        }
        catch (JsonException) { }
        return OneLine(inputJson, 160);
    }

    public static string Summarize(JsonObject input)
    {
        foreach (var key in SummaryKeys)
            if (input[key] is JsonValue v && v.TryGetValue<string>(out var s) && s.Length > 0) return OneLine(s, 160);
        return OneLine(input.ToJsonString(), 160);
    }

    static string OneLine(string s, int max)
    {
        var line = s.ReplaceLineEndings(" ").Trim();
        return line.Length <= max ? line : line[..max] + "…";
    }
}
