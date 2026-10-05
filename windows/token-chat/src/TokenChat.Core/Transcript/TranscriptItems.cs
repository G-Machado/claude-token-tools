using System.Collections.ObjectModel;
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
public abstract class TranscriptItem : Bindable
{
    bool _isRenewal;

    /// <summary>Part of an extension-mark renewal turn (a poke): drawn dimmed.</summary>
    public bool IsRenewal { get => _isRenewal; set => Set(ref _isRenewal, value); }
}

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

    /// <summary>What the markdown shows: the reply without its ▶ lines once the bar has them, so each ask shows once,
    /// tidied for MdXaml (<see cref="ReplyText.Tidy"/>).</summary>
    public string Body => ReplyText.Tidy(_open?.Body ?? Text);
}

public sealed class ThinkingItem : StreamedItem;

public sealed class ToolUseItem(string toolName, string? toolUseId) : TranscriptItem
{
    internal readonly StringBuilder InputJson = new();
    string _summary = "";
    ToolHeadline _line = new(toolName, "");
    string _outcome = "";
    string? _result;
    int _resultLines;
    long? _tokens;
    bool _isError, _isInterrupted, _tokensExact;

    public string ToolName { get; } = toolName;
    public string? ToolUseId { get; } = toolUseId;
    public string Summary { get => _summary; internal set => Set(ref _summary, value); }
    /// <summary>The call as a phrase; just the tool's name until its input is in.</summary>
    public ToolHeadline Line { get => _line; internal set => Set(ref _line, value); }
    /// <summary>What came back, in the tool's terms ("lines 95–130", "3 hits · 2 files", "+4 −1"); empty until it does.</summary>
    public string Outcome { get => _outcome; internal set => Set(ref _outcome, value); }
    /// <summary>What the result added to the window, in tokens; null until it arrives.</summary>
    public long? Tokens { get => _tokens; internal set { if (Set(ref _tokens, value)) { Notify(nameof(TokensText)); Notify(nameof(IsBig)); } } }
    /// <summary>Measured: the next request's growth was this call's alone. False: estimated from the result's size,
    /// or this call's share (by size) of a parallel batch's growth.</summary>
    public bool TokensExact { get => _tokensExact; internal set { if (Set(ref _tokensExact, value)) Notify(nameof(TokensText)); } }
    public string TokensText => _tokens is { } n ? ToolText.Cost(n, _tokensExact) : "";
    public bool IsBig => _tokens >= ToolText.BigCall;
    internal int ResultChars;
    internal System.Text.Json.Nodes.JsonObject? Input;
    /// <summary>Only looks (read, search, read-only shell): a second one next to it folds both into a run.</summary>
    internal bool Looks;
    /// <summary>The first lines of the tool result; null until it arrives.</summary>
    public string? Result { get => _result; internal set => Set(ref _result, value); }
    public int ResultLines { get => _resultLines; internal set => Set(ref _resultLines, value); }
    public bool IsError { get => _isError; internal set => Set(ref _isError, value); }
    /// <summary>The turn ended with no result for it: stopped mid-run.</summary>
    public bool IsInterrupted { get => _isInterrupted; internal set => Set(ref _isInterrupted, value); }
}

/// <summary>A run of calls that only look (reads, searches, read-only shell) folded into one row, with the
/// thinking between them. Anything else, an edit, text, a prompt, ends the run.</summary>
public sealed class ToolGroupItem : TranscriptItem
{
    static readonly string[] Derived = [nameof(Title), nameof(Counts), nameof(CountsAside), nameof(TokensText), nameof(IsBig), nameof(IsRunning), nameof(HasFailed), nameof(State)];
    string? _caption;
    bool _narrated;

    public ObservableCollection<TranscriptItem> Children { get; } = [];
    public IEnumerable<ToolUseItem> Tools => Children.OfType<ToolUseItem>();
    /// <summary>Why the run happened, from the thinking before it; null when there was none to read.</summary>
    public string? Caption { get => _caption; internal set { if (Set(ref _caption, value)) Notify(nameof(Title)); } }
    /// <summary>Reply text sits right above the run and already says why, so the run is titled by its shape alone.</summary>
    public bool Narrated { get => _narrated; internal set { if (Set(ref _narrated, value)) Changed(); } }
    public string Title => Narrated ? Counts : Caption ?? ToolText.Subjects(Tools);
    public string Counts => ToolText.Counts(Tools);
    /// <summary>The shape beside the title; empty when the title already is the shape.</summary>
    public string CountsAside => Narrated ? "" : Counts;
    public string TokensText => Tools.Where(t => t.Tokens is not null).ToList() is { Count: > 0 } priced
        ? ToolText.Cost(priced.Sum(t => t.Tokens!.Value), priced.All(t => t.TokensExact)) : "";
    public bool IsBig => Tools.Sum(t => t.Tokens ?? 0) >= ToolText.BigRun || Tools.Any(t => t.IsBig);
    public bool IsRunning => Tools.Any(t => t.Result is null && !t.IsInterrupted);
    public int Failed => Tools.Count(t => t.IsError);
    public bool HasFailed => Failed > 0;
    public string State => IsRunning ? "running…" : Failed > 0 ? $"{Failed} failed" : "";

    internal void Add(TranscriptItem item)
    {
        Children.Add(item);
        if (item is ToolUseItem tool) tool.PropertyChanged += (_, _) => Changed();
        Changed();
    }

    void Changed()
    {
        foreach (var name in Derived) Notify(name);
    }
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
public sealed class QuestionItem : TranscriptItem
{
    QuestionState _state;

    public QuestionItem(QuestionRequest request)
    {
        Request = request;
        Questions = request.Questions.Select((q, i) => new QuestionPick(q, i + 1)).ToList();
        foreach (var q in Questions) q.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(QuestionPick.Answer)) Notify(nameof(CanSubmit)); };
        if (Questions.Count > 0) Questions[0].IsExpanded = true;
    }

    public QuestionRequest Request { get; }
    public IReadOnlyList<QuestionPick> Questions { get; }

    /// <summary>A pick that answers a single-select question folds it and opens the next one still unanswered. A
    /// multi-select one stays open for more picks, until <paramref name="done"/> (Enter in its box) says it is finished.</summary>
    public void AdvanceFrom(QuestionPick picked, bool done = false)
    {
        if ((picked.MultiSelect && !done) || !picked.IsAnswered) return;
        Fold.Advance(Questions, picked);
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

/// <summary>One button on a <see cref="CardItem"/>: what it says, and the key the tab acts on.</summary>
public sealed record CardAction(string Label, string Key, bool Primary = false);

/// <summary>A card the app raises itself, with buttons: a block token-block.sh put on the window, the auto-handoff
/// offer. Open until one button is taken; then its outcome replaces the buttons.</summary>
public sealed class CardItem(string kind, string title, string text, IReadOnlyList<CardAction> actions, string? payload = null)
    : TranscriptItem
{
    string? _outcome;

    /// <summary>"block" or "handoff"; what the tab dispatches the key on.</summary>
    public string Kind { get; } = kind;
    public string Title { get; } = title;
    public string Text { get; } = text;
    public IReadOnlyList<CardAction> Actions { get; } = actions;
    /// <summary>A block: the prompt it refused, which "lift" sends again.</summary>
    public string? Payload { get; } = payload;
    public string? Outcome { get => _outcome; set { if (Set(ref _outcome, value)) Notify(nameof(IsOpen)); } }
    public bool IsOpen => Outcome is null;
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

    /// <summary>The turn in plain words: "done in 3m 38s · 24 steps · Claude wrote 15.1k tokens · re-read 1.46M from
    /// cache · added 76.2k · ≈$1.20". Added is what the window grew by this turn: cache writes plus uncached input.</summary>
    public string Summary
    {
        get
        {
            var u = Result.Usage;
            var head = IsStopped ? "stopped" : Result.IsError ? Result.Subtype : "done";
            var s = Result.DurationMs / 1000.0;
            var took = s < 60 ? s.ToString("0.0", CultureInfo.InvariantCulture) + "s" : $"{(int)s / 60}m {(int)s % 60}s";
            var steps = Result.NumTurns == 1 ? "1 step" : $"{Result.NumTurns} steps";
            return string.Create(CultureInfo.InvariantCulture,
                $"{head} in {took} · {steps} · Claude wrote {Tokens.Km(u.Output)} tokens · re-read {Tokens.Km(u.CacheRead)} from cache · added {Tokens.Km(u.CacheWrite + u.Input)} · ≈${Result.TotalCostUsd:0.00}");
        }
    }
}

public static class Tokens
{
    /// <summary>16900 → "16.9k".</summary>
    public static string K(long n) => n >= 1000
        ? (n / 1000.0).ToString(n >= 100_000 ? "0" : "0.#", CultureInfo.InvariantCulture) + "k"
        : n.ToString(CultureInfo.InvariantCulture);

    /// <summary><see cref="K"/>, but millions as "1.46M".</summary>
    public static string Km(long n) => n >= 1_000_000
        ? (n / 1_000_000.0).ToString("0.##", CultureInfo.InvariantCulture) + "M"
        : K(n);
}
