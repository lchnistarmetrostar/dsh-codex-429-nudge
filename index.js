/**
 * dsh-codex-429-nudge —— 插件宿主半端
 *
 * 两件事：按节奏起 bin/codex-429-nudge.ps1，读它 stdout 里那行 RESULT。
 * 真正的读屏与点击在 PowerShell 里（Windows UI Automation），这里不碰界面。
 *
 * 配置不放 DSH 的 Config schema，而是自己存 config.json：
 * DSH 的 describe() 里 user 层不会跟着插件写入更新（bili-scroll 踩过，改了等于没改），
 * 自己存一份、设置页走 /api/codex-429-nudge/config 读写，来源只有一个，不打架。
 *
 * 计数语义（用户 2026-10-25 明确要求）：这是"离开电脑时替你看着"的工具，
 * 所以 Codex 中途恢复正常 **不清零** —— 恢复一次只花掉一次预算，
 * 剩下的预算还留着，免得"刚好在你回来前又 429 了一次"。
 * 预算 = maxAttempts 次；接管时长上限 = intervalSeconds × maxAttempts。
 */
import { spawn } from 'node:child_process'
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

export const name = 'codex-429-nudge'
export const inject = ['webServer']

const PLUGIN_DIR = dirname(fileURLToPath(import.meta.url))
const DSH_HOME = process.env.DSH_HOME || join(homedir(), '.dsh')
const STATE_DIR = join(DSH_HOME, 'codex-429-nudge')
const CFG_FILE = join(STATE_DIR, 'config.json')
const LOG_FILE = join(STATE_DIR, 'plugin.log')
const API_PATH = '/api/codex-429-nudge'

const DEFAULTS = {
  enabled: false,
  intervalSeconds: 300,
  maxAttempts: 6,
  usedAttempts: 0,
  startedAt: null,
  // 认哪个窗口：进程名或标题含它就算 Codex。Codex 换版本/换装法时进程名可能变，所以留个可改的口子
  windowKeyword: 'ChatGPT',
  lastCheckAt: null,
  lastFound: false,
  // 到点试一次：绝对时间戳（毫秒）。到点哪怕本轮预算已经用完，也照样试一次，这次不占预算。
  // 用途：额度要几小时后才重置，先睡到那会儿再点，别把次数浪费在明知没用的时段。
  wakeAt: null,
  // Codex 一次只显示一个会话，默认只盯当前那个。下面两个让你多盯几路：
  // scanRecent = 每次额外翻几个「屏幕上看得见的」会话（0 = 只盯当前会话）
  scanRecent: 5,
  // watchSessions = 另外指定要盯的会话标题，用 ; 分隔
  watchSessions: '',
}

function log(msg) {
  const line = `[${new Date().toISOString()}] ${msg}`
  try {
    mkdirSync(STATE_DIR, { recursive: true })
    appendFileSync(LOG_FILE, line + '\n')
  } catch {
    // 日志写不进去不该拖垮插件
  }
  console.log(`[codex-429-nudge] ${msg}`)
}

/** 把读到/收到的配置钳进合法范围，坏值一律回默认。 */
function clampCfg(raw) {
  const c = { ...DEFAULTS, ...(raw && typeof raw === 'object' ? raw : {}) }
  const intervalSeconds = Math.min(3600, Math.max(30, Math.round(Number(c.intervalSeconds) || 300)))
  const maxAttempts = Math.min(600, Math.max(1, Math.round(Number(c.maxAttempts) || 6)))
  const usedAttempts = Math.min(maxAttempts, Math.max(0, Math.round(Number(c.usedAttempts) || 0)))
  const startedAt = Number.isFinite(Number(c.startedAt)) && Number(c.startedAt) > 0 ? Number(c.startedAt) : null
  const windowKeyword = typeof c.windowKeyword === 'string' && c.windowKeyword.trim()
    ? c.windowKeyword.trim().slice(0, 120)
    : 'ChatGPT'
  const lastCheckAt = Number.isFinite(Number(c.lastCheckAt)) && Number(c.lastCheckAt) > 0 ? Number(c.lastCheckAt) : null
  const scanRecent = Math.min(20, Math.max(0, Math.round(Number(c.scanRecent) || 0)))
  const watchSessions = typeof c.watchSessions === 'string' ? c.watchSessions.trim().slice(0, 2000) : ''
  // 注意：过去的 wakeAt 不能被清掉 —— tick 正是靠"已到点"来判断要不要强制跑一次。
  // 这里只挡掉明显不合理的值（非数字、太远）。
  const wakeNum = Number(c.wakeAt)
  const wakeAt = Number.isFinite(wakeNum) && wakeNum > 0 && wakeNum < Date.now() + 7 * 86400_000
    ? Math.round(wakeNum)
    : null
  return {
    enabled: Boolean(c.enabled),
    intervalSeconds,
    maxAttempts,
    usedAttempts,
    startedAt,
    windowKeyword,
    lastCheckAt,
    lastFound: Boolean(c.lastFound),
    wakeAt,
    scanRecent,
    watchSessions,
  }
}

function loadCfg() {
  try {
    return clampCfg(JSON.parse(readFileSync(CFG_FILE, 'utf8')))
  } catch {
    return { ...DEFAULTS }
  }
}

function saveCfg(patch) {
  const next = clampCfg({ ...loadCfg(), ...(patch || {}) })
  mkdirSync(STATE_DIR, { recursive: true })
  writeFileSync(CFG_FILE, JSON.stringify(next, null, 2) + '\n')
  return next
}

/** 给界面算的那几个数：预算、剩余、最晚几点结束。 */
function statusOf(cfg) {
  const totalMs = cfg.intervalSeconds * 1000 * cfg.maxAttempts
  const remainingAttempts = Math.max(0, cfg.maxAttempts - cfg.usedAttempts)
  return {
    totalMs,
    remainingAttempts,
    remainingMs: remainingAttempts * cfg.intervalSeconds * 1000,
    endsAt: cfg.startedAt === null ? null : cfg.startedAt + totalMs,
    exhausted: remainingAttempts === 0,
    running: cfg.enabled && remainingAttempts > 0,
    usedAttempts: cfg.usedAttempts,
    // 到点试一次的时间点；界面上要显示"还剩多久"，所以放 status 里一起给
    wakeAt: cfg.wakeAt,
  }
}

function sendJson(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8' })
  res.end(JSON.stringify(body))
}

function readBody(req) {
  return new Promise((resolve) => {
    let raw = ''
    req.on('data', (chunk) => { raw += chunk })
    req.on('end', () => {
      try {
        resolve(raw ? JSON.parse(raw) : {})
      } catch {
        resolve({})
      }
    })
    req.on('error', () => resolve({}))
  })
}

export function apply(ctx) {
  mkdirSync(STATE_DIR, { recursive: true })
  if (!existsSync(CFG_FILE)) saveCfg(DEFAULTS)
  // 老版本配置里没有 startedAt：开关开着却没开始时间就补一个，界面上才不会显示"—"
  const boot = loadCfg()
  if (boot.enabled && boot.startedAt === null) saveCfg({ startedAt: Date.now() })

  const script = join(PLUGIN_DIR, 'bin', 'codex-429-nudge.ps1')
  if (!existsSync(script)) {
    log(`找不到脚本，插件不工作：${script}`)
    return
  }

  let busy = false
  let timer = null

  function planNext() {
    if (timer) {
      clearTimeout(timer)
      timer = null
    }
    const cfg = loadCfg()
    const regular = statusOf(cfg).running ? cfg.intervalSeconds * 1000 : null
    // 到点试一次的优先级高于常规节奏，而且预算用完了也照样排 —— 它就是为"预算花光了但额度快重置了"准备的
    const wake = cfg.wakeAt === null ? null : Math.max(0, cfg.wakeAt - Date.now())
    const delay = regular === null ? wake : (wake === null ? regular : Math.min(regular, wake))
    if (delay === null) return
    timer = setTimeout(tick, delay)
    timer.unref?.()
  }

  function tick() {
    const cfg = loadCfg()
    const st = statusOf(cfg)
    // 到点强制跑：不看预算，跑完把 wakeAt 清掉（一次性）
    const forced = cfg.wakeAt !== null && cfg.wakeAt <= Date.now() + 1000
    if ((!st.running && !forced) || busy) return
    busy = true
    if (forced) saveCfg({ wakeAt: null })

    // 判定只认 ASCII 字段（"acted":true 等），中文控制台会转 GBK，中文内容不可靠
    const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script,
      '-Once', '-WindowKeyword', cfg.windowKeyword, '-ScanRecent', String(cfg.scanRecent)]
    if (cfg.watchSessions) args.push('-WatchSessions', cfg.watchSessions)
    const child = spawn('powershell.exe', args, { windowsHide: true })

    let out = ''
    child.stdout.on('data', (b) => { out += b.toString('utf8') })
    child.stderr.on('data', (b) => { out += b.toString('utf8') })

    child.on('error', (err) => {
      busy = false
      log(`起不了脚本：${err?.message ?? err}`)
      planNext()
    })

    child.on('close', (code) => {
      busy = false
      const fresh = loadCfg()
      const acted = /"acted"\s*:\s*true/.test(out)
      const stalled = /"stalled"\s*:\s*true/.test(out)
      const found = /"found"\s*:\s*true/.test(out)
      const blank = /"blank"\s*:\s*true/.test(out)
      // 额度用尽（不是 429，但同样是"任务停了"）
      const limit = /"limit"\s*:\s*true/.test(out)

      // 把"刚才有没有认到 Codex 窗口"记下来，用户在设置页能一眼看出它在不在干活
      saveCfg({ lastCheckAt: Date.now(), lastFound: found })
      if (!found && !acted) log(`这一轮没找到 Codex 窗口（认的关键字：${fresh.windowKeyword}）`)

      if (acted) {
        // 额度用尽和 429 是两回事：429 等一会儿多半就好了，额度用尽得等它重置。
        // 所以这两种日志要分开写，用户翻日志时才知道该不该去设「到点再试一次」。
        const what = limit ? '额度用尽，已帮你发起重试' : '已自动点「继续」'
        if (forced) {
          // 到点试的这一下是预算之外的，不扣次数
          log(`到点试了一次：${limit ? '额度还没恢复，' : ''}已帮你点「继续」（这次不占预算）`)
        } else {
          // ⭐ 恢复运行也不清零：花掉一次就是花掉一次（离开电脑时最怕的是"刚好又 429"）
          const next = saveCfg({ usedAttempts: fresh.usedAttempts + 1 })
          const left = Math.max(0, next.maxAttempts - next.usedAttempts)
          const tail = left === 0 ? ' —— 预算用完，停手' : `（还剩 ${left} 次）`
          log(`${what}：第 ${next.usedAttempts}/${next.maxAttempts} 次${tail}`)
          if (limit) log('  如果额度还没恢复，这次会白给；可以在设置里用「到点再试一次」定到重置时间')
        }
      } else if (forced) {
        log('到点试了一次：Codex 没卡住，不用点')
      } else if (blank) {
        // 2026-10-25 早上就是这里漏了：整夜读到空界面，却当成"一切正常"，白等 7 小时。
        // 现在脚本会先把聊天会话切回来、再摇窗口；能走到这里说明两道都失败了。
        log('这一轮怎么都读不到 Codex 的对话内容（会话切不回来、窗口也摇不醒），这轮没法判断卡没卡')
      } else if (stalled) {
        log(limit ? '额度用尽，但界面上没找到可点的按钮（可能被弹窗挡住了）' : '看着像卡住了，但界面上没找到可点的按钮')
      } else if (code !== 0) {
        log(`脚本退出码 ${code}`)
      }
      planNext()
    })
  }

  // 设置页读写配置：一个来源，改完立即按新间隔排下一次
  ctx.effect(() => ctx.webServer.register({
    kind: 'prefix',
    path: API_PATH,
    handler: async (req, res) => {
      try {
        const url = new URL(req.url, 'http://127.0.0.1')

        if (req.method === 'GET' && url.pathname === API_PATH + '/config') {
          const config = loadCfg()
          return sendJson(res, 200, { ok: true, config, status: statusOf(config) })
        }

        if (req.method === 'POST' && url.pathname === API_PATH + '/config') {
          const body = await readBody(req)
          const patch = {}
          for (const k of ['enabled', 'intervalSeconds', 'maxAttempts', 'windowKeyword', 'wakeAt', 'scanRecent', 'watchSessions']) if (k in body) patch[k] = body[k]

          const before = loadCfg()
          const config = saveCfg(patch)

          // 刚打开开关、或调大了预算 ⇒ 开一轮新的接管（记开始时间）
          const opened = !before.enabled && config.enabled
          const widened = config.maxAttempts > before.maxAttempts
          if (opened || widened || config.startedAt === null) {
            const next = saveCfg({ startedAt: Date.now() })
            log(`新一轮接管开始：${Math.round(next.intervalSeconds * next.maxAttempts / 60)} 分钟内最多点 ${next.maxAttempts} 次`)
            planNext()
            return sendJson(res, 200, { ok: true, config: next, status: statusOf(next) })
          }

          log(`设置已更新：${JSON.stringify(config)}`)
          planNext()
          return sendJson(res, 200, { ok: true, config, status: statusOf(config) })
        }

        // 用户回来了 / 想再盯一轮：预算清零、重新计时
        if (req.method === 'POST' && url.pathname === API_PATH + '/reset') {
          const config = saveCfg({ usedAttempts: 0, startedAt: Date.now() })
          log(`预算已重置：还能点 ${config.maxAttempts} 次`)
          planNext()
          return sendJson(res, 200, { ok: true, config, status: statusOf(config) })
        }

        return sendJson(res, 404, { ok: false, error: `unknown ${req.method} ${url.pathname}` })
      } catch (error) {
        sendJson(res, 500, { ok: false, error: String(error?.message ?? error) })
      }
    },
  }), 'codex-429-nudge: 配置路由')

  planNext()
  // 刚打开开关/刚重载时先看一眼，别让人等满一个间隔才知道找到没
  if (statusOf(loadCfg()).running) {
    const first = setTimeout(tick, 1500)
    first.unref?.()
  }
  const cfg = loadCfg()
  const st = statusOf(cfg)
  log(st.running
    ? `已启动：每 ${cfg.intervalSeconds} 秒看一眼，本轮还剩 ${st.remainingAttempts}/${cfg.maxAttempts} 次`
    : (cfg.enabled ? '已启动，但本轮预算用完了（点「重新开始接管」）' : '插件已加载，总开关关着（设置 → Codex 自动继续 里打开）'))
}
