# token-widget.ps1 - the always-on-top readout for token-sessions.
#
# The pane in a terminal answers "what is happening" only while you are looking
# at it, and the whole thesis of the tool is that the expensive window is the
# one you cannot see. So this is a readout, not an alert: it sits in a corner
# and is always true, and the tray icon only exists to get it out of the way.
#
# It carries the same per-session facts the pane does - verdict, nickname and
# short id, context against the measured bands, growth per cycle against its
# budget, cache clock, cycles, weighted cost and the three grades - and the
# same keys, so what you already know how to press works here too. ? lists them.
#
# Everything is in tokens, weighted into input-equivalents (output x5, cache
# write x2, cache read x0.1). No currency: the point of comparison here is one
# cycle against another, and a dollar figure invites comparing against a bill.
#
# Nothing here is installed. WPF and WinForms both ship inside Windows
# PowerShell 5.1; every number comes from `token-sessions.sh --json`, which
# reads disk and costs no model tokens.
#
#   powershell -ExecutionPolicy Bypass -File token-widget.ps1
#   token-widget.vbs            same thing with no console window
#
# Hovering anything writes into the card's own message line rather than opening
# a ToolTip. A tooltip is a second window: it draws outside the panel, covers
# the row under it, and cannot be read while the pointer walks along a strip of
# bars - which is exactly how you read a sparkline.
#
# Filtering and sorting are not here. They are questions about the history and
# they belong with the history, in the pane's analytics tab; a corner readout
# showing four rows does not need a query language.
#
# View state - position, compact, fold, pinned, sizes - is remembered in
# token-widget-pos.json.

param(
  [int]$Every = 30,          # seconds between refreshes
  [switch]$TopLeft,          # start in the top-left instead of bottom-right
  [switch]$Compact,          # start minimised to the one live session
  [switch]$NoTray,           # no tray icon; closing the panel exits
  [switch]$SelfTest          # build and populate once, report, exit - no window
)

# --- one widget, not twenty-six ----------------------------------------------
# Nothing used to stop a second copy starting, and the tray icon is what made
# that expensive rather than merely untidy: closing the panel HIDES it, so every
# launch added a process and no launch ever removed one. Measured 2026-09-03,
# 461 hours into an uptime: 26 live copies, ~2 GB of working set between them,
# 23 of them started inside one 14-hour stretch.
#
# The memory was not the expensive part. Each copy runs its own refresh timer
# and its own collect loop, and a collect spawns something over a hundred
# short-lived processes - so twenty-six of them overlapping turned a
# seven-second collect into a 140-second one. Start-Collect's guard could not
# help: it serialises collects WITHIN a process, and these were 26 processes.
#
# Worth naming the trap, because the panel fell into it: at that load a no-op
# process spawn measured ~2s, and the countdown's own hover text blamed the
# machine's antivirus for it. Nothing was wrong with Defender. When a tool
# spawns a hundred processes per pass, "spawning is slow" is a claim about how
# many copies of the tool are running before it is a claim about the machine.
#
# Local\ rather than Global\: the scope that matters is one desktop session, and
# a Global name would also block a second user on the same machine. An abandoned
# mutex - the previous copy killed rather than closed - throws on WaitOne, and
# that means we DID acquire it, so it is success and not failure. The handle
# lives in a script-scope variable so that nothing collects it and releases the
# mutex out from under a running widget.
if (-not $SelfTest -and -not $env:TOKEN_WIDGET_MULTI) {
  # A second launch is a request to SEE the widget, so it hands that job to the
  # copy already running instead of dying quietly - which is what makes the
  # mutex safe when the saved position is on a display that has gone away.
  $script:ShowEvent = New-Object System.Threading.EventWaitHandle($false,
    [System.Threading.EventResetMode]::AutoReset, 'Local\claude-token-widget-show')
  $script:SoloMutex = New-Object System.Threading.Mutex($false, 'Local\claude-token-widget')
  $got = $false
  try   { $got = $script:SoloMutex.WaitOne(0) }
  catch [System.Threading.AbandonedMutexException] { $got = $true }
  if (-not $got) {
    # Started from the .vbs there is no console to write to and no window yet,
    # so this is quiet by design: the widget you already have IS the answer, and
    # a message box on every stray double-click would be its own nuisance.
    [void]$script:ShowEvent.Set()
    Write-Host 'token-widget is already running - asked it to surface, this copy is exiting. TOKEN_WIDGET_MULTI=1 runs a second one anyway.'
    exit 0
  }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$ErrorActionPreference = 'Stop'
$Root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script  = Join-Path $Root 'token-sessions.sh'
$PosFile = Join-Path $Root 'token-widget-pos.json'
$Dash    = Join-Path $Root 'token-dashboard.html'
$DashGen = Join-Path $Root 'token-dashboard.sh'

# Git Bash. Looked up once rather than per refresh, and by several names
# because "bash" on PATH is sometimes the WSL shim, which cannot see this repo.
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
  [System.Windows.MessageBox]::Show("Git Bash not found - the widget runs token-sessions.sh through it.", "token-widget") | Out-Null
  exit 1
}

# --- palette -----------------------------------------------------------------
# Named $Pal, not $C: PowerShell variable names are case-insensitive, so any
# local $c anywhere in a function would silently shadow a palette called $C and
# every colour lookup in that scope would come back empty.
#
# The ladder is the one the pane draws: green under the parking bar, yellow
# past it, orange and red at the two cut bars. Colour means size, only size.
$Pal = @{
  bg     = '#F01A1B20'; card = '#FF212228'; line = '#FF2E3038'
  text   = '#FFE6E7EA'; dim  = '#FF8A8D97'; faint = '#FF5A5D66'
  green  = '#FF4ADE80'; yellow = '#FFFACC15'; orange = '#FFFB923C'
  red    = '#FFF87171'; blue  = '#FF60A5FA'; grey   = '#FF6B6F7A'
  track  = '#FF34363F'; sel   = '#FF2A2C34'; white = '#FFFFFFFF'
}
function Br([string]$hex) {
  if (-not $hex) {
    # Naming the caller matters here: an empty colour is almost always a
    # palette key that does not exist, and the message alone cannot say which.
    $where = (Get-PSCallStack | Select-Object -Skip 1 -First 3 |
              ForEach-Object { "$($_.FunctionName):$($_.ScriptLineNumber)" }) -join ' <- '
    throw "Br: empty colour - a palette lookup missed at $where"
  }
  New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex))
}

# Two shared brushes rather than one per element, because the hover handlers
# tell them apart by REFERENCE: an element whose background is the ghost is one
# this code put there and may recolour, and anything else is a bar with a colour
# of its own that must be left alone. Frozen, so thousands of rows share three
# objects between them.
$GhostBrush = (Br '#01000000')   # hit-testable and invisible
$HoverBrush = (Br '#1EFFFFFF')   # what the pointer leaves behind
$RowBrush   = (Br '#0BFFFFFF')   # the same, one step quieter, for a whole row
# A lapsed window, as a ground rather than a word. COLD is already spelled out
# in the cache column, but that is one small token at the far right of a dense
# row; the state it names applies to the whole session, and the whole session
# is what changes colour.
#
# Blue, and a dusty one rather than the palette's accent - #FF60A5FA is what
# selection and the message arrow are made of, and a ground must not read as
# something you just did. This is the colour of stale: cooled off, still there,
# nobody has touched it. It used to be orange, which was borrowed from the
# cache column's own token, but orange on a whole row reads as a warning and a
# lapsed cache is not one - it is a fact about the window, and the advice line
# is where the urgency belongs.
#
# Alpha 0x1A rather than the 0x14 the orange used: the card is already a cool
# grey, so a cool tint over it registers less than a warm one did at the same
# strength. Slightly more alpha buys back the same separation, not more.
$ColdBrush  = (Br '#1A7C9CBF')
# Cold AND parked used to have a ground of its own - green, on the argument that
# the action it invites is /clear rather than rescue. Retired: a parked window is
# still a cold window, and two grounds for one state meant the colour of a cold
# row depended on something the colour was not about. Cold is blue now whatever
# else is true of it, and the P marker on line 1 carries parked - which is where
# every other per-session fact already lives.
$GhostBrush.Freeze(); $HoverBrush.Freeze(); $RowBrush.Freeze()
# A window the tooling opened rather than you. Laid OVER the whole row and not
# swapped into the palette underneath it, which is the only way to grey every
# aspect at once without rewriting fifteen colour lookups - and the only way that
# cannot drift as new things are added to a row. A neutral grey at low alpha
# pulls every hue on the row toward itself, so the numbers stay legible and stop
# competing: an agent's window is context, not something you are deciding about.
$WashBrush = (Br '#38808080')
$ColdBrush.Freeze(); $WashBrush.Freeze()
# The prompt cache lives an hour, and that hour is the full scale of the bar
# on line 2. Not a band table like context has - there is only one number here
# and it is the same for every window.
$CacheTtl = 60

$XAML = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Token Sessions" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ShowInTaskbar="False"
        SizeToContent="Height" Width="412" ResizeMode="NoResize" Focusable="True">
  <Window.Resources>
    <!-- The row list is the only scrolling thing here, so the style is implicit
         rather than keyed. Windows' own scrollbar is 17px of arrows and track
         chrome and reads as a different application sitting inside the card;
         this is a 6px thumb in the card's own greys and nothing else. -->
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
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal">
          <TextBlock x:Name="Dot" Text="&#9679;" FontSize="10" Margin="0,3,7,0" Foreground="#FF4ADE80"/>
          <TextBlock x:Name="Title" Text="TOKEN SESSIONS" FontFamily="Segoe UI" FontSize="11"
                     FontWeight="SemiBold" Foreground="#FFE6E7EA"/>
        </StackPanel>
        <TextBlock x:Name="Clock" Grid.Column="1" FontFamily="Consolas" FontSize="11"
                   Foreground="#FF8A8D97" Margin="0,1,10,0"/>
        <TextBlock x:Name="Pin" Grid.Column="2" Text="&#9679;" FontSize="9"
                   Foreground="#FF60A5FA" Cursor="Hand" Margin="0,2,9,0" ToolTip="p - unpin from the top"/>
        <TextBlock x:Name="Min" Grid.Column="3" Text="&#8211;" FontSize="12"
                   Foreground="#FF5A5D66" Cursor="Hand" Margin="0,0,9,0" ToolTip="c - minimise to the live session"/>
        <TextBlock x:Name="Close" Grid.Column="4" Text="&#10005;" FontSize="11"
                   Foreground="#FF5A5D66" Cursor="Hand" Margin="0,1,4,0" ToolTip="esc - hide to the tray"/>
      </Grid>

      <Border Height="1" Background="#FF2E3038"/>

      <!-- Running out. Above everything, including the scorecard, because it is
           the only thing here that is about the next ten minutes rather than
           the last seven days. Collapsed entirely while there is room. -->
      <Border x:Name="AlertBox" Padding="14,8,14,8" Visibility="Collapsed">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <TextBlock x:Name="AlertGlyph" FontFamily="Segoe UI Symbol" FontSize="11"
                     Margin="0,1,8,0" VerticalAlignment="Top"/>
          <TextBlock x:Name="AlertText" Grid.Column="1" FontFamily="Segoe UI" FontSize="10.5"
                     TextWrapping="Wrap" LineHeight="15"/>
        </Grid>
      </Border>

      <!-- the 7d scorecard: what the week cost, and whether it is getting better -->
      <StackPanel x:Name="Score" Margin="14,10,14,10">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock Text="7d" FontFamily="Consolas" FontSize="10" Foreground="#FF5A5D66" Margin="0,2,9,0"/>
          <StackPanel x:Name="Grades" Grid.Column="1" Orientation="Horizontal"/>
          <TextBlock x:Name="Spend" Grid.Column="2" FontFamily="Consolas" FontSize="11" Foreground="#FFE6E7EA"/>
        </Grid>
        <Grid x:Name="SplitBar" Height="6" Margin="0,8,0,4"/>
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <TextBlock x:Name="SplitKey" FontFamily="Consolas" FontSize="9" Foreground="#FF5A5D66"/>
          <TextBlock x:Name="Wpc" Grid.Column="1" FontFamily="Consolas" FontSize="9" Foreground="#FF5A5D66"/>
        </Grid>
        <!-- What is left to spend, which is a different question from what a
             window costs and so gets its own line under the split rather than a
             column in it. Built in code: it is absent entirely until a status
             line has run at least once. -->
        <StackPanel x:Name="Limits" Margin="0,9,0,0"/>
      </StackPanel>

      <Border x:Name="ScoreRule" Height="1" Background="#FF2E3038"/>
      <!-- The rows scroll rather than push the window taller. Without the cap a
           busy machine grows the panel past the screen and there is no way back
           short of minimising it; MaxHeight is set from view state in Apply-Size
           and the bottom corner drags it. Below the cap the panel still hugs its
           content, so one session is still one session tall. -->
      <ScrollViewer x:Name="RowScroll" VerticalScrollBarVisibility="Auto"
                    HorizontalScrollBarVisibility="Disabled" MaxHeight="360"
                    PanningMode="VerticalOnly" Focusable="False">
        <StackPanel x:Name="Rows" Margin="0,3,0,3"/>
      </ScrollViewer>
      <Border Height="1" Background="#FF2E3038"/>

      <!-- naming a session: one line, opened on whatever it is called now -->
      <Border x:Name="NameBox" Background="#FF1B1C22" Padding="14,6,14,6" Visibility="Collapsed">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <TextBlock Text="name" FontFamily="Consolas" FontSize="11" Foreground="#FF60A5FA" Margin="0,1,8,0"/>
          <TextBox x:Name="NameInput" Grid.Column="1" FontFamily="Consolas" FontSize="11"
                   Background="Transparent" Foreground="#FFE6E7EA" BorderThickness="0"
                   CaretBrush="#FF60A5FA"/>
        </Grid>
      </Border>

      <!-- the footer, foldable as one block: legend or keys, then the strip -->
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
                     Foreground="#FF5A5D66" Cursor="Hand" Margin="0,0,10,0" ToolTip="l - the symbols"/>
          <TextBlock x:Name="DashLink" Text="dashboard" FontFamily="Consolas" FontSize="9"
                     Foreground="#FF44464E" Cursor="Arrow" Margin="0,0,10,0"
                     ToolTip="the dashboard is under development - its analytics are derived from the per-cycle cost model, which measures well under the billed figure, so the page would be confidently wrong"/>
          <TextBlock x:Name="Refresh" Text="&#8635;" FontFamily="Segoe UI Symbol" FontSize="11"
                     Foreground="#FF5A5D66" Cursor="Hand" ToolTip="r - collect now"/>
        </StackPanel>
        <!-- the resize corner. Sideways it widens the card; up and down it sets
             how tall the row list may get before it starts scrolling. -->
        <TextBlock x:Name="Grip" Grid.Column="3" Text="&#9698;" FontFamily="Segoe UI Symbol"
                   FontSize="10" Foreground="#FF3E414B" Cursor="SizeNWSE" Margin="9,2,0,-2"/>
      </Grid>

      <!-- The message line: hover text and confirmations. LAST on purpose - it
           appears and disappears as the pointer moves, and anything below it
           would be shoved around by its own tooltip. Rounded to match the card,
           since it is now what the bottom corners are made of. -->
      <Border x:Name="AdviceBox" Background="#FF1B1C22" Padding="14,9,14,9"
              CornerRadius="0,0,9,9">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <TextBlock x:Name="AdviceArrow" Text="&#8594;" FontFamily="Consolas" FontSize="11"
                     Foreground="#FF8A8D97" Margin="0,0,7,0" VerticalAlignment="Top"/>
          <!-- Bounded on both sides, so a long string does not make the panel
               taller than a short one and set the same loop going vertically. -->
          <TextBlock x:Name="Advice" Grid.Column="1" FontFamily="Segoe UI" FontSize="10.5"
                     Foreground="#FF8A8D97" TextWrapping="Wrap" LineHeight="15"
                     MinHeight="30" MaxHeight="45" TextTrimming="CharacterEllipsis"/>
        </Grid>
      </Border>

    </StackPanel>
  </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$XAML)
$win = [Windows.Markup.XamlReader]::Load($reader)
$el = @{}
foreach ($n in 'Card','Header','Dot','Title','Clock','Pin','Min','Close','AlertBox','AlertGlyph','AlertText','Score','ScoreRule',
                'Grades','Spend','SplitBar','SplitKey','Wpc','Limits','Rows','RowScroll','NameBox','NameInput',
                'AdviceBox','AdviceArrow','Advice','FootRule','FootBody','Legend','Keys',
                'Fold','Countdown','KeysToggle','LegendToggle','DashLink','Refresh','Grip') {
  $el[$n] = $win.FindName($n)
}

# --- view state --------------------------------------------------------------
# All of it is remembered, because a widget that forgets it was minimised is a
# widget you minimise again every morning.
$script:View = @{
  compact = [bool]$Compact; pinned = $true
  detail = $false; legend = $true; keys = $false
  bell = $true; foot = $true; width = 412.0; zoom = 1.0; rowsH = 360.0
}
# The panel is legible between these; outside them the bars stop being readable
# at one end and it stops being a corner widget at the other. rowsH is how tall
# the row list may get before it scrolls - two rows at the bottom, and at the
# top enough that a tall screen never scrolls at all.
$MINW = 330.0; $MAXW = 900.0; $MINZ = 0.75; $MAXZ = 1.6
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
    foreach ($k in 'compact','pinned','detail','legend','bell','foot','width','zoom','rowsH') {
      if ($null -ne $p.$k) { $script:View[$k] = $p.$k }
    }
    if ($Compact) { $script:View.compact = $true }
  } catch { $script:Placed = $false }
}
if (-not $script:Placed) {
  if ($TopLeft) { $win.Left = $wa.Left + 20; $win.Top = $wa.Top + 20 }
  else { $win.Left = $wa.Right - 432; $win.Top = $wa.Bottom - 430 }
}
Clamp-Placement

function Save-State {
  try {
    @{ left = $win.Left; top = $win.Top
       compact = $script:View.compact; pinned = $script:View.pinned
       detail = $script:View.detail
       legend = $script:View.legend; bell = $script:View.bell
       foot = $script:View.foot; width = $script:View.width; zoom = $script:View.zoom
       rowsH = $script:View.rowsH
    } | ConvertTo-Json -Compress | Set-Content $PosFile -Encoding utf8
  } catch { }
}

# Width, height and zoom are three different wants and are kept apart. Width
# buys room for long nicknames and paths; the row height decides how many
# sessions you see before the list scrolls; zoom makes the whole thing bigger on
# a dense screen. The window has to carry all three, since a scaled card inside
# a fixed window would just be clipped.
#
# The height is applied to the LIST, not to the window: the chrome around it -
# the scorecard, the message line, the footer - is whatever it is, and the
# window still sizes itself to the total. Capping the window instead would clip
# the footer off the bottom on a busy machine.
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
# Tokens throughout, in input-equivalents. Three scales so the column stays the
# same width whether a session has spent nine thousand or nine million.
function Tok([double]$v) {
  if ($v -ge 1e7)  { return ('{0:N1}M' -f ($v / 1e6)) }
  if ($v -ge 1e6)  { return ('{0:N2}M' -f ($v / 1e6)) }
  if ($v -ge 1e4)  { return ('{0:N0}k' -f ($v / 1e3)) }
  if ($v -ge 1000) { return ('{0:N1}k' -f ($v / 1e3)) }
  return ('{0:N0}' -f $v)
}
function Grade-Color([string]$g) {
  switch ($g) { 'A' { $Pal.green } 'B' { $Pal.green } 'C' { $Pal.blue }
                'D' { $Pal.yellow } 'E' { $Pal.red } default { $Pal.faint } }
}
# Same three-colour ladder as ctxcol() in token-sessions.sh (2026-09-23): green is
# the working range, yellow from the cut bar (a restart pays; cut at the next topic
# change), red past the ceiling. The park bar stays a tick, not a colour - it is
# gap advice, and colouring by it painted every normal session as a warning.
function Band-Color([double]$k, $bands) {
  if ($bands.max_at -gt 0 -and $k -ge $bands.max_at) { return $Pal.red }
  if ($k -ge $bands.cut_pk) { return $Pal.yellow }
  $Pal.green
}
# Heat: what a cycle pays to HAVE the window against what that cycle produced.
# The pane's own ladder, so the number means the same thing in both places, and
# 1.0x is the bar where rent overtakes work.
function Heat-Color([double]$h) {
  if ($h -ge 1.5) { return $Pal.red }
  if ($h -ge 1.0) { return $Pal.orange }
  if ($h -ge 0.7) { return $Pal.yellow }
  $Pal.green
}

# What a whole window has COST, banded against what windows on this machine
# actually cost. Measured 2026-09-11 across 198 transcripts under
# ~/.claude/projects, weighted the way everything else here is (output 5x,
# cache write 2x, cache read 0.1x): p25 475k, p50 1.95M, p75 4.24M, p90 7.85M.
#
# They are NOT a budget - a long session doing real work belongs in orange -
# they say where this window sits among yours, which is the one thing a bare
# token figure could never answer on its own.
#
# Full scale is the third quartile, not the ninetieth percentile. p90 is where
# these started and it made the gauge useless for the sessions you actually
# have open: half of them are under a quarter of 7.85M, so the working range of
# the bar was its first two centimetres and everything ordinary drew as an
# empty track. Cut to 4M, the median lands at the halfway mark and the bar
# spends its length on the range rows are really in. The top quartile pins - a
# 25M outlier and a 5M one both draw full - which is the right trade: past the
# end the colour has already said everything the length could.
# full was 4.0e6 (the p75 of the corpus). Lowered 2026-09-11 to the same 3.5M a
# DAY is now budgeted at in token-sessions.sh, so the two gauges agree about what
# a lot of tokens is. Past full the bar pins and the colour goes on saying more.
$SpendBands = @{ ok = 500e3; watch = 2.0e6; heavy = 3.0e6; full = 3.5e6 }
function Spend-Color([double]$w) {
  if ($w -ge $SpendBands.heavy) { return $Pal.red }
  if ($w -ge $SpendBands.watch) { return $Pal.orange }
  if ($w -ge $SpendBands.ok)    { return $Pal.yellow }
  $Pal.green
}
# The spend gauge. Same shape as New-CtxBar - track, scaled fill, band ticks
# that overhang so they read as marks against the bar rather than seams in it -
# but a fixed width, because it lives inside an Auto-width pill rather than in a
# star column that can stretch.
#
# Full scale is p75 rather than the corpus maximum: the tail runs to 25M and
# scaling to it would draw every ordinary session as an empty track. Past full
# the bar pins and the colour is what goes on saying more.
function New-SpendBar {
  param([double]$W, [double]$FromW = -1, [double]$Width = 66, [int]$Height = 6)
  $g = New-Object Windows.Controls.Grid
  $g.Height = $Height; $g.Width = $Width; $g.ClipToBounds = $false
  $track = New-Object Windows.Controls.Border
  $track.Background = (Br $Pal.track)
  $track.CornerRadius = New-Object Windows.CornerRadius (3)
  $g.Children.Add($track) | Out-Null

  $frac = [math]::Min(1.0, [math]::Max(0.0, $W / $SpendBands.full))
  $fill = New-Object Windows.Controls.Border
  $fill.Background = (Br (Spend-Color $W))
  $fill.CornerRadius = New-Object Windows.CornerRadius (3)
  $fill.HorizontalAlignment = 'Stretch'
  $sc = New-Object Windows.Media.ScaleTransform
  $sc.ScaleX = $frac
  $fill.RenderTransform = $sc
  $fill.RenderTransformOrigin = New-Object Windows.Point (0, 0.5)
  $g.Children.Add($fill) | Out-Null
  $g.Tag = @{ scale = $sc; fill = $fill; frac = $frac }
  if ($FromW -ge 0) {
    $f0 = [math]::Min(1.0, [math]::Max(0.0, $FromW / $SpendBands.full))
    if ([math]::Abs($f0 - $frac) -gt 0.0005) {
      Animate -Target $sc -Property ([Windows.Media.ScaleTransform]::ScaleXProperty) `
              -From $f0 -To $frac -Seconds 0.85
    }
  }
  # All three boundaries get a mark now that the scale ends at p75 - the red one
  # used to sit past the end of the track and could only be seen by the fill
  # changing colour under you. The fourth boundary is the end of the bar.
  foreach ($b in @(@{ k = [double]$SpendBands.ok;    c = $Pal.yellow },
                   @{ k = [double]$SpendBands.watch; c = $Pal.orange },
                   @{ k = [double]$SpendBands.heavy; c = $Pal.red })) {
    $f = $b.k / $SpendBands.full
    $tg = New-Object Windows.Controls.Grid
    $tg.ClipToBounds = $false
    $c1 = New-Object Windows.Controls.ColumnDefinition
    $c1.Width = New-Object Windows.GridLength ($f, 'Star')
    $c2 = New-Object Windows.Controls.ColumnDefinition
    $c2.Width = New-Object Windows.GridLength ((1 - $f), 'Star')
    $tg.ColumnDefinitions.Add($c1); $tg.ColumnDefinitions.Add($c2)
    $tick = New-Object Windows.Controls.Border
    $tick.Width = 1; $tick.HorizontalAlignment = 'Right'
    $tick.Margin = '0,-2,0,-2'
    $tick.Background = (Br $b.c)
    $tick.Opacity = $(if ($b.k -le $W) { 0.25 } else { 0.55 })
    [Windows.Controls.Grid]::SetColumn($tick, 0)
    $tg.Children.Add($tick) | Out-Null
    $g.Children.Add($tg) | Out-Null
  }
  $g
}
# Move a spend gauge between collects. The live payload carries this session's
# own billed total, which is both truer than the snapshot and a great deal
# fresher - so the bar follows it rather than waiting for the next collect and
# stepping in one jump. The colour is re-read on the way, because crossing a
# band is the only thing this gauge has to say that the figure does not.
function Set-SpendBar($bar, [double]$W) {
  if (-not $bar -or -not $bar.Tag) { return }
  $frac = [math]::Min(1.0, [math]::Max(0.0, $W / $SpendBands.full))
  if ([math]::Abs($frac - [double]$bar.Tag.frac) -gt 0.0005) {
    Animate -Target $bar.Tag.scale -Property ([Windows.Media.ScaleTransform]::ScaleXProperty) `
            -From ([double]$bar.Tag.frac) -To $frac -Seconds 0.5
    $bar.Tag.frac = $frac
  }
  $bar.Tag.fill.Background = (Br (Spend-Color $W))
}
# The account's own bands. Nothing measured here - these are just the points at
# which "how much is left" stops being a background fact and starts being a
# thing to plan around.
function Limit-Color([double]$p) {
  if ($p -ge 90) { return $Pal.red }
  if ($p -ge 75) { return $Pal.orange }
  if ($p -ge 50) { return $Pal.yellow }
  $Pal.green
}
# A percentage as a bar AND a number, off ONE value and ONE clock.
#
# They used to be built separately - New-PctBar under the lerp key "pct:acct:.."
# and the figure under "acctpct:.." - which is two independent animations over a
# single fact. Three ways that comes apart, all of them seen: the bar only
# registers a lerp when the change clears 0.05 while the number registers one
# every collect, so the two are not even created on the same polls; each entry
# expires on its own 60-second timer, so one can land while the other is still
# walking; and the bar starts from $script:Prev (rewritten every collect) while
# the number starts from $script:Lerp[..].cur (rewritten only by the timer), so
# their starting points are different clocks as well. A bar that disagrees with
# the figure printed beside it is worse than either alone, because there is no
# way to tell which one to believe.
#
# One key now drives both. They cannot diverge: if it is wrong it is wrong in
# both places at once, which is a bug you can see rather than one you argue with.
function New-PctGauge([double]$Pct, [double]$W, [double]$H, [string]$Key, [double]$Size = 9.5) {
  $g = New-Object Windows.Controls.Grid
  $g.Width = $W; $g.Height = $H; $g.VerticalAlignment = 'Center'
  $tr = New-Object Windows.Controls.Border
  $tr.Background = (Br $Pal.track)
  $tr.CornerRadius = New-Object Windows.CornerRadius ($H / 2)
  $g.Children.Add($tr) | Out-Null
  $f = New-Object Windows.Controls.Border
  $f.CornerRadius = New-Object Windows.CornerRadius ($H / 2)
  $f.HorizontalAlignment = 'Left'
  $g.Children.Add($f) | Out-Null
  $tx = New-Object Windows.Controls.TextBlock
  $tx.FontSize = $Size; $tx.FontFamily = 'Consolas'; $tx.FontWeight = 'SemiBold'
  $tx.VerticalAlignment = 'Center'
  # The one writer. Width, text and colour all come off the same $v, so the
  # colour cannot describe one number while the digits show another either.
  $apply = {
    param($v)
    $c = (Limit-Color $v)
    $f.Width = [math]::Max(1.0, $W * [math]::Min(1.0, [math]::Max(0.0, $v / 100.0)))
    $f.Background = (Br $c)
    $tx.Text = ('{0,3:N0}%' -f $v)
    $tx.Foreground = (Br $c)
  }.GetNewClosure()
  & $apply $Pct
  if ($Key) {
    $from = Prev-Val "gauge:$Key" $Pct
    if ([math]::Abs($from - $Pct) -gt 0.05) { Lerp-Do "gauge:$Key" $Pct $apply $from }
  }
  @{ bar = $g; text = $tx }
}
function Growth-Color([double]$ratio) {
  if ($ratio -ge 1.0) { return $Pal.red }
  if ($ratio -ge 0.6) { return $Pal.orange }
  if ($ratio -ge 0.3) { return $Pal.yellow }
  $Pal.green
}
function Verdict-Color([string]$v) {
  switch ($v) { 'now' { $Pal.red } 'soon' { $Pal.orange } 'cut' { $Pal.yellow }
                'ok' { $Pal.green } default { $Pal.grey } }
}
function Verdict-Glyph([string]$v) {
  switch ($v) { 'now' { [char]0x25B2 } 'soon' { [char]0x25B2 } 'cut' { [char]0x25B3 }
                'ok' { [char]0x25CB } default { [char]0x00B7 } }
}
function Text-Block([string]$s, [double]$size, [string]$colour, [string]$family = 'Consolas') {
  $t = New-Object Windows.Controls.TextBlock
  $t.Text = $s; $t.FontSize = $size; $t.FontFamily = $family
  $t.Foreground = (Br $colour)
  $t
}
# Hover text, in the card's own message line. This used to be a real ToolTip -
# a second window that draws over the row you are pointing at, appears after a
# delay, and vanishes on a timer, none of which suits a readout you scan.
#
# The text is still stashed in .ToolTip: it is a property every FrameworkElement
# already has, so nothing has to be tracked in a side table that would then leak
# a row's worth of entries on every redraw. The popup itself is switched off.
# Setting .ToolTip again on a later refresh only replaces the string, which is
# what keeps the three chrome elements from collecting a handler per refresh.
function Tip($element, [string]$text) {
  if (-not $text) { return }
  $first = ($null -eq $element.ToolTip)
  $element.ToolTip = $text
  if (-not $first) { return }
  [Windows.Controls.ToolTipService]::SetIsEnabled($element, $false)
  # A TextBlock with no background is hit-tested across its glyphs only, so the
  # gap between two words reads as a leave and the line flickers as you move.
  # One nearly-invisible fill makes the whole box the target, showing nothing -
  # and gives the hover something to recolour.
  if ($element.PSObject.Properties['Background'] -and -not $element.Background) {
    $element.Background = $GhostBrush
  }
  # The pointer lights up what it is over. Without it the message line names
  # something and you have to work out which of nine things on the row it meant
  # - and on a row of bars two pixels apart, you cannot.
  $element.add_MouseEnter({ param($s, $e)
    if ($s.Background -eq $GhostBrush) { $s.Background = $HoverBrush }
    Set-Hover ([string]$s.ToolTip) })
  $element.add_MouseLeave({ param($s, $e)
    if ($s.Background -eq $HoverBrush) { $s.Background = $GhostBrush }
    Set-Hover (Tip-Above $s) })
}

# Leaving a child usually means arriving at its parent, and the parent's own
# MouseEnter does not fire again for that - it never left. So a leave hands the
# line back to the nearest ancestor still under the pointer that has something
# to say, rather than blanking it.
function Tip-Above($element) {
  $p = [Windows.Media.VisualTreeHelper]::GetParent($element)
  while ($p) {
    $fe = $p -as [Windows.FrameworkElement]
    if ($fe -and $fe.IsMouseOver -and $fe.ToolTip) { return [string]$fe.ToolTip }
    $p = [Windows.Media.VisualTreeHelper]::GetParent($p)
  }
  ''
}

# Sweeping the pointer across a row crosses six or seven hoverable parts in a
# couple of hundred milliseconds, and each crossing used to commit its own
# message - so the line strobed through everything on the way to the thing you
# meant. A short dwell holds only the newest value and commits what survives
# it, which is the whole difference between "moved over" and "stopped on".
# Nothing is queued: a later arrival overwrites the pending value rather than
# adding to it, so the cost of a fast sweep is one commit, not seven.
#
# 180ms, doubled from the 90 this started at. 90 stopped the strobe but still
# committed on a slow pass across a row, which is the same flicker arriving
# later; the dwell has to be longer than a deliberate sweep, not just longer
# than a fast one. It is spent only on the way IN - the line is already up by
# the time you have read where you are pointing.
$script:HoverPending = $null
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
  # Not while the corner is being dragged. The drag measures from a screen
  # position, and a message line appearing mid-drag would resize the window
  # under the very pointer that is steering it.
  if ($script:Resizing) { return }
  # Already showing this and nothing else is waiting: the dwell has nothing to
  # decide. Guarding on the pending slot too matters - without it, re-arriving
  # at the current value would leave a stale pending one to fire later.
  if ($script:Hover -eq $s -and $null -eq $script:HoverPending) { return }
  $script:HoverPending = $s
  $script:HoverTimer.Stop()
  $script:HoverTimer.Start()
}

# The one line at the foot of the card. Advice used to live here too and now
# lives on the row it is about, so this is left with the two things that are
# answers to something you just did: what the pointer is over, and a
# confirmation. Only this line moves - no redraw - so hovering costs nothing.
#
# It is the LAST thing in the card, so appearing and disappearing extends the
# bottom edge downward rather than shifting anything you might be pointing at.
function Show-Message {
  $txt = ''; $col = $Pal.dim; $arw = $Pal.dim
  $glyph = [string][char]0x2192; $fam = 'Segoe UI'
  if ($script:Hover) {
    $txt = $script:Hover; $col = $Pal.text; $arw = $Pal.blue
    $glyph = [string][char]0x25CF; $fam = 'Consolas'
  } elseif ($script:Flash) {
    $txt = $script:Flash; $col = $Pal.blue; $arw = $Pal.blue
  }
  $el.Advice.Text = $txt
  $el.Advice.FontFamily = $fam
  $el.Advice.FontSize = $(if ($fam -eq 'Consolas') { 10 } else { 10.5 })
  $el.Advice.Foreground = (Br $col)
  $el.AdviceArrow.Text = $glyph
  $el.AdviceArrow.Foreground = (Br $arw)
  $el.AdviceBox.Visibility = if ($txt) { 'Visible' } else { 'Collapsed' }
}

# --- animation ---------------------------------------------------------------
# All of it is WPF's own, driven by the composition thread rather than by the
# 1Hz tick - a timer-driven animation stutters, and a stuttering "this is live"
# indicator reads as a hang.
function Animate {
  param($Target, $Property, [double]$From, [double]$To, [double]$Seconds,
        [switch]$Forever, [switch]$AutoReverse)
  $a = New-Object Windows.Media.Animation.DoubleAnimation (
    $From, $To, (New-Object Windows.Duration ([TimeSpan]::FromSeconds($Seconds))))
  if ($AutoReverse) { $a.AutoReverse = $true }
  if ($Forever) { $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever }
  $a.EasingFunction = New-Object Windows.Media.Animation.CubicEase
  $Target.BeginAnimation($Property, $a)
}

# The spinner. A dashed ring turning once every 1.2s, which reads as "this one
# is thinking" at a glance and, unlike a blinking glyph, does not compete with
# the verdict colours for attention. The dash array is in multiples of the
# stroke thickness, so 5-on 13-off leaves roughly a quarter-turn arc.
function New-Spinner([string]$colour) {
  $ring = New-Object Windows.Shapes.Ellipse
  $ring.Width = 11; $ring.Height = 11
  $ring.Stroke = (Br $colour); $ring.StrokeThickness = 1.6
  $ring.StrokeDashCap = 'Round'
  $dash = New-Object Windows.Media.DoubleCollection
  $dash.Add(5); $dash.Add(13)
  $ring.StrokeDashArray = $dash
  $rot = New-Object Windows.Media.RotateTransform
  $ring.RenderTransform = $rot
  $ring.RenderTransformOrigin = New-Object Windows.Point (0.5, 0.5)
  $lin = New-Object Windows.Media.Animation.DoubleAnimation (
    0, 360, (New-Object Windows.Duration ([TimeSpan]::FromSeconds(1.2))))
  $lin.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
  $rot.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $lin)
  $ring
}

# The spinner's own colour as a turn ages, on the same ramp Run-Color already
# gives the elapsed text - except a spinner at rest reads as "alive" and dim
# reads as "faded out", the opposite of what a fresh turn should say. So the
# under-10-minute band keeps the spinner's original green here and only the
# two escalating bands (yellow past 10m, orange past 30m) are shared with the
# text ramp - one source for where the thresholds sit, not for what "normal"
# looks like on each element.
function Spin-Color([double]$Secs, [int]$State) {
  $c = Run-Color $Secs $State
  if ($c -eq $Pal.dim) { return $Pal.green }
  $c
}

# --- pieces ------------------------------------------------------------------

# A stacked proportional bar. Star widths rather than pixels, so it re-lays
# itself with its container and cannot disagree about its own width.
function Fill-Split {
  param($Grid, [double]$Out, [double]$Write, [double]$Read, [int]$Radius = 3,
        [double]$OutTok = -1, [double]$WriteTok = -1, [double]$ReadTok = -1,
        [bool]$Live = $false, [string]$Key = '')
  $Grid.Children.Clear(); $Grid.ColumnDefinitions.Clear()
  # On a live session this bar is being redrawn under you every cycle, so it
  # breathes for the same reason the newest spark bar does: it is the part of
  # the row that is still moving. Same 1.5s as the nickname, so a live row
  # pulses as one thing rather than three things out of step.
  if ($Live) {
    Animate -Target $Grid -Property ([Windows.Controls.Grid]::OpacityProperty) `
            -From 1.0 -To 0.5 -Seconds 1.5 -Forever -AutoReverse
  }
  $parts = @(
    @{ v = [math]::Max($Out, 0.001);   c = $Pal.green;  n = 'output';      t = $OutTok },
    @{ v = [math]::Max($Write, 0.001); c = $Pal.orange; n = 'cache write'; t = $WriteTok },
    @{ v = [math]::Max($Read, 0.001);  c = $Pal.blue;   n = 'cache read';  t = $ReadTok })
  $i = 0
  foreach ($p in $parts) {
    $cd = New-Object Windows.Controls.ColumnDefinition
    $cd.Width = New-Object Windows.GridLength ($p.v, 'Star')
    $Grid.ColumnDefinitions.Add($cd)
    $b = New-Object Windows.Controls.Border
    $b.Background = (Br $p.c)
    if ($i -eq 0) { $b.CornerRadius = New-Object Windows.CornerRadius ($Radius, 0, 0, $Radius) }
    elseif ($i -eq 2) { $b.CornerRadius = New-Object Windows.CornerRadius (0, $Radius, $Radius, 0) }
    # Each segment answers for itself on hover, in both units.
    $lbl = if ($p.t -ge 0) { "{0}: {1}  ({2:N1}%)" -f $p.n, (Tok $p.t), $p.v }
           else { "{0}: {1:N1}%" -f $p.n, $p.v }
    Tip $b $lbl
    [Windows.Controls.Grid]::SetColumn($b, $i)
    $Grid.Children.Add($b) | Out-Null
    # The boundaries between the three colours are the whole content of this
    # bar, and they are column weights rather than widths - so they are moved by
    # rewriting the GridLength each frame. WPF has no animation for that type,
    # which is why this one goes through Lerp-Do rather than a storyboard.
    if ($Key) {
      $from = Prev-Val "split:$Key/$($p.n)" $p.v
      if ([math]::Abs($from - $p.v) -gt 0.05) {
        Lerp-Do "split:$Key/$($p.n)" $p.v `
          { param($v) $cd.Width = New-Object Windows.GridLength ([math]::Max($v, 0.001), 'Star') }.GetNewClosure() $from
      }
    }
    $i++
  }
}

# Growth per cycle against its budget - the pane's GROWTH column. Bars rather
# than a line: the question is "was this cycle over", which is a comparison
# against a fixed bar, not a trend.
#
# Every bar answers on hover with the tokens AND the share of budget, because
# those are two different questions - "how much did this cycle pull in" and
# "was that more than a cycle is supposed to". The newest bar on a live session
# breathes, since it is the one still being written.
# Epoch seconds, the same clock token-sessions.sh stamps run_since with. Both
# sides have to be UTC or the elapsed figure comes out an entire timezone wrong
# - which on a four-character column reads as a plausible number rather than as
# an obvious break.
function Now-Epoch {
  return [double]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
}

# How long the turn in flight has been running, and what colour to say it in.
#
# The clock is `statusUpdatedAt` out of the CLI's own pid file - the moment it
# flipped this window to busy, which measured on this machine lands on the same
# second as the human prompt that started the turn. So it is the age of the
# TURN, not of the last collect noticing it: the widget re-reads disk once a
# minute, and a figure baked in at collect time would sit frozen for a minute
# in the one place on the row whose whole job is to move. Recomputed against
# the clock every second instead, in Run-Tick.
#
# Four characters is the budget, same ladder the terminal pane uses, so the two
# never disagree about the same turn: 59s, 22m, 1.7h, then days - a turn older
# than a few hours is a stalled window and the exact figure has stopped being
# the point.
function Run-Str([double]$Secs) {
  if ($Secs -lt 0) { $Secs = 0 }
  if ($Secs -lt 60) { return '{0:N0}s' -f $Secs }
  $m = [math]::Floor($Secs / 60)
  if ($m -lt 100) { return '{0:N0}m' -f $m }
  if ($m -lt 5760) { return '{0:N1}h' -f ($m / 60) }
  return '{0:N0}d' -f [math]::Floor($m / 1440)
}
# Dim while the turn is ordinary, warming as it gets long: past ten minutes it
# is worth a glance, past thirty it is more likely stalled than working, and the
# colour is the only thing on the row that will say so.
#
# The clock does not run for `waiting`. A window holding a permission prompt in
# front of you has stopped spending and stopped working - timing it would be
# timing how slow YOU are, on a row whose whole subject is what the machine is
# doing. It disappears instead, which is also the honest answer to "is this
# still running".
function Run-Color([double]$Secs, [int]$State) {
  if ($Secs -ge 1800) { return $Pal.orange }
  if ($Secs -ge 600) { return $Pal.yellow }
  return $Pal.dim
}
function Run-Tip([double]$Secs, [int]$State) {
  $t = "the turn in flight has been running {0}, timed from the moment the CLI marked this window busy" -f (Run-Str $Secs)
  if ($Secs -ge 1800) {
    $t += "`npast half an hour a turn is more often stalled than working - the status flag is written on transition, so a process that died mid-turn leaves busy behind forever. Check the terminal before assuming it is still going."
  }
  return $t
}

function New-Spark {
  param($Recent, [double]$Budget, [bool]$Live, $LiveRow = $null,
        [int]$Width = 46, [int]$Height = 13, [string]$Key = '')
  $sp = New-Object Windows.Controls.StackPanel
  $sp.Orientation = 'Horizontal'; $sp.Height = $Height; $sp.VerticalAlignment = 'Bottom'
  $items = @($Recent)
  # The cycle running right now gets its own bar. The Stop hook only writes a
  # row when a cycle ENDS, so up to here the sparkline was a history of finished
  # work with nothing standing for the work in flight - and the bar left
  # breathing was the last FINISHED one, which is the single bar on the row
  # guaranteed not to be moving any more.
  if ($LiveRow) { $items += $LiveRow }
  $n = $items.Count
  if ($n -eq 0) {
    $sp.Children.Add((Text-Block '  -' 9 $Pal.faint)) | Out-Null
    return $sp
  }
  # Sized against at least three bars, whatever the count. Dividing the full
  # width by $n alone made a young session's one or two cycles draw as slabs
  # half the sparkline wide - which reads as an enormous cycle rather than as a
  # short history, and then visibly shrinks with every cycle that lands even
  # when growth is flat. Past three it divides as it always did, so the line
  # keeps narrowing as the history fills.
  $each = [math]::Max(2, [math]::Floor($Width / [math]::Max($n, 3)) - 1)
  for ($i = 0; $i -lt $n; $i++) {
    $r = $items[$i]
    $ratio = 0.0
    if ($Budget -gt 0) { $ratio = [double]$r.growth / $Budget }
    $h = [math]::Max(1.5, [math]::Min(1.0, $ratio) * $Height)
    $b = New-Object Windows.Controls.Border
    $b.Width = $each; $b.Height = $h; $b.Margin = '0,0,1,0'
    $b.VerticalAlignment = 'Bottom'; $b.Background = (Br (Growth-Color $ratio))
    $b.CornerRadius = New-Object Windows.CornerRadius (1)
    # Grows in from its previous height rather than appearing full-size. A
    # finished cycle's bar is otherwise static between collects - this is the
    # one moment it moves, and it is the moment that matters: a cycle just
    # landed. New keys default to 0, so a bar the sparkline has never drawn
    # before rises from the baseline instead of snapping into place.
    if ($Key) {
      $bkey = "spark:$Key/$($r.cycle)"
      $bfrom = if ($script:Prev.ContainsKey($bkey)) { [double]$script:Prev[$bkey] } else { 0.0 }
      $script:Prev[$bkey] = $h
      if ([math]::Abs($bfrom - $h) -gt 0.1) {
        Lerp-Do $bkey $h { param($v) $b.Height = [math]::Max(0.5, $v) }.GetNewClosure() $bfrom
      }
    }
    $isLive = ($LiveRow -and $i -eq $n - 1)
    $btip = if ($isLive) {
      "cycle {0}, running now   grown {1} so far   {2:N0}% of the {3} budget   output {4}" -f `
        $r.cycle, (Tok $r.growth), ($ratio * 100), (Tok $Budget), (Tok $r.output)
    } else {
      "cycle {0}   grew {1}   {2:N0}% of the {3} budget   output {4}" -f `
        $r.cycle, (Tok $r.growth), ($ratio * 100), (Tok $Budget), (Tok $r.output)
    }
    Tip $b $btip
    # A hit target the height of the whole sparkline, so a 2px bar is still
    # hoverable. Transparent, and behind nothing - it only carries the tooltip.
    $hit = New-Object Windows.Controls.Grid
    $hit.Width = $each + 1; $hit.Height = $Height; $hit.Background = (Br '#01000000')
    $hit.VerticalAlignment = 'Bottom'
    $b.HorizontalAlignment = 'Left'; $b.Margin = '0,0,0,0'
    $hit.Children.Add($b) | Out-Null
    Tip $hit $btip
    $hit.Margin = '0,0,1,0'
    # Only the in-flight bar breathes, and only when there is one.
    if ($isLive) {
      Animate -Target $b -Property ([Windows.Controls.Border]::OpacityProperty) `
              -From 1.0 -To 0.35 -Seconds 0.9 -Forever -AutoReverse
    }
    $sp.Children.Add($hit) | Out-Null
  }
  $sp
}

# The context bar, with the measured bands ticked onto it. Same four marks the
# pane prints under its key, so the number and its meaning arrive together.
#
# This has line 2 back, and the reason is the TICKS rather than the fill. A
# cache clock is a number with a deadline and it was given this line on that
# basis - but the number, its colour and the extension marks beside it already
# say the whole of it three times, and a bar that only restates a countdown is
# a picture of something you can already read. The band marks are the opposite:
# they are the only place on the row where a size turns into a DECISION - below
# the first, carrying on beats clearing even cold and unparked; past the
# second, park before you step away; past the last, a cut finally pays for
# itself. None of that is derivable from "235.3k" without knowing four measured
# constants by heart.
#
# The fill is full width under a ScaleTransform rather than a sized column,
# because a GridLength cannot be animated but a ScaleX can - which is what lets
# the bar slide from its last value to its new one on each collect instead of
# jumping, so growth is something you SEE rather than something you diff.
function New-CtxBar {
  param([double]$K, $Bands, [double]$FromK = -1, [int]$Height = 7)
  $g = New-Object Windows.Controls.Grid
  $g.Height = $Height
  $track = New-Object Windows.Controls.Border
  $track.Background = (Br $Pal.track)
  $track.CornerRadius = New-Object Windows.CornerRadius (3.5)
  $g.Children.Add($track) | Out-Null

  $frac = [math]::Min(1.0, $K / $Bands.ctxmax)
  $fill = New-Object Windows.Controls.Border
  $fill.Background = (Br (Band-Color $K $Bands))
  $fill.CornerRadius = New-Object Windows.CornerRadius (3.5)
  $sc = New-Object Windows.Media.ScaleTransform
  $sc.ScaleX = $frac
  $fill.RenderTransform = $sc
  $fill.RenderTransformOrigin = New-Object Windows.Point (0, 0.5)
  $g.Children.Add($fill) | Out-Null
  # Kept so the row can slide this bar again later without being rebuilt - the
  # live repaint below animates exactly what the collect would have animated.
  $g.Tag = @{ scale = $sc; fill = $fill; frac = $frac }
  if ($FromK -ge 0) {
    $f0 = [math]::Min(1.0, $FromK / $Bands.ctxmax)
    if ([math]::Abs($f0 - $frac) -gt 0.0005) {
      Animate -Target $sc -Property ([Windows.Media.ScaleTransform]::ScaleXProperty) `
              -From $f0 -To $frac -Seconds 0.85
    }
  }

  # Band ticks: a spacer column, then a mark on its right edge.
  #
  # Three things separate these from the hairlines they used to be, and each
  # one is answering a question the old marks could not.
  #
  #   WEIGHT SAYS WHICH ONE IS NEXT. A tick you are already past is history -
  #     it cannot tell you to do anything - so it drops to a whisper, while the
  #     next threshold ahead of the fill goes to full strength and gains a
  #     pixel. The bar then reads as "here is where you are, here is the next
  #     decision", which is the only question a ladder of constants is for.
  #   THEY OVERHANG. A mark drawn inside a 7px bar is indistinguishable from a
  #     seam in the fill. Two pixels of overhang top and bottom make it read as
  #     a gauge mark against the bar rather than a feature of it - the Grid
  #     does not clip, so a negative margin is the whole implementation.
  #   THEY CAN BE HOVERED. A 1px line is not a pointer target, so every tick
  #     had a tooltip nobody could reach. Each now carries a transparent 9px
  #     pad on the same boundary - the trick the sparkline uses for its 2px
  #     bars - and the tooltip says what the threshold MEANS, not just its
  #     number, because the number is already drawn where the mark is.
  $ticks = @()
  $bandList = @(
    @{ k = $Bands.clear_no; c = $Pal.grey; n = 'the floor'
       t = ("{0:N0}k - the floor. A fresh session starts at about this size, so below here clearing makes the window BIGGER: carrying on is cheaper even after the cache has lapsed. Parked, the same bar sits at {1:N0}k." -f $Bands.clear_no, $Bands.clear_pk) },
    @{ k = $Bands.park_at; c = $Pal.grey; n = 'park at'
       t = ("{0:N0}k - past here, /park before any gap over an hour. Parking then clearing is a FIXED ~{1} whatever the window grows to; carrying it across a lapse costs the context twice and keeps climbing." -f $Bands.park_at, (Tok ([double]$Bands.restart_park * 1000))) },
    @{ k = $Bands.cut_pk; c = $Pal.yellow; n = 'cut, parked'
       t = ("{0:N0}k - with a checkpoint on disk, a cut starts to pay here. Re-derivation is what you buy back by parking, so this bar sits apart from the unparked one." -f $Bands.cut_pk) },
    @{ k = $Bands.cut_no; c = $Pal.yellow; n = 'cut, unparked'
       t = ("{0:N0}k - with no checkpoint, a cut only pays past here. Below it a restart is a straight loss: you pay the floor again at the 2x write rate and re-derive everything the window already knows." -f $Bands.cut_no) },
    # The ceiling, and the one mark here that is not a cost answer. Drawn as a
    # WALL rather than a threshold - wider, and it never dims once you are past
    # it, because the others stop applying when you cross them and this one
    # starts. It is also the only mark that can sit BELOW a cost bar and still
    # be right: cost says a cut may not pay until 300k or 400k, and cost is not
    # what should have stopped you.
    @{ k = $Bands.max_at; c = $Pal.red; n = 'the ceiling'; wall = $true
       t = ("{0:N0}k - the ceiling: checkpoint and continue in a fresh window. Every other mark here asks whether a restart PAYS, and up here it may well not; this one is about attention, compaction risk and headroom, which the bill does not measure. /park then /clear. Retune it with TOKEN_MAX_AT." -f $Bands.max_at) })

  # Which mark is the one still ahead of you. Only the lowest such tick is lit;
  # the rest are neither past nor imminent and stay quiet.
  $nextK = [double]::MaxValue
  foreach ($b in $bandList) {
    if ($b.k -gt 0 -and $b.k -lt $Bands.ctxmax -and $b.k -gt $K -and $b.k -lt $nextK) { $nextK = $b.k }
  }

  foreach ($b in $bandList) {
    # -le 0 catches a band a snapshot did not carry - an older token-sessions.sh
    # emits no max_at, and $null through [double] is 0, which would otherwise
    # paint a mark hard against the left edge as though the ceiling were there.
    if ($b.k -le 0 -or $b.k -ge $Bands.ctxmax) { continue }
    $f = $b.k / $Bands.ctxmax
    $tg = New-Object Windows.Controls.Grid
    $tg.ClipToBounds = $false
    $c1 = New-Object Windows.Controls.ColumnDefinition
    $c1.Width = New-Object Windows.GridLength ($f, 'Star')
    $c2 = New-Object Windows.Controls.ColumnDefinition
    $c2.Width = New-Object Windows.GridLength ((1 - $f), 'Star')
    $tg.ColumnDefinitions.Add($c1); $tg.ColumnDefinitions.Add($c2)

    $isNext = ($b.k -eq $nextK)
    $isWall = [bool]$b.wall
    $tick = New-Object Windows.Controls.Border
    $tick.Width = $(if ($isWall) { 3 } elseif ($isNext) { 2 } else { 1 })
    $tick.HorizontalAlignment = 'Right'
    $tick.Margin = $(if ($isWall) { '0,-3,0,-3' } else { '0,-2,0,-2' })
    $tick.CornerRadius = New-Object Windows.CornerRadius (1)
    $tick.Background = (Br $b.c)
    $tick.Opacity = $(if ($isWall) { 0.95 }
                      elseif ($isNext) { 1.0 }
                      elseif ($b.k -le $K) { 0.28 } else { 0.6 })
    [Windows.Controls.Grid]::SetColumn($tick, 0)
    $tg.Children.Add($tick) | Out-Null

    $pad = New-Object Windows.Controls.Border
    $pad.Width = 9; $pad.HorizontalAlignment = 'Right'
    $pad.Margin = '0,-4,-4,-4'
    $pad.Background = (Br '#01000000')
    Tip $pad $b.t
    [Windows.Controls.Grid]::SetColumn($pad, 0)
    $tg.Children.Add($pad) | Out-Null

    $g.Children.Add($tg) | Out-Null
    $ticks += @{ k = [double]$b.k; el = $tick; wall = $isWall }
  }
  # Handed to the live repaint so the lit mark follows a window that grows
  # between collects. Without this the weighting is only ever as fresh as the
  # last snapshot, and the payload moves the fill several times in between.
  $g.Tag.ticks = $ticks
  $g
}

# What line 2 says when you point at it. This is the tooltip that used to
# explain the parking bands, and the bands are still on the context gauge where
# they belong - what a person actually wants here is the three numbers that
# decide whether to keep this window, and none of them were anywhere on the row:
#
#   what the next message costs RIGHT NOW, warm against cold. Both inputs were
#     already in the JSON and the row only ever implied it inside a sentence.
#   whether the cache survives until you next speak. The only forecast here.
#   growth against churn. Growth-heavy means your prompts read too much and you
#     can fix that; churn-heavy means the session is old and only cutting helps.
#     Opposite actions, and the row could not tell them apart.
function Cache-Tip($S) {
  $ctx  = [double]$S.context
  $warm = $ctx * 0.1
  $cold = $ctx * 2
  $lf   = [int]$S.cache_left_min
  $gm   = [int]$S.gap_med_min
  $gr   = [double]$S.growth_total
  $ch   = [math]::Max(0, [double]$S.recache_total - $gr)
  $t = @()
  if ($lf -gt 0) {
    $t += "next message here ~{0}, a 0.1x read on {1:N1}k" -f (Tok $warm), $S.context_k
    $t += "letting it lapse first makes the same message ~{0} at the 2x write rate - a {1:N0}x swing" -f (Tok $cold), ($cold / [math]::Max(1, $warm))
  } else {
    $t += "COLD - the next message rewrites {0:N1}k at 2x, about {1}" -f $S.context_k, (Tok $cold)
    $t += 'that rewrite is charged on the next REQUEST, so clearing before you type skips it outright'
  }
  if ($gm -gt 0 -and $lf -gt 0) {
    $t += if ($gm -lt $lf) {
            "cache {0}m and you prompt here about every {1}m - room for {2} more before it lapses" -f $lf, $gm, [math]::Floor($lf / $gm)
          } else {
            "cache {0}m but you prompt here only about every {1}m - it will most likely lapse first" -f $lf, $gm
          }
  } elseif ($gm -le 0) {
    $t += 'no finished cycles here yet, so there is no prompt gap to forecast against'
  }
  if ([double]$S.recache_total -gt 0) {
    $t += "growth {0} against churn {1} - {2}" -f (Tok $gr), (Tok $ch), `
          $(if ($gr -ge $ch) { 'mostly new material, so it is what your prompts read in and it is yours to trim' }
            else { 'mostly the window being rewritten, which nothing but a shorter session avoids' })
  }
  $t -join "`n"
}

# What line 2 says when you point at it. The bar's marks are a ladder of
# measured constants, and a tooltip that only repeated their numbers would be
# telling you what the ticks already draw. So this answers the two questions
# the marks raise and cannot themselves answer: which band am I IN, and how far
# is the next one.
function Ctx-Tip($S, $Bands) {
  $k     = [double]$S.context_k
  $scale = [double]$Bands.ctxmax
  $max   = [double]$Bands.max_at
  $cut   = [math]::Min([double]$Bands.cut_no, [double]$Bands.cut_pk)
  $t = @()
  $t += "{0:N1}k of the {1:N0}k scale - {2:N0}%" -f $k, $scale, ($k * 100 / $scale)
  $t += if ($k -lt [double]$Bands.clear_no) {
          "under the floor: a fresh session starts near {0:N0}k, so there is nothing here a restart would give back" -f $Bands.clear_no
        } elseif ($k -lt [double]$Bands.park_at) {
          'above the floor, under the park bar - carry on, no decision to make yet'
        } elseif ($max -gt 0 -and $k -ge $max) {
          'past the ceiling - checkpoint and continue in a fresh window, whatever the cut arithmetic says'
        } elseif ($k -lt $cut) {
          '/park before any gap over an hour: parking then clearing is a fixed cost, carrying a lapse is the context twice and still growing'
        } else {
          'past the cut bar - a restart now buys back more than the floor and the re-derivation cost'
        }
  # The next mark ahead, in the units the row is measured in. "37k away" is a
  # thing you can feel against a growth number on line 3; "park at 85k" is not.
  $ahead = @(@([double]$Bands.clear_no, [double]$Bands.park_at,
               [double]$Bands.cut_pk, [double]$Bands.cut_no, [double]$Bands.max_at) |
             Where-Object { $_ -gt $k -and $_ -gt 0 -and $_ -lt $scale } | Sort-Object)
  if ($ahead.Count) {
    $n = [double]$ahead[0]
    $nm = if ($n -eq [double]$Bands.clear_no) { 'the floor' }
          elseif ($n -eq [double]$Bands.park_at) { 'the park bar' }
          elseif ($n -eq $max) { 'the ceiling' }
          elseif ($n -eq [double]$Bands.cut_pk) { 'the parked cut bar' }
          else { 'the unparked cut bar' }
    $t += "next mark: {0} at {1:N0}k, {2:N0}k away" -f $nm, $n, ($n - $k)
  } else {
    $t += 'every mark is behind you - there is nothing above this but the end of the scale'
  }
  if ([double]$S.hot -ge 1.0 -and $k -ge [double]$Bands.overheat) {
    $t += "and it is running hot at {0:N1}x - rent on the window is outpacing what the cycles produce" -f [double]$S.hot
  }
  $t -join "`n"
}

# The cache clock, as a bar.
#
# UNUSED since line 2 went back to context - the countdown it draws is the same
# countdown the clock on line 1 prints, in the same colour, a few pixels away,
# and a bar that restates a number is width spent on nothing. Kept whole rather
# than deleted because the measurement below it is the expensive part: the
# caret is the only forecast anywhere in this tool, and rebuilding it from
# scratch would cost more than carrying twenty lines nothing calls.
#
# Two marks, not one. The FILL is what is left of the hour. The caret is how
# long you usually leave between prompts in this session, measured from the
# same left edge - so a caret sitting inside the colour means you will speak
# before it lapses, and a caret out on the grey means you will not. That is the
# whole park-or-carry question, answered by two shapes on one line.
function New-CacheBar {
  param([int]$Left, [int]$GapMed, [int]$Ttl = 60, [bool]$Alive = $true, [int]$Height = 7)
  $g = New-Object Windows.Controls.Grid
  $g.Height = $Height
  $track = New-Object Windows.Controls.Border
  $track.Background = (Br $Pal.track)
  $track.CornerRadius = New-Object Windows.CornerRadius (3.5)
  $g.Children.Add($track) | Out-Null

  $lf = [math]::Max(0, [math]::Min($Ttl, $Left))
  $frac = if ($Ttl -gt 0) { $lf / $Ttl } else { 0 }
  $col = if (-not $Alive) { $Pal.faint }
         elseif ($Left -le 0)  { $Pal.red }
         elseif ($Left -le 10) { $Pal.orange }
         elseif ($Left -le 20) { $Pal.yellow }
         else { $Pal.green }
  $fill = New-Object Windows.Controls.Border
  $fill.Background = (Br $col)
  $fill.CornerRadius = New-Object Windows.CornerRadius (3.5)
  $sc = New-Object Windows.Media.ScaleTransform
  $sc.ScaleX = $frac
  $fill.RenderTransform = $sc
  $fill.RenderTransformOrigin = New-Object Windows.Point (0, 0.5)
  $g.Children.Add($fill) | Out-Null
  $g.Tag = @{ scale = $sc; fill = $fill; frac = $frac }

  # A cold window keeps the empty track and says so in the tip rather than
  # drawing a zero-width fill nobody can see.
  if ($GapMed -gt 0 -and $GapMed -lt $Ttl -and $Alive) {
    $f = $GapMed / $Ttl
    $tg = New-Object Windows.Controls.Grid
    $c1 = New-Object Windows.Controls.ColumnDefinition
    $c1.Width = New-Object Windows.GridLength ($f, 'Star')
    $c2 = New-Object Windows.Controls.ColumnDefinition
    $c2.Width = New-Object Windows.GridLength ((1 - $f), 'Star')
    $tg.ColumnDefinitions.Add($c1); $tg.ColumnDefinitions.Add($c2)
    $mk = New-Object Windows.Controls.Border
    $mk.Width = 2; $mk.HorizontalAlignment = 'Right'
    $mk.Background = (Br $(if ($GapMed -lt $Left) { $Pal.dim } else { $Pal.red }))
    $mk.Opacity = 0.9
    Tip $mk ("you prompt here about every {0}m" -f $GapMed)
    [Windows.Controls.Grid]::SetColumn($mk, 0)
    $tg.Children.Add($mk) | Out-Null
    $g.Children.Add($tg) | Out-Null
  }
  $g
}
function New-Row {
  param($S, $Bands, [double]$Gbud, [bool]$Selected, [bool]$Detail, [double]$FromK = -1,
        [bool]$Dim = $false)
  $live = ($S.running -eq 1)

  # Two borders, not one. A Border has a single brush for all four sides, so a
  # row that is both live and selected could only ever show one of the two
  # states; the outer one owns selection - a ring around the whole row - and the
  # inner one keeps the live accent as a stripe down its left edge.
  $sel = New-Object Windows.Controls.Border
  $sel.CornerRadius = New-Object Windows.CornerRadius (6)
  $sel.Margin = '5,1,7,1'
  $sel.BorderThickness = New-Object Windows.Thickness (1)
  $sel.BorderBrush = (Br $(if ($Selected) { $Pal.blue } else { 'Transparent' }))
  # The row's resting ground, in priority order: selection outranks the one
  # standing state left, because selection is something you just did.
  $isCold = ([int]$S.cache_left_min -le 0)
  # Two lines instead of three: the bar comes off. That shape used to belong to
  # the closed rows, which are not drawn here at all any more; compact mode
  # keeps it, without the tint and the fade that said "nothing left to act on".
  #
  # A cold row takes that shape ALWAYS, whatever the view is set to - the one
  # exception, and it used to run the other way. The argument for keeping a
  # lapsed window full was the bar: band ticks are the only place a size
  # becomes an instruction, and a cold window is exactly when that instruction
  # is due. What that missed is the cost of the room. The bar only ever says
  # one of two things here - carry on, or clear before you type - and the
  # context figure on line 1 is already painted in the same band colours, so
  # the reading survives the cut. Meanwhile a machine with six lapsed windows
  # on it was spending most of the list on the rows there is least to do about,
  # pushing the warm ones - the only rows where anything is still in flight -
  # off the bottom. Cold rows are history; history gets one line less.
  $twoLine = ([bool]$script:View.compact) -or $isCold
  $rest = if ($Selected) { (Br $Pal.sel) }
          elseif ($isCold) { $ColdBrush }
          else { $GhostBrush }
  $sel.Background = $rest
  # A cold window ABOVE the clear bar is a write-off, and the row should say so
  # without being read. What is in it cannot be rescued - nothing typed renews a
  # lapsed prefix - and re-deriving it costs the 2x write on a whole window of
  # material most of which was never the subject. Below the bar the opposite
  # holds: a small cold window is cheaper to carry than to rebuild, because
  # clearing cannot take you under the floor. So dim the write-offs and leave
  # the ones that are still worth typing into at full strength.
  $coldDim = ($isCold -and [double]$S.context_k -ge [double]$(
    if ([int]$S.parked -eq 1) { $Bands.clear_pk } else { $Bands.clear_no }))
  # Picking one row steps every other one back. Selection used to be a tint you
  # had to hunt for across four near-identical rows; contrast finds it for you.
  if ($Dim -or $coldDim) { $sel.Opacity = 0.45 }
  # A whole-row hover, quieter than the per-part one, so the pointer says which
  # row it is on even when it is between two of the things that can be hovered.
  # The resting brush is carried on the Tag rather than assumed to be the ghost:
  # a cold row has its own ground, and hovering must hand that back on leave
  # instead of quietly clearing it.
  $sel.add_MouseEnter({ param($x, $e)
    if ($x.Background -ne $RowBrush) {
      if ($x.Tag) { $x.Tag.rest = $x.Background }
      $x.Background = $RowBrush }
    $x.Opacity = 1.0
    # The wash lifts for the same reason a hover exists at all: greyed means
    # "not yours", not "not readable".
    if ($x.Child) { $x.Child.Opacity = 1.0 }
    if ($x.Tag -and $x.Tag.wash) { $x.Tag.wash.Opacity = 0.0 } })
  $sel.add_MouseLeave({ param($x, $e)
    if ($x.Background -eq $RowBrush) {
      $x.Background = $(if ($x.Tag -and $x.Tag.rest) { $x.Tag.rest } else { $GhostBrush }) }
    # colddim as well as dim: Draw-Rows overwrites .dim on every repaint with
    # the selection answer alone, so the write-off wash has to be its own key
    # or hovering a cold row would permanently un-dim it.
    if ($x.Tag -and ($x.Tag.dim -or $x.Tag.colddim)) { $x.Opacity = 0.45 }
    if ($x.Tag -and $x.Tag.wash) { $x.Tag.wash.Opacity = 1.0 } })

  $shell = New-Object Windows.Controls.Border
  $shell.Padding = '10,7,10,7'
  $shell.BorderThickness = New-Object Windows.Thickness (3, 0, 0, 0)
  $shell.BorderBrush = (Br $(if ($live) { $Pal.green } else { 'Transparent' }))
  # Spawned rows get the shell wrapped so a wash can sit on top of it. Only
  # spawned ones - an extra Grid per row costs little, but nothing is the right
  # amount to pay on the rows that do not need it.
  $wash = $null
  if ([int]$S.spawned -eq 1) {
    $wrap = New-Object Windows.Controls.Grid
    $wrap.Children.Add($shell) | Out-Null
    $wash = New-Object Windows.Controls.Border
    $wash.Background = $WashBrush
    $wash.CornerRadius = New-Object Windows.CornerRadius (6)
    # Never a mouse target. It covers the whole row, so a hit-testable wash
    # would swallow every tooltip and click underneath it.
    $wash.IsHitTestVisible = $false
    $wrap.Children.Add($wash) | Out-Null
    $sel.Child = $wrap
  } else {
    $sel.Child = $shell
  }
  $outer = New-Object Windows.Controls.StackPanel
  $shell.Child = $outer

  # --- line 1: verdict, name, size, clock
  $l1 = New-Object Windows.Controls.Grid
  foreach ($w in 'Auto', '*', 'Auto') {
    $cd = New-Object Windows.Controls.ColumnDefinition
    $cd.Width = if ($w -eq 'Auto') { [Windows.GridLength]::Auto } else { New-Object Windows.GridLength (1, 'Star') }
    $l1.ColumnDefinitions.Add($cd)
  }
  $mark = New-Object Windows.Controls.Grid
  $mark.Width = 13; $mark.Height = 13; $mark.Margin = '0,1,0,0'
  $mark.HorizontalAlignment = 'Center'
  # $runState is the CLI's own flag, not a guess: 0 idle, 1 running, 2 waiting
  # on you, 3 busy but quiet. Anything above 1 is still a turn that started at
  # $runSince, so the clock runs for all of them - only the colour and the words
  # change. An unrecognised value means DOING SOMETHING, never idle.
  $runState = [int]$S.running
  $runSince = [double]$S.run_since
  # Drawn only while a turn is actually RUNNING. `waiting` and `busy but quiet`
  # are states the payload counts above zero, and a clock on either of them is
  # measuring the wrong thing - so the column is empty on both, and Run-Tick
  # re-checks the pid file every second rather than waiting for the next collect
  # to notice the turn ended.
  $runOn    = ($runState -eq 1 -and $runSince -gt 0)
  $runSecs = 0.0
  if ($runOn) { $runSecs = [math]::Max(0.0, (Now-Epoch) - $runSince) }
  $ring = $null
  if ($live) {
    $ring = New-Spinner (Spin-Color $runSecs $runState)
    $mark.Children.Add($ring) | Out-Null
    Tip $mark 'a turn is running in this window right now'
  } else {
    $gl = Text-Block (Verdict-Glyph $S.verdict) 9 (Verdict-Color $S.verdict)
    $gl.HorizontalAlignment = 'Center'; $gl.VerticalAlignment = 'Center'
    $mark.Children.Add($gl) | Out-Null
  }
  # The elapsed clock stacks under the spinner rather than beside it - the
  # spinner keeps the exact spot the idle glyph sits in, and the number hangs
  # below it as a caption rather than pushing the nickname column sideways
  # every time a turn starts or ends. Only visible while a turn is actually
  # running (Collapsed, not empty text, so it takes no row height when idle -
  # a TextBlock still claims a line of height for an empty string).
  $markWrap = New-Object Windows.Controls.StackPanel
  $markWrap.Orientation = 'Vertical'; $markWrap.VerticalAlignment = 'Center'
  $markWrap.Margin = '0,0,7,0'
  $markWrap.Children.Add($mark) | Out-Null
  $runT = Text-Block $(if ($runOn) { Run-Str $runSecs } else { '' }) 9 `
                     (Run-Color $runSecs $runState)
  $runT.FontFamily = 'Consolas'
  $runT.HorizontalAlignment = 'Center'
  $runT.Margin = '0,1,0,0'
  $runT.Visibility = if ($runOn) { 'Visible' } else { 'Collapsed' }
  if ($runOn) { Tip $runT (Run-Tip $runSecs $runState) }
  $markWrap.Children.Add($runT) | Out-Null
  [Windows.Controls.Grid]::SetColumn($markWrap, 0); $l1.Children.Add($markWrap) | Out-Null

  $names = New-Object Windows.Controls.StackPanel
  $names.Orientation = 'Horizontal'

  # The STATE cluster. Extension marks, parked and blocked are one kind of fact -
  # what you can still do with this window - and they used to be scattered: the
  # marks inside the ctx pill among three measurements, P and B trailing the
  # model and effort labels at label size. Both placements buried the two things
  # on the row that are about a DECISION rather than a quantity. They travel
  # together now, in their own pill, at a size you can read without leaning in.
  $state = New-Object Windows.Controls.StackPanel
  $state.Orientation = 'Horizontal'; $state.VerticalAlignment = 'Center'
  # Clipped, because a horizontal StackPanel gives every child the width it
  # asks for and this one sits in the star column: a long nickname next to a
  # long model name would otherwise run straight under the ctx group on the
  # right rather than being cut off at the column edge. The corner widens the
  # card when that is not enough.
  $names.ClipToBounds = $true
  # A typed name used to be tinted blue, to say which rows you had named and
  # which were still the opening words of their first prompt. It reads better
  # in the same white as the rest: a nickname IS the row's title, and giving it
  # its own colour made the ones you cared about enough to name look like a
  # different class of thing from the ones you had not got to yet. Where the
  # name came from is still on the hover, which is where you ask that question
  # anyway - and only when you are about to rename it.
  $nick = Text-Block $S.nick 11.5 $(
    if ($S.alive -ne 1) { $Pal.faint } else { $Pal.text })
  $nickTip = $(if ($S.named -eq 1) { "named by hand - n renames it, empty clears it" }
               else { "from its first prompt - n names it" })
  if ([int]$S.spawned -eq 1) {
    $nickTip += "`nopened by the tooling{0}, not by you - greyed for that reason" -f `
                  $(if ($S.spawn_reason) { ": $($S.spawn_reason)" } else { '' })
  }
  Tip $nick $nickTip
  # The nickname itself breathes on a live session - the accent stripe alone is
  # easy to miss in the corner of an eye, and this is the thing you read.
  if ($live) {
    Animate -Target $nick -Property ([Windows.Controls.TextBlock]::OpacityProperty) `
            -From 1.0 -To 0.55 -Seconds 1.5 -Forever -AutoReverse
  }
  $names.Children.Add($nick) | Out-Null
  # What is answering in there, where the short session id used to sit. The id
  # was only ever a lookup key for the commands below - r copies it, e spends a
  # mark with it - and never something read at a glance; it moved to the detail
  # line, which is where you go when you want to act on a specific window.
  # Model and effort are the pair that change what a cycle in this window
  # COSTS, they can both be changed mid-session without anything else on the
  # row moving, and until now the panel could not see either.
  $ml = [string]$S.model
  if ($ml -or $S.effort) {
    # The same pill the ctx group draws further right: model and effort are
    # both facts about what a cycle in THIS window costs, not what it currently
    # measures, and used to just trail the nickname as plain text - nothing on
    # the row said they were a pair rather than two more labels drifting past.
    $mdl = New-Object Windows.Controls.Border
    $mdl.CornerRadius = New-Object Windows.CornerRadius (4)
    $mdl.Background = (Br '#FF1B1C22')
    $mdl.Padding = '6,1,6,2'
    $mdl.Margin = '7,0,0,0'
    $mdl.VerticalAlignment = 'Center'
    $mp = New-Object Windows.Controls.StackPanel
    $mp.Orientation = 'Horizontal'; $mp.VerticalAlignment = 'Center'
    $mdl.Child = $mp
    if ($ml) {
      # claude-haiku-4-5-20251001 -> haiku-4-5. The vendor prefix is the same on
      # every row and the build date is never the thing being asked.
      $ml = $ml -replace '^claude-', '' -replace '-\d{8}$', ''
      $mb = Text-Block $ml 9.5 $Pal.faint
      Tip $mb "answering with $($S.model)"
      $mp.Children.Add($mb) | Out-Null
    }
    if ($S.effort) {
      # Its own block so it can carry its own colour. xhigh is not a neutral fact
      # about a window - it is the setting that multiplies the output half of
      # every cycle in it, and output is the second-biggest line in the bill.
      $eb = Text-Block $(if ($ml) { "  $($S.effort)" } else { $S.effort }) 9.5 $(
        if ([string]$S.effort -eq 'xhigh') { $Pal.orange } else { $Pal.faint })
      Tip $eb "reasoning effort: $($S.effort)"
      $mp.Children.Add($eb) | Out-Null
    }
    $names.Children.Add($mdl) | Out-Null
  }
  # Which account this window is spending. Its own pill rather than a word in
  # the model one, because it is a different KIND of fact: model and effort say
  # what a cycle here costs, this says whose limit it comes out of - and with
  # two accounts in play that is the difference between a row at 30% and the
  # same row at 88%.
  #
  # Derived per session, never read off the global config: a window started
  # before a cswap switch keeps the credentials it opened with and goes on
  # spending the OLD account, which is exactly the case where guessing is worse
  # than saying nothing. No attribution yet (a window that has not made a
  # request since the last poll) draws no pill at all.
  if ([int]$S.account -gt 0) {
    $acc = New-Object Windows.Controls.Border
    $acc.CornerRadius = New-Object Windows.CornerRadius (4)
    $acc.Background = (Br '#FF1B1C22')
    $acc.Padding = '6,1,6,2'
    $acc.Margin = '5,0,0,0'
    $acc.VerticalAlignment = 'Center'
    $ap = New-Object Windows.Controls.StackPanel
    $ap.Orientation = 'Horizontal'; $ap.VerticalAlignment = 'Center'
    $acc.Child = $ap
    # The number is what the limits panel calls it, so the two can be read
    # against each other; the name is there because a bare digit is not
    # recognisable at a glance and the panel is 40 rows down.
    $an = Text-Block ([string][int]$S.account) 9.5 $Pal.blue
    $ap.Children.Add($an) | Out-Null
    $who = [string]$S.account_email
    if ($who) {
      $short = $who -replace '@.*$', ''
      if ($short.Length -gt 14) { $short = $short.Substring(0, 13) + [char]0x2026 }
      $ab = Text-Block "  $short" 9.5 $Pal.faint
      $ap.Children.Add($ab) | Out-Null
    }
    Tip $acc $("this window is spending account {0}{1} - derived from its own usage payload, not from the global config, so a session that outlived a cswap switch still reports the credentials it opened with" -f `
      [int]$S.account, $(if ($who) { " ($who)" } else { '' }))
    $names.Children.Add($acc) | Out-Null
  }
  # The three grades used to sit here, beside the model pill. They are back at
  # the end of line 3 - the card's bottom-right corner, in a box of their own -
  # because a verdict is the last thing read on a card, not the first, and up
  # here they were three loose letters between a nickname and a state glyph
  # with nothing to say they were a summary of the figures two lines down.
  # Blocked, as a sibling of the parked marker rather than a banner of its own.
  # The two are the same kind of fact - a state this window is in that changes
  # what you can do with it - and P has already taught the eye where to look for
  # that. It breathes because unlike P it is a state you are meant to CLEAR, and
  # a static red letter in a corner is one you stop seeing by the afternoon.
  if ([int]$S.blocked -eq 1) {
    $bk = Text-Block 'B' 11.5 $Pal.red
    $bk.FontWeight = 'Bold'; $bk.Margin = '5,0,0,0'; $bk.VerticalAlignment = 'Center'
    Tip $bk ("input blocked: this window ran out of extension marks, was checkpointed automatically, and is now refusing EVERY prompt - ordinary work and slash commands alike. Anything typed there is cut to the clipboard and saved under token-cut/ rather than lost. Nothing in the session lifts this: u lifts it from here, and /clear is what the window is being pointed at.")
    Animate -Target $bk -Property ([Windows.Controls.TextBlock]::OpacityProperty) `
            -From 1.0 -To 0.4 -Seconds 1.3 -Forever -AutoReverse
    $state.Children.Add($bk) | Out-Null
  }
  [Windows.Controls.Grid]::SetColumn($names, 1); $l1.Children.Add($names) | Out-Null

  # The headline slot carries the SHARE; the size moved down to sit at the end
  # of the bar it measures. They used to be the other way round and the pairing
  # was wrong at both ends: "142.4k" on the top line is a number you cannot act
  # on without four measured constants in your head, while the bar underneath -
  # which is a picture of exactly the share - carried no label at all. A
  # percentage is the one form of this number that means the same thing on
  # every row, so it belongs where rows are compared; the absolute belongs
  # against the gauge, where it reads as that gauge's value.
  #
  # A two-line row has no bar, so nothing down there could hold the absolute
  # and the headline falls back to it.
  $k = Text-Block ('{0:N1}k' -f $S.context_k) $(if ($twoLine) { 11.5 } else { 10.5 }) `
                  (Band-Color ([double]$S.context_k) $Bands)
  $k.Margin = $(if ($twoLine) { '8,0,10,0' } else { '7,0,2,0' })
  Lerp-Num "$($S.sid):ctx" $k ([double]$S.context_k) { param($v) '{0:N1}k' -f $v } | Out-Null
  $ctxTip = "{0:N0} tokens carried; {1:N0}% of the {2:N0}k full scale" -f `
                $S.context, ($S.context_k * 100 / $Bands.ctxmax), $Bands.ctxmax
  if ([int]$S.live -eq 1) {
    $ctxTip += "`n{0:N0} of that arrived in the cycle running now, across {1} request{2} the Stop hook has not seen yet." -f `
                 ([double]$S.live_growth), [int]$S.live_requests, $(if ([int]$S.live_requests -eq 1) { '' } else { 's' })
  }
  Tip $k $ctxTip

  # The group's headline used to be a percentage of the full scale whenever the
  # row had a bar - but the bar IS that share, drawn to the same scale in the
  # same colour, so the number said the picture again. It is gone; the absolute
  # beside the bar is the only figure here, and on a two-line row (which has no
  # bar) it moves up into the slot the percentage used to hold.
  $head = $(if ($twoLine) { $k } else { $null })

  # The cache clock is the one number that decides anything, so it is the one
  # allowed to shout. COLD is a state, not a duration.
  $clk = New-Object Windows.Controls.TextBlock
  # The minimum width keeps 'COLD' and '120m' ending on the same pixel, so the
  # pill does not twitch as the number shrinks. It was 42, wider than the widest
  # of them, which spent the difference as a gap in front of the one number the
  # group exists to deliver.
  $clk.FontFamily = 'Consolas'; $clk.FontSize = 11.5; $clk.MinWidth = 30
  $clk.TextAlignment = 'Right'
  if ([int]$S.cache_left_min -le 0) {
    $clk.Text = 'COLD'; $clk.Foreground = (Br $Pal.red); $clk.FontWeight = 'Bold'
    Tip $clk ("the cache has lapsed; the next message rewrites {0:N1}k at 2x" -f $S.context_k)
    Animate -Target $clk -Property ([Windows.Controls.TextBlock]::OpacityProperty) `
            -From 1.0 -To 0.45 -Seconds 1.1 -Forever -AutoReverse
  } else {
    $clk.Text = ('{0}m' -f [int]$S.cache_left_min)
    $clk.Foreground = (Br $(if ([int]$S.cache_left_min -le 10) { $Pal.orange }
                            elseif ([int]$S.cache_left_min -le 20) { $Pal.yellow }
                            else { $Pal.dim }))
    # The clock owns the cache tooltip now that line 2 has gone back to
    # context. It was attached to a bar that drew the same countdown the clock
    # already prints, so pointing at the picture explained the number and
    # pointing at the number explained nothing. What the next message costs
    # warm against cold belongs to the clock, because the clock is what decides
    # which of the two you are about to pay.
    Tip $clk (Cache-Tip $S)
  }
  # Extension marks, immediately left of the clock they are a budget for.
  #
  # A mark is a TICKET for carrying this window past the end of an hour. Filled
  # is one you still hold; hollow is one this window has already spent, and a
  # spent one takes the PLACE of the filled mark it was rather than appearing
  # beside it - so the row is always exactly `allowed` glyphs wide and what
  # changes as the day goes on is which of them are solid.
  #
  # That width matters more than it looks. Drop the spent ones and the row
  # shrinks as the session ages, so a five-mark window down to its last ticket
  # draws identically to a one-mark window that has never been used - opposite
  # situations wanting opposite actions. Append them instead of substituting
  # and spending one makes the row GROW, which reads as a mark being handed out
  # at the exact moment one was taken away.
  #
  # Filled and hollow are two blocks rather than one string so they can carry
  # different weight: what you hold is blue and legible, what you spent is
  # faint. A hollow mark is also INERT - shift-e cannot take one back (the same
  # clamp lives in set_extend), because removing it would not return a ticket,
  # it would erase a crossing this window actually made and hand out a free
  # extension, since what is left is allowed minus used.
  $exa = [int]$S.ext_allowed; $exl = [int]$S.ext_left; $exu = [int]$S.ext_used
  $exs = [math]::Min($exu, $exa)     # spent, clamped to the row's width
  if ($exa -gt 0 -or $exu -gt 0) {
    $em = New-Object Windows.Controls.StackPanel
    $em.Orientation = 'Horizontal'
    # 11pt rather than 8.5. A mark is a ticket for one crossing of the hour and
    # running out is what sends a window cold - the most consequential fact on
    # the row was being drawn at the smallest size on it.
    if ($exa -le 6) {
      # A restart arrow rather than a diamond: what a mark actually buys is one
      # more crossing of the hour without the window going cold, which a gem
      # never said and a clock-arrow does. Held and spent share the same glyph -
      # the diamonds only ever told the two apart by colour anyway - so the
      # meaning here rides entirely on blue-in-hand versus faint-already-spent.
      if ($exl -gt 0) {
        $em.Children.Add((Text-Block (([string][char]0x21BB) * $exl) 11 $Pal.blue)) | Out-Null
      }
      if ($exs -gt 0) {
        $em.Children.Add((Text-Block (([string][char]0x21BB) * $exs) 11 $Pal.faint)) | Out-Null
      }
    } else {
      # Past six, a count. Eight diamonds is a number you have to stop and read
      # rather than see, which defeats the point of drawing shapes at all.
      $em.Children.Add((Text-Block ('{0}/{1}' -f $exl, $exa) 11 `
                        $(if ($exl -gt 0) { $Pal.blue } else { $Pal.faint }))) | Out-Null
    }
    $em.Margin = '0,1,0,0'; $em.VerticalAlignment = 'Center'
    # The whole point of a mark, in the tip: what one extension would cost
    # against what the same window costs to rebuild once it has gone cold.
    $ratio = if ([double]$S.ext_cost -gt 0) { [double]$S.lapse_cost / [double]$S.ext_cost } else { 20 }
    $spent = if ($exs -gt 0) {
      " The {0} hollow one{1} already been spent carrying it past an hour, and cannot be taken back." -f `
        $exs, $(if ($exs -eq 1) { ' has' } else { 's have' })
    } else { '' }
    $cap = [int]$(if ($Bands.ext_max) { $Bands.ext_max } else { 5 })
    Tip $em ("{0} extension mark{1} left.{2} A mark is a ticket for one crossing of the hour: with none in hand when the clock runs out, this window goes cold whatever the read would have cost. Keeping this {3:N0}k window warm costs ~{4} (a 0.1x cache read) against ~{5} to rebuild it cold (a 2x write) - {6:N0}x. This is spent for you: ClaudeTokenPokeDue types into that window's own console inside the last 8 minutes, because only the session itself can renew its prefix. Every mark goes on a renewal; once they are gone the sweep types /park instead and this window stops taking prompts until you lift it here with u. Zero marks means leave this session alone entirely. e adds a mark up to {7}, shift-e removes an unspent one." -f `
             $exl, $(if ($exl -eq 1) { '' } else { 's' }), $spent, [double]$S.context_k, `
             (Tok ([double]$S.ext_cost)), (Tok ([double]$S.lapse_cost)), $ratio, $cap)
    # Ahead of P and B: the marks are the count, the letters are the states, and
    # the count is the one that decides whether the states still matter.
    $state.Children.Insert(0, $em)
  }

  # The three numbers on the right of a row are one fact in three parts, all of
  # them about the same cached context: how full it is, how many crossings of
  # the hour it can still buy, and how long until the next one. They used to
  # sit in two grid columns with the same gap between them as between the name
  # and the percentage, so nothing on the row said they belonged together - and
  # read one at a time they invite the wrong question ("is 43% a lot?") instead
  # of the only one that matters, which is whether this window survives the
  # next gap.
  #
  # A pill rather than a rule or a bracket. It groups without adding a fifth
  # line to a row that has four already, it carries the title the 5h/7d rows
  # taught the eye to look for on the left, and the card already uses this
  # exact fill for the name box and the message line, so it is not new chrome.
  $grp = New-Object Windows.Controls.Border
  $grp.CornerRadius = New-Object Windows.CornerRadius (4)
  $grp.Background = (Br '#FF1B1C22')
  $grp.Padding = '7,1,7,2'
  $grp.Margin = '7,0,0,0'
  $grp.VerticalAlignment = 'Center'
  $gp = New-Object Windows.Controls.StackPanel
  $gp.Orientation = 'Horizontal'; $gp.VerticalAlignment = 'Center'
  # 'ctx' and not 'cached': three characters where six would be, on the one
  # line of the row that the model and effort labels have already made longer.
  # What the group actually covers is on the hover, which is where the question
  # gets asked.
  # A clock, not the word "ctx".
  #
  # The pill lost its other members one at a time - the marks went to the state
  # cluster, the percentage went to line 3, the absolute went down beside the bar
  # it measures - and what is left in here is a countdown. So the title was
  # labelling the group by the thing it no longer holds, and "ctx" above a number
  # reading 44m invited the one reading it cannot mean. The word itself moved to
  # line 2, where the context bar actually is.
  #
  # U+23F1 lives in Segoe UI Symbol rather than in the UI face, and WPF font
  # fallback is not something to leave to chance on a glyph that IS the label -
  # if it misses, the group loses its title entirely. Named explicitly for that
  # reason.
  $ctxTitle = Text-Block ([string][char]0x23F1) 10 $Pal.faint
  $ctxTitle.FontFamily = New-Object Windows.Media.FontFamily 'Segoe UI Symbol, Segoe UI, Consolas'
  $ctxTitle.VerticalAlignment = 'Center'; $ctxTitle.Margin = '0,1,6,0'
  # The hover the icon owns is the MECHANISM, and it is deliberately not the one
  # on the number beside it: Cache-Tip answers "what does the next message cost
  # warm against cold", which is the money question, and this answers "what is
  # this clock, what moves it, and what happens when it reaches zero" - which is
  # the question a person actually has the first few times they see a countdown
  # on a row and cannot act on it.
  $lapseAt = $(if ([int]$S.cache_left_min -gt 0) {
                 (Get-Date).AddMinutes([int]$S.cache_left_min).ToString('HH:mm') } else { '' })
  $clkTip = @()
  $clkTip += "The prompt cache on this window. Anthropic holds the cached prefix for ONE HOUR from the last request, and every request slides that hour forward - so a session you are working never lapses, and the countdown is really a measure of how long you have been away."
  if ([int]$S.cache_left_min -gt 0) {
    $clkTip += "Lapses at about {0} ({1}m from now) unless something goes out before then." -f $lapseAt, [int]$S.cache_left_min
    $clkTip += "At zero the prefix is dropped and the next message rebuilds all {0:N1}k at the 2x write rate instead of reading it at 0.1x. That charge lands on the next REQUEST, not at the lapse itself - which is why clearing a cold window before you type costs nothing." -f $S.context_k
  } else {
    $clkTip += "It has already lapsed. Nothing is being held any more: the next message here rewrites {0:N1}k from scratch at 2x, and /clear before you type avoids that outright." -f $S.context_k
  }
  $clkTip += "Anything counts as a request - a prompt, a slash command, the renewal the tooling types in. Only the session itself can do it; nothing outside the window can touch its prefix."
  $clkTip += $(if ([int]$S.ext_left -gt 0) {
      "{0} extension mark{1} left, so this window will be renewed for you inside the last 8 minutes." -f `
        [int]$S.ext_left, $(if ([int]$S.ext_left -eq 1) { '' } else { 's' })
    } else {
      "No extension marks left: instead of a renewal it gets /park typed into it while it is still warm, and then stops taking prompts until you lift the block here with u."
    })
  $clkTip += "Midnight breaks it regardless of the clock - the date sits in the system prompt, so the prefix invalidates from the first block down at 00:00."
  Tip $ctxTitle ($clkTip -join "`n`n")
  # Order inside the pill, on a two-line row: ctx 144.3k [clock] 59m. The label
  # and the absolute go in FRONT of the icon, because each title has to sit
  # against the number it names - with the icon first, the clock glyph led a
  # figure in thousands of tokens and named the wrong one. On a compact row the
  # absolute is beside its bar on line 2 and the pill is the clock alone.
  #
  # The marks used to open this group. They left for the state cluster on line 1:
  # everything still in here is about the hour or the size, and a count of
  # tickets was neither - it answers "what can I do with this window", which is
  # the other question entirely.
  if ($head) {
    $ctxWord = Text-Block 'ctx' 8 $Pal.faint
    $ctxWord.VerticalAlignment = 'Center'; $ctxWord.Margin = '0,1,5,0'
    Tip $ctxWord (Ctx-Tip $S $Bands)
    $gp.Children.Add($ctxWord) | Out-Null
    $head.Margin = '0,0,8,0'
    $gp.Children.Add($head) | Out-Null
  }
  $gp.Children.Add($ctxTitle) | Out-Null
  $clk.HorizontalAlignment = 'Right'; $clk.VerticalAlignment = 'Center'
  $gp.Children.Add($clk) | Out-Null
  $grp.Child = $gp

  # Line 1's right column now carries the STATE, and the ctx group drops to the
  # end of the bar it describes. The pill was a picture of a number sitting one
  # line above the picture of the same number; putting them on the same line
  # makes the bar the group's own illustration rather than a repeat of it.
  #
  # A compact row has no line 2 at all, so there the pill stays here, after the
  # cluster - which is the order the two had when both lived on this line.
  $rt = New-Object Windows.Controls.StackPanel
  $rt.Orientation = 'Horizontal'; $rt.VerticalAlignment = 'Center'
  $rt.HorizontalAlignment = 'Right'
  # PARKED, anchored hard against the left of the marks.
  #
  # It was a bold blue P inside the state pill until 2026-09-10, then a word
  # beside the model pill, and this is the third and right place for it: the
  # marks say how many crossings of the hour this window has left, and whether
  # there is a checkpoint behind it is the other half of that same sentence.
  # Reading them together answers "can I walk away from this" outright - and it
  # is the one state on the row a person recognises faster as a word than as an
  # initial.
  #
  # OUTSIDE the pill, immediately in front of it. What is in that box is what you
  # can still do with this window, all of it changeable from here with a key; a
  # checkpoint is a file somewhere else, so it sits against the box rather than
  # in it.
  if ($S.parked -eq 1) {
    $pk = Text-Block 'PARKED' 9 $(if ($S.ck_stale -eq 1) { $Pal.orange } else { $Pal.blue })
    $pk.FontWeight = 'Bold'; $pk.Margin = '7,0,0,0'; $pk.VerticalAlignment = 'Center'
    Tip $pk $(if ($S.ck_stale -eq 1) {
      "parked $($S.ck_age_min)m ago and the window has worked since, so the checkpoint is behind - /park again before stepping away, or unparking resumes from an older place than this window is at" }
      else { "checkpoint on disk: $($S.ck_name). Clearing this window costs ~5k to pick the strand back up instead of ~34k, which is the whole reason to park before a gap." })
    $rt.Children.Add($pk) | Out-Null
  }
  if ($state.Children.Count -gt 0) {
    $sb = New-Object Windows.Controls.Border
    $sb.CornerRadius = New-Object Windows.CornerRadius (4)
    $sb.Background = (Br '#FF1B1C22')
    $sb.Padding = '7,1,7,2'; $sb.Margin = '7,0,0,0'
    $sb.VerticalAlignment = 'Center'
    $sb.Child = $state
    $rt.Children.Add($sb) | Out-Null
  }
  if ($twoLine) { $rt.Children.Add($grp) | Out-Null }
  [Windows.Controls.Grid]::SetColumn($rt, 2); $l1.Children.Add($rt) | Out-Null
  $outer.Children.Add($l1) | Out-Null

  # --- line 2: where this window sits on the ladder
  #
  # This line went to the cache clock for a while, on the argument that context
  # only ever climbs and climbing is not a deadline. The argument was about the
  # FILL and it was right about the fill; it was wrong about the marks. A
  # countdown bar is a picture of a number printed a few pixels away in the
  # same colour, so line 2 said the same thing the clock said and its tooltip
  # - what the next message costs - had nothing to do with the shape above it.
  #
  # The band ticks were the part worth the width. They are the only place a
  # size becomes an instruction: below the floor, carrying on beats clearing
  # even cold and unparked; past the park bar, checkpoint before you step away;
  # past the cut bars, a restart finally pays. So context is back on the line,
  # the clock keeps the cost tooltip that was always about it, and line 3 keeps
  # the percentage for cross-row comparison. See New-CtxBar for the marks.
  #
  # Null rather than absent, and the repaint at the foot of this file already
  # guards on it - a compact row simply has no bar to re-animate.
  $bar = $null
  if (-not $twoLine) {
    $l2 = New-Object Windows.Controls.Grid
    $l2.Margin = '20,7,0,2'
    $l2.ClipToBounds = $false
    # Four columns now: the word, the bar, its value, the clock pill. The label
    # leads rather than trailing, because the bar is the widest thing on the card
    # and a name at the far end of it is read after the shape it was supposed to
    # introduce.
    $bc0 = New-Object Windows.Controls.ColumnDefinition
    $bc0.Width = [Windows.GridLength]::Auto
    $bc1 = New-Object Windows.Controls.ColumnDefinition
    $bc1.Width = New-Object Windows.GridLength (1, 'Star')
    $bc2 = New-Object Windows.Controls.ColumnDefinition
    $bc2.Width = [Windows.GridLength]::Auto
    # A fourth column, for the ctx pill that came down off line 1.
    $bc3 = New-Object Windows.Controls.ColumnDefinition
    $bc3.Width = [Windows.GridLength]::Auto
    $l2.ColumnDefinitions.Add($bc0); $l2.ColumnDefinitions.Add($bc1)
    $l2.ColumnDefinitions.Add($bc2); $l2.ColumnDefinitions.Add($bc3)
    # The word the pill gave up, put where the thing it names actually is. Same
    # 8pt faint as every other group title on the card, so it reads as a label on
    # the bar rather than as a fourth measurement.
    $ctxLbl = Text-Block 'ctx' 8 $Pal.faint
    $ctxLbl.VerticalAlignment = 'Center'; $ctxLbl.Margin = '0,1,6,0'
    Tip $ctxLbl (Ctx-Tip $S $Bands)
    [Windows.Controls.Grid]::SetColumn($ctxLbl, 0); $l2.Children.Add($ctxLbl) | Out-Null
    $bar = New-CtxBar ([double]$S.context_k) $Bands $FromK
    $bar.VerticalAlignment = 'Center'
    Tip $bar (Ctx-Tip $S $Bands)
    [Windows.Controls.Grid]::SetColumn($bar, 1); $l2.Children.Add($bar) | Out-Null
    $k.VerticalAlignment = 'Center'
    [Windows.Controls.Grid]::SetColumn($k, 2); $l2.Children.Add($k) | Out-Null
    [Windows.Controls.Grid]::SetColumn($grp, 3); $l2.Children.Add($grp) | Out-Null
    $outer.Children.Add($l2) | Out-Null
  }

  # --- line 3: growth in tokens, the spark, cycles, cost split, total, grades
  #
  # On a compact row this IS line 2, and it grows one column at the front to
  # take the percentage that came off the bar. Everything after it shifts along
  # by $co rather than the whole line being written out twice - one offset is a
  # great deal easier to keep correct than two copies of six SetColumn calls.
  # The column has to be PREPENDED rather than appended: the star column is what
  # absorbs the slack, and it must stay fifth from the left or the cost split
  # stops stretching and the grades stop sitting on the right edge.
  $l3 = New-Object Windows.Controls.Grid
  $l3.Margin = $(if ($twoLine) { '20,3,0,0' } else { '20,6,0,0' })
  # The leading column is gone. It used to hold the context percentage, which
  # now sits on line 1, so keeping an Auto column that measures to zero width
  # would only be a place for the next thing to be dropped into by accident.
  # $co survives at 0 rather than being edited out of six SetColumn calls: one
  # offset is far easier to keep correct than six literals, and the next column
  # added or removed here is a one-line change again.
  $co = 0
  $cols = @('Auto', 'Auto', 'Auto', 'Auto', '*', 'Auto')
  foreach ($w in $cols) {
    $cd = New-Object Windows.Controls.ColumnDefinition
    $cd.Width = if ($w -eq 'Auto') { [Windows.GridLength]::Auto } else { New-Object Windows.GridLength (1, 'Star') }
    $l3.ColumnDefinitions.Add($cd)
  }
  # The cycle in flight, as a bar of its own rather than only as a number.
  $liveRow = $null
  if ([int]$S.live -eq 1) {
    $liveRow = @{ cycle  = ([int]$S.cycles + 1)
                  growth = [double]$S.live_growth
                  output = [double]$S.live_output }
  }
  $spark = New-Spark $S.recent $Gbud $live $liveRow -Key ([string]$S.sid)
  [Windows.Controls.Grid]::SetColumn($spark, 0 + $co); $l3.Children.Add($spark) | Out-Null

  # The growth number beside the bars. A sparkline says "was this one bigger
  # than that one"; it cannot say how big. While a cycle is running this reports
  # THAT cycle - the one you can still do something about - and falls back to
  # the last finished one only when nothing is in flight.
  $items = @($S.recent)
  $lastG = 0.0
  if ($items.Count) { $lastG = [double]$items[$items.Count - 1].growth }
  if ($liveRow) { $lastG = [double]$S.live_growth }
  $gratio = 0.0
  if ($Gbud -gt 0) { $gratio = $lastG / $Gbud }
  $gt = Text-Block ("  +{0}" -f (Tok $lastG)) 9.5 (Growth-Color $gratio)
  $gt.VerticalAlignment = 'Bottom'; $gt.Margin = '2,0,8,0'
  Lerp-Num "$($S.sid):growth" $gt ([double]$lastG) { param($v) '  +{0}' -f (Tok $v) } | Out-Null
  if ($liveRow) {
    Tip $gt ("this cycle has grown {0} so far - {1:N0}% of the {2} budget, across {3} request{4} the hook has not seen yet; {5} of growth all told" -f `
                   (Tok $lastG), ($gratio * 100), (Tok $Gbud), [int]$S.live_requests, `
                   $(if ([int]$S.live_requests -eq 1) { '' } else { 's' }), (Tok $S.growth_total))
  } else {
    Tip $gt ("last cycle grew {0} - {1:N0}% of the {2} budget; {3} of growth all told" -f `
                   (Tok $lastG), ($gratio * 100), (Tok $Gbud), (Tok $S.growth_total))
  }
  # The growth number is the one figure on the row that is still being written
  # while you look at it, so it breathes with the bar it labels.
  if ($live) {
    Animate -Target $gt -Property ([Windows.Controls.TextBlock]::OpacityProperty) `
            -From 1.0 -To 0.5 -Seconds 1.5 -Forever -AutoReverse
  }
  [Windows.Controls.Grid]::SetColumn($gt, 1 + $co); $l3.Children.Add($gt) | Out-Null

  # Cycles and renewals, as a pill of their own rather than a dim figure
  # between two other dim figures.
  #
  # How many cycles a window has run, and how many times it has been carried
  # past the end of an hour, is the shortest history of it there is: how much
  # work went in, and how much of its life was bought rather than earned. Both
  # were drawn at 9.5pt faint, the same weight as everything else on the line,
  # which made the row's only COUNTS look like two more measurements to skim.
  #
  # A renewal is marked in place, never subtracted. The cycles DID happen and
  # their cost is real; what the arrow says is who asked for them. A poke or an
  # automatic /park is a real cycle - prompt, response, history row, bill - but
  # it is not work, and left unmarked it drags the per-cycle medians and the
  # churn grade of the very windows it was keeping cheap. A window held warm
  # overnight would show sixteen cycles of near-zero output and grade as the
  # least productive session on the machine, which is precisely backwards.
  $cgrp = New-Object Windows.Controls.Border
  $cgrp.CornerRadius = New-Object Windows.CornerRadius (4)
  $cgrp.Background = (Br '#FF1B1C22')
  $cgrp.Padding = '7,1,7,2'
  $cgrp.Margin = '0,0,10,0'
  $cgrp.VerticalAlignment = 'Bottom'
  $cp = New-Object Windows.Controls.StackPanel
  $cp.Orientation = 'Horizontal'; $cp.VerticalAlignment = 'Center'
  $cgrp.Child = $cp
  $cycLbl = Text-Block 'cycles' 8 $Pal.faint
  $cycLbl.VerticalAlignment = 'Center'; $cycLbl.Margin = '0,1,6,0'
  $cp.Children.Add($cycLbl) | Out-Null
  $cyc = Text-Block ([string][int]$S.cycles) 10.5 $Pal.dim
  $cyc.VerticalAlignment = 'Center'
  $cp.Children.Add($cyc) | Out-Null
  # Not "+1h". That read as an hour - which on a row whose whole subject is a
  # sixty-minute cache is the worst possible thing for it to look like. The
  # refresh glyph says renewal, which is what a hold is, and cannot be read as a
  # unit of anything. Blue, because a renewal is the same currency as the marks
  # on the clock pill: one mark spent is exactly one of these.
  if ([int]$S.pokes -gt 0) {
    $pk = Text-Block ("+{0}{1}" -f [int]$S.pokes, ([char]0x21BB)) 9.5 $Pal.blue
    $pk.VerticalAlignment = 'Center'; $pk.Margin = '5,0,0,0'
    $cp.Children.Add($pk) | Out-Null
  }
  $cycTip = "{0} cycles, {1} of output, {2} of growth" -f `
                  $S.cycles, (Tok $S.output_total), (Tok $S.growth_total)
  if ([int]$S.pokes -gt 0) {
    $cycTip += "`n{0} of them typed by the tooling to hold this window warm - a renewal costs about a tenth of what letting it lapse does{1}" -f `
                 [int]$S.pokes, `
                 $(if ([int]$S.poke_age_min -ge 0) { ", most recently {0}m ago" -f [int]$S.poke_age_min } else { '' })
  }
  # The marks themselves stay on the clock pill, beside the hour they buy. What
  # belongs here is how many crossings this window has already MADE - the half
  # of that budget the clock stops showing the moment a mark is spent.
  $cycTip += "`n{0} of {1} extension mark(s) spent, {2} still in hand." -f `
               [int]$S.ext_used, [int]$S.ext_allowed, [int]$S.ext_left
  Tip $cgrp $cycTip
  [Windows.Controls.Grid]::SetColumn($cgrp, 2 + $co); $l3.Children.Add($cgrp) | Out-Null

  # Heat, which --json has carried all along and this panel never drew. It is
  # the one number here that is a RATIO rather than a size: what the window
  # costs to hold against what it is producing, so a big window doing big work
  # stays cool and a big window answering one-liners does not. Blank under three
  # cycles or under the floor, where it would be measuring noise.
  $hot = [double]$S.hot
  $ht = Text-Block $(if ($hot -gt 0) { '{0:N1}x' -f $hot } else { '' }) 9.5 (Heat-Color $hot)
  $ht.VerticalAlignment = 'Bottom'; $ht.Margin = '0,0,10,0'; $ht.FontWeight = 'SemiBold'
  if ($hot -gt 0) {
    Tip $ht ("heat {0:N2}x - this window costs {0:N2} to hold for what a cycle here produces{1}" -f `
             $hot, $(if ($hot -ge 1.0) { '; past 1.0x the rent is bigger than the work' } else { '' }))
    # Only while the figure stays a figure. Blank-to-number (heat only exists
    # past 3 cycles and above the floor) is a state changing, not a value
    # moving, so that edge snaps; once it is showing, cycle to cycle is a small
    # step and worth the same short slide as everything else here.
    $hprev = Prev-Val "hot:$($S.sid)" $hot
    if ($hprev -gt 0) {
      Lerp-Num "hot:$($S.sid)" $ht $hot { param($v) '{0:N1}x' -f $v } | Out-Null
    }
  }
  [Windows.Controls.Grid]::SetColumn($ht, 3 + $co); $l3.Children.Add($ht) | Out-Null

  # Spend, as a gauge with its total beside it.
  #
  # Two things left this pill and one arrived. The three percentages are gone:
  # output / write / read said where the money went, which is a real question,
  # but not one asked at a glance across eight rows - and three coloured figures
  # reading 34% 49% 17% on every row taught the eye to skip the whole group.
  # They are in the hover now, where a breakdown belongs.
  #
  # What replaced them answers what the number alone never could: is this a lot?
  # "1.76M weighted" means nothing without four other windows to hold it
  # against, and the bar IS those windows - full scale is the 90th percentile of
  # every session on this machine and the ticks are its quartiles, so the fill
  # reads as this window's place among yours rather than as an abstract size.
  # See New-SpendBar for the measurement behind the bands.
  #
  # And the total went grey. It is the gauge's VALUE now rather than the
  # headline of a group, and a SemiBold near-white figure was pulling the eye to
  # the one part of the pill that had stopped being the thing to read first.
  $sgrp = New-Object Windows.Controls.Border
  $sgrp.CornerRadius = New-Object Windows.CornerRadius (4)
  $sgrp.Background = (Br '#FF1B1C22')
  $sgrp.Padding = '7,2,7,3'
  $sgrp.Margin = '0,0,0,0'
  $sgrp.VerticalAlignment = 'Bottom'
  $sp3 = New-Object Windows.Controls.StackPanel
  $sp3.Orientation = 'Horizontal'; $sp3.VerticalAlignment = 'Center'
  $sgrp.Child = $sp3
  $spTitle = Text-Block 'spend' 8 $Pal.faint
  $spTitle.VerticalAlignment = 'Center'; $spTitle.Margin = '0,1,7,0'
  $sp3.Children.Add($spTitle) | Out-Null

  # The whole group shares one hover, because the bar, the ticks and the figure
  # are three views of a single number - and the split the percentages used to
  # draw lives in it, unabbreviated, which is more than three headline figures
  # could ever say.
  $spendTip = ("{0} weighted - what this window has COST in input-equivalents: an output token counts 5x an uncached input one, a cache write 2x, a cache read 0.1x.`n`noutput {1} ({2:N0}%) - work done.  cache writes {3} ({4:N0}%) - context paid for at 2x.  cache reads {5} ({6:N0}%) - rent on context already paid for.`n`nMostly-output is a window earning its keep; mostly-read is one being carried rather than used.`n`nThe bar is this figure against every session on this machine: the ticks are {7}, {8} and {9}, and full scale is {10} - the third quartile, so half of your sessions sit in the left half of it and the top quarter pins." -f `
    (Tok $S.cost.total), `
    (Tok ([double]$S.cost.output)), [double]$S.cost.pct_output, `
    (Tok ([double]$S.cost.cache_write)), [double]$S.cost.pct_write, `
    (Tok ([double]$S.cost.cache_read)), [double]$S.cost.pct_read, `
    (Tok $SpendBands.ok), (Tok $SpendBands.watch), (Tok $SpendBands.heavy), (Tok $SpendBands.full))
  if ([int]$S.live -eq 1) {
    $spendTip += "`n`nIncluding {0} spent in the cycle still running - output {1}, cache writes {2}." -f `
                   (Tok ([double]$S.live_cost)), (Tok ([double]$S.live_output)), (Tok ([double]$S.live_recache))
  }
  $sbar = New-SpendBar ([double]$S.cost.total) (Prev-Val "spend:$($S.sid)" ([double]$S.cost.total))
  $sbar.VerticalAlignment = 'Center'; $sbar.Margin = '0,0,7,0'
  $sp3.Children.Add($sbar) | Out-Null

  $cost = Text-Block (Tok $S.cost.total) 10.5 $Pal.dim
  $cost.VerticalAlignment = 'Center'
  Lerp-Num "$($S.sid):cost" $cost ([double]$S.cost.total) { param($v) Tok $v } | Out-Null
  $sp3.Children.Add($cost) | Out-Null
  Tip $sgrp $spendTip

  $right = New-Object Windows.Controls.StackPanel
  $right.Orientation = 'Horizontal'; $right.VerticalAlignment = 'Bottom'
  $right.Children.Add($sgrp) | Out-Null

  # The three grades, back where they started: hard against the right edge of
  # the last figure line, which is this card's bottom-right corner.
  #
  # They spent a while up on line 1 beside the model pill, on the argument that
  # "is this window doing well" is asked in the same glance as "what is
  # answering in there". It is - but a verdict read BEFORE its evidence is just
  # three letters, and up there they had no box and no neighbour, so they read
  # as decoration trailing the nickname. Down here they close the line whose
  # numbers they grade, and the box says they are one thing rather than three.
  $gbox = New-Object Windows.Controls.Border
  $gbox.CornerRadius = New-Object Windows.CornerRadius (4)
  $gbox.Background = (Br '#FF1B1C22')
  $gbox.BorderBrush = (Br $Pal.line)
  $gbox.BorderThickness = 1
  $gbox.Padding = '7,2,7,3'
  $gbox.Margin = '7,0,0,0'
  $gbox.VerticalAlignment = 'Bottom'
  $grades = New-Object Windows.Controls.StackPanel
  $grades.Orientation = 'Horizontal'; $grades.VerticalAlignment = 'Center'
  $gbox.Child = $grades
  foreach ($g in @($S.grades.spend, $S.grades.churn, $S.grades.control)) {
    $gg = Text-Block $(if ($g) { $g } else { [string][char]0x00B7 }) 10.5 (Grade-Color $g)
    $gg.FontWeight = 'SemiBold'; $gg.VerticalAlignment = 'Center'
    $gg.Margin = '0,0,5,0'
    $grades.Children.Add($gg) | Out-Null
  }
  # The last letter owns the right edge of the box, so it gets no trailing gap.
  if ($grades.Children.Count -gt 0) {
    $grades.Children[$grades.Children.Count - 1].Margin = '0,0,0,0'
  }
  Tip $gbox ("spend {0} / churn {1} / control {2}   -   {3:N1}k per cycle, {4:N0}% churn. Graded against your own median cycle, not an absolute: spend is what a cycle here costs, churn how much of that is the window being rewritten rather than new material, control whether this session is being kept warm and checkpointed or left to lapse." -f `
    $S.grades.spend, $S.grades.churn, $S.grades.control, $S.spend_per_cycle, $S.churn_pct)
  $right.Children.Add($gbox) | Out-Null

  [Windows.Controls.Grid]::SetColumn($right, 5 + $co); $l3.Children.Add($right) | Out-Null
  $outer.Children.Add($l3) | Out-Null

  # --- line 4: what to do about THIS session, under its own numbers
  #
  # This used to be one line at the foot of the card, which meant the panel
  # could advise about exactly one session and the only way to read what it
  # thought of the others was to select them one at a time. The pane has always
  # put it under the row it belongs to; so does this now.
  #
  # The row grows to fit, and grows further again when d opens the detail below
  # it. That is the whole reason the list is capped and scrollable: rows are no
  # longer a fixed height, so the panel cannot be sized by counting them.
  # Only on the row you are looking at, or the one that is working. On eight
  # idle rows at once it stopped being advice and became wallpaper - and it is
  # the tallest thing on a row, so it was also most of the scrolling.
  if ($S.advice -and ($Selected -or $live)) {
    $l4 = New-Object Windows.Controls.Grid
    $l4.Margin = '20,6,4,1'
    foreach ($w in 'Auto', '*') {
      $cd = New-Object Windows.Controls.ColumnDefinition
      $cd.Width = if ($w -eq 'Auto') { [Windows.GridLength]::Auto } else { New-Object Windows.GridLength (1, 'Star') }
      $l4.ColumnDefinitions.Add($cd)
    }
    $ag = Text-Block ([string](Verdict-Glyph $S.verdict)) 8 (Verdict-Color $S.verdict)
    $ag.Margin = '0,2,7,0'; $ag.VerticalAlignment = 'Top'
    [Windows.Controls.Grid]::SetColumn($ag, 0); $l4.Children.Add($ag) | Out-Null
    # Urgent advice is worth reading; the rest is worth having. Same split the
    # foot line used to make, kept so a quiet machine does not shout on 8 rows.
    $at = Text-Block ([string]$S.advice) 9.5 `
            $(if ([int]$S.urank -ge 2) { $Pal.text } else { $Pal.dim }) 'Segoe UI'
    $at.TextWrapping = 'Wrap'; $at.LineHeight = 14
    if ($S.advice2) { Tip $at ([string]$S.advice2) }
    [Windows.Controls.Grid]::SetColumn($at, 1); $l4.Children.Add($at) | Out-Null
    $outer.Children.Add($l4) | Out-Null
  }

  # --- the detail lines, on d
  if ($Detail -and $Selected) {
    # The short id, evicted from the headline by the model and effort. It is
    # what r and e take, so it belongs where you are already looking to act.
    $d0 = Text-Block $S.short 9 $Pal.faint
    $d0.Margin = '20,7,0,0'
    $outer.Children.Add($d0) | Out-Null
    $d1 = Text-Block $S.title 9.5 $Pal.dim 'Segoe UI'
    $d1.TextWrapping = 'Wrap'; $d1.Margin = '20,3,0,0'
    $outer.Children.Add($d1) | Out-Null
    $d2 = Text-Block $S.cwd 9 $Pal.faint
    $d2.TextTrimming = 'CharacterEllipsis'; $d2.Margin = '20,2,0,0'
    $outer.Children.Add($d2) | Out-Null
    if ($S.advice2) {
      # The second half of the advice, which the line above only hints at on
      # hover. Detail is where there is room to print it outright.
      $d3 = Text-Block $S.advice2 9.5 $Pal.dim 'Segoe UI'
      $d3.TextWrapping = 'Wrap'; $d3.Margin = '20,5,4,0'
      $outer.Children.Add($d3) | Out-Null
    }
    # Subagents this window spawned. A Task subagent writes its own transcript
    # under <sid>/subagents/ rather than into the parent, so its spend is
    # invisible everywhere else - this is the one place it surfaces, and only
    # here, per the closed-row rule the advice line above already follows.
    if ($S.agents -and [int]$S.agents.n -gt 0) {
      foreach ($ag in @($S.agents.list)) {
        $arow = New-Object Windows.Controls.StackPanel
        $arow.Orientation = 'Horizontal'; $arow.Margin = '20,4,0,0'
        $running = ([int]$ag.running -eq 1)
        $aglyph = Text-Block ([string]$(if ($running) { [char]0x25CF } else { [char]0x25CB })) 8.5 `
                    $(if ($running) { $Pal.green } else { $Pal.faint })
        $aglyph.Margin = '0,0,5,0'
        $arow.Children.Add($aglyph) | Out-Null
        $adesc = [string]$ag.desc
        if ($adesc.Length -gt 42) { $adesc = $adesc.Substring(0, 41) + [char]0x2026 }
        $alabel = "{0}{1}" -f $ag.type, $(if ($adesc) { " - $adesc" } else { '' })
        $atxt = Text-Block $alabel 9 $Pal.dim 'Segoe UI'
        $arow.Children.Add($atxt) | Out-Null
        $ameta = Text-Block `
          ("  {0} - {1} req, {2}, {3}" -f $ag.model, $ag.requests, (Tok ([double]$ag.cost)), (Run-Str ([double]$ag.age_sec))) `
          8.5 $Pal.faint
        $arow.Children.Add($ameta) | Out-Null
        $outer.Children.Add($arow) | Out-Null
      }
      # Beside the row total, never folded into it: agent spend and window
      # spend are both true and adding them silently would make every
      # historical cost figure disagree with the one shown next to it.
      $asum = Text-Block `
        ("agents +{0} against {1} window - {2} combined" -f `
          (Tok ([double]$S.agents.cost)), (Tok ([double]$S.cost.total)), (Tok ([double]$S.cost.total + [double]$S.agents.cost))) `
        8.5 $Pal.faint
      $asum.Margin = '20,4,0,0'
      Tip $asum ("{0} spent across {1} agent(s) this session, reported beside the window total rather than folded into it" -f `
        (Tok ([double]$S.agents.cost)), [int]$S.agents.n)
      $outer.Children.Add($asum) | Out-Null
    }
  }
  # Everything the live repaint needs to find again, hung off the row it
  # belongs to. Draw-Rows adds idx and dim to this same table.
  $sel.Tag = @{
    rest = $rest; wash = $wash; colddim = $coldDim
    sid = [string]$S.sid; ctxk = [double]$S.context_k
    k = $k; clk = $clk; bar = $bar; alive = ([int]$S.alive -eq 1)
    # The elapsed clock and the two numbers it is computed from. Run-Tick owns
    # this text from here on - nothing else writes it between collects.
    run = $runT; runSince = $runSince; runState = $runState
    runPid = [int]$S.pid; runStat = ''
    runCol = (Run-Color $runSecs $runState); runTipAt = (Now-Epoch)
    # The spinner ring, so Run-Tick can recolour it the same tick it recolours
    # the text below it. $null on an idle row, where the icon is the verdict
    # glyph rather than a ring - Run-Tick checks before touching it.
    ring = $ring
    # The two baselines a live repaint measures against: the context at the end
    # of the last COMPLETED cycle, and the weighted cost as of that cycle.
    baseCtx = [double]$S.context; baseCost = [double]$S.cost.total
    grow = $gt; cost = $cost; gbud = $Gbud; spendbar = $sbar
  }
  $sel
}

# --- legend and keys ---------------------------------------------------------
# Written once: neither depends on the data. A readout whose symbols you have
# to remember is a readout you stop reading.
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
  # Interpolated, never concatenated. Inside an array literal both a [string]
  # cast and a + bind LOOSER than the comma, so `'a' + $x, $b, $c` is really
  # `'a' + ($x, $b, $c)` - one joined string where three elements were meant,
  # and the colour argument silently arrives as $null.
  $L.Children.Add((Legend-Line @(
    @("$([char]0x25B2) act now", $Pal.red, '0,0,10,0'),
    @("$([char]0x25B3) cut pays", $Pal.yellow, '0,0,10,0'),
    @("$([char]0x25CB) nothing to do", $Pal.green, '0,0,10,0'),
    @("$([char]0x25CC) working (it spins)", $Pal.dim, '0,0,10,0'),
    @('12m', $Pal.dim, '0,0,4,0'),
    @('how long the turn has run; yellow past 10m or waiting on you, orange past 30m', $Pal.faint)))) | Out-Null
  # The cache BAR has not been drawn since line 2 went back to context - it was
  # a picture of the number the clock already printed. What the legend has to
  # explain now is the icon that titles the clock pill.
  $L.Children.Add((Legend-Line @(
    @("$([char]0x23F1) 44m", $Pal.faint, '0,0,7,0'),
    @('the hour left on the prompt cache; hover it for what moves and ends it', $Pal.dim, '0,0,6,0'),
    @('20', $Pal.yellow, '0,0,4,0'),
    @('10', $Pal.orange, '0,0,4,0'),
    @('COLD', $Pal.red, '0,0,6,0'),
    @('act / act now / lapsed', $Pal.faint)))) | Out-Null
  $L.Children.Add((Legend-Line @(
    @('ctx gauge', $Pal.faint, '0,0,7,0'),
    @("% of $('{0:N0}k' -f $script:Bands.ctxmax), ticks at", $Pal.dim, '0,0,6,0'),
    @(('{0:N0}' -f $script:Bands.floor), $Pal.grey, '0,0,4,0'),
    @(('{0:N0}' -f $script:Bands.park_at), $Pal.yellow, '0,0,4,0'),
    @(('{0:N0}' -f $script:Bands.cut_pk), $Pal.orange, '0,0,4,0'),
    @(('{0:N0}k' -f $script:Bands.cut_no), $Pal.red, '0,0,6,0'),
    @('floor / park / cut', $Pal.faint)))) | Out-Null
  $L.Children.Add((Legend-Line @(
    @('spend gauge', $Pal.faint, '0,0,7,0'),
    @("what the window has cost, against every session on this machine; full scale $(Tok $script:SpendBands.full), ticks at", $Pal.dim, '0,0,6,0'),
    @((Tok $script:SpendBands.ok), $Pal.yellow, '0,0,4,0'),
    @((Tok $script:SpendBands.watch), $Pal.orange, '0,0,4,0'),
    @((Tok $script:SpendBands.heavy), $Pal.red)))) | Out-Null
  $L.Children.Add((Legend-Line @(
    @('cycles', $Pal.faint, '0,0,7,0'),
    @('how many turns this window has run,', $Pal.dim, '0,0,6,0'),
    @("+n$([char]0x21BB)", $Pal.blue, '0,0,6,0'),
    @('how many the tooling typed to hold it warm', $Pal.dim, '0,0,10,0'),
    @("+n = last growth vs $(Tok $script:Bands.gbud)/cycle", $Pal.dim)))) | Out-Null
  $L.Children.Add((Legend-Line @(
    @('heat', $Pal.faint, '0,0,7,0'),
    @('rent per cycle vs work; 1.0x is the bar', $Pal.dim, '0,0,6,0'),
    @('0.7', $Pal.yellow, '0,0,4,0'),
    @('1.0', $Pal.orange, '0,0,4,0'),
    @('1.5x', $Pal.red)))) | Out-Null
  $L.Children.Add((Legend-Line @(
    @('5h 7d', $Pal.faint, '0,0,7,0'),
    @('plan used per account, then when that window resets,', $Pal.dim, '0,0,6,0'),
    @("$([char]0x25CF) the one in use", $Pal.blue, '0,0,8,0'),
    @("$([char]0x25B2) ahead of pace", $Pal.orange)))) | Out-Null
  $L.Children.Add((Legend-Line @(
    @("$([char]0x21BB)$([char]0x21BB)", $Pal.blue, '0,0,7,0'),
    @('extension marks - blue is a ticket in hand, faint is one spent and cannot be removed', $Pal.dim)))) | Out-Null
  $L.Children.Add((Legend-Line @(
    @('PARKED', $Pal.blue, '0,0,8,0'),
    @('a checkpoint on disk', $Pal.faint, '0,0,10,0'),
    @('B', $Pal.red, '0,0,6,0'),
    @('refusing every prompt - u lifts it', $Pal.faint, '0,0,10,0'),
    @('A-E spend / churn / control', $Pal.faint)))) | Out-Null
  # The leading comma is load-bearing: @( @(one, thing) ) unrolls to the inner
  # array, so a one-part line arrives as its own parts and the colour lands in
  # $p[0]. Same trap the note at the top of this function describes.
  $L.Children.Add((Legend-Line @(, @('hover anything - the line below says what it is', $Pal.faint)))) | Out-Null
}

# The same vocabulary the pane uses, so a key you already know works here. The
# table is the source for both this overlay and the handler below, which is why
# a key cannot end up working while being documented nowhere.
# Filter and sort used to be here and are not any more. They are questions
# about a list long enough to need narrowing, which is the pane's job and the
# analytics tab's; four rows in a corner want a scrollbar, not a query.
$KEYMAP = @(
  @('j k', 'move the selection'),      @('1-9', 'select that row'),
  @('d',   'detail on the selected row'),
  @('n',   'name the selected row'),   @('e E', 'add / remove an extension mark'),
  @('u',   'lift the input block'),
  @('c',   'minimise to the live one'),
  @('y',   'copy a resume command'),
  @('o',   'open the working directory'),
  @('w',   'switch account (twice)'), @('v', 'the parked panel'),
  @('f',   'fold the footer'),          @('r',   'collect now'),
  @('p',   'pin / unpin on top'),      @('l',   'the legend'),
  @('+ -', 'zoom, or wheel the corner'),
  @('drag corner', 'width and list height'), @('0', 'reset size and zoom'),
  @('?',   'this list'),               @('esc', 'hide to the tray'),
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
      $kk.MinWidth = 26; $kk.Margin = '0,0,7,0'
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
$script:Left = $Every
$script:LastWarn = @{}
# Sessions this widget has already asked to be blocked. See the arming pass.
$script:Armed = @{}
# How close to the lapse the block arms. Two minutes: late enough that the
# session has had every chance to spend a mark it does not have, early enough
# that the checkpoint is written while the window is still warm and /park is
# still a 0.1x read rather than the rewrite it is trying to avoid.
$script:BlockAt = [int]$(if ($env:TOKEN_BLOCK_AT) { $env:TOKEN_BLOCK_AT } else { 2 })
$script:Bands = $null
$script:Sel = 0            # 1-based into the visible rows; 0 is no selection
$script:Visible = @()
$script:PrevCtx = @{}      # sid -> the context the bar last drew, for the slide

# Plan usage only ever goes UP inside a window - the API has no mechanism to
# hand tokens back. So a poll that reports LESS than the last one did, with no
# reset in between, is not real usage falling; it is a bad or partial read from
# whichever layer produced it (cswap, the live merge, or a JSON caught mid
# write). Trusting it anyway is what turned one glitched poll into the bar
# sliding to that reading and SITTING there: the lerp only knows how to ease
# toward whatever target it is handed, and a wrong target is animated to and
# held just as faithfully as a right one, for as long as the bad reading
# stands - up to a full $Every between collects. This is the guard: hold the
# last good percentage across a drop, and only ever accept a lower one when the
# countdown says the window actually turned over.
$script:AcctLastPct = @{}
$script:AcctLastMin = @{}
# "4h 34m" / "2d 12h" -> minutes, so a reset (countdown jumping back up) can be
# told apart from ordinary ticking-down without needing the raw reset epoch,
# which never leaves the shell side.
function Countdown-Mins([string]$s) {
  if (-not $s) { return -1 }
  $d = 0; $h = 0; $m = 0
  if ($s -match '(\d+)\s*d') { $d = [int]$Matches[1] }
  if ($s -match '(\d+)\s*h') { $h = [int]$Matches[1] }
  if ($s -match '(\d+)\s*m') { $m = [int]$Matches[1] }
  return $d * 1440 + $h * 60 + $m
}
# Returns the percentage to actually draw: $pct as given, unless it is an
# implausible mid-window dip, in which case the last good reading is repeated.
function Guard-Pct([string]$key, [double]$pct, [string]$cdStr) {
  $mins = Countdown-Mins $cdStr
  $prevPct = if ($script:AcctLastPct.ContainsKey($key)) { [double]$script:AcctLastPct[$key] } else { -1 }
  $prevMin = if ($script:AcctLastMin.ContainsKey($key)) { [int]$script:AcctLastMin[$key] } else { -1 }
  # The guard may only hold a dip while it can PROVE the window did not turn
  # over, and the only proof is a clock that was running last poll, is running
  # now, and has ticked down - +2m of slack for a poll landing on the boundary.
  #
  # Absence of a clock is not that proof, and reading it as such is what froze
  # the account you are not signed into. cswap reports a countdown only once a
  # window has usage in it, so a window that resets untouched comes back as
  # 0% with countdown null - the row's own 'idle' tail is drawn off exactly
  # that. The old test asked only "did the countdown jump UP", which a null
  # countdown never does, so the drop to 0% was rejected and the bar sat at
  # the percentage the account had reached before its reset, indefinitely:
  # a row reading 'idle' beside a used bar, with the number the one thing on
  # it that never moved.
  $running = ($mins -ge 0 -and $prevMin -ge 0 -and $mins -le $prevMin + 2)
  $out = $pct
  if ($running -and $prevPct -ge 0 -and $pct -lt $prevPct - 0.5) {
    $out = $prevPct
  } else {
    $script:AcctLastPct[$key] = $pct
  }
  # Recorded even when it is -1, so the clock STOPPING is a state change the
  # next poll can see. Skipping the write was the other half of the freeze:
  # $prevMin kept the last running value for ever, and every later poll was
  # judged against a clock that had not existed for hours.
  $script:AcctLastMin[$key] = $mins
  $out
}

# Numbers that move instead of jumping. A poll can land a large step - a cycle
# closing and folding the live half into the hook totals, a session appearing -
# and a figure that snaps reads as a glitch rather than as news. Each registered
# TextBlock eases toward its target on a 33ms timer, and the value it is
# currently SHOWING is keyed by session rather than by element, so rebuilding
# every row on the next poll continues the slide instead of restarting it.
#
# Entries are dropped 60s after they were last re-registered, which is what
# retires a session that has gone: a visible row re-registers on every poll.
$script:Lerp = @{}
# What this key was showing last time it was drawn. Rows and footer cells are
# REBUILT on every collect rather than updated in place, so an element has no
# memory of its own former value - without one, every bar would snap into place
# on each refresh and the animation would only ever be seen by the three cells
# that happened to have a live repaint path. Keyed by sid (or by whatever names
# the cell), so it survives the rebuild the element does not.
$script:Prev = @{}
function Prev-Val([string]$key, [double]$target) {
  $p = $target
  if ($script:Prev.ContainsKey($key)) { $p = [double]$script:Prev[$key] }
  $script:Prev[$key] = $target
  return $p
}

# Lerp-Num moves a NUMBER; this moves anything else - a column's star weight, a
# bar's width - by handing the interpolated value to a scriptblock each frame.
# One mechanism for both, because two would drift out of step and the whole
# point is that a card settles as one movement rather than six.
function Lerp-Do([string]$key, [double]$target, [scriptblock]$apply, [double]$from = [double]::NaN) {
  $cur = $target
  if (-not [double]::IsNaN($from)) { $cur = $from }
  elseif ($script:Lerp.ContainsKey($key)) { $cur = [double]$script:Lerp[$key].cur }
  $script:Lerp[$key] = @{ cur = $cur; target = $target; elem = $null
                          fmt = $null; apply = $apply; ts = [datetime]::UtcNow }
  & $apply $cur
}

function Lerp-Num([string]$key, $elem, [double]$target, [scriptblock]$fmt) {
  $cur = $target
  if ($script:Lerp.ContainsKey($key)) { $cur = [double]$script:Lerp[$key].cur }
  $script:Lerp[$key] = @{ cur = $cur; target = $target; elem = $elem
                          fmt = $fmt; apply = $null; ts = [datetime]::UtcNow }
  $elem.Text = (& $fmt $cur)
  $elem
}
# One writer for both kinds of entry, so the snap-to-target path and the moving
# path can never disagree about how a value is applied.
function Lerp-Set($e) {
  if ($e.apply) { & $e.apply ([double]$e.cur) } else { $e.elem.Text = (& $e.fmt ([double]$e.cur)) }
}
$script:LerpTimer = New-Object Windows.Threading.DispatcherTimer
$script:LerpTimer.Interval = [TimeSpan]::FromMilliseconds(33)
$script:LerpTimer.Add_Tick({
  $drop = @()
  foreach ($k in @($script:Lerp.Keys)) {
    $e = $script:Lerp[$k]
    if (([datetime]::UtcNow - $e.ts).TotalSeconds -gt 60) { $drop += $k; continue }
    $d = [double]$e.target - [double]$e.cur
    # Close enough to land: snap, so a value never sits a rounding error short
    # of the truth for the rest of its life.
    if ([math]::Abs($d) -lt 0.0005) {
      if ([double]$e.cur -ne [double]$e.target) {
        $e.cur = [double]$e.target
        try { Lerp-Set $e } catch { $drop += $k } }
      continue }
    # 0.32 rather than 0.22: these are short on purpose. A bar that takes a full
    # second to settle is still moving when your eye has already read it, and
    # with every cell on the card animating at once that reads as the panel
    # being slow rather than as anything arriving.
    $e.cur = [double]$e.cur + $d * 0.32
    try { Lerp-Set $e } catch { $drop += $k }
  }
  foreach ($k in $drop) { $script:Lerp.Remove($k) }
})
$script:LerpTimer.Start()
$script:Flash = ''
$script:Hover = ''         # what the pointer is over, for the message line
$script:Naming = ''        # the sid the name box is open on
$script:AlertSeen = 'ok'   # the level the balloon last rang for
$script:SwitchArm = 0      # w pressed once; a second press inside the window commits
$script:SwitchWindow = 5   # widened when the first press has a cost to report

# The collect, off the dispatcher. It costs 5.4 seconds here - 7.2 with --all -
# and nearly all of that is Git Bash spawning processes, so there is nothing to
# make faster; it just must not happen on the thread that draws.
#
# One at a time, and never awaited. The tick below asks whether the last one has
# landed; until it does the panel keeps drawing the snapshot it already has,
# which is what makes j and k answer instantly instead of whenever bash is
# finished.
$script:CollectPS = $null
$script:CollectHandle = $null
$script:Collecting = $false
# When the current collect started, so the footer can say how long it has been
# rather than only that it is happening. A collect is meant to take seconds; on
# a machine where process creation has gone slow it can take minutes, and a
# countdown that just says "collecting..." for three of them is indistinguishable
# from one that has hung. See the note on Start-Collect.
$script:CollectAt = [datetime]::MinValue

# Live windows only. A closed session is a question about the past, and the
# past is the dashboard's job; this is a corner readout of what is costing
# something right now. Asking for none of them is the collector's own default,
# so there is no flag here: the absence of --closed-count IS the request, and
# it is also the cheapest collect there is.
function Collect-Cmd {
  $sh = ($Script -replace '\\', '/') -replace '^C:', '/c'
  "'$sh' --json --no-update-check 2>/dev/null"
}

# Synchronous, and used only by -SelfTest, which has no dispatcher to block.
function Get-Data {
  try {
    $raw = & $Bash -lc (Collect-Cmd)
    if (-not $raw) { return $null }
    return ($raw -join "`n") | ConvertFrom-Json
  } catch { return $null }
}

# The small writes behind a keystroke. Nothing on screen waits for these: the
# file is the record, but the panel has already been told the answer, and a key
# that takes a second to land is a key you press twice.
#
# Handles are kept only so the runspaces can be disposed once they finish -
# without that, every keypress leaks one for the life of the widget.
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

# The path token-sessions.sh answers to from inside Git Bash.
function Script-Sh { ($Script -replace '\\', '/') -replace '^C:', '/c' }

# One collect at a time. A second request arriving mid-flight is dropped: every
# collect asks for the same thing now that there are no pages, so the one
# already running is the one the caller wanted.
function Start-Collect {
  if ($script:CollectPS) { return }
  # Hourly, folded into a collect that is already happening. Defined further
  # down and throttled inside itself, so this call is a timestamp comparison
  # every refresh and a Get-ScheduledTask once an hour.
  if (-not $SelfTest) { Ensure-PokeDue }
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

# Called once a second. Cheap when nothing has landed - one IsCompleted read.
function Poll-Collect {
  if (-not $script:CollectPS) { return }
  if (-not $script:CollectHandle.IsCompleted) { return }
  $ok = $false
  try {
    $txt = ($script:CollectPS.EndInvoke($script:CollectHandle) | Out-String)
    if ($txt.Trim()) {
      $d = $txt | ConvertFrom-Json
      if ($d) {
        $script:Data = $d
        $ok = $true
      }
    }
  } catch { }
  try { $script:CollectPS.Dispose() } catch { }
  $script:CollectPS = $null; $script:CollectHandle = $null; $script:Collecting = $false
  if ($ok) { Update-View -Redraw }
}

# Snapshot order, which is warm-soonest first - the order in which the rows
# will actually cost you something. Nothing re-orders or narrows it here: the
# list scrolls now, so length is no longer a reason to filter it, and a widget
# that sorts differently from the pane is two tools disagreeing about which
# session is the urgent one.
function Get-Visible {
  # Live windows only, always. The filter is belt to the collector's braces -
  # --live-only is what actually keeps closed sessions off the wire - and it
  # also covers the case where a window exits between one collect and the next
  # and its row would otherwise sit there as a corpse until the refresh.
  #
  # Compact used to mean ONE row - the live session and nothing else - which
  # answered "what am I doing now" and nothing about the machine. Every window
  # is still here; each is drawn two lines high instead of three. What compact
  # buys is height, not information: the bar is the part a glance can do
  # without, since the size it pictures is printed on the same line.
  , @(@($script:Data.sessions) | Where-Object { $_.alive -eq 1 })
}

# What the panel is before it knows anything.
#
# A collect is seven to seventeen seconds on this machine - three live windows
# each want a transcript probe, and that is real work, not overhead. Until now
# those seconds were spent looking at an empty card with an empty scorecard
# above it, which is indistinguishable from a widget that has crashed on
# startup. The card is the same card; it just says what it is doing.
#
# The scorecard and its rule are hidden rather than left blank, because a 7d
# panel with no numbers in it reads as "you spent nothing this week".
function Show-Loading {
  $el.Rows.Children.Clear()
  $el.Score.Visibility = 'Collapsed'
  $el.ScoreRule.Visibility = 'Collapsed'
  $el.Dot.Foreground = (Br $Pal.faint)

  $sp = New-Object Windows.Controls.StackPanel
  $sp.Margin = '14,26,14,26'
  $sp.HorizontalAlignment = 'Center'

  # The same spinner a running row wears. It is the one thing on screen that
  # proves the process is alive rather than wedged, which is the entire job
  # of this view.
  $sw = New-Object Windows.Controls.StackPanel
  $sw.Orientation = 'Horizontal'; $sw.HorizontalAlignment = 'Center'
  $spin = New-Object Windows.Controls.Grid
  $spin.Width = 13; $spin.Height = 13; $spin.Margin = '0,1,8,0'
  $spin.Children.Add((New-Spinner $Pal.blue)) | Out-Null
  $sw.Children.Add($spin) | Out-Null
  $t1 = Text-Block 'reading sessions' 11 $Pal.text 'Segoe UI'
  $t1.VerticalAlignment = 'Center'
  $sw.Children.Add($t1) | Out-Null
  $sp.Children.Add($sw) | Out-Null

  # Says why it is not instant, so the wait reads as work rather than as a
  # hang. Naming the number is the point: a person who knows it takes about
  # ten seconds does not start wondering at four.
  $t2 = Text-Block 'a live window has to be measured from its transcript, which takes a few seconds each' 9 $Pal.faint 'Segoe UI'
  $t2.TextWrapping = 'Wrap'; $t2.TextAlignment = 'Center'
  $t2.Margin = '0,9,0,0'; $t2.MaxWidth = 300
  $sp.Children.Add($t2) | Out-Null

  $el.Rows.Children.Add($sp) | Out-Null
  # Built here as well as in Update-View: the footer is on screen during the
  # wait, and an empty legend under a loading panel looks like a second thing
  # that has failed to load.
  if ($el.Legend.Children.Count -eq 0) { Build-Legend; Build-Keys }
}

function Draw-Rows {
  $el.Rows.Children.Clear()
  $script:Visible = Get-Visible
  $n = $script:Visible.Count
  if ($script:Sel -gt $n) { $script:Sel = $n }
  if ($n -eq 0) {
    $t = Text-Block 'no live sessions' 10 $Pal.faint
    $t.Margin = '14,6,14,6'
    $el.Rows.Children.Add($t) | Out-Null
    return
  }
  # With nothing picked every row is equal and none is dimmed. It is only once
  # you have chosen one that the others become context.
  $anySel = ($script:Sel -gt 0 -and $script:Sel -le $n)
  for ($i = 0; $i -lt $n; $i++) {
    $s = $script:Visible[$i]
    $from = -1.0
    if ($script:PrevCtx.ContainsKey($s.sid)) { $from = [double]$script:PrevCtx[$s.sid] }
    $isSel = ($script:Sel -eq $i + 1)
    $row = New-Row $s $script:Bands $script:Bands.gbud $isSel `
                   $script:View.detail $from ($anySel -and -not $isSel)
    # Click selects, and clicking the selected row again lets it go - the mouse
    # spelling of pressing the same digit twice.
    $row.Tag.idx = $i + 1
    $row.Tag.dim = ($anySel -and -not $isSel)
    $row.Add_MouseLeftButtonUp({
      param($sender, $e)
      $ix = [int]$sender.Tag.idx
      $script:Sel = $(if ($script:Sel -eq $ix) { 0 } else { $ix })
      $e.Handled = $true; Update-View -Redraw })
    $el.Rows.Children.Add($row) | Out-Null
    $script:PrevCtx[$s.sid] = [double]$s.context_k
  }
  # The list scrolls, so a selection can be off-screen - j past the bottom has
  # to bring the row to you rather than silently select something you cannot
  # see. Layout first: a row added this instant has no position yet.
  if ($script:Sel -gt 0 -and $script:Sel -le $el.Rows.Children.Count) {
    $el.Rows.UpdateLayout()
    $el.Rows.Children[$script:Sel - 1].BringIntoView()
  }
}

# Repaint the two numbers that actually move while you watch, from the status
# line payload rather than from a collect. Everything else on a row - cycles,
# grades, cost, growth - is a per-CYCLE quantity and does not change until a
# cycle ends, so there is nothing live about it to show.
#
# Gated on the file's mtime, so a row whose session is idle costs one stat a
# second and nothing else.
$script:LiveSeen = @{}
function Live-Tick {
  if (-not $script:Bands) { return }
  $dir = Join-Path $Root 'session-usage'
  if (-not (Test-Path $dir)) { return }
  $now = [int][double]::Parse((Get-Date -Date (Get-Date).ToUniversalTime() -UFormat %s))
  foreach ($row in $el.Rows.Children) {
    $t = $row.Tag
    if (-not $t -or -not $t.sid -or -not $t.alive) { continue }
    $f = Join-Path $dir ($t.sid + '.json')
    if (-not (Test-Path $f)) { continue }
    try { $mt = (Get-Item $f).LastWriteTimeUtc.Ticks } catch { continue }
    if ($script:LiveSeen[$t.sid] -eq $mt) { continue }
    $script:LiveSeen[$t.sid] = $mt
    try { $p = (Get-Content $f -Raw -ErrorAction Stop) | ConvertFrom-Json } catch { continue }
    if (-not $p.context_window) { continue }

    $ck = [double]$p.context_window.total_input_tokens / 1000.0
    if ([math]::Abs($ck - [double]$t.ctxk) -gt 0.05) {
      $col = Band-Color $ck $script:Bands
      $t.k.Text = '{0:N1}k' -f $ck
      $t.k.Foreground = (Br $col)
      if ($t.bar -and $t.bar.Tag) {
        $to = [math]::Min(1.0, $ck / $script:Bands.ctxmax)
        $t.bar.Tag.fill.Background = (Br $col)
        Animate -Target $t.bar.Tag.scale `
                -Property ([Windows.Media.ScaleTransform]::ScaleXProperty) `
                -From $t.bar.Tag.frac -To $to -Seconds 0.6
        $t.bar.Tag.frac = $to
        # The lit mark is defined as "the next threshold ahead of the fill", so
        # it has to move when the fill does. The payload nudges the fill several
        # times between collects; without this the weighting would only ever be
        # as fresh as the last snapshot, and the one tick that means anything
        # would stay lit on a band you had already crossed.
        if ($t.bar.Tag.ticks) {
          $nk = [double]::MaxValue
          foreach ($tk in $t.bar.Tag.ticks) {
            if ($tk.k -gt $ck -and $tk.k -lt $nk) { $nk = $tk.k } }
          foreach ($tk in $t.bar.Tag.ticks) {
            if ($tk.wall) { continue }
            $tk.el.Opacity = if ($tk.k -eq $nk) { 1.0 }
                             elseif ($tk.k -le $ck) { 0.28 } else { 0.6 }
            $tk.el.Width   = if ($tk.k -eq $nk) { 2 } else { 1 } }
        }
      }
      $t.ctxk = $ck
    }

    # Growth, in flight. The snapshot can only report a cycle once it has
    # ended; the payload says how big the window is right now, so the growth of
    # the cycle you are in the middle of is just the difference.
    if ($t.grow -and $t.gbud -gt 0) {
      $g = ($ck * 1000.0) - [double]$t.baseCtx
      if ($g -gt 0) {
        $t.grow.Text = '  +{0}' -f (Tok $g)
        $t.grow.Foreground = (Br (Growth-Color ($g / [double]$t.gbud)))
      }
    }

    # Cost, live. total_cost_usd is cumulative and authoritative - Claude Code's
    # own billing - so it converts straight into the input-equivalents the rest
    # of this panel counts in: usd / price-per-input-token.
    #
    # Worth knowing that it does NOT agree with the snapshot: measured $31.08
    # here against the per-cycle model's $10.66. The model counts one recache
    # per cycle; billing counts every request's cache_creation, and a cycle with
    # thirty tool calls has thirty of them. The live number is the true one.
    if ($t.cost -and $p.cost -and $script:PriceIn -gt 0) {
      $usd = [double]$p.cost.total_cost_usd
      if ($usd -gt 0) {
        $wt = $usd / $script:PriceIn * 1e6
        $t.cost.Text = Tok $wt
        # The gauge beside it, moved by the same figure. A bar that only ever
        # steps once a collect, while the number above it moves every few
        # seconds, reads as two different measurements of the same thing.
        if ($t.spendbar) { Set-SpendBar $t.spendbar $wt }
        Tip $t.cost ("{0} weighted, live from this session's own billing (\${1:N2}). The per-cycle model says {2} - it counts one recache per cycle where billing counts every request." -f `
                     (Tok $wt), $usd, (Tok ([double]$t.baseCost)))
      }
    }

    # The cache clock, stated rather than inferred. The snapshot works it out
    # from the last transcript timestamp plus the TTL; the payload just says
    # when it expires, and says so again every few seconds.
    if ($p.prompt_cache -and $p.prompt_cache.expires_at) {
      $m = [math]::Floor(([double]$p.prompt_cache.expires_at - $now) / 60)
      if ($m -le 0) {
        if ($t.clk.Text -ne 'COLD') {
          $t.clk.Text = 'COLD'; $t.clk.Foreground = (Br $Pal.red); $t.clk.FontWeight = 'Bold'
        }
      } else {
        $t.clk.Text = '{0}m' -f $m
        $t.clk.FontWeight = 'Normal'
        $t.clk.Foreground = (Br $(if ($m -le 10) { $Pal.orange }
                                  elseif ($m -le 20) { $Pal.yellow } else { $Pal.dim }))
      }
    }
  }
}


# The elapsed clock, re-read every second off the Tag rather than off disk. The
# payload only changes on a collect (once a minute), so a clock driven by the
# payload would jump a minute at a time; this one counts on its own from the
# turn's start and is only ever CORRECTED by a collect.
function Run-Tick {
  if (-not $el -or -not $el.Rows) { return }
  $now = Now-Epoch
  $sdir = Join-Path $Root 'sessions'
  foreach ($row in $el.Rows.Children) {
    $t = $row.Tag
    if (-not $t -or -not $t.ContainsKey('run') -or -not $t.run) { continue }
    # The CLI rewrites sessions/<pid>.json on every state transition, so this is
    # the turn starting and ending in real time rather than up to a minute after
    # the fact. It is also the only way the clock can VANISH promptly: a collect
    # is a minute apart, and a timer that keeps counting for fifty seconds after
    # the turn ended is worse than no timer, because it is confidently wrong.
    #
    # Nothing here is a heuristic: `status` is the CLI's own flag. An
    # unrecognised value means doing something, never idle - so only the two
    # states that are explicitly NOT work stop the clock.
    if ([int]$t.runPid -gt 0) {
      $sf = Join-Path $sdir ("{0}.json" -f [int]$t.runPid)
      if (Test-Path $sf) {
        try {
          $sj = (Get-Content $sf -Raw -ErrorAction Stop) | ConvertFrom-Json
          $st = [string]$sj.status
          if ($st -and $st -ne $t.runStat) {
            $t.runStat = $st
            $t.runState = $(if ($st -eq 'idle' -or $st -eq 'waiting') { 0 } else { 1 })
            if ($sj.statusUpdatedAt) { $t.runSince = [math]::Floor([double]$sj.statusUpdatedAt / 1000) }
          }
        } catch { }
      }
    }
    if ([int]$t.runState -ne 1 -or [double]$t.runSince -le 0) {
      if ($t.run.Visibility -ne 'Collapsed') { $t.run.Text = ''; $t.run.Visibility = 'Collapsed' }
      continue
    }
    if ($t.run.Visibility -ne 'Visible') { $t.run.Visibility = 'Visible' }
    $secs = [math]::Max(0.0, $now - [double]$t.runSince)
    $txt = Run-Str $secs
    if ($t.run.Text -ne $txt) { $t.run.Text = $txt }
    # Brush and tooltip only when they would actually differ. The text moves
    # every second under a minute; the colour moves four times in a turn's whole
    # life and the tooltip says the same sentence with a different number in it.
    # Rebuilding both once a second, on every row, for a panel that is usually
    # not even being looked at, is the kind of cost that is invisible until the
    # machine is busy - which is exactly when a turn is running.
    $col = Run-Color $secs ([int]$t.runState)
    if ($t.runCol -ne $col) {
      $t.run.Foreground = (Br $col); $t.runCol = $col
      # The spinner rides the same escalation (yellow past 10m, orange past
      # 30m) but keeps its own green at rest rather than the text's dim - see
      # Spin-Color. $null on a row whose icon is still the idle glyph from the
      # last full redraw; Run-Tick does not swap icons, only recolour them.
      if ($t.ring) { $t.ring.Stroke = (Br (Spin-Color $secs ([int]$t.runState))) }
    }
    if ($now - [double]$t.runTipAt -ge 15) {
      Tip $t.run (Run-Tip $secs ([int]$t.runState))
      $t.runTipAt = $now
    }
  }
}

function Apply-Chrome {
  # What compact actually means: the one row, and none of the furniture around
  # it. The header stays because the clock and the state dot are the point.
  $full = -not $script:View.compact
  $el.Score.Visibility     = if ($full) { 'Visible' } else { 'Collapsed' }
  $el.ScoreRule.Visibility = if ($full) { 'Visible' } else { 'Collapsed' }
  Show-Message
  # The footer folds as one block - the fold chevron owns whether it is there
  # at all, and l / ? only choose which of the two things it holds.
  $open = ($full -and $script:View.foot)
  $el.FootBody.Visibility = if ($open) { 'Visible' } else { 'Collapsed' }
  $el.FootRule.Visibility = if ($open) { 'Visible' } else { 'Collapsed' }
  $el.Legend.Visibility = if ($script:View.keys) { 'Collapsed' } else { 'Visible' }
  $el.Keys.Visibility   = if ($script:View.keys) { 'Visible' } else { 'Collapsed' }
  $el.Fold.Text = if ($open) { [string][char]0x25BE } else { [string][char]0x25B8 }
  $el.Fold.ToolTip = if ($open) { 'f - fold the footer away' } else { 'f - unfold the footer' }
  $el.Min.Text = if ($full) { [string][char]0x2013 } else { [string][char]0x25A1 }
  $el.Min.ToolTip = if ($full) { 'c - compact rows (two lines each)' } else { 'c - back to full rows' }
  $el.Pin.Opacity = if ($script:View.pinned) { 1.0 } else { 0.25 }
  $el.Pin.ToolTip = if ($script:View.pinned) { 'p - unpin from the top' } else { 'p - pin on top' }
  $el.LegendToggle.Foreground = (Br $(if ($open -and -not $script:View.keys) { $Pal.dim } else { $Pal.faint }))
  $el.KeysToggle.Foreground = (Br $(if ($open -and $script:View.keys) { $Pal.blue } else { $Pal.faint }))
  $win.Topmost = $script:View.pinned
}

# Draw what is in hand. It never goes to disk any more - Poll-Collect owns
# that - so every caller of this is free, and the -Redraw switch is kept only so
# the dozens of existing call sites still read correctly.
function Update-View {
  param([switch]$Redraw)
  $d = $script:Data
  if (-not $d) { Show-Loading; return }
  # Data has landed at least once, so whatever the loading view hid comes back.
  # Idempotent and cheap - two enum writes on a property that is already right.
  $el.Score.Visibility = 'Visible'
  $el.ScoreRule.Visibility = 'Visible'
  $cn = $d.constants
  # One object carrying everything a bar needs to place itself, so no drawing
  # function has to reach back into the whole payload.
  # Dollars per input token, for turning the payload's cumulative USD into the
  # weighted input-equivalents everything else is counted in.
  $script:PriceIn = [double]$cn.price_in
  $script:Bands = [pscustomobject]@{
    floor = $cn.floor; park_at = $cn.park_at; overheat = $cn.overheat
    cut_pk = $cn.cut_pk; cut_no = $cn.cut_no; ctxmax = $cn.ctxmax; gbud = $cn.gbud
  }
  if ($el.Legend.Children.Count -eq 0) { Build-Legend; Build-Keys }

  $el.Clock.Text = (Get-Date -Format 'HH:mm')
  $bits = @()
  if (-not $script:View.bell) { $bits += 'muted' }
  $el.Title.Text = if ($bits.Count) { "TOKEN  $($bits -join '  ')" } else { 'TOKEN SESSIONS' }

  $el.Grades.Children.Clear()
  foreach ($g in @(@('spend', $d.overall.grades.spend, $d.overall.prev_grades.spend),
                   @('churn', $d.overall.grades.churn, $d.overall.prev_grades.churn),
                   @('ctl',   $d.overall.grades.control, $d.overall.prev_grades.control))) {
    $sp = New-Object Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'; $sp.Margin = '0,0,12,0'
    $lab = Text-Block $g[0] 10 $Pal.faint; $lab.Margin = '0,2,4,0'
    $sp.Children.Add($lab) | Out-Null
    $gr = Text-Block $(if ($g[1]) { $g[1] } else { '-' }) 11 (Grade-Color $g[1])
    $gr.FontWeight = 'Bold'
    $sp.Children.Add($gr) | Out-Null
    # An arrow only where the week actually moved. A letter that has not changed
    # is not news, and a permanent arrow reads as one.
    if ($g[2] -and $g[1] -and $g[2] -ne $g[1]) {
      $up = $g[1] -lt $g[2]          # A is better than B
      $ar = Text-Block $(if ($up) { [char]0x2191 } else { [char]0x2193 }) 9 `
                       $(if ($up) { $Pal.green } else { $Pal.red })
      $ar.Margin = '2,2,0,0'
      Tip $ar "was $($g[2]) the week before"
      $sp.Children.Add($ar) | Out-Null
    }
    $el.Grades.Children.Add($sp) | Out-Null
  }

  $sp7 = [double]$d.overall.spend_7d * 1000
  $el.Spend.Text = (Tok $sp7)
  Tip $el.Spend "7 days weighted; 5h window $(Tok ([double]$d.overall.spend_5h * 1000))"

  # The week's split, not the live sessions' - this block is under a "7d"
  # heading and has to mean the same thing the grades above it do.
  $to = [double]$d.overall.split_7d.output
  $tw = [double]$d.overall.split_7d.cache_write
  $tr = [double]$d.overall.split_7d.cache_read
  $tt = $to + $tw + $tr; if ($tt -le 0) { $tt = 1 }
  Fill-Split -Grid $el.SplitBar -Out ($to * 100 / $tt) -Write ($tw * 100 / $tt) -Read ($tr * 100 / $tt) `
             -OutTok $to -WriteTok $tw -ReadTok $tr -Key 'footer'
  $el.SplitKey.Text = ('out {0:N0}%   write {1:N0}%   read {2:N0}%' -f `
                       ($to * 100 / $tt), ($tw * 100 / $tt), ($tr * 100 / $tt))
  Tip $el.SplitKey ("output {0} / cache write {1} / cache read {2}" -f (Tok $to), (Tok $tw), (Tok $tr))
  $el.Wpc.Text = "$(Tok ([double]$d.overall.wpc * 1000))/cycle"
  Tip $el.Wpc "this machine's median is $(Tok ([double]$d.overall.median.wpc * 1000))/cycle"

  # What is left to spend, one row per managed account. Every other number in
  # this panel is about what a WINDOW costs; this is the only one about what is
  # left to spend it with - and the account you are NOT signed into belongs here
  # just as much, because a five-hour window at 90% stops being a problem the
  # moment you can see a second account sitting at zero.
  #
  # cswap is the source when it is installed - it polls every account on a timer
  # of its own, so these keep moving with no session open. Without it the status
  # line payload covers the active account alone, and the row says so.
  $el.Limits.Children.Clear()
  $lm = $d.limits
  $accts = @()
  if ($lm) { $accts = @($lm.accounts | Where-Object { [double]$_.five_hour_pct -ge 0 }) }
  # The one in use first, then the rest by number: the active account is what
  # you are spending and the others are the answer to it running out.
  $accts = @($accts | Sort-Object -Property @{ E = { -[int]$_.active } }, @{ E = { [int]$_.n } })
  # A header, because this block reads as a continuation of the session rows
  # above it otherwise - same width, same type, and two more percentages. These
  # percentages answer a different question: not "what is this window costing"
  # but "how much plan is left to spend it with". Naming the source matters too,
  # since cswap sees every account and the status line only sees the one in use.
  if ($accts.Count) {
    $hd = New-Object Windows.Controls.StackPanel
    $hd.Orientation = 'Horizontal'; $hd.Margin = '0,2,0,4'
    # Every figure in this panel is used_percentage, and the bars fill with it.
    # The header said LEFT, which inverted the reading of every row under it:
    # 62% against a 62%-full bar is comfortable if the number is used and nearly
    # spent if it is left. The tooltips have always said both.
    $ht = Text-Block 'PLAN USED' 8 $Pal.faint
    $ht.VerticalAlignment = 'Center'
    $hd.Children.Add($ht) | Out-Null
    $hs = Text-Block $(if ([string]$lm.source -eq 'cswap') { '  all accounts' } else { '  this account only' }) 8 $Pal.faint
    $hs.Opacity = 0.7; $hs.VerticalAlignment = 'Center'
    $hd.Children.Add($hs) | Out-Null
    Tip $hd $(if ([string]$lm.source -eq 'cswap') {
      'plan headroom per account, polled by cswap on its own timer - including the accounts you are not signed into' }
      else { 'plan headroom from the status line, which only ever describes the account in use and only refreshes while a session is open' })
    $el.Limits.Children.Add($hd) | Out-Null
  }
  foreach ($a in $accts) {
    $on = ([int]$a.active -eq 1)
    $stale = ([int]$a.age_sec -gt 1800 -or [string]$a.status -ne 'ok')
    $row = New-Object Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'; $row.Margin = '0,0,0,3'
    if (-not $on) { $row.Opacity = 0.62 }

    $dot = Text-Block $([string][char]$(if ($on) { 0x25CF } else { 0x25CB })) 8 `
                      $(if ($on) { $Pal.blue } else { $Pal.faint })
    $dot.Margin = '0,1,6,0'; $dot.VerticalAlignment = 'Center'
    $row.Children.Add($dot) | Out-Null

    $who = Text-Block $(if ([int]$a.n -gt 0) { [string]$a.n } else { '-' }) 9 $Pal.faint
    $who.Margin = '0,0,8,0'; $who.VerticalAlignment = 'Center'; $who.MinWidth = 7
    $row.Children.Add($who) | Out-Null

    foreach ($L in @(@('5h', [double]$a.five_hour_pct, [string]$a.five_hour_in, 'five-hour'),
                     @('7d', [double]$a.seven_day_pct, [string]$a.seven_day_in, 'seven-day'))) {
      # Guarded before anything downstream (bar, lerp, text, tooltip) sees it -
      # a rejected dip must not exist for this poll at all, not just visually.
      $L[1] = Guard-Pct "acct:$($a.n):$($L[3])" ([double]$L[1]) ([string]$L[2])
      $lab = Text-Block $L[0] 9 $Pal.faint
      $lab.Margin = '0,0,5,0'; $lab.VerticalAlignment = 'Center'
      $row.Children.Add($lab) | Out-Null
      $gauge = New-PctGauge ([double]$L[1]) 46 4 "acct:$($a.n):$($L[3])"
      $bar = $gauge.bar; $pc = $gauge.text
      $bar.Margin = '0,0,6,0'
      $row.Children.Add($bar) | Out-Null
      $pc.Margin = '0,0,6,0'
      $row.Children.Add($pc) | Out-Null
      # The countdown belongs to the window it counts down, not to the account.
      # The five-hour one used to sit alone at the end of the row, which read as
      # a property of the account and left the seven-day bar with no clock at
      # all - so 51% could mean comfortable or nearly out and there was nothing
      # on the row to say which. A percentage is only half the fact; the other
      # half is how long you have to spend it in.
      $rs = $null
      if ($L[2]) {
        # "3h 37m" -> "3h37m". The space costs a character in a row that has
        # four numbers on it already, and buys nothing back.
        $rs = Text-Block ([string]$L[2] -replace ' ', '') 9 $Pal.faint
        $rs.VerticalAlignment = 'Center'; $rs.Margin = '0,0,12,0'; $rs.Opacity = 0.85
        $row.Children.Add($rs) | Out-Null
      }
      $msg = ("{0}  {1} window: {2:N0}% used, {3:N0}% left{4}" -f `
              $a.email, $L[3], $L[1], (100 - $L[1]),
              $(if ($L[2]) { ", resets in $($L[2])" } else { '' }))
      Tip $lab $msg; Tip $bar $msg; Tip $pc $msg
      if ($rs) { Tip $rs $msg }
    }

    # Pace, which is the part a bare percentage cannot tell you: 30% used is
    # fine on day five of seven and not fine on day one. cswap works it out;
    # this only has to say when the answer is no.
    if ([int]$a.ahead_of_pace -eq 1 -or [int]$a.lasts_to_reset -eq 0) {
      $wr = Text-Block $([string][char]0x25B2) 8 `
                       $(if ([int]$a.lasts_to_reset -eq 0) { $Pal.red } else { $Pal.orange })
      $wr.Margin = '0,0,8,0'; $wr.VerticalAlignment = 'Center'
      Tip $wr $(if ([int]$a.lasts_to_reset -eq 0) {
        "at this rate the seven-day window runs out before it resets - {0:N0}% used against {1:N0}% expected by now" -f `
          [double]$a.seven_day_pct, [double]$a.pace_pct }
        else { "ahead of pace: {0:N0}% used where {1:N0}% would be on track" -f `
          [double]$a.seven_day_pct, [double]$a.pace_pct })
      $row.Children.Add($wr) | Out-Null
    }

    # Whatever is left at the end of the row is a fact about the ACCOUNT, not
    # about either window: the reading is old, or the clock is not running at
    # all. The five-hour countdown used to live here too, which is what made
    # this slot ambiguous - a number and a status word in the same position,
    # meaning entirely different things. It sits beside its own bar now.
    #
    # 'idle' still matters and is still not gated on $on: cswap reports a
    # countdown only once a window has actually started, so an untouched
    # account has a stopped clock, and switching to it starts a fresh window
    # from that moment rather than inheriting one.
    $tail = ''
    if ($stale) { $tail = 'stale' }
    elseif (-not $a.five_hour_in) { $tail = 'idle' }
    if ($tail) {
      $tl = Text-Block $tail 9 $(if ($stale) { $Pal.orange }
                                 elseif (-not $on) { $Pal.faint } else { $Pal.dim })
      $tl.VerticalAlignment = 'Center'
      Tip $tl $(if ($stale) {
        "{0}: last read {1} minutes ago ({2})" -f $a.email, [math]::Floor([int]$a.age_sec / 60), $a.status }
        else {
        "{0}: the five-hour clock is not running, so switching here starts a fresh window from that moment. token-window-keeper.sh normally keeps it ticking - check its log if this persists." -f $a.email })
      $row.Children.Add($tl) | Out-Null
    }
    $el.Limits.Children.Add($row) | Out-Null
  }
  $el.Limits.Visibility = if ($el.Limits.Children.Count) { 'Visible' } else { 'Collapsed' }

  Draw-Rows


  # The header dot is the machine's overall state at a glance, and it breathes
  # while anything is running.
  $top = ($d.sessions | Where-Object { $_.alive -eq 1 } | Measure-Object -Property urank -Maximum).Maximum
  $el.Dot.Foreground = (Br (Verdict-Color $(switch ([int]$top) { 3 { 'now' } 2 { 'soon' } 1 { 'cut' } default { 'ok' } })))
  if ($d.sessions | Where-Object { $_.running -eq 1 }) {
    Animate -Target $el.Dot -Property ([Windows.Controls.TextBlock]::OpacityProperty) `
            -From 1.0 -To 0.3 -Seconds 1.5 -Forever -AutoReverse
  } else {
    $el.Dot.BeginAnimation([Windows.Controls.TextBlock]::OpacityProperty, $null)
    $el.Dot.Opacity = 1.0
  }

  # Running out, and what to do about it. The two levels differ only in whether
  # there is somewhere to go: at warn you wrap up, at brake you either switch or
  # you park - and which of those it is depends on another account, which is why
  # this could not be said at all before the usage came from cswap.
  $al = $d.alert
  $lvl = if ($al) { [string]$al.level } else { 'ok' }
  if ($lvl -eq 'ok') {
    $el.AlertBox.Visibility = 'Collapsed'
  } else {
    $brake = ($lvl -eq 'brake')
    $col = if ($brake) { $Pal.red } else { $Pal.orange }
    $el.AlertBox.Background = (Br $(if ($brake) { '#33F87171' } else { '#26FB923C' }))
    $el.AlertGlyph.Text = [string][char]$(if ($brake) { 0x25B2 } else { 0x25B3 })
    $el.AlertGlyph.Foreground = (Br $col)
    $head = '{0:N0}% of the {1} window left' -f [double]$al.left_pct, $al.window
    if ([int]$al.spare -eq 1) {
      $msg = "$head. Account $($al.spare_n) has {0:N0}% free - press w to switch." -f [double]$al.spare_left
    } elseif ($brake) {
      $msg = "$head, and no account has headroom. Park every live session now - /park then /clear, before the window stops you mid-task."
    } else {
      $msg = "$head. Wrap up what is open and do not start anything big; nothing else has headroom to fall back on."
    }
    $el.AlertText.Text = $msg
    $el.AlertText.Foreground = (Br $(if ($brake) { $Pal.text } else { $Pal.dim }))
    $el.AlertBox.Visibility = 'Visible'
    Tip $el.AlertBox ("{0}: {1:N0}% left on {2} ({3}). warn at {4:N0}%, brake at {5:N0}%." -f `
      $lvl, [double]$al.left_pct, $al.account, $al.window, [double]$al.warn_at, [double]$al.brake_at)
    # The banner is always there; the balloon fires once per level, because a
    # notification that repeats every refresh is one you turn off.
    if ($tray -and $script:View.bell -and $script:AlertSeen -ne $lvl) {
      $tray.BalloonTipTitle = $(if ($brake) { 'Out of headroom' } else { 'Running low' })
      $tray.BalloonTipText = $msg
      $tray.ShowBalloonTip(12000)
    }
  }
  if ($script:AlertSeen -ne $lvl) { $script:AlertSeen = $lvl }

  Apply-Chrome

  # Balloons, once per session per lapse. A readout that also nags on every
  # refresh trains you to ignore it.
  if ($tray -and $script:View.bell) {
    foreach ($s in $d.sessions) {
      if ($s.alive -ne 1) { continue }
      $key = $s.sid
      $due = ([int]$s.cache_left_min -le 15 -and [int]$s.cache_left_min -gt 0 -and [double]$s.context_k -ge $cn.park_at)
      if ($due -and -not $script:LastWarn[$key]) {
        $script:LastWarn[$key] = $true
        $tray.BalloonTipTitle = ('{0} lapses in {1}m' -f $s.nick, [int]$s.cache_left_min)
        $tray.BalloonTipText = $s.advice
        $tray.ShowBalloonTip(9000)
      } elseif (-not $due -and [int]$s.cache_left_min -gt 15) {
        $script:LastWarn[$key] = $false
      }
    }
  }
  # The block arms itself. Not on a timer and not on size - on the one state
  # where the tool has nothing useful left to say: a window that has spent every
  # mark it was given, with the hour running out. Up to that point every warning
  # here ends in "type something into it and the cache holds", and that advice is
  # exactly what stops being true when the last ticket is gone.
  #
  # Three guards, and each one is a way this could be wrong rather than a knob:
  #   ext_used > 0   - it must have SPENT its budget, not merely been handed
  #                    zero. A session nobody gave a mark to has done nothing
  #                    wrong and blocking it would be a punishment for a default.
  #   blocked -ne 1  - the snapshot already says armed, so there is nothing to do.
  #   $script:Armed  - the snapshot is up to a refresh behind, so without this
  #                    the same session is armed again on every collect until the
  #                    next one lands. Cleared when the condition passes, which
  #                    is how lifting it by hand does not immediately re-arm.
  foreach ($s in $d.sessions) {
    if ($s.alive -ne 1) { continue }
    $armDue = ([int]$s.ext_left -le 0 -and [int]$s.ext_used -gt 0 -and
               [int]$s.cache_left_min -le $script:BlockAt -and [int]$s.cache_left_min -gt 0 -and
               [double]$s.context_k -ge $cn.park_at)
    if ($armDue -and [int]$s.blocked -ne 1 -and -not $script:Armed[$s.sid]) {
      $script:Armed[$s.sid] = $true
      $why = "out of extension marks at {0:N0}k with {1}m of cache left" -f $s.context_k, [int]$s.cache_left_min
      Start-Bg ("'$(Script-Sh)' --block '$($s.sid)' '$why'")
      Flash ("{0}: blocked - out of marks. u lifts it from here." -f $s.nick)
      if ($tray -and $script:View.bell) {
        $tray.BalloonTipTitle = ('{0} is blocked' -f $s.nick)
        $tray.BalloonTipText = "No extension marks left and the cache is about to lapse. That window has been checkpointed and is now refusing every prompt; anything you type there is cut to the clipboard, not lost. Press u on its row to lift the block."
        $tray.ShowBalloonTip(12000)
      }
    } elseif (-not $armDue -and [int]$s.blocked -ne 1) {
      $script:Armed[$s.sid] = $false
    }
  }

  if ($tray) {
    $live = @($d.sessions | Where-Object { $_.alive -eq 1 }).Count
    $tray.Text = ('Claude: {0} live, {1} this week' -f $live, (Tok $sp7))
  }
}

# --- glass -------------------------------------------------------------------
# The panel was permanently at 93%, which is the wrong default twice over: it
# is faded when there is nothing behind it to see, and barely faded when there
# is. What actually matters is whether the window you are working in is under
# this one - so that is what gets asked, once a second, and the panel is solid
# the rest of the time.
#
# Topmost means nothing ever draws over the widget, which is exactly why it has
# to get out of the way itself.
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
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  // FindWindow looks like the obvious call here and does not work: measured
  // 2026-09-03, it returns 0 for the widget's own "Token Sessions" window while
  // EnumWindows finds it visible in the same process. Enumerating is a few
  // hundred windows once per keypress, which is nothing, and it is reliable.
  public static IntPtr ByTitle(string title) {
    IntPtr hit = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      if (!IsWindowVisible(h)) return true;
      StringBuilder sb = new StringBuilder(256);
      GetWindowTextW(h, sb, 256);
      if (sb.ToString() == title) { hit = h; return false; }
      return true;
    }, IntPtr.Zero);
    return hit;
  }
}
'@

$GLASS = 0.55        # how far out of the way it gets
$script:MouseIn = $false
$script:Hwnd = [IntPtr]::Zero

# True when the focused window overlaps this one. Rectangles come from
# GetWindowRect on both sides - real screen pixels, so nothing here has to know
# anything about DPI scaling, which window Left/Top would have needed.
function Behind-Widget {
  try {
    if ($script:Hwnd -eq [IntPtr]::Zero) {
      $script:Hwnd = (New-Object Windows.Interop.WindowInteropHelper $win).Handle
    }
    if ($script:Hwnd -eq [IntPtr]::Zero) { return $false }
    $fg = [WGlass]::GetForegroundWindow()
    if ($fg -eq [IntPtr]::Zero -or $fg -eq $script:Hwnd) { return $false }
    if ([WGlass]::IsIconic($fg)) { return $false }
    # The desktop and the shell are not a program you are working in. Without
    # this the widget fades whenever you click the wallpaper.
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

# Pointing at the panel always wins: you are looking at it, so it is solid.
function Set-Glass {
  $want = 1.0
  if (-not $script:MouseIn -and (Behind-Widget)) { $want = $GLASS }
  if ([math]::Abs($win.Opacity - $want) -gt 0.005) { $win.Opacity = $want }
}

# --- tray --------------------------------------------------------------------
function Toggle-Panel {
  if ($win.Visibility -eq 'Visible') { $win.Hide() } else { $win.Show(); $win.Activate() }
}
# Regenerating the page runs the same 5.4s collect and used to do it on the
# dispatcher, so the whole panel locked up between pressing t and the browser
# opening. The generator writes to a temp and renames, so opening the file that
# is already there and letting the rewrite land behind it is safe - the browser
# either gets this second's numbers or last minute's, and never a half-file.
# The dashboard is under development and every way in goes through here - the
# link, the tray item and t - so one gate covers all three. Inert rather than
# deleted: the page still builds from the command line, and what is wrong with
# it is the analytics it draws, not the plumbing that draws them.
$script:DashEnabled = $false

function Open-Dashboard {
  if (-not $script:DashEnabled) {
    Flash 'dashboard is under development'
    return
  }
  if (Test-Path $DashGen) {
    Start-Bg ("'$(($DashGen -replace '\\', '/') -replace '^C:', '/c')' >/dev/null 2>&1")
  }
  if (Test-Path $Dash) { Start-Process $Dash }
}

# The parked panel is a separate process with its own window, and - unlike this
# one - no mutex, so a second launch would just stack a duplicate on top of the
# first. Ask the desktop instead: if a window called "Parked" already exists,
# raise that one and stop. The match is on the title WPF sets from XAML
# (token-parked.ps1:112), so nothing has to be written to disk to coordinate.
#
# Launched through the .vbs rather than powershell.exe directly for the same
# reason the widget itself is: -WindowStyle Hidden still leaves an empty console
# in the taskbar for the life of the panel.
function Open-Parked {
  $h = [WGlass]::ByTitle('Parked')
  if ($h -ne [IntPtr]::Zero) {
    if ([WGlass]::IsIconic($h)) { [WGlass]::ShowWindow($h, 9) | Out-Null }  # SW_RESTORE
    [WGlass]::SetForegroundWindow($h) | Out-Null
    Flash 'parked panel is already open'
    return
  }
  $vbs = Join-Path $Root 'token-parked.vbs'
  if (-not (Test-Path $vbs)) { Flash 'token-parked.vbs is missing'; return }
  Start-Process wscript.exe -ArgumentList "`"$vbs`"" -WindowStyle Hidden
  Flash 'opening the parked panel'
}

$tray = $null
if (-not $NoTray) {
  $tray = New-Object System.Windows.Forms.NotifyIcon
  $ico = Join-Path $Root 'token-widget.ico'
  if (Test-Path $ico) { $tray.Icon = New-Object System.Drawing.Icon $ico }
  else { $tray.Icon = [System.Drawing.SystemIcons]::Information }
  $tray.Visible = $true
  $tray.Text = 'Token Sessions'
  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  $miShow = $menu.Items.Add('Show / hide')
  $miMin  = $menu.Items.Add('Minimise / expand')
  $miPark = $menu.Items.Add('Open parked panel')
  $miDash = $menu.Items.Add('Open dashboard (under development)')
  $menu.Items.Add('-') | Out-Null
  $miQuit = $menu.Items.Add('Quit')
  $tray.ContextMenuStrip = $menu
  $miShow.add_Click({ Toggle-Panel })
  $miMin.add_Click({ $script:View.compact = -not $script:View.compact; Update-View -Redraw; Save-State })
  $miPark.add_Click({ Open-Parked })
  $miDash.add_Click({ Open-Dashboard })
  $miQuit.add_Click({ $tray.Visible = $false; $win.Close() })
  $tray.add_MouseDoubleClick({ Toggle-Panel })
}

# A confirmation, on the same line as everything else. It only touches that
# line - there is nothing to redraw for it, and a redraw would restart every
# animation in the panel on every keypress.
function Flash([string]$msg) {
  $script:Flash = $msg
  Show-Message
  $t = New-Object Windows.Threading.DispatcherTimer
  $t.Interval = [TimeSpan]::FromSeconds(2.5)
  $t.add_Tick({ $script:Flash = ''; $this.Stop(); Show-Message })
  $t.Start()
}

# Switching account is cswap's job, not this panel's - but the panel is where
# you find out you need to, so it offers the keystroke. Two presses: swapping
# credentials under running sessions is not something to do on a mistyped key.
function Switch-Account {
  $al = $script:Data.alert
  if (-not $al -or [int]$al.spare -ne 1) { Flash 'no account has headroom to switch to'; return }
  $now = [int][double]::Parse((Get-Date -UFormat %s))

  # What a switch actually costs, measured 2026-09-02 rather than assumed.
  # A prompt cache cannot be read by another account. The same conversation,
  # forked twice in the same minute, only the credentials differing:
  #
  #   account that wrote the cache : read 35,860   write     0
  #   the other account            : read 20,535   write 9,064
  #
  # So it is not a total block. The shared tier - system prompt, tools and
  # CLAUDE.md, byte-identical in both config dirs - is cached SEPARATELY per
  # account and still reads; only the conversation half is lost. That half is
  # the one that scales with context, so the bill is (context - floor) x 2 and
  # every warm session pays it, not just the one you are looking at.
  #
  # This was a warning and not a block, on the reasoning that parking cannot be
  # done from out here - a checkpoint is what the session knows about its own
  # task, and forking it to run /park would itself cost context x 2.
  #
  # That reasoning was wrong, and token-renew.log says so. It priced a fork by
  # the RENEWAL experiment, which failed for an unrelated reason (print mode
  # renders a different first tier, so it warms the wrong prefix - see the
  # refusal note in token-sessions.sh). Parking does not need the right prefix.
  # It only needs a model that can read the transcript and write a file.
  #
  #   MEASURED 2026-09-02, session c527da35, interactive context 45,392:
  #     fork prefix   write 16,042 (2x) + read 13,463 (0.1x)  =  ~33k
  #     the burn this switch inflicts on that window anyway    =  ~51k
  #                                       (45,392 - 20,000) x 2
  #
  # So a fork-park costs LESS than the lapse it is buying a checkpoint against,
  # and it is only paid once - provided the session is cleared afterwards,
  # since a session carried across the switch pays its own burn regardless.
  #
  # ASSUMED, not measured: that the write half scales with conversation size.
  # n=1, at 45k. A 130k window has not been tried and the margin above could
  # close. Measure before trusting this on a large session.
  #
  # Either way the useful thing is still to name what is about to burn, and
  # price it.
  $floor = 20000
  $burn = @($script:Data.sessions | Where-Object {
    [int]$_.alive -eq 1 -and [int]$_.cache_left_min -gt 0 -and [double]$_.context -gt $floor })
  $unparked = @($burn | Where-Object {
    [int]$_.parked -ne 1 -and [double]$_.context_k -ge [double]$script:Bands.park_at })
  $cost = 0.0
  foreach ($b in $burn) { $cost += ([double]$b.context - $floor) * 2 }

  if ($script:SwitchArm -lt $now - $script:SwitchWindow) {
    $script:SwitchArm = $now
    # Longer to answer when there is something to read before answering.
    $script:SwitchWindow = $(if ($burn.Count) { 15 } else { 5 })
    $m = "press w again to switch to account {0} ({1:N0}% free)" -f $al.spare_n, [double]$al.spare_left
    if ($burn.Count) {
      $m += " - burns {0} across {1} warm window{2}" -f `
              (Tok $cost), $burn.Count, $(if ($burn.Count -eq 1) { '' } else { 's' })
    }
    if ($unparked.Count) {
      $m += ". UNPARKED: {0} - /park then /clear there first" -f `
              (($unparked | ForEach-Object { [string]$_.nick }) -join ', ')
    }
    Flash $m
    return
  }
  $script:SwitchArm = 0
  # One command, not two: the memo is what --json reads and it is a lie about
  # which account is active the moment the switch lands, so dropping it has to
  # happen after the switch and before the next collect. Chained in the shell
  # rather than sequenced here, so this can go to the background without the
  # two ends racing.
  Start-Bg ("cswap switch $($al.spare_n) >/dev/null 2>&1; rm -f ~/.claude/.cswap-usage.json")
  Flash "switching to account $($al.spare_n)"
  # Give the switch a moment before asking who is active now.
  $script:Left = 4
}

function Selected-Session {
  if ($script:Sel -gt 0 -and $script:Visible.Count -ge $script:Sel) { return $script:Visible[$script:Sel - 1] }
  if ($script:Visible.Count) { return $script:Visible[0] }
  $null
}

# Naming a session. The line opens on the name it has if you typed one, and
# empty if it is still the derived one - so Enter on an untouched row is a
# no-op rather than a way to accidentally freeze the derived name in place.
function Open-Rename {
  $s = Selected-Session
  if (-not $s) { return }
  $script:Naming = [string]$s.sid
  $el.NameBox.Visibility = 'Visible'
  $el.NameInput.Text = $(if ($s.named -eq 1) { [string]$s.nick } else { '' })
  $el.NameInput.Focus() | Out-Null; $el.NameInput.SelectAll()
}

# Written through token-sessions.sh --name rather than into token-nicks.tsv
# here. The file has one writer on purpose - it is read by the pane, the widget
# and the dashboard - and a second one in another language is how the two
# spellings of a name drift apart.
function Apply-Rename([string]$name) {
  $el.NameBox.Visibility = 'Collapsed'; $win.Focus() | Out-Null
  $sid = $script:Naming; $script:Naming = ''
  if (-not $sid) { return }
  $nm = ($name.Trim() -replace "'", '')
  Start-Bg ("'$(Script-Sh)' --name '$sid' '$nm'")
  # Same trick as the marks: show it now, write it behind. Clearing a name is
  # the one case that still needs the collect, because only token-sessions.sh
  # knows what the derived name would be.
  if ($nm) {
    $s = @($script:Data.sessions | Where-Object { $_.sid -eq $sid })
    if ($s.Count) { $s[0].nick = $nm; $s[0].named = 1 }
    Update-View -Redraw
    Flash "named $nm"
  } else {
    $script:Left = $Every; Start-Collect
    Flash 'back to its derived name'
  }
}
function Toggle-Keys {
  $script:View.keys = -not $script:View.keys
  if ($script:View.keys) { $script:View.compact = $false; $script:View.foot = $true }
  Update-View -Redraw
}

# --- keys --------------------------------------------------------------------
# The pane's vocabulary, so nothing has to be relearned. Everything here is
# view state except r and a, which are the only ones that go back to disk.
function Handle-Key {
  param($e)
  $k = $e.Key.ToString()
  $shift = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0

  # The name line owns the keyboard while it is open.
  if ($el.NameBox.Visibility -eq 'Visible') {
    if ($k -eq 'Return') { Apply-Rename $el.NameInput.Text }
    elseif ($k -eq 'Escape') {
      $script:Naming = ''
      $el.NameBox.Visibility = 'Collapsed'; $win.Focus() | Out-Null
    }
    return
  }

  # WHICH KEYS ARE ACTUALLY USED.
  #
  # Nothing on this machine has ever recorded a keypress, so every question
  # about which bindings earn their line in the overlay has been answered by
  # guessing. This is the cheapest possible answer to it: one row per key, raw,
  # with no bucketing or classification at collection time - what gets counted
  # as "used" is a decision for the reading, not for the writing.
  #
  # Appended, never rotated: the whole value is in the tail of a few weeks. It
  # is written after the name-box guard so a nickname being typed does not enter
  # as thirty keystrokes, and it never touches the UI path - a failed write is
  # silent, because losing a statistic is not a reason to eat a keypress.
  try {
    Add-Content -Path (Join-Path $Root 'token-keys.log') `
                -Value ("{0}`t{1}`t{2}" -f (Get-Date -Format "s"), $k, $(if ($shift) { "shift" } else { "-" })) `
                -Encoding utf8 -ErrorAction SilentlyContinue
  } catch { }

  $n = $script:Visible.Count

  # Digits pick a row outright, the way they do in the pane - and the same digit
  # again lets it go, so there is a way back to "nothing selected" that does not
  # go through esc.
  if ($k -match '^(D|NumPad)([1-9])$') {
    $i = [int]$Matches[2]
    if ($i -le $n) {
      $script:Sel = $(if ($script:Sel -eq $i) { 0 } else { $i })
      Update-View -Redraw
    }
    return
  }

  switch ($k) {
    'Down'   { if ($n) { $script:Sel = [math]::Min($n, $script:Sel + 1); Update-View -Redraw }; return }
    'Up'     { if ($n) { $script:Sel = [math]::Max(1, $script:Sel - 1); Update-View -Redraw }; return }
    'Escape' { if ($script:Sel) { $script:Sel = 0; Update-View -Redraw }
               elseif ($tray) { $win.Hide() } else { $win.Close() }; return }
    'J'      { if ($n) { $script:Sel = [math]::Min($n, $script:Sel + 1); Update-View -Redraw }; return }
    'K'      { if ($n) { $script:Sel = [math]::Max(1, $script:Sel - 1); Update-View -Redraw }; return }
    'C'      { $script:View.compact = -not $script:View.compact; $script:Sel = 0
               Update-View -Redraw; Save-State; return }
    'F'      { $script:View.foot = -not $script:View.foot; Apply-Chrome; Save-State; return }
    'D'      { $script:View.detail = -not $script:View.detail
               if (-not $script:Sel -and $n) { $script:Sel = 1 }
               Update-View -Redraw; Save-State; return }
    'Return' { $script:View.detail = -not $script:View.detail
               if (-not $script:Sel -and $n) { $script:Sel = 1 }
               Update-View -Redraw; Save-State; return }
    'N'      { if ($n) { if (-not $script:Sel) { $script:Sel = 1; Update-View -Redraw }
                          Open-Rename }
               return }
    'W'      { Switch-Account; return }
    'U'      { $s = Selected-Session
               if ($s) {
                 if ([int]$s.blocked -eq 1) {
                   # Lifted here, but the checkpoint is still the point - so the
                   # flash says what was skipped rather than pretending the
                   # session is now in good order.
                   $s.blocked = 0
                   $script:Armed[$s.sid] = $false
                   Update-View -Redraw
                   Start-Bg ("'$(Script-Sh)' --unblock '$($s.sid)'")
                   Flash ("{0}: block lifted - it will re-arm at the next lapse with no marks left" -f $s.nick)
                 } else {
                   Flash ("{0} is not blocked" -f $s.nick)
                 }
               }
               return }
    'E'      { $s = Selected-Session
               if ($s) {
                 $a = [int]$s.ext_allowed + $(if ($shift) { -1 } else { 1 })
                 # The floor is what has been SPENT, not zero: a hollow mark is
                 # a crossing this window made, and taking one back would hand
                 # out a free extension rather than return a ticket. The cap
                 # comes off the snapshot so the number lives in one place, and
                 # set_extend clamps to the same pair on the way to disk - a
                 # stale snapshot cannot talk it past either end.
                 $cap = [int]$(if ($script:Bands.ext_max) { $script:Bands.ext_max } else { 5 })
                 if ($a -lt [int]$s.ext_used) { $a = [int]$s.ext_used }
                 if ($a -lt 0) { $a = 0 }
                 if ($a -gt $cap) { $a = $cap }
                 # The snapshot in hand is updated first and the row redrawn from
                 # it, so the mark appears on the keystroke. The absolute count
                 # goes to disk rather than a delta, so holding the key down
                 # cannot end up applying the increments out of order.
                 $s.ext_allowed = $a
                 $s.ext_left = [math]::Max(0, $a - [int]$s.ext_used)
                 Update-View -Redraw
                 Start-Bg ("'$(Script-Sh)' --extend '$($s.short)' $a")
                 Flash $(if ($shift -and $a -gt 0 -and $a -eq [int]$s.ext_used) {
                           "{0}: those {1} are spent - a hollow mark cannot be removed" -f $s.nick, $a
                         } elseif (-not $shift -and $a -eq $cap) {
                           "{0}: {1} marks, the cap - past this the answer is /park, not another ticket" -f $s.nick, $a
                         } else {
                           "{0}: {1} extension mark{2}" -f $s.nick, $a, $(if ($a -eq 1) { '' } else { 's' }) })
               }
               return }
    'R'      { $script:Left = $Every; Start-Collect
               Flash 'collecting'; return }
    'V'      { Open-Parked; return }
    # g/G, t and b were here until 2026-09-10. g/G (first / last row) duplicated
    # 1-9 and j/k on a list that is never long enough to need a jump; t opened a
    # dashboard the overlay itself labelled under development; b muted the lapse
    # balloons, which nothing had ever turned off - `bell` sits in the saved
    # state and can still be set there. Open-Dashboard and the bell state stay,
    # they just have no key. From now on this is a question with an answer:
    # every press is logged to token-keys.log, so the next cut is arithmetic.
    'P'      { $script:View.pinned = -not $script:View.pinned; Apply-Chrome; Save-State
               Flash $(if ($script:View.pinned) { 'pinned on top' } else { 'unpinned' }); return }
    'L'      { $script:View.legend = -not $script:View.legend
               $script:View.keys = $false; $script:View.foot = $script:View.legend
               Update-View -Redraw; Save-State; return }
    'Q'      { if ($tray) { $tray.Visible = $false }; $win.Close(); return }
    'Y'      {
      # The resume command for that window, on the clipboard. The pane's y.
      $s = Selected-Session
      if ($s) {
        $cmd = "cd `"$($s.cwd)`" && claude -r $($s.sid)"
        try { [System.Windows.Clipboard]::SetText($cmd); Flash "copied: claude -r $($s.short)" }
        catch { Flash 'could not reach the clipboard' }
      }
      return
    }
    'O'      {
      $s = Selected-Session
      if ($s -and (Test-Path $s.cwd)) { Start-Process explorer.exe $s.cwd; Flash "opened $($s.project)" }
      return
    }
  }
  # ? is the key list. Unshifted / used to open the filter and now does the
  # same thing, because a key that silently stopped working is worse than one
  # that quietly still means something.
  if ($k -eq 'OemQuestion' -or $k -eq 'Oem2' -or $k -eq 'Divide') {
    Toggle-Keys
    return
  }
  # Size. + and - zoom the whole panel, 0 puts it back where it started.
  if ($k -eq 'OemPlus' -or $k -eq 'Add') {
    $script:View.zoom = [double]$script:View.zoom + 0.05
    Apply-Size; Save-State; Flash ("zoom {0:N0}%" -f ($script:View.zoom * 100)); return
  }
  if ($k -eq 'OemMinus' -or $k -eq 'Subtract') {
    $script:View.zoom = [double]$script:View.zoom - 0.05
    Apply-Size; Save-State; Flash ("zoom {0:N0}%" -f ($script:View.zoom * 100)); return
  }
  if ($k -eq 'D0' -or $k -eq 'NumPad0') {
    $script:View.width = 412.0; $script:View.zoom = 1.0; $script:View.rowsH = 360.0
    Apply-Size; Save-State; Flash 'size reset'; return
  }
}

# --- interaction -------------------------------------------------------------
# Drag from the header only. On the whole window it would swallow clicks meant
# for the filter box and for row selection.
$el.Header.add_MouseLeftButtonDown({ $win.DragMove() })
$win.add_MouseEnter({ $script:MouseIn = $true;  Set-Glass })
$win.add_MouseLeave({ $script:MouseIn = $false; Set-Glass })
$win.Opacity = 1.0
$win.add_KeyDown({ param($sender, $e) Handle-Key $e })

$el.Close.add_MouseLeftButtonDown({
  $_.Handled = $true
  if ($tray) { $win.Hide() } else { $win.Close() } })
$el.Min.add_MouseLeftButtonDown({
  $_.Handled = $true; $script:View.compact = -not $script:View.compact
  $script:Sel = 0; Update-View -Redraw; Save-State })
$el.Pin.add_MouseLeftButtonDown({
  $_.Handled = $true; $script:View.pinned = -not $script:View.pinned; Apply-Chrome; Save-State })
$el.Fold.add_MouseLeftButtonDown({
  $_.Handled = $true; $script:View.foot = -not $script:View.foot; Apply-Chrome; Save-State })
# Dragging the corner. Screen coordinates rather than window-relative ones,
# because the element being dragged is itself moving as the window widens -
# measuring against it would feed the change back into itself.
# A bare TextBlock is only hit-testable across its glyph, which for a corner
# triangle is a few pixels. The near-transparent background makes the whole
# padded box grabbable without showing anything.
$el.Grip.Background = (Br '#01000000')
$el.Grip.Padding = New-Object Windows.Thickness (5, 3, 3, 3)
$script:Resizing = $false; $script:ResizeX = 0.0; $script:ResizeW = 0.0
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
  # The corner doubles as a zoom dial, which is the gesture people try first.
  $script:View.zoom = [double]$script:View.zoom + $(if ($e.Delta -gt 0) { 0.05 } else { -0.05 })
  Apply-Size; Save-State; $e.Handled = $true })

# --- window edges ------------------------------------------------------------
# The corner grip above is discoverable, but it is also the ONLY place this
# window can be taken hold of, which is not how any other window on the machine
# behaves. This gives it the four edges and the other three corners too, without
# adopting the system chrome - AllowsTransparency rules that out, since a
# layered window has no non-client area for Windows to hit-test against.
#
# The window has no height of its own to set. SizeToContent=Height means the
# height is whatever the content comes to, and the content is bounded by the
# list cap - so a vertical drag moves View.rowsH and lets the window follow. The
# consequence is that the far edge cannot be held still by arithmetic done up
# front: the new height is not known until WPF has measured it. So the edge that
# must not move is recorded as a screen coordinate and re-applied after layout.
$EDGE = 6.0
$script:EdgeMode = ''      # which edge is in hand, '' when none
$script:AnchorB  = $null   # screen y the bottom edge must keep, during a top drag
$script:AnchorR  = $null   # screen x the right edge must keep, during a left drag
$script:Clamping = $false  # re-entrancy guard - the clamp relays out, which re-enters

function Edge-At($pt) {
  $w = $win.ActualWidth; $h = $win.ActualHeight
  $l = ($pt.X -le $EDGE); $r = ($pt.X -ge $w - $EDGE)
  $t = ($pt.Y -le $EDGE); $b = ($pt.Y -ge $h - $EDGE)
  if ($t -and $l) { return 'TL' }; if ($t -and $r) { return 'TR' }
  if ($b -and $l) { return 'BL' }; if ($b -and $r) { return 'BR' }
  if ($l) { return 'L' }; if ($r) { return 'R' }
  if ($t) { return 'T' }; if ($b) { return 'B' }
  ''
}
function Edge-Cursor([string]$m) {
  switch -Regex ($m) {
    '^(L|R)$'   { [Windows.Input.Cursors]::SizeWE }
    '^(T|B)$'   { [Windows.Input.Cursors]::SizeNS }
    '^(TL|BR)$' { [Windows.Input.Cursors]::SizeNWSE }
    '^(TR|BL)$' { [Windows.Input.Cursors]::SizeNESW }
    default     { [Windows.Input.Cursors]::Arrow }
  }
}

# Runs after every layout pass while an edge is in hand. Two jobs: hold the far
# edge still, and refuse to grow off the screen.
#
# The screen limit is a RESIZE rule only, deliberately. A window you DRAG may
# hang off the edge as far as you like - that is a position you chose and can
# undo by dragging back. A window that GROWS off the edge is one whose far side
# you can no longer reach in order to shrink it again, which is a trap rather
# than a placement. So overshoot is not clipped off the window, it is handed
# back to whichever want was being dragged, and the growth simply stops.
function Clamp-Window {
  if ($script:Clamping) { return }
  $script:Clamping = $true
  try {
    $z = [double]$script:View.zoom
    if ($null -ne $script:AnchorR) {
      $l = $script:AnchorR - $win.ActualWidth
      if ($l -lt $wa.Left) {
        $over = $wa.Left - $l
        $win.Left = $wa.Left
        $script:View.width = [math]::Max($MINW, [double]$script:View.width - ($over / $z))
        $win.Width = $script:View.width * $z
      } else { $win.Left = $l }
    } elseif ($script:EdgeMode -match 'R') {
      $over = ($win.Left + $win.ActualWidth) - $wa.Right
      if ($over -gt 0) {
        $script:View.width = [math]::Max($MINW, [double]$script:View.width - ($over / $z))
        $win.Width = $script:View.width * $z
      }
    }
    if ($null -ne $script:AnchorB) {
      $t = $script:AnchorB - $win.ActualHeight
      if ($t -lt $wa.Top) {
        # Scaled all the way to the top. Pin it to the screen and give the
        # overshoot back to the list cap, so what stops is the growing - not the
        # header sliding up out of reach above the top of the display.
        $over = $wa.Top - $t
        $win.Top = $wa.Top
        $script:View.rowsH = [math]::Max($MINH, [double]$script:View.rowsH - ($over / $z))
        $el.RowScroll.MaxHeight = $script:View.rowsH
      } else { $win.Top = $t }
    } elseif ($script:EdgeMode -match 'B') {
      $over = ($win.Top + $win.ActualHeight) - $wa.Bottom
      if ($over -gt 0) {
        $script:View.rowsH = [math]::Max($MINH, [double]$script:View.rowsH - ($over / $z))
        $el.RowScroll.MaxHeight = $script:View.rowsH
      }
    }
  } finally { $script:Clamping = $false }
}

# Preview rather than bubbling, on all three. The card fills the window to its
# own border - there is no transparent gutter to put hit targets in - so the
# edge band lies on top of the header, the rows and the footer. Tunnelling is
# what lets six pixels of edge win over whatever is underneath them.
$win.add_PreviewMouseMove({
  param($sender, $e)
  if ($script:EdgeMode) {
    # Screen coordinates, not window ones: the window is moving underneath the
    # pointer, and measuring against it would feed the change back into itself.
    $dx = [System.Windows.Forms.Cursor]::Position.X - $script:ResizeX
    $dy = [System.Windows.Forms.Cursor]::Position.Y - $script:ResizeY
    $z  = [double]$script:View.zoom
    if ($script:EdgeMode -match 'R') { $script:View.width = $script:ResizeW + ($dx / $z) }
    if ($script:EdgeMode -match 'L') { $script:View.width = $script:ResizeW - ($dx / $z) }
    if ($script:EdgeMode -match 'B') { $script:View.rowsH = $script:ResizeH + ($dy / $z) }
    if ($script:EdgeMode -match 'T') { $script:View.rowsH = $script:ResizeH - ($dy / $z) }
    Apply-Size
    Clamp-Window
    $e.Handled = $true
    return
  }
  # Not dragging: the pointer just says what the edge under it would do.
  if (-not $script:Resizing) { $win.Cursor = (Edge-Cursor (Edge-At ($e.GetPosition($win)))) }
})

$win.add_PreviewMouseLeftButtonDown({
  param($sender, $e)
  $m = Edge-At ($e.GetPosition($win))
  if (-not $m) { return }
  $script:EdgeMode = $m
  # The same flag the corner grip sets, so the message line and the deactivate
  # handler keep treating a resize as a resize whichever way it was started.
  $script:Resizing = $true
  $script:ResizeX = [System.Windows.Forms.Cursor]::Position.X
  $script:ResizeY = [System.Windows.Forms.Cursor]::Position.Y
  $script:ResizeW = [double]$script:View.width
  $script:ResizeH = [double]$script:View.rowsH
  # Only the far side of the edge being pulled gets an anchor. Pull the right
  # edge and the left one is already still, because Left is what it was.
  if ($m -match 'T') { $script:AnchorB = $win.Top + $win.ActualHeight }
  if ($m -match 'L') { $script:AnchorR = $win.Left + $win.ActualWidth }
  $win.CaptureMouse() | Out-Null
  $e.Handled = $true
})

$win.add_PreviewMouseLeftButtonUp({
  param($sender, $e)
  if (-not $script:EdgeMode) { return }
  $script:EdgeMode = ''; $script:Resizing = $false
  $script:AnchorB = $null; $script:AnchorR = $null
  $win.ReleaseMouseCapture()
  Save-State
  $e.Handled = $true
})

# SizeToContent settles a frame late, so the anchor has to be re-applied here
# and not only in the move handler - otherwise the far edge walks by whatever
# the last drag step changed the height by.
$win.add_SizeChanged({ if ($script:EdgeMode) { Clamp-Window } })

$el.Refresh.add_MouseLeftButtonDown({
  $_.Handled = $true; $script:Left = $Every; Start-Collect })
$el.DashLink.add_MouseLeftButtonDown({ $_.Handled = $true; Open-Dashboard })
$el.LegendToggle.add_MouseLeftButtonDown({
  $_.Handled = $true; $script:View.keys = $false; $script:View.foot = $true
  Update-View -Redraw; Save-State })
$el.KeysToggle.add_MouseLeftButtonDown({ $_.Handled = $true; Toggle-Keys })

$win.add_Closing({
  Save-State
  if ($tray) { $tray.Visible = $false; $tray.Dispose() } })

# One timer at 1Hz drives both the countdown and the refresh, so the two can
# never disagree about when the next collect is due. The animations are WPF's
# own and are not driven from here - a 1Hz tick would make them stutter.
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.add_Tick({
  Poll-Collect
  Reap-Bg
  try { Live-Tick } catch { }
  try { Run-Tick } catch { }
  $script:Left--
  if ($script:Left -le 0) {
    $script:Left = $Every
    Start-Collect
  }
  # Elapsed, not a spinner. Every number this widget draws comes from a
  # token-sessions.sh run that spawns something over a hundred processes, so the
  # collect is only ever as fast as process creation on this machine - measured
  # at 55ms per spawn when the tooling was written, and at ~2s per spawn on
  # 2026-09-03, which turned a six-second collect into a 140-second one.
  #
  # That was read as an antivirus setting for a while, and it was not: 26 copies
  # of this widget were running at once, each with its own refresh timer and its
  # own collect, so the machine was creating processes for two dozen overlapping
  # hundred-process passes. Killing them took the spawn back to 41ms and the
  # collect to 5.9s - faster than the baseline the tooling was written against,
  # with Defender untouched throughout. The single-instance guard at the top of
  # this file is what stops it recurring; this countdown just stops pretending
  # the wait is short while it lasts.
  $el.Countdown.Text = $(if ($script:Collecting) {
      $secs = [int]((Get-Date) - $script:CollectAt).TotalSeconds
      if ($secs -ge 20) { 'collecting... {0}s' -f $secs } else { 'collecting...' }
    } else { 'refresh {0}s' -f $script:Left })
  if ($script:Collecting -and ((Get-Date) - $script:CollectAt).TotalSeconds -ge 45) {
    Tip $el.Countdown ("this collect has been running {0}s. token-sessions.sh spawns about a hundred short-lived processes, so it is only ever as fast as process creation - and the usual reason that goes slow is another copy of THIS widget, not the machine. Check the process list for duplicate token-widget.ps1 before suspecting anything else; measured 2026-09-03, 26 copies had a no-op spawn at ~2s and a collect at 140s, and killing them put it back to 41ms and 5.9s. Memory pressure is the next thing to check. Antivirus almost never is." -f [int]((Get-Date) - $script:CollectAt).TotalSeconds)
  }
  # Cheap enough to ask every second: three user32 calls and a rectangle test.
  Set-Glass
})
$timer.Start()

Apply-Size

# The renewer's schedule, re-armed at launch.
#
# It stays a Windows task rather than a timer this process owns, because it has
# to keep renewing after the widget is closed - but a task that quietly goes
# missing is invisible from here, and that is not hypothetical: measured
# 2026-09-04, extension marks had been budgeted and displayed for two days with
# ClaudeTokenPokeDue not registered at all, so every window lapsed with a full
# ticket in hand. The widget is the one thing always running when sessions are,
# so it is where the check belongs.
#
# Cheap and idempotent: one Get-ScheduledTask when the task is already there,
# and the installer only runs when it is not. token-pokedue.off is honoured as
# the deliberate "leave it down" path - pause with the file, and -Remove plus
# that file is how you turn it off for good without the widget re-arming it.
#
# Re-checked hourly as well as at launch, from Start-Collect. The check is a
# timestamp comparison until the hour is up and one Get-ScheduledTask after
# that - measured in milliseconds, no model tokens, nothing spawned - so the
# cost is not the reason it was startup-only; it was startup-only because that
# is where the failure had been seen. An unregistered task is silent either
# way, and the widget is what is watching.
$script:PokeDueCheckedAt = [datetime]::MinValue
function Ensure-PokeDue {
  try {
    if (((Get-Date) - $script:PokeDueCheckedAt).TotalMinutes -lt 60) { return }
    $script:PokeDueCheckedAt = Get-Date
    if (Test-Path (Join-Path $Root 'token-pokedue.off')) { return }
    if (Get-ScheduledTask -TaskName 'ClaudeTokenPokeDue' -ErrorAction SilentlyContinue) { return }
    $inst = Join-Path $Root 'token-pokedue-install.ps1'
    if (-not (Test-Path $inst)) { return }
    & $inst | Out-Null
    Add-Content -Path (Join-Path $Root 'token-pokedue.log') -Encoding utf8 `
      -Value ("{0}`tre-armed by the widget - the task was missing" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'))
  } catch {
    # Never fatal. A widget that refuses to start because a scheduled task
    # could not be registered is a worse failure than the one it is fixing.
  }
}
# Not called here: the first Start-Collect below does it, and every one after
# that re-checks once the hour is up.

# The first collect is started, not awaited: the panel is on screen in
# milliseconds saying it is collecting, rather than five seconds after launch.
if (-not $SelfTest) { Start-Collect }

try { if ($SelfTest) { $d = Get-Data; if ($d) { $script:Data = $d } }; Update-View } catch {
  # Swallowed in normal use - a widget that vanishes on one bad refresh is
  # worse than one showing stale numbers. Under -SelfTest it must not be,
  # or the test reports "fine" on a panel that built nothing.
  if ($SelfTest) { throw }
  $el.Advice.Text = "could not read token-sessions.sh --json: $_"
}

# Everything above is buildable and populatable without a window, so it can be
# checked from a terminal. A widget you can only test by looking at it is a
# widget nobody tests.
if ($SelfTest) {
  $timer.Stop()
  if ($tray) { $tray.Visible = $false; $tray.Dispose() }
  Write-Output ("bash      : " + $Bash)
  Write-Output ("sessions  : " + $(if ($script:Data) { @($script:Data.sessions).Count } else { 'NO DATA' }))
  Write-Output ("rows      : " + $el.Rows.Children.Count)
  Write-Output ("keys      : " + $el.Keys.Children.Count + " lines, " + $KEYMAP.Count + " bindings")
  Write-Output ("legend    : " + $el.Legend.Children.Count + " lines")
  $script:View.width = 500; $script:View.zoom = 1.2; Apply-Size
  Write-Output ("resize    : width=" + $script:View.width + " zoom=" + $script:View.zoom +
                " -> window " + $win.Width)
  $script:View.width = 99999; $script:View.zoom = 9; Apply-Size
  Write-Output ("clamped   : width=" + $script:View.width + " zoom=" + $script:View.zoom)
  $script:View.width = 412; $script:View.zoom = 1.0; Apply-Size
  # The cap only earns its keep if it actually engages, so measure the rows
  # rather than asserting the property: with advice on every row the content is
  # taller than it used to be and the scroll is no longer hypothetical.
  function Wants {
    $el.Card.UpdateLayout()
    $el.Card.Measure((New-Object Windows.Size ([double]$script:View.width, [double]::PositiveInfinity)))
    [math]::Round($el.Rows.DesiredSize.Height)
  }
  function Verdict([double]$need) {
    if ($need -gt $el.RowScroll.MaxHeight) { 'scrolls' } else { 'fits' }
  }
  $base = Wants
  Write-Output ("list      : {0} rows want {1}px, cap {2}px -> {3}" -f `
                $el.Rows.Children.Count, $base, [math]::Round($el.RowScroll.MaxHeight), (Verdict $base))
  # Detail on the selected row has to make the SAME list taller - that is the
  # stretch - and the cap has to notice.
  $script:Sel = 1; $script:View.detail = $true; Update-View -Redraw
  $withD = Wants
  Write-Output ("  detail  : {0}px, {1}px more than closed -> {2}" -f `
                $withD, ($withD - $base), (Verdict $withD))
  # And dragging the cap under the content is what turns the scrollbar on.
  $script:View.rowsH = 120.0; Apply-Size
  Write-Output ("  capped  : cap {0}px -> {1}" -f [math]::Round($el.RowScroll.MaxHeight), (Verdict (Wants)))
  $script:View.detail = $false; $script:Sel = 0; $script:View.rowsH = 360.0
  Apply-Size; Update-View -Redraw
  $script:View.rowsH = 5; Apply-Size
  Write-Output ("clamped h : rowsH=" + $script:View.rowsH)
  $script:View.rowsH = 360.0; Apply-Size
  Write-Output ("7d spend  : " + $el.Spend.Text + "   " + $el.SplitKey.Text + "   " + $el.Wpc.Text)
  foreach ($s in $script:Visible) {
    $rec = @($s.recent)
    $lg = 0; if ($rec.Count) { $lg = [double]$rec[$rec.Count - 1].growth }
    Write-Output ("  row     : {0,-22} {1,7:N1}k  {2,5}  spark {3}  +{4,-6} {5,8}  heat {9,6}  {6}{7}{8}{10}" -f `
      $s.nick, $s.context_k, `
      $(if ($s.cache_left_min -le 0) { 'COLD' } else { "$($s.cache_left_min)m" }), `
      $rec.Count, (Tok $lg), (Tok $s.cost.total), $s.grades.spend, $s.grades.churn, $s.grades.control, `
      $(if ($s.hot -gt 0) { '{0:N2}x' -f $s.hot } else { '-' }), `
      $(if ($s.running -eq 1) { '  <- spinner, breathing name' } else { '' }))
  }
  # The elapsed clock, read back off the built rows rather than recomputed from
  # the payload - the point of the check is that the TextBlock got the number,
  # not that the arithmetic works. Run-Tick is driven once by hand first, since
  # in a self-test no timer ever fires.
  try { Run-Tick } catch { Write-Output ("  run     : Run-Tick threw - " + $_.Exception.Message) }
  $nrun = 0
  foreach ($row in $el.Rows.Children) {
    $t = $row.Tag
    if (-not $t -or -not $t.ContainsKey('run')) { continue }
    if ([int]$t.runState -lt 1 -or [double]$t.runSince -le 0) { continue }
    $nrun++
    Write-Output ("  run     : {0,-22} {1,6} elapsed   state {2}   {3}" -f `
      $t.sid.Substring(0, [math]::Min(8, $t.sid.Length)), $t.run.Text, $t.runState, $t.runCol)
  }
  if ($nrun -eq 0) { Write-Output "  run     : no turn in flight - clock not exercised" }

  $lm = $script:Data.limits
  Write-Output ("limits    : source " + $(if ($lm) { $lm.source } else { 'none' }) +
                ", " + $el.Limits.Children.Count + " rows drawn")
  foreach ($sx in $script:Visible) {
    Write-Output ("  marks   : {0,-22} {1}/{2} left, extend ~{3} vs lapse ~{4} ({5:N0}x)" -f `
      $sx.nick, $sx.ext_left, $sx.ext_allowed, (Tok ([double]$sx.ext_cost)),
      (Tok ([double]$sx.lapse_cost)),
      $(if ([double]$sx.ext_cost -gt 0) { [double]$sx.lapse_cost / [double]$sx.ext_cost } else { 0 }))
  }
  Write-Output ("scales    : growth budget " + (Tok $script:Bands.gbud) +
                "/cycle, price_in $" + $script:PriceIn + "/Mtok")
  $lr = 0
  foreach ($row in $el.Rows.Children) { if ($row.Tag -and $row.Tag.sid) { $lr++ } }
  $usage = @(Get-ChildItem (Join-Path $Root 'session-usage') -Filter *.json -ErrorAction SilentlyContinue).Count
  Live-Tick
  Write-Output ("live      : {0}/{1} rows wired for live repaint, {2} payloads on disk" -f `
                $lr, $el.Rows.Children.Count, $usage)
  $al = $script:Data.alert
  if ($al) {
    Write-Output ("alert     : {0}  {1:N0}% left on the {2}  banner={3}  spare={4}" -f `
      $al.level, [double]$al.left_pct, $al.window, $el.AlertBox.Visibility,
      $(if ([int]$al.spare -eq 1) { "account $($al.spare_n) at $([math]::Round([double]$al.spare_left))%" } else { 'none' }))
  }
  if ($lm) {
    foreach ($a in @($lm.accounts)) {
      Write-Output ("  account : {0,-30} {1,-9} 5h {2,3:N0}%  7d {3,3:N0}%  pace {4,3:N0}%  {5,4}s old{6}" -f `
        $a.email, $(if ([int]$a.active -eq 1) { '(in use)' } else { '' }),
        $a.five_hour_pct, $a.seven_day_pct, $a.pace_pct, $a.age_sec,
        $(if ([int]$a.ahead_of_pace -eq 1) { '  AHEAD OF PACE' }
          elseif ([int]$a.lasts_to_reset -eq 0) { '  WILL NOT LAST' } else { '' }))
    }
  }
  # Selection has to be visible from the data alone, not only to an eye: a ring
  # on the picked row and every other row stepped back.
  if ($script:Visible.Count -ge 2) {
    $script:Sel = 2; Update-View -Redraw
    Write-Output ("selected  : row2 ring=" + $el.Rows.Children[1].BorderBrush.Color +
                  "  row1 opacity=" + $el.Rows.Children[0].Opacity +
                  "  row2 opacity=" + $el.Rows.Children[1].Opacity)
    $script:Sel = 2; Update-View -Redraw    # the digit again lets it go
    $script:Sel = 0; Update-View -Redraw
    Write-Output ("cleared   : row1 opacity=" + $el.Rows.Children[0].Opacity +
                  "  ring=" + $el.Rows.Children[1].BorderBrush.Color)
  }

  # The three chrome states that have to hold up on their own.
  $script:View.foot = $false; Apply-Chrome
  Write-Output ("folded    : foot=" + $el.FootBody.Visibility + " chevron=" + $el.Fold.Text)
  $script:View.foot = $true; $script:View.keys = $true; Apply-Chrome
  Write-Output ("keys view : legend=" + $el.Legend.Visibility + " keys=" + $el.Keys.Visibility)
  $script:View.keys = $false; $script:View.compact = $true
  Update-View -Redraw
  Write-Output ("compact   : " + $script:Visible.Count + " row, score=" + $el.Score.Visibility +
                " foot=" + $el.FootBody.Visibility + " advice=" + $el.AdviceBox.Visibility)
  foreach ($s in $script:Visible) { Write-Output ("  shows    : " + $s.nick + "  running=" + $s.running) }
  exit 0
}

# The chrome buttons declared their hover text inline in the XAML, so they were
# the last things in the widget still popping a REAL tooltip - a second window
# that floats over the rows and times out, which is the whole thing Tip() was
# written to replace. They were never converted because Tip() returns early when
# .ToolTip is already set (that early return is what stops persistent elements
# collecting a handler per refresh), and a XAML attribute sets it before any
# code runs. Clearing it first is what makes the conversion take.
#
# Swept over the tree rather than done by name: there are eight of them, not one
# carries an x:Name, and a tooltip added to the XAML later is caught for free.
# Runs exactly once, here, so the per-refresh guard is untouched.
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

# Clicking away drops the selection. A selected row dims every other one, so a
# selection left standing while you work elsewhere turns the whole panel into a
# view of one session - and the panel exists to be glanced at, which means its
# resting state has to be "all of them". Escape and clicking the row again
# already clear it; this makes looking away do the same.
#
# Two states are exempt, because in both the widget loses focus as part of an
# action still in progress rather than because you left: the name box (which
# takes keyboard focus, and whose row must stay selected to receive the name)
# and a corner drag (which is steered from outside the window's own bounds).
$win.Add_Deactivated({
  if ($script:Naming) { return }
  if ($script:Resizing) { return }
  if ($script:Sel -ne 0) { $script:Sel = 0; Update-View -Redraw }
})

# Without this the window can go while the dispatcher loop keeps spinning, and a
# windowless process still holds the single-instance mutex - so every later
# launch prints "already running" into a console that isn't there and exits.
# Observed 2026-09-03: a widget invisible since 17:43 that could not be
# restarted until the zombie was killed by hand.
$win.Add_Closed({
  if ($tray) { $tray.Visible = $false; $tray.Dispose() }
  [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
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
