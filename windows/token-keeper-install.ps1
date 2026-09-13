# token-keeper-install.ps1 - register (or remove) the five-hour window keeper
# as a Windows scheduled task.
#
#   .\token-keeper-install.ps1              register, every 15 minutes
#   .\token-keeper-install.ps1 -Every 5     tighter tick, less renewal drift
#   .\token-keeper-install.ps1 -Remove      unregister
#   .\token-keeper-install.ps1 -Status      show the task and the last log rows
#
# It runs as the logged-on user, only while logged on, and only on AC or
# battery alike. It must NOT run in another session: cswap reads the user's
# credential store, so a task running "whether user is logged on or not" would
# find no accounts and log an error every quarter hour.

param(
  [int]    $Every  = 15,
  [switch] $Remove,
  [switch] $Status
)

$ErrorActionPreference = 'Stop'
$TaskName = 'ClaudeTokenWindowKeeper'
$Vbs      = Join-Path $HOME '.claude\token-keeper.vbs'
$Log      = Join-Path $HOME '.claude\token-keeper.log'

function Show-Status {
  $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if (-not $t) { Write-Host "not registered"; return }
  $i = Get-ScheduledTaskInfo -TaskName $TaskName
  Write-Host ("task     : {0}  ({1})" -f $t.TaskName, $t.State)
  Write-Host ("every    : {0}" -f $t.Triggers[0].Repetition.Interval)
  Write-Host ("last run : {0}   result {1}" -f $i.LastRunTime, $i.LastTaskResult)
  Write-Host ("next run : {0}" -f $i.NextRunTime)
  if (Test-Path $Log) {
    Write-Host "`nlast keeper decisions:"
    Get-Content $Log -Tail 8 | ForEach-Object { Write-Host "  $_" }
  }
}

if ($Status) { Show-Status; return }

if ($Remove) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Write-Host "removed $TaskName"
  Write-Host "the keeper can also be stopped without unregistering:  New-Item ~\.claude\token-keeper.off"
  return
}

if (-not (Test-Path $Vbs)) { throw "missing $Vbs" }

$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f $Vbs)

# A repeating trigger with no end. -RepetitionDuration ([TimeSpan]::MaxValue) is
# the obvious spelling and it does not work: it serialises to P99999999DT23H59M59S
# and the scheduler rejects the XML as out of range. Attaching a repetition
# pattern with Duration simply absent is what "run forever" actually looks like.
# Starting one minute out, so registering the task does not fire a ping at once.
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)
$trigger.Repetition = New-CimInstance -ClassName MSFT_TaskRepetitionPattern `
  -Namespace Root/Microsoft/Windows/TaskScheduler -ClientOnly `
  -Property @{ Interval = "PT${Every}M"; StopAtDurationEnd = $false }

$settings = New-ScheduledTaskSettingsSet `
              -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
              -StartWhenAvailable -MultipleInstances IgnoreNew `
              -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -Hidden

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
  -Settings $settings -Description 'Keeps each idle Claude account five-hour window ticking, phased for even resets' `
  -Force -ErrorAction Stop | Out-Null

Write-Host "registered $TaskName - every $Every minutes, while logged on"
Write-Host "  status : .\token-keeper-install.ps1 -Status"
Write-Host "  pause  : New-Item ~\.claude\token-keeper.off"
Write-Host "  remove : .\token-keeper-install.ps1 -Remove"
Show-Status
