# Fresh-session handoff (session-hygiene item 0, 2026-09-23): after Claude has written
# the checkpoint, open a NEW terminal running claude "/unpark <topic>" - the same launch
# token-parked.ps1 does on Enter (shim, Windows Terminal, cmd /k). Nothing is typed into
# the old session; the user closes that window. The old session is set to --extend 0 so
# the renewal sweep leaves it to lapse instead of paying to keep it warm.
param(
  [Parameter(Mandatory = $true)][string]$Topic,
  [string]$Cwd = (Get-Location).Path,
  [string]$OldSid = '',
  [string]$Model = '',
  [string]$Effort = ''
)
$cl  = Join-Path $env:USERPROFILE '.claude'
$log = Join-Path $cl 'token-handoff.log'
function Log($m) { Add-Content -Path $log -Value ("{0} unpark-new {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) }

if (-not (Test-Path (Join-Path $cl "checkpoints\*.$Topic.md"))) { Log "no checkpoint for '$Topic' - abort"; Write-Output "no checkpoint for $Topic"; exit 2 }
if (-not (Test-Path $Cwd)) { Log "no dir $Cwd - abort"; Write-Output "no dir $Cwd"; exit 2 }

$flags = ''
if ($Model)  { $flags += " --model $Model" }
if ($Effort) { $flags += " --effort $Effort" }
$shim  = Join-Path $cl 'token-unpark-launch.cmd'
$inner = if (Test-Path $shim) { '"{0}"{1} "/unpark {2}"' -f $shim, $flags, $Topic } else { 'claude{0} "/unpark {1}"' -f $flags, $Topic }

$wt = Get-Command wt.exe -ErrorAction SilentlyContinue
if ($wt) { Start-Process -FilePath $wt.Source -ArgumentList @('-d', $Cwd, 'cmd.exe', '/k', $inner) | Out-Null }
else     { Start-Process -FilePath 'cmd.exe' -ArgumentList @('/k', $inner) -WorkingDirectory $Cwd | Out-Null }
Log "opened /unpark $Topic in $Cwd (old $OldSid)"

if ($OldSid) {
  # bash is not on PowerShell's PATH here; Git Bash's own is the one token-sessions.sh wants.
  $bash = (Get-Command bash -ErrorAction SilentlyContinue).Source
  if (-not $bash) { $bash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe' }
  $out = & $bash (Join-Path $cl 'token-sessions.sh') --extend $OldSid 0 2>&1
  Log ("old session {0} --extend 0 exit={1} {2}" -f $OldSid, $LASTEXITCODE, (($out | Out-String).Trim() -replace "`r?`n", ' | '))
}
Write-Output "opened a new window: /unpark $Topic in $Cwd - close the old one"
