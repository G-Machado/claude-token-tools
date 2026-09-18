# Create (or remove) the "Claude Widget" desktop shortcut.
#
# The widget is the UI, so the install is not finished until there is something
# to double-click. This is the one thing install.sh cannot do in bash: a .lnk is
# a COM object, not a file you can write.
#
#   token-shortcut.ps1 -Dest C:\Users\you\.claude     create it
#   token-shortcut.ps1 -Dest ... -DryRun              say what it would do
#   token-shortcut.ps1 -Remove                        delete it
#
# The properties match a hand-made shortcut exactly, and each one earns its
# place: wscript rather than powershell, because powershell.exe leaves an empty
# console in the taskbar for the life of the widget (see token-widget.vbs);
# WindowStyle 7 so the host window starts minimised; the icon so the taskbar
# entry is the widget's own rather than a generic script icon.
[CmdletBinding()]
param(
  [string]$Dest = (Join-Path $env:USERPROFILE '.claude'),
  [switch]$Remove,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# GetFolderPath, never "$env:USERPROFILE\Desktop": with OneDrive backup on, the
# real desktop is ~\OneDrive\Desktop and the literal path is a stale empty
# folder, so a shortcut written there never appears.
$desktop = [Environment]::GetFolderPath('Desktop')
if (-not $desktop) { Write-Error 'could not locate the Desktop folder'; exit 1 }
$lnk = Join-Path $desktop 'Claude Widget.lnk'

if ($Remove) {
  if (Test-Path -LiteralPath $lnk) {
    if ($DryRun) { "  would  remove $lnk" } else { Remove-Item -LiteralPath $lnk -Force; "  removed $lnk" }
  } else { "  absent  Claude Widget.lnk" }
  exit 0
}

$vbs = Join-Path $Dest 'token-widget.vbs'
$ico = Join-Path $Dest 'token-widget.ico'
if (-not (Test-Path -LiteralPath $vbs)) { Write-Error "no $vbs - run install.sh first"; exit 1 }

if ($DryRun) { "  would  create $lnk -> $vbs"; exit 0 }

$sh = New-Object -ComObject WScript.Shell
$s = $sh.CreateShortcut($lnk)
$s.TargetPath       = Join-Path $env:WINDIR 'System32\wscript.exe'
$s.Arguments        = '"' + $vbs + '"'
$s.WorkingDirectory = $Dest
if (Test-Path -LiteralPath $ico) { $s.IconLocation = "$ico,0" }
$s.WindowStyle      = 7
$s.Description      = 'Always-on-top readout of every Claude session on this machine'
$s.Save()

if (-not (Test-Path -LiteralPath $lnk)) { Write-Error "shortcut not written: $lnk"; exit 1 }
"  created $lnk"
