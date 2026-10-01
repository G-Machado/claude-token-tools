using System.Windows;
using System.Windows.Media;
using ICSharpCode.AvalonEdit.Highlighting;
using System.Windows.Threading;
using TokenChat.Core;

namespace TokenChat.App;

/// <summary>TokenChat.App [--lite] [--model name] [--resume sid] [directory]: opens a tab in directory (resuming sid),
/// else the start screen. With TokenChat already running, the request goes to that window and this process exits.</summary>
public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var request = LaunchRequest.Parse(e.Args);
        var first = SingleInstance.Claim();
        if (!first && SingleInstance.Forward(request))
        {
            Shutdown();
            return;
        }
        DispatcherUnhandledException += OnUnhandled;
        LiftCodeColours();
        var window = new MainWindow { Lite = request.Lite, Model = request.Model };
        MainWindow = window;
        window.Show();
        window.Handle(request);
        if (first) _ = Task.Run(() => SingleInstance.ServeAsync(r => Dispatcher.Invoke(() => window.Handle(r))));
    }

    /// <summary>AvalonEdit's syntax colours are chosen for white paper (navy keywords, dark green comments). Code blocks
    /// sit on the dark card, so lift every named colour to the same hue at a readable lightness, once, at startup.
    /// Rules share these objects, so changing the named colour changes the rule.</summary>
    static void LiftCodeColours()
    {
        foreach (var definition in HighlightingManager.Instance.HighlightingDefinitions)
            foreach (var colour in definition.NamedHighlightingColors)
            {
                if (colour.IsFrozen) continue;
                if (colour.Foreground?.GetColor(null) is { } fg) colour.Foreground = new SimpleHighlightingBrush(Lift(fg));
                colour.Background = null;
            }
    }

    /// <summary>Same hue, lightness raised to at least 0.72 and saturation capped at 0.75.</summary>
    static Color Lift(Color c)
    {
        double r = c.R / 255.0, g = c.G / 255.0, b = c.B / 255.0;
        double max = Math.Max(r, Math.Max(g, b)), min = Math.Min(r, Math.Min(g, b)), d = max - min;
        var l = (max + min) / 2;
        var s = d == 0 ? 0 : d / (1 - Math.Abs(2 * l - 1));
        var h = d == 0 ? 0 : max == r ? (g - b) / d : max == g ? (b - r) / d + 2 : (r - g) / d + 4;
        if (h < 0) h += 6;
        l = Math.Max(l, 0.72);
        s = Math.Min(s, 0.75);
        double chroma = (1 - Math.Abs(2 * l - 1)) * s, x = chroma * (1 - Math.Abs(h % 2 - 1)), m = l - chroma / 2;
        var (r1, g1, b1) = (int)h switch
        {
            0 => (chroma, x, 0.0), 1 => (x, chroma, 0.0), 2 => (0.0, chroma, x),
            3 => (0.0, x, chroma), 4 => (x, 0.0, chroma), _ => (chroma, 0.0, x),
        };
        static byte B(double v) => (byte)Math.Round(Math.Clamp(v, 0, 1) * 255);
        return Color.FromArgb(c.A, B(r1 + m), B(g1 + m), B(b1 + m));
    }

    /// <summary>Keep the window (and its live sessions) up on a UI bug; say what broke.</summary>
    void OnUnhandled(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        MessageBox.Show(MainWindow, e.Exception.ToString(), "token-chat: unexpected error", MessageBoxButton.OK, MessageBoxImage.Error);
        e.Handled = true;
    }
}
