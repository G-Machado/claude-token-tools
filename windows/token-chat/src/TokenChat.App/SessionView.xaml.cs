using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
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
            Input.Text = Input.Text.Length == 0 ? queued : queued + "\n\n" + Input.Text;
            Input.CaretIndex = Input.Text.Length;
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
        if (text.Length == 0 || Tab is not { IsReady: true } tab) return;
        Input.Clear();
        _stick = true;
        _ = tab.SendAsync(text);
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
