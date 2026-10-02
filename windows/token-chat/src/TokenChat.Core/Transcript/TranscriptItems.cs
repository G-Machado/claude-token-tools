using System.ComponentModel;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text;
using TokenChat.Core.Protocol;

namespace TokenChat.Core.Transcript;

/// <summary>Change notification for the transcript's view models.</summary>
public abstract class Bindable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Notify(name);
        return true;
    }

    protected void Notify(string? name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

/// <summary>One row of a tab's transcript. Created and mutated on one thread (the UI's).</summary>
public abstract class TranscriptItem : Bindable;

public sealed class UserItem(string text, IReadOnlyList<string>? files = null) : TranscriptItem
{
    public string Text { get; } = text;
    /// <summary>Attachment labels ("shot.png · ≈2.6k"), shown under the text.</summary>
    public IReadOnlyList<string> Files { get; } = files ?? [];
    public bool HasFiles => Files.Count > 0;
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

public sealed class AssistantTextItem : StreamedItem
{
    OpenBlock? _open;

    public AssistantTextItem() => PropertyChanged += (_, e) => { if (e.PropertyName == nameof(Text)) Notify(nameof(Body)); };

    /// <summary>The reply's ▶ asks as buttons; parsed once the text stops streaming, null if it has none.</summary>
    public OpenBlock? Open { get => _open; internal set { if (Set(ref _open, value)) Notify(nameof(Body)); } }

    /// <summary>What the markdown shows: the reply without its ▶ lines once the bar has them, so each ask shows once.</summary>
    public string Body => _open?.Body ?? Text;
}

public sealed class ThinkingItem : StreamedItem;

public sealed class ToolUseItem(string toolName, string? toolUseId) : TranscriptItem
{
    internal readonly StringBuilder InputJson = new();
    string _summary = "";
    string? _result;
    int _resultLines;
    bool _isError, _isInterrupted;

    public string ToolName { get; } = toolName;
    public string? ToolUseId { get; } = toolUseId;
    public string Summary { get => _summary; internal set => Set(ref _summary, value); }
    /// <summary>The first lines of the tool result; null until it arrives.</summary>
    public string? Result { get => _result; internal set => Set(ref _result, value); }
    public int ResultLines { get => _resultLines; internal set => Set(ref _resultLines, value); }
    public bool IsError { get => _isError; internal set => Set(ref _isError, value); }
    /// <summary>The turn ended with no result for it: stopped mid-run.</summary>
    public bool IsInterrupted { get => _isInterrupted; internal set => Set(ref _isInterrupted, value); }
}

/// <summary>Cancelled: the turn ended (stopped) before it was decided.</summary>
public enum PermissionState { Pending, Allowed, AllowedForSession, Denied, Cancelled }

public sealed class PermissionItem(PermissionRequest request, string summary) : TranscriptItem
{
    PermissionState _state;

    public PermissionRequest Request { get; } = request;
    public string ToolName => Request.ToolName;
    public string Summary { get; } = summary;
    public PermissionState State { get => _state; set => Set(ref _state, value); }
    /// <summary>What an Edit, MultiEdit or Write would change; null for other tools.</summary>
    public IReadOnlyList<DiffLine>? Diff { get; init; }
    /// <summary>What the diff is against or how it applies: new file, overwrites the file, every occurrence.</summary>
    public string? DiffNote { get; init; }
    /// <summary>Sent with an allow-for-session; null hides the button.</summary>
    public System.Text.Json.Nodes.JsonArray? SessionRules { get; init; }
    public string? SessionLabel { get; init; }
}

public enum QuestionState { Pending, Answered, Declined, Cancelled }

/// <summary>An AskUserQuestion: pick an option per question, or type an answer, then submit.</summary>
public sealed class QuestionItem : TranscriptItem, ITabbedQuestions
{
    QuestionState _state;
    QuestionPick? _current;
    bool _isTabbed;

    public QuestionItem(QuestionRequest request)
    {
        Request = request;
        Questions = request.Questions.Select((q, i) => new QuestionPick(q, i + 1)).ToList();
        foreach (var q in Questions) q.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(QuestionPick.Answer)) Notify(nameof(CanSubmit)); };
        Current = Questions.FirstOrDefault();
    }

    public QuestionRequest Request { get; }
    public IReadOnlyList<QuestionPick> Questions { get; }

    /// <summary>The view's call: the questions stacked don't fit the window, so the card shows one at a time as tabs.</summary>
    public bool IsTabbed { get => _isTabbed; set => Set(ref _isTabbed, value); }

    public QuestionPick? Current
    {
        get => _current;
        set
        {
            if (_current == value) return;
            if (_current is not null) _current.IsCurrent = false;
            _current = value;
            if (value is not null) value.IsCurrent = true;
            Notify(nameof(Current));
        }
    }

    /// <summary>After a pick answers a single-select question, a tabbed card moves to the next one still unanswered.</summary>
    public void AdvanceFrom(QuestionPick picked)
    {
        if (!IsTabbed || picked.MultiSelect || !picked.IsAnswered) return;
        if (Tabs.NextUnanswered(Questions, picked, q => q.IsAnswered) is { } next) Current = next;
    }
    public bool CanSubmit => State == QuestionState.Pending && Questions.All(q => q.Answer is not null);
    /// <summary>A lone single-select question is answered by its first click.</summary>
    public bool AnswersOnPick => Questions is [{ MultiSelect: false }];
    public string? Outcome => State switch
    {
        QuestionState.Answered => "✓ " + string.Join("  ·  ", Questions.Select(q => q.Header is { Length: > 0 } h ? $"{h}: {q.Answer}" : q.Answer)),
        QuestionState.Declined => "declined",
        QuestionState.Cancelled => "cancelled",
        _ => null,
    };

    public QuestionState State
    {
        get => _state;
        set
        {
            if (!Set(ref _state, value)) return;
            Notify(nameof(CanSubmit));
            Notify(nameof(Outcome));
        }
    }

    /// <summary>Question text → answer, as <c>ClaudeSession.AnswerAsync</c> takes it.</summary>
    public Dictionary<string, string> Answers() => Questions.Where(q => q.Answer is not null).ToDictionary(q => q.Text, q => q.Answer!);
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
    /// <summary>Ended by an interrupt; the CLI reports that as error_during_execution, which is no error to the user.</summary>
    public bool IsStopped { get; init; }
    public bool IsError => Result.IsError && !IsStopped;
    public string? Detail => IsError ? Result.Text : null;

    public string Summary
    {
        get
        {
            var u = Result.Usage;
            var head = IsStopped ? "stopped" : Result.IsError ? Result.Subtype : "done";
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
