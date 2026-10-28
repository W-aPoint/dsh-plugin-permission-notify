' Launch activate.ps1 without showing any console window.
' Registered as the dshnotify: protocol handler so clicking a toast focuses DSH.
Dim fso, shell, here, cmd, i
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
here = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & here & "\activate.ps1"""
If WScript.Arguments.Count > 0 Then
    cmd = cmd & " -ProtocolArgument """ & WScript.Arguments(0) & """"
End If
shell.Run cmd, 0, False
