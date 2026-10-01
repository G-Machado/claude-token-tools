using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text;
using TokenChat.Core.Protocol;

namespace TokenChat.Core.Transcript;

/// <summary>One row of a tab's transcript. Created and mutated on one thread (the UI's).</summary>
public abstract class TranscriptItem : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
        return true;
    }
}

public sealed class UserItem(string text) : TranscriptItem
{
    public string Text { get; } = text;
}

/// <summary>Text that arrives as deltas. Deltas land in a buffer and <see cref="TranscriptProjector.Flush"/>
/// publishes it, so whoever calls Flush sets the render rate.</summary>
public abstract class StreamedItem : TranscriptItem
{
    readonly StringBuilder _buffer = new();
    string _text = "";
    bool _isStreaming = true;

    public string Text { get => _text; private set => Set(ref _text, value); }
    public bool IsStreaming { get => _isStreaming; internal set => Set(ref _isStreaming, value); }

    internal void Append(string s) => _buffer.Append(s);

    /// <summary>Append-only, so a length change is a content change.</summary>
    internal void Flush()
    {
        if (_buffer.Length != _text.Length) Text = _buffer.ToString();
    }
}

public sealed class AssistantTextItem : StreamedItem;

public sealed class ThinkingItem : StreamedItem;

public sealed class ToolUseItem(string toolName, string? toolUseId) : TranscriptItem
{
    internal readonly StringBuilder InputJson = new();
    string _summary = "";
    string? _result;
    int _resultLines;
    bool _isError;

    public string ToolName { get; } = toolName;
    public string? ToolUseId { get; } = toolUseId;
    public string Summary { get => _summary; internal set => Set(ref _summary, value); }
    /// <summary>The first lines of the tool result; null until it arrives.</summary>
    public string? Result { get => _result; internal set => Set(ref _result, value); }
    public int ResultLines { get => _resultLines; internal set => Set(ref _resultLines, value); }
    public bool IsError { get => _isError; internal set => Set(ref _isError, value); }
}

public enum PermissionState { Pending, Allowed, Denied }

public sealed class PermissionItem(PermissionRequest request, string summary) : TranscriptItem
{
    PermissionState _state;

    public PermissionRequest Request { get; } = request;
    public string ToolName => Request.ToolName;
    public string Summary { get; } = summary;
    public PermissionState State { get => _state; set => Set(ref _state, value); }
}

public enum NoteKind { Info, Warning, Error, Command, Compact }

public sealed class NoteItem(NoteKind kind, string text, string? detail = null) : TranscriptItem
{
    public NoteKind Kind { get; } = kind;
    public string Text { get; } = text;
    public string? Detail { get; } = detail;
}

/// <summary>End-of-turn footer built from the result event.</summary>
public sealed class TurnItem(ResultEvent result) : TranscriptItem
{
    public ResultEvent Result { get; } = result;
    public bool IsError => Result.IsError;
    public string? Detail => Result.IsError ? Result.Text : null;

    public string Summary
    {
        get
        {
            var u = Result.Usage;
            var head = Result.IsError ? Result.Subtype : "done";
            return string.Create(CultureInfo.InvariantCulture,
                $"{head} · {Result.DurationMs / 1000.0:0.0}s · {Result.NumTurns} steps · in {Tokens.K(u.Input)} · cache r {Tokens.K(u.CacheRead)} w {Tokens.K(u.CacheWrite)} · out {Tokens.K(u.Output)} · ≈${Result.TotalCostUsd:0.00}");
        }
    }
}

public static class Tokens
{
    /// <summary>16900 → "16.9k".</summary>
    public static string K(long n) => n >= 1000
        ? (n / 1000.0).ToString(n >= 100_000 ? "0" : "0.#", CultureInfo.InvariantCulture) + "k"
        : n.ToString(CultureInfo.InvariantCulture);
}
