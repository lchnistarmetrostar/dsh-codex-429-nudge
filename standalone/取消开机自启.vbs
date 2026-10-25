' Codex 自动继续 - 取消开机自启
Option Explicit
Dim ws, fso, lnk
Set ws = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
lnk = ws.SpecialFolders("Startup") & "\Codex 自动继续.lnk"
If fso.FileExists(lnk) Then
    fso.DeleteFile lnk, True
    MsgBox "已取消开机自启。", 64, "Codex 自动继续"
Else
    MsgBox "本来就没有开着开机自启。", 64, "Codex 自动继续"
End If