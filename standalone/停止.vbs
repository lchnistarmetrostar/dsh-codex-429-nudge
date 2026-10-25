' Codex 自动继续 - 停止正在跑的那个（只停托盘模式的，不碰别的命令行）
Option Explicit
Dim wmi, procs, p, n, cl
n = 0
Set wmi = GetObject("winmgmts:\\.\root\cimv2")
Set procs = wmi.ExecQuery("SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name='powershell.exe'")
For Each p In procs
    If Not IsNull(p.CommandLine) Then
        cl = LCase(p.CommandLine)
        If InStr(cl, "codex-429-nudge.ps1") > 0 And InStr(cl, "-tray") > 0 And InStr(cl, "-command") = 0 Then
            p.Terminate()
            n = n + 1
        End If
    End If
Next
MsgBox "已停止 " & n & " 个后台进程。", 64, "Codex 自动继续"