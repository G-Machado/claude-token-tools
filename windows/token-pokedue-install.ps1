# token-pokedue-install.ps1 - register (or remove) the cache renewer as a
# Windows scheduled task.
#
#   .\token-pokedue-install.ps1              register, every 3 minutes
#   .\token-pokedue-install.ps1 -Every 2     tighter tick
#   .\token-pokedue-install.ps1 -Remove      unregister
#   .\token-pokedue-install.ps1 -Status      show the task and the last log rows
#
# What it arms. Every tick, token-sessions.sh --poke-due looks for an open
# window inside the danger zone - 8 minutes or less of prompt cache left - that
# still has an extension mark, is over the 60k floor and is not about to cross
# local midnight. For each one it types a single line into that session's own
# console, which is the only thing that renews a prefix cache: measured on a
# 107k window, read 107,700 / write 40 / output 4, about 10.9k input-equivalents
# against ~175k to let it lapse.
#
# This task is the BACKSTOP now, not the mechanism. The mechanism is a one-shot
# wake timer, re-armed at the end of every sweep for the next moment anything is
# due - see token-pokewake.ps1. A wake timer fires whether the machine is awake
# or asleep, which a repetition trigger flatly does not: measured 2026-09-11,
# standby at 01:10:43 and TEN missed runs while a 164k window with both marks in
# hand lapsed at ~01:35. Three minutes of polling could not have saved it and
# did not.
#
# So the interval stopped being load-bearing and went from 3 minutes to 15. What
# it covers is the three things an alarm cannot: the machine off through the
# armed instant, "Allow wake timers" disabled in the power plan, and a re-arm
# that failed - the one failure a self-arming chain cannot recover from. Each
# sweep re-arms, so a single backstop tick repairs the chain.
#
# It runs as the logged-on user, only while logged on, and it must NOT run in
# another session: AttachConsole reaches the console input buffers of THIS
# desktop only.

param(
  # 15 -> 5 on 2026-09-15: the safe-park's idle rule has to land a tick in the
  # 5-10 minutes between "idle" and "asleep", and the alarm cannot wake this
  # machine on battery. The widget re-installs with this default, so it is the
  # value that sticks.
  [int]    $Every  = 5,
  [switch] $Remove,
  [switch] $Status
)

$ErrorActionPreference = 'Stop'
$TaskName = 'ClaudeTokenPokeDue'
$Vbs      = Join-Path $HOME '.claude\token-pokedue.vbs'
$Log      = Join-Path $HOME '.claude\token-pokedue.log'
$Poke     = Join-Path $HOME '.claude\token-poke.log'

function Show-Status {
  $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if (-not $t) { Write-Host "not registered"; return }
  $i = Get-ScheduledTaskInfo -TaskName $TaskName
  Write-Host ("task     : {0}  ({1})" -f $t.TaskName, $t.State)
  Write-Host ("every    : {0}" -f $t.Triggers[0].Repetition.Interval)
  Write-Host ("last run : {0}   result {1}" -f $i.LastRunTime, $i.LastTaskResult)
  Write-Host ("next run : {0}" -f $i.NextRunTime)
  if (Test-Path $Poke) {
    Write-Host "`nrenewals typed so far:"
    Get-Content $Poke -Tail 6 | ForEach-Object { Write-Host "  $_" }
  }
  if (Test-Path $Log) {
    Write-Host "`nlast scan said:"
    Get-Content $Log -Tail 6 | ForEach-Object { Write-Host "  $_" }
  }
  # The alarm is the thing actually holding a window, so it is reported here
  # rather than in a script of its own that nobody would think to run.
  Write-Host ""
  & (Join-Path $HOME '.claude\token-pokewake.ps1') -Status |
    ForEach-Object { Write-Host "  $_" }
}

if ($Status) { Show-Status; return }

if ($Remove) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  # The alarm goes with it. Leaving a one-shot armed after the backstop has been
  # removed would fire once more, sweep, and re-arm itself forever with nothing
  # left to repair the chain if it ever broke.
  & (Join-Path $HOME '.claude\token-pokewake.ps1') -Remove | ForEach-Object { Write-Host $_ }
  Write-Host "removed $TaskName"
  Write-Host "it can also be stopped without unregistering:  New-Item ~\.claude\token-pokedue.off"
  return
}

if (-not (Test-Path $Vbs)) { throw "missing $Vbs" }

$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f $Vbs)

# Repetition with Duration absent is what "forever" actually looks like here -
# see the note in token-keeper-install.ps1, which learned it the hard way.
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)
$trigger.Repetition = New-CimInstance -ClassName MSFT_TaskRepetitionPattern `
  -Namespace Root/Microsoft/Windows/TaskScheduler -ClientOnly `
  -Property @{ Interval = "PT${Every}M"; StopAtDurationEnd = $false }

$settings = New-ScheduledTaskSettingsSet `
              -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
              -StartWhenAvailable -MultipleInstances IgnoreNew `
              -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -Hidden

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
  -Settings $settings -Description 'Renews a Claude window inside the danger zone by typing into its own console' `
  -Force -ErrorAction Stop | Out-Null

# Arm the first alarm now rather than waiting up to $Every minutes for the
# backstop to do it. The sweep arms as a side effect of running, so this is also
# the install-time smoke test.
Write-Host "`narming the first alarm:"
& 'C:\Program Files\Git\bin\bash.exe' -lc '~/.claude/token-sessions.sh --poke-due' 2>&1 |
  Select-Object -Last 3 | ForEach-Object { Write-Host "  $_" }

Write-Host "`nregistered $TaskName - backstop every $Every minutes, while logged on"
Write-Host "  status : .\token-pokedue-install.ps1 -Status"
Write-Host "  pause  : New-Item ~\.claude\token-pokedue.off"
Write-Host "  remove : .\token-pokedue-install.ps1 -Remove"
Show-Status
