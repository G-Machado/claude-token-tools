using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Text;

namespace TokenChat.Core;

/// <summary>Line-oriented pipe to a claude process. Tests replace it with a fixture replay.</summary>
public interface IClaudeTransport : IAsyncDisposable
{
    IAsyncEnumerable<string> ReadLinesAsync(CancellationToken ct);
    Task WriteLineAsync(string line, CancellationToken ct);
}

/// <summary>A hidden claude.exe with redirected stdio. Disposing closes stdin, then kills the tree after 3 s.</summary>
public sealed class ProcessTransport : IClaudeTransport
{
    readonly Process _process;
    readonly SemaphoreSlim _writeLock = new(1, 1);

    public int ProcessId => _process.Id;

    /// <summary>Raised on the stderr reader thread.</summary>
    public event Action<string>? StderrLine;

    public ProcessTransport(LaunchSpec spec)
    {
        var psi = new ProcessStartInfo(spec.Exe)
        {
            WorkingDirectory = spec.WorkingDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false), // a BOM would corrupt the first JSON line
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var a in spec.Arguments) psi.ArgumentList.Add(a);
        foreach (var k in psi.Environment.Keys.Where(ClaudeLauncher.IsSessionMarker).ToList()) psi.Environment.Remove(k);
        foreach (var (k, v) in spec.Environment) psi.Environment[k] = v;
        _process = Process.Start(psi) ?? throw new InvalidOperationException("claude.exe did not start: " + spec.Exe);
        _process.ErrorDataReceived += (_, e) => { if (e.Data is not null) StderrLine?.Invoke(e.Data); };
        _process.BeginErrorReadLine();
    }

    public async IAsyncEnumerable<string> ReadLinesAsync([EnumeratorCancellation] CancellationToken ct)
    {
        while (await _process.StandardOutput.ReadLineAsync(ct) is { } line)
            if (line.Length > 0) yield return line;
    }

    public async Task WriteLineAsync(string line, CancellationToken ct)
    {
        await _writeLock.WaitAsync(ct);
        try
        {
            await _process.StandardInput.WriteAsync((line + "\n").AsMemory(), ct);
            await _process.StandardInput.FlushAsync(ct);
        }
        finally { _writeLock.Release(); }
    }

    public async ValueTask DisposeAsync()
    {
        try { _process.StandardInput.Close(); } catch (IOException) { }
        using var grace = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        try { await _process.WaitForExitAsync(grace.Token); }
        catch (OperationCanceledException)
        {
            try { _process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
        }
        _process.Dispose();
        _writeLock.Dispose();
    }
}
