# token-idle.ps1 - how long until this machine sleeps, for the safe-park.
#
# Prints one line:  <idle-seconds> <on-ac 1|0> <standby-ac-seconds> <standby-dc-seconds>
#
# Raw quantities only; token-sessions.sh --poke-due decides what they mean.
#
# Why it exists (measured 2026-09-15): idle sleep here is 15m on AC and 10m on
# battery, wake timers cannot wake the machine, and a console poke is not input,
# so it does not hold the machine awake. A window's hour runs out ~52 minutes
# after its last request - long after the machine has gone to sleep on a person
# who walked away. The only moment a checkpoint can still be written warm is the
# few minutes between "idle" and "asleep", and this is how the sweep sees them.
#
# GetLastInputInfo is per interactive session, which is why the sweep has to run
# in the logged-on session - it already does, for AttachConsole.

#   token-idle.ps1 -HoldAwake 180   hold off idle sleep for 180s, print nothing
#
# The hold is for a park already typed: a /park is a few requests, a minute or
# two, and the sweep that decided it may well be the last tick before sleep. A
# half-written checkpoint is no checkpoint. ES_SYSTEM_REQUIRED only defers IDLE
# sleep - a closed lid or the Start menu still wins - and ends with this process.
#
#   token-idle.ps1 -Nudge           reset the idle-sleep timer once, print nothing
#
# The keep-awake (2026-09-15): a renewal still to come is a reason not to sleep.
# ES_SYSTEM_REQUIRED WITHOUT ES_CONTINUOUS resets the system idle timer and
# holds nothing - the machine sleeps a full sleep-after later unless the next
# sweep nudges again. It does not touch GetLastInputInfo, so the idle reading
# above keeps counting from the person's last real input. S3 machine; on Modern
# Standby this would not be enough.
param([int] $HoldAwake = 0, [switch] $Nudge)

$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TokenIdle {
  [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [StructLayout(LayoutKind.Sequential)] struct SYSTEM_POWER_STATUS {
    public byte ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag;
    public int BatteryLifeTime, BatteryFullLifeTime; }
  [DllImport("user32.dll")]   static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
  [DllImport("kernel32.dll")] static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS s);
  [DllImport("kernel32.dll")] static extern uint GetTickCount();
  [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint f);
  public static bool Hold() { return SetThreadExecutionState(0x80000001) != 0; }   // CONTINUOUS | SYSTEM_REQUIRED
  public static bool Nudge() { return SetThreadExecutionState(0x00000001) != 0; }  // SYSTEM_REQUIRED, one-shot
  public static long IdleSeconds() {
    var i = new LASTINPUTINFO(); i.cbSize = (uint)Marshal.SizeOf(i);
    if (!GetLastInputInfo(ref i)) return -1;
    return (long)unchecked(GetTickCount() - i.dwTime) / 1000;   // uint subtraction survives the 49-day wrap
  }
  public static int OnAc() {
    SYSTEM_POWER_STATUS s; if (!GetSystemPowerStatus(out s)) return -1;
    return s.ACLineStatus == 1 ? 1 : (s.ACLineStatus == 0 ? 0 : -1);
  }
}
'@

if ($Nudge) {
  if (-not [TokenIdle]::Nudge()) { throw "token-idle: SetThreadExecutionState refused" }
  return
}

if ($HoldAwake -gt 0) {
  if (-not [TokenIdle]::Hold()) { throw "token-idle: SetThreadExecutionState refused" }
  Start-Sleep -Seconds $HoldAwake
  return
}

# "Sleep after", current scheme: the last two 0x values are AC then DC. Parsed by
# position, not by label, because the labels are localised (pt-BR here).
$hex = @(& powercfg /q SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>$null |
         Select-String -Pattern '0x[0-9a-fA-F]{8}' -AllMatches |
         ForEach-Object { $_.Matches } | ForEach-Object { $_.Value })
if ($hex.Count -lt 2) { throw "token-idle: could not read STANDBYIDLE from powercfg" }
$ac = [Convert]::ToInt64($hex[$hex.Count - 2], 16)
$dc = [Convert]::ToInt64($hex[$hex.Count - 1], 16)

'{0} {1} {2} {3}' -f [TokenIdle]::IdleSeconds(), [TokenIdle]::OnAc(), $ac, $dc
