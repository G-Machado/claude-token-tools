' Regenerates the dashboard and opens it, with no console window.
'
' The generator is a bash script, so running it from a shortcut would otherwise
' flash a terminal every time - and a shortcut you flinch at is one you stop
' clicking. WScript.Run with an intWindowStyle of 0 keeps it silent, and the
' True on the second Run makes this wait for the rewrite to finish before the
' browser opens, so the page never shows the previous run's numbers.
'
' Anything passed through goes to token-dashboard.sh:
'   token-dashboard.vbs --watch 60      keep rewriting while you read

Dim sh, fso, here, bash, args, i, gen, page
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)

bash = sh.ExpandEnvironmentStrings("%ProgramFiles%") & "\Git\bin\bash.exe"
If Not fso.FileExists(bash) Then
  bash = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\Programs\Git\bin\bash.exe"
End If
If Not fso.FileExists(bash) Then
  MsgBox "Git Bash not found - token-dashboard.sh runs through it.", 48, "Claude analytics"
  WScript.Quit 1
End If

' bash wants a posix path for its own argument, whatever Windows calls it here.
gen = "/" & Replace(Replace(here, ":", ""), "\", "/") & "/token-dashboard.sh"
args = ""
For i = 0 To WScript.Arguments.Count - 1
  args = args & " " & WScript.Arguments(i)
Next

' Single-quoted inside -lc so a path with a space still arrives as one word.
sh.Run """" & bash & """ -lc ""'" & gen & "'" & args & " >/dev/null 2>&1""", 0, True

page = here & "\token-dashboard.html"
If fso.FileExists(page) Then
  sh.Run """" & page & """", 1, False
Else
  MsgBox "token-dashboard.sh produced no page.", 48, "Claude analytics"
End If
