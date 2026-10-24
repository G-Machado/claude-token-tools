using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using TokenChat.Core;
using TokenChat.Core.Transcript;

namespace TokenChat.App;

public partial class SessionView : UserControl
{
    ScrollViewer? _scroller;
    bool _stick = true; // follow new output while the view is at the bottom

    public SessionView()
    {
        InitializeComponent();
        Transcript.AddHandler(ScrollViewer.ScrollChangedEvent, new ScrollChangedEventHandler(OnScrollChanged));
        CommandManager.AddPreviewExecutedHandler(Input, OnPaste);
        // the text box disables paste when the clipboard holds no text, e.g. a screenshot alone
        CommandManager.AddPreviewCanExecuteHandler(Input, (_, e) =>
        {
            if (e.Command != ApplicationCommands.Paste || Clipboard.ContainsText()) return;
            if (!Clipboard.ContainsFileDropList() && !Clipboard.ContainsImage() && !Clipboard.ContainsData("PNG")) return;
            e.CanExecute = true;
            e.Handled = true;
        });
        Loaded += (_, _) =>
        {
            _scroller = (ScrollViewer?)Transcript.Template.FindName("Scroller", Transcript);
            _scroller?.ScrollToEnd();
            Input.Focus();
            UnhookVoice(); // Loaded can fire again on re-parenting
            VoiceLink.Shared.StateChanged += OnVoiceState;
            VoiceLink.Shared.Text += OnVoiceText;
            VoiceLink.Shared.Partial += OnVoicePartial;
            ShowVoice(VoiceLink.Shared.Current, null);
        };
        Unloaded += (_, _) => UnhookVoice();
        // one view serves every tab of the window: the composer's text is the tab's, kept as it was left
        DataContextChanged += (_, e) =>
        {
            if (e.OldValue is SessionTab left) (left.Draft, left.DraftCaret) = (Input.Text, Input.CaretIndex);
            var back = e.NewValue as SessionTab;
            Input.Text = back?.Draft ?? "";
            Input.CaretIndex = Math.Min(back?.DraftCaret ?? 0, Input.Text.Length);
        };
        PreviewMouseDown += OnMouse4;
        PreviewMouseUp += OnMouse4;
    }

    SessionTab? Tab => DataContext as SessionTab;

    void OnScrollChanged(object sender, ScrollChangedEventArgs e)
    {
        if (_scroller is null || e.OriginalSource != _scroller) return; // markdown and text boxes scroll too
        if (e.ExtentHeightChange == 0) _stick = _scroller.VerticalOffset >= _scroller.ScrollableHeight - 4;
        else if (_stick) _scroller.ScrollToEnd();
        ToBottom.Visibility = _stick ? Visibility.Collapsed : Visibility.Visible;
    }

    void OnToBottom(object sender, RoutedEventArgs e)
    {
        _stick = true;
        _scroller?.ScrollToEnd();
        ToBottom.Visibility = Visibility.Collapsed;
    }

    /// <summary>Rows host their own scroll viewers, which swallow the wheel even with nothing to scroll.</summary>
    void OnTranscriptWheel(object sender, MouseWheelEventArgs e)
    {
        if (_scroller is null) return;
        _scroller.ScrollToVerticalOffset(_scroller.VerticalOffset - e.Delta * 0.6);
        e.Handled = true;
    }

    void OnInputKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && (Keyboard.Modifiers & ModifierKeys.Shift) == 0)
        {
            e.Handled = true;
            Send();
        }
        else if (e.Key == Key.Escape)
        {
            e.Handled = true;
            Stop();
        }
        else if (e.Key == Key.Tab && Keyboard.Modifiers == ModifierKeys.Shift)
        {
            e.Handled = true;
            _ = Tab?.CycleModeAsync();
        }
    }

    void OnSend(object sender, RoutedEventArgs e) => Send();

    /// <summary>The aside button: the typed text goes to a fork, not the session; attachments stay for the next send.</summary>
    async void OnAside(object sender, RoutedEventArgs e)
    {
        if (Tab is not { } tab || Input.Text.Trim() is not { Length: > 0 } question) return;
        Input.Clear();
        await tab.AsideAsync(question);
    }

    void OnStop(object sender, RoutedEventArgs e) => Stop();

    /// <summary>Interrupts the turn; queued messages come back into the input, ahead of anything typed since.</summary>
    void Stop()
    {
        if (Tab is not { } tab) return;
        if (tab.TakeQueued() is { } queued)
        {
            if (queued.Text.Length > 0) Input.Text = Input.Text.Length == 0 ? queued.Text : queued.Text + "\n\n" + Input.Text;
            Input.CaretIndex = Input.Text.Length;
            for (var i = 0; i < queued.Files.Count; i++) tab.Attachments.Insert(i, queued.Files[i]);
        }
        Input.Focus();
        _ = tab.InterruptAsync();
    }

    void OnInject(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is QueuedMessage m && Tab is { } tab) _ = tab.InjectAsync(m);
    }

    void OnUnqueue(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is QueuedMessage m) Tab?.Unqueue(m);
    }

    void Send()
    {
        var text = Input.Text.Trim();
        if (Tab is not { IsReady: true } tab || text.Length == 0 && tab.Attachments.Count == 0) return;
        Input.Clear();
        _stick = true;
        _ = tab.SendAsync(text);
    }

    // Dictation: the mic toggles, Mouse 4 is hold-to-talk, Shift with either is Portuguese. The
    // transcript lands at the caret and is never sent - reading it over is the point of a composer.
    static string VoiceLang => (Keyboard.Modifiers & ModifierKeys.Shift) != 0 ? "pt" : "en";

    void OnMic(object sender, RoutedEventArgs e)
    {
        var voice = VoiceLink.Shared;
        _ = voice.Current == VoiceLink.State.Off ? voice.StartAsync(VoiceLang) : voice.StopAsync();
        Input.Focus();
    }

    /// <summary>Reaches here only when voice-nav runs with --serve; its own hotkey mode takes Mouse 4
    /// first and pastes, which lands in the focused composer just the same.</summary>
    void OnMouse4(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.XButton1) return;
        e.Handled = true;
        if (e.ButtonState == MouseButtonState.Pressed)
        {
            CaptureMouse(); // or a release outside the window never arrives and it records on
            if (VoiceLink.Shared.Current == VoiceLink.State.Off) _ = VoiceLink.Shared.StartAsync(VoiceLang);
        }
        else
        {
            ReleaseMouseCapture();
            _ = VoiceLink.Shared.StopAsync(); // a tap under voice-nav's tap time cancels instead
        }
    }

    void OnVoiceState(VoiceLink.State state, string? detail) => Dispatcher.BeginInvoke(() => ShowVoice(state, detail));

    void OnVoiceText(string text) => Dispatcher.BeginInvoke(() => InsertDictation(text));

    void OnVoicePartial(string text) => Dispatcher.BeginInvoke(() =>
    {
        if (VoiceLink.Shared.Current is not (VoiceLink.State.Recording or VoiceLink.State.Transcribing)) return;
        VoicePreview.Text = text + " …";
        VoicePreview.Visibility = Visibility.Visible;
    });

    void UnhookVoice()
    {
        VoiceLink.Shared.StateChanged -= OnVoiceState;
        VoiceLink.Shared.Text -= OnVoiceText;
        VoiceLink.Shared.Partial -= OnVoicePartial;
    }

    void ShowVoice(VoiceLink.State state, string? detail)
    {
        if (state is not (VoiceLink.State.Recording or VoiceLink.State.Transcribing))
        {
            VoicePreview.Visibility = Visibility.Collapsed; // the transcript has landed, or there is none
            VoicePreview.Text = "";
        }
        Mic.Content = state switch
        {
            VoiceLink.State.Starting => "starting…",
            VoiceLink.State.Recording => "● rec",
            VoiceLink.State.Transcribing => "…",
            _ => "mic",
        };
        Mic.Foreground = (Brush)FindResource(state == VoiceLink.State.Recording ? "Red" : "Dim");
        Mic.ToolTip = detail ?? "dictate - click to start and stop, or hold Mouse 4; with Shift, Portuguese";
    }

    void InsertDictation(string text)
    {
        text = text.Trim();
        if (text.Length == 0) return;
        var at = Input.SelectionStart;
        if (at > 0 && !char.IsWhiteSpace(Input.Text[at - 1])) text = " " + text;
        Input.SelectedText = text; // through the selection, so Ctrl+Z takes it back out
        Input.Select(Input.SelectionStart + Input.SelectionLength, 0);
        Input.Focus();
    }

    void OnDetach(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is Attachment a) Tab?.Detach(a);
        Input.Focus();
    }

    /// <summary>Files dropped anywhere on the tab attach; dragged text still goes to the input as text.</summary>
    void OnDragOver(object sender, DragEventArgs e)
    {
        if (!e.Data.GetDataPresent(DataFormats.FileDrop)) return;
        e.Effects = Tab is { IsReady: true } ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    void OnDrop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] paths) return;
        e.Handled = true;
        AttachFiles(paths);
        Input.Focus();
    }

    /// <summary>ctrl+v: copied files and images attach; anything else pastes as text.</summary>
    void OnPaste(object sender, ExecutedRoutedEventArgs e)
    {
        if (e.Command != ApplicationCommands.Paste || Tab is not { } tab) return;
        if (Clipboard.ContainsFileDropList())
        {
            e.Handled = true;
            AttachFiles(Clipboard.GetFileDropList().Cast<string>());
        }
        else if (Clipboard.ContainsImage() || Clipboard.ContainsData("PNG"))
        {
            e.Handled = true;
            Try(() => AttachmentLoader.FromClipboard() is { } a ? [a] : []);
        }
    }

    void AttachFiles(IEnumerable<string> paths)
    {
        foreach (var path in paths)
        {
            if (Directory.Exists(path)) Tab?.Transcript.AddNote(NoteKind.Warning, "folders don't attach", path);
            else Try(() => [AttachmentLoader.FromFile(path)]);
        }
    }

    void Try(Func<IEnumerable<Attachment>> load)
    {
        if (Tab is not { } tab) return;
        try
        {
            foreach (var a in load()) tab.Attach(a);
        }
        catch (AttachmentException ex) { tab.Transcript.AddNote(NoteKind.Error, "can't attach", ex.Message); }
    }

    void OnAllow(object sender, RoutedEventArgs e) => Decide(sender, PermissionState.Allowed);

    void OnAllowSession(object sender, RoutedEventArgs e) => Decide(sender, PermissionState.AllowedForSession);

    void OnDeny(object sender, RoutedEventArgs e) => Decide(sender, PermissionState.Denied);

    void Decide(object sender, PermissionState decision)
    {
        if ((sender as FrameworkElement)?.DataContext is PermissionItem p) _ = Tab?.DecideAsync(p, decision);
    }

    void OnCardAction(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is CardAction a && Owner<CardItem>(sender) is { } card) _ = Tab?.ActAsync(card, a.Key);
    }

    void OnPickOption(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not OptionPick o) return;
        o.Pick();
        if (Owner<QuestionItem>(sender) is not { } q) return;
        if (q is { AnswersOnPick: true, CanSubmit: true }) _ = Tab?.AnswerAsync(q);
        else if (Owner<QuestionPick>(sender) is { } pick) q.AdvanceFrom(pick);
    }

    /// <summary>A question's line opens or folds it, whatever the others are doing.</summary>
    void OnFoldQuestion(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is IFoldingQuestion q) q.IsExpanded = !q.IsExpanded;
    }

    void OnSubmitAnswer(object sender, RoutedEventArgs e)
    {
        if (Owner<QuestionItem>(sender) is { } q) _ = Tab?.AnswerAsync(q);
    }

    void OnDeclineQuestion(object sender, RoutedEventArgs e)
    {
        if (Owner<QuestionItem>(sender) is { } q) _ = Tab?.DeclineAsync(q);
    }

    /// <summary>Enter in a typed answer submits the card once every question has an answer; before that it folds
    /// its question, multi-select too, and opens the next unanswered.</summary>
    void OnOtherKey(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter || Keyboard.Modifiers != ModifierKeys.None) return;
        e.Handled = true;
        if (Owner<QuestionItem>(sender) is not { } q) return;
        if (q.CanSubmit) _ = Tab?.AnswerAsync(q);
        else if (Owner<QuestionPick>(sender) is { } pick) q.AdvanceFrom(pick, done: true);
    }

    /// <summary>The model pill opens its effort menu on a left click as well as a right one.</summary>
    void OnEffortMenu(object sender, MouseButtonEventArgs e)
    {
        if (sender is not FrameworkElement { ContextMenu: { } menu } pill) return;
        menu.PlacementTarget = pill;
        menu.Placement = System.Windows.Controls.Primitives.PlacementMode.Top;
        menu.IsOpen = true;
        e.Handled = true;
    }

    /// <summary>Ticks the level the last reply ran at, and the tab's handoff mode.</summary>
    void OnEffortMenuOpened(object sender, RoutedEventArgs e)
    {
        if (sender is not ContextMenu { PlacementTarget: FrameworkElement { DataContext: FooterRow row } } menu) return;
        foreach (var item in menu.Items.OfType<MenuItem>())
            item.IsChecked = item.Tag is string mode ? mode == Tab?.HandoffMode : (string)item.Header == row.Effort.Trim();
    }

    void OnHandoffPick(object sender, RoutedEventArgs e)
    {
        if (sender is MenuItem { Tag: string mode } && Tab is { } tab) tab.HandoffMode = mode;
    }

    void OnEffortPick(object sender, RoutedEventArgs e)
    {
        if (sender is MenuItem { Header: string level }) Tab?.SetEffort(level);
    }

    void OnSendOpen(object sender, RoutedEventArgs e) => SendOpen((sender as FrameworkElement)?.DataContext as OpenBlock);

    /// <summary>Enter in a ▶ ask's typed answer sends the bar, as its send button would.</summary>
    void OnOpenOtherKey(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter || Keyboard.Modifiers != ModifierKeys.None) return;
        e.Handled = true;
        SendOpen(Owner<OpenBlock>(sender));
    }

    void SendOpen(OpenBlock? block)
    {
        if (block is not { CanSend: true, Reply: { } reply } || Tab is not { IsReady: true } tab) return;
        _stick = true;
        _ = tab.SendAsync(reply);
    }

    /// <summary>The nearest data context of type T above a control in a nested template: the card a button sits in.</summary>
    static T? Owner<T>(object sender) where T : class
    {
        for (var d = sender as DependencyObject; d is not null; d = VisualTreeHelper.GetParent(d))
            if (d is FrameworkElement { DataContext: T t }) return t;
        return null;
    }
}
