/**
 * dsh-codex-429-nudge —— 浏览器半端（设置里的一页）
 *
 * client bundle 不是 ESM，是自注册脚本（抄 dsh-bili-scroll 摸出来的约定）：
 *   window.__ModuleLoader__.load({ id: '<包名>', factory: (require) => ({ inject, apply }) })
 * 进设置页靠 slots.inject('settings.section', ...) 注册一个导航项。
 *
 * 配置读写走宿主半端挂的 /api/codex-429-nudge/config，不走 DSH 的 Config schema。
 *
 * 这一页要讲的唯一一件事：**我离开的这段时间，它替我盯多久**。
 * 接管时长 = 间隔 × 次数，界面按用户填的值实时算出来给他看。
 */
window.__ModuleLoader__.load({
  id: 'dsh-codex-429-nudge',
  factory: (require) => {
    const React = require('react')
    const h = React.createElement

    const API = '/api/codex-429-nudge'

    const S = {
      page: { display: 'flex', flexDirection: 'column', gap: 20, padding: '2px 2px 12px', maxWidth: 640 },
      sec: { display: 'flex', flexDirection: 'column', gap: 10 },
      h: { fontSize: 11, fontWeight: 600, letterSpacing: '.04em', color: 'var(--dsw-alias-label-tertiary, #9aa0a6)' },
      row: { display: 'flex', alignItems: 'center', gap: 10 },
      grow: { flex: 1, minWidth: 0 },
      title: { fontSize: 13 },
      hint: { fontSize: 12, color: 'var(--dsw-alias-label-tertiary, #9aa0a6)', lineHeight: 1.55 },
      num: { width: 84, padding: '4px 8px', borderRadius: 6, border: '1px solid var(--dsw-alias-border, #d0d0d0)', background: 'transparent', color: 'inherit', fontSize: 13 },
      btn: { padding: '6px 14px', borderRadius: 8, border: 'none', cursor: 'pointer', fontSize: 13, background: 'var(--dsw-alias-accent, #2563eb)', color: '#fff' },
      btn2: { padding: '6px 14px', borderRadius: 8, cursor: 'pointer', fontSize: 13, background: 'transparent', color: 'inherit', border: '1px solid var(--dsw-alias-border, #d0d0d0)' },
      chip: { padding: '5px 12px', borderRadius: 999, cursor: 'pointer', fontSize: 12, background: 'transparent', color: 'inherit', border: '1px solid var(--dsw-alias-border, #d0d0d0)' },
      chipOn: { padding: '5px 12px', borderRadius: 999, cursor: 'pointer', fontSize: 12, background: 'var(--dsw-alias-accent, #2563eb)', color: '#fff', border: '1px solid transparent' },
      card: { display: 'flex', flexDirection: 'column', gap: 6, padding: '12px 14px', borderRadius: 10, border: '1px solid var(--dsw-alias-border, #e0e0e0)', background: 'var(--dsw-alias-bg-secondary, rgba(127,127,127,.05))' },
      kv: { display: 'flex', gap: 8, fontSize: 12.5, lineHeight: 1.6 },
      k: { width: 96, color: 'var(--dsw-alias-label-tertiary, #9aa0a6)' },
      msg: { fontSize: 12, color: 'var(--dsw-alias-label-secondary, #666)' },
    }

    // 预设：档位 = 你离开多久，这段时间里出现多少次 429 都帮你点
    const PRESETS = [
      { id: 'p30m', label: '半小时', intervalSeconds: 300, maxAttempts: 6 },
      { id: 'p2h', label: '2 小时', intervalSeconds: 300, maxAttempts: 24 },
      { id: 'p12h', label: '半天', intervalSeconds: 600, maxAttempts: 72 },
      { id: 'p24h', label: '一天', intervalSeconds: 600, maxAttempts: 144 },
    ]

    const pad = (n) => String(n).padStart(2, '0')
    const clock = (ts) => {
      const d = new Date(ts)
      return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`
    }
    const span = (ms) => {
      const m = Math.round(ms / 60000)
      if (m < 60) return `${m} 分钟`
      const hours = Math.floor(m / 60)
      const rest = m % 60
      return rest ? `${hours} 小时 ${rest} 分钟` : `${hours} 小时`
    }

    async function jfetch(url, init) {
      const res = await fetch(url, { credentials: 'same-origin', ...(init || {}) })
      const data = await res.json().catch(() => ({}))
      if (!res.ok || data.ok === false) throw new Error(data.error || 'HTTP ' + res.status)
      return data
    }

    function Row(props) {
      return h('div', { style: S.row }, h('div', { style: S.grow }, props.children), props.right)
    }

    function Panel() {
      const [cfg, setCfg] = React.useState(null)
      const [status, setStatus] = React.useState(null)
      const [msg, setMsg] = React.useState('')
      const [busy, setBusy] = React.useState(false)

      const load = React.useCallback(() => {
        jfetch(API + '/config')
          .then((d) => { setCfg(d.config); setStatus(d.status) })
          .catch((e) => setMsg('读不到配置：' + (e?.message ?? e)))
      }, [])

      React.useEffect(load, [load])

      const act = async (path, body, note) => {
        setBusy(true)
        setMsg('')
        try {
          const d = await jfetch(API + path, body === undefined ? { method: 'POST' } : {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify(body),
          })
          setCfg(d.config)
          setStatus(d.status)
          setMsg(note)
        } catch (e) {
          setMsg('保存失败：' + (e?.message ?? e))
        } finally {
          setBusy(false)
        }
      }

      if (!cfg || !status) return h('div', { style: S.page }, h('div', { style: S.msg }, msg || '加载中…'))

      const intervalMin = Math.max(0.5, Math.round((cfg.intervalSeconds / 60) * 10) / 10)
      const totalMs = cfg.intervalSeconds * 1000 * cfg.maxAttempts
      const activePreset = PRESETS.find((p) => p.intervalSeconds === cfg.intervalSeconds && p.maxAttempts === cfg.maxAttempts)

      const state = !cfg.enabled ? '已关闭' : status.exhausted ? '预算用完，已停手' : '正在盯'

      return h('div', { style: S.page },

        h('div', { style: S.sec },
          h('div', { style: S.h }, '它替你做什么'),
          h('div', { style: S.hint },
            '你离开电脑的时候，Codex 要是被上游 429 卡住，它每隔一会儿替你点一次「继续」。',
            '点了一直没好就一直点，直到用掉你给的次数；中间哪怕恢复过也会接着盯——',
            '免得"刚好在你回来前又来一次 429"。'),
        ),

        h('div', { style: S.sec },
          Row({
            children: [
              h('div', { key: 't', style: S.title }, '启用'),
              h('div', { key: 'd', style: S.hint }, '关掉就完全不动 Codex。'),
            ],
            right: h('input', {
              type: 'checkbox',
              checked: !!cfg.enabled,
              disabled: busy,
              onChange: (e) => act('/config', { enabled: e.target.checked }, e.target.checked ? '已打开' : '已关闭'),
            }),
          }),
        ),

        h('div', { style: S.sec },
          h('div', { style: S.h }, '认哪个窗口'),
          Row({
            children: [
              h('div', { key: 't', style: S.title }, '窗口关键字'),
              h('div', { key: 'd', style: S.hint }, '进程名或窗口标题里有它，就当作 Codex；可用 | 分隔多个。'),
            ],
            right: h('div', { style: S.row },
              h('input', {
                type: 'text',
                style: { ...S.num, width: 150 },
                value: cfg.windowKeyword ?? '',
                disabled: busy,
                onChange: (e) => setCfg({ ...cfg, windowKeyword: e.target.value }),
              }),
              h('button', {
                style: S.btn2,
                disabled: busy,
                onClick: () => act('/config', { windowKeyword: cfg.windowKeyword }, '已保存窗口关键字'),
              }, '保存'),
            ),
          }),
          h('div', { style: S.hint },
            '微软商店版的 Codex 进程名是 ChatGPT，默认值就行。',
            '要是换成官网版、或者哪天它改了名导致"找不到窗口"，把新进程名填这里。'),
        ),

        h('div', { style: S.sec },
          h('div', { style: S.h }, '接管多久（档位）'),
          h('div', { style: { display: 'flex', gap: 8, flexWrap: 'wrap' } },
            ...PRESETS.map((p) => h('button', {
              key: p.id,
              style: activePreset?.id === p.id ? S.chipOn : S.chip,
              disabled: busy,
              onClick: () => act('/config', { intervalSeconds: p.intervalSeconds, maxAttempts: p.maxAttempts }, `已切到「${p.label}」`),
            }, p.label)),
          ),
          h('div', { style: S.hint }, '也可以自己填：'),
          Row({
            children: [
              h('div', { key: 't', style: S.title }, '检查间隔'),
              h('div', { key: 'd', style: S.hint }, '每隔多少分钟看一眼（0.5–60）。'),
            ],
            right: h('div', { style: S.row },
              h('input', {
                type: 'number', style: S.num, min: 0.5, max: 60, step: 0.5,
                value: intervalMin, disabled: busy,
                onChange: (e) => setCfg({ ...cfg, intervalSeconds: Math.round(Number(e.target.value) * 60) || 300 }),
              }),
              h('span', { style: S.hint }, '分钟'),
            ),
          }),
          Row({
            children: [
              h('div', { key: 't', style: S.title }, '最多重试'),
              h('div', { key: 'd', style: S.hint }, '总共能点多少次（1–600），恢复不清零，用完为止。'),
            ],
            right: h('div', { style: S.row },
              h('input', {
                type: 'number', style: S.num, min: 1, max: 600,
                value: cfg.maxAttempts, disabled: busy,
                onChange: (e) => setCfg({ ...cfg, maxAttempts: Number(e.target.value) || 1 }),
              }),
              h('span', { style: S.hint }, '次'),
            ),
          }),
          h('div', { style: S.row },
            h('button', { style: S.btn, disabled: busy, onClick: () => act('/config', { intervalSeconds: cfg.intervalSeconds, maxAttempts: cfg.maxAttempts }, '已保存') }, '保存'),
            h('button', { style: S.btn2, disabled: busy, onClick: () => act('/reset', undefined, '已重新开始一轮接管') }, '重新开始接管'),
          ),
        ),

        h('div', { style: S.card },
          h('div', { style: S.kv }, h('span', { style: S.k }, '本轮上限'), h('span', {}, span(totalMs) + `（${intervalMin} 分钟 × ${cfg.maxAttempts} 次）`)),
          h('div', { style: S.kv }, h('span', { style: S.k }, '已用'), h('span', {}, `${status.usedAttempts} 次，还剩 ${status.remainingAttempts} 次`)),
          h('div', { style: S.kv }, h('span', { style: S.k }, '还能盯'), h('span', {}, status.exhausted ? '0（预算用完了）' : span(status.remainingMs))),
          h('div', { style: S.kv }, h('span', { style: S.k }, '本轮开始'), h('span', {}, cfg.startedAt ? clock(cfg.startedAt) : '—')),
          h('div', { style: S.kv }, h('span', { style: S.k }, '最晚结束'), h('span', {}, status.endsAt ? clock(status.endsAt) : '—')),
          h('div', { style: S.kv }, h('span', { style: S.k }, '现在'), h('span', {}, state)),
          h('div', { style: S.kv }, h('span', { style: S.k }, '上次检查'), h('span', {}, cfg.lastCheckAt ? clock(cfg.lastCheckAt) : '还没检查过')),
          h('div', { style: S.kv }, h('span', { style: S.k }, '找到 Codex'), h('span', {},
            cfg.lastFound ? '找到了' : (cfg.lastCheckAt ? '没找到 —— 改上面的窗口关键字' : '—'))),
        ),

        h('div', { style: S.sec },
          h('div', { style: S.h }, '说清楚一件事'),
          h('div', { style: S.hint },
            '它不绕过 429 —— 429 是上游的额度/限流，插件只是把「重新发起请求」这个动作自动化。',
            '上游没缓过来，点了还是 429；它做的是替你把重试的机会一个不落地用掉。'),
          h('div', { style: S.hint }, '日志：%USERPROFILE%\\.dsh\\codex-429-nudge\\plugin.log'),
        ),

        msg ? h('div', { style: S.msg }, msg) : null,
      )
    }

    return {
      inject: ['slots'],
      apply(ctx) {
        const slots = ctx.get('slots')
        slots.inject('settings.section', () => slots.register(
          { name: 'settings.section', id: 'codex-429-nudge', order: 32, label: 'Codex 429 重试' },
          () => h(Panel),
        ))
      },
    }
  },
})
