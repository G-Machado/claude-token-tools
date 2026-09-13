' Runs token-sessions.sh --poke-due with no console window behind it.
'
' Same reasoning as token-keeper.vbs: this is on a two-or-three minute schedule,
' so a visible console would flash on the desktop several hundred times a day.
' Task Scheduler's own "run whether user is logged on or not" hides it too, but
' only by running in another session - and this one has to reach the console
' input buffers of the sessions on THIS desktop, which is precisely what another
' session cannot do.
'
' Registered by token-pokedue-install.ps1. Arguments are passed straight through:
'   token-pokedue.vbs --dry-run

Dim sh, fso, here, cmd, i
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)

cmd = """C:\Program Files\Git\bin\bash.exe"" -lc ""~/.claude/token-sessions.sh --poke-due"

For i = 0 To WScript.Arguments.Count - 1
  cmd = cmd & " " & WScript.Arguments(i)
Next

' Appended, unlike the keeper's .out: a poke is a thing that HAPPENED to a
' session and the log is the only record of it outside token-poke.log. Rotation
' is the installer's job, not this wrapper's.
cmd = cmd & " >> ~/.claude/token-pokedue.log 2>&1"""

sh.Run cmd, 0, True
