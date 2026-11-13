namespace TokenChat.Core.Tests;

public class AppUpdateTests
{
    [Fact]
    public void Counts_read_ahead_then_behind()
    {
        Assert.Equal((2, 5), AppUpdate.ParseCounts("2\t5\n"));
        Assert.Equal((0, 0), AppUpdate.ParseCounts("fatal: no upstream"));
    }

    [Fact]
    public void A_local_edit_the_pull_also_changes_is_a_conflict()
    {
        var porcelain = " M bin/token-master.js\n M windows/token-chat/src/TokenChat.App/Tray.cs\nR  old.md -> commands/new.md\n";
        var c = AppUpdate.Conflicts(porcelain, ["windows/token-chat/src/TokenChat.App/Tray.cs", "commands/new.md", "install.sh"]);
        Assert.Equal(["windows/token-chat/src/TokenChat.App/Tray.cs", "commands/new.md"], c);
    }

    [Fact]
    public void Dry_run_backup_lines_are_the_live_drift()
    {
        var output = "scripts -> /c/Users/x/.claude\n  same    token-me.js\n  backup  token-cycles.sh -> token-cycles.sh.bak-20261029-101010\n  would   copy token-cycles.sh\n  would   copy token-new.sh\n";
        Assert.Equal(["token-cycles.sh"], AppUpdate.ParseDryRun(output));
    }

    [Fact]
    public void Only_tokenchat_sources_need_a_restart()
    {
        Assert.False(UpdateStatus.TouchesApp(["bin/token-sessions.sh", "commands/park.md", "windows/token-chat/update.ps1"]));
        Assert.True(UpdateStatus.TouchesApp(["windows/token-chat/src/TokenChat.Core/Plan.cs"]));
    }

    [Fact]
    public void Local_commits_or_conflicts_block_the_update()
    {
        UpdateStatus S(int ahead, params string[] conflicts) => new("r", "origin/master", "abc", 3, ahead, [], conflicts, []);
        Assert.Null(S(0).Blocker);
        Assert.Contains("1 commit not on origin/master", S(1).Blocker);
        Assert.Contains("install.sh", S(0, "install.sh").Blocker);
    }

    [Fact]
    public void Git_bash_paths_become_windows_paths()
    {
        Assert.Equal(@"C:\Users\x\claude-token-tools", AppUpdate.WindowsPath("/c/Users/x/claude-token-tools"));
        Assert.Equal(@"D:\src", AppUpdate.WindowsPath(@"D:\src"));
    }

    [Fact]
    public void Due_once_a_day_and_later_holds_for_that_commit_only()
    {
        var now = DateTimeOffset.Parse("2026-10-29T12:00:00Z");
        var s = new UpdateState { LastCheck = now.AddHours(-23) };
        Assert.False(s.Due(now));
        Assert.True(s.Due(now.AddHours(2)));
        s.SnoozedSha = "abc";
        s.SnoozedAt = now;
        Assert.True(s.Snoozed("abc", now.AddHours(5)));
        Assert.False(s.Snoozed("def", now.AddHours(5)));
        Assert.False(s.Snoozed("abc", now.AddHours(25)));
    }
}

public class RestoreManifestTests
{
    [Fact]
    public void Round_trips_and_is_restored_once()
    {
        var dir = Directory.CreateTempSubdirectory().FullName;
        var path = Path.Combine(dir, "tokenchat-restore.json");
        var m = new RestoreManifest(DateTimeOffset.Now,
            [new RestoreTab(@"C:\a", "s1", Model: "claude-opus-5-5", Effort: "high", Mode: "plan", Draft: "half a thought", MasterSid: "m1", Locked: true),
             new RestoreTab(@"C:\b", Lite: true)], Current: 1, Maximized: true, Reason: "update");
        m.Save(path);
        Assert.Equal(path, RestoreManifest.Pending(path, DateTimeOffset.Now));
        var back = RestoreManifest.Load(path)!;
        Assert.Equal(m.Tabs, back.Tabs);
        Assert.Equal((1, true, "update"), (back.Current, back.Maximized, back.Reason));
        RestoreManifest.MarkDone(path);
        Assert.Null(RestoreManifest.Pending(path, DateTimeOffset.Now));
        Assert.True(File.Exists(RestoreManifest.DonePath(path)));
    }

    [Fact]
    public void A_stale_manifest_is_set_aside_not_restored()
    {
        var path = Path.Combine(Directory.CreateTempSubdirectory().FullName, "tokenchat-restore.json");
        new RestoreManifest(DateTimeOffset.Now.AddDays(-3), [new RestoreTab(@"C:\a", "s1")]).Save(path);
        Assert.Null(RestoreManifest.Pending(path, DateTimeOffset.Now));
        Assert.False(File.Exists(path));
    }

    [Fact]
    public void A_transcript_is_found_under_any_project()
    {
        var projects = Directory.CreateTempSubdirectory().FullName;
        Directory.CreateDirectory(Path.Combine(projects, "C--x"));
        File.WriteAllText(Path.Combine(projects, "C--x", "abc.jsonl"), "");
        Assert.True(RestoreManifest.TranscriptExists("abc", projects));
        Assert.False(RestoreManifest.TranscriptExists("def", projects));
    }

    [Fact]
    public void Restore_flag_parses_to_a_full_path()
    {
        var r = LaunchRequest.Parse(["--restore", "m.json"]);
        Assert.Equal(Path.GetFullPath("m.json"), r.Restore);
        Assert.Null(r.Directory);
    }
}
