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

# Straight Win32 rather than WMI: a Win32_Process query costs ~0.3 s, and this
# runs on the widget's UI thread. Compiled once per process (~0.25 s).
#
# Why the console windows. Windows Terminal runs every window from ONE process,
# so focusing by pid lands on whichever window it likes. Each tab's pseudo-
# console window is owned by the WT window holding it, and reports the tab's
# first process (the shell, or claude itself) as its pid; a classic conhost
# window does the same and is its own root. Which TAB is not reachable.
# The widget warms this on a background runspace at startup; a keypress that
# lands mid-compile loses the race to add the type, which is not an error.
function Add-TokenOpenWin {
  if ('TokenOpen.Win' -as [type]) { return }
  try { Add-TokenOpenType } catch { if (-not ('TokenOpen.Win' -as [type])) { throw } }
}
function Add-TokenOpenType {
  Add-Type -Namespace TokenOpen -Name Win -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] struct PBI { public System.IntPtr R1, Peb, R2a, R2b, Pid, Parent; }
[DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(System.IntPtr h, int cls, ref PBI pbi, int len, out int ret);
[DllImport("kernel32.dll")] static extern System.IntPtr OpenProcess(int access, bool inherit, int pid);
[DllImport("kernel32.dll")] static extern bool CloseHandle(System.IntPtr h);
delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[DllImport("user32.dll")] static extern bool EnumWindows(EnumProc f, System.IntPtr l);
[DllImport("user32.dll")] static extern int GetWindowThreadProcessId(System.IntPtr h, out int pid);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] static extern System.IntPtr GetAncestor(System.IntPtr h, int flags);
[DllImport("user32.dll")] static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] static extern bool IsIconic(System.IntPtr h);
[DllImport("user32.dll")] static extern bool ShowWindow(System.IntPtr h, int cmd);
[DllImport("user32.dll")] static extern bool SetForegroundWindow(System.IntPtr h);

public static int ParentPid(int pid) {
  var h = OpenProcess(0x1000, false, pid);  // PROCESS_QUERY_LIMITED_INFORMATION
  if (h == System.IntPtr.Zero) return 0;
  try { var p = new PBI(); int r; return NtQueryInformationProcess(h, 0, ref p, Marshal.SizeOf(p), out r) == 0 ? (int)p.Parent : 0; }
  finally { CloseHandle(h); }
}

// The visible root of the first console window owned by a pid in chain, nearest first.
public static System.IntPtr ConsoleRoot(int[] chain) {
  var byPid = new System.Collections.Generic.Dictionary<int, System.IntPtr>();
  EnumWindows((w, l) => {
    var c = new System.Text.StringBuilder(32); GetClassName(w, c, 32);
    if (c.ToString() == "PseudoConsoleWindow" || c.ToString() == "ConsoleWindowClass") {
      int p; GetWindowThreadProcessId(w, out p); if (!byPid.ContainsKey(p)) byPid[p] = w;
    }
    return true;
  }, System.IntPtr.Zero);
  foreach (var pid in chain) {
    System.IntPtr w;
    if (!byPid.TryGetValue(pid, out w)) continue;
    var r = GetAncestor(w, 3);  // GA_ROOTOWNER
    return IsWindowVisible(r) ? r : System.IntPtr.Zero;  // an IDE terminal's is hidden and unowned
  }
  return System.IntPtr.Zero;
}

public static bool Focus(System.IntPtr h) {
  if (IsIconic(h)) ShowWindow(h, 9);  // SW_RESTORE
  return SetForegroundWindow(h);
}
'@
}

# Walks up from the claude process to whatever holds it. A CLI in a terminal
# owns no window; its shell's parent (Windows Terminal, conhost, VS Code) does.
# A parent younger than its child is a recycled pid, not the real parent, and
# the walk stops there rather than focusing a stranger.
function Find-SessionHost([int]$ProcessId) {
  Add-TokenOpenWin
  $q = $ProcessId; $born = [datetime]::MaxValue; $chain = @()
  for ($i = 0; $i -lt 8 -and $q -gt 0; $i++) {
    $p = Get-Process -Id $q -ErrorAction SilentlyContinue
    if (-not $p) { break }
    $start = try { $p.StartTime } catch { $null }
    if ($start -and $start -gt $born) { break }
    $chain += $q
    if ($p.ProcessName -eq 'TokenChat.App') { return @{ kind = 'chat'; pid = $q; name = 'TokenChat'; chain = $chain } }
    if ($p.MainWindowHandle -ne 0) { return @{ kind = 'window'; pid = $q; name = $p.ProcessName; chain = $chain } }
    if ($start) { $born = $start }
    $q = [TokenOpen.Win]::ParentPid($q)
  }
  @{ kind = 'none'; pid = 0; name = ''; chain = $chain }
}

function Start-TokenChat([string]$Sid, [string]$Cwd) {
  $exe = Find-TokenChat
  if (-not $exe) { return 'TokenChat not found - build windows/token-chat or set TOKEN_CHAT_EXE' }
  # Quoted for spaces; a trailing \ doubled so "C:\" does not escape its own quote.
  Start-Process -FilePath $exe -ArgumentList @('--resume', $Sid, ('"{0}"' -f ($Cwd -replace '\\$', '\\'))) | Out-Null
  $null
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
      $w = [TokenOpen.Win]::ConsoleRoot([int[]]$h.chain)
      if ($w -ne [IntPtr]::Zero) {
        if ([TokenOpen.Win]::Focus($w)) { return "focused the terminal holding $s8" }
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

if ($MyInvocation.InvocationName -ne '.' -and $args.Count -ge 2) {
  $pidArg = 0; $aliveArg = 0
  if ($args.Count -ge 3) { [void][int]::TryParse([string]$args[2], [ref]$pidArg) }
  if ($args.Count -ge 4) { [void][int]::TryParse([string]$args[3], [ref]$aliveArg) }
  Open-Session ([string]$args[0]) ([string]$args[1]) $pidArg $aliveArg
}
