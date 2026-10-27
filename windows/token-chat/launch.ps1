# Desktop-icon entry point (through launch.vbs): start TokenChat from bin/Debug, rebuilding it first when any source
# under src/ is newer than the DLL there. The icon used to start bin/Debug directly, so it ran whatever was last
# built into that folder - and builds made while the app runs go to bin/Fresh, because the app locks bin/Debug.
# With an instance already running nothing can be rebuilt; this starts that instance's own exe, which forwards and exits.
# Log: %TEMP%\tokenchat-launch.log, fresh per run.
param([Parameter(ValueFromRemainingArguments)][string[]]$Rest)
$proj = Join-Path $PSScriptRoot 'src\TokenChat.App'
$out  = Join-Path $proj 'bin\Debug\net10.0-windows'
$exe  = Join-Path $out 'TokenChat.App.exe'
$log  = Join-Path $env:TEMP 'tokenchat-launch.log'
function Log($m) { Add-Content -Path $log -Value ("{0:s}  {1}" -f (Get-Date), $m) }
function Warn($m) { Log $m; (New-Object -ComObject WScript.Shell).Popup($m, 0, 'TokenChat launch', 48) | Out-Null }
Set-Content -Path $log -Value ''

$run = Get-Process TokenChat.App -ErrorAction SilentlyContinue | Where-Object Path | Select-Object -First 1
if ($run) {
  Log "running pid $($run.Id) since $($run.StartTime.ToString('s')) from $($run.Path) - forwarding, no build"
  $exe = $run.Path
} else {
  $dll = Join-Path $out 'TokenChat.App.dll'
  $built = if (Test-Path $dll) { (Get-Item $dll).LastWriteTime } else { [datetime]::MinValue }
  $newest = Get-ChildItem (Join-Path $PSScriptRoot 'src') -Recurse -File -Include *.cs, *.xaml, *.csproj, *.props, *.ico, *.png |
    Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $newest) { Warn "no sources found under $PSScriptRoot\src - starting $exe as is" }
  elseif ($newest.LastWriteTime -gt $built) {
    Log "dll $($built.ToString('s')) older than $($newest.FullName) $($newest.LastWriteTime.ToString('s')) - building"
    $b = & dotnet build $proj -c Debug -nologo -v q 2>&1
    $b | ForEach-Object { Log "  $_" }
    if ($LASTEXITCODE -ne 0) { Warn "dotnet build failed (exit $LASTEXITCODE) - starting the previous build. Details: $log" }
    else { Log "built, dll now $((Get-Item $dll).LastWriteTime.ToString('s'))" }
  } else { Log "dll $($built.ToString('s')) is current (newest source $($newest.LastWriteTime.ToString('s')))" }
}

if (-not (Test-Path $exe)) { Warn "no TokenChat.App.exe at $exe"; exit 1 }
$wd = Split-Path (Split-Path $PSScriptRoot)   # the claude-token-tools clone, as the old shortcut had it
if ($Rest) { Start-Process -FilePath $exe -ArgumentList $Rest -WorkingDirectory $wd }
else { Start-Process -FilePath $exe -WorkingDirectory $wd }
Log "started $exe $Rest"
