using System.Globalization;
using System.Text.RegularExpressions;
using TokenChat.Core.Protocol;

namespace TokenChat.Core.Transcript;

/// <summary>An option button. Picking goes through its group, which knows whether picks exclude each other.</summary>
public sealed class OptionPick(string label, string? description, Action<OptionPick> pick) : Bindable
{
    bool _isSelected;

    public string Label { get; } = label;
    public string? Description { get; } = description;
    public bool IsSelected { get => _isSelected; internal set => Set(ref _isSelected, value); }

    public void Pick() => pick(this);

    /// <summary>Multi toggles the one picked; single selects it alone, and a second click clears it.</summary>
    internal static void Choose(IEnumerable<OptionPick> options, OptionPick picked, bool multi)
    {
        var on = !picked.IsSelected;
        if (!multi)
            foreach (var o in options) o.IsSelected = false;
        picked.IsSelected = on;
    }
}

/// <summary>One question of an AskUserQuestion. Its answer is the picked labels, then any typed text, comma-joined.</summary>
public sealed class QuestionPick : Bindable
{
    string _other = "";

    internal QuestionPick(Question q)
    {
        Text = q.Text;
        Header = q.Header;
        MultiSelect = q.MultiSelect;
        Options = q.Options.Select(o => new OptionPick(o.Label, o.Description, Choose)).ToList();
    }

    public string Text { get; }
    public string? Header { get; }
    public bool MultiSelect { get; }
    public IReadOnlyList<OptionPick> Options { get; }

    /// <summary>A typed answer. In a single-select question it replaces the picked option.</summary>
    public string Other
    {
        get => _other;
        set
        {
            if (!Set(ref _other, value ?? "")) return;
            if (!MultiSelect && _other.Trim().Length > 0)
                foreach (var o in Options) o.IsSelected = false;
            Notify(nameof(Answer));
        }
    }

    public string? Answer
    {
        get
        {
            var parts = Options.Where(o => o.IsSelected).Select(o => o.Label).ToList();
            if (Other.Trim() is { Length: > 0 } typed) parts.Add(typed);
            return parts.Count == 0 ? null : string.Join(", ", parts);
        }
    }

    void Choose(OptionPick o)
    {
        OptionPick.Choose(Options, o, MultiSelect);
        if (!MultiSelect && o.IsSelected) Other = "";
        Notify(nameof(Answer));
    }
}

/// <summary>The ▶ asks that close a reply ("▶ 1 Keep the fallback? — yes / drop it"), one button group per ask.
/// It sends "1 yes, 2 drop it", the shape the user would type. Closed once the user sends anything.</summary>
public sealed class OpenBlock : Bindable
{
    static readonly Regex AskLine = new(@"^\s*▶\s*(?<n>\d+)?[.):]?\s*(?<rest>.+?)\s*$");
    bool _isClosed;

    OpenBlock(IEnumerable<(string Number, string Text, string[] Options)> asks) =>
        Asks = asks.Select(a => new OpenAsk(this, a.Number, a.Text, a.Options)).ToList();

    public IReadOnlyList<OpenAsk> Asks { get; }
    public bool CanSend => !IsClosed && Reply is not null;

    public bool IsClosed
    {
        get => _isClosed;
        internal set { if (Set(ref _isClosed, value)) Notify(nameof(CanSend)); }
    }

    /// <summary>"1 yes, 2 drop it" over the asks with a pick; null while none has one.</summary>
    public string? Reply
    {
        get
        {
            var picks = Asks.Where(a => a.Picked is not null).Select(a => $"{a.Number} {a.Picked!.Label}").ToList();
            return picks.Count == 0 ? null : string.Join(", ", picks);
        }
    }

    /// <summary>▶ lines outside code fences with options after an em dash, split on " / ". An ask without
    /// options keeps its number but gets no buttons; it needs a typed answer.</summary>
    public static OpenBlock? Parse(string markdown)
    {
        var asks = new List<(string, string, string[])>();
        var (fenced, seen) = (false, 0);
        foreach (var line in markdown.Split('\n'))
        {
            if (line.TrimStart().StartsWith("```", StringComparison.Ordinal)) fenced = !fenced;
            if (fenced || AskLine.Match(line) is not { Success: true } m) continue;
            seen++;
            var rest = m.Groups["rest"].Value;
            var dash = rest.LastIndexOf('—');
            if (dash < 0) continue;
            var options = rest[(dash + 1)..].Split(" / ", StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
            if (options.Length == 0) continue;
            var number = m.Groups["n"].Success ? m.Groups["n"].Value : seen.ToString(CultureInfo.InvariantCulture);
            asks.Add((number, rest[..dash].Trim(), options));
        }
        return asks.Count == 0 ? null : new OpenBlock(asks);
    }

    internal void Changed()
    {
        Notify(nameof(Reply));
        Notify(nameof(CanSend));
    }
}

public sealed class OpenAsk : Bindable
{
    readonly OpenBlock _block;

    internal OpenAsk(OpenBlock block, string number, string text, IEnumerable<string> options)
    {
        _block = block;
        Number = number;
        Text = text;
        Options = options.Select(o => new OptionPick(o, null, Choose)).ToList();
    }

    public string Number { get; }
    public string Text { get; }
    public IReadOnlyList<OptionPick> Options { get; }
    public OptionPick? Picked => Options.FirstOrDefault(o => o.IsSelected);

    void Choose(OptionPick o)
    {
        if (_block.IsClosed) return;
        OptionPick.Choose(Options, o, multi: false);
        _block.Changed();
    }
}
