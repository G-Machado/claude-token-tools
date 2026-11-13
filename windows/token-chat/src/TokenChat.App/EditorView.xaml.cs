using System.IO;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace TokenChat.App;

/// <summary>The window's Editor tab: shows one UnityEditorLink and watches it while visible.</summary>
public partial class EditorView : UserControl
{
    public sealed record Node(int Id, string Name, string Glyph, Thickness Indent, Brush Fore);
    public sealed record Prop(string Name, string Value);
    public sealed record Comp(string Title, string Off, Brush Fore, IReadOnlyList<Prop> Props);

    UnityEditorLink? _link;
    int _image = -1, _scene = -1, _inspect = -1;
    bool _filling;

    public EditorView()
    {
        InitializeComponent();
        IsVisibleChanged += (_, _) =>
        {
            if (_link is null) return;
            if (IsVisible) _link.Watch(this); else _link.Unwatch(this);
        };
    }

    /// <summary>Points the view at a project's Editor; it starts watching once shown.</summary>
    public void Show(UnityEditorLink link)
    {
        if (_link == link) return;
        if (_link is { } old) { old.Changed -= OnChanged; old.Unwatch(this); }
        _link = link;
        _image = _scene = _inspect = -1;
        link.Changed += OnChanged;
        if (IsVisible) link.Watch(this);
        Update();
    }

    void OnChanged() => Dispatcher.BeginInvoke(Update);

    void OnRefresh(object sender, RoutedEventArgs e) => _ = _link?.RefreshAsync();

    void OnPick(object sender, SelectionChangedEventArgs e)
    {
        if (!_filling && Tree.SelectedItem is Node n && _link is { } link) _ = link.PickAsync(n.Id);
    }

    void OnScene(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is string path && _link is { } link) _ = link.OpenSceneAsync(path);
    }

    Brush B(string key) => (Brush)FindResource(key);

    void Update()
    {
        if (_link is not { } link) return;
        Title.Text = link.Name;
        Status.Text = (link.Busy ? "reading… " : "") + link.Status;
        if (link.ImageVersion != _image && File.Exists(link.PngPath))
        {
            _image = link.ImageVersion;
            try
            {
                var bmp = new BitmapImage();
                bmp.BeginInit();
                bmp.CacheOption = BitmapCacheOption.OnLoad;   // read now, so the file is free for the next shot
                bmp.StreamSource = new MemoryStream(File.ReadAllBytes(link.PngPath));
                bmp.EndInit();
                bmp.Freeze();
                Shot.Source = bmp;
                ShotEmpty.Visibility = Visibility.Collapsed;
            }
            catch (Exception ex) when (ex is IOException or NotSupportedException) { _image = -1; }
        }
        if (link.SceneVersion != _scene && link.Scene is { } scene)
        {
            _scene = link.SceneVersion;
            var nodes = new List<Node>();
            Node? picked = null;
            foreach (var x in scene["nodes"] as JsonArray ?? [])
            {
                if (x is null) continue;
                var n = new Node((int)x["id"]!, (string?)x["n"] ?? "", (int?)x["c"] > 0 ? "▾ " : "   ",
                                 new Thickness((int)x["d"]! * 14, 0, 0, 0), B((int?)x["a"] == 1 ? "Text" : "Faint"));
                if (n.Id == link.Picked) picked = n;
                nodes.Add(n);
            }
            _filling = true;
            Tree.ItemsSource = nodes;
            Tree.SelectedItem = picked;
            _filling = false;
            ScenePick.Visibility = link.NeedsScene ? Visibility.Visible : Visibility.Collapsed;
            SceneList.ItemsSource = link.NeedsScene ? (scene["scenes"] as JsonArray ?? []).Select(x => (string?)x).OfType<string>().ToList() : null;
            if (link.Inspected is null) { InspectTitle.Text = link.NeedsScene ? "" : "pick an object in the hierarchy"; InspectSub.Text = ""; Comps.ItemsSource = null; }
        }
        if (link.InspectVersion != _inspect && link.Inspected is { } insp)
        {
            _inspect = link.InspectVersion;
            if ((string?)insp["error"] is { } err)
            {
                InspectTitle.Text = "";
                InspectSub.Text = err;
                Comps.ItemsSource = null;
                return;
            }
            InspectTitle.Text = (string?)insp["n"] ?? "";
            InspectSub.Text = $"tag {(string?)insp["tag"]} · layer {(string?)insp["layer"]}" + ((int?)insp["a"] == 1 ? "" : " · inactive");
            Comps.ItemsSource = (insp["comps"] as JsonArray ?? []).Where(c => c is not null).Select(c => new Comp(
                (string?)c!["t"] ?? "", (int?)c["en"] == 0 ? "  (off)" : "", B((int?)c["en"] == 0 ? "Dim" : "Text"),
                [.. (c["p"] as JsonArray ?? []).Where(p => p is not null).Select(p => new Prop((string?)p!["n"] ?? "", (string?)p["v"] ?? ""))])).ToList();
        }
    }
}
