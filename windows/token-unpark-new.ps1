# Fresh-session handoff (session-hygiene item 0, 2026-09-23): after Claude has written
# the checkpoint, open a NEW TokenChat tab running "/unpark <topic>" - the same launch
# the widget's Parked tab does on Enter (terminal only if no TokenChat). Nothing is typed into
# the old session; the user closes that window. The old session is set to --extend 0 so
# the renewal sweep leaves it to lapse instead of paying to keep it warm.
param(
  [Parameter(Mandatory = $true)][string]$Topic,
  [string]$Cwd = (Get-Location).Path,
  [string]$OldSid = '',
  [string]$Model = '',
  [string]$Effort = '',
  [ValidateSet('handoff', 'delegate')][string]$Mode = 'handoff',   # delegate: /delegate's worktree tab, parent left live
  [string]$ParentSid = ''   # delegate only: logged, never touched
)
$cl  = Join-Path $env:USERPROFILE '.claude'
$log = Join-Path $cl 'token-handoff.log'
function Log($m) { Add-Content -Path $log -Value ("{0} unpark-new {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) }

if (-not (Test-Path (Join-Path $cl "checkpoints\*.$Topic.md"))) { Log "no checkpoint for '$Topic' - abort"; Write-Output "no checkpoint for $Topic"; exit 2 }
if (-not (Test-Path $Cwd)) { Log "no dir $Cwd - abort"; Write-Output "no dir $Cwd"; exit 2 }

# A TokenChat tab first, the same route as Enter on the widget's Parked tab
# (Open-Unpark): a running instance takes it as a new tab. The terminal is only
# the fallback for a machine with no TokenChat build to find.
. (Join-Path $cl 'token-open.ps1')
$why = Open-Unpark $Cwd "/unpark $Topic --$Mode" $Model $Effort $OldSid
if ($null -eq $why) {
  $where = if ($OldSid) { 'the old session''s TokenChat tab' } else { 'a new TokenChat tab' }
} else {
  $flags = ''
  if ($Model)  { $flags += " --model $Model" }
  if ($Effort) { $flags += " --effort $Effort" }
  $shim  = Join-Path $cl 'token-unpark-launch.cmd'
  $inner = if (Test-Path $shim) { '"{0}"{1} "/unpark {2} --{3}"' -f $shim, $flags, $Topic, $Mode } else { 'claude{0} "/unpark {1} --{2}"' -f $flags, $Topic, $Mode }

  $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
  if ($wt) { Start-Process -FilePath $wt.Source -ArgumentList @('-d', $Cwd, 'cmd.exe', '/k', $inner) | Out-Null }
  else     { Start-Process -FilePath 'cmd.exe' -ArgumentList @('/k', $inner) -WorkingDirectory $Cwd | Out-Null }
  $where = "a new terminal ($why)"
}
Log "opened /unpark $Topic in $Cwd via $where (old $OldSid)"
if ($Mode -eq 'delegate') {
  # Raw events for fact-checking /delegate later (TokenChat's DelegateReport.Log appends report/card/read/dismiss):
  # time, event, topic, parent sid, delegate sid (unknown yet), extra = cwd and the parent's HEAD.
  $head = (& git -C $Cwd rev-parse --short HEAD 2>$null)
  Add-Content -Path (Join-Path $cl 'token-delegate.log') -Value ("{0}`topen`t{1}`t{2}`t`t{3} {4}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Topic, $ParentSid, $Cwd, $head)
}

if ($OldSid) {
  # bash is not on PowerShell's PATH here; Git Bash's own is the one token-sessions.sh wants.
  $bash = (Get-Command bash -ErrorAction SilentlyContinue).Source
  if (-not $bash) { $bash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe' }
  $out = & $bash (Join-Path $cl 'token-sessions.sh') --extend $OldSid 0 2>&1
  Log ("old session {0} --extend 0 exit={1} {2}" -f $OldSid, $LASTEXITCODE, (($out | Out-String).Trim() -replace "`r?`n", ' | '))
}
Write-Output "opened ${where}: /unpark $Topic in $Cwd$(if ($OldSid) { ' - a TokenChat tab holding the old session is taken over; anywhere else, close it' } else { ' - close the old one' })"
