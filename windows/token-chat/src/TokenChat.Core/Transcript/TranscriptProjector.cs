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
    readonly List<OpenBlock> _open = []; // ▶ blocks the user has not replied past
    readonly List<TranscriptItem> _prompts = []; // permission and question cards of the running turn
    readonly List<ToolUseItem> _unpriced = []; // results since the last main-chain request, waiting for the next one's growth
    ToolUseItem? _unplaced; // a shell call whose input is still streaming: only that says whether it folds
    long? _lastPrompt;
    long _lastOutput;
    bool _interrupted; // the running turn saw the CLI's interrupt marker
    bool _renewal; // the running turn is a poke's renewal: every row it adds, its own message to its summary, is IsRenewal

    public TranscriptProjector() => Items.CollectionChanged += (_, e) =>
    {
        if (_renewal && e.NewItems is { } added) foreach (TranscriptItem item in added) item.IsRenewal = true;
    };

    public ObservableCollection<TranscriptItem> Items { get; } = [];

    /// <summary>Every tool row, folded or not.</summary>
    public IEnumerable<ToolUseItem> Tools => _tools.Values;

    /// <summary>The session's directory, from its init event; tool rows show paths relative to it.</summary>
    public string? Cwd { get; set; }

    /// <summary>A file's text, or null if there is none; Write previews diff against it. Unset: every Write is a new file.</summary>
    public Func<string, string?>? ReadFile { get; init; }

    /// <summary>Any message answers the ▶ asks before it, so their buttons close. renewal: a poke's, dimmed to its turn's end.</summary>
    public void AddUser(string text, IReadOnlyList<string>? files = null, bool renewal = false)
    {
        _renewal = renewal;
        foreach (var b in _open) b.IsClosed = true;
        _open.Clear();
        _unpriced.Clear(); // the next request's growth is mostly this message
        Items.Add(new UserItem(text, files));
    }

    public void AddNote(NoteKind kind, string text, string? detail = null) => Items.Add(new NoteItem(kind, text, detail));

    public void Apply(ClaudeEvent e)
    {
        switch (e)
        {
            case InitEvent i: Cwd = i.Cwd; break;
            case MessageStartEvent { ParentToolUseId: null } m: _blocks.Clear(); Price(m.Usage); break;
            case MessageDeltaEvent { ParentToolUseId: null } d: _lastOutput = Math.Max(_lastOutput, d.Usage.Output); break;
            case BlockStartEvent { ParentToolUseId: null } b: StartBlock(b); break;
            case DeltaEvent { ParentToolUseId: null } d when _blocks.TryGetValue(d.Index, out var row): Append(row, d); break;
            case BlockStopEvent { ParentToolUseId: null } s when _blocks.TryGetValue(s.Index, out var row): StopBlock(row); break;
            case UserEvent { ParentToolUseId: null } u: ApplyUser(u.Content); break;
            case ResultEvent r: EndTurn(r); break;
            case PermissionRequest p: AddPrompt(NewPermission(p)); break;
            case QuestionRequest q: AddPrompt(new QuestionItem(q)); break;
            case PromptCancelledEvent c: CancelPrompts(c.RequestId); break;
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
        PlaceUnplaced();
        _blocks[b.Index] = row;
        if (row is not ToolUseItem tool)
        {
            Items.Add(row);
            return;
        }
        if (tool.ToolUseId is { } id) _tools[id] = tool;
        if (ToolText.NeedsInput(tool.ToolName)) _unplaced = tool;
        else Place(tool, ToolText.IsLook(tool.ToolName, null));
    }

    /// <summary>A call that only looks joins the run of them just before it, taking the thinking before it along. A lone
    /// one stays a plain row until a second arrives; then both fold into a run, captioned by the thinking before it, or
    /// by its shape alone when reply text right above it already says why. Any other call goes on the transcript as is.</summary>
    void Place(ToolUseItem tool, bool looks)
    {
        tool.Looks = looks;
        var thought = looks && Items.Count > 0 ? Items[^1] as ThinkingItem : null;
        var before = Items.Count - (thought is null ? 1 : 2);
        var prev = looks && before >= 0 ? Items[before] : null;
        if (prev is ToolUseItem { Looks: true } lone)
        {
            var run = new ToolGroupItem();
            var first = before;
            if (first > 0 && Items[first - 1] is ThinkingItem led)
            {
                first--;
                run.Add(led);
                run.Caption = ToolText.Intent(led.Text);
            }
            run.Add(lone);
            run.Narrated = first > 0 && Items[first - 1] is AssistantTextItem said && said.Text.Trim().Length > 0;
            if (first < before) Items.RemoveAt(before);
            Items[first] = run;
            prev = run;
        }
        if (prev is not ToolGroupItem group)
        {
            Items.Add(tool);
            return;
        }
        if (thought is not null)
        {
            Items.RemoveAt(Items.Count - 1);
            group.Add(thought);
            group.Caption ??= ToolText.Intent(thought.Text);
        }
        group.Add(tool);
    }

    void PlaceUnplaced()
    {
        if (_unplaced is not { } tool) return;
        _unplaced = null;
        Place(tool, ToolText.IsLook(tool.ToolName, tool.Input));
    }

    /// <summary>A main-chain request's prompt is the last one's prompt, plus its output, plus what landed in between: in
    /// a tool loop, the results (with anything the CLI attached to them). Checked on this repo's transcripts
    /// (2026-10-02): growth tracks result size at a steady 2.0-2.6 chars/token. One result takes the growth as
    /// measured; a parallel batch splits it by result size.</summary>
    void Price(TokenUsage usage)
    {
        if (usage.Prompt == 0) return;
        var growth = usage.Prompt - (_lastPrompt ?? 0) - _lastOutput;
        if (_lastPrompt is not null && _unpriced.Count > 0 && growth > 0)
        {
            var chars = _unpriced.Sum(t => (long)Math.Max(1, t.ResultChars));
            foreach (var t in _unpriced)
            {
                t.Tokens = growth * Math.Max(1, t.ResultChars) / chars;
                t.TokensExact = _unpriced.Count == 1;
            }
        }
        _unpriced.Clear();
        _lastPrompt = usage.Prompt;
        _lastOutput = usage.Output;
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
                EndStream(s);
                if (s is ThinkingItem && s.Text.Trim().Length == 0) Items.Remove(s); // redacted: a row with nothing in it
                break;
            case ToolUseItem t:
                var json = t.InputJson.ToString();
                t.Input = Parse(json);
                t.Summary = t.Input is { } input ? Summarize(input) : OneLine(json, 160);
                t.Line = ToolText.Describe(t.ToolName, t.Input, Cwd);
                if (t == _unplaced) PlaceUnplaced();
                break;
        }
    }

    void EndStream(StreamedItem s)
    {
        s.IsStreaming = false;
        if (s is AssistantTextItem { Open: null } a && OpenBlock.Parse(a.Text) is { } block)
        {
            a.Open = block;
            _open.Add(block);
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
                        tool.IsError = block["is_error"] is JsonValue e && e.TryGetValue<bool>(out var isError) && isError;
                        tool.Outcome = ToolText.Outcome(tool.ToolName, tool.Input, result, tool.IsError);
                        tool.ResultChars = result.Length;
                        tool.TokensExact = false;
                        tool.Tokens = ToolText.Estimate(result.Length);
                        _unpriced.Add(tool);
                        tool.Result = result.Length <= ResultPreviewChars ? result : result[..ResultPreviewChars] + "…";
                        tool.IsInterrupted = false;
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
        _unpriced.Clear(); // it lands in the window beside the results
        if (text.StartsWith("[Request interrupted", StringComparison.Ordinal))
        {
            _interrupted = true;
            AddNote(NoteKind.Warning, "Interrupted");
        }
        else if (text.StartsWith(stdout, StringComparison.Ordinal))
            AddNote(NoteKind.Command, text[stdout.Length..].Replace("</local-command-stdout>", "").Trim());
        else
            AddNote(NoteKind.Info, OneLine(text, 120), text);
    }

    void EndTurn(ResultEvent r)
    {
        PlaceUnplaced();
        _unpriced.Clear();
        foreach (var row in _blocks.Values.OfType<StreamedItem>())
        {
            row.Flush();
            if (row.IsStreaming) EndStream(row);
        }
        _dirty.Clear();
        _blocks.Clear();
        // a main-chain tool's result always lands before its turn's result, unless the turn was stopped
        foreach (var t in _tools.Values)
            if (t.Result is null) t.IsInterrupted = true;
        CancelPrompts(null);
        var stopped = _interrupted || r.TerminalReason?.StartsWith("aborted", StringComparison.Ordinal) == true;
        _interrupted = false;
        Items.Add(new TurnItem(r) { IsStopped = stopped });
        _renewal = false;
    }

    void AddPrompt(TranscriptItem card)
    {
        _prompts.Add(card);
        Items.Add(card);
    }

    /// <summary>Cards still pending lose their buttons: one by request id, or all of them (null) at the end of a turn.</summary>
    void CancelPrompts(string? requestId)
    {
        foreach (var card in _prompts)
        {
            if (card is PermissionItem { State: PermissionState.Pending } p && (requestId is null || p.Request.RequestId == requestId))
                p.State = PermissionState.Cancelled;
            else if (card is QuestionItem { State: QuestionState.Pending } q && (requestId is null || q.Request.RequestId == requestId))
                q.State = QuestionState.Cancelled;
        }
        if (requestId is null) _prompts.Clear();
    }

    PermissionItem NewPermission(PermissionRequest p)
    {
        var session = PermissionRules.ForSession(p.Suggestions);
        var (diff, note) = Preview(p.ToolName, p.Input);
        return new(p, Summarize(p.Input)) { Diff = diff, DiffNote = note, SessionRules = session?.Rules, SessionLabel = session?.Label };
    }

    (List<DiffLine>?, string?) Preview(string tool, JsonObject input)
    {
        switch (tool)
        {
            case "Edit" when Json.Str(input["old_string"]) is { } before && Json.Str(input["new_string"]) is { } after:
                return (LineDiff.Compute(before, after), Json.Bool(input["replace_all"]) ? "every occurrence" : null);
            case "MultiEdit" when input["edits"] is JsonArray edits:
                var rows = new List<DiffLine>();
                foreach (var e in edits.OfType<JsonObject>())
                {
                    if (rows.Count > 0) rows.Add(new(DiffKind.Gap, "⋯"));
                    rows.AddRange(LineDiff.Compute(Json.Str(e["old_string"]) ?? "", Json.Str(e["new_string"]) ?? ""));
                }
                return (rows, $"{edits.Count} edits");
            case "Write" when Json.Str(input["content"]) is { } content:
                var old = Json.Str(input["file_path"]) is { } path ? ReadFile?.Invoke(path) : null;
                return (LineDiff.Compute(old ?? "", content), old is null ? "new file" : "overwrites the file");
        }
        return (null, null);
    }

    static string ResultText(JsonNode? content) => content switch
    {
        JsonValue v when v.TryGetValue<string>(out var s) => s,
        JsonArray a => string.Join("\n", a.OfType<JsonObject>().Select(b => (string?)b["text"]).OfType<string>()),
        _ => "",
    };

    /// <summary>One line naming what a tool call touches: the command, path or pattern if there is one.</summary>
    public static string Summarize(string inputJson) => Parse(inputJson) is { } o ? Summarize(o) : OneLine(inputJson, 160);

    static JsonObject? Parse(string json)
    {
        try
        {
            return JsonNode.Parse(json) as JsonObject;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public static string Summarize(JsonObject input)
    {
        if (input["questions"] is JsonArray { Count: > 0 } questions && questions[0] is JsonObject first
            && Json.Str(first["question"]) is { Length: > 0 } question)
            return OneLine(question, 160); // AskUserQuestion
        foreach (var key in SummaryKeys)
            if (input[key] is JsonValue v && v.TryGetValue<string>(out var s) && s.Length > 0) return OneLine(s, 160);
        return OneLine(input.ToJsonString(), 160);
    }

    internal static string OneLine(string s, int max)
    {
        var line = s.ReplaceLineEndings(" ").Trim();
        return line.Length <= max ? line : line[..max] + "…";
    }
}
