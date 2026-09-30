# token-parked-tab.ps1 - the Parked tab of token-widget.ps1.
#
# Dot-sourced by the widget after its helpers and $el exist, so it runs in the
# widget's process and draws into the widget's window. Ported from the retired
# standalone token-parked.ps1: every function here is Pk-prefixed and every bit
# of state is $script:Pk*, because the two scripts grew the same names
# (Pk-Update-View, Pk-Draw-Rows, $script:PkSel ...) for different things. Window
# plumbing - chrome, size, glass, tray, Br/Tip/Flash/Show-Message - is the
# widget's and is shared, as is $script:View (zoom, width, rowsH, foot, keys).

# checkpoints change slowly, and the answer is a directory listing, not a collect
$PkEvery = 300

# A checkpoint whose window is still open. Not a warning - there is nothing
# wrong with it - but unparking it starts a SECOND window on one strand, and the
# two will then diverge with no way to merge them. So the row is tinted the way
# a lapsed session is tinted next door: a fact about the row, stated by its
# ground rather than by a word you have to find.
$OpenBrush  = (Br '#1A7C9CBF')
# A checkpoint the work ran on past. Warm, because this one IS a warning: resume
# it and you resume from behind, and the distance is printed on the row.
$BehindBrush = (Br '#18FB923C')

$PK_KEYMAP = @(
  @('j k', 'move - the selected row opens'), @('1-9', 'select that row'),
  @('g G', 'first / last row'),
  @('enter', 'resume it in a terminal'), @('y', 'copy the resume command'),
  @('o',   'open the checkpoint file'), @('e', 'open the project folder'),
  @('x x', 'delete it - twice, and it is gone'),
  @('r',   're-read the directory'),  @('f',   'fold the footer'),
  @('p',   'pin / unpin on top'),     @('l',   'the legend'),
  @('+ -', 'zoom, or wheel the corner'), @('0', 'reset size and zoom'),
  @('?',   'this list'),              @('esc', 'hide to the tray'),
  @('v',   'back to the sessions tab'), @('q', 'quit')
)

# --- data --------------------------------------------------------------------
$script:PkData = $null
$script:PkVisible = @()
$script:PkSel = 0
$script:PkLeft = $PkEvery
# The file the last x was pressed on. Deleting a checkpoint destroys the only
# record of where that work stood, so it takes two presses on the same row - and
# the arming is cleared by anything else you do, including moving off the row.
$script:PkArmedDelete = ''
# The same idea for resuming a checkpoint whose window is still open. That one
# is not destructive - you may well mean it - so the first press explains what
# it will do and the second goes ahead.
$script:PkArmedOpen = ''

$script:PkCollectPS = $null
$script:PkCollectHandle = $null
$script:PkCollecting = $false
$script:PkCollectAt = [datetime]::MinValue

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

# --- formatting --------------------------------------------------------------
# Minutes into the shortest true thing. The same three scales token-sessions.sh
# uses in its own listing, so an age reads the same in both.
function Pk-Age([double]$m) {
  if ($m -lt 60)   { return ('{0:N0}m' -f $m) }
  if ($m -lt 2880) { return ('{0:N0}h' -f ($m / 60)) }
  ('{0:N0}d' -f ($m / 1440))
}

# How old is too old to trust without looking. Not a cliff - a checkpoint from
# last week is still the cheapest way back into that work - but past a couple of
# days the tree has usually moved under it, which is the thing /unpark is told
# to check first. So the age simply loses its brightness rather than turning a
# colour that would compete with the state.
function Pk-Age-Color([double]$m) {
  if ($m -ge 10080) { return $Pal.faint }   # a week
  if ($m -ge 2880)  { return $Pal.grey }    # two days
  $Pal.dim
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
function Pk-State-Of($C, [double]$StaleAfter) {
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
    return @{ key = 'behind'; word = ('behind {0}' -f (Pk-Age ([double]$C.behind_min))); glyph = [string][char]0x25B2
              colour = $Pal.orange; ground = $BehindBrush
              why = ("the session worked on for {0} after writing this, so the checkpoint is behind the work. Resume it and you resume from that far back - what happened in between was never written down anywhere." -f (Pk-Age ([double]$C.behind_min))) }
  }
  @{ key = 'ready'; word = 'ready'; glyph = [string][char]0x25CB; colour = $Pal.green
     ground = $null
     why = "the window is closed and nothing happened after the checkpoint was written, so this is the whole state of that work. Enter resumes it in its own directory." }
}

# --- the row -----------------------------------------------------------------
# One labelled block of the expanded row. -Bullets takes the body as one item
# per line (token-sessions.sh keeps a section's bullets on separate lines) and
# hangs each off a dot, so a wrapped item still reads as one. -Brief is for a
# list you want the gist of: each item is cut at its first em-dash aside (the
# reason, which is what makes a decision long) and held to one line, the whole
# item on hover; -Max stops the list and says how many were left out. Only the
# em dash: a spaced hyphen turns up inside decisions too, "(+ - 0)". Written as
# [char]0x2014 because PowerShell 5.1 reads a BOM-less script as ANSI.
function Pk-Detail-Section {
  param($Parent, [string]$Label, [string]$Body, $Colour, [string]$Why = '',
        [switch]$Bullets, [switch]$Brief, [int]$Max = 0)
  $lb = Text-Block $Label 8.5 $Pal.faint
  $lb.Margin = '18,7,0,2'
  if ($Why) { Tip $lb $Why }
  $Parent.Children.Add($lb) | Out-Null
  $items = if ($Bullets) { @($Body -split "`n" | Where-Object { $_ -match '\S' }) } else { @($Body) }
  $shown = if ($Max -gt 0 -and $items.Count -gt $Max) { $items[0..($Max - 1)] } else { $items }
  foreach ($it in $shown) {
    $txt = if ($Brief) { ($it -split (' {0} ' -f [char]0x2014), 2)[0] } else { $it }
    $tx = Text-Block $txt 9.5 $Colour 'Segoe UI'
    if ($Brief) {
      $tx.TextWrapping = 'NoWrap'; $tx.TextTrimming = 'CharacterEllipsis'
      if ($txt -ne $it) { Tip $tx $it }
    } else { $tx.TextWrapping = 'Wrap' }
    if (-not $Bullets) { $tx.Margin = '18,0,4,0'; $Parent.Children.Add($tx) | Out-Null; continue }
    $dp = New-Object Windows.Controls.DockPanel
    $dp.Margin = '18,1,4,0'
    $bd = Text-Block ([string][char]0x2022) 9.5 $Colour
    $bd.Width = 10
    [Windows.Controls.DockPanel]::SetDock($bd, 'Left')
    $dp.Children.Add($bd) | Out-Null
    $dp.Children.Add($tx) | Out-Null
    $Parent.Children.Add($dp) | Out-Null
  }
  if ($shown.Count -lt $items.Count) {
    $mo = Text-Block ('+{0} more - o opens the checkpoint' -f ($items.Count - $shown.Count)) 9 $Pal.faint
    $mo.Margin = '28,1,4,0'
    $Parent.Children.Add($mo) | Out-Null
  }
}

function Pk-New-Row {
  param($C, [double]$StaleAfter, [bool]$Selected, [bool]$Dim)
  $st = Pk-State-Of $C $StaleAfter

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

  $ag = Text-Block (Pk-Age ([double]$C.age_min)) 11 (Pk-Age-Color ([double]$C.age_min))
  $ag.TextAlignment = 'Right'; $ag.MinWidth = 34; $ag.VerticalAlignment = 'Center'
  Tip $ag ("written {0}. A checkpoint records what was true then - compare its branch and HEAD against the tree before trusting it, which is the first thing /unpark is told to do." -f `
           ([datetimeoffset]::FromUnixTimeSeconds([long]$C.written).LocalDateTime.ToString('ddd d MMM HH:mm')))
  [Windows.Controls.Grid]::SetColumn($ag, 2); $l1.Children.Add($ag) | Out-Null
  $outer.Children.Add($l1) | Out-Null

  # --- line 2: the next step -------------------------------------------------
  # The single most useful line on the row, and the reason this panel is worth
  # having at all: it is the one thing that tells you whether picking this up
  # now is five minutes of work or an afternoon. Trimmed to one line - the whole
  # section is on hover, and in full once the row is selected.
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
  # What the row has no room for, on the selected row only: selecting IS asking
  # what this one was, so there is no second key to find. What is waiting on
  # you comes first and in full - it is the thing to settle before resuming -
  # and saying there is none is as useful as listing them. Decisions are
  # already settled, so they get a line each: enough to recognise, not re-read.
  if ($Selected) {
    $rule = New-Object Windows.Controls.Border
    $rule.Height = 1; $rule.Background = (Br $Pal.line); $rule.Margin = '18,8,4,1'
    $outer.Children.Add($rule) | Out-Null
    if ($C.blocked) { Pk-Detail-Section $outer 'waiting on you' ([string]$C.blocked) $Pal.yellow -Bullets }
    else {
      $no = Text-Block 'nothing left open' 9 $Pal.faint
      $no.Margin = '18,7,0,0'
      $outer.Children.Add($no) | Out-Null
    }
    if ($C.task)    { Pk-Detail-Section $outer 'goal' ([string]$C.task) $Pal.dim }
    if ($C.next)    { Pk-Detail-Section $outer 'next' ([string]$C.next) $Pal.dim }
    if ($C.decided) { Pk-Detail-Section $outer 'decided' ([string]$C.decided) $Pal.faint `
                        'settled in that session - /unpark treats these as closed. Hover a line for the reason.' `
                        -Bullets -Brief -Max 4 }
    $d3 = Text-Block ("{0}   {1}" -f $C.file, $(if ($C.short) { "session $($C.short)" } else { 'unstamped' })) 9 $Pal.faint
    $d3.Margin = '18,7,0,0'
    Tip $d3 ([string]$C.path)
    $outer.Children.Add($d3) | Out-Null
  }

  $sel.Tag = @{ rest = $rest; file = [string]$C.file; state = $st.key }
  $sel
}

function Pk-Build-Legend {
  $L = $el.PkLegend
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

function Pk-Build-Keys {
  $K = $el.PkKeys
  $K.Children.Clear()
  for ($i = 0; $i -lt $PK_KEYMAP.Count; $i += 2) {
    $row = New-Object Windows.Controls.Grid
    $row.Margin = '0,0,0,3'
    foreach ($w in 'Auto', '*', 'Auto', '*') {
      $cd = New-Object Windows.Controls.ColumnDefinition
      $cd.Width = if ($w -eq 'Auto') { [Windows.GridLength]::Auto } else { New-Object Windows.GridLength (1, 'Star') }
      $row.ColumnDefinitions.Add($cd)
    }
    $pairs = @(, $PK_KEYMAP[$i])
    if ($i + 1 -lt $PK_KEYMAP.Count) { $pairs += , $PK_KEYMAP[$i + 1] }
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

function Pk-Collect-Cmd {
  $sh = ($Script -replace '\\', '/') -replace '^C:', '/c'
  "'$sh' --parked --json --no-update-check 2>/dev/null"
}

function Pk-Start-Collect {
  if ($script:PkCollectPS) { return }
  try {
    $ps = [PowerShell]::Create()
    $ps.AddScript('param($bash, $cmd) (& $bash -lc $cmd) -join [char]10') | Out-Null
    $ps.AddArgument($Bash) | Out-Null
    $ps.AddArgument((Pk-Collect-Cmd)) | Out-Null
    $script:PkCollectPS = $ps
    $script:PkCollectHandle = $ps.BeginInvoke()
    $script:PkCollecting = $true
    $script:PkCollectAt = Get-Date
  } catch {
    if ($script:PkCollectPS) { $script:PkCollectPS.Dispose() }
    $script:PkCollectPS = $null; $script:PkCollecting = $false
  }
}

function Pk-Poll-Collect {
  if (-not $script:PkCollectPS) { return }
  if (-not $script:PkCollectHandle.IsCompleted) { return }
  $ok = $false
  try {
    $txt = ($script:PkCollectPS.EndInvoke($script:PkCollectHandle) | Out-String)
    if ($txt.Trim()) {
      $d = $txt | ConvertFrom-Json
      if ($d) { $script:PkData = $d; $ok = $true }
    }
  } catch { }
  try { $script:PkCollectPS.Dispose() } catch { }
  $script:PkCollectPS = $null; $script:PkCollectHandle = $null; $script:PkCollecting = $false
  if ($ok) { Pk-Update-View }
}

# Newest first, which is the order the collector emits and the order the pane's
# own listing uses. Nothing re-sorts by state: a list that reorders itself when
# a window closes is one you cannot learn the shape of.
function Pk-Get-Visible {
  if (-not $script:PkData) { return , @() }
  , @($script:PkData.checkpoints)
}

function Pk-Selected-Row {
  if ($script:PkSel -le 0 -or $script:PkSel -gt $script:PkVisible.Count) { return $null }
  $script:PkVisible[$script:PkSel - 1]
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
function Pk-Resume-Args($C) {
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
function Pk-Resume-Flags($C) {
  $f = ''
  if ($C.model)  { $f += ' --model {0}' -f $C.model }
  if ($C.effort) { $f += ' --effort {0}' -f $C.effort }
  $f
}

function Pk-Log-Parked($Action, $C) {
  try {
    if (-not $C) { return }
    $row = @(
      (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss'), $Action, [string]$C.topic,
      [string]$C.project, [string]$C.short, [int]$C.alive, [int]$C.age_min,
      [int]$C.behind_min, [string]$C.cwd) -join "`t"
    Add-Content -LiteralPath $script:ParkedLog -Value $row -Encoding utf8 -ErrorAction Stop
  } catch { }
}

# A checkpoint with no known directory: parked before /park stamped cwd= into
# its park line, by a session token-meta.tsv never recorded. A folder named
# after the project under the home directory is looked for first, and a single
# hit is taken as the answer; none or several, and a folder picker asks. What
# is chosen is stamped into the checkpoint, so this runs once per checkpoint.
function Pk-Find-ProjectDirs([string]$Name) {
  $skip = @('AppData', 'node_modules', 'Library', 'Temp', 'obj', 'bin', 'Packages')
  $hits = New-Object System.Collections.Generic.List[string]
  $level = @($env:USERPROFILE)
  for ($d = 0; $d -lt 4 -and $level.Count; $d++) {
    $next = New-Object System.Collections.Generic.List[string]
    foreach ($dir in $level) {
      foreach ($k in @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($k.Name -ieq $Name) { $hits.Add($k.FullName); continue }
        if ($k.Name.StartsWith('.') -or $skip -contains $k.Name) { continue }
        if ($k.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        $next.Add($k.FullName)
      }
    }
    $level = $next.ToArray()
  }
  return ,$hits.ToArray()
}

function Pk-Stamp-Cwd($C, [string]$Dir) {
  $p = [string]$C.path
  if ($p -match '^/([a-zA-Z])/(.*)$') { $p = '{0}:\{1}' -f $Matches[1], ($Matches[2] -replace '/', '\') }
  try {
    $text  = [IO.File]::ReadAllText($p)
    $first = ($text -split "`r?`n", 2)[0]
    if ($first -match '^<!-- park:' -and $first -notmatch ' cwd=') {
      $i = $first.LastIndexOf('-->')
      $text = $first.Substring(0, $i).TrimEnd() + " cwd=$Dir -->" + $text.Substring($first.Length)
    } elseif ($first -notmatch '^<!-- park:') {
      $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
      $text = "<!-- park: cwd=$Dir -->$nl" + $text
    } else { return }
    [IO.File]::WriteAllText($p, $text, (New-Object Text.UTF8Encoding $false))
    Pk-Log-Parked 'stamp-cwd' $C
  } catch { Pk-Log-Parked 'stamp-cwd-failed' $C }
}

function Pk-Resolve-Cwd($C) {
  $hits = @(Pk-Find-ProjectDirs ([string]$C.project))
  if ($hits.Count -eq 1) {
    $dir = $hits[0]; $how = 'cwd-found'
  } else {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = if ($hits.Count) {
      "{0}: {1} folders are named {2} - pick the one to resume in" -f $C.topic, $hits.Count, $C.project
    } else { "{0}: no folder named {1} under your home - where does it live?" -f $C.topic, $C.project }
    $dlg.SelectedPath = if ($hits.Count) { $hits[0] } else { $env:USERPROFILE }
    # Owned by the pane, or a topmost pane draws over its own dialog.
    $owner = New-Object System.Windows.Forms.NativeWindow
    $owner.AssignHandle((New-Object Windows.Interop.WindowInteropHelper $win).Handle)
    try { $ok = $dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK }
    finally { $owner.ReleaseHandle() }
    if (-not $ok) { Flash ("{0}: no folder chosen" -f $C.topic); return $null }
    $dir = $dlg.SelectedPath; $how = 'cwd-picked'
  }
  $C.cwd = $dir
  Pk-Log-Parked $how $C
  Pk-Stamp-Cwd $C $dir
  return $dir
}

# A terminal in the project directory, already running it. Windows Terminal when
# it is there, because a bare conhost window is a worse place to hold a session
# for an hour; plain cmd otherwise, which is always there.
#
# cmd.exe rather than powershell as the inner shell on purpose: on PATH the
# launcher is claude.cmd, and cmd finds it without the ExecutionPolicy question
# claude.ps1 would raise on a locked-down machine.
function Pk-Unpark-Row {
  $c = Pk-Selected-Row
  if (-not $c) { Flash 'nothing selected'; return }
  if (-not $c.cwd -and -not (Pk-Resolve-Cwd $c)) { return }
  if (-not (Test-Path $c.cwd)) {
    Flash ("{0}: {1} is not there any more" -f $c.topic, $c.cwd)
    Pk-Log-Parked 'resume-nocwd' $c
    return
  }
  if ([int]$c.alive -eq 1) {
    # Not refused - you may well mean it, and the panel does not get to decide
    # that. Said out loud, because the cost of doing it by accident is two
    # windows on one strand and no way to merge them.
    Flash ("{0}: that window is STILL OPEN - resuming makes a second one. Press enter again if you mean it." -f $c.topic)
    if ($script:PkArmedOpen -ne $c.file) { $script:PkArmedOpen = $c.file; Pk-Log-Parked 'resume-armed' $c; return }
  }
  $script:PkArmedOpen = ''
  # Through the shim, never `claude` directly: a session started from this
  # widget would otherwise inherit CLAUDE_CODE_CHILD_SESSION and come up with
  # transcript saving off and no sessions/<pid>.json - silently unmeasurable.
  # token-unpark-launch.cmd strips the markers in the new console. Falls back to
  # a bare launch if the shim has gone missing: a polluted session beats none.
  $shim = Join-Path $Root 'token-unpark-launch.cmd'
  if (Test-Path $shim) {
    $inner = '"{0}"{1} "{2}"' -f $shim, (Pk-Resume-Flags $c), (Pk-Resume-Args $c)
  } else {
    $inner = 'claude{0} "{1}"' -f (Pk-Resume-Flags $c), (Pk-Resume-Args $c)
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
    Pk-Log-Parked 'resume' $c
  } catch {
    Flash ("could not open a terminal: {0}" -f $_.Exception.Message)
    Pk-Log-Parked 'resume-failed' $c
  }
}

function Pk-Copy-Resume {
  $c = Pk-Selected-Row
  if (-not $c) { return }
  $cmd = 'cd "{0}" && claude{1} "{2}"' -f $c.cwd, (Pk-Resume-Flags $c), (Pk-Resume-Args $c)
  try { [System.Windows.Clipboard]::SetText($cmd); Pk-Log-Parked 'copy' $c; Flash ("copied: claude{0} ""{1}""" -f (Pk-Resume-Flags $c), (Pk-Resume-Args $c)) }
  catch { Flash 'could not reach the clipboard' }
}

function Pk-Open-Checkpoint {
  $c = Pk-Selected-Row
  if (-not $c) { return }
  if (-not (Test-Path $c.path)) { Flash 'the checkpoint file is gone'; return }
  try { Start-Process $c.path; Pk-Log-Parked 'open-file' $c; Flash ("opened {0}" -f $c.file) }
  catch { Flash 'nothing is registered to open a .md file' }
}

function Pk-Open-Folder {
  $c = Pk-Selected-Row
  if (-not $c) { return }
  if ($c.cwd -and (Test-Path $c.cwd)) { Start-Process explorer.exe $c.cwd; Pk-Log-Parked 'open-folder' $c; Flash ("opened {0}" -f $c.project) }
}

# Twice, on the same row. A checkpoint is the only record of where that work
# stood - measured re-derivation without one is ~34k tokens against ~5k with -
# so deleting one by a mistyped key is the most expensive keystroke in either
# panel. The armed row is cleared by moving, refreshing, or pressing anything
# else, so the two presses have to be deliberate and consecutive.
function Pk-Delete-Checkpoint {
  $c = Pk-Selected-Row
  if (-not $c) { return }
  if ($script:PkArmedDelete -ne $c.file) {
    $script:PkArmedDelete = $c.file
    Flash ("x again to delete {0} - this is the only record of that work" -f $c.topic)
    return
  }
  $script:PkArmedDelete = ''
  $sh = ([string]$c.path -replace '\\', '/') -replace '^C:', '/c'
  Start-Bg ("rm -f '$sh'")
  # Dropped from the list at once rather than waiting for the next collect: a
  # row that survives the keystroke that deleted it reads as a key that did not
  # take, and the second press would then land on something else.
  $script:PkData.checkpoints = @($script:PkData.checkpoints | Where-Object { $_.file -ne $c.file })
  if ($script:PkSel -gt @($script:PkData.checkpoints).Count) { $script:PkSel = @($script:PkData.checkpoints).Count }
  Pk-Update-View
  Flash ("deleted {0}" -f $c.file)
}

# --- drawing -----------------------------------------------------------------
function Pk-Show-Loading {
  $el.PkRows.Children.Clear()
  $sp = New-Object Windows.Controls.StackPanel
  $sp.Margin = '14,22,14,22'; $sp.HorizontalAlignment = 'Center'
  $t1 = Text-Block 'reading checkpoints' 11 $Pal.text 'Segoe UI'
  $t1.HorizontalAlignment = 'Center'
  $sp.Children.Add($t1) | Out-Null
  $t2 = Text-Block 'one directory and two side tables - no session is measured for this' 9 $Pal.faint 'Segoe UI'
  $t2.TextWrapping = 'Wrap'; $t2.TextAlignment = 'Center'; $t2.Margin = '0,7,0,0'; $t2.MaxWidth = 300
  $sp.Children.Add($t2) | Out-Null
  $el.PkRows.Children.Add($sp) | Out-Null
  if ($el.PkLegend.Children.Count -eq 0) { Pk-Build-Legend; Pk-Build-Keys }
}

function Pk-Draw-Rows {
  $el.PkRows.Children.Clear()
  $script:PkVisible = Pk-Get-Visible
  $n = $script:PkVisible.Count
  if ($script:PkSel -gt $n) { $script:PkSel = $n }
  if ($n -eq 0) {
    $t = Text-Block 'nothing parked' 10 $Pal.faint
    $t.Margin = '14,8,14,8'
    Tip $t 'no checkpoints on disk. /park writes one - task in flight, file:line state, verified vs assumed, next step - and it is what makes ending a session the cheap option.'
    $el.PkRows.Children.Add($t) | Out-Null
    return
  }
  $stale = [double]$(if ($script:PkData.stale_after) { $script:PkData.stale_after } else { 15 })
  $anySel = ($script:PkSel -gt 0 -and $script:PkSel -le $n)
  for ($i = 0; $i -lt $n; $i++) {
    $c = $script:PkVisible[$i]
    $isSel = ($script:PkSel -eq $i + 1)
    $row = Pk-New-Row $c $stale $isSel ($anySel -and -not $isSel)
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
        $script:PkSel = $ix; Pk-Update-View; Pk-Unpark-Row; return
      }
      $script:PkSel = $(if ($script:PkSel -eq $ix) { 0 } else { $ix })
      $script:PkArmedDelete = ''; $script:PkArmedOpen = ''
      Pk-Update-View })
    $el.PkRows.Children.Add($row) | Out-Null
  }
  if ($script:PkSel -gt 0 -and $script:PkSel -le $el.PkRows.Children.Count) {
    $el.PkRows.UpdateLayout()
    $el.PkRows.Children[$script:PkSel - 1].BringIntoView()
  }
}

function Pk-Update-View {
  if (-not $script:PkData) { Pk-Show-Loading; Apply-Chrome; return }
  if ($el.PkLegend.Children.Count -eq 0) { Pk-Build-Legend; Pk-Build-Keys }
  Pk-Draw-Rows
  $all = @($script:PkData.checkpoints)
  $n = $all.Count
  $stale = [double]$(if ($script:PkData.stale_after) { $script:PkData.stale_after } else { 15 })
  # The header counts what is worth acting on rather than what exists. A total
  # says how full the directory is; "3 ready" says how many strands you could
  # pick up right now, which is the question the panel is open for.
  $ready = @($all | Where-Object { (Pk-State-Of $_ $stale).key -eq 'ready' }).Count
  $open  = @($all | Where-Object { [int]$_.alive -eq 1 }).Count
  $el.PkCount.Text = $(if ($n -eq 0) { '' } else { '{0} of {1}' -f $ready, $n })
  Tip $el.PkCount $(if ($n -eq 0) { 'nothing parked' } else {
    "{0} checkpoint{1} on disk, {2} ready to pick up{3}. The rest are either behind the work that followed them or belong to a window that is still open." -f `
      $n, $(if ($n -eq 1) { '' } else { 's' }), $ready, $(if ($open) { ", $open still open" } else { '' }) })
  # The dot is the panel's own state light: blue while there is something ready,
  # faint when the directory is empty or everything in it needs a decision first.
  $el.PkDot.Foreground = (Br $(if ($ready -gt 0) { $Pal.blue } elseif ($n -gt 0) { $Pal.orange } else { $Pal.faint }))
  Apply-Chrome
}


# --- keys and the clock ------------------------------------------------------
# The widget's Handle-Key offers every key here first while this tab is showing.
# A key taken is marked Handled; one left alone goes back to the widget, which
# owns the window keys (f p l ? + - 0 q) and esc once there is no selection to
# let go of.
function Pk-Handle-Key {
  param($e)
  $k = $e.Key.ToString()
  $shift = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0
  $n = $script:PkVisible.Count

  # Anything that is not a second x disarms the delete, and anything that is not
  # a second enter disarms the open-window warning. Done here, once, rather than
  # in every branch - a confirmation that survives an unrelated keystroke is not
  # a confirmation.
  if ($k -ne 'X') { $script:PkArmedDelete = '' }
  if ($k -ne 'Return') { $script:PkArmedOpen = '' }

  $e.Handled = $true
  if ($k -match '^(D|NumPad)([1-9])$') {
    $i = [int]$Matches[2]
    if ($i -le $n) { $script:PkSel = $(if ($script:PkSel -eq $i) { 0 } else { $i }); Pk-Update-View }
    return
  }

  switch ($k) {
    'Down'   { if ($n) { $script:PkSel = [math]::Min($n, $script:PkSel + 1); Pk-Update-View }; return }
    'Up'     { if ($n) { $script:PkSel = [math]::Max(1, $script:PkSel - 1); Pk-Update-View }; return }
    'J'      { if ($n) { $script:PkSel = [math]::Min($n, $script:PkSel + 1); Pk-Update-View }; return }
    'K'      { if ($n) { $script:PkSel = [math]::Max(1, $script:PkSel - 1); Pk-Update-View }; return }
    'G'      { if ($shift) { $script:PkSel = $n } elseif ($n) { $script:PkSel = 1 }
               Pk-Update-View; return }
    'Escape' { if ($script:PkSel) { $script:PkSel = 0; Pk-Update-View; return }; break }
    'Return' { if (-not $script:PkSel -and $n) { $script:PkSel = 1; Pk-Update-View }
               Pk-Unpark-Row; return }
    'Y'      { if (-not $script:PkSel -and $n) { $script:PkSel = 1; Pk-Update-View }
               Pk-Copy-Resume; return }
    'O'      { if (-not $script:PkSel -and $n) { $script:PkSel = 1; Pk-Update-View }
               Pk-Open-Checkpoint; return }
    'E'      { if (-not $script:PkSel -and $n) { $script:PkSel = 1; Pk-Update-View }
               Pk-Open-Folder; return }
    'X'      { if (-not $script:PkSel) { Flash 'select a row first'; return }
               Pk-Delete-Checkpoint; return }
    'R'      { $script:PkLeft = $PkEvery; Pk-Start-Collect; Flash 're-reading the checkpoint directory'; return }
  }
  $e.Handled = $false
}

# One step of the widget's 1Hz timer. The listing is re-read on its own clock
# whichever tab is showing, so the count on the tab title stays true while the
# sessions are what you are looking at.
function Pk-Tick {
  Pk-Poll-Collect
  $script:PkLeft--
  if ($script:PkLeft -le 0) { $script:PkLeft = $PkEvery; Pk-Start-Collect }
}
