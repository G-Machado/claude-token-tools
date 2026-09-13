# token-pokewake.ps1 - arm ONE alarm for the next moment a window needs holding.
#
#   .\token-pokewake.ps1 -At <unix seconds>   arm (or move) the alarm
#   .\token-pokewake.ps1 -Remove              disarm it
#   .\token-pokewake.ps1 -Status              what is armed, and whether it can fire
#
# Why this exists. The renewer used to be a blind 3-minute poll, and a poll is
# exactly the thing Windows suspends first: measured 2026-09-11, the machine
# entered standby at 01:10:43 and Task Scheduler recorded TEN missed runs while
# a 164k window with both its extension marks still in hand lapsed at ~01:35.
# The marks were never the failure - nothing was running to spend them.
#
# A wake timer is a different kind of object. Task Scheduler hands it to the
# kernel's timer queue, so it fires at a named instant whether the machine is
# awake or asleep, and WakeToRun brings the machine up to run it. One alarm, set
# for the earliest moment anything is due, replaces the poll entirely.
#
# What makes one alarm enough is that due moments only ever move LATER. A due
# moment is expires_at - 8m; every request a session makes pushes its expires_at
# out another hour, and a brand new session's first due moment is ~52 minutes
# away. So nothing can become due EARLIER than what is already armed - the worst
# case is an alarm that fires, finds the window it was set for has renewed
# itself, and re-arms for later. That costs one wake and nothing else.
#
# Three things it cannot do, all of which the backstop poll in
# token-pokedue-install.ps1 exists to cover:
#   the machine is OFF, or hibernated on hardware that drops timers. Nothing
#     fires; StartWhenAvailable runs it late, at the next boot, by which point
#     the window is cold and the log says so.
#   "Allow wake timers" is disabled in the power plan - see -Status, which reads
#     it. Disabled on battery is the Windows default on a lot of laptops.
#   the re-arm itself failed, which is the one case a chain of self-arming
#     alarms cannot recover from on its own.

param(
  [long]   $At = 0,
  [switch] $Remove,
  [switch] $Status
)

$ErrorActionPreference = 'Stop'
$TaskName = 'ClaudeTokenPokeWake'
$Vbs      = Join-Path $HOME '.claude\token-pokedue.vbs'

# Whether a wake timer can fire at all under the current power plan. The labels
# powercfg prints are localised and the GUIDs are not, so the value is taken
# positionally - the two hex indices at the foot of the block are AC then DC.
# 0 disabled, 1 enabled, 2 important-only (which does NOT include ours).
function Wake-Allowed {
  try {
    $raw = & powercfg /q SCHEME_CURRENT SUB_SLEEP BD3B718A-0680-4D9D-8AB2-E1D2B4AC806D 2>$null
    $hex = @($raw | Select-String -Pattern '0x[0-9a-fA-F]{8}' -AllMatches |
             ForEach-Object { $_.Matches } | ForEach-Object { $_.Value })
    if ($hex.Count -lt 2) { return $null }
    $ac = [Convert]::ToInt32($hex[$hex.Count - 2], 16)
    $dc = [Convert]::ToInt32($hex[$hex.Count - 1], 16)
    return @{ ac = $ac; dc = $dc }
  } catch { return $null }
}

function Show-Status {
  $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if (-not $t) {
    Write-Output "wake: not armed"
  } else {
    $sb = $t.Triggers[0].StartBoundary
    $i  = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    $when = try { [datetime]::Parse($sb) } catch { $null }
    $in = if ($when) { [int]([math]::Round(($when - (Get-Date)).TotalMinutes)) } else { 0 }
    Write-Output ("wake: armed for {0} ({1}m out), wakes the machine: {2}" -f `
                  $(if ($when) { $when.ToString('HH:mm:ss') } else { $sb }), $in, $t.Settings.WakeToRun)
    if ($i) { Write-Output ("      last fired {0}, result {1}" -f $i.LastRunTime, $i.LastTaskResult) }
  }
  $w = Wake-Allowed
  if ($null -eq $w) {
    Write-Output "      power plan: could not read the wake-timer setting"
  } else {
    $lbl = @{ 0 = 'disabled'; 1 = 'enabled'; 2 = 'important only' }
    Write-Output ("      wake timers: AC {0}, battery {1}" -f `
                  $(if ($lbl.ContainsKey($w.ac)) { $lbl[$w.ac] } else { $w.ac }), `
                  $(if ($lbl.ContainsKey($w.dc)) { $lbl[$w.dc] } else { $w.dc }))
    # Only worth shouting about on AC. On battery, a machine that refuses to
    # wake itself every hour is making a defensible choice and this is not the
    # place to argue with it.
    if ($w.ac -ne 1) {
      Write-Output "      WARNING: on AC this alarm cannot wake the machine - powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_SLEEP BD3B718A-0680-4D9D-8AB2-E1D2B4AC806D 1"
    }
  }
}

if ($Status) { Show-Status; return }

if ($Remove) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Write-Output "wake: disarmed - nothing open is worth holding"
  return
}

if ($At -le 0) { throw "token-pokewake: -At takes a unix timestamp" }
if (-not (Test-Path $Vbs)) { throw "missing $Vbs" }

$when = [DateTimeOffset]::FromUnixTimeSeconds($At).LocalDateTime
# A minute of floor. Registering a trigger in the past is legal and fires
# immediately, which turns a re-arm into a tight loop of wakes.
$floor = (Get-Date).AddSeconds(45)
if ($when -lt $floor) { $when = $floor }

# Already set for this instant, to the second. The sweep re-arms on every run,
# and rewriting an identical definition churns the task store for nothing - and
# would do it from INSIDE a run of the very task being rewritten.
$cur = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($cur) {
  $sb = try { [datetime]::Parse($cur.Triggers[0].StartBoundary) } catch { $null }
  if ($sb -and [math]::Abs(($sb - $when).TotalSeconds) -lt 30) {
    Write-Output ("wake: already armed for {0} - left alone" -f $sb.ToString('HH:mm:ss'))
    return
  }
}

$action  = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f $Vbs)
$trigger = New-ScheduledTaskTrigger -Once -At $when
# An end boundary is the PRICE of DeleteExpiredTaskAfter: Task Scheduler refuses
# the pair without it (HRESULT 0x80041319, "unsupported account option", which
# is not what is wrong and cost a registration to find out). Ten minutes past
# the alarm - long enough that StartWhenAvailable can still run it late after a
# boot, short enough that the spent task tidies itself up the same hour.
$trigger.EndBoundary = $when.AddMinutes(10).ToString('yyyy-MM-ddTHH:mm:ss')

# WakeToRun is the whole point and has no parameter on the settings cmdlet.
# StartWhenAvailable is the consolation prize: if the machine was off through
# the alarm, the sweep at least runs on the next boot and LOGS that the window
# went cold, which is the difference between a known loss and a silent one.
$settings = New-ScheduledTaskSettingsSet `
              -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
              -StartWhenAvailable -MultipleInstances IgnoreNew `
              -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -Hidden
$settings.WakeToRun = $true
# One-shot triggers leave the task behind once they have fired. Without this the
# task store slowly fills with spent alarms.
$settings.DeleteExpiredTaskAfter = 'PT2H'

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
  -Settings $settings -Force `
  -Description 'One-shot: wakes the machine to renew the Claude window closest to lapsing' `
  -ErrorAction Stop | Out-Null

Write-Output ("wake: armed for {0} ({1}m out)" -f `
              $when.ToString('HH:mm:ss'), [int]([math]::Round(($when - (Get-Date)).TotalMinutes)))
