using System.Text.Json;
using System.Text.Json.Nodes;
using TokenChat.Core.Protocol;

namespace TokenChat.Core.Analytics;

/// <summary>One prompt cycle: a typed message plus every request until control returns to the user.</summary>
/// <param name="Usage">sum over the cycle's deduplicated main-chain requests; every request pays its own cache read</param>
/// <param name="Context">prompt of the cycle's last request: window occupancy when the cycle ended</param>
/// <param name="Growth">context delta from the previous cycle, never negative; on cycle 1 the cold load</param>
/// <param name="Churn">cache write that is not growth: context that was already there, rewritten</param>
public sealed record CycleStats(int Index, string PromptId, TokenUsage Usage, long Context, long Growth, long Churn,
    int Requests);

/// <summary>Port of the cycle parser in ~/.claude/token-cycles.sh, so a terminal transcript and a TokenChat one are
/// scored by the same rules as the CLAUDE.md budgets. Keep the two in step: a change here is a change there.</summary>
public static class TranscriptCycles
{
    public static IReadOnlyList<CycleStats> Read(string path)
    {
        // The CLI may be appending to it right now.
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var reader = new StreamReader(stream);
        var lines = new List<string>();
        while (reader.ReadLine() is { } line) lines.Add(line);
        return Parse(lines);
    }

    public static IReadOnlyList<CycleStats> Parse(IEnumerable<string> lines)
    {
        var cycles = new List<Cycle>();
        var seen = new HashSet<string>();
        string? last = null;
        var n = 0;
        foreach (var line in lines)
        {
            n++;
            // The script's own gates, so a line it never looks at is never parsed here either.
            if (!line.Contains("\"promptId\"") && !line.Contains("\"output_tokens\"")) continue;
            JsonNode? o;
            try { o = JsonNode.Parse(line); }
            catch (JsonException) { continue; } // the last line, still being written

            // promptId repeats on every user line of a cycle (tool results too), so a new cycle is a change in it.
            if (Json.Str(o?["type"]) == "user")
            {
                var pid = Json.Str(o?["promptId"]);
                if (pid is not null && pid != last) { cycles.Add(new Cycle(pid)); last = pid; }
                continue;
            }

            // The same usage is written once per content block; the first sighting already carries the final count.
            var message = o?["message"];
            if (message?["usage"] is not JsonObject usage || Json.Bool(o?["isSidechain"])) continue;
            if (!seen.Add(Json.Str(message["id"]) ?? $"L{n}")) continue;
            if (cycles.Count > 0) cycles[^1].Add(TokenUsage.From(usage)); // before the first prompt: not a cycle
        }

        var stats = new List<CycleStats>(cycles.Count);
        long previous = 0;
        foreach (var c in cycles)
        {
            // A cycle with no request (interrupted before any reply) left the window as it was: carry the previous
            // context forward, or the next cycle would count the whole window as growth.
            var context = c.Context > 0 ? c.Context : previous;
            var growth = Math.Max(0, context - previous);
            stats.Add(new CycleStats(stats.Count + 1, c.PromptId, c.Usage, context, growth,
                Math.Max(0, c.Usage.CacheWrite - growth), c.Requests));
            previous = context;
        }
        return stats;
    }

    sealed class Cycle(string promptId)
    {
        public string PromptId { get; } = promptId;
        public TokenUsage Usage { get; private set; }
        public long Context { get; private set; }
        public int Requests { get; private set; }

        public void Add(TokenUsage u)
        {
            Usage += u;
            Requests++;
            // Last request wins, never max: a compaction shrinks the window.
            if (u.Prompt > 0) Context = u.Prompt;
        }
    }
}
