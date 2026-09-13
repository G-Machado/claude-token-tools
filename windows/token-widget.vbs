' Starts token-widget.ps1 with no console window behind it.
'
' powershell.exe -WindowStyle Hidden still flashes a console for a moment and
' then keeps an empty one in the taskbar for the life of the widget, which is
' the opposite of what an always-on-top panel is for. WScript.Run with an
' intWindowStyle of 0 is the only way to start it genuinely windowless.
'
' Put a shortcut to this file in shell:startup to have the widget come back
' with the machine.

Dim sh, fso, here, cmd
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & _
      here & "\token-widget.ps1"""

' Anything passed to the .vbs is passed straight through, so the same file can
' be copied and pointed at a different refresh rate or corner:
'   token-widget.vbs -Every 30 -TopLeft
Dim i
For i = 0 To WScript.Arguments.Count - 1
  cmd = cmd & " " & WScript.Arguments(i)
Next

sh.Run cmd, 0, False
