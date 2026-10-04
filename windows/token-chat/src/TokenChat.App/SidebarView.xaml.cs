using System.Windows.Controls;

namespace TokenChat.App;

/// <summary>Every session as the widget lists it, this window's first; Sidebar fills it, MainWindow syncs it with the tabs.</summary>
public partial class SidebarView : UserControl
{
    public SidebarView() => InitializeComponent();
}
