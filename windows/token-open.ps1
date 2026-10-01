# Enter on a session, from wherever it is pressed: the widget's session list or
# the retired --watch pane. One route so the three places cannot drift:
#
#   1. alive inside TokenChat   -> TokenChat --resume, which the running
#                                  instance takes as "focus that tab"
#   2. alive in a terminal/IDE  -> focus the window that holds it
#   3. not alive                -> TokenChat --resume <sid> <cwd>, a new tab
#
# Order matters. A session alive in a terminal must never reach step 3: two
# processes on one transcript is the one outcome nobody can merge afterwards.
# So "alive" with no window anywhere up its parent chain is refused, not resumed.
#
# Dot-sourced by the widget, which flashes what Open-Session returns. Run as a
# script by token-sessions.sh: token-open.ps1 <sid> <cwd> <pid> <alive>, and the
# one line it prints is the pane's flash. Positional rather than a param block,
# because a param block would land $Sid and $Cwd in the widget's own scope.

# The build the running instance came from first, so a forwarded request goes to
# the same exe; then TOKEN_CHAT_EXE; then the newest build in the clone that
# install.sh recorded. There is no published path yet.
function Find-TokenChat {
  $run = Get-Process -Name 'TokenChat.App' -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
  if ($run) { return $run.Path }
  if ($env:TOKEN_CHAT_EXE -and (Test-Path $env:TOKEN_CHAT_EXE)) { return $env:TOKEN_CHAT_EXE }
  $rec = Join-Path $HOME '.claude\token-tools-src'
  if (-not (Test-Path $rec)) { return $null }
  # Written from Git Bash, so it reads /c/Users/...
  $src = ((Get-Content $rec -TotalCount 1) -replace '^/([a-zA-Z])/', '$1:/') -replace '/', '\'
  $bin = Join-Path $src 'windows\token-chat\src\TokenChat.App\bin'
  Get-ChildItem -Path $bin -Filter 'TokenChat.App.exe' -Recurse -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}

# Walks up from the claude process to whatever holds it. A CLI in a terminal
# owns no window; its shell's parent (Windows Terminal, conhost, VS Code) does.
# A parent younger than its child is a recycled pid, not the real parent, and
# the walk stops there rather than focusing a stranger. One process snapshot,
# not a query per level: ~0.4 s against ~0.3 s a level, on the widget's UI thread.
function Find-SessionHost([int]$ProcessId) {
  $tree = @{}
  Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CreationDate -ErrorAction SilentlyContinue |
    ForEach-Object { $tree[[int]$_.ProcessId] = $_ }
  $q = $ProcessId; $born = [datetime]::MaxValue
  for ($i = 0; $i -lt 8 -and $q -gt 0; $i++) {
    $ci = $tree[$q]
    if (-not $ci -or $ci.CreationDate -gt $born) { break }
    if ($ci.Name -eq 'TokenChat.App.exe') { return @{ kind = 'chat'; pid = $q; name = 'TokenChat' } }
    $p = Get-Process -Id $q -ErrorAction SilentlyContinue
    if ($p -and $p.MainWindowHandle -ne 0) { return @{ kind = 'window'; pid = $q; name = $p.ProcessName } }
    $born = $ci.CreationDate; $q = [int]$ci.ParentProcessId
  }
  @{ kind = 'none'; pid = 0; name = '' }
}

function Start-TokenChat([string]$Sid, [string]$Cwd) {
  $exe = Find-TokenChat
  if (-not $exe) { return 'TokenChat not found - build windows/token-chat or set TOKEN_CHAT_EXE' }
  # Quoted for spaces; a trailing \ doubled so "C:\" does not escape its own quote.
  Start-Process -FilePath $exe -ArgumentList @('--resume', $Sid, ('"{0}"' -f ($Cwd -replace '\\$', '\\'))) | Out-Null
  $null
}

$TokenOpenPs1 = $PSCommandPath

function Add-TokenOpenWin {
  if ('TokenOpen.Win' -as [type]) { return }
  Add-Type -Namespace TokenOpen -Name Win -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern bool FreeConsole();
[DllImport("kernel32.dll")] public static extern bool AttachConsole(int pid);
[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern System.IntPtr GetAncestor(System.IntPtr h, int flags);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
'@
}

# The window a console session is drawn in. Windows Terminal runs every window
# from ONE process, so focusing by pid lands on whichever window it likes; the
# session's own console does know. Its pseudo-console window is owned by the WT
# window holding the tab (a classic conhost window is simply itself), so the
# root owner of GetConsoleWindow() is the answer. Which TAB is not reachable.
#
# AttachConsole means letting go of your own console first, and the widget must
# keep its hidden one - every bash it starts would otherwise pop a visible
# window. So the attach runs in a throwaway copy of this script.
function Get-ConsoleRoot([int]$ProcessId) {
  $o = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $TokenOpenPs1 --console-root $ProcessId 2>$null
  $h = [long]0
  [void][long]::TryParse(([string]($o | Select-Object -Last 1)).Trim(), [ref]$h)
  [IntPtr]$h
}

function Focus-Window([IntPtr]$Handle) {
  Add-TokenOpenWin
  if ([TokenOpen.Win]::IsIconic($Handle)) { [void][TokenOpen.Win]::ShowWindow($Handle, 9) }  # SW_RESTORE
  [TokenOpen.Win]::SetForegroundWindow($Handle)
}

# Returns the line to flash. Never throws: the widget calls it from a key handler.
function Open-Session([string]$Sid, [string]$Cwd, [int]$ProcessId, [int]$Alive) {
  $s8 = if ($Sid.Length -gt 8) { $Sid.Substring(0, 8) } else { $Sid }
  try {
    if (-not $Sid) { return 'nothing selected' }
    if ($Alive -eq 1 -and $ProcessId -gt 0) {
      $h = Find-SessionHost $ProcessId
      if ($h.kind -eq 'chat') { $e = Start-TokenChat $Sid $Cwd; if ($e) { return $e }; return "TokenChat: $s8" }
      # Its own console window first; the ancestor's main window only where the
      # console has none of its own (an IDE terminal), as that one is a guess.
      $w = Get-ConsoleRoot $ProcessId
      if ($w -ne [IntPtr]::Zero) {
        if (Focus-Window $w) { return "focused the terminal holding $s8" }
        return "$s8 is in a terminal window that would not come forward"
      }
      if ($h.kind -eq 'window') {
        if ((New-Object -ComObject WScript.Shell).AppActivate($h.pid)) { return "focused $($h.name): $s8" }
        return "$s8 is open in $($h.name) (pid $($h.pid)) but it would not come forward"
      }
      return "$s8 is alive (pid $ProcessId) with no window to focus - not opening a second copy"
    }
    if (-not $Cwd -or -not (Test-Path $Cwd)) { return "$s8 cannot resume: folder '$Cwd' is not there" }
    $e = Start-TokenChat $Sid $Cwd; if ($e) { return $e }
    "resuming $s8 in TokenChat"
  } catch { "could not open ${s8}: $($_.Exception.Message)" }
}

# The throwaway half of Get-ConsoleRoot: prints the window handle, 0 for none.
if ($MyInvocation.InvocationName -ne '.' -and $args.Count -eq 2 -and $args[0] -eq '--console-root') {
  Add-TokenOpenWin
  $r = [IntPtr]::Zero
  [void][TokenOpen.Win]::FreeConsole()
  if ([TokenOpen.Win]::AttachConsole([int]$args[1])) {
    $c = [TokenOpen.Win]::GetConsoleWindow()
    if ($c -ne [IntPtr]::Zero) { $r = [TokenOpen.Win]::GetAncestor($c, 3) }  # GA_ROOTOWNER
    if ($r -ne [IntPtr]::Zero -and -not [TokenOpen.Win]::IsWindowVisible($r)) { $r = [IntPtr]::Zero }
    [void][TokenOpen.Win]::FreeConsole()
  }
  [Console]::Out.WriteLine($r.ToInt64())
  exit 0
}

if ($MyInvocation.InvocationName -ne '.' -and $args.Count -ge 2) {
  $pidArg = 0; $aliveArg = 0
  if ($args.Count -ge 3) { [void][int]::TryParse([string]$args[2], [ref]$pidArg) }
  if ($args.Count -ge 4) { [void][int]::TryParse([string]$args[3], [ref]$aliveArg) }
  Open-Session ([string]$args[0]) ([string]$args[1]) $pidArg $aliveArg
}
