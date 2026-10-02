using System.Runtime.CompilerServices;
using System.Text.Json.Nodes;
using System.Threading.Channels;

namespace TokenChat.Core;

/// <summary>Replays recorded stdout, for the tests and for TokenChat --preview. A recorded control_response is held until
/// the session sends a control_request, then released under the live request id; everything else streams straight
/// through. holdOpen keeps the stream open after the last line, so the session never sees claude exit.</summary>
public sealed class ReplayTransport(IEnumerable<string> lines, bool holdOpen = false) : IClaudeTransport
{
    readonly Channel<string> _requestIds = Channel.CreateUnbounded<string>();
    readonly List<JsonObject> _sent = [];

    public IReadOnlyList<JsonObject> Sent { get { lock (_sent) return [.. _sent]; } }

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
        if (holdOpen) await Task.Delay(Timeout.Infinite, ct);
    }

    public Task WriteLineAsync(string line, CancellationToken ct)
    {
        if (line.Contains('\n')) throw new ArgumentException("a stdin message must be one line", nameof(line));
        var o = JsonNode.Parse(line)!.AsObject();
        lock (_sent) _sent.Add(o);
        if ((string?)o["type"] == "control_request") _requestIds.Writer.TryWrite((string)o["request_id"]!);
        return Task.CompletedTask;
    }

    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}
