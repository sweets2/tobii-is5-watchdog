Option Explicit

Dim shell, fso, scriptDir, scriptPath, powershellPath, command, i

If WScript.Arguments.Count < 1 Then
    WScript.Quit 2
End If

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(scriptDir, WScript.Arguments(0))
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")

command = Quote(powershellPath) & " -NoProfile -ExecutionPolicy Bypass -File " & Quote(scriptPath)
For i = 1 To WScript.Arguments.Count - 1
    command = command & " " & Quote(WScript.Arguments(i))
Next

' Window style 0 prevents the console from being created visibly. Waiting keeps
' Task Scheduler's running/restart state tied to the PowerShell child.
WScript.Quit shell.Run(command, 0, True)

Function Quote(value)
    Quote = Chr(34) & Replace(value, Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function
