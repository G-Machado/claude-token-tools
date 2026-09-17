# token-poke.ps1 - type into a Claude session's console without touching the window.
#
# Why this exists. A prompt cache is renewed by the session's OWN next request and
# by nothing else: it is a PREFIX cache, keyed by content, so anything that renders
# a different first tier - claude -p above all - warms its own prefix and leaves the
# target's clock running. Measured 2026-09-02, see token-renew.log and the refusal
# note in token-sessions.sh. The only thing that reliably hits a session's prefix is
# that session sending a message.
#
# So: make it send one. The obvious route is SendKeys, and it is wrong here. A
# Claude session owns no window - claude.exe reports hwnd 0, its parent shell too,
# and the only real window belongs to WindowsTerminal, which hosts every tab in one
# hwnd. Keys sent there land in whatever tab happens to be focused. On this machine
# that is a one-in-three chance of typing into the right session and a two-in-three
# chance of typing into a different one.
#
# The console INPUT BUFFER has none of that ambiguity. Every console client has its
# own, ConPTY included; AttachConsole(pid) reaches the buffer belonging to that
# process, whatever is focused, whatever tab is on top. Nothing is stolen and
# nothing is guessed.
#
# MEASURED 2026-09-02, session ad3ed1b3 at 107k, and it does exactly what the -p
# renewer could not:
#
#   cache_read_input_tokens      107,700    full hit on the interactive prefix
#   cache_creation_input_tokens       40    only the new message written
#   output_tokens                      4    it replied 'ok'
#   cache_left_min                48 -> 60  the clock reset
#
#   ~10,870 input-equivalents, against ~175,500 to let that window lapse. 16x.
#
# The console probe reported mode 0x208 - VIRTUAL_TERMINAL_INPUT | WINDOW_INPUT,
# with line, echo and processed input all off. That is a raw-mode TUI, which is
# the shape where injected records are translated to VT for the client.
#
#   -TargetPid <n> the claude.exe pid, as token-sessions.sh --json reports it
#   -Text <s>     what to type. Omit it and the message is composed from this
#                 session's own state - marks left, size, how close it was to
#                 lapsing - so that when you scroll back to it a week later the
#                 line says why it is there and what it bought. It still asks for
#                 one word back: output is billed at 5x and this message exists to
#                 buy a cache read, not an answer.
#   -Short <id>   the 8-char session id, for reading extension marks. Derived
#                 from sessions/<pid>.json when omitted.
#   -ContextK <n> / -CacheLeftMin <n>   what the caller already knows, folded
#                 into the message. Left out of it when not supplied.
#   -Probe        attach, report what it found, write nothing. Run this first.
#   -NoEnter      leave the line uncommitted - types it and does not send.
#   -TypeMode     split (default) / keys / burst - how the bytes are handed over.
#   -EnterDelayMs how long to wait before the CR. 300 by default.
#
# MEASURED AGAIN 2026-09-03, and the first measurement above was luck. A poke on
# session f045a9c0 at 67k reported POKE ok and produced no cycle at all - no row
# in token-history.csv, the window lapsed, and the log said it had worked. The
# rig in tests/poke-l1.sh shows why: the whole line and its CR left as ONE
# WriteConsoleInput call and arrived at the far end as ONE 86-byte read. Claude
# Code is Ink on a raw stdin and a multi-character read is a PASTE, where a CR
# inserts a newline in the prompt box instead of submitting it. The line was
# typed, correctly, into a box nobody pressed Enter on.
param(
  [Parameter(Mandatory = $true)][int]$TargetPid,
  [string]$Text = '',
  [string]$Short = '',
  [int]$ContextK = -1,
  [int]$CacheLeftMin = -1,
  [switch]$Probe,
  [switch]$NoEnter,
  [switch]$Force,
  # Do not lose a window to a line somebody forgot to send.
  #
  # Two different things can be in the way, and the old refusal treated only the
  # first as existing:
  #   pending input events - characters typed and not yet read by claude. Drained
  #     here, held, and written back after the renewal has been submitted, so they
  #     land in a fresh prompt box instead of on the end of ours.
  #   text already in the prompt box - the forgotten half-sentence. It is not in
  #     the input buffer at all, so nothing detected it: the renewal appended
  #     itself to that line and sent BOTH. Scraped off the screen buffer, cleared
  #     with Ctrl+E then Ctrl+U, and typed back afterwards WITHOUT an Enter.
  # Restoring is never guessed at: the box is re-read after the clear, and the
  # draft only goes home if it verifiably emptied.
  # A box that will not clear no longer costs the window. Three tries, then the
  # draft is appended to token-cut/<short>.draft and erased with backspaces -
  # and in that case it is NOT typed back, because a prompt that ignored two
  # readline kills is not one to hand a sentence to. Losing the window is the
  # dearer mistake: a lapse is the whole context at 2x, and when the poke is a
  # /park it is the checkpoint as well. Measured 2026-09-10 - 05604c8b (65k,
  # out of marks, its auto-park skipped) and 36f13208 (85k, a mark still in
  # hand) lapsed three minutes apart, both held up by one unsent sentence.
  [switch]$Preserve,
  # How the characters are handed over. This is not a tuning knob - it is the
  # difference between a renewal and a gap. See the block above WriteConsoleInput.
  #   split (default) the text in one write, a pause, then the CR on its own
  #   keys            one write per character, then a pause, then the CR
  #   burst           text and CR in a single write - the original, kept only so
  #                   the rig can demonstrate the failure it causes
  [ValidateSet('split','keys','burst')][string]$TypeMode = 'split',
  [int]$EnterDelayMs = 300,
  [int]$KeyDelayMs = 8,
  # Send nothing but the Enter. The recovery half of the verification in
  # poke_due: if a line was typed and no request went out, the text is sitting
  # in the prompt box and one more keypress commits it. Costs nothing when the
  # box is empty - Claude Code does not submit an empty prompt.
  [switch]$CrOnly
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ConIn {
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool AttachConsole(uint dwProcessId);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool FreeConsole();
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern IntPtr GetConsoleWindow();
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess,
    uint dwShareMode, IntPtr lpSecurityAttributes, uint dwCreationDisposition,
    uint dwFlagsAndAttributes, IntPtr hTemplateFile);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool CloseHandle(IntPtr hObject);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool GetNumberOfConsoleInputEvents(IntPtr hConsoleInput, out uint n);

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct KEY_EVENT_RECORD {
    public int bKeyDown;
    public ushort wRepeatCount;
    public ushort wVirtualKeyCode;
    public ushort wVirtualScanCode;
    public ushort UnicodeChar;
    public uint dwControlKeyState;
  }
  // The union is 16 bytes wide and the tag sits in the first 2, padded to 4 by
  // the alignment of the int that opens KEY_EVENT_RECORD. Getting this wrong
  // does not fail - it types garbage into someone's session - so it is explicit.
  [StructLayout(LayoutKind.Explicit)]
  public struct INPUT_RECORD {
    [FieldOffset(0)] public ushort EventType;
    [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
  }

  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool WriteConsoleInputW(IntPtr hConsoleInput,
    INPUT_RECORD[] lpBuffer, uint nLength, out uint lpNumberOfEventsWritten);

  // Reading takes the records OUT of the buffer, which is the whole mechanism
  // for -Preserve: hold them while the renewal goes through, then write them
  // back. Only ever called with a count already known to be pending, because
  // this blocks on an empty buffer.
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern bool ReadConsoleInputW(IntPtr hConsoleInput,
    [Out] INPUT_RECORD[] lpBuffer, uint nLength, out uint lpNumberOfEventsRead);

  [StructLayout(LayoutKind.Sequential)]
  public struct COORD { public short X; public short Y; }
  [StructLayout(LayoutKind.Sequential)]
  public struct SMALL_RECT { public short Left; public short Top; public short Right; public short Bottom; }
  [StructLayout(LayoutKind.Sequential)]
  public struct CONSOLE_SCREEN_BUFFER_INFO {
    public COORD dwSize;
    public COORD dwCursorPosition;
    public ushort wAttributes;
    public SMALL_RECT srWindow;
    public COORD dwMaximumWindowSize;
  }

  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool GetConsoleScreenBufferInfo(IntPtr hConsoleOutput,
    out CONSOLE_SCREEN_BUFFER_INFO lpInfo);

  // What is on the screen, which is the only place a line sitting in Claude's
  // prompt box exists - it was consumed from the input buffer the moment it was
  // typed, so nothing on the input side can see it.
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern bool ReadConsoleOutputCharacterW(IntPtr hConsoleOutput,
    [Out] System.Text.StringBuilder lpCharacter, uint nLength, COORD dwReadCoord,
    out uint lpNumberOfCharsRead);
}
'@

$KEY_EVENT     = 1
# Decimal, not 0x80000000: PowerShell parses that hex literal as a signed Int32,
# which overflows negative and will not marshal to the UInt32 CreateFileW wants.
$GENERIC_READ  = [uint32]2147483648
$GENERIC_WRITE = [uint32]1073741824
$FILE_SHARE_RW = 3
$OPEN_EXISTING = 3
$INVALID       = [IntPtr]::new(-1)

function Fail([string]$m) {
  Write-Output "FAIL: $m (win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
  try { [ConIn]::FreeConsole() | Out-Null } catch { }
  exit 1
}

$CL = Split-Path -Parent $MyInvocation.MyCommand.Path

# Extension marks, read from the same table token-sessions.sh writes:
#   sid <TAB> allowed <TAB> used [<TAB> lastx]
# A session with no row is on the default, which is why the file only holds the
# ones that have been changed - and that default has to be the SAME number
# token-sessions.sh uses (EXT_DEFAULT, from TOKEN_EXTEND_DEFAULT), or this line
# contradicts the widget about the window it is typed into. Measured 2026-09-08:
# a session on the default was told "0 of 1 marks left after this" while the
# widget, reading --json, showed two marks in hand and was the one telling the
# truth. Hardcoding it here is what made a raised default invisible in the half
# of the feature a person actually reads.
function Get-Marks([string]$sid) {
  # Tested rather than assumed: `$null -as [int]` is 0 in PowerShell, not $null,
  # so reading the override unguarded gives every no-row session a budget of zero
  # - which reads exactly like a deliberate opt-out and would have been worse
  # than the hardcoded 1 it replaced.
  $def = 2
  if ($env:TOKEN_EXTEND_DEFAULT) {
    $ed = $env:TOKEN_EXTEND_DEFAULT -as [int]
    if ($null -ne $ed -and $ed -ge 0) { $def = $ed }
  }
  $r = @{ allowed = $def; used = 0 }
  if (-not $sid) { return $r }
  $f = Join-Path $CL 'token-extend.tsv'
  if (-not (Test-Path $f)) { return $r }
  foreach ($ln in (Get-Content $f -ErrorAction SilentlyContinue)) {
    $c = $ln -split "`t"
    if ($c.Length -ge 3 -and $c[0] -eq $sid) {
      if ($c[1] -match '^\d+$') { $r.allowed = [int]$c[1] }
      if ($c[2] -match '^\d+$') { $r.used    = [int]$c[2] }
      break
    }
  }
  return $r
}

# The session id, so marks can be looked up without the caller knowing it.
if (-not $Short) {
  $sf = Join-Path $CL ("sessions/{0}.json" -f $TargetPid)
  if (Test-Path $sf) {
    $m = [regex]::Match((Get-Content $sf -Raw), '"sessionId"\s*:\s*"([0-9a-f-]{8})')
    if ($m.Success) { $Short = $m.Groups[1].Value }
  }
}

# Composed rather than fixed, because this line is going to sit in someone's
# transcript for the life of the session. It should say what it bought.
#
# Kept to one short clause per fact on purpose: every token here is context the
# session carries from now on, and is re-read on every later request. A renewal
# that explains itself at length would be charging rent to justify saving it.
if ($CrOnly) { $Text = '' }
elseif (-not $PSBoundParameters.ContainsKey('Text') -or -not $Text) {
  $mk = Get-Marks $Short
  $left = $mk.allowed - $mk.used - 1
  if ($left -lt 0) { $left = 0 }
  $bits = @("{0} of {1} marks left after this" -f $left, $mk.allowed)
  if ($ContextK -ge 0)     { $bits += "{0}k" -f $ContextK }
  if ($CacheLeftMin -ge 0) { $bits += "{0}m from lapsing" -f $CacheLeftMin }
  $Text = "[auto-renew: {0}] reply with only: ok" -f ($bits -join ', ')
}

# The target must still be there, and must be the thing we think it is. A pid on
# Windows is recycled, so a stale one from a cached --json can name something
# else entirely by the time this runs - and this writes keystrokes.
$proc = Get-Process -Id $TargetPid -ErrorAction SilentlyContinue
if (-not $proc) { Write-Output "FAIL: no process $TargetPid"; exit 1 }
if ($proc.ProcessName -ne 'claude') {
  Write-Output "FAIL: pid $TargetPid is $($proc.ProcessName), not claude - refusing to type into it"
  exit 1
}

# Our own console has to go before another can be attached; a process may hold
# exactly one. Nothing after this point can Write-Host - output goes through the
# pipe we were started with, which survives.
[ConIn]::FreeConsole() | Out-Null
if (-not [ConIn]::AttachConsole([uint32]$TargetPid)) {
  Fail "AttachConsole($TargetPid)"
}

$h = [ConIn]::CreateFileW('CONIN$', [uint32]($GENERIC_READ -bor $GENERIC_WRITE), $FILE_SHARE_RW,
                          [IntPtr]::Zero, $OPEN_EXISTING, 0, [IntPtr]::Zero)
if ($h -eq $INVALID) { Fail 'open CONIN$' }

$mode = 0; $pending = 0
[void][ConIn]::GetConsoleMode($h, [ref]$mode)
[void][ConIn]::GetNumberOfConsoleInputEvents($h, [ref]$pending)
$cw = [ConIn]::GetConsoleWindow()

# CONOUT$ on the same attached console. Opened whatever the mode, because the
# probe's job is to report what the prompt box holds - that is the reading that
# has to be trusted before anything is allowed to clear it.
$ho = [ConIn]::CreateFileW('CONOUT$', [uint32]($GENERIC_READ -bor $GENERIC_WRITE), $FILE_SHARE_RW,
                           [IntPtr]::Zero, $OPEN_EXISTING, 0, [IntPtr]::Zero)

# What is in the prompt box, read off the screen buffer.
#
# Claude Code draws its input inside a box, so the row the cursor sits on reads
# something like "> the half-typed line" between two border glyphs. Strip the
# frame and the marker and what is left is exactly what the person typed.
#
# ONE ROW ONLY, on purpose. A wrapped box puts the rest of the line on the rows
# above, Ctrl+U's reach across them is not something this can verify from here,
# and a restore that returns half a sentence is worse than a lapse. A multi-row
# box reports ok = $false and takes the old refusal path.
$BOXCH = @([char]0x2502, [char]0x2503, [char]0x007C, [char]0x2551)   # the frame glyphs, left and right
# The prompt marker, and one space after it if there is one. U+276F is what
# Claude Code actually draws; the rest are the near neighbours a theme might use.
$MARKRE = '^[>' + [char]0x276F + [char]0x203A + [char]0x00BB + [char]0x25B8 + [char]0x25B6 + ']\s?'
function Read-Row([int]$y, [int]$w) {
  $sb = New-Object System.Text.StringBuilder $w
  # [int16], not [short] - PowerShell 5.1 has no such type accelerator, and the
  # failure is a runtime TypeNotFound inside the poke, i.e. at the worst moment.
  $c = New-Object ConIn+COORD; $c.X = 0; $c.Y = [int16]$y
  $n = 0
  if (-not [ConIn]::ReadConsoleOutputCharacterW($ho, $sb, [uint32]$w, $c, [ref]$n)) { return $null }
  return $sb.ToString().Substring(0, [Math]::Min($n, $sb.Length))
}
function Strip-Frame([string]$s) {
  if ($null -eq $s) { return $null }
  $t = $s.TrimEnd()
  if ($t.Length -gt 0 -and $BOXCH -contains $t[$t.Length - 1]) { $t = $t.Substring(0, $t.Length - 1).TrimEnd() }
  $t = $t.TrimStart()
  if ($t.Length -gt 0 -and $BOXCH -contains $t[0]) { $t = $t.Substring(1).TrimStart() }
  return $t
}
function Get-Box {   # -> @{ ok; text; row; why }
  $r = @{ ok = $false; text = ''; row = -1; why = ''; raw = '' }
  if ($ho -eq $INVALID) { $r.why = 'CONOUT$ would not open'; return $r }
  $bi = New-Object ConIn+CONSOLE_SCREEN_BUFFER_INFO
  if (-not [ConIn]::GetConsoleScreenBufferInfo($ho, [ref]$bi)) { $r.why = 'no screen buffer info'; return $r }
  # Found by searching UP from the bottom of the window for the marker, not by
  # trusting the cursor. Measured 2026-09-04: a session mid-turn parked its
  # cursor on a row reading just ">", which the cursor-row version read as an
  # empty prompt box - a false empty is exactly how a renewal gets appended to
  # someone's line. The input box is always within a few rows of the bottom.
  $w = [int]$bi.dwSize.X
  $bot = [int]$bi.srWindow.Bottom
  $y = -1; $line = $null
  for ($i = $bot; $i -ge [Math]::Max(0, $bot - 15); $i--) {
    $cand = Strip-Frame (Read-Row $i $w)
    if ($null -ne $cand -and $cand -match $MARKRE) { $y = $i; $line = $cand; break }
  }
  if ($y -lt 0) { $r.why = "no prompt row in the bottom 16 rows (cursor at $($bi.dwCursorPosition.Y))"; return $r }
  $r.row = $y
  $r.raw = $line
  # The marker is what proves this is the input box and not, say, a permission
  # dialog or a tool's output - which is a line this must never type into.
  #
  # Claude Code draws it as U+276F, not '>'. Measured 2026-09-04: the first
  # version of this accepted ASCII only and reported a perfectly readable
  # "can you read this?" as unreadable. The others are here because the glyph is
  # a theme decision, not a contract, and a marker this misses costs a window.
  $txt = ($line -replace $MARKRE, '')
  # A wrapped box: the row above still has content after its border rather than
  # the top frame. Bail out rather than restore a fragment.
  #
  # "Border" is the whole box-drawing block, not a hand-listed set of glyphs -
  # the first version listed the corners it had thought of, missed U+256E, and
  # called a perfectly ordinary one-line box wrapped.
  if ($txt -ne '' -and $y -gt 0) {
    $above = Strip-Frame (Read-Row ($y - 1) $w)
    if ($above -and $above -notmatch "^[$([char]0x2500)-$([char]0x257F)\s-]*$" -and $above -notmatch $MARKRE) {
      $r.why = 'the box looks wrapped over more than one row'; return $r
    }
  }
  $r.ok = $true; $r.text = $txt
  return $r
}

$box = Get-Box

# Someone half way through typing has characters sitting in this buffer, and
# splicing a renewal into the middle of their line would send whatever the two
# make together. Refuse rather than guess; -Force is for a caller that has
# already established the session is idle.
#
# With -Preserve the events are taken out instead of refused, held here, and
# written back once the renewal is in. One exception: a CR among them means the
# person has just sent something of their own, and their request renews the
# cache for free - put the events back untouched and get out of the way.
$held = $null
if (-not $Probe -and $pending -gt 0 -and -not $Force) {
  if (-not $Preserve) {
    Write-Output "SKIP: $pending input events already pending - someone is typing"
    [void][ConIn]::CloseHandle($h)
    [void][ConIn]::FreeConsole()
    exit 2
  }
  $buf = New-Object 'ConIn+INPUT_RECORD[]' $pending
  $got = 0
  if (-not [ConIn]::ReadConsoleInputW($h, $buf, [uint32]$pending, [ref]$got)) { Fail 'ReadConsoleInput (draining)' }
  $held = $buf[0..([Math]::Max(0, $got - 1))]
  foreach ($rec in $held) {
    if ($rec.EventType -eq $KEY_EVENT -and $rec.KeyEvent.bKeyDown -ne 0 -and $rec.KeyEvent.UnicodeChar -eq 13) {
      $n = 0
      [void][ConIn]::WriteConsoleInputW($h, $held, [uint32]$held.Length, [ref]$n)
      Write-Output "SKIP: an Enter was pending - their own request renews it, nothing to do"
      [void][ConIn]::CloseHandle($h)
      [void][ConIn]::FreeConsole()
      exit 2
    }
  }
  Write-Output "  preserving $got pending input event(s) across the renewal"
}

if ($Probe) {
  # Probe doubles as the dry run: it prints the exact line that would be typed,
  # which is the half worth checking before anything reaches a live session. It
  # also prints what it can see in the prompt box, which is the half of
  # -Preserve that has to be believed before it is allowed to clear anything.
  Write-Output ("PROBE ok: pid {0} attached, CONIN$ open, mode 0x{1:X}, {2} events pending, console hwnd {3}" -f `
                $TargetPid, $mode, $pending, $cw)
  Write-Output ("  short : {0}" -f $(if ($Short) { $Short } else { '(unknown)' }))
  Write-Output ("  would type: {0}" -f $Text)
  Write-Output ("  cursor row: '{0}'" -f $box.raw)
  Write-Output ("  prompt box: {0}" -f $(if ($box.ok) {
    if ($box.text -eq '') { "empty (row $($box.row))" } else { "'$($box.text)' (row $($box.row)) - would be cleared and typed back" }
  } else { "unreadable - $($box.why)" }))
  [void][ConIn]::CloseHandle($h)
  if ($ho -ne $INVALID) { [void][ConIn]::CloseHandle($ho) }
  [void][ConIn]::FreeConsole()
  exit 0
}

# One key-down record per character. Key-up is not sent: a console reads the
# down edge, and sending both doubles every keystroke on clients that watch either.
function New-Recs([char[]]$cs) {
  $a = New-Object 'ConIn+INPUT_RECORD[]' $cs.Length
  for ($i = 0; $i -lt $cs.Length; $i++) {
    $k = New-Object ConIn+KEY_EVENT_RECORD
    $k.bKeyDown = 1
    $k.wRepeatCount = 1
    $k.wVirtualKeyCode = $(if ($cs[$i] -eq "`r") { 0x0D } else { 0 })
    $k.wVirtualScanCode = 0
    $k.UnicodeChar = [uint16][char]$cs[$i]
    $k.dwControlKeyState = 0
    $r = New-Object ConIn+INPUT_RECORD
    $r.EventType = $KEY_EVENT
    $r.KeyEvent = $k
    $a[$i] = $r
  }
  return ,$a
}

$script:Written = 0
$script:Err = 0
function Send-Chars([char[]]$cs) {
  if ($cs.Length -eq 0) { return $true }
  $recs = New-Recs $cs
  $n = 0
  $r = [ConIn]::WriteConsoleInputW($h, $recs, [uint32]$recs.Length, [ref]$n)
  if (-not $r) { $script:Err = [Runtime.InteropServices.Marshal]::GetLastWin32Error() }
  $script:Written += $n
  return $r
}

# One key WITH its virtual-key code, for the one place the encodings differ.
# Measured 2026-09-13 on a live prompt: 0x7F under VK_BACK deletes ONE
# character, while 0x08 - with or without VK_BACK - deletes a whole word.
function Send-Key([uint16]$vk, [uint16]$ch) {
  $k = New-Object ConIn+KEY_EVENT_RECORD
  $k.bKeyDown = 1; $k.wRepeatCount = 1; $k.wVirtualKeyCode = $vk; $k.UnicodeChar = $ch
  $r = New-Object ConIn+INPUT_RECORD
  $r.EventType = $KEY_EVENT; $r.KeyEvent = $k
  $a = New-Object 'ConIn+INPUT_RECORD[]' 1
  $a[0] = $r
  $n = 0
  return [ConIn]::WriteConsoleInputW($h, $a, 1, [ref]$n)
}

# WHY THIS IS SPLIT.
#
# The receiving end is Ink on a raw stdin, and Ink tells a paste from a keypress
# by the SHAPE of the read: several characters in one read is a paste, one
# character is a key. A CR that lands inside a paste inserts a newline into the
# prompt box; a CR that lands on its own submits it. Same bytes, same order,
# opposite outcome - and WriteConsoleInput returns true either way, which is how
# a poke was logged ok while the session sat there with an uncommitted line and
# lapsed. Measured in tests/poke-l1.sh: the shipped single call arrived as one
# 86-byte read.
#
# So the text goes over as text - it may well be read as a paste, which is fine,
# pasted text lands in the box - and then, after a pause long enough that no
# reader can coalesce the two, the CR goes on its own.
# A line already in the box, and the renewal about to be appended to it.
#
# This is the case nothing detected before: those characters were read out of
# the input buffer the moment they were typed, so `pending` is 0 and the old
# code went ahead - typed its line onto the end of someone's half-sentence and
# sent the pair. -Preserve clears the box first and types the line back after;
# without it this now REFUSES, which is the conservative half of the same fix.
#
# Ctrl+U is the kill-to-start every readline-ish input binds, but nothing here
# assumes it worked: the row is read again, and unless the box actually came up
# empty this types nothing at all. A refusal costs a lapse; getting this wrong
# costs someone's unsent line.
$restore = ''
# A box that cannot be read is not a box known to be empty. Refusing here costs
# a lapse; guessing costs someone's unsent line, and the whole point of this
# pass is that the second is the dearer mistake. -Force is the way past it.
if (-not $CrOnly -and -not $box.ok -and -not $Force) {
  Write-Output "SKIP: cannot read the prompt box - $($box.why)"
  [void][ConIn]::CloseHandle($h)
  if ($ho -ne $INVALID) { [void][ConIn]::CloseHandle($ho) }
  [void][ConIn]::FreeConsole()
  exit 2
}
if (-not $CrOnly -and $box.ok -and $box.text -ne '') {
  if (-not $Preserve) {
    Write-Output "SKIP: the prompt box holds '$($box.text)' - a renewal would be sent on the end of it"
    [void][ConIn]::CloseHandle($h)
    if ($ho -ne $INVALID) { [void][ConIn]::CloseHandle($ho) }
    [void][ConIn]::FreeConsole()
    exit 2
  }
  # Ctrl+E first, then Ctrl+U. Ctrl+U is a readline KILL-BACKWARD: with the
  # cursor parked in the middle of a draft it takes the head and leaves the
  # tail, the box reads non-empty, and the whole renewal is abandoned - so the
  # cursor goes to the end of the line before the kill, which costs nothing when
  # it was already there.
  #
  # And it gets more than one go. The box is read back off the console SCREEN
  # BUFFER, so what is being waited for is a TUI repaint, not a keystroke; 250ms
  # was one frame's grace on an idle machine and none at all on a busy one.
  # Three tries at 400ms, re-sending the kill each time, because a miss here is
  # not cosmetic: measured 2026-09-10, it is what lapsed 05604c8b (65k, out of
  # marks, the automatic /park skipped with it) and 36f13208 (85k, a mark still
  # in hand) within three minutes of each other, both with a sentence sitting
  # unsent in the box.
  $after = $null
  for ($try = 1; $try -le 3; $try++) {
    [void](Send-Chars @([char]0x05))        # Ctrl+E - end of line
    [void](Send-Chars @([char]0x15))        # Ctrl+U - kill backward from there
    Start-Sleep -Milliseconds 400
    $after = Get-Box
    if ($after.ok -and $after.text -eq '') { break }
  }
  # A SUGGESTION, not a draft. Claude Code draws a predicted next prompt into
  # the empty box as dim ghost text, and the screen buffer keeps no colour to
  # tell it apart (every cell reads attribute 0x07). There is nothing in the box
  # to kill, so the kills change nothing and this used to refuse: measured
  # 2026-09-13, not one clear in the whole log had ever succeeded, and ea8530a3
  # (110k, a mark in hand) lapsed behind "deleted the repo, continue with install
  # and docs" - a sentence nobody typed.
  #
  # One character settles it: a suggestion is REPLACED by what is typed, a real
  # draft is appended to. Tested live on that window. Asked only when the kills
  # moved nothing at all, so a draft that did answer them never sees the probe,
  # and the probe comes back out with the one-character backspace either way.
  $ghost = $false
  if ($after.ok -and $after.text -eq $box.text) {
    [void](Send-Key 0 ([uint16][char]'q'))
    Start-Sleep -Milliseconds 400
    $g = Get-Box
    [void](Send-Key 0x08 0x7F)
    Start-Sleep -Milliseconds 400
    if ($g.ok -and $g.text -eq 'q') {
      $ghost = $true
      Write-Output "  '$($box.text)' is a prompt suggestion, not a draft - typing over it"
    }
    $after = Get-Box
  }
  # Still in the way. At this point the window is worth more than the sentence
  # blocking it: a lapse costs the whole context at 2x, and when this poke is a
  # park it also loses the checkpoint that was the last thing this window was
  # ever going to do. So the draft is SAVED and then erased outright, rather
  # than the renewal being abandoned to protect it.
  #
  # Backspace rather than a third kill. Ctrl+U is a readline BINDING, and three
  # failed tries are evidence enough that it is not reaching this prompt;
  # backspace is not a binding, it is the key, and the count is known because
  # the box was read. The margin covers a cursor that did not end up where
  # Ctrl+E was supposed to put it.
  $forced = $false
  if (-not $ghost -and (-not $after.ok -or $after.text -ne '')) {
    # The FIRST read, not the latest: a kill that took the head and left the
    # tail would otherwise save only the tail.
    $stuck = $box.text
    $cutd  = Join-Path $env:USERPROFILE '.claude\token-cut'
    $cutf  = Join-Path $cutd ("{0}.draft" -f $(if ($Short) { $Short } else { "pid$TargetPid" }))
    try {
      if (-not (Test-Path $cutd)) { [void](New-Item -ItemType Directory -Path $cutd -Force) }
      # Appended, never overwritten. A window that jams once tends to jam again,
      # and the second draft must not be paid for with the first. Same directory
      # the input block cuts to, different extension - that one owns <sid>.prompt.
      Add-Content -LiteralPath $cutf -Encoding utf8 -Value ("--- {0}  cut to renew {1}`r`n{2}`r`n" -f `
        ([datetime]::Now.ToString('s')), $(if ($Short) { $Short } else { "pid $TargetPid" }), $stuck)
      Write-Output "  draft saved to $cutf"
    } catch {
      Write-Output "WARN: could not save the draft ($($_.Exception.Message)) - erasing it anyway"
    }
    [void](Send-Chars @([char]0x05))        # Ctrl+E, in case the cursor sits mid-line
    [void](Send-Chars ([char[]]([char]0x08) * ($stuck.Length + 8)))
    Start-Sleep -Milliseconds 400
    $after = Get-Box
    if ($after.ok -and $after.text -eq '') {
      $forced = $true
      Write-Output "  erased '$stuck' by hand - it is in the cut file, not in the prompt box"
    }
  }
  if (-not $ghost -and (-not $after.ok -or $after.text -ne '')) {
    Write-Output "SKIP: could not clear the prompt box even by erasing it (still '$($after.text)') - leaving it alone"
    [void][ConIn]::CloseHandle($h)
    if ($ho -ne $INVALID) { [void][ConIn]::CloseHandle($ho) }
    [void][ConIn]::FreeConsole()
    exit 2
  }
  # Nothing is typed back after a forced erase. Restoring is the right courtesy
  # when the box cleared on the first ask - the draft goes home and nobody
  # notices - but here the box has already proved it does not respond to the
  # keys it is sent, and typing a sentence into a prompt that may not be where
  # it looks is how the renewal itself gets appended to somebody's half-written
  # line. The copy on disk is the recovery path, and it is a better one.
  if ($forced -or $ghost) {
    $restore = ''
  } else {
    $restore = $box.text
    Write-Output "  held '$restore' out of the prompt box - typed back, unsent, after the renewal"
  }
}

$ok = $true
$script:Written = 0   # count the renewal only, not the clearing keys before it
$body = $Text.ToCharArray()
if ($CrOnly) { $body = @() }
switch ($TypeMode) {
  'burst' {
    # The original. Kept so the rig can show the failure, not because it works.
    if (-not $NoEnter) { $body += "`r"[0] }
    $ok = Send-Chars $body
  }
  'keys' {
    # Belt and braces: one write per character, so nothing can look like a paste.
    # A reader that is behind can still coalesce them, which is why the CR is
    # separated by a pause regardless of mode.
    foreach ($c in $body) {
      if (-not (Send-Chars @($c))) { $ok = $false; break }
      if ($KeyDelayMs -gt 0) { Start-Sleep -Milliseconds $KeyDelayMs }
    }
    if ($ok -and -not $NoEnter) {
      Start-Sleep -Milliseconds $EnterDelayMs
      $ok = Send-Chars @([char]13)
    }
  }
  default {
    $ok = Send-Chars $body
    if ($ok -and -not $NoEnter) {
      Start-Sleep -Milliseconds $EnterDelayMs
      $ok = Send-Chars @([char]13)
    }
  }
}
$written = $script:Written
$err = $script:Err

# Give it back. The CR has gone, so the session is committing the renewal and
# the box it opens next is empty - which is where this text belongs, still
# unsent. Character by character and never with a CR: whatever they were
# writing stays theirs to send.
#
# Restoring happens even when the typing failed. Holding someone's line and
# then dropping it because a WriteConsoleInput came back false is the one
# outcome this must not have.
if ($restore -ne '' -or $held) {
  Start-Sleep -Milliseconds ([Math]::Max(400, $EnterDelayMs))
  if ($restore -ne '') {
    foreach ($c in $restore.ToCharArray()) {
      if (-not (Send-Chars @($c))) { Write-Output "WARN: could not type back '$restore'"; break }
      if ($KeyDelayMs -gt 0) { Start-Sleep -Milliseconds $KeyDelayMs }
    }
  }
  if ($held) {
    $n = 0
    if (-not [ConIn]::WriteConsoleInputW($h, $held, [uint32]$held.Length, [ref]$n)) {
      Write-Output "WARN: could not put back $($held.Length) pending input event(s)"
    }
  }
}

[void][ConIn]::CloseHandle($h)
if ($ho -ne $INVALID) { [void][ConIn]::CloseHandle($ho) }
[void][ConIn]::FreeConsole()

if (-not $ok) { Write-Output "FAIL: WriteConsoleInput (win32 $err)"; exit 1 }

# One row per poke, so the panel can tell a held window from a worked one.
#
# A log rather than a scan. The alternative is to find these cycles again later
# by matching the prompt text in the transcript, which is both dearer and
# wrong at the edges - a real prompt can quote the sentinel, and a cycle cannot
# be attributed to a prompt by timestamp without guessing. Writing the row at
# the moment the thing happens costs nothing and cannot be misread afterwards.
#
#   ISO8601 <TAB> short <TAB> pid <TAB> kind <TAB> contextK <TAB> marksLeft
#
# kind is renew or park: both are messages this machine put into a session that
# the person at the keyboard did not type, which is the distinction the stats
# care about. Everything else about the cycle - what it cost, what it grew - is
# already in token-history.csv under the same session, keyed by the timestamp.
try {
  $kind = if ($CrOnly) { 'nudge' } elseif ($Text -match '^/park') { 'park' } else { 'renew' }
  $mk2  = Get-Marks $Short
  $lf   = [Math]::Max(0, $mk2.allowed - $mk2.used - 1)
  $row  = "{0}`t{1}`t{2}`t{3}`t{4}`t{5}" -f `
            (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $Short, $TargetPid, $kind, $ContextK, $lf
  Add-Content -Path (Join-Path $CL 'token-poke.log') -Value $row -Encoding utf8
} catch {
  # A poke that lands but cannot be logged is still a poke. Say so and carry on -
  # losing the row costs a mark in the stats, losing the renewal costs 2x.
  Write-Output "WARN: poked but could not write token-poke.log: $($_.Exception.Message)"
}

$expect = $(if ($CrOnly) { 1 } else { $Text.Length + $(if ($NoEnter) { 0 } else { 1 }) })
Write-Output ("POKE ok: wrote {0} of {1} records to pid {2} ({3})" -f $written, $expect, $TargetPid, $TypeMode)
