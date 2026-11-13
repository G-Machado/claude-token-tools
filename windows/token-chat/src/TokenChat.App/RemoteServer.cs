using System.Collections.ObjectModel;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Channels;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;
using TokenChat.Core;
using TokenChat.Core.Remote;
using TokenChat.Core.Transcript;

namespace TokenChat.App;

/// <summary>TokenChat in a browser on the LAN (the Quest's, a phone's): one page, state over a WebSocket, actions back.
/// The page is the same sessions drawn in HTML, so the device's own keyboard and dictation work. Off until started.
/// A device pairs once with the 6-digit <see cref="Code"/> shown here and keeps a cookie; the code then rotates.
/// Everything that touches a tab runs on the UI thread, as the tabs do.</summary>
sealed class RemoteServer(ObservableCollection<SessionTab> tabs, Dispatcher ui)
{
    public const int Port = 8765;
    const string Cookie = "tokenchat";
    static readonly string TokenFile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "tokenchat-remote-tokens");

    readonly HashSet<string> _tokens = Load();
    readonly Dictionary<SessionTab, int> _tabIds = [];
    readonly List<Client> _clients = [];
    WebApplication? _app;
    DispatcherTimer? _tick;
    int _wrong, _nextTab;
    DateTime _pairShutUntil;

    public bool IsOn => _app is not null;
    public string Code { get; private set; } = NewCode();
    /// <summary>The pairing code changed (a device paired, or too many wrong tries).</summary>
    public event Action? CodeChanged;

    /// <summary>Where a device on the LAN (or the tailnet, 100.x) reaches the page.</summary>
    public static IReadOnlyList<string> Urls() =>
        [.. NetworkInterface.GetAllNetworkInterfaces()
            .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
            .SelectMany(n => n.GetIPProperties().UnicastAddresses)
            .Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork && !a.Address.ToString().StartsWith("169.254."))
            .Select(a => $"http://{a.Address}:{Port}/")];

    public async Task StartAsync()
    {
        if (_app is not null) return;
        var b = WebApplication.CreateSlimBuilder();
        b.Logging.ClearProviders();
        b.WebHost.UseKestrel(o => o.Listen(IPAddress.Any, Port));
        var app = b.Build();
        app.UseWebSockets(new WebSocketOptions { KeepAliveInterval = TimeSpan.FromSeconds(20) });
        app.MapGet("/", () => Results.Content(Page(), "text/html; charset=utf-8"));
        app.MapGet("/theme.css", async () => Results.Content(await ui.InvokeAsync(ThemeCss), "text/css; charset=utf-8"));
        app.MapPost("/pair", (Func<HttpContext, Task<IResult>>)Pair);
        // the Editor tab's scene image, behind the same pairing cookie as the socket
        app.MapGet("/editor/{id:int}.png", (HttpContext ctx, int id) =>
        {
            if (!Paired(ctx)) return Results.StatusCode(401);
            if (UnityEditorLink.ById(id) is not { } l || !File.Exists(l.PngPath)) return Results.NotFound();
            try { return Results.File(File.ReadAllBytes(l.PngPath), "image/png"); }
            catch (IOException) { return Results.StatusCode(503); }   // mid-swap: the page asks again on the next version
        });
        app.Map("/ws", Socket);
        await app.StartAsync();
        _app = app;
        _tick = new DispatcherTimer(TimeSpan.FromMilliseconds(100), DispatcherPriority.Background, (_, _) => Tick(), ui);
        _tick.Start();
    }

    public async Task StopAsync()
    {
        _tick?.Stop();
        _tick = null;
        foreach (var c in _clients.ToList()) c.Close();
        if (_app is { } app) { _app = null; await app.StopAsync(); await app.DisposeAsync(); }
    }

    static string NewCode() => RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("000000");

    static HashSet<string> Load()
    {
        try { return [.. File.ReadAllLines(TokenFile).Where(l => l.Length > 0)]; }
        catch (IOException) { return []; }
    }

    /// <summary>Run from the clone (bin\Debug\net10.0-windows under the project), the page is read from the source file
    /// on every load, so an edit to Remote\index.html shows on a browser reload with no restart; else the embedded copy.</summary>
    static readonly string? PageSource = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "Remote", "index.html")) is var p && File.Exists(p) ? p : null;

    static string Page()
    {
        if (PageSource is { } src) try { return File.ReadAllText(src); } catch (IOException) { }
        using var s = typeof(RemoteServer).Assembly.GetManifestResourceStream("remote.index.html")!;
        return new StreamReader(s).ReadToEnd();
    }

    /// <summary>The app's own brushes and fonts (Theme.xaml, as loaded) as CSS variables, <c>--Card</c>, <c>--Ui</c>...,
    /// so the page takes every colour from the same place the window does and cannot drift from it.</summary>
    static string ThemeCss()
    {
        var css = new StringBuilder(":root {\n");
        void Walk(System.Windows.ResourceDictionary d)
        {
            foreach (var m in d.MergedDictionaries) Walk(m);
            foreach (var key in d.Keys)
                if (key is string k && d[k] is { } v)
                    switch (v)
                    {
                        case SolidColorBrush b:
                            var c = b.Color;
                            css.Append(FormattableString.Invariant($"  --{k}: rgba({c.R},{c.G},{c.B},{c.A / 255.0:0.###});\n"));
                            break;
                        case FontFamily f:
                            css.Append($"  --{k}: \"{f.Source}\", system-ui, sans-serif;\n");
                            break;
                    }
        }
        Walk(System.Windows.Application.Current.Resources);
        return css.Append("}\n").ToString();
    }

    bool Paired(HttpContext ctx) => ctx.Request.Cookies.TryGetValue(Cookie, out var t) && t is not null && _tokens.Contains(t);

    async Task<IResult> Pair(HttpContext ctx)
    {
        var form = await ctx.Request.ReadFormAsync();
        var given = form["code"].ToString().Trim();
        return await ui.InvokeAsync(() =>
        {
            if (DateTime.UtcNow < _pairShutUntil) return Results.StatusCode(429);
            if (given != Code)
            {
                // a guess per try out of a million; after five the code moves and pairing shuts for a minute,
                // so a LAN brute force runs at five guesses a minute
                if (++_wrong >= 5) { _wrong = 0; _pairShutUntil = DateTime.UtcNow.AddMinutes(1); Code = NewCode(); CodeChanged?.Invoke(); }
                return Results.Unauthorized();
            }
            var token = Convert.ToHexString(RandomNumberGenerator.GetBytes(24));
            _tokens.Add(token);
            File.WriteAllLines(TokenFile, _tokens);
            _wrong = 0;
            Code = NewCode();
            CodeChanged?.Invoke();
            ctx.Response.Cookies.Append(Cookie, token, new CookieOptions
                { HttpOnly = true, SameSite = SameSiteMode.Strict, MaxAge = TimeSpan.FromDays(365) });
            return Results.Ok();
        });
    }

    async Task Socket(HttpContext ctx)
    {
        if (!ctx.WebSockets.IsWebSocketRequest) { ctx.Response.StatusCode = 400; return; }
        if (!Paired(ctx)) { ctx.Response.StatusCode = 401; return; }
        using var ws = await ctx.WebSockets.AcceptWebSocketAsync();
        var client = new Client(ws);
        await ui.InvokeAsync(() => { _clients.Add(client); client.Send(TabList()); });
        var send = client.PumpAsync();
        try
        {
            var buf = new byte[64 * 1024];
            while (ws.State == WebSocketState.Open)
            {
                using var msg = new MemoryStream();
                WebSocketReceiveResult r;
                do
                {
                    r = await ws.ReceiveAsync(buf, ctx.RequestAborted);
                    if (r.MessageType == WebSocketMessageType.Close) break;
                    msg.Write(buf, 0, r.Count);
                } while (!r.EndOfMessage);
                if (r.MessageType == WebSocketMessageType.Close) break;
                if (JsonNode.Parse(msg.ToArray()) is JsonObject op)
                    await await ui.InvokeAsync(() => ActAsync(client, op));
            }
        }
        catch (Exception ex) when (ex is WebSocketException or OperationCanceledException) { }
        finally
        {
            await ui.InvokeAsync(() => { _clients.Remove(client); client.Close(); });
            await send;
        }
    }

    /// <summary>One message from the page. Every action is a method the tab already has; the page names rows by the ids
    /// its projection gave them.</summary>
    async Task ActAsync(Client c, JsonObject op)
    {
        // the Editor tab names a project, not a tab
        switch ((string?)op["op"])
        {
            case "editor-open" when UnityEval.ProjectRoot((string?)op["root"]) is { } root:
                c.ShowEditor(UnityEditorLink.For(root));
                return;
            case "editor-close":
                c.ShowEditor(null);
                return;
            case "editor-pick" when c.Editor is { } l && (int?)op["node"] is { } node:
                _ = l.PickAsync(node);
                return;
            case "editor-scene" when c.Editor is { } l && (string?)op["path"] is { } path:
                _ = l.OpenSceneAsync(path);
                return;
            case "editor-refresh":
                _ = c.Editor?.RefreshAsync();
                return;
        }
        var tab = _tabIds.FirstOrDefault(p => p.Value == (int?)op["tab"]).Key;
        if (tab is null || !tabs.Contains(tab)) return;
        var item = op["id"] is { } id ? c.View?.Find((int)id) : null;
        try
        {
            switch ((string?)op["op"])
            {
                case "select":
                    c.ShowEditor(null);
                    c.Show(tab, TabId(tab));
                    break;
                case "send" when (string?)op["text"] is { Length: > 0 } text:
                    await tab.SendAsync(text);
                    break;
                case "stop":
                    await tab.InterruptAsync();
                    break;
                case "permission" when item is PermissionItem p && Enum.TryParse<PermissionState>((string?)op["decision"], out var d):
                    await tab.DecideAsync(p, d);
                    break;
                case "card" when item is CardItem card && (string?)op["key"] is { } key:
                    await tab.ActAsync(card, key);
                    break;
                case "answer" when item is QuestionItem q && op["answers"] is JsonObject given:
                    q.Show(given.ToDictionary(kv => kv.Key, kv => (string?)kv.Value ?? ""));
                    await tab.AnswerAsync(q);
                    break;
                case "decline" when item is QuestionItem q:
                    await tab.DeclineAsync(q);
                    break;
            }
        }
        catch (Exception ex) { c.Send(new JsonObject { ["type"] = "error", ["text"] = ex.Message }); }
    }

    string? _lastTabs;

    void Tick()
    {
        var list = TabList();
        var json = list.ToJsonString();
        var tabsChanged = json != _lastTabs;
        _lastTabs = json;
        foreach (var c in _clients)
        {
            if (tabsChanged) c.Send(list);
            if (c.Tab is { } t && !tabs.Contains(t)) c.Show(null, 0);
            if (c.View?.Flush() is { } patch) c.Send(patch);
            if (c.EditorPatch() is { } ed) c.Send(ed);
        }
    }

    /// <summary>The window's sidebar, set once it exists: the page draws the same rows from it.</summary>
    public Sidebar? Side { get; set; }

    static string? Hex(Brush? b) => b is SolidColorBrush s
        ? (s.Color.A == 255 ? $"#{s.Color.R:X2}{s.Color.G:X2}{s.Color.B:X2}" : $"#{s.Color.R:X2}{s.Color.G:X2}{s.Color.B:X2}{s.Color.A:X2}")
        : null;

    /// <summary>The sidebar's rows as SidebarView draws them: group headers, then each session with the widget's figures.
    /// Rows of this window carry the page's tab id, so a click selects that tab.</summary>
    JsonArray SideRows()
    {
        var list = new JsonArray();
        if (Side is null) return list;
        const double spendWidth = 66;   // the spend bar's width in SidebarView, which the tick margins are laid against
        foreach (var it in Side.Items)
        {
            if (it.IsHeader)
            {
                list.Add(new JsonObject { ["h"] = true, ["name"] = it.Name, ["color"] = Hex(it.ProjectBrush), ["count"] = it.Count,
                                          ["folded"] = it.Folded, ["state"] = it.State });
                continue;
            }
            var o = new JsonObject
            {
                ["tab"] = it.Tab is { } t ? TabId(t) : null, ["here"] = it.Here, ["name"] = it.Name, ["arrow"] = it.Arrow,
                ["project"] = it.Project, ["color"] = Hex(it.ProjectBrush), ["state"] = it.State, ["depth"] = it.Depth,
                ["master"] = it.IsMaster, ["masterSummary"] = it.MasterSummary, ["delegate"] = it.DelegateState,
                ["reported"] = it.Reported, ["children"] = it.HasChildren ? it.ChildLabel : null, ["unity"] = it.UnityRoot,
            };
            if (it.Row is { } r)
                o["row"] = new JsonObject
                {
                    ["mark"] = r.Mark, ["markC"] = Hex(r.MarkBrush), ["ctx"] = r.Ctx, ["ctxC"] = Hex(r.CtxBrush),
                    ["clock"] = r.Clock, ["clockC"] = Hex(r.ClockBrush), ["cold"] = r.Cold,
                    ["spark"] = new JsonArray([.. r.Spark.Select(b => (JsonNode)new JsonArray(b.Width, b.Height, Hex(b.Fill)))]),
                    ["growth"] = r.Growth, ["growthC"] = Hex(r.GrowthBrush), ["heat"] = r.Heat, ["heatC"] = Hex(r.HeatBrush),
                    ["cycles"] = r.Cycles, ["pokes"] = r.Pokes, ["parked"] = r.Parked, ["parkedC"] = Hex(r.ParkedBrush),
                    ["marksLeft"] = r.MarksLeft, ["marksSpent"] = r.MarksSpent, ["blocked"] = r.Blocked, ["hasState"] = r.HasState,
                    ["model"] = r.Model, ["effort"] = r.Effort, ["effortC"] = Hex(r.EffortBrush),
                    ["spend"] = r.Spend, ["spendC"] = Hex(r.SpendBrush), ["spendFill"] = r.SpendFill,
                    ["ticks"] = new JsonArray(
                        new JsonArray(FooterRow.TickOkAt.Left / spendWidth, r.TickOk),
                        new JsonArray(FooterRow.TickWatchAt.Left / spendWidth, r.TickWatch),
                        new JsonArray(FooterRow.TickHeavyAt.Left / spendWidth, r.TickHeavy)),
                    ["grades"] = new JsonArray([.. r.Grades.Select(g => (JsonNode)new JsonArray(g.Letter, Hex(g.Fill)))]),
                };
            list.Add(o);
        }
        return list;
    }

    JsonObject TabList() => new()
    {
        ["type"] = "tabs",
        ["side"] = SideRows(),
        ["tabs"] = new JsonArray([.. tabs.Select(t => (JsonNode)new JsonObject
        {
            ["id"] = TabId(t), ["title"] = t.AutoTitle ?? t.Title, ["project"] = t.ProjectKey,
            ["color"] = t.ProjectBrush is SolidColorBrush b ? $"#{b.Color.R:X2}{b.Color.G:X2}{b.Color.B:X2}" : null,
            ["state"] = t.State, ["status"] = t.Status, ["waiting"] = t.Waiting, ["ready"] = t.IsReady,
        })]),
    };

    int TabId(SessionTab t) => _tabIds.TryGetValue(t, out var id) ? id : _tabIds[t] = ++_nextTab;

    /// <summary>One connected page: the tab it shows, that tab's projection, and its outgoing queue.</summary>
    sealed class Client(WebSocket ws)
    {
        readonly Channel<string> _out = Channel.CreateUnbounded<string>(new UnboundedChannelOptions { SingleReader = true });
        public SessionTab? Tab { get; private set; }
        public RemoteProjection? View { get; private set; }

        public void Show(SessionTab? tab, int id)
        {
            View?.Dispose();
            (Tab, View) = (tab, tab is null ? null : new RemoteProjection(tab.Items));
            if (View is { } v)
            {
                var snap = v.Snapshot();
                snap["tab"] = id;
                Send(snap);
            }
        }

        public void Send(JsonObject msg) => _out.Writer.TryWrite(msg.ToJsonString());

        /// <summary>The Editor this page shows, if any; it watches the link while open.</summary>
        public UnityEditorLink? Editor { get; private set; }
        int _edStatus, _edImage, _edScene, _edInspect;

        public void ShowEditor(UnityEditorLink? link)
        {
            if (Editor == link) return;
            Editor?.Unwatch(this);
            Editor = link;
            _edStatus = _edImage = _edScene = _edInspect = -1;
            link?.Watch(this);
        }

        /// <summary>The parts of the Editor that moved since the last send; the hierarchy only when its nodes changed.</summary>
        public JsonObject? EditorPatch()
        {
            if (Editor is not { } l) return null;
            var m = new JsonObject { ["type"] = "editor", ["root"] = l.Root, ["name"] = l.Name };
            var any = false;
            if (l.StatusVersion != _edStatus) { _edStatus = l.StatusVersion; m["status"] = l.Status; m["busy"] = l.Busy; any = true; }
            if (l.ImageVersion != _edImage && l.ImageVersion > 0) { _edImage = l.ImageVersion; m["img"] = $"/editor/{l.Id}.png?v={l.ImageVersion}"; any = true; }
            if (l.SceneVersion != _edScene && l.Scene is { } sc) { _edScene = l.SceneVersion; m["nodes"] = sc["nodes"]?.DeepClone(); m["picked"] = l.Picked;
                m["scenes"] = l.NeedsScene ? sc["scenes"]?.DeepClone() : null; any = true; }
            if (l.InspectVersion != _edInspect && l.Inspected is { } ins) { _edInspect = l.InspectVersion; m["insp"] = ins.DeepClone(); any = true; }
            return any ? m : null;
        }

        public void Close()
        {
            ShowEditor(null);
            View?.Dispose();
            View = null;
            _out.Writer.TryComplete();
        }

        public async Task PumpAsync()
        {
            try
            {
                await foreach (var s in _out.Reader.ReadAllAsync())
                    await ws.SendAsync(Encoding.UTF8.GetBytes(s), WebSocketMessageType.Text, true, CancellationToken.None);
            }
            catch (Exception ex) when (ex is WebSocketException or ObjectDisposedException) { }
        }
    }
}
