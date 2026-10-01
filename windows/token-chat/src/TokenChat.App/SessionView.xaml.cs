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
        };
    }

    SessionTab? Tab => DataContext as SessionTab;

    void OnScrollChanged(object sender, ScrollChangedEventArgs e)
    {
        if (_scroller is null || e.OriginalSource != _scroller) return; // markdown and text boxes scroll too
        if (e.ExtentHeightChange == 0) _stick = _scroller.VerticalOffset >= _scroller.ScrollableHeight - 4;
        else if (_stick) _scroller.ScrollToEnd();
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

    void OnPickOption(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not OptionPick o) return;
        o.Pick();
        if (Owner<QuestionItem>(sender) is { AnswersOnPick: true, CanSubmit: true } q) _ = Tab?.AnswerAsync(q);
    }

    void OnSubmitAnswer(object sender, RoutedEventArgs e)
    {
        if (Owner<QuestionItem>(sender) is { } q) _ = Tab?.AnswerAsync(q);
    }

    void OnDeclineQuestion(object sender, RoutedEventArgs e)
    {
        if (Owner<QuestionItem>(sender) is { } q) _ = Tab?.DeclineAsync(q);
    }

    /// <summary>Enter in a typed answer submits the card once every question has an answer.</summary>
    void OnOtherKey(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter || Keyboard.Modifiers != ModifierKeys.None) return;
        e.Handled = true;
        if (Owner<QuestionItem>(sender) is { CanSubmit: true } q) _ = Tab?.AnswerAsync(q);
    }

    void OnSendOpen(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not OpenBlock { CanSend: true, Reply: { } reply } || Tab is not { IsReady: true } tab) return;
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
