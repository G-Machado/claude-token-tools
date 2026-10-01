using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
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
            _ = Tab?.InterruptAsync();
        }
    }

    void OnSend(object sender, RoutedEventArgs e) => Send();

    void Send()
    {
        var text = Input.Text.Trim();
        if (text.Length == 0 || Tab is not { IsReady: true } tab) return;
        Input.Clear();
        _stick = true;
        _ = tab.SendAsync(text);
    }

    void OnAllow(object sender, RoutedEventArgs e) => Decide(sender, allow: true);

    void OnDeny(object sender, RoutedEventArgs e) => Decide(sender, allow: false);

    void Decide(object sender, bool allow)
    {
        if ((sender as FrameworkElement)?.DataContext is PermissionItem p) _ = Tab?.DecideAsync(p, allow);
    }
}
