# token-parked.ps1 - the always-on-top readout for /park checkpoints.
#
# token-widget.ps1 answers "what is running and what is it costing". This
# answers the other half of the same policy: "what did I put down, and can I
# pick it up". They are deliberately two windows rather than two tabs - the
# first is glanced at while you work and the second is opened when you are
# deciding what to work on, and a tab you have to switch to is a tab you forget
# is there.
#
# A row here is not a session. Everything a live row carries - context, cache
# clock, cost, grades, extension marks - is about a window that is spending
# money, and a checkpoint is not one: it is a file. So the row carries only the
# facts that change what resuming DOES:
#
#   what      the topic, which is the identity of the strand
#   when      how long ago it was written
#   where     the working directory it has to be resumed in
#   next      the single next action the checkpoint names
#   state     open / behind / ready - see New-Row for what each one means
#
# Enter resumes the selected one: a terminal in that directory running
#   claude "/unpark <topic>"
# which is exactly what the /unpark command was written to be handed.
#
# Nothing here is installed. Every number comes from
# `token-sessions.sh --parked --json`, which reads the checkpoint directory and
# two side tables and costs no model tokens. That mode deliberately does NOT run
# a collect - see parked_json in token-sessions.sh.
#
#   powershell -ExecutionPolicy Bypass -File token-parked.ps1
#   token-parked.vbs            same thing with no console window
#
# View state - position, fold, pinned, size, zoom - is remembered in
# token-parked-pos.json.

param(
  [int]$Every = 300,         # seconds between refreshes; checkpoints change slowly
  [switch]$TopLeft,          # start in the top-left instead of bottom-right
  [switch]$NoTray,           # no tray icon; closing the panel exits
  [switch]$SelfTest          # build and populate once, report, exit - no window
)

# --- one copy only -----------------------------------------------------------
# The sessions widget grew this guard after 26 copies of it were found running at
# once. This panel never got it, and by 2026-09-09 there were 13 - one per time
# the window could not be found, which is the entire mechanism. Closing the panel
# hides it to the tray rather than exiting, so the copy you "closed" is still
# there; and a position saved on a monitor that is no longer attached renders it
# where no display covers. Both look identical from the desk: nothing on screen.
# Launching it again is the obvious response, and it was the wrong one.
#
# So a second launch does not become a second panel. It signals the running copy
# to surface itself and exits - which turns the reflex into the fix, because what
# was wanted was to SEE the panel, never to have two of them. That signal is not
# a nicety: without it the mutex alone would make an off-screen panel
# unrecoverable, the relaunch dying quietly and leaving the desk as empty as
# before.
#
# Local\ rather than Global\: the scope that matters is one desktop session, and
# a Global name would also block a second user on the same machine. An abandoned
# mutex - a previous copy killed rather than closed - throws on WaitOne, and that
# means we DID acquire it, so it is success and not failure. Both handles live in
# script scope so that nothing collects them out from under a running panel.
if (-not $SelfTest -and -not $env:TOKEN_PARKED_MULTI) {
  $script:ShowEvent = New-Object System.Threading.EventWaitHandle($false,
    [System.Threading.EventResetMode]::AutoReset, 'Local\claude-token-parked-show')
  $script:SoloMutex = New-Object System.Threading.Mutex($false, 'Local\claude-token-parked')
  $got = $false
  try   { $got = $script:SoloMutex.WaitOne(0) }
  catch [System.Threading.AbandonedMutexException] { $got = $true }
  if (-not $got) {
    # Started from the .vbs there is no console to write to, so this is quiet by
    # design: the panel surfacing itself IS the feedback.
    [void]$script:ShowEvent.Set()
    Write-Host 'token-parked is already running - asked it to surface, this copy is exiting. TOKEN_PARKED_MULTI=1 runs a second one anyway.'
    exit 0
  }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$ErrorActionPreference = 'Stop'
$Root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script  = Join-Path $Root 'token-sessions.sh'
$PosFile = Join-Path $Root 'token-parked-pos.json'

# Git Bash, looked up once and by several names - "bash" on PATH is sometimes
# the WSL shim, which cannot see this repo. Same lookup the sessions widget
# does, and for the same reason.
$Bash = $null
foreach ($cand in @(
    "$env:ProgramFiles\Git\bin\bash.exe",
    "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe")) {
  if (Test-Path $cand) { $Bash = $cand; break }
}
if (-not $Bash) {
  $g = Get-Command bash.exe -ErrorAction SilentlyContinue
  if ($g) { $Bash = $g.Source }
}
if (-not $Bash) {
  [System.Windows.MessageBox]::Show("Git Bash not found - this reads token-sessions.sh through it.", "token-parked") | Out-Null
  exit 1
}

# --- palette -----------------------------------------------------------------
# The sessions widget's palette verbatim, so the two panels are recognisably one
# tool. What the colours MEAN is different, because the question is: there, a
# hue is a size against the measured bands; here it is a state - whether picking
# this checkpoint up is safe, and if not, why not.
$Pal = @{
  bg     = '#F01A1B20'; card = '#FF212228'; line = '#FF2E3038'
  text   = '#FFE6E7EA'; dim  = '#FF8A8D97'; faint = '#FF5A5D66'
  green  = '#FF4ADE80'; yellow = '#FFFACC15'; orange = '#FFFB923C'
  red    = '#FFF87171'; blue  = '#FF60A5FA'; grey   = '#FF6B6F7A'
  track  = '#FF34363F'; sel   = '#FF2A2C34'; white = '#FFFFFFFF'
}
function Br([string]$hex) {
  if (-not $hex) {
    $where = (Get-PSCallStack | Select-Object -Skip 1 -First 3 |
              ForEach-Object { "$($_.FunctionName):$($_.ScriptLineNumber)" }) -join ' <- '
    throw "Br: empty colour - a palette lookup missed at $where"
  }
  New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex))
}

# Told apart by REFERENCE in the hover handlers: an element whose background is
# the ghost is one this code put there and may recolour; anything else has a
# colour of its own and must be left alone.
$GhostBrush = (Br '#01000000')   # hit-testable and invisible
$HoverBrush = (Br '#1EFFFFFF')   # what the pointer leaves behind
$RowBrush   = (Br '#0BFFFFFF')   # the same, one step quieter, for a whole row
# A checkpoint whose window is still open. Not a warning - there is nothing
# wrong with it - but unparking it starts a SECOND window on one strand, and the
# two will then diverge with no way to merge them. So the row is tinted the way
# a lapsed session is tinted next door: a fact about the row, stated by its
# ground rather than by a word you have to find.
$OpenBrush  = (Br '#1A7C9CBF')
# A checkpoint the work ran on past. Warm, because this one IS a warning: resume
# it and you resume from behind, and the distance is printed on the row.
$BehindBrush = (Br '#18FB923C')
$GhostBrush.Freeze(); $HoverBrush.Freeze(); $RowBrush.Freeze()
$OpenBrush.Freeze(); $BehindBrush.Freeze()

$XAML = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Parked" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ShowInTaskbar="False"
        SizeToContent="Height" Width="440" ResizeMode="NoResize" Focusable="True">
  <Window.Resources>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="6"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border CornerRadius="2" Background="#FF4A4D57" Margin="2,0,1,0"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border x:Name="Card" CornerRadius="10" Background="#FF212228"
          BorderBrush="#FF34363F" BorderThickness="1" Padding="0">
    <Border.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="3" Opacity="0.55" Color="#FF000000"/></Border.Effect>
    <StackPanel>

      <Grid x:Name="Header" Margin="14,11,10,8" Background="Transparent">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal">
          <TextBlock x:Name="Dot" Text="&#9670;" FontSize="10" Margin="0,3,7,0" Foreground="#FF60A5FA"/>
          <TextBlock x:Name="Title" Text="PARKED" FontFamily="Segoe UI" FontSize="11"
                     FontWeight="SemiBold" Foreground="#FFE6E7EA"/>
        </StackPanel>
        <TextBlock x:Name="Count" Grid.Column="1" FontFamily="Consolas" FontSize="11"
                   Foreground="#FF8A8D97" Margin="0,1,10,0"/>
        <TextBlock x:Name="Pin" Grid.Column="2" Text="&#9679;" FontSize="9"
                   Foreground="#FF60A5FA" Cursor="Hand" Margin="0,2,9,0" ToolTip="p - unpin from the top"/>
        <TextBlock x:Name="Close" Grid.Column="3" Text="&#10005;" FontSize="11"
                   Foreground="#FF5A5D66" Cursor="Hand" Margin="0,1,4,0" ToolTip="esc - hide to the tray"/>
      </Grid>

      <Border Height="1" Background="#FF2E3038"/>

      <ScrollViewer x:Name="RowScroll" VerticalScrollBarVisibility="Auto"
                    HorizontalScrollBarVisibility="Disabled" MaxHeight="420"
                    PanningMode="VerticalOnly" Focusable="False">
        <StackPanel x:Name="Rows" Margin="0,3,0,3"/>
      </ScrollViewer>
      <Border Height="1" Background="#FF2E3038"/>

      <Border x:Name="FootRule" Height="1" Background="#FF2E3038"/>
      <StackPanel x:Name="FootBody" Margin="14,8,14,2">
        <StackPanel x:Name="Legend"/>
        <StackPanel x:Name="Keys" Visibility="Collapsed"/>
      </StackPanel>

      <Border Height="1" Background="#FF2E3038" Margin="0,7,0,0"/>
      <Grid Margin="12,7,10,7">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="Fold" Text="&#9662;" FontFamily="Segoe UI Symbol" FontSize="9"
                   Foreground="#FF5A5D66" Cursor="Hand" Margin="0,0,7,0" ToolTip="f - fold the footer"/>
        <TextBlock x:Name="Countdown" Grid.Column="1" FontFamily="Consolas" FontSize="9" Foreground="#FF5A5D66"/>
        <StackPanel Grid.Column="2" Orientation="Horizontal">
          <TextBlock x:Name="KeysToggle" Text="?" FontFamily="Consolas" FontSize="9"
                     Foreground="#FF5A5D66" Cursor="Hand" Margin="0,0,10,0" ToolTip="? - the keys"/>
          <TextBlock x:Name="LegendToggle" Text="legend" FontFamily="Consolas" FontSize="9"
                     Foreground="#FF5A5D66" Cursor="Hand" Margin="0,0,10,0" ToolTip="l - what the states mean"/>
          <TextBlock x:Name="Refresh" Text="&#8635;" FontFamily="Segoe UI Symbol" FontSize="11"
                     Foreground="#FF5A5D66" Cursor="Hand" ToolTip="r - re-read the checkpoint directory"/>
        </StackPanel>
        <TextBlock x:Name="Grip" Grid.Column="3" Text="&#9698;" FontFamily="Segoe UI Symbol"
                   FontSize="10" Foreground="#FF3E414B" Cursor="SizeNWSE" Margin="9,2,0,-2"/>
      </Grid>

      <Border x:Name="AdviceBox" Background="#FF1B1C22" Padding="14,9,14,9"
              CornerRadius="0,0,9,9">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <TextBlock x:Name="AdviceArrow" Text="&#8594;" FontFamily="Consolas" FontSize="11"
                     Foreground="#FF8A8D97" Margin="0,0,7,0" VerticalAlignment="Top"/>
          <TextBlock x:Name="Advice" Grid.Column="1" FontFamily="Segoe UI" FontSize="10.5"
                     Foreground="#FF8A8D97" TextWrapping="Wrap" LineHeight="15"
                     MinHeight="30" MaxHeight="60" TextTrimming="CharacterEllipsis"/>
        </Grid>
      </Border>

    </StackPanel>
  </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$XAML)
$win = [Windows.Markup.XamlReader]::Load($reader)
$el = @{}
foreach ($n in 'Card','Header','Dot','Title','Count','Pin','Close','Rows','RowScroll',
                'AdviceBox','AdviceArrow','Advice','FootRule','FootBody','Legend','Keys',
                'Fold','Countdown','KeysToggle','LegendToggle','Refresh','Grip') {
  $el[$n] = $win.FindName($n)
}

# --- view state --------------------------------------------------------------
$script:View = @{
  pinned = $true; detail = $false; legend = $true; keys = $false
  foot = $true; width = 440.0; zoom = 1.0; rowsH = 420.0
}
$MINW = 340.0; $MAXW = 900.0; $MINZ = 0.75; $MAXZ = 1.6
$MINH = 96.0;  $MAXH = 1100.0
$wa = [System.Windows.SystemParameters]::WorkArea

# A saved position is a position on the desktop THAT EXISTED WHEN IT WAS SAVED.
# Undock a second monitor and the coordinates outlive the pixels: the window is
# created, IsWindowVisible reports True, and it renders at x=2790 on a desktop
# 1536 wide. From the desk that is indistinguishable from a crash, and the
# response it invites - launch it again - is how copies accumulate.
#
# So the restore is treated as a request, not an instruction. VirtualScreen* is
# the union of every attached display in the same device-independent units as
# $win.Left, which makes this a bounds check rather than a walk over monitors.
function Clamp-Placement {
  $vl = [double][System.Windows.SystemParameters]::VirtualScreenLeft
  $vt = [double][System.Windows.SystemParameters]::VirtualScreenTop
  $vr = $vl + [double][System.Windows.SystemParameters]::VirtualScreenWidth
  $vb = $vt + [double][System.Windows.SystemParameters]::VirtualScreenHeight

  # Measured if the window has been through a layout pass, estimated if it has
  # not. Both cases are real: this runs once before the window is ever shown, so
  # that it is never drawn off-screen even for a frame, and again from
  # ContentRendered once there are true numbers to use.
  #
  # The estimate is deliberately lopsided. Width is exact - width and zoom come
  # from the same file as the position - but there is no saved height at all:
  # rowsH is the cap on the row list, not the height of the window, and reading
  # it as one over-estimated a 395px widget at 939px, which is enough to shove a
  # panel the user had parked at the bottom of the screen up to the top on every
  # start. So when the height is unknown, only the top edge is held on screen
  # (below), and the bottom is left to the measured pass.
  $w = if ($win.ActualWidth -gt 0) { [double]$win.ActualWidth }
       else { [double]$script:View.width * [double]$script:View.zoom }
  $h = if ($win.ActualHeight -gt 0) { [double]$win.ActualHeight } else { 0.0 }

  $l = [double]$win.Left; $t = [double]$win.Top
  # A NaN would silently defeat every comparison below, and a half-written pos
  # file is exactly how one arrives.
  if ([double]::IsNaN($l) -or [double]::IsInfinity($l)) { $l = $vl }
  if ([double]::IsNaN($t) -or [double]::IsInfinity($t)) { $t = $vt }

  # Fit it whole where the desktop allows, and pin the top-left corner where it
  # does not: a window wider than every display attached has to give up its right
  # edge, never its left, because the left is where the header and grip are.
  # An unmeasured window gets the reachability rule instead of the fitting one:
  # keep MINVIS of it below the top edge, which is where the header and the grip
  # are, so it can always be dragged wherever the user actually wants it.
  $MINVIS = 80.0
  if ($w -lt ($vr - $vl)) { $l = [math]::Min([math]::Max($l, $vl), $vr - $w) } else { $l = $vl }
  if ($h -le 0)              { $t = [math]::Min([math]::Max($t, $vt), $vb - $MINVIS) }
  elseif ($h -lt ($vb - $vt)) { $t = [math]::Min([math]::Max($t, $vt), $vb - $h) }
  else                        { $t = $vt }

  # The virtual screen is bounds, not work area, so a window pushed up off the
  # bottom edge comes to rest under the taskbar - on screen and still half
  # unusable. When the result lands on the primary display, which is the whole
  # of the single-monitor case, finish the job against $wa instead. Only then:
  # $wa describes the primary monitor alone, so applying it to a position on a
  # second display would drag the window back to the first one.
  $pw = [double][System.Windows.SystemParameters]::PrimaryScreenWidth
  $ph = [double][System.Windows.SystemParameters]::PrimaryScreenHeight
  if ($l -ge 0 -and $t -ge 0 -and ($l + $w) -le $pw -and ($t + [math]::Max($h, $MINVIS)) -le $ph) {
    if ($w -lt ($wa.Right - $wa.Left)) { $l = [math]::Min([math]::Max($l, $wa.Left), $wa.Right - $w) }
    if ($h -gt 0 -and $h -lt ($wa.Bottom - $wa.Top)) {
      $t = [math]::Min([math]::Max($t, $wa.Top), $wa.Bottom - $h)
    }
  }

  if ($l -ne [double]$win.Left -or $t -ne [double]$win.Top) { $win.Left = $l; $win.Top = $t }
}

$script:Placed = $false
if (Test-Path $PosFile) {
  try {
    $p = Get-Content $PosFile -Raw | ConvertFrom-Json
    $win.Left = [double]$p.left; $win.Top = [double]$p.top; $script:Placed = $true
    foreach ($k in 'pinned','detail','legend','foot','width','zoom','rowsH') {
      if ($null -ne $p.$k) { $script:View[$k] = $p.$k }
    }
  } catch { $script:Placed = $false }
}
if (-not $script:Placed) {
  # Offset from where the sessions widget parks itself, so launching both does
  # not stack one exactly on the other.
  if ($TopLeft) { $win.Left = $wa.Left + 20; $win.Top = $wa.Top + 20 }
  else { $win.Left = $wa.Right - 470; $win.Top = $wa.Top + 40 }
}
Clamp-Placement

function Save-State {
  try {
    @{ left = $win.Left; top = $win.Top
       pinned = $script:View.pinned; detail = $script:View.detail
       legend = $script:View.legend; foot = $script:View.foot
       width = $script:View.width; zoom = $script:View.zoom; rowsH = $script:View.rowsH
    } | ConvertTo-Json -Compress | Set-Content $PosFile -Encoding utf8
  } catch { }
}

function Apply-Size {
  $w = [math]::Max($MINW, [math]::Min($MAXW, [double]$script:View.width))
  $z = [math]::Max($MINZ, [math]::Min($MAXZ, [double]$script:View.zoom))
  $h = [math]::Max($MINH, [math]::Min($MAXH, [double]$script:View.rowsH))
  $script:View.width = $w; $script:View.zoom = $z; $script:View.rowsH = $h
  if ($z -eq 1.0) { $el.Card.LayoutTransform = $null }
  else { $el.Card.LayoutTransform = New-Object Windows.Media.ScaleTransform ($z, $z) }
  $win.Width = $w * $z
  $el.RowScroll.MaxHeight = $h
}

# --- formatting --------------------------------------------------------------
# Minutes into the shortest true thing. The same three scales token-sessions.sh
# uses in its own listing, so an age reads the same in both.
function Age([double]$m) {
  if ($m -lt 60)   { return ('{0:N0}m' -f $m) }
  if ($m -lt 2880) { return ('{0:N0}h' -f ($m / 60)) }
  ('{0:N0}d' -f ($m / 1440))
}
# How old is too old to trust without looking. Not a cliff - a checkpoint from
# last week is still the cheapest way back into that work - but past a couple of
# days the tree has usually moved under it, which is the thing /unpark is told
# to check first. So the age simply loses its brightness rather than turning a
# colour that would compete with the state.
function Age-Color([double]$m) {
  if ($m -ge 10080) { return $Pal.faint }   # a week
  if ($m -ge 2880)  { return $Pal.grey }    # two days
  $Pal.dim
}

function Text-Block([string]$s, [double]$size, [string]$colour, [string]$family = 'Consolas') {
  $t = New-Object Windows.Controls.TextBlock
  $t.Text = $s; $t.FontSize = $size; $t.FontFamily = $family
  $t.Foreground = (Br $colour)
  $t
}

# Hover text in the card's own message line rather than a real ToolTip, which is
# a second window that draws over the row you are pointing at. Same mechanism as
# the sessions widget, including stashing the string in .ToolTip so nothing has
# to be tracked in a side table that would leak an entry per redraw.
function Tip($element, [string]$text) {
  if (-not $text) { return }
  $first = ($null -eq $element.ToolTip)
  $element.ToolTip = $text
  if (-not $first) { return }
  [Windows.Controls.ToolTipService]::SetIsEnabled($element, $false)
  if ($element.PSObject.Properties['Background'] -and -not $element.Background) {
    $element.Background = $GhostBrush
  }
  $element.add_MouseEnter({ param($s, $e)
    if ($s.Background -eq $GhostBrush) { $s.Background = $HoverBrush }
    Set-Hover ([string]$s.ToolTip) })
  $element.add_MouseLeave({ param($s, $e)
    if ($s.Background -eq $HoverBrush) { $s.Background = $GhostBrush }
    Set-Hover (Tip-Above $s) })
}

function Tip-Above($element) {
  $p = [Windows.Media.VisualTreeHelper]::GetParent($element)
  while ($p) {
    $fe = $p -as [Windows.FrameworkElement]
    if ($fe -and $fe.IsMouseOver -and $fe.ToolTip) { return [string]$fe.ToolTip }
    $p = [Windows.Media.VisualTreeHelper]::GetParent($p)
  }
  ''
}

# A short dwell, so sweeping the pointer across a row commits one message rather
# than strobing through everything on the way to the thing you meant.
$script:HoverPending = $null
$script:Hover = ''
$script:Flash = ''
$script:HoverTimer = New-Object Windows.Threading.DispatcherTimer
$script:HoverTimer.Interval = [TimeSpan]::FromMilliseconds(240)
$script:HoverTimer.Add_Tick({
  $script:HoverTimer.Stop()
  if ($null -eq $script:HoverPending) { return }
  $s = [string]$script:HoverPending
  $script:HoverPending = $null
  if ($script:Hover -eq $s) { return }
  $script:Hover = $s
  Show-Message
})
function Set-Hover([string]$s) {
  if ($script:Resizing) { return }
  if ($script:Hover -eq $s -and $null -eq $script:HoverPending) { return }
  $script:HoverPending = $s
  $script:HoverTimer.Stop()
  $script:HoverTimer.Start()
}

function Show-Message {
  $txt = ''; $col = $Pal.dim; $arw = $Pal.dim
  $glyph = [string][char]0x2192; $fam = 'Segoe UI'
  if ($script:Hover) {
    $txt = $script:Hover; $col = $Pal.text; $arw = $Pal.blue
    $glyph = [string][char]0x25CF; $fam = 'Segoe UI'
  } elseif ($script:Flash) {
    $txt = $script:Flash; $col = $Pal.blue; $arw = $Pal.blue
  }
  $el.Advice.Text = $txt
  $el.Advice.FontFamily = $fam
  $el.Advice.Foreground = (Br $col)
  $el.AdviceArrow.Text = $glyph
  $el.AdviceArrow.Foreground = (Br $arw)
  $el.AdviceBox.Visibility = if ($txt) { 'Visible' } else { 'Collapsed' }
}

function Flash([string]$msg) {
  $script:Flash = $msg
  Show-Message
  $t = New-Object Windows.Threading.DispatcherTimer
  $t.Interval = [TimeSpan]::FromSeconds(3)
  $t.add_Tick({ $script:Flash = ''; $this.Stop(); Show-Message })
  $t.Start()
}

# --- the state a checkpoint is in --------------------------------------------
# The one judgement this panel makes, and the only reason a row has a colour.
# Four outcomes, in the order they outrank each other:
#
#   open        the window that wrote it is STILL RUNNING. Resuming makes a
#               second window on one strand; they diverge and nothing merges
#               them. Go back to that window instead - it has the context.
#   behind      the session kept working after it parked, by more than the
#               collector's stale threshold. The checkpoint describes a state
#               the work has moved past, so resuming it loses the difference.
#   unstamped   no `session=` line, so there is no window to ask about. Old
#               checkpoints, from before the stamp existed. Readable, resumable,
#               just not checkable.
#   ready       nothing else is true: the window is closed, the checkpoint is
#               the newest thing that happened, pick it up.
function State-Of($C, [double]$StaleAfter) {
  if ([int]$C.alive -eq 1) {
    return @{ key = 'open'; word = 'open'; glyph = [string][char]0x25CF; colour = $Pal.blue
              ground = $OpenBrush
              why = "the window that wrote this is still open. Resuming here starts a SECOND window on one strand and they will diverge with nothing to merge them - go back to that window instead, it still has the context this file is a summary of." }
  }
  if (-not [string]$C.sid) {
    return @{ key = 'unstamped'; word = 'no stamp'; glyph = [string][char]0x25CC; colour = $Pal.grey
              ground = $null
              why = "no session stamp, so there is no window to check this against - it predates the stamp. Resumable, just not checkable: read the branch and HEAD it records against the tree before trusting it." }
  }
  if ([double]$C.behind_min -ge $StaleAfter) {
    return @{ key = 'behind'; word = ('behind {0}' -f (Age ([double]$C.behind_min))); glyph = [string][char]0x25B2
              colour = $Pal.orange; ground = $BehindBrush
              why = ("the session worked on for {0} after writing this, so the checkpoint is behind the work. Resume it and you resume from that far back - what happened in between was never written down anywhere." -f (Age ([double]$C.behind_min))) }
  }
  @{ key = 'ready'; word = 'ready'; glyph = [string][char]0x25CB; colour = $Pal.green
     ground = $null
     why = "the window is closed and nothing happened after the checkpoint was written, so this is the whole state of that work. Enter resumes it in its own directory." }
}

# --- the row -----------------------------------------------------------------
function New-Row {
  param($C, [double]$StaleAfter, [bool]$Selected, [bool]$Detail, [bool]$Dim)
  $st = State-Of $C $StaleAfter

  # Two borders, as next door: the outer owns selection - a ring round the whole
  # row - and the inner keeps the state accent as a stripe down the left edge.
  $sel = New-Object Windows.Controls.Border
  $sel.CornerRadius = New-Object Windows.CornerRadius (6)
  $sel.Margin = '5,1,7,1'
  $sel.BorderThickness = New-Object Windows.Thickness (1)
  $sel.BorderBrush = (Br $(if ($Selected) { $Pal.blue } else { 'Transparent' }))
  $rest = if ($Selected) { (Br $Pal.sel) }
          elseif ($st.ground) { $st.ground }
          else { $GhostBrush }
  $sel.Background = $rest
  if ($Dim) { $sel.Opacity = 0.45 }
  $sel.add_MouseEnter({ param($x, $e)
    if ($x.Background -ne $RowBrush) {
      if ($x.Tag) { $x.Tag.rest = $x.Background }
      $x.Background = $RowBrush }
    $x.Opacity = 1.0 })
  $sel.add_MouseLeave({ param($x, $e)
    if ($x.Background -eq $RowBrush) {
      $x.Background = $(if ($x.Tag -and $x.Tag.rest) { $x.Tag.rest } else { $GhostBrush }) }
    if ($x.Tag -and $x.Tag.dim) { $x.Opacity = 0.45 } })

  $shell = New-Object Windows.Controls.Border
  $shell.Padding = '10,7,10,8'
  $shell.BorderThickness = New-Object Windows.Thickness (3, 0, 0, 0)
  # The stripe is the state, always - unlike next door, where it means "running"
  # and is absent the rest of the time. Here every row has a state and the
  # stripe is the fastest way to sort a list of them by eye.
  $shell.BorderBrush = (Br $st.colour)
  $sel.Child = $shell

  $outer = New-Object Windows.Controls.StackPanel
  $shell.Child = $outer

  # --- line 1: state glyph, project / topic, age -----------------------------
  $l1 = New-Object Windows.Controls.Grid
  foreach ($w in 'Auto', '*', 'Auto') {
    $cd = New-Object Windows.Controls.ColumnDefinition
    $cd.Width = if ($w -eq 'Auto') { [Windows.GridLength]::Auto } else { New-Object Windows.GridLength (1, 'Star') }
    $l1.ColumnDefinitions.Add($cd)
  }
  $gl = Text-Block $st.glyph 10 $st.colour
  $gl.Margin = '0,2,8,0'; $gl.VerticalAlignment = 'Top'
  Tip $gl $st.why
  [Windows.Controls.Grid]::SetColumn($gl, 0); $l1.Children.Add($gl) | Out-Null

  # The topic is the identity of the strand and the project is where it lives,
  # so the topic is what is bright. It is also the argument /unpark takes, which
  # is the other reason it must be the readable half: what you see on the row is
  # literally what gets typed.
  $names = New-Object Windows.Controls.StackPanel
  $names.Orientation = 'Horizontal'
  $pj = Text-Block ($C.project + '  ') 10 $Pal.faint
  $pj.VerticalAlignment = 'Bottom'; $pj.Margin = '0,0,0,1'
  Tip $pj ("project directory: " + $(if ($C.cwd) { [string]$C.cwd } else { 'not known - no session stamp and no other checkpoint in this project has one' }))
  $names.Children.Add($pj) | Out-Null
  $tp = Text-Block ([string]$C.topic) 12 $Pal.text
  $tp.FontWeight = 'SemiBold'
  Tip $tp ("/unpark {0} - the topic is the argument, matched as a substring, so this is what resuming types" -f $C.topic)
  $names.Children.Add($tp) | Out-Null
  # The state in words, immediately after the name, for everything the glyph and
  # the ground cannot say - "behind 4h" is a quantity and a colour cannot carry
  # one.
  $sw = Text-Block ('  ' + $st.word) 9.5 $st.colour
  $sw.VerticalAlignment = 'Bottom'; $sw.Margin = '0,0,0,1'
  Tip $sw $st.why
  $names.Children.Add($sw) | Out-Null
  [Windows.Controls.Grid]::SetColumn($names, 1); $l1.Children.Add($names) | Out-Null

  $ag = Text-Block (Age ([double]$C.age_min)) 11 (Age-Color ([double]$C.age_min))
  $ag.TextAlignment = 'Right'; $ag.MinWidth = 34; $ag.VerticalAlignment = 'Center'
  Tip $ag ("written {0}. A checkpoint records what was true then - compare its branch and HEAD against the tree before trusting it, which is the first thing /unpark is told to do." -f `
           ([datetimeoffset]::FromUnixTimeSeconds([long]$C.written).LocalDateTime.ToString('ddd d MMM HH:mm')))
  [Windows.Controls.Grid]::SetColumn($ag, 2); $l1.Children.Add($ag) | Out-Null
  $outer.Children.Add($l1) | Out-Null

  # --- line 2: the next step -------------------------------------------------
  # The single most useful line on the row, and the reason this panel is worth
  # having at all: it is the one thing that tells you whether picking this up
  # now is five minutes of work or an afternoon. Trimmed to one line - the whole
  # section is on hover, and in full under d.
  if ($C.next) {
    $nx = Text-Block ([string]$C.next) 10 $Pal.dim 'Segoe UI'
    $nx.Margin = '18,4,0,0'
    $nx.TextTrimming = 'CharacterEllipsis'
    $nx.TextWrapping = 'NoWrap'
    Tip $nx ('next step - ' + [string]$C.next)
    $outer.Children.Add($nx) | Out-Null
  }

  # --- line 3: where, and whether anything was left open ---------------------
  $l3 = New-Object Windows.Controls.StackPanel
  $l3.Orientation = 'Horizontal'; $l3.Margin = '18,4,0,0'
  $cw = Text-Block $(if ($C.cwd) { [string]$C.cwd } else { '(directory unknown)' }) 9 $Pal.faint
  $cw.TextTrimming = 'CharacterEllipsis'; $cw.MaxWidth = 250
  Tip $cw $(if ($C.cwd) {
      "resuming opens a terminal here and runs claude ""/unpark $($C.topic)"". e opens the folder instead." }
    else { "no directory known for this checkpoint, so it cannot be resumed from here - open it with o and cd there yourself." })
  $l3.Children.Add($cw) | Out-Null
  # Something the parker left for you to decide. Rare, and the whole point of
  # the section - a checkpoint with an open question in it is one you should not
  # resume without reading first.
  if ($C.blocked) {
    $bk = Text-Block '   open question' 9 $Pal.yellow
    Tip $bk ('blocked / open - ' + [string]$C.blocked)
    $l3.Children.Add($bk) | Out-Null
  }
  $outer.Children.Add($l3) | Out-Null

  # --- detail ----------------------------------------------------------------
  # What the row has no room for and you only want on one checkpoint at a time.
  # Task in flight first, because that is the paragraph that says what the work
  # IS - the row says what to do next, which is only meaningful once you have
  # remembered what you were doing.
  if ($Detail -and $Selected) {
    $rule = New-Object Windows.Controls.Border
    $rule.Height = 1; $rule.Background = (Br $Pal.line); $rule.Margin = '18,8,4,7'
    $outer.Children.Add($rule) | Out-Null
    if ($C.task) {
      $d1 = Text-Block ([string]$C.task) 9.5 $Pal.dim 'Segoe UI'
      $d1.TextWrapping = 'Wrap'; $d1.Margin = '18,0,4,0'
      $outer.Children.Add($d1) | Out-Null
    }
    if ($C.blocked) {
      $d2 = Text-Block ('open: ' + [string]$C.blocked) 9.5 $Pal.yellow 'Segoe UI'
      $d2.TextWrapping = 'Wrap'; $d2.Margin = '18,6,4,0'
      $outer.Children.Add($d2) | Out-Null
    }
    $d3 = Text-Block ("{0}   {1}" -f $C.file, $(if ($C.short) { "session $($C.short)" } else { 'unstamped' })) 9 $Pal.faint
    $d3.Margin = '18,7,0,0'
    Tip $d3 ([string]$C.path)
    $outer.Children.Add($d3) | Out-Null
  }

  $sel.Tag = @{ rest = $rest; file = [string]$C.file; state = $st.key }
  $sel
}

# --- legend and keys ---------------------------------------------------------
function Legend-Line($parts) {
  $sp = New-Object Windows.Controls.StackPanel
  $sp.Orientation = 'Horizontal'; $sp.Margin = '0,0,0,4'
  foreach ($p in $parts) {
    $t = Text-Block $p[0] 9 $p[1]
    if ($p.Count -gt 2) { $t.Margin = $p[2] }
    $sp.Children.Add($t) | Out-Null
  }
  $sp
}

function Build-Legend {
  $L = $el.Legend
  $L.Children.Clear()
  $L.Children.Add((Legend-Line @(
    @("$([char]0x25CB) ready", $Pal.green, '0,0,10,0'),
    @("$([char]0x25B2) behind the work", $Pal.orange, '0,0,10,0'),
    @("$([char]0x25CF) window still open", $Pal.blue, '0,0,10,0'),
    @("$([char]0x25CC) no stamp", $Pal.grey)))) | Out-Null
  $L.Children.Add((Legend-Line @(
    @('enter', $Pal.blue, '0,0,7,0'),
    @('opens a terminal in that directory running /unpark on the topic', $Pal.dim)))) | Out-Null
  $L.Children.Add((Legend-Line @(
    @('line 2', $Pal.faint, '0,0,7,0'),
    @('is the checkpoint''s own next step - d opens the rest of it', $Pal.dim)))) | Out-Null
  $L.Children.Add((Legend-Line @(, @('hover anything - the line below says what it is', $Pal.faint)))) | Out-Null
}

$KEYMAP = @(
  @('j k', 'move the selection'),     @('1-9', 'select that row'),
  @('g G', 'first / last row'),       @('d',   'the rest of the checkpoint'),
  @('enter', 'resume it in a terminal'), @('y', 'copy the resume command'),
  @('o',   'open the checkpoint file'), @('e', 'open the project folder'),
  @('x x', 'delete it - twice, and it is gone'),
  @('r',   're-read the directory'),  @('f',   'fold the footer'),
  @('p',   'pin / unpin on top'),     @('l',   'the legend'),
  @('+ -', 'zoom, or wheel the corner'), @('0', 'reset size and zoom'),
  @('?',   'this list'),              @('esc', 'hide to the tray'),
  @('q',   'quit')
)
function Build-Keys {
  $K = $el.Keys
  $K.Children.Clear()
  for ($i = 0; $i -lt $KEYMAP.Count; $i += 2) {
    $row = New-Object Windows.Controls.Grid
    $row.Margin = '0,0,0,3'
    foreach ($w in 'Auto', '*', 'Auto', '*') {
      $cd = New-Object Windows.Controls.ColumnDefinition
      $cd.Width = if ($w -eq 'Auto') { [Windows.GridLength]::Auto } else { New-Object Windows.GridLength (1, 'Star') }
      $row.ColumnDefinitions.Add($cd)
    }
    $pairs = @(, $KEYMAP[$i])
    if ($i + 1 -lt $KEYMAP.Count) { $pairs += , $KEYMAP[$i + 1] }
    $col = 0
    foreach ($p in $pairs) {
      $kk = Text-Block $p[0] 9 $Pal.blue
      $kk.MinWidth = 30; $kk.Margin = '0,0,7,0'
      [Windows.Controls.Grid]::SetColumn($kk, $col); $row.Children.Add($kk) | Out-Null
      $dd = Text-Block $p[1] 9 $Pal.faint
      $dd.Margin = '0,0,12,0'
      [Windows.Controls.Grid]::SetColumn($dd, $col + 1); $row.Children.Add($dd) | Out-Null
      $col += 2
    }
    $K.Children.Add($row) | Out-Null
  }
}

# --- data --------------------------------------------------------------------
$script:Data = $null
$script:Visible = @()
$script:Sel = 0
$script:Left = $Every
$script:Resizing = $false
# The file the last x was pressed on. Deleting a checkpoint destroys the only
# record of where that work stood, so it takes two presses on the same row - and
# the arming is cleared by anything else you do, including moving off the row.
$script:ArmedDelete = ''
# The same idea for resuming a checkpoint whose window is still open. That one
# is not destructive - you may well mean it - so the first press explains what
# it will do and the second goes ahead.
$script:ArmedOpen = ''

function Collect-Cmd {
  $sh = ($Script -replace '\\', '/') -replace '^C:', '/c'
  "'$sh' --parked --json --no-update-check 2>/dev/null"
}

$script:CollectPS = $null
$script:CollectHandle = $null
$script:Collecting = $false
$script:CollectAt = [datetime]::MinValue

function Start-Collect {
  if ($script:CollectPS) { return }
  try {
    $ps = [PowerShell]::Create()
    $ps.AddScript('param($bash, $cmd) (& $bash -lc $cmd) -join [char]10') | Out-Null
    $ps.AddArgument($Bash) | Out-Null
    $ps.AddArgument((Collect-Cmd)) | Out-Null
    $script:CollectPS = $ps
    $script:CollectHandle = $ps.BeginInvoke()
    $script:Collecting = $true
    $script:CollectAt = Get-Date
  } catch {
    if ($script:CollectPS) { $script:CollectPS.Dispose() }
    $script:CollectPS = $null; $script:Collecting = $false
  }
}

function Poll-Collect {
  if (-not $script:CollectPS) { return }
  if (-not $script:CollectHandle.IsCompleted) { return }
  $ok = $false
  try {
    $txt = ($script:CollectPS.EndInvoke($script:CollectHandle) | Out-String)
    if ($txt.Trim()) {
      $d = $txt | ConvertFrom-Json
      if ($d) { $script:Data = $d; $ok = $true }
    }
  } catch { }
  try { $script:CollectPS.Dispose() } catch { }
  $script:CollectPS = $null; $script:CollectHandle = $null; $script:Collecting = $false
  if ($ok) { Update-View }
}

function Get-Data {
  try {
    $raw = & $Bash -lc (Collect-Cmd)
    if (-not $raw) { return $null }
    return ($raw -join "`n") | ConvertFrom-Json
  } catch { return $null }
}

# Small writes behind a keystroke - deleting a file, mostly. Nothing on screen
# waits for these; handles are kept only so the runspaces can be disposed.
$script:Bg = @()
function Start-Bg([string]$cmd) {
  try {
    $ps = [PowerShell]::Create()
    $ps.AddScript('param($bash, $cmd) & $bash -lc $cmd 2>&1 | Out-Null') | Out-Null
    $ps.AddArgument($Bash) | Out-Null
    $ps.AddArgument($cmd) | Out-Null
    $script:Bg += @{ ps = $ps; h = $ps.BeginInvoke() }
  } catch { }
}
function Reap-Bg {
  if (-not $script:Bg.Count) { return }
  $keep = @()
  foreach ($b in $script:Bg) {
    if ($b.h.IsCompleted) {
      try { $b.ps.EndInvoke($b.h) | Out-Null } catch { }
      try { $b.ps.Dispose() } catch { }
    } else { $keep += $b }
  }
  $script:Bg = $keep
}

# Newest first, which is the order the collector emits and the order the pane's
# own listing uses. Nothing re-sorts by state: a list that reorders itself when
# a window closes is one you cannot learn the shape of.
function Get-Visible {
  if (-not $script:Data) { return , @() }
  , @($script:Data.checkpoints)
}

function Selected-Row {
  if ($script:Sel -le 0 -or $script:Sel -gt $script:Visible.Count) { return $null }
  $script:Visible[$script:Sel - 1]
}

# --- what the panel does -----------------------------------------------------
# The resume command, in one place, because it is both what Enter runs and what
# y copies and those two must never drift apart.
#
# "general" is not a topic - it is what the collector calls a checkpoint whose
# filename carries no topic at all, the old one-per-project "<project>.md" from
# before parallel strands each got their own. Passing it as an argument would
# have /unpark look for a slug called "general", find nothing, and say so; with
# no argument it lists what is actually there for that project and asks, which
# is the right behaviour for the one case where the file cannot name itself.
function Resume-Args($C) {
  if ([string]$C.topic -eq 'general') { return '/unpark' }
  '/unpark {0}' -f $C.topic
}

# CLI flags that put the new process back on the model and effort the parked
# session was last answering with, cached in token-meta.tsv and carried
# through --parked --json. Without these, a bare `claude "/unpark ..."`
# starts on the account default instead - a session parked on sonnet/medium
# would silently reopen on opus/high. Empty when the checkpoint predates the
# cache columns or the session was never measured; a fresh start on defaults
# is the right fallback there, not a refusal.
function Resume-Flags($C) {
  $f = ''
  if ($C.model)  { $f += ' --model {0}' -f $C.model }
  if ($C.effort) { $f += ' --effort {0}' -f $C.effort }
  $f
}

# --- action log ---------------------------------------------------------------
#
# Nothing on disk recorded what this widget did. The habit it exists to support -
# resuming a parked window from here instead of typing into a cold one - could
# therefore be neither verified now nor measured a week from now, which is the
# same hole the gap-warn hook has: the advice is cheap, knowing whether it was
# taken is not. One tab-separated row per action, shaped like token-poke.log so
# the two can be read together.
#
# Columns: ts, action, topic, project, sid, alive, age_min, behind_min, cwd
#   sid         the 8 characters token-history.csv keys on, so a resume can be
#               joined to the cycles it went on to produce
#   alive       the parked window was STILL OPEN when this ran - resuming makes
#               a second window on one strand, the mistake worth counting
#   age_min     how stale the checkpoint was at the moment it was used
#   behind_min  work done after the checkpoint was written, which a resume
#               silently starts behind
#
# Actions: resume, resume-armed (the still-open warning, first press),
# resume-failed, resume-nocwd, copy, open-file, open-folder.
#
# Fail-open throughout. A widget that throws because a log is unwritable is
# worse than no log, so the whole write is guarded and nothing upstream ever
# sees an error.
$script:ParkedLog = Join-Path $Root 'token-parked.log'
function Log-Parked($Action, $C) {
  try {
    if (-not $C) { return }
    $row = @(
      (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss'), $Action, [string]$C.topic,
      [string]$C.project, [string]$C.short, [int]$C.alive, [int]$C.age_min,
      [int]$C.behind_min, [string]$C.cwd) -join "`t"
    Add-Content -LiteralPath $script:ParkedLog -Value $row -Encoding utf8 -ErrorAction Stop
  } catch { }
}

# A terminal in the project directory, already running it. Windows Terminal when
# it is there, because a bare conhost window is a worse place to hold a session
# for an hour; plain cmd otherwise, which is always there.
#
# cmd.exe rather than powershell as the inner shell on purpose: on PATH the
# launcher is claude.cmd, and cmd finds it without the ExecutionPolicy question
# claude.ps1 would raise on a locked-down machine.
function Unpark-Row {
  $c = Selected-Row
  if (-not $c) { Flash 'nothing selected'; return }
  if (-not $c.cwd) {
    Flash ("{0}: no directory known for this one - open it with o and cd there yourself" -f $c.topic)
    return
  }
  if (-not (Test-Path $c.cwd)) {
    Flash ("{0}: {1} is not there any more" -f $c.topic, $c.cwd)
    Log-Parked 'resume-nocwd' $c
    return
  }
  if ([int]$c.alive -eq 1) {
    # Not refused - you may well mean it, and the panel does not get to decide
    # that. Said out loud, because the cost of doing it by accident is two
    # windows on one strand and no way to merge them.
    Flash ("{0}: that window is STILL OPEN - resuming makes a second one. Press enter again if you mean it." -f $c.topic)
    if ($script:ArmedOpen -ne $c.file) { $script:ArmedOpen = $c.file; Log-Parked 'resume-armed' $c; return }
  }
  $script:ArmedOpen = ''
  # Through the shim, never `claude` directly: a session started from this
  # widget would otherwise inherit CLAUDE_CODE_CHILD_SESSION and come up with
  # transcript saving off and no sessions/<pid>.json - silently unmeasurable.
  # token-unpark-launch.cmd strips the markers in the new console. Falls back to
  # a bare launch if the shim has gone missing: a polluted session beats none.
  $shim = Join-Path $Root 'token-unpark-launch.cmd'
  if (Test-Path $shim) {
    $inner = '"{0}"{1} "{2}"' -f $shim, (Resume-Flags $c), (Resume-Args $c)
  } else {
    $inner = 'claude{0} "{1}"' -f (Resume-Flags $c), (Resume-Args $c)
  }
  try {
    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    if ($wt) {
      Start-Process -FilePath $wt.Source `
        -ArgumentList @('-d', $c.cwd, 'cmd.exe', '/k', $inner) | Out-Null
    } else {
      Start-Process -FilePath 'cmd.exe' -ArgumentList @('/k', $inner) `
        -WorkingDirectory $c.cwd | Out-Null
    }
    Flash ("resuming {0} in {1}" -f $c.topic, (Split-Path -Leaf $c.cwd))
    Log-Parked 'resume' $c
  } catch {
    Flash ("could not open a terminal: {0}" -f $_.Exception.Message)
    Log-Parked 'resume-failed' $c
  }
}

function Copy-Resume {
  $c = Selected-Row
  if (-not $c) { return }
  $cmd = 'cd "{0}" && claude{1} "{2}"' -f $c.cwd, (Resume-Flags $c), (Resume-Args $c)
  try { [System.Windows.Clipboard]::SetText($cmd); Log-Parked 'copy' $c; Flash ("copied: claude{0} ""{1}""" -f (Resume-Flags $c), (Resume-Args $c)) }
  catch { Flash 'could not reach the clipboard' }
}

function Open-Checkpoint {
  $c = Selected-Row
  if (-not $c) { return }
  if (-not (Test-Path $c.path)) { Flash 'the checkpoint file is gone'; return }
  try { Start-Process $c.path; Log-Parked 'open-file' $c; Flash ("opened {0}" -f $c.file) }
  catch { Flash 'nothing is registered to open a .md file' }
}

function Open-Folder {
  $c = Selected-Row
  if (-not $c) { return }
  if ($c.cwd -and (Test-Path $c.cwd)) { Start-Process explorer.exe $c.cwd; Flash ("opened {0}" -f $c.project) }
  if ($c.cwd -and (Test-Path $c.cwd)) { Start-Process explorer.exe $c.cwd; Log-Parked 'open-folder' $c; Flash ("opened {0}" -f $c.project) }
}

# Twice, on the same row. A checkpoint is the only record of where that work
# stood - measured re-derivation without one is ~34k tokens against ~5k with -
# so deleting one by a mistyped key is the most expensive keystroke in either
# panel. The armed row is cleared by moving, refreshing, or pressing anything
# else, so the two presses have to be deliberate and consecutive.
function Delete-Checkpoint {
  $c = Selected-Row
  if (-not $c) { return }
  if ($script:ArmedDelete -ne $c.file) {
    $script:ArmedDelete = $c.file
    Flash ("x again to delete {0} - this is the only record of that work" -f $c.topic)
    return
  }
  $script:ArmedDelete = ''
  $sh = ([string]$c.path -replace '\\', '/') -replace '^C:', '/c'
  Start-Bg ("rm -f '$sh'")
  # Dropped from the list at once rather than waiting for the next collect: a
  # row that survives the keystroke that deleted it reads as a key that did not
  # take, and the second press would then land on something else.
  $script:Data.checkpoints = @($script:Data.checkpoints | Where-Object { $_.file -ne $c.file })
  if ($script:Sel -gt @($script:Data.checkpoints).Count) { $script:Sel = @($script:Data.checkpoints).Count }
  Update-View
  Flash ("deleted {0}" -f $c.file)
}

# --- drawing -----------------------------------------------------------------
function Show-Loading {
  $el.Rows.Children.Clear()
  $sp = New-Object Windows.Controls.StackPanel
  $sp.Margin = '14,22,14,22'; $sp.HorizontalAlignment = 'Center'
  $t1 = Text-Block 'reading checkpoints' 11 $Pal.text 'Segoe UI'
  $t1.HorizontalAlignment = 'Center'
  $sp.Children.Add($t1) | Out-Null
  $t2 = Text-Block 'one directory and two side tables - no session is measured for this' 9 $Pal.faint 'Segoe UI'
  $t2.TextWrapping = 'Wrap'; $t2.TextAlignment = 'Center'; $t2.Margin = '0,7,0,0'; $t2.MaxWidth = 300
  $sp.Children.Add($t2) | Out-Null
  $el.Rows.Children.Add($sp) | Out-Null
  if ($el.Legend.Children.Count -eq 0) { Build-Legend; Build-Keys }
}

function Draw-Rows {
  $el.Rows.Children.Clear()
  $script:Visible = Get-Visible
  $n = $script:Visible.Count
  if ($script:Sel -gt $n) { $script:Sel = $n }
  if ($n -eq 0) {
    $t = Text-Block 'nothing parked' 10 $Pal.faint
    $t.Margin = '14,8,14,8'
    Tip $t 'no checkpoints on disk. /park writes one - task in flight, file:line state, verified vs assumed, next step - and it is what makes ending a session the cheap option.'
    $el.Rows.Children.Add($t) | Out-Null
    return
  }
  $stale = [double]$(if ($script:Data.stale_after) { $script:Data.stale_after } else { 15 })
  $anySel = ($script:Sel -gt 0 -and $script:Sel -le $n)
  for ($i = 0; $i -lt $n; $i++) {
    $c = $script:Visible[$i]
    $isSel = ($script:Sel -eq $i + 1)
    $row = New-Row $c $stale $isSel $script:View.detail ($anySel -and -not $isSel)
    $row.Tag.idx = $i + 1
    $row.Tag.dim = ($anySel -and -not $isSel)
    # One handler for both clicks. A Border is not a Control, so it has no
    # MouseDoubleClick of its own - the count comes off the event, which is
    # where WPF puts it for every mouse button event anyway.
    $row.Add_MouseLeftButtonUp({
      param($sender, $e)
      $e.Handled = $true
      $ix = [int]$sender.Tag.idx
      if ($e.ClickCount -ge 2) {
        # The mouse spelling of Enter, which is this panel's verb.
        $script:Sel = $ix; Update-View; Unpark-Row; return
      }
      $script:Sel = $(if ($script:Sel -eq $ix) { 0 } else { $ix })
      $script:ArmedDelete = ''; $script:ArmedOpen = ''
      Update-View })
    $el.Rows.Children.Add($row) | Out-Null
  }
  if ($script:Sel -gt 0 -and $script:Sel -le $el.Rows.Children.Count) {
    $el.Rows.UpdateLayout()
    $el.Rows.Children[$script:Sel - 1].BringIntoView()
  }
}

function Apply-Chrome {
  $win.Topmost = [bool]$script:View.pinned
  $el.Pin.Foreground = (Br $(if ($script:View.pinned) { $Pal.blue } else { $Pal.faint }))
  $el.FootBody.Visibility = $(if ($script:View.foot) { 'Visible' } else { 'Collapsed' })
  $el.FootRule.Visibility = $(if ($script:View.foot) { 'Visible' } else { 'Collapsed' })
  $el.Fold.Text = $(if ($script:View.foot) { [string][char]0x25BE } else { [string][char]0x25B8 })
  $el.Legend.Visibility = $(if ($script:View.keys) { 'Collapsed' } else { 'Visible' })
  $el.Keys.Visibility   = $(if ($script:View.keys) { 'Visible' } else { 'Collapsed' })
}

function Update-View {
  if (-not $script:Data) { Show-Loading; Apply-Chrome; return }
  if ($el.Legend.Children.Count -eq 0) { Build-Legend; Build-Keys }
  Draw-Rows
  $all = @($script:Data.checkpoints)
  $n = $all.Count
  $stale = [double]$(if ($script:Data.stale_after) { $script:Data.stale_after } else { 15 })
  # The header counts what is worth acting on rather than what exists. A total
  # says how full the directory is; "3 ready" says how many strands you could
  # pick up right now, which is the question the panel is open for.
  $ready = @($all | Where-Object { (State-Of $_ $stale).key -eq 'ready' }).Count
  $open  = @($all | Where-Object { [int]$_.alive -eq 1 }).Count
  $el.Count.Text = $(if ($n -eq 0) { '' } else { '{0} of {1}' -f $ready, $n })
  Tip $el.Count $(if ($n -eq 0) { 'nothing parked' } else {
    "{0} checkpoint{1} on disk, {2} ready to pick up{3}. The rest are either behind the work that followed them or belong to a window that is still open." -f `
      $n, $(if ($n -eq 1) { '' } else { 's' }), $ready, $(if ($open) { ", $open still open" } else { '' }) })
  # The dot is the panel's own state light: blue while there is something ready,
  # faint when the directory is empty or everything in it needs a decision first.
  $el.Dot.Foreground = (Br $(if ($ready -gt 0) { $Pal.blue } elseif ($n -gt 0) { $Pal.orange } else { $Pal.faint }))
  Apply-Chrome
}

function Toggle-Keys {
  $script:View.keys = -not $script:View.keys
  if ($script:View.keys) { $script:View.foot = $true }
  Apply-Chrome; Save-State
}

# --- keys --------------------------------------------------------------------
function Handle-Key {
  param($e)
  $k = $e.Key.ToString()
  $shift = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0
  $n = $script:Visible.Count

  # Anything that is not a second x disarms the delete, and anything that is not
  # a second enter disarms the open-window warning. Done here, once, rather than
  # in every branch - a confirmation that survives an unrelated keystroke is not
  # a confirmation.
  if ($k -ne 'X') { $script:ArmedDelete = '' }
  if ($k -ne 'Return') { $script:ArmedOpen = '' }

  if ($k -match '^(D|NumPad)([1-9])$') {
    $i = [int]$Matches[2]
    if ($i -le $n) { $script:Sel = $(if ($script:Sel -eq $i) { 0 } else { $i }); Update-View }
    return
  }

  switch ($k) {
    'Down'   { if ($n) { $script:Sel = [math]::Min($n, $script:Sel + 1); Update-View }; return }
    'Up'     { if ($n) { $script:Sel = [math]::Max(1, $script:Sel - 1); Update-View }; return }
    'J'      { if ($n) { $script:Sel = [math]::Min($n, $script:Sel + 1); Update-View }; return }
    'K'      { if ($n) { $script:Sel = [math]::Max(1, $script:Sel - 1); Update-View }; return }
    'G'      { if ($shift) { $script:Sel = $n } elseif ($n) { $script:Sel = 1 }
               Update-View; return }
    'Escape' { if ($script:Sel) { $script:Sel = 0; Update-View }
               elseif ($tray) { $win.Hide() } else { $win.Close() }; return }
    'Return' { if (-not $script:Sel -and $n) { $script:Sel = 1; Update-View }
               Unpark-Row; return }
    'D'      { $script:View.detail = -not $script:View.detail
               if (-not $script:Sel -and $n) { $script:Sel = 1 }
               Update-View; Save-State; return }
    'Y'      { if (-not $script:Sel -and $n) { $script:Sel = 1; Update-View }
               Copy-Resume; return }
    'O'      { if (-not $script:Sel -and $n) { $script:Sel = 1; Update-View }
               Open-Checkpoint; return }
    'E'      { if (-not $script:Sel -and $n) { $script:Sel = 1; Update-View }
               Open-Folder; return }
    'X'      { if (-not $script:Sel) { Flash 'select a row first'; return }
               Delete-Checkpoint; return }
    'R'      { $script:Left = $Every; Start-Collect; Flash 're-reading the checkpoint directory'; return }
    'F'      { $script:View.foot = -not $script:View.foot; Apply-Chrome; Save-State; return }
    'P'      { $script:View.pinned = -not $script:View.pinned; Apply-Chrome; Save-State
               Flash $(if ($script:View.pinned) { 'pinned on top' } else { 'unpinned' }); return }
    'L'      { $script:View.keys = $false; $script:View.foot = -not $script:View.foot
               Apply-Chrome; Save-State; return }
    'Q'      { if ($tray) { $tray.Visible = $false }; $win.Close(); return }
  }
  if ($k -eq 'OemQuestion' -or $k -eq 'Oem2' -or $k -eq 'Divide') { Toggle-Keys; return }
  if ($k -eq 'OemPlus' -or $k -eq 'Add') {
    $script:View.zoom = [double]$script:View.zoom + 0.05
    Apply-Size; Save-State; Flash ("zoom {0:N0}%" -f ($script:View.zoom * 100)); return
  }
  if ($k -eq 'OemMinus' -or $k -eq 'Subtract') {
    $script:View.zoom = [double]$script:View.zoom - 0.05
    Apply-Size; Save-State; Flash ("zoom {0:N0}%" -f ($script:View.zoom * 100)); return
  }
  if ($k -eq 'D0' -or $k -eq 'NumPad0') {
    $script:View.width = 440.0; $script:View.zoom = 1.0; $script:View.rowsH = 420.0
    Apply-Size; Save-State; Flash 'size reset'; return
  }
}

# --- glass -------------------------------------------------------------------
# Topmost means nothing ever draws over this, which is exactly why it has to get
# out of the way itself when the window you are working in is underneath.
# WGlass is defined by token-widget.ps1 too; both panels can be running, and
# Add-Type would throw on the second one - so the type is only added if this
# process does not already have it.
if (-not ('WGlass' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public struct WRECT { public int Left, Top, Right, Bottom; }
public static class WGlass {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out WRECT r);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Auto)]
  public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
}
'@
}

$GLASS = 0.55
$script:MouseIn = $false
$script:Hwnd = [IntPtr]::Zero

function Behind-Widget {
  try {
    if ($script:Hwnd -eq [IntPtr]::Zero) {
      $script:Hwnd = (New-Object Windows.Interop.WindowInteropHelper $win).Handle
    }
    if ($script:Hwnd -eq [IntPtr]::Zero) { return $false }
    $fg = [WGlass]::GetForegroundWindow()
    if ($fg -eq [IntPtr]::Zero -or $fg -eq $script:Hwnd) { return $false }
    if ([WGlass]::IsIconic($fg)) { return $false }
    $sb = New-Object System.Text.StringBuilder 256
    [WGlass]::GetClassName($fg, $sb, 256) | Out-Null
    if (@('Progman', 'WorkerW', 'Shell_TrayWnd', 'Windows.UI.Core.CoreWindow') -contains $sb.ToString()) {
      return $false
    }
    $a = New-Object WRECT; $b = New-Object WRECT
    if (-not [WGlass]::GetWindowRect($script:Hwnd, [ref]$a)) { return $false }
    if (-not [WGlass]::GetWindowRect($fg, [ref]$b)) { return $false }
    return ($a.Left -lt $b.Right -and $b.Left -lt $a.Right -and
            $a.Top -lt $b.Bottom -and $b.Top -lt $a.Bottom)
  } catch { return $false }
}
function Set-Glass {
  $want = 1.0
  if (-not $script:MouseIn -and (Behind-Widget)) { $want = $GLASS }
  if ([math]::Abs($win.Opacity - $want) -gt 0.005) { $win.Opacity = $want }
}

# --- tray --------------------------------------------------------------------
function Toggle-Panel {
  if ($win.Visibility -eq 'Visible') { $win.Hide() } else { $win.Show(); $win.Activate() }
}

$tray = $null
if (-not $NoTray) {
  $tray = New-Object System.Windows.Forms.NotifyIcon
  $ico = Join-Path $Root 'token-widget.ico'
  if (Test-Path $ico) { $tray.Icon = New-Object System.Drawing.Icon $ico }
  else { $tray.Icon = [System.Drawing.SystemIcons]::Information }
  $tray.Visible = $true
  $tray.Text = 'Parked checkpoints'
  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  $miShow = $menu.Items.Add('Show / hide')
  $miRef  = $menu.Items.Add('Re-read now')
  $menu.Items.Add('-') | Out-Null
  $miQuit = $menu.Items.Add('Quit')
  $tray.ContextMenuStrip = $menu
  $miShow.add_Click({ Toggle-Panel })
  $miRef.add_Click({ $script:Left = $Every; Start-Collect })
  $miQuit.add_Click({ $tray.Visible = $false; $win.Close() })
  $tray.add_MouseDoubleClick({ Toggle-Panel })
}

# --- interaction -------------------------------------------------------------
$el.Header.add_MouseLeftButtonDown({ $win.DragMove() })
$win.add_MouseEnter({ $script:MouseIn = $true;  Set-Glass })
$win.add_MouseLeave({ $script:MouseIn = $false; Set-Glass })
$win.Opacity = 1.0
$win.add_KeyDown({ param($sender, $e) Handle-Key $e })

$el.Close.add_MouseLeftButtonDown({
  $_.Handled = $true
  if ($tray) { $win.Hide() } else { $win.Close() } })
$el.Pin.add_MouseLeftButtonDown({
  $_.Handled = $true; $script:View.pinned = -not $script:View.pinned; Apply-Chrome; Save-State })
$el.Fold.add_MouseLeftButtonDown({
  $_.Handled = $true; $script:View.foot = -not $script:View.foot; Apply-Chrome; Save-State })
$el.Refresh.add_MouseLeftButtonDown({
  $_.Handled = $true; $script:Left = $Every; Start-Collect })
$el.LegendToggle.add_MouseLeftButtonDown({
  $_.Handled = $true; $script:View.keys = $false; $script:View.foot = $true
  Apply-Chrome; Save-State })
$el.KeysToggle.add_MouseLeftButtonDown({ $_.Handled = $true; Toggle-Keys })

# The corner: sideways for width, up and down for how tall the list gets before
# it scrolls, and the wheel for zoom. Screen coordinates, because the element
# being dragged is itself moving as the window widens.
$el.Grip.Background = (Br '#01000000')
$el.Grip.Padding = New-Object Windows.Thickness (5, 3, 3, 3)
$script:ResizeX = 0.0; $script:ResizeW = 0.0
$script:ResizeY = 0.0; $script:ResizeH = 0.0
Tip $el.Grip 'drag: sideways for width, up and down for how tall the list gets before it scrolls'
$el.Grip.add_MouseLeftButtonDown({
  param($sender, $e)
  $script:Resizing = $true
  $script:ResizeX = [System.Windows.Forms.Cursor]::Position.X
  $script:ResizeY = [System.Windows.Forms.Cursor]::Position.Y
  $script:ResizeW = [double]$script:View.width
  $script:ResizeH = [double]$script:View.rowsH
  $sender.CaptureMouse() | Out-Null
  $e.Handled = $true })
$el.Grip.add_MouseMove({
  param($sender, $e)
  if (-not $script:Resizing) { return }
  $dx = [System.Windows.Forms.Cursor]::Position.X - $script:ResizeX
  $dy = [System.Windows.Forms.Cursor]::Position.Y - $script:ResizeY
  $script:View.width = $script:ResizeW + ($dx / [double]$script:View.zoom)
  $script:View.rowsH = $script:ResizeH + ($dy / [double]$script:View.zoom)
  Apply-Size })
$el.Grip.add_MouseLeftButtonUp({
  param($sender, $e)
  if ($script:Resizing) {
    $script:Resizing = $false; $sender.ReleaseMouseCapture(); Save-State; $e.Handled = $true } })
$el.Grip.add_MouseWheel({
  param($sender, $e)
  $script:View.zoom = [double]$script:View.zoom + $(if ($e.Delta -gt 0) { 0.05 } else { -0.05 })
  Apply-Size; Save-State; $e.Handled = $true })

$win.add_Closing({
  Save-State
  if ($tray) { $tray.Visible = $false; $tray.Dispose() } })

# One timer at 1Hz for the countdown and the refresh, so the two can never
# disagree about when the next read is due.
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.add_Tick({
  Poll-Collect
  Reap-Bg
  $script:Left--
  if ($script:Left -le 0) { $script:Left = $Every; Start-Collect }
  $el.Countdown.Text = $(if ($script:Collecting) {
      $secs = [int]((Get-Date) - $script:CollectAt).TotalSeconds
      if ($secs -ge 10) { 'reading... {0}s' -f $secs } else { 'reading...' }
    } else { 'refresh {0}s' -f $script:Left })
  Set-Glass
})
$timer.Start()

Apply-Size
Apply-Chrome
if (-not $SelfTest) { Start-Collect }

try { if ($SelfTest) { $d = Get-Data; if ($d) { $script:Data = $d } }; Update-View } catch {
  if ($SelfTest) { throw }
  $el.Advice.Text = "could not read token-sessions.sh --parked --json: $_"
}

# Buildable and populatable without a window, so it can be checked from a
# terminal. A widget you can only test by looking at it is a widget nobody tests.
if ($SelfTest) {
  $timer.Stop()
  if ($tray) { $tray.Visible = $false; $tray.Dispose() }
  Write-Output ("bash        : " + $Bash)
  Write-Output ("checkpoints : " + $(if ($script:Data) { @($script:Data.checkpoints).Count } else { 'NO DATA' }))
  Write-Output ("rows        : " + $el.Rows.Children.Count)
  Write-Output ("header      : '" + $el.Count.Text + "'  dot=" + $el.Dot.Foreground.Color)
  Write-Output ("keys        : " + $el.Keys.Children.Count + " lines, " + $KEYMAP.Count + " bindings")
  Write-Output ("legend      : " + $el.Legend.Children.Count + " lines")
  $stale = [double]$(if ($script:Data.stale_after) { $script:Data.stale_after } else { 15 })
  Write-Output ("stale after : " + $stale + " min of work past a checkpoint")
  foreach ($c in $script:Visible) {
    $st = State-Of $c $stale
    Write-Output ("  row       : {0,-10} {1,-30} {2,5}  {3,-12} {4}" -f `
      $c.project, $c.topic, (Age ([double]$c.age_min)), $st.word,
      $(if ($c.cwd) { 'cwd ok' } else { 'NO CWD' }))
    Write-Output ("     resume : claude{0} ""{1}""   in {2}" -f (Resume-Flags $c), (Resume-Args $c), $c.cwd)
    Write-Output ("     next   : " + $(if ($c.next) { ([string]$c.next).Substring(0, [math]::Min(90, ([string]$c.next).Length)) } else { 'NONE' }))
  }
  function Wants {
    $el.Card.UpdateLayout()
    $el.Card.Measure((New-Object Windows.Size ([double]$script:View.width, [double]::PositiveInfinity)))
    [math]::Round($el.Rows.DesiredSize.Height)
  }
  $base = Wants
  Write-Output ("list        : {0} rows want {1}px, cap {2}px -> {3}" -f `
    $el.Rows.Children.Count, $base, [math]::Round($el.RowScroll.MaxHeight),
    $(if ($base -gt $el.RowScroll.MaxHeight) { 'scrolls' } else { 'fits' }))
  $script:Sel = 1; $script:View.detail = $true; Update-View
  $withD = Wants
  Write-Output ("  detail    : {0}px, {1}px more than closed" -f $withD, ($withD - $base))
  Write-Output ("  selected  : row1 ring=" + $el.Rows.Children[0].BorderBrush.Color +
                "  row2 opacity=" + $(if ($el.Rows.Children.Count -gt 1) { $el.Rows.Children[1].Opacity } else { 'n/a' }))
  $script:View.detail = $false; $script:Sel = 0; Update-View
  $script:View.width = 99999; $script:View.zoom = 9; Apply-Size
  Write-Output ("clamped     : width=" + $script:View.width + " zoom=" + $script:View.zoom)
  $script:View.width = 440; $script:View.zoom = 1.0; Apply-Size
  $script:View.foot = $false; Apply-Chrome
  Write-Output ("folded      : foot=" + $el.FootBody.Visibility + " chevron=" + $el.Fold.Text)
  $script:View.foot = $true; $script:View.keys = $true; Apply-Chrome
  Write-Output ("keys view   : legend=" + $el.Legend.Visibility + " keys=" + $el.Keys.Visibility)
  $script:View.keys = $false; Apply-Chrome
  exit 0
}

# The chrome buttons declare their hover text in the XAML, which is a REAL
# tooltip - a second window that floats over the rows. Swept over the tree and
# converted once, here, so the per-refresh guard inside Tip() is untouched.
function Convert-Tips($node) {
  if ($null -eq $node) { return }
  $fe = $node -as [Windows.FrameworkElement]
  if ($fe -and $fe.ToolTip -is [string]) {
    $t = [string]$fe.ToolTip
    $fe.ToolTip = $null
    Tip $fe $t
  }
  foreach ($child in [Windows.LogicalTreeHelper]::GetChildren($node)) {
    if ($child -is [Windows.DependencyObject]) { Convert-Tips $child }
  }
}
Convert-Tips $win

# Clicking away drops the selection, so the panel's resting state is "all of
# them". It also disarms the two confirmations, which is the point: a delete
# armed on Monday must not fire on Tuesday's first keystroke.
$win.Add_Deactivated({
  if ($script:Resizing) { return }
  $script:ArmedDelete = ''; $script:ArmedOpen = ''
  if ($script:Sel -ne 0) { $script:Sel = 0; Update-View }
})


# The clamp above ran before the window had ever been measured, so it could only
# guarantee the top edge. ContentRendered is the first moment ActualHeight means
# anything, and it is still before the user has touched the window - so this is
# the one chance to correct the bottom edge without overriding a placement they
# chose themselves. Once only, for that reason.
$win.Add_ContentRendered({
  if ($script:PlacementSettled) { return }
  $script:PlacementSettled = $true
  Clamp-Placement
})

# A second launch signals rather than starts (see the mutex at the top of this
# file), so the copy already running has to be listening for it. A second of
# latency on a double-click is imperceptible, and polling a handle costs nothing
# beside a refresh.
if ($script:ShowEvent) {
  $script:SoloTimer = New-Object Windows.Threading.DispatcherTimer
  $script:SoloTimer.Interval = [TimeSpan]::FromSeconds(1)
  $script:SoloTimer.Add_Tick({
    if (-not $script:ShowEvent.WaitOne(0)) { return }
    # Re-clamped rather than merely shown: much the likeliest reason to be
    # launching it a second time is that a display went away underneath it.
    Clamp-Placement
    $win.Show(); $win.Activate(); $win.Focus() | Out-Null
    # Off and on again is what raises a window that is already visible but
    # buried - setting Topmost to a value it already holds does nothing.
    $win.Topmost = $false; $win.Topmost = $true
    $win.Topmost = [bool]$script:View.pinned
  })
  $script:SoloTimer.Start()
}

$win.Show()
$win.Activate()
$win.Focus() | Out-Null
[System.Windows.Threading.Dispatcher]::Run()
