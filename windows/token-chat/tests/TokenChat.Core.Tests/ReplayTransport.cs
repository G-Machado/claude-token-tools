using System.Runtime.CompilerServices;
using System.Text.Json.Nodes;
using System.Threading.Channels;
using TokenChat.Core;

namespace TokenChat.Core.Tests;

/// <summary>Replays recorded stdout. A recorded control_response is held until the session sends a
/// control_request, then released under the live request id; everything else streams straight through.</summary>
sealed class ReplayTransport(IEnumerable<string> lines) : IClaudeTransport
{
    readonly Channel<string> _requestIds = Channel.CreateUnbounded<string>();
    readonly List<JsonObject> _sent = [];

    public IReadOnlyList<JsonObject> Sent { get { lock (_sent) return [.. _sent]; } }

    public static ReplayTransport FromFixture(string name) => new(Fixture.Lines(name));

    public async IAsyncEnumerable<string> ReadLinesAsync([EnumeratorCancellation] CancellationToken ct)
    {
        foreach (var line in lines)
        {
            var o = JsonNode.Parse(line)!.AsObject();
            if ((string?)o["type"] == "control_response")
            {
                o["response"]!["request_id"] = await _requestIds.Reader.ReadAsync(ct);
                yield return o.ToJsonString();
            }
            else yield return line;
        }
    }

    public Task WriteLineAsync(string line, CancellationToken ct)
    {
        Assert.DoesNotContain('\n', line);
        var o = JsonNode.Parse(line)!.AsObject();
        lock (_sent) _sent.Add(o);
        if ((string?)o["type"] == "control_request") _requestIds.Writer.TryWrite((string)o["request_id"]!);
        return Task.CompletedTask;
    }

    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}

static class Fixture
{
    public static readonly TheoryData<string> All = new("full", "noskills", "perm", "slim", "tools");

    public static IReadOnlyList<string> Lines(string name)
    {
        var lines = File.ReadAllLines(Path.Combine(AppContext.BaseDirectory, "Fixtures", name + ".jsonl"))
            .Where(l => l.Length > 0).ToList();
        Assert.NotEmpty(lines);
        return lines;
    }
}
