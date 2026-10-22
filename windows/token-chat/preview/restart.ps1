# Restart TokenChat on a fresh bin/Debug build once every session in it is idle; -Repo is windows/token-chat.
# Launch through WMI, so closing TokenChat (which kills its claude.exe trees) does not take this script with it:
#   Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine =
#     "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"<repo>\preview\restart.ps1`" -Repo `"<repo>`" -Log `"<log>`"" }
param([string]$Repo, [string]$Log)
function Log($m) { Add-Content -Path $Log -Value ("{0:s}  {1}" -f (Get-Date), $m) }
Set-Content -Path $Log -Value ''

$tc = Get-Process TokenChat.App -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $tc) { Log 'TokenChat is not running'; exit 1 }
$sessions = @(Get-CimInstance Win32_Process -Filter "Name='claude.exe' AND ParentProcessId=$($tc.Id)" | ForEach-Object {
  $f = Join-Path $env:USERPROFILE ".claude\sessions\$($_.ProcessId).json"
  if (Test-Path $f) {
    $j = Get-Content $f -Raw | ConvertFrom-Json
    $t = Get-ChildItem (Join-Path $env:USERPROFILE '.claude\projects') -Recurse -Filter "$($j.sessionId).jsonl" | Select-Object -First 1
    [pscustomobject]@{ sid = $j.sessionId; cwd = $j.cwd; transcript = $t.FullName }
  }
})
if ($sessions.Count -eq 0) { Log 'no sessions found under TokenChat - nothing restarted'; exit 1 }
# a session another one took over by /handoff (tokenchat-handoffs.tsv, written by the app) may still be finishing its
# turn out of sight; it comes back as a fold of its successor, not as a tab of its own
$chain = Join-Path $env:USERPROFILE '.claude\tokenchat-handoffs.tsv'
$handed = if (Test-Path $chain) { @(Get-Content $chain | ForEach-Object { ($_ -split "`t")[1] -split ',' }) } else { @() }
$sessions = @($sessions | Where-Object { $handed -notcontains $_.sid })
foreach ($s in $sessions) { Log ("session $($s.sid) $($s.cwd)" + $(if (-not $s.transcript) { ' (no transcript yet - not resumed)' })) }

# idle: the transcript quiet for 20 s and its last turn closed by the stop hooks; a tab with no
# first prompt has no transcript, is idle by definition, and is not resumed
function Test-Idle($s) {
  if (-not $s.transcript) { return $true }
  if (((Get-Date) - (Get-Item $s.transcript).LastWriteTime).TotalSeconds -lt 20) { return $false }
  $last = Get-Content $s.transcript -Tail 40 | ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } |
    Where-Object { $_.type -in 'user', 'assistant', 'system' } | Select-Object -Last 1
  return ($last.type -eq 'system' -and $last.subtype -eq 'stop_hook_summary')
}
$deadline = (Get-Date).AddMinutes(30)
while (@($sessions | Where-Object { -not (Test-Idle $_) }).Count -gt 0) {
  if ((Get-Date) -gt $deadline) { Log 'not all idle within 30 min - restart abandoned, TokenChat left running'; exit 1 }
  Start-Sleep -Seconds 5
}

Log 'all idle; closing TokenChat'
$tc.CloseMainWindow() | Out-Null
if (-not $tc.WaitForExit(30000)) { Log 'TokenChat did not exit within 30 s - restart abandoned'; exit 1 }

Log 'building bin/Debug'
$out = & (Join-Path $env:ProgramFiles 'dotnet\dotnet.exe') build (Join-Path $Repo 'src\TokenChat.App') 2>&1 | Select-Object -Last 4
Log ($out -join ' / ')

# the first launch owns the pipe; the rest forward to it once its window is up
$exe = Join-Path $Repo 'src\TokenChat.App\bin\Debug\net10.0-windows\TokenChat.App.exe'
$resumable = @($sessions | Where-Object { $_.transcript })
if ($resumable.Count -eq 0) {
  Start-Process -FilePath $exe
  Log 'no tab had a transcript; launched a plain window'
}
$first = $true
foreach ($s in $resumable) {
  Start-Process -FilePath $exe -ArgumentList '--resume', $s.sid, ('"{0}"' -f $s.cwd)
  Log "launched --resume $($s.sid)"
  if ($first) {
    $first = $false
    $until = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $until -and -not (Get-Process TokenChat.App -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })) {
      Start-Sleep -Milliseconds 500
    }
    Start-Sleep -Seconds 2
  }
}
Log 'done'
