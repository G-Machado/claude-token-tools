using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Text.Json;

namespace TokenChat.Core;

/// <summary>
/// Dictation through voice-nav (~/source/repos/voice-nav, or VOICENAV_HOME). Its named pipe takes
/// start/stop/cancel and hands the transcript back instead of typing it (voicenav/ipc.py). With no
/// voice-nav running this starts one with --serve (no hotkeys, no widget; it exits when this app
/// disconnects) and waits out the Whisper load. One mic, so one link for the whole app.
/// </summary>
[System.Runtime.Versioning.SupportedOSPlatform("windows")] // message-mode pipes
public sealed class VoiceLink
{
    public static VoiceLink Shared { get; } = new();

    public enum State { Off, Starting, Recording, Transcribing }

    const string PipeName = "voicenav";
    const string MutexName = @"Local\voice-nav-single-instance"; // voicenav/__main__.py single_instance
    const int LoadTimeoutMs = 90_000; // the pipe opens only once Whisper is loaded and the mic is open
    const int TranscribeTimeoutMs = 60_000; // a 2 s hold transcribes in 0.7 s; a minute of quiet is a dead worker

    NamedPipeClientStream? _pipe;
    bool _stopEarly; // released or clicked off while still starting
    int _utterance; // which transcribing the watchdog is waiting on

    public State Current { get; private set; }

    /// <summary>State changes, with voice-nav's reason when it has one. Raised on a background thread.</summary>
    public event Action<State, string?>? StateChanged;

    /// <summary>A finished transcript. Raised on a background thread.</summary>
    public event Action<string>? Text;

    /// <summary>The words so far while recording (voice-nav's live preview; display only, the final
    /// pass is what arrives as <see cref="Text"/>). Raised on a background thread.</summary>
    public event Action<string>? Partial;

    static string Root => Environment.GetEnvironmentVariable("VOICENAV_HOME")
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "source", "repos", "voice-nav");

    public async Task StartAsync(string lang)
    {
        if (Current != State.Off) return;
        _stopEarly = false;
        Set(State.Starting, null);
        try
        {
            await EnsureConnectedAsync();
            if (_stopEarly)
            {
                Set(State.Off, "released before voice-nav was ready");
                return;
            }
            await SendAsync(new { cmd = "start", lang });
        }
        catch (Exception e)
        {
            Drop();
            Set(State.Off, e.Message);
        }
    }

    /// <summary>End the recording and transcribe it; while still starting, don't record at all.</summary>
    public Task StopAsync() => End("stop");

    public Task CancelAsync() => End("cancel");

    async Task End(string cmd)
    {
        if (Current == State.Starting) _stopEarly = true;
        if (Current != State.Recording) return;
        try { await SendAsync(new { cmd }); }
        catch (Exception e)
        {
            Drop();
            Set(State.Off, e.Message);
        }
    }

    async Task EnsureConnectedAsync()
    {
        if (_pipe is { IsConnected: true }) return;
        Drop();
        var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
        try
        {
            try { await pipe.ConnectAsync(300); }
            catch (TimeoutException)
            {
                // A voice-nav already up (the user's own, or one still loading) gets waited for, not doubled.
                if (!System.Threading.Mutex.TryOpenExisting(MutexName, out var held)) Launch();
                else held.Dispose();
                try { await pipe.ConnectAsync(LoadTimeoutMs); }
                catch (TimeoutException)
                {
                    throw new TimeoutException("voice-nav didn't open its pipe - an older copy running? its serve.log says why");
                }
            }
            pipe.ReadMode = PipeTransmissionMode.Message;
        }
        catch
        {
            pipe.Dispose();
            throw;
        }
        _pipe = pipe;
        _ = ReadLoopAsync(pipe);
    }

    static void Launch()
    {
        var exe = Path.Combine(Root, ".venv", "Scripts", "pythonw.exe");
        if (!File.Exists(exe)) throw new FileNotFoundException($"voice-nav not found: {exe} (set VOICENAV_HOME)");
        Process.Start(new ProcessStartInfo(exe, "-m voicenav --serve") { WorkingDirectory = Root, UseShellExecute = false })?.Dispose();
    }

    async Task SendAsync(object msg)
    {
        var pipe = _pipe ?? throw new IOException("voice-nav isn't connected");
        await pipe.WriteAsync(JsonSerializer.SerializeToUtf8Bytes(msg)); // one write = one pipe message
        await pipe.FlushAsync();
    }

    async Task ReadLoopAsync(NamedPipeClientStream pipe)
    {
        var buffer = new byte[4096];
        var message = new MemoryStream();
        try
        {
            while (true)
            {
                var n = await pipe.ReadAsync(buffer);
                if (n == 0) break;
                message.Write(buffer, 0, n);
                if (!pipe.IsMessageComplete) continue;
                Handle(message.ToArray());
                message.SetLength(0);
            }
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException or JsonException) { }
        if (_pipe != pipe) return;
        Drop();
        if (Current != State.Off) Set(State.Off, "voice-nav closed");
    }

    void Handle(byte[] bytes)
    {
        using var doc = JsonDocument.Parse(bytes);
        var root = doc.RootElement;
        string? Str(string name) =>
            root.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        switch (Str("event"))
        {
            case "partial":
                Partial?.Invoke(Str("text") ?? "");
                break;
            case "text":
                Text?.Invoke(Str("text") ?? "");
                break;
            case "cancelled":
                Set(State.Off, Str("detail"));
                break;
            case "error":
                Set(Current, Str("detail"));
                break;
            case "status":
                switch (Str("state"))
                {
                    case "listening": Set(State.Recording, null); break;
                    case "transcribing":
                        Set(State.Transcribing, null);
                        _ = WatchTranscribingAsync(++_utterance);
                        break;
                    case "idle": Set(State.Off, Str("detail")); break;
                }
                break;
        }
    }

    /// <summary>voice-nav's worker thread can die mid-transcript and leave the pipe open (it did once,
    /// on a TypeError), which would hold the button on "…" forever. Dropping the pipe ends a --serve
    /// copy, so the next press starts a fresh one.</summary>
    async Task WatchTranscribingAsync(int utterance)
    {
        await Task.Delay(TranscribeTimeoutMs);
        if (utterance != _utterance || Current != State.Transcribing) return;
        Drop();
        Set(State.Off, "voice-nav stopped answering - its serve.log says why");
    }

    void Drop()
    {
        var pipe = _pipe;
        _pipe = null;
        pipe?.Dispose();
    }

    void Set(State state, string? detail)
    {
        Current = state;
        StateChanged?.Invoke(state, detail);
    }
}
