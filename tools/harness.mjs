#!/usr/bin/env node
/**
 * Offline harness for dsh-plugin-permission-notify.
 *
 * Boots the plugin against a minimal fake cordis context, so the wiring can be
 * checked without restarting DeepSeek Harness. Run from a directory whose
 * node_modules resolves @deepseek-ai/schemastery (the installer's junction, or
 * a temporary copy as done by tools/verify-plugin.ps1).
 *
 *   node tools/harness.mjs <path-to-plugin-index.js>
 */
import { readFileSync, rmSync } from 'node:fs'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const indexPath = process.argv[2]
if (!indexPath) {
  console.error('usage: node tools/harness.mjs <path-to-plugin-index.js>')
  process.exit(2)
}

const mod = await import(pathToFileURL(indexPath).href)
const logFile = resolve('.scratch/harness-notify.log')
rmSync(logFile, { force: true })

// ---------------------------------------------------------------- fake cordis
const listeners = new Map()
const effects = []
let injected = 0
const presetCalls = []

const fakePermissions = {
  names: ['workspace-write', 'danger-full-access', 'auto'],
  current: () => 'workspace-write',
  set: (session, name) => presetCalls.push({ id: session.id, name }),
}

const sessions = []

const ctx = {
  logger: () => ({ info: () => {}, warn: () => {}, error: () => {} }),
  on(eventName, handler) {
    const list = listeners.get(eventName) ?? []
    list.push(handler)
    listeners.set(eventName, list)
    return () => {}
  },
  effect(fn) {
    const dispose = fn()
    effects.push(dispose)
    return dispose
  },
  inject(_deps, callback) {
    injected += 1
    callback({
      ...ctx,
      permissionPresets: fakePermissions,
      sessions: { list: () => sessions },
      agents: { list: () => sessions.map((session) => ({ session })) },
    })
    return () => {}
  },
  get: () => undefined,
}

const emit = (eventName, ...args) => {
  for (const handler of listeners.get(eventName) ?? []) handler(...args)
}

const config = mod.Config({
  sound: process.env.NOTIFY_SOUND === '1',
  logFile,
})

const root = { id: 'sess-root', header: { cwd: 'D:\\work\\demo-project', origin: 'main' } }
const root2 = { id: 'sess-root-2', header: { cwd: 'D:\\work\\other', origin: 'main' } }
const child = { id: 'sess-child', header: { cwd: 'D:\\work\\demo-project', origin: 'subagent', parentSession: 'sess-root' } }
sessions.push(root2)

mod.apply(ctx, config)

// ---------------------------------------------------------------- assertions
let failures = 0
const check = (label, condition, extra = '') => {
  if (condition) {
    console.log(`  ok   ${label}`)
  } else {
    failures += 1
    console.log(`  FAIL ${label} ${extra}`)
  }
}

check('injected permissionPresets + agents', injected === 1, `(${injected})`)

// existing root session must be switched on mount; child sessions must not
check(
  'mount sweep applies default preset to existing root session only',
  presetCalls.length === 1 && presetCalls[0].id === 'sess-root-2' && presetCalls[0].name === 'auto',
  JSON.stringify(presetCalls),
)

// current dsh announces agents; this path is append-legal and synchronous.
emit('agent/created', { agent: { session: root } })
check(
  'agent/created applies auto to a new root session',
  presetCalls.some((call) => call.id === 'sess-root' && call.name === 'auto'),
  JSON.stringify(presetCalls),
)

emit('agent/created', { agent: { session: child } })
check(
  'agent/created skips a subagent session',
  !presetCalls.some((call) => call.id === 'sess-child'),
  JSON.stringify(presetCalls),
)

// older dsh only emits session/created, where appends are still blocked:
// the plugin must defer one macrotask and then succeed.
const deferred = { id: 'sess-deferred', header: { cwd: 'D:\\work\\deferred', origin: 'main' } }
emit('session/created', deferred)
const appliedImmediately = presetCalls.some((call) => call.id === 'sess-deferred')
await new Promise((resolve) => setTimeout(resolve, 30))
check('session/created defers the append instead of failing', !appliedImmediately)
check(
  'deferred session/created applies auto afterwards',
  presetCalls.some((call) => call.id === 'sess-deferred' && call.name === 'auto'),
  JSON.stringify(presetCalls),
)

// a host that rejects the append with the announcement guard must be retried.
const guardedSession = { id: 'sess-guard', header: { cwd: 'D:\\work\\guard', origin: 'main' } }
let guardThrown = 0
const originalSet = fakePermissions.set
fakePermissions.set = (session, name) => {
  if (session.id === 'sess-guard' && guardThrown === 0) {
    guardThrown += 1
    throw new Error(`session "${session.id}" cannot append before session/created completes`)
  }
  originalSet(session, name)
}
emit('agent/created', { agent: { session: guardedSession } })
await new Promise((resolve) => setTimeout(resolve, 120))
check('announcement-guard rejection is retried', guardThrown === 1 && presetCalls.some((call) => call.id === 'sess-guard'))

const readLog = () => {
  try {
    return readFileSync(logFile, 'utf8')
  } catch {
    return ''
  }
}
const clearLog = () => rmSync(logFile, { force: true })
// Helper processes log asynchronously; let them settle before a clean slate.
const settle = async () => {
  await new Promise((resolve) => setTimeout(resolve, 500))
  clearLog()
  await new Promise((resolve) => setTimeout(resolve, 60))
}

emit('session/event', root, {
  type: 'assistant/message',
  data: { message: { content: [{ type: 'text', text: '我已经把权限预设改成自动审查，接下来跑一遍自测。' }] } },
})
emit('session/event', root, { type: 'turn/end', data: { turn: 1, reason: { kind: 'completed' } } })
await new Promise((resolve) => setTimeout(resolve, 400))
check('turn/end completed notifies', readLog().includes('kind=done'), JSON.stringify(readLog().slice(0, 200)))
check(
  'notification quotes the assistant answer',
  readLog().includes('snippet="我已经把权限预设改成自动审查'),
  JSON.stringify(readLog().slice(0, 300)),
)

await settle()
emit('session/event', root, { type: 'turn/end', data: { turn: 2, reason: { kind: 'aborted' } } })
await new Promise((resolve) => setTimeout(resolve, 120))
check('aborted turn does not notify', !readLog().includes('notify kind='), JSON.stringify(readLog().slice(0, 200)))

emit('session/event', root, { type: 'approval/asked', data: { toolName: 'pwsh' } })
await new Promise((resolve) => setTimeout(resolve, 1400))
check('approval/asked notifies', readLog().includes('kind=approval'), JSON.stringify(readLog().slice(0, 200)))

emit('session/event', root, {
  type: 'tool/call',
  data: { name: 'ask_user_question', arguments: JSON.stringify({ questions: [{ header: '选择方案' }] }) },
})
await new Promise((resolve) => setTimeout(resolve, 1400))
check('ask_user_question notifies', readLog().includes('kind=question'), JSON.stringify(readLog().slice(0, 300)))

await settle()
emit('session/event', child, { type: 'turn/end', data: { turn: 1, reason: { kind: 'completed' } } })
await new Promise((resolve) => setTimeout(resolve, 120))
check('subagent turn does not notify', !readLog().includes('notify kind='), JSON.stringify(readLog().slice(0, 200)))

check('Config resolves defaults', config.defaultPreset === 'auto' && config.appId === 'com.deepseek.dsh' && config.sound === (process.env.NOTIFY_SOUND === '1'))

// Optional end-to-end check of the PowerShell helper when a real visual is on.
if (process.env.NOTIFY_TEST_HELPER === '1') {
  clearLog()
  emit('session/event', root, { type: 'turn/end', data: { turn: 9, reason: { kind: 'completed' } } })
  await new Promise((resolve) => setTimeout(resolve, 3000))
  const text = readLog()
  check('helper wrote its delivery log', /\[(helper|exe)\]/.test(text), JSON.stringify(text.slice(0, 300)))
  console.log('  --- helper log ---\n' + text.trim().split('\n').map((line) => '  ' + line).join('\n'))
}

console.log(failures === 0 ? '\nALL CHECKS PASSED' : `\n${failures} CHECK(S) FAILED`)
process.exit(failures === 0 ? 0 : 1)
