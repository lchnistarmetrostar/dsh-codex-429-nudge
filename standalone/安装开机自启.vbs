' Codex 自动继续 - 装成开机自启
Option Explicit
Dim fso, base, ws, lnk, sc
Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.GetParentFolderName(WScript.ScriptFullName)
Set ws = CreateObject("WScript.Shell")
lnk = ws.SpecialFolders("Startup") & "\Codex 自动继续.lnk"
Set sc = ws.CreateShortcut(lnk)
sc.TargetPath = base & "\启动 Codex 自动继续.vbs"
sc.WorkingDirectory = base
sc.WindowStyle = 7
sc.Description = "Codex 自动继续"
sc.Save
MsgBox "好消息：下次开机它自己就起来了。" & vbCrLf & vbCrLf & "快捷方式放在：" & vbCrLf & lnk, 64, "Codex 自动继续"