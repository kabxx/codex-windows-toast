Option Explicit

Dim activationUri
Dim command
Dim fileSystem
Dim handlerPath
Dim pattern
Dim powershellPath
Dim scriptDirectory
Dim shell

If WScript.Arguments.Count <> 1 Then
    WScript.Quit 0
End If

activationUri = WScript.Arguments(0)

Set pattern = New RegExp
pattern.Global = False
pattern.IgnoreCase = False
pattern.Pattern = "^codex-windows-toast://ignore/?$|^codex-windows-toast://activate/?\?v=2&targets=[1-9][0-9]{0,18}\.[1-9][0-9]{0,9}\.[1-9][0-9]{0,18}(~[1-9][0-9]{0,18}\.[1-9][0-9]{0,9}\.[1-9][0-9]{0,18}){0,7}&sig=[0-9a-f]{64}$|^codex-windows-toast://activate/?\?v=3&id=[0-9a-f]{32}&sig=[0-9a-f]{64}$"
If Not pattern.Test(activationUri) Then
    WScript.Quit 0
End If

Set fileSystem = CreateObject("Scripting.FileSystemObject")
scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
handlerPath = fileSystem.BuildPath(scriptDirectory, "activate-window.ps1")
If Not fileSystem.FileExists(handlerPath) Then
    WScript.Quit 0
End If

Set shell = CreateObject("WScript.Shell")
powershellPath = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
command = QuoteArgument(powershellPath) & _
    " -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File " & _
    QuoteArgument(handlerPath) & " " & QuoteArgument(activationUri)

On Error Resume Next
shell.Run command, 0, False

Function QuoteArgument(value)
    If InStr(value, Chr(34)) <> 0 Then
        WScript.Quit 0
    End If

    QuoteArgument = Chr(34) & value & Chr(34)
End Function
