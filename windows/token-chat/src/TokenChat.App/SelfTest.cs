using System.Diagnostics;
using System.IO;
using TokenChat.Core;
using TokenChat.Core.Transcript;

namespace TokenChat.App;

/// <summary>Master plan mode end to end, run once at the start after ~/.claude/token-selftest/master.pending is written:
/// a master tab and a delegate tab on haiku, the delegate opened by the real /unpark --delegate on a throwaway checkpoint
/// and scratch repo. Each step is logged raw with its time to token-selftest/master-&lt;stamp&gt;.log, ending in PASS or
/// FAIL at the step that timed out. Removing it is deleting this file and its one call in MainWindow.</summary>
static class SelfTest
{
    static readonly string Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "token-selftest");
    const string Slug = "selftest-probe";

    public static void RunIfPending(Func<string, string, string, SessionTab> open)
    {
        var flag = Path.Combine(Dir, "master.pending");
        if (!File.Exists(flag)) return;
        try { File.Delete(flag); } catch (IOException) { return; } // never twice
        _ = RunAsync(open);
    }

    static async Task RunAsync(Func<string, string, string, SessionTab> open)
    {
        var stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
        var log = Path.Combine(Dir, $"master-{stamp}.log");
        var t0 = Stopwatch.StartNew();
        void Log(string s) => File.AppendAllText(log, $"{t0.Elapsed.TotalSeconds,7:0.0}s  {s}\n");
        var checkpoint = Path.Combine(Plan.Dir, $"selftest.{Slug}.md");
        string? masterSid = null;
        SessionTab? master = null, dlg = null;

        async Task<bool> Until(string step, Func<bool> ok, int seconds, Func<string>? state = null)
        {
            var last = "";
            for (var i = 0; i < seconds * 2; i++)
            {
                if (ok()) { Log($"ok    {step}"); return true; }
                if (state?.Invoke() is { } s && s != last) Log($"      {step}: {last = s}");
                await Task.Delay(500);
            }
            Log($"FAIL  {step} (timed out after {seconds}s)" + (state is null ? "" : $" last: {state()}"));
            return false;
        }
        string Of(SessionTab? t) => t is null ? "no tab" :
            $"sid={t.SessionId?[..8]} state={t.State} waiting={t.Waiting} delegate={t.DelegateState} locked={t.Locked} " +
            $"master={t.MasterSid?[..8]} summary='{t.MasterSummary}' delegates={t.Delegates.Count} report={t.ReportPath is not null} " +
            $"prompts=[{string.Join(",", t.Transcript.PendingPrompts.Select(p => p.GetType().Name))}]";

        try
        {
            Directory.CreateDirectory(Dir);
            Log("start");
            // the delegate's folder: a scratch repo already on its delegate branch, as /delegate's worktree would be
            var repo = Path.Combine(Path.GetTempPath(), $"tokenchat-selftest-{stamp}");
            Directory.CreateDirectory(repo);
            File.WriteAllText(Path.Combine(repo, "README.md"), "TokenChat master plan mode self-test.\n");
            foreach (var args in new[] { "init -q -b master", "add README.md", "-c user.name=selftest -c user.email=selftest@local commit -q -m init",
                         $"checkout -q -b delegate/{Slug}" })
                Git(repo, args, Log);
            Log($"repo {repo}");

            master = open(repo, "haiku", "Self-test: you are a master session. Your plan's Decided: the probe colour is Blue. " +
                "When a delegate asks, answer it from that with /answer. Reply now with the one word ready.");
            if (!await Until("master tab up", () => master.SessionId is not null && master.State == "idle", 180, () => Of(master))) return;
            masterSid = master.SessionId!;
            master.SetMaster(true);
            if (!await Until("master state file", () => MasterState.Load(masterSid) is not null && master.IsMaster, 10, () => Of(master))) return;

            File.WriteAllText(checkpoint, $"""
                <!-- park: session=none topic={Slug} cwd={repo} delegate-of={masterSid} master={masterSid} -->
                # selftest - {Slug} - {DateTime.Now:yyyy-MM-dd HH:mm}

                ## Next
                1. Ask the master one question with AskUserQuestion: "Which colour should the probe use?", options Red and Blue.
                2. Write the chosen colour, one word, into colour.txt in this folder and commit it on this branch.
                Stop after: step 2, then write the report.

                ## Goal
                TokenChat's master plan mode self-test. Scope: colour.txt in this folder only.

                ## Decided - do not reopen
                - The colour comes from the master, never guessed.

                """);
            Log($"checkpoint {checkpoint}");

            dlg = open(repo, "haiku", $"/unpark {Slug} --delegate");
            if (!await Until("delegate bound to master", () => dlg.MasterSid == masterSid && dlg.Locked, 5, () => Of(dlg))) return;
            if (!await Until("strip lists the delegate", () => master.HasDelegates && master.Delegates.Contains(dlg), 30, () => Of(master))) return;
            if (!await Until("delegate asks the master", () => dlg.DelegateState is "asking" || dlg.AsksMaster || dlg.ReportPath is not null, 300, () => Of(dlg))) return;
            if (!await Until("master holds the ask", () => master.MasterSummary.Contains("ask"), 15, () => Of(master))) return;
            if (!await Until("master answers, card closes", () => !dlg.AsksMaster && dlg.DelegateState != "asking", 300,
                    () => Of(dlg) + " | master " + Of(master))) return;
            if (!await Until("report lands, delegate done", () => dlg.DelegateState == "done" && dlg.ReportPath is not null, 400, () => Of(dlg))) return;
            var colour = File.Exists(Path.Combine(repo, "colour.txt")) ? File.ReadAllText(Path.Combine(repo, "colour.txt")).Trim() : "(no colour.txt)";
            Log($"colour.txt: {colour}");
            Log($"report {dlg.ReportPath}");
            Log("PASS");
        }
        catch (Exception e) { Log("FAIL  exception: " + e); }
        finally
        {
            Log("final master   " + Of(master));
            Log("final delegate " + Of(dlg));
            // the throwaway checkpoint would sit in Parked; the master file would keep the tab a master
            try { File.Delete(checkpoint); } catch (IOException) { }
            if (masterSid is not null) MasterState.SetMaster(masterSid, false);
            master?.Transcript.AddNote(NoteKind.Info, "Master self-test finished", log);
        }
    }

    static void Git(string cwd, string args, Action<string> log)
    {
        using var p = Process.Start(new ProcessStartInfo("git", args)
        {
            WorkingDirectory = cwd, UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true,
        })!;
        var err = p.StandardError.ReadToEnd();
        p.WaitForExit();
        if (p.ExitCode != 0) throw new InvalidOperationException($"git {args}: {err.Trim()}");
        log($"git {args}");
    }
}
