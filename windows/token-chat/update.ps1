# TokenChat's update and restart, run by the app (Updater.cs) through WMI once every tab is idle and the restore
# manifest is written: wait for the app to exit, [-Pull: git pull --ff-only + install.sh], rebuild bin/Debug, then
# relaunch with --restore so every tab reopens. Whatever fails, the relaunch still happens - on the previous build if
# the new one did not compile - so the sessions always come back. The outcome goes to the relaunched app through
# ~/.claude/tokenchat-update-result.txt (first line "ok ..." or what failed). Log: %TEMP%\tokenchat-update.log.
param([string]$Repo, [int]$AppPid, [string]$Manifest, [switch]$Pull)
$log = Join-Path $env:TEMP 'tokenchat-update.log'
$result = Join-Path $env:USERPROFILE '.claude\tokenchat-update-result.txt'
function Log($m) { Add-Content -Path $log -Value ("{0:s}  {1}" -f (Get-Date), $m) }
Set-Content -Path $log -Value ''
Log "repo $Repo, app pid $AppPid, manifest $Manifest, pull $Pull"
$problems = @()
$app = Join-Path $Repo 'windows\token-chat'
$exe = Join-Path $app 'src\TokenChat.App\bin\Debug\net10.0-windows\TokenChat.App.exe'

# the app closes its tabs (each claude.exe tree killed) and exits; give it a minute, then make sure
$p = Get-Process -Id $AppPid -ErrorAction SilentlyContinue
if ($p -and -not $p.WaitForExit(60000)) {
  Log 'app still running after 60 s - stopping it'
  Stop-Process -Id $AppPid -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
}
Log 'app exited'

$git = (Get-Command git -ErrorAction SilentlyContinue).Source
$bash = @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe", "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe") |
  Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $git -and $bash) { $git = Join-Path (Split-Path $bash) 'git.exe' }

$pulled = $false
if ($Pull) {
  $env:GIT_TERMINAL_PROMPT = '0'
  $out = & $git -C $Repo pull --ff-only 2>&1
  Log "git pull (exit $LASTEXITCODE): $($out -join ' / ')"
  if ($LASTEXITCODE -ne 0) { $problems += "git pull failed - nothing was installed or rebuilt:`n$($out | Select-Object -Last 3 | Out-String)" }
  else {
    $pulled = $true
    if (-not $bash) { $problems += 'Git Bash not found - install.sh did not run' }
    else {
      $out = & $bash -lc 'bash "$1" 2>&1' install (($Repo -replace '\\', '/') + '/install.sh')
      Log "install.sh (exit $LASTEXITCODE): $(($out | Where-Object { $_ -match '^\s*(backup|copy|link|would)' }) -join ' / ')"
      if ($LASTEXITCODE -ne 0) { $problems += "install.sh failed (exit $LASTEXITCODE):`n$($out | Select-Object -Last 5 | Out-String)" }
    }
  }
}

# a failed pull leaves the sources as they were: the existing build is still theirs
if (-not $Pull -or $pulled) {
  $dotnet = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
  if (-not (Test-Path $dotnet)) { $dotnet = 'dotnet' }
  $out = & $dotnet build (Join-Path $app 'src\TokenChat.App') -c Debug -nologo -v q 2>&1
  Log "build (exit $LASTEXITCODE): $(($out | Select-Object -Last 4) -join ' / ')"
  if ($LASTEXITCODE -ne 0) {
    $errs = $out | Where-Object { $_ -match ' error ' } | Select-Object -First 3
    $problems += "the build failed - this is the previous build:`n$($errs | Out-String)"
  }
}

$head = if ($git) { (& $git -C $Repo log -1 --format='%h %s' 2>$null) } else { '' }
$verb = if ($Pull) { 'updated to' } else { 'rebuilt at' }
$text = if ($problems.Count -eq 0) { "ok: $verb $head" } else { ($problems -join "`n") + "`nLog: $log" }
Set-Content -Path $result -Value $text -Encoding utf8
Log "result: $($text -split "`n" | Select-Object -First 1)"

if (-not (Test-Path $exe)) {
  Log "no exe at $exe - nothing to relaunch; the manifest stays for the next launch"
  (New-Object -ComObject WScript.Shell).Popup("TokenChat could not be relaunched: no build at`n$exe`n`nYour sessions reopen the next time you start it. Log: $log", 0, 'TokenChat update', 48) | Out-Null
  exit 1
}
Start-Process -FilePath $exe -ArgumentList '--restore', ('"{0}"' -f $Manifest) -WorkingDirectory $Repo
Log "launched $exe --restore"
$until = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $until) {
  if (Get-Process TokenChat.App -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 }) { Log 'window up - done'; exit 0 }
  Start-Sleep -Milliseconds 500
}
Log 'no window within 90 s'
(New-Object -ComObject WScript.Shell).Popup("TokenChat did not come back up after the $(if ($Pull) { 'update' } else { 'restart' }).`nStart it from the desktop icon: your sessions reopen then. Log: $log", 0, 'TokenChat update', 48) | Out-Null
exit 1
