/**
 * dsh-plugin-permission-notify
 *
 * Two host-side capabilities for DeepSeek Harness:
 *
 * 1. Default permission preset — dsh keeps `auto` (Auto review) out of the
 *    future-session default on purpose; this plugin re-applies a chosen preset
 *    (`auto` by default) to every root session, on creation and on mount.
 * 2. Windows notifications — a native Windows toast (with its system sound)
 *    whenever a turn finishes or the agent is blocked on a user decision
 *    (approval request / ask_user_question).
 *
 * No build step: plain ESM, resolved from the owning profile's node_modules.
 */
import { spawn } from 'node:child_process'
import { appendFileSync, existsSync, mkdirSync } from 'node:fs'
import { basename, dirname, join } from 'node:path'
import { homedir } from 'node:os'
import { fileURLToPath } from 'node:url'
import Schema from '@deepseek-ai/schemastery'

/** Loader identity used in diagnostics. */
export const name = 'permission-notify'

const HERE = dirname(fileURLToPath(import.meta.url))
const NOTIFY_SCRIPT = join(HERE, 'assets', 'notify.ps1')

/** Preset names accepted for `defaultPreset`; `off` disables that half. */
const OFF_VALUES = new Set(['', 'off', 'none', 'keep', 'false'])

export const Config = Schema.object({
  defaultPreset: Schema.string()
    .default('auto')
    .description(
      '新建会话（以及插件挂载时的现存会话）使用的权限预设：auto=自动审查，danger-full-access / workspace-write 或任意自定义预设名；off/留空=不改动。',
    ),
  applyToExistingSessions: Schema.boolean()
    .default(true)
    .description('插件挂载时，是否把默认预设也应用到已经存在的根会话。'),
  notifyTurnEnd: Schema.boolean().default(true).description('一轮回答结束时弹 Windows 通知。'),
  notifyApproval: Schema.boolean().default(true).description('需要确认操作（审批）时弹通知。'),
  notifyQuestion: Schema.boolean().default(true).description('ask_user_question 需要你选择时弹通知。'),
  sound: Schema.boolean().default(true).description('是否带系统提示音。'),
  includeSnippet: Schema.boolean()
    .default(true)
    .description('通知里附带最近一条回答的开头片段，而不是只有通用文字。'),
  snippetChars: Schema.number().default(120).description('片段最大字符数。'),
  clickToFocus: Schema.boolean().default(true).description('点击通知时把 DSH 窗口切到前台（走安装时注册的 dshnotify: 协议）。'),
  appId: Schema.string()
    .default('com.deepseek.dsh')
    .description(
      'Windows 通知的 AppUserModelID：默认用 DSH 桌面端开始菜单快捷方式里注册的 com.deepseek.dsh，通知会显示成 DeepSeek Harness。',
    ),
  minIntervalMs: Schema.number().default(1200).description('同类提示的最小间隔（毫秒），用于去重。'),
  logFile: Schema.string().default('').description('通知投递日志路径；留空写到 ~/.dsh/logs/permission-notify.log。'),
})

/** Resolve the effective log file path. */
function resolveLogFile(configured) {
  if (configured && configured.trim() !== '') return configured.trim()
  return join(process.env.DSH_HOME || join(homedir(), '.dsh'), 'logs', 'permission-notify.log')
}

/** Append one diagnostic line; failures are non-fatal. */
function logLine(ctx, file, message) {
  try {
    mkdirSync(dirname(file), { recursive: true })
    appendFileSync(file, `${new Date().toISOString()} ${message}\n`, 'utf8')
  } catch {
    /* diagnostics must never break the host */
  }
  try {
    ctx.logger?.('permission-notify')?.info?.(message)
  } catch {
    /* logger is best-effort */
  }
}

/** Whether this session is a root conversation rather than a delegated child. */
function isRootSession(session) {
  const header = session?.header
  if (!header || typeof header !== 'object') return true
  if (header.origin === 'subagent') return false
  if (header.parentSession !== undefined) return false
  return true
}

/** Short project label for the notification title. */
function projectOf(session) {
  const cwd = session?.header?.cwd
  if (typeof cwd === 'string' && cwd !== '') return basename(cwd)
  return 'DSH'
}

const BODY_BY_KIND = {
  done: '回答完成',
  approval: '需要你确认操作',
  question: '需要你做出选择',
}

/**
 * Collapse one assistant answer into a one-line notification snippet:
 * code fences become a short marker, whitespace is flattened, and the result is
 * clipped to `max` characters.
 * @param text - newest assistant text, if any.
 * @param max - character budget from config.
 * @returns the snippet, or '' when there is nothing worth quoting.
 */
function makeSnippet(text, max) {
  if (typeof text !== 'string' || text.trim() === '') return ''
  const clean = text
    .replace(/```[\s\S]*?```/g, ' [代码] ')
    .replace(/\s+/g, ' ')
    .trim()
  if (clean === '') return ''
  const limit = Math.max(20, Number(max) || 120)
  return clean.length > limit ? `${clean.slice(0, limit)}…` : clean
}

/**
 * Install both capabilities.
 * @param ctx - profile-scoped cordis context.
 * @param config - resolved {@link Config} values.
 */
export function apply(ctx, config) {
  const logFile = resolveLogFile(config.logFile)
  const state = {
    lastByKind: new Map(),
    warnedMissingPresets: false,
    /** sessionId -> newest assistant text, used as the notification snippet. */
    lastAssistant: new Map(),
  }
  logLine(
    ctx,
    logFile,
    `mounted: defaultPreset=${config.defaultPreset || 'off'} appId=${config.appId} sound=${config.sound} ` +
      `turnEnd=${config.notifyTurnEnd} approval=${config.notifyApproval} question=${config.notifyQuestion}`,
  )

  //#region notifications
  const deliver = (kind, session, detail) => {
    const now = Date.now()
    const last = state.lastByKind.get(kind) ?? 0
    if (now - last < Math.max(0, config.minIntervalMs)) return
    state.lastByKind.set(kind, now)

    const title = `DeepSeek Harness · ${projectOf(session)}`
    const body = detail ? `${BODY_BY_KIND[kind]} — ${detail}` : BODY_BY_KIND[kind]
    const snippet = config.includeSnippet
      ? makeSnippet(state.lastAssistant.get(session?.id), config.snippetChars)
      : ''
    logLine(ctx, logFile, `notify kind=${kind} session=${session?.id ?? '-'} body="${body}" snippet="${snippet}"`)
    spawnNotifier(
      ctx,
      {
        title,
        body,
        detail: snippet,
        kind,
        sound: config.sound,
        appId: config.appId,
        logFile,
        clickToFocus: config.clickToFocus,
      },
      logFile,
    )
  }

  ctx.effect(() => {
    const off = []
    off.push(
      ctx.on('session/event', (session, event) => {
        try {
          if (!isRootSession(session)) return
          const type = event?.type
          // Track the newest assistant text so notifications can quote it
          // instead of repeating a generic template.
          if (type === 'assistant/message') {
            const blocks = event?.data?.message?.content
            if (Array.isArray(blocks)) {
              const text = blocks
                .filter((block) => block?.type === 'text' && typeof block.text === 'string')
                .map((block) => block.text)
                .join('\n')
                .trim()
              if (text !== '') state.lastAssistant.set(session.id, text)
            }
            return
          }
          if (type === 'turn/start') {
            state.lastAssistant.delete(session.id)
            return
          }
          if (type === 'turn/end') {
            if (!config.notifyTurnEnd) return
            const kind = event?.data?.reason?.kind
            // `completed` / `max-tokens` mean the model finished speaking;
            // `blocked` / `aborted` / `error` end a turn without an answer to read.
            if (kind === 'completed' || kind === 'max-tokens') deliver('done', session)
            return
          }
          if (type === 'approval/asked') {
            if (!config.notifyApproval) return
            deliver('approval', session, toolNameOfApproval(event))
            return
          }
          if (type === 'tool/call' && event?.data?.name === 'ask_user_question') {
            if (!config.notifyQuestion) return
            deliver('question', session, questionHint(event?.data?.arguments))
            return
          }
          if (type === 'tool/ptc-dispatch' && event?.data?.name === 'ask_user_question' && !event?.data?.isError) {
            if (!config.notifyQuestion) return
            deliver('question', session)
          }
        } catch (error) {
          logLine(ctx, logFile, `session/event hook failed: ${error instanceof Error ? error.message : String(error)}`)
        }
      }),
    )
    return () => {
      for (const dispose of off) {
        try {
          dispose?.()
        } catch {
          /* ignore */
        }
      }
    }
  }, 'permission-notify: session events')

  // The questions service asks through a waterfall; catch the same moment when
  // the gate is reached, so the notification still fires if the tool-call event
  // was folded away (restored or PTC sessions).
  ctx.effect(() => {
    try {
      return ctx.on('user-questions/request', async (request, next) => {
        try {
          if (config.notifyQuestion && isRootSession(request?.agent?.session)) deliver('question', request.agent.session)
        } catch {
          /* notification only */
        }
        return next()
      })
    } catch {
      return () => {}
    }
  }, 'permission-notify: user-questions gate')
  //#endregion

  //#region default permission preset
  const targetPreset = String(config.defaultPreset ?? '').trim()
  if (OFF_VALUES.has(targetPreset.toLowerCase())) {
    logLine(ctx, logFile, 'defaultPreset disabled; permission part inactive')
    return
  }

  ctx.inject(['permissionPresets', 'sessions'], (child) => {
    const permissions = child.permissionPresets
    const applyDefault = (session, reason) => {
      try {
        if (!isRootSession(session)) return
        const available = permissions.names ?? []
        if (!available.includes(targetPreset)) {
          if (!state.warnedMissingPresets) {
            state.warnedMissingPresets = true
            logLine(
              ctx,
              logFile,
              `defaultPreset "${targetPreset}" is not available (have: ${available.join(', ')}); ` +
                'enable the @deepseek-ai/dsh-experimental-auto-review bundle for auto',
            )
          }
          return
        }
        if (permissions.current(session) === targetPreset) return
        permissions.set(session, targetPreset)
        logLine(ctx, logFile, `permission preset -> ${targetPreset} (${reason}) session=${session?.id ?? '-'}`)
      } catch (error) {
        logLine(
          ctx,
          logFile,
          `failed to apply preset ${targetPreset} (${reason}): ${error instanceof Error ? error.message : String(error)}`,
        )
      }
    }

    child.effect(() => {
      const disposers = [child.on('session/created', (session) => applyDefault(session, 'created'))]
      if (config.applyToExistingSessions) {
        try {
          for (const session of child.sessions.list()) applyDefault(session, 'mounted')
        } catch (error) {
          logLine(ctx, logFile, `existing-session sweep failed: ${error instanceof Error ? error.message : String(error)}`)
        }
      }
      return () => {
        for (const dispose of disposers) {
          try {
            dispose?.()
          } catch {
            /* ignore */
          }
        }
      }
    }, 'permission-notify: default preset')
  })
  //#endregion
}

/** Best-effort tool name carried by an approval audit event. */
function toolNameOfApproval(event) {
  const data = event?.data
  if (!data || typeof data !== 'object') return undefined
  for (const key of ['toolName', 'tool', 'name']) {
    if (typeof data[key] === 'string' && data[key] !== '') return data[key]
  }
  return undefined
}

/** Best-effort first-question hint from `ask_user_question` arguments. */
function questionHint(rawArguments) {
  if (typeof rawArguments !== 'string' || rawArguments === '') return undefined
  try {
    const parsed = JSON.parse(rawArguments)
    const first = Array.isArray(parsed?.questions) ? parsed.questions[0] : undefined
    const header = first?.header ?? first?.question ?? first?.prompt
    if (typeof header === 'string' && header.trim() !== '') return header.trim().slice(0, 40)
  } catch {
    /* raw arguments are model output; ignore */
  }
  return undefined
}

/**
 * Spawn the PowerShell helper that raises the Windows toast and its sound.
 *
 * `detached` must stay off: a detached PowerShell child exits before doing its
 * work on Windows (observed: exit code 0, no toast, no log).
 */
function spawnNotifier(ctx, payload, logFile) {
  try {
    if (process.platform !== 'win32') {
      logLine(ctx, logFile, `notify skipped: unsupported platform ${process.platform}`)
      return
    }
    if (!existsSync(NOTIFY_SCRIPT)) {
      logLine(ctx, logFile, `notify helper missing: ${NOTIFY_SCRIPT}`)
      return
    }
    const encoded = Buffer.from(JSON.stringify(payload), 'utf8').toString('base64')
    const child = spawn(
      process.env.DSH_NOTIFY_POWERSHELL || 'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        NOTIFY_SCRIPT,
        '-Data',
        encoded,
      ],
      { stdio: 'ignore', windowsHide: true },
    )
    child.on?.('error', (error) => logLine(ctx, logFile, `notify spawn failed: ${error.message}`))
  } catch (error) {
    logLine(ctx, logFile, `notify dispatch failed: ${error instanceof Error ? error.message : String(error)}`)
  }
}
