#:project ../src/TokenChat.Core/TokenChat.Core.csproj
// Live smoke test of TokenChat.Core against the real claude.exe (lite profile, two short turns).
// Spends ~16k cached tokens of the subscription. dotnet run smoke.cs
using System.Diagnostics;
using TokenChat.Core;
using TokenChat.Core.Protocol;

var repo = Path.GetFullPath(Path.Combine(AppContext.GetData("EntryPointFileDirectoryPath") as string ?? ".", "..", "..", ".."));
var target = Path.Combine(Path.GetTempPath(), "token-chat-smoke.txt");
using var overall = new CancellationTokenSource(TimeSpan.FromMinutes(4));
var ct = overall.Token;
var clock = Stopwatch.StartNew();
var failures = new List<string>();
void Check(bool ok, string what) { Console.WriteLine($"  [{(ok ? "ok" : "FAIL")}] {what}"); if (!ok) failures.Add(what); }

var spec = ClaudeLauncher.Build(new LaunchOptions { WorkingDirectory = repo, Profile = Profile.Lite });
Console.WriteLine($"exe {spec.Exe}\ncwd {repo}");
var transport = new ProcessTransport(spec);
var stderr = new List<string>();
transport.StderrLine += l => { lock (stderr) stderr.Add(l); };
var session = new ClaudeSession(transport);
int pid = transport.ProcessId;

try
{
    await session.HandshakeAsync(TimeSpan.FromSeconds(90), ct);
    Console.WriteLine($"handshake {clock.ElapsedMilliseconds} ms, pid {pid}");
    Check((string?)session.InitializeInfo?["account"]?["subscriptionType"] is { Length: > 0 }, "initialize returned an account");

    await session.SendAsync("Reply with exactly the word: pong", ct);
    var (text1, result1) = await Turn();
    Check(text1.Contains("pong", StringComparison.OrdinalIgnoreCase), $"turn 1 streamed text: \"{text1.Trim()}\"");
    Check(session.Init?.Tools.Contains("AskUserQuestion") == true, $"lite tools: {string.Join(",", session.Init?.Tools ?? [])}");
    Check(result1?.Usage == session.Usage.LastTurn, $"ledger turn {session.Usage.LastTurn} == result {result1?.Usage}");
    Check(session.Usage.Context > 10_000, $"context {session.Usage.Context}");
    Check(session.Usage.Floor == result1?.Usage.Prompt, $"floor {session.Usage.Floor} == first request prompt");

    await session.SendAsync($"Use the AskUserQuestion tool to ask me: red or blue? Then use the Write tool to write my answer to {target}. If the write is denied, stop and say so in one line.", ct);
    var asked = 0; var denied = 0;
    var (text2, result2) = await Turn(async e =>
    {
        switch (e)
        {
            case QuestionRequest q:
                asked++;
                Console.WriteLine($"  question: {q.Questions.FirstOrDefault()?.Text} [{string.Join("/", q.Questions.FirstOrDefault()?.Options.Select(o => o.Label) ?? [])}]");
                await session.AnswerAsync(q, q.Questions.ToDictionary(x => x.Text, x => x.Options.Select(o => o.Label).FirstOrDefault(l => l.Contains("Blue", StringComparison.OrdinalIgnoreCase)) ?? x.Options[0].Label), ct);
                break;
            case PermissionRequest p:
                denied++;
                Console.WriteLine($"  permission: {p.ToolName} {p.Description}");
                Check(!session.AtCleanPoint, "not at a clean point while a permission is open");
                await session.DenyAsync(p.RequestId, "smoke test: denied", ct);
                break;
        }
    });
    Check(asked == 1, $"one question answered (got {asked})");
    Check(denied >= 1, $"permission requested and denied (got {denied})");
    Check(!File.Exists(target), "nothing was written");
    Check(text2.Contains("blue", StringComparison.OrdinalIgnoreCase), $"turn 2 used the answer: \"{text2.Trim().ReplaceLineEndings(" ")}\"");
    Check(result2?.Usage == session.Usage.LastTurn, $"ledger turn {session.Usage.LastTurn} == result {result2?.Usage}");
    Check(session.AtCleanPoint, "clean point after the result");
    var rl = session.RateLimit;
    Check(rl?.FiveHour is not null, $"rate limit: five_hour {rl?.FiveHour?.Utilization:P0}, seven_day {rl?.SevenDay?.Utilization:P0}");
    Console.WriteLine($"session {session.SessionId}, total {session.Usage.Session}, {clock.Elapsed.TotalSeconds:F0} s");
}
catch (Exception ex)
{
    failures.Add(ex.GetType().Name + ": " + ex.Message);
    Console.WriteLine("EXCEPTION " + ex);
}
finally
{
    await session.DisposeAsync();
    bool exited;
    try { exited = Process.GetProcessById(pid).HasExited; } catch (ArgumentException) { exited = true; }
    Check(exited, $"claude.exe {pid} gone after dispose");
    lock (stderr) if (stderr.Count > 0) Console.WriteLine("stderr:\n  " + string.Join("\n  ", stderr.TakeLast(10)));
}
Console.WriteLine(failures.Count == 0 ? "SMOKE PASSED" : $"SMOKE FAILED ({failures.Count}): {string.Join("; ", failures)}");
return failures.Count == 0 ? 0 : 1;

// Drains events until the turn's result; streams main-chain text to the console.
async Task<(string Text, ResultEvent? Result)> Turn(Func<ClaudeEvent, Task>? onEvent = null)
{
    var text = new System.Text.StringBuilder();
    await foreach (var e in session.Events.ReadAllAsync(ct))
    {
        if (e is DeltaEvent { Kind: DeltaKind.Text, ParentToolUseId: null } d) text.Append(d.Text);
        if (e is UnknownEvent u) Console.WriteLine($"  unknown event {u.Type}:{u.Subtype}");
        if (onEvent is not null) await onEvent(e);
        if (e is ResultEvent r)
        {
            Console.WriteLine($"  result {r.Subtype} in {r.DurationMs} ms, usage {r.Usage}");
            return (text.ToString(), r);
        }
    }
    return (text.ToString(), null);
}
