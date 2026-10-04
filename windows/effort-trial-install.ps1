# Installs the effort trial: copies effort-trial.js to ~/.claude and registers the EffortTrial task
# (daily 00:01 and at logon, hidden via wscript). -Uninstall removes the task and restores high.
param([switch]$Uninstall)
$dest = "$env:USERPROFILE\.claude"
if ($Uninstall) {
  Unregister-ScheduledTask -TaskName EffortTrial -Confirm:$false -ErrorAction SilentlyContinue
  & 'C:\Program Files\nodejs\node.exe' "$dest\effort-trial.js" --off
  "EffortTrial removed; claude-opus-5-5 back on high"; exit 0
}
Copy-Item "$PSScriptRoot\effort-trial.js" "$dest\effort-trial.js" -Force
# wscript runs node with no console window (same reason as token-pokedue.vbs).
Set-Content "$dest\effort-trial.vbs" -Encoding ascii -Value @'
CreateObject("WScript.Shell").Run """C:\Program Files\nodejs\node.exe"" """ & CreateObject("WScript.Shell").ExpandEnvironmentStrings("%USERPROFILE%") & "\.claude\effort-trial.js""", 0, True
'@
$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$dest\effort-trial.vbs`""
$triggers = @((New-ScheduledTaskTrigger -Daily -At 00:01), (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME))
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
Register-ScheduledTask -TaskName EffortTrial -Action $action -Trigger $triggers -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName EffortTrial
"EffortTrial registered"
