' Runs token-window-keeper.sh with no console window behind it.
'
' The keeper is on a fifteen-minute schedule, so a visible console would flash
' on this desktop about a hundred times a day. Task Scheduler's own "run whether
' user is logged on or not" hides it too, but only by running in another session
' where cswap cannot see the logged-on user's credentials - so the window has to
' be suppressed here instead, the same way token-widget.vbs does it.
'
' Registered by token-keeper-install.ps1. Arguments are passed straight through:
'   token-keeper.vbs --dry-run

Dim sh, fso, here, cmd, i
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)

' -l so the login profile sets PATH; the keeper falls back to `command -v cswap`
' when the fixed ~/.local/bin path is not there.
cmd = """C:\Program Files\Git\bin\bash.exe"" -lc ""~/.claude/token-window-keeper.sh"

For i = 0 To WScript.Arguments.Count - 1
  cmd = cmd & " " & WScript.Arguments(i)
Next

' A fresh file per run, not an append: token-keeper.log is the history, this is
' only ever "what the last run printed", so it can never grow without bound.
cmd = cmd & " > ~/.claude/token-keeper.out 2>&1"""

sh.Run cmd, 0, True
