# codex-429-nudge.ps1 — Codex 429 自动重试器（M1 原型）
# 机制：用 Windows 无障碍接口(UIA)直接读 Codex 窗口的界面文字与按钮，不需要截图、不占用鼠标。
# 判据：界面里出现 429 报错 且 不在运行中(没有"停止"按钮) 且 429 是最新的内容 → 判定为"卡住了"。
# 动作：优先点"恢复目标"按钮；否则往输入框填"继续"并发送。
param(
    [int]$IntervalSeconds = 300,   # 检查间隔
    [int]$MaxAttempts = 6,         # 最多自动重试几次
    [switch]$DryRun,               # 只看不动手
    [switch]$Once,                 # 只检查一轮
    [string]$WindowKeyword = 'ChatGPT',  # 认哪个窗口：进程名或标题含它就当 Codex，可用 | 分隔多个
    [switch]$Notify                # 救不回来时弹桌面通知（插件每轮传，手动跑时不传）
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$script:LogPath = Join-Path $PSScriptRoot 'nudge.log'

function Log([string]$msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Write-Host $line
    try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 } catch { }
}

$script:StateDir = Join-Path $env:USERPROFILE '.dsh\codex-429-nudge'
$script:NotifyStamp = Join-Path $script:StateDir '.last-notify'

# 救不回来时弹右下角通知。30 分钟内不重复弹，免得你人不在时一直响。
function Send-FailNotice([string]$msg) {
    try {
        if (Test-Path -LiteralPath $script:NotifyStamp) {
            $last = [datetime]::MinValue
            $raw = (Get-Content -LiteralPath $script:NotifyStamp -Raw).Trim()
            if ([datetime]::TryParse($raw, [ref]$last) -and (([datetime]::Now - $last).TotalMinutes -lt 30)) { return }
        }
        New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null
        Set-Content -LiteralPath $script:NotifyStamp -Value (Get-Date -Format 'o') -Encoding ASCII
    } catch { }

    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon = [System.Drawing.SystemIcons]::Warning
        $ni.Visible = $true
        $ni.ShowBalloonTip(15000, 'Codex 429：没救回来', $msg, [System.Windows.Forms.ToolTipIcon]::Warning)
        Start-Sleep -Milliseconds 1500
        $ni.Dispose()
    } catch {
        Log "  弹通知失败：$($_.Exception.Message)"
    }
}

# 窗口重绘用的最小 Win32 接口。只用三个函数，不需要 UIA 之外的其他依赖。
if (-not ('CodexNudge.Win32' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace CodexNudge {
    public static class Win32 {
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int X, int Y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    }
}
'@
}

$script:WakeStamp = Join-Path $script:StateDir '.last-wake'

# 摇窗口要节流：界面长期空着（比如你就停在新聊天页）时，别每 5 分钟抖一次。
function Should-Wake {
    try {
        if (Test-Path -LiteralPath $script:WakeStamp) {
            $last = [datetime]::MinValue
            $raw = (Get-Content -LiteralPath $script:WakeStamp -Raw).Trim()
            if ([datetime]::TryParse($raw, [ref]$last) -and (([datetime]::Now - $last).TotalMinutes -lt 30)) { return $false }
        }
    } catch { }
    try {
        New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null
        Set-Content -LiteralPath $script:WakeStamp -Value (Get-Date -Format 'o') -Encoding ASCII
    } catch { }
    return $true
}

# 界面读不到内容时，轻轻抖一下窗口：把宽高改 2px 再改回来，逼 WebView 重新渲染。
# 不抢焦点、不动鼠标。实测过：只有改尺寸能触发重绘，移动窗口位置没用；PrintWindow 抓不到内容，靠不住。
function Wake-CodexWindow($win) {
    try {
        $h = [IntPtr]$win.Current.NativeWindowHandle
        if ($h -eq [IntPtr]::Zero) { return $false }
        $r = New-Object CodexNudge.Win32+RECT
        if (-not [CodexNudge.Win32]::GetWindowRect($h, [ref]$r)) { return $false }
        $w = $r.Right - $r.Left
        $ht = $r.Bottom - $r.Top
        if ($w -le 100 -or $ht -le 100) { return $false }
        $flags = [uint32]0x0014   # SWP_NOZORDER | SWP_NOACTIVATE
        # SW_SHOWNOACTIVATE(4)：万一被最小化了先拉出来，但不抢焦点
        [void][CodexNudge.Win32]::ShowWindow($h, 4)
        Start-Sleep -Milliseconds 250
        [void][CodexNudge.Win32]::SetWindowPos($h, [IntPtr]::Zero, $r.Left, $r.Top, ($w + 2), $ht, $flags)
        Start-Sleep -Milliseconds 350
        [void][CodexNudge.Win32]::SetWindowPos($h, [IntPtr]::Zero, $r.Left, $r.Top, $w, $ht, $flags)
        Start-Sleep -Milliseconds 1200
        return $true
    } catch {
        Log "  摇窗口失败：$($_.Exception.Message)"
        return $false
    }
}

function Test-Pattern($el, $pattern) {
    $obj = $null
    if ($el.TryGetCurrentPattern($pattern, [ref]$obj)) { return $obj }
    return $null
}

# Goal 模式横幅右边那个 ▶ 往往是个没名字的图标按钮，按名字找不到时就按位置抓：
# 和「目标已停滞」这行字垂直对得上（±50px）、在它右边、又不是认识的那些控件。
$script:KnownButtonNames = '^(停止|继续|发送|提交|发送消息|恢复目标|继续目标|清除目标|暂停目标|编辑目标|添加文件.*|更改权限|听写|开启语音聊天|返回|前进|隐藏侧边栏|显示侧边栏|首页|图像|定时任务|资料库|插件|探索|代码审查|站点|滚动到底部|跳转到用户消息.*|新聊天|搜索|通知|文件|编辑|视图|帮助|复制消息|编辑消息|查看变更|撤销|显示更多|收起文件|再显示.*|聊天操作|显示标签页|切换摘要面板固定状态)$'

function Find-GoalButton($all, $labelEl) {
    try {
        $lr = $labelEl.Current.BoundingRectangle
        if ($lr.IsEmpty -or [double]::IsInfinity($lr.Y) -or [double]::IsInfinity($lr.X)) { return $null }
        $ly = $lr.Y + $lr.Height / 2
        $best = $null
        $bestDx = [double]::MaxValue
        foreach ($e in $all) {
            if ($e.Current.ControlType.ProgrammaticName -ne 'ControlType.Button') { continue }
            $n = $e.Current.Name
            if ($n -and $n -match $script:KnownButtonNames) { continue }
            $r = $e.Current.BoundingRectangle
            if ($r.IsEmpty -or [double]::IsInfinity($r.Y) -or [double]::IsInfinity($r.X)) { continue }
            $dy = [math]::Abs(($r.Y + $r.Height / 2) - $ly)
            $dx = $r.X - $lr.Right
            if ($dy -lt 50 -and $dx -gt -600 -and $dx -lt 500 -and $dx -lt $bestDx) {
                $best = $e
                $bestDx = $dx
            }
        }
        return $best
    } catch { return $null }
}

# 找 Codex 主窗口。三层兜底，因为 Codex 换版本/换装法时进程名和标题都可能变：
#   1) 进程名里含关键字（默认 ChatGPT）
#   2) 顶层窗口标题里含关键字
#   3) 界面特征：往下找 "和 Codex 一起工作" 那个输入框（只扫 Electron/WebView 系窗口，不然太慢）
# 前两层便宜，第三层兜底。
function Find-CodexWindow {
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $wins = @($root.FindAll([System.Windows.Automation.TreeScope]::Children,
                            [System.Windows.Automation.Condition]::TrueCondition))
    if ($wins.Count -eq 0) { return $null }

    $keys = @(($WindowKeyword -split '[|,]') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($keys.Count -eq 0) { $keys = @('ChatGPT') }

    # 1) 进程名
    foreach ($k in $keys) {
        $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like "*$k*" })
        if ($procs.Count -eq 0) { continue }
        $ids = @($procs | ForEach-Object { $_.Id })
        foreach ($w in $wins) {
            if ($ids -contains $w.Current.ProcessId) { return $w }
        }
    }

    # 2) 窗口标题
    foreach ($w in $wins) {
        $title = $w.Current.Name
        if (-not $title) { continue }
        foreach ($k in $keys) {
            if ($title -like "*$k*") { return $w }
        }
    }

    # 3) 界面特征
    $feature = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, '和 Codex 一起工作')
    foreach ($w in $wins) {
        if ($w.Current.ClassName -notmatch 'Chrome_WidgetWin|Tauri|WebView') { continue }
        try {
            if ($w.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $feature)) { return $w }
        } catch { }
    }

    return $null
}

# 读取界面状态
function Get-CodexState($win) {
    $state = [pscustomobject]@{
        Found        = $true
        Running      = $false   # 有"停止"按钮 = 正在生成
        ErrorElements = @()      # 可见的 429 / 限流 报错
        ResumeButton = $null     # "恢复目标" 按钮（目标/Goal 模式）
        ContinueButton = $null   # "继续" 按钮（普通对话，输入框右下角黑色圆钮）
        SendButton   = $null
        StopButton   = $null
        GoalText     = $null     # 「目标已停滞」/「已暂停的目标」那行（= 要救的信号）
        GoalRunning  = $false    # 「进行中的目标」= 正常在推进，别动它
        GoalButton   = $null     # 按位置推断出来的 ▶
        Input        = $null
        LastTextY    = -1
        LastText     = ''
        LastErrorIndex   = -1
        LastContentIndex = -1
        ContentCount     = 0      # 读到的对话内容条数（正常界面几十上百条，空页面 = 0）
        TotalElements    = 0
        DocTitle         = ''     # 当前看的是哪个会话（Document 的 name）
    }
    $all = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                        [System.Windows.Automation.Condition]::TrueCondition)
    $i = 0
    foreach ($e in $all) {
        $i++
        $c = $e.Current
        $t = $c.ControlType.ProgrammaticName
        switch ($t) {
            'ControlType.Button' {
                switch -Regex ($c.Name) {
                    '^停止$'               { $state.StopButton = $e; $state.Running = $true }
                    '^恢复目标$|^继续目标$' { $state.ResumeButton = $e }
                    '^继续$'               { $state.ContinueButton = $e }
                    '^发送$|^提交$|^发送消息$' { $state.SendButton = $e }
                    # 实测：Goal 模式下整条横幅本身就是一个 Button，名字以「目标已停滞」/「已暂停的目标」开头。
                    # 「进行中的目标」= 正常在推进，绝不能当成卡住。
                    '^(目标已停滞|已暂停的目标)' { $state.GoalText = $e }
                    '^进行中的目标' { $state.GoalRunning = $true }
                }
            }
            'ControlType.Edit' {
                # 输入框 placeholder 会变（"和 Codex 一起工作" / "随心输入"），不能按固定名匹配。
                # 取界面上第一个可见的 Edit。
                if (-not $c.IsOffscreen -and -not $state.Input) { $state.Input = $e }
            }
            'ControlType.Text' {
                if ($c.Name) {
                    if ($c.Name -match '429|Too Many Requests|exceeded retry limit|使用上限') {
                        $state.ErrorElements += [pscustomobject]@{ Text = $c.Name; Index = $i }
                        $state.LastErrorIndex = $i
                    }
                    elseif ($c.Name -match '目标已停滞|已暂停的目标') {
                        # Goal 模式的横幅是 429 之后才冒出来的，它不算"正常内容"，
                        # 否则判定会以为报错后面还有东西，反而不敢动手。
                        $state.GoalText = $e
                    }
                    elseif ($c.Name.Length -gt 20) {
                        $state.LastContentIndex = $i
                        $state.ContentCount++
                    }
                    try {
                        if (-not $c.IsOffscreen) {
                            $r = $c.BoundingRectangle
                            if (-not $r.IsEmpty -and -not [double]::IsInfinity($r.Y)) {
                                $y = [int]$r.Y
                                if ($y -gt $state.LastTextY) { $state.LastTextY = $y; $state.LastText = $c.Name }
                            }
                        }
                    } catch { }
                }
            }
        }
    }
    $state.TotalElements = $all.Count
    # 记下当前在看哪个会话：出问题时一眼看出是"窗口切走了"还是"界面没渲染出来"。
    try {
        $docCond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Document)
        $doc = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $docCond)
        if ($doc) { $state.DocTitle = [string]$doc.Current.Name }
    } catch { }
    if ($state.GoalText) { $state.GoalButton = Find-GoalButton $all $state.GoalText }
    return $state
}

# 判断：是不是卡住了
function Test-Stalled($state) {
    # Goal 模式：横幅直接写着「目标已停滞」或「已暂停的目标」，那就是卡了，不用再问别的。
    # ⚠️ 这里不能沿用下面"报错是不是最后一条"的判断 —— 2026-10-25 早上实测：
    #    目标暂停时，429 报错后面还挂着上一条正常回复，按顺序比会以为没卡住，白白放过一整夜。
    if ($state.GoalText) { return $true }
    if ($state.Running) { return $false }
    if ($state.ErrorElements.Count -eq 0) { return $false }
    # 报错之后没有更新的正常内容 → 报错就是最后一条，说明卡住了
    return ($state.LastErrorIndex -gt $state.LastContentIndex)
}

function Invoke-Button($btn, [string]$label) {
    $p = Test-Pattern $btn ([System.Windows.Automation.InvokePattern]::Pattern)
    if (-not $p) { Log "  [$label] 该按钮不支持程序化点击"; return $false }
    $p.Invoke()
    Log "  已点击 [$label]"
    return $true
}

function Set-InputText($edit, [string]$text) {
    $p = Test-Pattern $edit ([System.Windows.Automation.ValuePattern]::Pattern)
    if (-not $p) { Log '  输入框不支持 ValuePattern'; return $false }
    $p.SetValue($text)
    Log "  已向输入框写入：$text"
    return $true
}

# ---------------- 主循环 ----------------
$attempts = 0
$lastActionAt = [datetime]::MinValue
$lastResult = [pscustomobject]@{ found = $false; stalled = $false; acted = $false; failed = $false; running = $false; blank = $false; error = '' }

Log "=== Codex 429 自动重试器启动 间隔=${IntervalSeconds}s 上限=${MaxAttempts}次 DryRun=$DryRun ==="

while ($true) {
    try {
        $win = Find-CodexWindow
        $lastResult.found = [bool]$win
        if (-not $win) {
            Log "未找到 Codex 窗口（认的关键字：$WindowKeyword），跳过本轮"
        }
        else {
            $st = Get-CodexState $win
            # 2026-10-25 早上踩到的坑：整夜 210 轮读到的是"空界面"——输入框在，
            # 但对话内容一条都没有（ContentCount=0），于是每轮都判"一切正常"，白等 7 小时。
            # 这里先兜一次：看到空界面就轻抖窗口逼它重绘，再读一遍。
            if (-not $st.Running -and $st.ErrorElements.Count -eq 0 -and -not $st.GoalText -and $st.ContentCount -eq 0) {
                Log ("界面读不到对话内容（会话=[{0}] 内容=0 元素={1}）" -f $st.DocTitle, $st.TotalElements)
                if ($DryRun) { Log '  [DryRun] 本应摇一下窗口试试' }
                elseif (-not (Should-Wake)) { Log '  30 分钟内摇过了，这次不重复摇' }
                elseif (Wake-CodexWindow $win) {
                    $st2 = Get-CodexState $win
                    if ($st2.ContentCount -gt 0 -or $st2.Running -or $st2.ErrorElements.Count -gt 0 -or $st2.GoalText) {
                        Log ("  摇醒了：会话=[{0}] 内容={1}" -f $st2.DocTitle, $st2.ContentCount)
                        $st = $st2
                    }
                    else {
                        Log '  摇不醒，还是空的（可能就停在新聊天页，或者界面真没渲染出来）'
                        $lastResult.blank = $true
                    }
                }
            }
            $stalled = Test-Stalled $st
            $lastResult.stalled = $stalled
            $lastResult.running = $st.Running
            $lastResult.error = if ($st.ErrorElements.Count -gt 0) { $st.ErrorElements[0].Text } else { '' }
            $lastResult.acted = $false
            $lastResult.failed = $false
            Log ("状态：运行中={0} 最后有报错={1} 判定卡住={2} 继续按钮={3} 恢复目标按钮={4} 目标横幅={5} 推断按钮={6} 停止按钮={7} 输入框={8} 目标在跑={9} 会话=[{10}] 内容={11}" -f `
                 $st.Running, ($st.ErrorElements.Count -gt 0), $stalled,
                 [bool]$st.ContinueButton, [bool]$st.ResumeButton, [bool]$st.GoalText, [bool]$st.GoalButton,
                 [bool]$st.StopButton, [bool]$st.Input, $st.GoalRunning, $st.DocTitle, $st.ContentCount)

            if ($stalled) {
                if ($attempts -ge $MaxAttempts) {
                    Log "已达上限 $MaxAttempts 次，停止自动重试"
                    if (-not $Once) { break }
                }
                elseif (([datetime]::Now - $lastActionAt).TotalSeconds -lt 60) {
                    Log '  刚动过手，冷却中'
                }
                else {
                    # 卡住的原因可能不是 429 报错（目标被暂停时就没有报错），所以别直接取 ErrorElements[0]
                    $why = ''
                    if ($st.GoalText) {
                        $gn = [string]$st.GoalText.Current.Name
                        $why = '目标横幅「' + $(if ($gn.Length -gt 20) { $gn.Substring(0, 20) + '…' } else { $gn }) + '」'
                    }
                    elseif ($st.ErrorElements.Count -gt 0) { $why = $st.ErrorElements[0].Text }
                    Log ("检测到卡住：{0}" -f $why)
                    $done = $false
                    $failReason = ''
                    # 兜底链，从上往下试：
                    #   1) 普通对话 → 输入框右下角黑色圆钮，UIA name = '继续'（已实测有效）
                    #   2) 目标模式 → 名字叫 '恢复目标' / '继续目标' 的按钮
                    #   3) 目标模式 → 名字判断不了就按位置抓「目标已停滞」右边那个 ▶
                    #   4) 都没有 → 往输入框写"继续"再点发送
                    #   5) 还是不行 → 记原因 + 弹通知（你在不在电脑前都得知道）
                    $target = $null
                    $targetLabel = ''
                    if ($st.ContinueButton) { $target = $st.ContinueButton; $targetLabel = '继续' }
                    elseif ($st.ResumeButton) { $target = $st.ResumeButton; $targetLabel = '恢复目标' }
                    elseif ($st.GoalButton) { $target = $st.GoalButton; $targetLabel = '目标横幅右侧的按钮' }

                    if ($target) {
                        if ($DryRun) { Log "  [DryRun] 本应点击「$targetLabel」" }
                        else {
                            $done = Invoke-Button $target $targetLabel
                            if ($done) {
                                # 点「恢复目标」有时会弹一个「恢复已暂停的目标吗？」确认框，
                                # 那个框里的确认按钮叫「继续目标」，需要补一下。
                                Start-Sleep -Milliseconds 800
                                $again = Get-CodexState $win
                                if ($again.ResumeButton -and ([string]$again.ResumeButton.Current.Name) -match '^继续目标$') {
                                    Log '  弹出确认框，补点「继续目标」'
                                    Invoke-Button $again.ResumeButton '继续目标' | Out-Null
                                }
                            }
                        }
                        if (-not $done -and -not $DryRun) { $failReason = "「$targetLabel」点不动" }
                    }
                    elseif ($st.Input -and $st.SendButton) {
                        Log '  没找到现成的恢复按钮，改用"发继续"兜底方案'
                        if (-not $DryRun) {
                            $okInput = Set-InputText $st.Input '继续'
                            Start-Sleep -Milliseconds 400
                            if ($okInput) { $done = Invoke-Button $st.SendButton '发送' }
                            if (-not $done) { $failReason = '往输入框写"继续"或点发送没成功' }
                        }
                        else { Log '  [DryRun] 跳过填写与发送' }
                    }
                    else {
                        Log '  界面里没找到可用的按钮或输入框'
                        $failReason = '界面上既没有恢复按钮，也没有能用的输入框'
                    }
                    if ($done) {
                        $lastResult.acted = $true
                        $attempts++
                        $lastActionAt = [datetime]::Now
                        Log "  第 $attempts/$MaxAttempts 次自动重试已发出"
                    }
                    elseif ($failReason -and -not $DryRun) {
                        $lastResult.failed = $true
                        Log "  没救成：$failReason"
                        if ($Notify) {
                            Send-FailNotice "Codex 卡在 429，插件没救回来：$failReason。你可能得自己看一眼。"
                        }
                    }
                }
            }
        }
    }
    catch {
        Log "本轮出错：$($_.Exception.Message)"
    }

    if ($Once) {
        Write-Host ('RESULT ' + ($lastResult | ConvertTo-Json -Compress))
        break
    }
    Start-Sleep -Seconds $IntervalSeconds
}

Log '=== 结束 ==='
