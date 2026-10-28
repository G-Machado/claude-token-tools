using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;
using System.Text.Json.Nodes;
using TokenChat.Core.Transcript;

namespace TokenChat.Core.Remote;

/// <summary>One tab's transcript as JSON for the remote web page. <see cref="Snapshot"/> is the whole list;
/// <see cref="Flush"/> is what changed since the last call: the top-level rows that changed (a change inside a tool run
/// or a handed-off segment re-sends its row) and the row order when it moved. Ids are stable for the projection's life.
/// Lives on the thread that mutates the items (the UI's), like the items themselves.</summary>
public sealed class RemoteProjection : IDisposable
{
    readonly ObservableCollection<TranscriptItem> _items;
    readonly Dictionary<TranscriptItem, int> _ids = [];
    readonly Dictionary<int, TranscriptItem> _byId = [];
    readonly Dictionary<object, TranscriptItem> _top = [];
    readonly List<Action> _unhook = [];
    readonly HashSet<TranscriptItem> _dirty = [];
    bool _orderDirty;
    int _next;

    public RemoteProjection(ObservableCollection<TranscriptItem> items)
    {
        _items = items;
        Hook(items, null);
    }

    /// <summary>Any row by id, nested ones included: what an action from the page names.</summary>
    public TranscriptItem? Find(int id) => _byId.GetValueOrDefault(id);

    public JsonObject Snapshot()
    {
        _dirty.Clear();
        _orderDirty = false;
        return new JsonObject { ["type"] = "snapshot", ["items"] = new JsonArray([.. _items.Select(Dto)]) };
    }

    /// <summary>Null when nothing changed.</summary>
    public JsonObject? Flush()
    {
        if (_dirty.Count == 0 && !_orderDirty) return null;
        var patch = new JsonObject { ["type"] = "patch" };
        var rows = _dirty.Where(_items.Contains).Select(Dto).ToList();
        if (rows.Count > 0) patch["items"] = new JsonArray([.. rows]);
        if (_orderDirty) patch["order"] = new JsonArray([.. _items.Select(i => (JsonNode)Id(i))]);
        _dirty.Clear();
        _orderDirty = false;
        return patch;
    }

    public void Dispose()
    {
        foreach (var u in _unhook) u();
        _unhook.Clear();
    }

    int Id(TranscriptItem item)
    {
        if (_ids.TryGetValue(item, out var id)) return id;
        _ids[item] = id = ++_next;
        _byId[id] = item;
        return id;
    }

    /// <summary>Watch a collection: top-level when <paramref name="owner"/> is null, else a row's children.</summary>
    void Hook(ObservableCollection<TranscriptItem> list, TranscriptItem? owner)
    {
        NotifyCollectionChangedEventHandler h = (_, e) =>
        {
            foreach (var i in e.NewItems?.OfType<TranscriptItem>() ?? []) Watch(i, owner ?? i);
            if (owner is null) _orderDirty = true;
            else _dirty.Add(owner);
            foreach (var i in e.NewItems?.OfType<TranscriptItem>() ?? []) _dirty.Add(owner ?? i);
        };
        list.CollectionChanged += h;
        _unhook.Add(() => list.CollectionChanged -= h);
        foreach (var i in list) Watch(i, owner ?? i);
    }

    void Watch(TranscriptItem item, TranscriptItem top)
    {
        if (!_top.TryAdd(item, top)) return;
        Id(item);
        Bind(item, top);
        switch (item)
        {
            case ToolGroupItem g: Hook(g.Children, top); break;
            case SegmentItem s: Hook(s.Items, top); break;
            case QuestionItem q:
                foreach (var p in q.Questions) Bind(p, top);
                break;
        }
    }

    void Bind(INotifyPropertyChanged source, TranscriptItem top)
    {
        PropertyChangedEventHandler h = (_, _) => _dirty.Add(top);
        source.PropertyChanged += h;
        _unhook.Add(() => source.PropertyChanged -= h);
    }

    JsonObject Dto(TranscriptItem item)
    {
        var o = Body(item);
        o["id"] = Id(item);
        if (item.IsRenewal) o["renewal"] = true;
        return o;
    }

    JsonObject Body(TranscriptItem item) => item switch
    {
        UserItem u => new() { ["k"] = "user", ["text"] = u.Text, ["files"] = new JsonArray([.. u.Files.Select(f => (JsonNode)f)]) },
        AssistantTextItem a => new() { ["k"] = "text", ["text"] = a.Text, ["streaming"] = a.IsStreaming },
        ThinkingItem t => new() { ["k"] = "thinking", ["text"] = t.Text, ["streaming"] = t.IsStreaming },
        ToolUseItem t => new()
        {
            ["k"] = "tool", ["verb"] = t.Line.Verb, ["subject"] = t.Line.Subject, ["detail"] = t.Line.Detail,
            ["command"] = t.Line.Command, ["outcome"] = t.Outcome, ["tokens"] = t.TokensText, ["big"] = t.IsBig,
            ["result"] = t.Result, ["error"] = t.IsError, ["interrupted"] = t.IsInterrupted,
            ["running"] = t.Result is null && !t.IsInterrupted,
        },
        ToolGroupItem g => new()
        {
            ["k"] = "group", ["title"] = g.Title, ["aside"] = g.CountsAside, ["tokens"] = g.TokensText, ["big"] = g.IsBig,
            ["state"] = g.State, ["running"] = g.IsRunning, ["failed"] = g.HasFailed, ["children"] = Children(g.Children),
        },
        PermissionItem p => new()
        {
            ["k"] = "permission", ["tool"] = p.ToolName, ["summary"] = p.Summary, ["state"] = p.State.ToString(),
            ["diff"] = p.Diff is { } d ? new JsonArray([.. d.Select(l => (JsonNode)new JsonArray(l.Kind.ToString(), l.Text))]) : null,
            ["diffNote"] = p.DiffNote, ["sessionLabel"] = p.SessionRules is null ? null : p.SessionLabel ?? "allow for session",
        },
        QuestionItem q => new()
        {
            ["k"] = "question", ["state"] = q.State.ToString(), ["outcome"] = q.Outcome, ["relay"] = q.Relay,
            ["questions"] = new JsonArray([.. q.Questions.Select(p => (JsonNode)new JsonObject
            {
                ["text"] = p.Text, ["header"] = p.Header, ["multi"] = p.MultiSelect,
                ["options"] = new JsonArray([.. p.Options.Select(o => (JsonNode)new JsonObject
                {
                    ["label"] = o.Caption, ["description"] = o.Description, ["recommended"] = o.IsRecommended,
                })]),
            })]),
        },
        CardItem c => new()
        {
            ["k"] = "card", ["kind"] = c.Kind, ["title"] = c.Title, ["text"] = c.Text, ["outcome"] = c.Outcome,
            ["actions"] = new JsonArray([.. c.Actions.Select(a => (JsonNode)new JsonObject
                { ["label"] = a.Label, ["key"] = a.Key, ["primary"] = a.Primary })]),
        },
        SegmentItem s => new() { ["k"] = "segment", ["header"] = s.Header, ["children"] = Children(s.Items) },
        NoteItem n => new() { ["k"] = "note", ["kind"] = n.Kind.ToString(), ["text"] = n.Text, ["detail"] = n.Detail },
        TurnItem t => new() { ["k"] = "turn", ["summary"] = t.Summary, ["error"] = t.IsError, ["detail"] = t.Detail },
        _ => new() { ["k"] = "unknown", ["type"] = item.GetType().Name },
    };

    JsonArray Children(IEnumerable<TranscriptItem> items) => new([.. items.Select(Dto)]);
}
