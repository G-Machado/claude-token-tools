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
        app.MapPost("/pair", (Func<HttpContext, Task<IResult>>)Pair);
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

    static string Page()
    {
        using var s = typeof(RemoteServer).Assembly.GetManifestResourceStream("remote.index.html")!;
        return new StreamReader(s).ReadToEnd();
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
        var tab = _tabIds.FirstOrDefault(p => p.Value == (int?)op["tab"]).Key;
        if (tab is null || !tabs.Contains(tab)) return;
        var item = op["id"] is { } id ? c.View?.Find((int)id) : null;
        try
        {
            switch ((string?)op["op"])
            {
                case "select":
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
        }
    }

    JsonObject TabList() => new()
    {
        ["type"] = "tabs",
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

        public void Close()
        {
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
