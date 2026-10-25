' Codex 自动继续 - 后台启动（不弹黑窗口）
' 注意 -STA：托盘图标（WinForms）在没有 STA 的进程里会直接卡死，实测过。
Option Explicit
Dim fso, base, sh, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
base = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("WScript.Shell")
cmd = "powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ _
    & base & "\bin\codex-429-nudge.ps1"" -Tray" _
    & " -ConfigFile """ & base & "\config.json""" _
    & " -DataDir """ & base & "\data"""
sh.Run cmd, 0, False