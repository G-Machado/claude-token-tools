' Starts launch.ps1 (rebuild bin/Debug if stale, then run TokenChat) with no console window behind it.
' The desktop "Claude Chat" shortcut points here: wscript.exe "<repo>\windows\token-chat\launch.vbs"

Dim sh, fso, here, cmd, i
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & here & "\launch.ps1"""
For i = 0 To WScript.Arguments.Count - 1
  cmd = cmd & " """ & WScript.Arguments(i) & """"
Next

sh.Run cmd, 0, False
