using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text.Json;
using TokenChat.Core;

namespace TokenChat.App;

/// <summary>One TokenChat per user. The first instance holds the mutex and serves a pipe; a later launch (the widget's
/// Enter, --watch, the parked tab) sends its <see cref="LaunchRequest"/> there and exits, so "open this session" lands
/// as a tab in the window that is already up.</summary>
static class SingleInstance
{
    static readonly string Name = "TokenChat-" + Environment.UserName;
    static Mutex? _mutex;

    /// <summary>True for the first instance. Held for the life of the process.</summary>
    public static bool Claim()
    {
        _mutex = new Mutex(true, @"Local\" + Name, out var first);
        return first;
    }

    /// <summary>Hands the request to the running instance; false if it did not answer within 3 s (still starting,
    /// or hung), and the caller carries on as a window of its own: a second window beats none.</summary>
    public static bool Forward(LaunchRequest request)
    {
        try
        {
            using var pipe = new NamedPipeClientStream(".", Name, PipeDirection.Out, PipeOptions.CurrentUserOnly);
            pipe.Connect(3000);
            // This process was launched by whatever the user just pressed a key in, so it holds the foreground right;
            // pass it on, or the running window can only flash its taskbar button.
            AllowSetForegroundWindow(AsfwAny);
            using var writer = new StreamWriter(pipe);
            writer.WriteLine(JsonSerializer.Serialize(request));
            return true;
        }
        catch (Exception ex) when (ex is TimeoutException or IOException) { return false; }
    }

    /// <summary>Serves requests until the process ends. <paramref name="onRequest"/> runs on the pipe thread.</summary>
    public static async Task ServeAsync(Action<LaunchRequest> onRequest)
    {
        while (true)
        {
            await using var pipe = new NamedPipeServerStream(Name, PipeDirection.In, 1, PipeTransmissionMode.Byte,
                PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            await pipe.WaitForConnectionAsync();
            using var reader = new StreamReader(pipe);
            LaunchRequest? request = null;
            try { if (await reader.ReadLineAsync() is { } line) request = JsonSerializer.Deserialize<LaunchRequest>(line); }
            catch (Exception ex) when (ex is JsonException or IOException) { } // a broken sender; serve the next one
            if (request is not null) onRequest(request);
        }
    }

    const int AsfwAny = -1;

    [DllImport("user32.dll")]
    static extern bool AllowSetForegroundWindow(int processId);
}
