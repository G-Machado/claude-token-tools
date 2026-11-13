using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Text.Json.Nodes;
using TokenChat.Core;

namespace TokenChat.App;

/// <summary>A Unity project's Editor as the Editor tab sees it: the scene image, the hierarchy and the picked object's
/// inspector, each read by one <c>unity command eval</c> on the Editor already serving the project (headless or windowed;
/// none is ever started from here). One per project, shared by the window's view and every page showing it: while any
/// of them watches, one loop refreshes the snapshot every few seconds. Calls run one at a time; each costs ~3s, mostly
/// CLI start-up. Changed fires off the UI thread.</summary>
public sealed class UnityEditorLink
{
    static readonly ConcurrentDictionary<string, UnityEditorLink> All = new(StringComparer.OrdinalIgnoreCase);
    static int _nextId;

    public static UnityEditorLink For(string root) => All.GetOrAdd(Path.TrimEndingDirectorySeparator(Path.GetFullPath(root)), r => new UnityEditorLink(r));
    public static UnityEditorLink? ById(int id) => All.Values.FirstOrDefault(l => l.Id == id);

    static string Cli => Environment.GetEnvironmentVariable("UNITY_CLI") is { Length: > 0 } c ? c
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Unity", "bin", "unity.exe");

    static readonly string Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "tokenchat-editor");

    UnityEditorLink(string root)
    {
        Root = root;
        Id = Interlocked.Increment(ref _nextId);
        PngPath = Path.Combine(Dir, Id + "-" + Name + ".png");
    }

    public string Root { get; }
    public int Id { get; }
    public string Name => Path.GetFileName(Root);
    public string PngPath { get; }

    /// <summary>One line on the link: the Editor serving it, or why nothing shows.</summary>
    public string Status { get; private set; } = "";
    public bool Busy { get; private set; }
    /// <summary>The last snapshot: <c>{scene, unity, from, sel, nodes, count, truncated}</c>.</summary>
    public JsonObject? Scene { get; private set; }
    /// <summary>The picked object's components, <c>{id, n, tag, layer, a, comps}</c>, or <c>{error}</c>.</summary>
    public JsonObject? Inspected { get; private set; }
    public int Picked { get; private set; }
    /// <summary>Bumped by each part when it changes, so a page resends only that part.</summary>
    public int ImageVersion { get; private set; }
    public int SceneVersion { get; private set; }
    public int InspectVersion { get; private set; }
    public int StatusVersion { get; private set; }

    public event Action? Changed;

    readonly SemaphoreSlim _gate = new(1, 1);
    readonly HashSet<object> _watchers = [];
    CancellationTokenSource? _loop;
    int? _pid;
    string? _lastNodes;

    /// <summary>Keeps the snapshot fresh while anyone watches; the first watcher starts the loop, the last stops it.</summary>
    public void Watch(object who)
    {
        lock (_watchers)
        {
            if (!_watchers.Add(who) || _loop is not null) return;
            _loop = new CancellationTokenSource();
            _ = LoopAsync(_loop.Token);
        }
    }

    public void Unwatch(object who)
    {
        lock (_watchers)
        {
            if (!_watchers.Remove(who) || _watchers.Count > 0) return;
            _loop?.Cancel();
            _loop = null;
        }
    }

    async Task LoopAsync(CancellationToken stop)
    {
        while (!stop.IsCancellationRequested)
        {
            await RefreshAsync();
            // no Editor: look again less often, the CLI's status call is not free either
            try { await Task.Delay(_pid is null ? 15000 : 4000, stop); }
            catch (OperationCanceledException) { return; }
        }
    }

    /// <summary>Re-reads the image and the hierarchy; a pick in place re-reads its inspector too.</summary>
    public async Task RefreshAsync()
    {
        if (!await _gate.WaitAsync(0)) return;   // one in flight already does it
        try
        {
            SetBusy(true);
            var shot = await EvalAsync(UnityEval.SnapshotScript(PngPath));
            if (shot is null) return;
            if (!shot.Value.Ok) { SetStatus(shot.Value.Error!); return; }
            if (Parse(shot.Value.Value) is not { } scene) { SetStatus("unreadable snapshot"); return; }
            var nodes = (string?)scene["scene"] + scene["nodes"]?.ToJsonString() + scene["scenes"]?.ToJsonString();
            if ((string?)scene["scene"] != (string?)Scene?["scene"] && Picked != 0)
            {
                Picked = 0;   // another scene: its objects are not the ones picked
                Inspected = null;
                InspectVersion++;
            }
            // swapped whole, never edited: the page's tick reads it from the UI thread
            if (nodes != _lastNodes) { _lastNodes = nodes; Scene = scene; SceneVersion++; }
            ImageVersion++;
            SetStatus(Describe(scene));
            if (Picked != 0) await InspectCoreAsync(Picked);
        }
        finally { SetBusy(false); _gate.Release(); }
    }

    /// <summary>Shows one object's inspector and selects it in the Editor.</summary>
    public async Task PickAsync(int id)
    {
        Picked = id;
        await _gate.WaitAsync();
        try
        {
            SetBusy(true);
            await InspectCoreAsync(id);
        }
        finally { SetBusy(false); _gate.Release(); }
    }

    /// <summary>The active scene is untitled or empty: the tab offers the project's scenes instead of a blank view.</summary>
    public bool NeedsScene => Scene is { } s && (string.IsNullOrEmpty((string?)s["scene"]) || (int?)s["count"] == 0);

    /// <summary>Opens one of the scenes the last snapshot listed (no other path is taken), never saving; then re-reads.</summary>
    public async Task OpenSceneAsync(string path)
    {
        if (Scene?["scenes"] is not JsonArray known || !known.Any(x => (string?)x == path)) return;
        await _gate.WaitAsync();
        try
        {
            SetBusy(true);
            var r = await EvalAsync(UnityEval.OpenSceneScript(path));
            if (r is { } o && (o.Value != "ok")) { SetStatus(o.Error ?? o.Value ?? "the scene did not open"); return; }
        }
        finally { SetBusy(false); _gate.Release(); }
        await RefreshAsync();
    }

    async Task InspectCoreAsync(int id)
    {
        var r = await EvalAsync(UnityEval.InspectScript(id));
        if (r is null || id != Picked) return;
        Inspected = r.Value.Ok ? Parse(r.Value.Value) ?? new JsonObject { ["error"] = "unreadable inspector" }
                               : new JsonObject { ["error"] = r.Value.Error };
        InspectVersion++;
        Changed?.Invoke();
    }

    string Describe(JsonObject scene)
    {
        var sceneName = Path.GetFileNameWithoutExtension((string?)scene["scene"] ?? "");
        var from = (string?)scene["from"];
        return $"{_mode} {_pid} · {(sceneName.Length > 0 ? sceneName : "untitled")} · {scene["count"]} objects"
               + (from is { Length: > 0 } ? " · from " + from : "") + $" · {DateTime.Now:HH:mm:ss}";
    }

    string _mode = "Editor";

    /// <summary>The eval's outcome, or null once the status line says there is no Editor to ask.</summary>
    async Task<UnityEval.Outcome?> EvalAsync(string code)
    {
        if (_pid is null && !await FindEditorAsync()) return null;
        var (exit, stdout) = await RunAsync(["command", "eval", code, "--pid", _pid!.Value.ToString(), "--project-path", Root,
                                             "--format", "json", "--no-banner", "--non-interactive"], 90);
        var r = UnityEval.ReadEval(stdout);
        if (!r.Ok && exit != 0 && !Alive(_pid.Value))
        {
            _pid = null;
            SetStatus("the Editor closed");
            return null;
        }
        return r;
    }

    async Task<bool> FindEditorAsync()
    {
        var (_, stdout) = await RunAsync(["status", "--format", "json", "--project-path", Root, "--no-banner", "--non-interactive"], 30);
        if (UnityEval.PickInstance(stdout, Root) is not { } hit)
        {
            SetStatus("no Unity Editor is open on " + Name + " — open one (headless or windowed) and this fills in");
            return false;
        }
        _pid = hit.Pid;
        _mode = hit.Batch ? "headless" : "windowed";
        return true;
    }

    static bool Alive(int pid)
    {
        try { using var p = Process.GetProcessById(pid); return !p.HasExited; }
        catch (Exception) { return false; }
    }

    static async Task<(int Exit, string Stdout)> RunAsync(string[] args, int seconds)
    {
        var psi = new ProcessStartInfo(Cli) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = new Process { StartInfo = psi };
        try { p.Start(); }
        catch (Exception ex) { return (-1, "{\"errors\":[{\"message\":\"cannot run the unity CLI: " + ex.Message.Replace("\"", "'") + "\"}]}"); }
        var outTask = p.StandardOutput.ReadToEndAsync();
        _ = p.StandardError.ReadToEndAsync();   // drained so a chatty stderr cannot stall it; notices land there
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
        try { await p.WaitForExitAsync(cts.Token); }
        catch (OperationCanceledException)
        {
            try { p.Kill(true); } catch (Exception) { }
            return (-1, "{\"errors\":[{\"message\":\"the Editor did not answer in " + seconds + "s (busy importing or compiling?)\"}]}");
        }
        return (p.ExitCode, await outTask);
    }

    static JsonObject? Parse(string? s)
    {
        try { return s is null ? null : JsonNode.Parse(s) as JsonObject; }
        catch (System.Text.Json.JsonException) { return null; }
    }

    void SetStatus(string s)
    {
        if (s == Status) { Changed?.Invoke(); return; }
        Status = s;
        StatusVersion++;
        Changed?.Invoke();
    }

    void SetBusy(bool b)
    {
        if (Busy == b) return;
        Busy = b;
        StatusVersion++;
        Changed?.Invoke();
    }
}
