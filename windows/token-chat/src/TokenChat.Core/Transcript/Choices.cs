using System.Globalization;
using System.Text.RegularExpressions;
using TokenChat.Core.Protocol;

namespace TokenChat.Core.Transcript;

/// <summary>An option button. Picking goes through its group, which knows whether picks exclude each other.</summary>
public sealed class OptionPick(string label, string? description, Action<OptionPick> pick, bool multi = false) : Bindable
{
    static readonly Regex Recommended = new(@"\s*\(recommended\)\s*$", RegexOptions.IgnoreCase);
    bool _isSelected;

    /// <summary>As given: what an AskUserQuestion answer carries.</summary>
    public string Label { get; } = label;
    /// <summary>The label without a trailing "(Recommended)", which shows as a tag instead.</summary>
    public string Caption { get; } = Recommended.Replace(label, "");
    public bool IsRecommended { get; } = Recommended.IsMatch(label);
    /// <summary>Picks in its group don't exclude each other: a checkbox, not a radio.</summary>
    public bool IsMulti { get; } = multi;
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
    bool _isCurrent;

    internal QuestionPick(Question q, int number)
    {
        Text = q.Text;
        Header = q.Header;
        MultiSelect = q.MultiSelect;
        Title = q.Header is { Length: > 0 } h ? h : $"Q{number}";
        Options = q.Options.Select(o => new OptionPick(o.Label, o.Description, Choose, q.MultiSelect)).ToList();
    }

    public string Text { get; }
    public string? Header { get; }
    public bool MultiSelect { get; }
    /// <summary>Its tab's name: the header, else "Q2".</summary>
    public string Title { get; }
    public IReadOnlyList<OptionPick> Options { get; }
    public bool IsAnswered => Answer is not null;
    /// <summary>The tab showing while the card is tabbed.</summary>
    public bool IsCurrent { get => _isCurrent; internal set => Set(ref _isCurrent, value); }

    /// <summary>A typed answer. In a single-select question it replaces the picked option.</summary>
    public string Other
    {
        get => _other;
        set
        {
            if (!Set(ref _other, value ?? "")) return;
            if (!MultiSelect && _other.Trim().Length > 0)
                foreach (var o in Options) o.IsSelected = false;
            Answered();
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
        Answered();
    }

    void Answered()
    {
        Notify(nameof(Answer));
        Notify(nameof(IsAnswered));
    }
}

/// <summary>The ▶ asks that close a reply ("▶ 1 Keep the fallback? — yes / drop it"), one button group per ask.
/// It sends "1 yes, 2 drop it", the shape the user would type. Closed once the user sends anything.</summary>
public sealed class OpenBlock : Bindable
{
    static readonly Regex AskLine = new(@"^\s*▶\s*(?<n>\d+)?[.):]?\s*(?<rest>.+?)\s*$");
    bool _isClosed;

    OpenBlock(string body, IEnumerable<(string Number, string Text, string[] Options)> asks)
    {
        Body = body;
        Asks = asks.Select(a => new OpenAsk(this, a.Number, a.Text, a.Options)).ToList();
    }

    /// <summary>The markdown without its ▶ lines: the bar is where the asks show.</summary>
    public string Body { get; }
    public IReadOnlyList<OpenAsk> Asks { get; }
    public bool CanSend => !IsClosed && Reply is not null;

    public bool IsClosed
    {
        get => _isClosed;
        internal set { if (Set(ref _isClosed, value)) Notify(nameof(CanSend)); }
    }

    /// <summary>"1 yes, 2 drop it" over the asks with an answer; null while none has one.</summary>
    public string? Reply
    {
        get
        {
            var picks = Asks.Where(a => a.Answer is not null).Select(a => $"{a.Number} {a.Answer}").ToList();
            return picks.Count == 0 ? null : string.Join(", ", picks);
        }
    }

    /// <summary>▶ lines outside code fences, options after an em dash split on " / ". An ask without options
    /// keeps its number but gets no buttons; it needs a typed answer.</summary>
    public static OpenBlock? Parse(string markdown)
    {
        var asks = new List<(string, string, string[])>();
        var kept = new List<string>();
        var (fenced, seen) = (false, 0);
        foreach (var line in markdown.Split('\n'))
        {
            if (line.TrimStart().StartsWith("```", StringComparison.Ordinal)) fenced = !fenced;
            if (fenced || AskLine.Match(line) is not { Success: true } m)
            {
                kept.Add(line);
                continue;
            }
            seen++;
            var rest = m.Groups["rest"].Value;
            var dash = rest.LastIndexOf('—');
            var options = dash < 0 ? [] : rest[(dash + 1)..].Split(" / ", StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
            var number = m.Groups["n"].Success ? m.Groups["n"].Value : seen.ToString(CultureInfo.InvariantCulture);
            asks.Add((number, (options.Length == 0 ? rest : rest[..dash]).Trim(), options));
        }
        return asks.Count == 0 ? null : new OpenBlock(string.Join('\n', kept).TrimEnd(), asks);
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
    string _other = "";

    internal OpenAsk(OpenBlock block, string number, string text, IEnumerable<string> options)
    {
        _block = block;
        Number = number;
        Text = text;
        var q = text.IndexOf('?');
        Lead = q < 0 ? text : text[..(q + 1)];
        Rest = q < 0 ? "" : text[(q + 1)..].Trim();
        Options = options.Select(o => new OptionPick(o, null, Choose)).ToList();
    }

    public string Number { get; }
    public string Text { get; }
    /// <summary>Text through its first question mark, the ask itself; <see cref="Rest"/> is what follows, shown dimmer.</summary>
    public string Lead { get; }
    public string Rest { get; }
    public IReadOnlyList<OptionPick> Options { get; }
    public OptionPick? Picked => Options.FirstOrDefault(o => o.IsSelected);

    /// <summary>A typed answer. It replaces the picked option, and picking one clears it.</summary>
    public string Other
    {
        get => _other;
        set
        {
            if (_block.IsClosed || !Set(ref _other, value ?? "")) return;
            if (_other.Trim().Length > 0)
                foreach (var o in Options) o.IsSelected = false;
            _block.Changed();
        }
    }

    /// <summary>What the reply says for this ask: the typed text, else the picked caption.</summary>
    public string? Answer => Other.Trim() is { Length: > 0 } typed ? typed : Picked?.Caption;

    void Choose(OptionPick o)
    {
        if (_block.IsClosed) return;
        OptionPick.Choose(Options, o, multi: false);
        if (o.IsSelected) Other = "";
        _block.Changed();
    }
}
