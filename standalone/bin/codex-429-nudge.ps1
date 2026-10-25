# codex-429-nudge.ps1 — Codex 自动继续（429 / 额度用尽都救）
# 机制：用 Windows 无障碍接口(UIA)直接读 Codex 窗口的界面文字与按钮，不需要截图、不占用鼠标。
# 判据：界面里出现 429 报错 且 不在运行中(没有"停止"按钮) 且 429 是最新的内容 → 判定为"卡住了"。
# 动作：优先点"恢复目标"按钮；否则往输入框填"继续"并发送。
param(
    [int]$IntervalSeconds = 300,   # 检查间隔
    [int]$MaxAttempts = 6,         # 最多自动重试几次；<=0 表示不限
    [switch]$DryRun,               # 只看不动手
    [switch]$Once,                 # 只检查一轮
    [string]$WindowKeyword = 'ChatGPT',  # 认哪个窗口：进程名或标题含它就当 Codex，可用 | 分隔多个
    [switch]$Notify,               # 救不回来时弹桌面通知（插件每轮传，手动跑时不传）
    [int]$ScanRecent = 0,          # 每轮额外翻几个"屏幕上看得见的"会话（0 = 只盯当前会话）
    [string]$WatchSessions = '',   # 还要盯哪几个会话，标题用 ; 分隔
    [int]$ScanIntervalSeconds = 600, # 翻会话的最小间隔，别每轮都翻
    [string]$ConfigFile = '',      # 独立版的配置文件（JSON）；给了就用它覆盖上面的参数
    [string]$DataDir = '',         # 独立版的数据目录（日志、记住的会话）；空则沿用 ~/.dsh/codex-429-nudge
    [switch]$Tray                  # 显示托盘图标（独立版用）
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

# 数据目录：独立版由启动器指定（-DataDir），插件版沿用 ~/.dsh/codex-429-nudge。
# 日志跟着数据目录走，免得装到只读位置时写不进去。
if ($DataDir) {
    $script:StateDir = $DataDir
    New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null
    $script:LogPath = Join-Path $script:StateDir 'nudge.log'
}
else {
    $script:StateDir = Join-Path $env:USERPROFILE '.dsh\codex-429-nudge'
    $script:LogPath = Join-Path $PSScriptRoot 'nudge.log'
}

function Log([string]$msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Write-Host $line
    try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 } catch { }
}

$script:NotifyStamp = Join-Path $script:StateDir '.last-notify'

# 独立版的配置文件：给了 -ConfigFile 且文件存在就用它覆盖上面的命令行参数。
# 这样"设置"和"日程"分开放，改完重启一下程序就生效，不用记命令行。
if ($ConfigFile -and (Test-Path -LiteralPath $ConfigFile)) {
    try {
        $raw = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8
        $c = $raw | ConvertFrom-Json
        if ($null -ne $c.intervalSeconds) { $IntervalSeconds = [int]$c.intervalSeconds }
        if ($null -ne $c.maxAttempts) { $MaxAttempts = [int]$c.maxAttempts }
        if ($null -ne $c.windowKeyword -and "$($c.windowKeyword)".Trim()) { $WindowKeyword = [string]$c.windowKeyword }
        if ($null -ne $c.scanRecent) { $ScanRecent = [int]$c.scanRecent }
        if ($null -ne $c.watchSessions) { $WatchSessions = [string]$c.watchSessions }
        if ($null -ne $c.scanIntervalSeconds) { $ScanIntervalSeconds = [int]$c.scanIntervalSeconds }
        if ($null -ne $c.notify) { $Notify = [bool]$c.notify }
        if ($null -ne $c.paused -and [bool]$c.paused) { $IntervalSeconds = 3600 }  # 暂停 = 只偶尔看一眼，不动作
    }
    catch {
        Write-Host "配置文件读不了（$ConfigFile）：$($_.Exception.Message)，按命令行参数跑"
    }
}

# 托盘图标：独立版用。没有它，别人装完就"看不见了"，也不知道怎么停。
$script:TrayIcon = $null
$script:Quit = $false
function Start-TrayIcon {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
        $script:TrayIcon.Icon = [System.Drawing.SystemIcons]::Shield
        $script:TrayIcon.Text = 'Codex 自动继续'
        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $itemLog = $menu.Items.Add('打开日志')
        $itemLog.Add_Click({ try { Start-Process notepad.exe -ArgumentList $script:LogPath } catch { } })
        $itemCfg = $menu.Items.Add('打开设置文件')
        if ($ConfigFile) { $itemCfg.Add_Click({ try { Start-Process notepad.exe -ArgumentList $ConfigFile } catch { } }) }
        else { $itemCfg.Enabled = $false }
        $itemDir = $menu.Items.Add('打开数据文件夹')
        $itemDir.Add_Click({ try { Start-Process explorer.exe -ArgumentList $script:StateDir } catch { } })
        $null = $menu.Items.Add('-')
        $itemQuit = $menu.Items.Add('退出')
        $itemQuit.Add_Click({ $script:Quit = $true })
        $script:TrayIcon.ContextMenuStrip = $menu
        $script:TrayIcon.Visible = $true
        $script:TrayIcon.ShowBalloonTip(4000, 'Codex 自动继续', '已开始盯着 Codex。右击这个盾牌图标可以看日志或退出。', [System.Windows.Forms.ToolTipIcon]::Info)
        Log '托盘图标已就绪（右击可看日志 / 退出）'
    }
    catch { Log "托盘图标起不来：$($_.Exception.Message)" }
}

function Pump-Tray { if ($script:TrayIcon) { try { [System.Windows.Forms.Application]::DoEvents() } catch { } } }

# 主循环里的等待也走这个，顺便让托盘菜单能点得动
function Wait-Tick([int]$seconds) {
    for ($i = 0; $i -lt $seconds; $i++) {
        if ($script:Quit) { return }
        Start-Sleep -Seconds 1
        Pump-Tray
    }
}

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
        $ni.ShowBalloonTip(15000, 'Codex 自动继续：没救回来', $msg, [System.Windows.Forms.ToolTipIcon]::Warning)
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

# ---- 切回上次那个会话 ----
# 2026-10-25 实测：用户切到「新聊天」页之后，界面和"最小化/渲染坏了"在日志里一模一样
# （内容=0、只有输入框、没有报错）。可这时候摇窗口没用 —— 摇了还是新聊天页。
# 得把侧栏里那个会话点回来。侧栏每项是 ListItem 套 Button，name = 会话标题。
$script:SessionFile = Join-Path $script:StateDir '.last-session'

function Save-LastSession([string]$title) {
    if (-not $title -or $title -eq 'ChatGPT') { return }
    try {
        New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null
        Set-Content -LiteralPath $script:SessionFile -Value $title -Encoding UTF8
    } catch { }
}

function Read-LastSession {
    try {
        if (Test-Path -LiteralPath $script:SessionFile) {
            $v = (Get-Content -LiteralPath $script:SessionFile -Raw -Encoding UTF8).Trim()
            if ($v) { return $v }
        }
    } catch { }
    return ''
}

# 读输入框里有没有字。有字 = 你正在写东西，这时候绝不能把界面抢走。
function Get-InputText($edit) {
    if (-not $edit) { return '' }
    $vp = Test-Pattern $edit ([System.Windows.Automation.ValuePattern]::Pattern)
    if ($vp) {
        try {
            # 实测（2026-10-25）：Codex 的输入框是 contenteditable，空着的时候
            # ValuePattern.Value 返回的是 **placeholder 文本**（"随心输入" / "和 Codex 一起工作"），
            # 不是空串。所以要把这两种"假字"排掉，否则永远以为你在打字、永远不敢切会话。
            $v = ([string]$vp.Current.Value).Trim()
            if ($v -and $v -notmatch '^(和 Codex 一起工作|随心输入)$') { return $v }
        } catch { }
    }
    return ''
}

# 在侧栏按名字找会话项（每个会话是 ListItem 套一个同名 Button）。
function Find-SessionItem($win, [string]$title) {
    $all = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                        [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($e in $all) {
        if ($e.Current.ControlType.ProgrammaticName -ne 'ControlType.Button') { continue }
        if ([string]$e.Current.Name -eq $title) { return $e }
    }
    return $null
}

# 点完会话后界面要重新渲染。实测只等 900ms 常常还没切过去，会把"切过去了"误判成"没切过去"。
# 只查 Document 一个元素，比全量 Get-CodexState 便宜得多。
function Wait-DocTitle($win, [string]$title, [int]$timeoutMs = 6000) {
    try {
        $cond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Document)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
            $doc = $win.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
            if ($doc -and [string]$doc.Current.Name -eq $title) { return $true }
            Start-Sleep -Milliseconds 150
        }
    } catch { }
    return $false
}

# 在侧栏找同名会话并点进去。
# 实测（2026-10-25）：项滚出视野时 IsOffscreen=True，这时候 Invoke 会「返回成功但界面根本不切」。
# 必须先 ScrollIntoView 让它真正进视野，再重新取一次元素（旧引用会失效），最后才点。
function Restore-Session($win, [string]$title) {
    try {
        $target = Find-SessionItem $win $title
        if (-not $target) { Log "  侧栏里找不到会话「$title」"; return $false }

        if ($target.Current.IsOffscreen) {
            $parent = $null
            try { $parent = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($target) } catch { }
            foreach ($node in @($target, $parent)) {
                if (-not $node) { continue }
                $sip = Test-Pattern $node ([System.Windows.Automation.ScrollItemPattern]::Pattern)
                if ($sip) { try { $sip.ScrollIntoView() } catch { } }
            }
            Start-Sleep -Milliseconds 500
            $target = Find-SessionItem $win $title
            if (-not $target) { Log "  侧栏里找不到会话「$title」"; return $false }
        }

        $ok = Invoke-Button $target "会话「$title」"
        if ($ok) { $null = Wait-DocTitle $win $title }
        return $ok
    } catch {
        Log "  切回会话失败：$($_.Exception.Message)"
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
        InputValue   = ''        # 输入框里已经有的字（判断"你是不是正在写东西"）
        LastTextY    = -1
        LastText     = ''
        LastErrorIndex   = -1
        LastContentIndex = -1
        ContentCount     = 0      # 读到的对话内容条数（正常界面几十上百条，空页面 = 0）
        TotalElements    = 0
        DocTitle         = ''     # 当前看的是哪个会话（Document 的 name）
        LimitText        = $null  # 「你已达到使用上限…」= 额度用尽，不是 429，但同样要救
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
                if (-not $c.IsOffscreen -and -not $state.Input) {
                    $state.Input = $e
                    $state.InputValue = Get-InputText $e
                }
            }
            'ControlType.Text' {
                if ($c.Name) {
                    # 额度用尽不是 429，但从用户角度是同一件事：任务停了，得有人把它拉起来。
                    # 只认完整长句（"你已达到使用上限…升级套餐或充值额度…"）；模型选择器里那条
                    # 光秃秃的「已达到使用上限」是常驻提示，不能拿来当卡住的证据。
                    if ($c.Name -match '你已达到使用上限|升级套餐或充值额度|或稍后再试|用量已尽') {
                        if (-not $c.IsOffscreen) { $state.LimitText = $e }
                    }
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
    # 额度用尽同理：提示可能挂在对话末尾后面，按顺序比会漏掉，直接判卡住。
    if ($state.LimitText) { return $true }
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

# ---------------- 卡住时的动作链 ----------------
# 从主循环里抽出来的：「翻别的会话」时也要用同一套动作，不能有两份。
# 返回 $true = 点下去了（确认框也补点了），$false = 没点成。
# 没点成的原因放在 $script:LastFailReason 里。
function Invoke-Fix($win, $st) {
    $script:LastFailReason = ''
    $why = ''
    if ($st.GoalText) {
        $gn = [string]$st.GoalText.Current.Name
        $why = '目标横幅「' + $(if ($gn.Length -gt 20) { $gn.Substring(0, 20) + '…' } else { $gn }) + '」'
    }
    elseif ($st.LimitText) {
        $ln = [string]$st.LimitText.Current.Name
        $why = '额度用尽「' + $(if ($ln.Length -gt 24) { $ln.Substring(0, 24) + '…' } else { $ln }) + '」'
    }
    elseif ($st.ErrorElements.Count -gt 0) { $why = $st.ErrorElements[0].Text }
    Log ("检测到卡住：{0}" -f $why)

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
        if ($DryRun) { Log "  [DryRun] 本应点击「$targetLabel」"; return $false }
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
        if (-not $done) { $script:LastFailReason = "「$targetLabel」点不动" }
        return $done
    }

    if ($st.Input -and $st.SendButton) {
        Log '  没找到现成的恢复按钮，改用"发继续"兜底方案'
        if ($DryRun) { Log '  [DryRun] 跳过填写与发送'; return $false }
        $done = $false
        $okInput = Set-InputText $st.Input '继续'
        Start-Sleep -Milliseconds 400
        if ($okInput) { $done = Invoke-Button $st.SendButton '发送' }
        if (-not $done) { $script:LastFailReason = '往输入框写"继续"或点发送没成功' }
        return $done
    }

    Log '  界面里没找到可用的按钮或输入框'
    $script:LastFailReason = '界面上既没有恢复按钮，也没有能用的输入框'
    return $false
}

# ---------------- 翻别的会话 ----------------
# Codex 一次只显示一个会话，所以只盯当前那个会漏掉别的任务。这里每隔一段时间去翻一遍：
# 先翻你指定的（WatchSessions），再翻屏幕上看得见的几个；翻完把界面切回原来那个。
function Get-SessionCandidates($win, [string]$current) {
    $list = New-Object System.Collections.ArrayList
    foreach ($t in ($WatchSessions -split ';')) {
        $t = $t.Trim()
        if ($t -and $t -ne $current -and -not $list.Contains($t)) { [void]$list.Add($t) }
    }
    if ($ScanRecent -gt 0) {
        $all = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                            [System.Windows.Automation.Condition]::TrueCondition)
        $taken = 0
        # 真会话项 = ListItem 且有一个同名 Button。项目分组项（名字是把几个会话名拼在一起的
        # 那种）只有 ListItem、没有 Button，靠这一条就能把它排掉。
        $hasButton = @{}
        foreach ($e in $all) {
            if ($e.Current.ControlType.ProgrammaticName -eq 'ControlType.Button') {
                $hasButton[[string]$e.Current.Name] = $true
            }
        }
        foreach ($e in $all) {
            if ($taken -ge $ScanRecent) { break }
            $c = $e.Current
            if ($c.ControlType.ProgrammaticName -ne 'ControlType.ListItem') { continue }
            if ($c.IsOffscreen) { continue }
            $n = [string]$c.Name
            if (-not $n -or -not $hasButton.ContainsKey($n)) { continue }
            if ($n -eq $current -or $list.Contains($n)) { continue }
            [void]$list.Add($n)
            $taken++
        }
    }
    return $list
}

# 返回这一次翻会话里成功发起了几次重试。
function Scan-OtherSessions($win, [string]$original, [datetime]$lastAt) {
    $cand = Get-SessionCandidates $win $original
    if ($cand.Count -eq 0) { return 0 }
    if ($DryRun) {
        Log ("  [DryRun] 本应翻一遍这些会话：{0}" -f ($cand -join ' | '))
        return 0
    }
    Log ("开始翻会话（{0} 个）：{1}" -f $cand.Count, ($cand -join ' | '))
    $hit = 0
    foreach ($title in $cand) {
        if (([datetime]::Now - $lastAt).TotalSeconds -lt 60) { Log '  刚动过手，这轮不再翻'; break }
        if (-not (Restore-Session $win $title)) { Log ("  「{0}」点不动，跳过" -f $title); continue }
        $null = Wait-DocTitle $win $title
        try {
            $st = Get-CodexState $win
            if ([string]$st.DocTitle -ne $title) {
                Log ("  「{0}」没切过去（读到的是「{1}」），跳过" -f $title, $st.DocTitle)
                continue
            }
            if (-not (Test-Stalled $st)) {
                Log ("  「{0}」正常：内容={1} 运行中={2}" -f $title, $st.ContentCount, $st.Running)
                continue
            }
            Log ("  会话「{0}」卡住了" -f $title)
            if (Invoke-Fix $win $st) {
                $hit++
                $lastAt = [datetime]::Now
                Log ("  已替会话「{0}」发起重试" -f $title)
            }
        } catch { Log ("  翻「{0}」出错：{1}" -f $title, $_.Exception.Message) }
    }
    # 翻完切回你原来在看的那个
    if ($original -and $original -ne 'ChatGPT') {
        if (Restore-Session $win $original) {
            Start-Sleep -Milliseconds 700
            $back = Get-CodexState $win
            Log ("  已切回「{0}」（内容={1}）" -f $back.DocTitle, $back.ContentCount)
        }
        else { Log ("  没能切回「{0}」" -f $original) }
    }
    return $hit
}

# ---------------- 主循环 ----------------
$attempts = 0
$lastActionAt = [datetime]::MinValue
$lastScanAt = [datetime]::MinValue
$lastResult = [pscustomobject]@{ found = $false; stalled = $false; acted = $false; failed = $false; running = $false; blank = $false; limit = $false; error = '' }

$limitText = if ($MaxAttempts -gt 0) { "$MaxAttempts 次" } else { '不限' }
Log "=== Codex 自动继续 启动 间隔=${IntervalSeconds}s 上限=$limitText DryRun=$DryRun Tray=$Tray ==="
if ($Tray) {
    # 托盘模式常驻，防重复：双击两次不要跑出两个进程抢着点按钮。
    # （命名 Mutex 试过，实测两个实例都能起来；直接查进程更实在。）
    try {
        $others = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*-Tray*' -and $_.CommandLine -like '*codex-429-nudge.ps1*' -and $_.CommandLine -notlike '*-Command*' })
        if ($others.Count -gt 0) {
            Log "已经有一个「Codex 自动继续」在跑了（pid=$($others[0].ProcessId)），这次不重复启动"
            return
        }
    } catch { }
    Start-TrayIcon
}

while ($true) {
    if ($script:Quit) { Log '收到退出指令，收工'; break }
    try {
        $win = Find-CodexWindow
        $lastResult.found = [bool]$win
        if (-not $win) {
            Log "未找到 Codex 窗口（认的关键字：$WindowKeyword），跳过本轮"
        }
        else {
            $st = Get-CodexState $win

            # 有内容就记住"这是哪个会话"，等你切走了好找回来（见下面的 Restore-Session）
            if ($st.ContentCount -gt 0 -and $st.DocTitle -and $st.DocTitle -ne 'ChatGPT') {
                Save-LastSession $st.DocTitle
            }

            # 停在新聊天页：内容 0 条、只有输入框，跟"最小化/渲染坏"长得一模一样，
            # 区别是摇窗口治不好。这里把上次那个会话点回来再看一眼。
            if ($st.ContentCount -eq 0 -and $st.DocTitle -eq 'ChatGPT') {
                $saved = Read-LastSession
                $typing = $st.InputValue
                if (-not $saved) { Log '  停在新聊天页，而且没记着上次在哪个会话' }
                elseif ($typing) { Log ("  停在新聊天页，但输入框里有字（你可能正在写东西），不切：[{0}]" -f $(if ($typing.Length -gt 30) { $typing.Substring(0, 30) + '…' } else { $typing })) }
                elseif ($DryRun) { Log "  [DryRun] 本应切回会话「$saved」再看一眼" }
                elseif (Restore-Session $win $saved) {
                    $null = Wait-DocTitle $win $saved
                    $st = Get-CodexState $win
                    Log ("  切回了会话「{0}」：内容={1} 运行中={2}" -f $st.DocTitle, $st.ContentCount, $st.Running)
                }
            }

            # 2026-10-25 早上踩到的坑：整夜 210 轮读到的是"空界面"——输入框在，
            # 但对话内容一条都没有（ContentCount=0），于是每轮都判"一切正常"，白等 7 小时。
            # 这里再兜一次：切会话也没救回来的话，轻抖窗口逼它重绘。
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
            $lastResult.limit = [bool]$st.LimitText
            $lastResult.error = if ($st.ErrorElements.Count -gt 0) { $st.ErrorElements[0].Text } else { '' }
            $lastResult.acted = $false
            $lastResult.failed = $false
            Log ("状态：运行中={0} 最后有报错={1} 判定卡住={2} 继续按钮={3} 恢复目标按钮={4} 目标横幅={5} 推断按钮={6} 停止按钮={7} 输入框={8} 目标在跑={9} 会话=[{10}] 内容={11} 额度不足={12}" -f `
                 $st.Running, ($st.ErrorElements.Count -gt 0), $stalled,
                 [bool]$st.ContinueButton, [bool]$st.ResumeButton, [bool]$st.GoalText, [bool]$st.GoalButton,
                 [bool]$st.StopButton, [bool]$st.Input, $st.GoalRunning, $st.DocTitle, $st.ContentCount, [bool]$st.LimitText)

            if ($stalled) {
                if ($MaxAttempts -gt 0 -and $attempts -ge $MaxAttempts) {
                    Log "已达上限 $MaxAttempts 次，停止自动重试"
                    if (-not $Once) { break }
                }
                elseif (([datetime]::Now - $lastActionAt).TotalSeconds -lt 60) {
                    Log '  刚动过手，冷却中'
                }
                else {
                    $done = Invoke-Fix $win $st
                    if ($done) {
                        $lastResult.acted = $true
                        $attempts++
                        $lastActionAt = [datetime]::Now
                        Log "  第 $attempts/$MaxAttempts 次自动重试已发出"
                    }
                    elseif ($script:LastFailReason -and -not $DryRun) {
                        $lastResult.failed = $true
                        Log "  没救成：$($script:LastFailReason)"
                        if ($Notify) {
                            Send-FailNotice "Codex 卡住了（429 或额度用尽），插件没救回来：$($script:LastFailReason)。你可能得自己看一眼。"
                        }
                    }
                }
            }

            # 当前会话没卡住、也没在跑：隔一会儿去翻翻别的会话（你可能同时开了好几个任务）。
            # 只在空闲时翻，免得打断正在跑的那个。
            if (-not $stalled -and -not $st.Running -and ($ScanRecent -gt 0 -or $WatchSessions)) {
                if (([datetime]::Now - $lastScanAt).TotalSeconds -ge $ScanIntervalSeconds) {
                    $lastScanAt = [datetime]::Now
                    $hit = Scan-OtherSessions $win $st.DocTitle $lastActionAt
                    if ($hit -gt 0) {
                        $lastResult.acted = $true
                        $attempts += $hit
                        $lastActionAt = [datetime]::Now
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
    Wait-Tick $IntervalSeconds
}

if ($script:Tray) {
    try { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() } catch { }
}
Log '=== 结束 ==='
