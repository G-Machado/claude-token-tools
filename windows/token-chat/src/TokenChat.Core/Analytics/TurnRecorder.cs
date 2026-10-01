using TokenChat.Core.Protocol;

namespace TokenChat.Core.Analytics;

/// <summary>One result, measured by every source the stream offers. Raw quantities only; the tab classifies.</summary>
/// <param name="Reported">result.usage: the CLI's own sum over the turn, zero after an interrupt</param>
/// <param name="Ledger">deduplicated stream usage over the turn, subagents included</param>
/// <param name="Main">the main chain alone: what a transcript cycle counts</param>
/// <param name="MainMessages">main-chain message ids in order: what pairs the turn with its transcript cycle</param>
/// <param name="Requests">distinct requests seen on the stream, subagents included</param>
/// <param name="CostUsd">Δ total_cost_usd: the CLI's price of the turn</param>
/// <param name="Models">Δ modelUsage per model; side requests the stream never shows land here and in CostUsd only</param>
public sealed record TurnRecord(int Index, string Subtype, int NumTurns, TokenUsage Reported, TokenUsage Ledger,
    TokenUsage Main, IReadOnlyList<string> MainMessages, int Requests, double CostUsd,
    IReadOnlyDictionary<string, ModelUsage> Models)
{
    public TokenUsage ModelTokens => Models.Values.Aggregate(default(TokenUsage), (sum, m) => sum + m.Tokens);
}

/// <summary>A turn beside the transcript cycle holding its first main-chain request; Cycle is null when the turn
/// made no request or the transcript has not caught up.</summary>
public sealed record TurnMatch(TurnRecord Turn, CycleStats? Cycle)
{
    /// <summary>Transcript minus stream, main chain only.</summary>
    public TokenUsage Diff => (Cycle?.Usage ?? default) - Turn.Main;

    public bool SameRequests => Cycle is not null && Cycle.MessageIds.SequenceEqual(Turn.MainMessages);
}

/// <summary>One <see cref="TurnRecord"/> per result. One recorder per claude.exe process: total_cost_usd and
/// modelUsage are cumulative per process, so the deltas assume the counters never restart.</summary>
public sealed class TurnRecorder
{
    readonly HashSet<string> _seen = [];
    readonly List<string> _main = [];
    int _requests;
    double _cost;
    IReadOnlyDictionary<string, ModelUsage> _models = new Dictionary<string, ModelUsage>();

    public UsageLedger Ledger { get; } = new();

    /// <summary>Swapped whole, so another thread never reads a half-appended list.</summary>
    public IReadOnlyList<TurnRecord> Turns { get; private set; } = [];

    public void Apply(ClaudeEvent e)
    {
        Ledger.Apply(e);
        switch (e)
        {
            case MessageStartEvent m:
                Track(m.MessageId, m.ParentToolUseId);
                break;
            // A local command's reply ("/context isn't available...") is written by the CLI, not requested.
            case AssistantEvent { Model: not "<synthetic>" } a:
                Track(a.MessageId, a.ParentToolUseId);
                break;
            case ResultEvent r:
                Close(r);
                break;
        }
    }

    void Track(string messageId, string? parentToolUseId)
    {
        if (messageId.Length == 0 || !_seen.Add(messageId)) return;
        _requests++;
        if (parentToolUseId is null) _main.Add(messageId);
    }

    void Close(ResultEvent r)
    {
        var models = r.ModelUsage.ToDictionary(kv => kv.Key,
            kv => _models.TryGetValue(kv.Key, out var old) ? kv.Value - old : kv.Value);
        var main = _main.Aggregate(default(TokenUsage), (sum, id) => sum + Ledger.Message(id));
        Turns = [.. Turns, new TurnRecord(Turns.Count + 1, r.Subtype, r.NumTurns, r.Usage, Ledger.Snapshot.LastTurn,
            main, [.. _main], _requests, r.TotalCostUsd - _cost, models)];
        _cost = r.TotalCostUsd;
        _models = r.ModelUsage;
        _main.Clear();
        _requests = 0;
    }

    /// <summary>Pairs each turn with its transcript cycle by message id, never by position: a turn without a request
    /// (a local command) may or may not leave a cycle behind.</summary>
    public static IReadOnlyList<TurnMatch> Match(IReadOnlyList<TurnRecord> turns, IReadOnlyList<CycleStats> cycles)
    {
        var byMessage = new Dictionary<string, CycleStats>();
        foreach (var c in cycles)
            foreach (var id in c.MessageIds) byMessage.TryAdd(id, c);
        return turns.Select(t => new TurnMatch(t,
            t.MainMessages.Count > 0 && byMessage.TryGetValue(t.MainMessages[0], out var c) ? c : null)).ToList();
    }
}
