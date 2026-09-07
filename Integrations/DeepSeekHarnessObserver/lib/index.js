import { chmod, mkdir, open, readFile, realpath, rename } from 'node:fs/promises'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'

export const name = 'loopfwd-observer'
export const inject = ['sessionController', 'webStartup']

const MAX_TITLE = 96
const MAX_TEXT = 512
const MAX_PATH = 1024
const MAX_SESSIONS = 512

function validIdentity(id) {
  return typeof id === 'string' && id.length > 0 && Buffer.byteLength(id) <= 256
    && id.trim() === id && !/[\u0000-\u001f\u007f]/u.test(id)
}

function validTime(value) {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= Date.now() + 30_000
}

// Read the actual boot executable's package, never the observer's target version.
export async function hostVersion(entry = process.argv[1]) {
  try {
    let directory = dirname(await realpath(entry))
    for (let depth = 0; depth < 8; depth++) {
      try {
        const manifest = JSON.parse(await readFile(join(directory, 'package.json'), 'utf8'))
        if (manifest.name === '@deepseek-ai/dsh') return bounded(manifest.version, MAX_TITLE) || 'unknown'
      } catch { /* Keep walking toward the CLI package root. */ }
      const parent = dirname(directory)
      if (parent === directory) break
      directory = parent
    }
  } catch { /* Unknown host is incompatible, not the supported version. */ }
  return 'unknown'
}

function bounded(value, limit) {
  if (typeof value !== 'string') return undefined
  const compact = value.slice(0, limit * 4).trim()
  if (!compact) return undefined
  return Array.from(compact).slice(0, limit).join('')
}

function textContent(value) {
  if (typeof value === 'string') return value
  if (!Array.isArray(value)) return undefined
  const text = value
    .slice(0, 32)
    .filter(part => part && typeof part === 'object' && part.type === 'text')
    .map(part => typeof part.text === 'string' ? part.text.slice(0, MAX_TEXT * 4) : '')
    .filter(Boolean)
    .join('\n')
  return text || undefined
}

function outputPath() {
  const root = process.env.DSH_HOME || join(homedir(), '.dsh')
  return join(root, 'integrations', 'loopfwd', 'web.json')
}

async function atomicWrite(path, value) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 })
  const temporary = path + '.tmp-' + process.pid
  const handle = await open(temporary, 'w', 0o600)
  try {
    await handle.writeFile(JSON.stringify(value))
    await handle.sync()
  } finally {
    await handle.close()
  }
  await chmod(temporary, 0o600)
  await rename(temporary, path)
  await chmod(path, 0o600)
}

function loopbackURL(ctx) {
  const port = Number(ctx.webStartup?.port ?? 3080)
  return 'http://127.0.0.1:' + (Number.isFinite(port) ? port : 3080)
}

export function apply(ctx) {
  const rows = new Map()
  const revisions = new Map()
  let revision = 0
  let rejectedEvents = 0
  let timer
  let writing = false
  let pending = false
  let disposed = false
  let sourceReadAt = null
  let readError = null
  let listInFlight = null
  let fileWriteInFlight = null
  let removedDuringRead = null
  const version = hostVersion()

  function ensure(id, seed = {}) {
    if (!validIdentity(id)) {
      rejectedEvents++
      readError = 'Invalid session identity'
      return
    }
    const key = bounded(id, 256)
    if (!key) return
    if (!rows.has(key) && rows.size >= MAX_SESSIONS) {
      rejectedEvents++
      readError = 'Session limit reached; observation is incomplete'
      return
    }
    const current = rows.get(key) || {
      sessionId: key,
      running: false,
      updatedAt: 0,
    }
    const next = { ...current, ...seed, sessionId: key,
      updatedAt: Math.max(current.updatedAt, validTime(seed.updatedAt) ? seed.updatedAt : 0) }
    rows.set(key, next)
    revisions.set(key, ++revision)
    return next
  }

  async function refreshList() {
    let timeout
    let removed
    try {
      // A non-cooperative host must neither block snapshot heartbeats forever
      // nor accumulate another never-settling request on every timer tick.
      if (listInFlight) throw new Error('Previous list request is still pending')
      const startedAtRevision = revision
      const startedAtRejections = rejectedEvents
      removed = new Set()
      removedDuringRead = removed
      const operation = Promise.resolve().then(() => ctx.sessionController.list({}, AbortSignal.timeout(1500)))
      listInFlight = operation
      operation.then(() => { if (listInFlight === operation) listInFlight = null },
        () => { if (listInFlight === operation) listInFlight = null })
      const result = await Promise.race([operation, new Promise((_, reject) => {
        timeout = setTimeout(() => reject(new Error('List read timed out')), 1500)
      })])
      if (!result || !Array.isArray(result.items) || result.items.length > MAX_SESSIONS) {
        throw new Error('Session list exceeds the supported observation budget')
      }
      // Never claim a complete scan when a host adds pagination we cannot read.
      if (result.nextCursor || result.hasMore) throw new Error('Session list requires pagination')
      const next = new Map()
      const seen = new Set()
      for (const item of result.items || []) {
        if (!item || !validIdentity(item.sessionId) || seen.has(item.sessionId)
          || typeof item.running !== 'boolean' || !validTime(item.updatedAt)) {
          throw new Error('Invalid or duplicate session summary')
        }
        seen.add(item.sessionId)
        const projections = item.projections?.values || {}
        const modelSelection = projections.modelSelection?.next
          || projections.modelSelection?.lastUsed
        if (removed.has(item.sessionId)) continue
        const previous = rows.get(item.sessionId)
        // An event received while the list awaited storage is newer than that
        // read. The next scan will reconcile it; do not overwrite it now.
        if ((revisions.get(item.sessionId) || 0) > startedAtRevision) {
          next.set(item.sessionId, previous)
          continue
        }
        next.set(item.sessionId, {
          ...previous,
          sessionId: item.sessionId,
          cwd: bounded(item.cwd, MAX_PATH),
          title: bounded(projections.title, MAX_TITLE),
          running: item.running === true,
          // The official list clock is max(createdAt,lastPromptAt), not
          // assistant/tool progress. Periodic list reads must not rewind it.
          updatedAt: Math.max(previous?.updatedAt || 0, item.updatedAt),
          model: bounded(modelSelection?.model, MAX_TITLE),
        })
      }
      for (const [id, previous] of rows) {
        if ((revisions.get(id) || 0) > startedAtRevision) next.set(id, previous)
      }
      if (next.size > MAX_SESSIONS || removed.size > MAX_SESSIONS) throw new Error('Concurrent list exceeds budget')
      if (rejectedEvents !== startedAtRejections) throw new Error('A concurrent event could not be retained')
      // Commit only after the entire response validates; a bad row must not
      // silently drop good sessions or advance the successful-read clock.
      rows.clear()
      for (const [id, value] of next) rows.set(id, value)
      for (const id of revisions.keys()) if (!rows.has(id)) revisions.delete(id)
      sourceReadAt = new Date().toISOString()
      readError = null
    } catch (error) {
      readError = 'Session list unavailable or incomplete'
      ctx.logger.warn('LoopFwd observer could not refresh session list')
    } finally {
      if (removedDuringRead === removed) removedDuringRead = null
      clearTimeout(timeout)
    }
  }

  async function writeSnapshot() {
    if (writing) {
      pending = true
      return
    }
    writing = true
    try {
      do {
        pending = false
        await refreshList()
        const harnessVersion = await version
        if (disposed) return
        const snapshot = {
          schemaVersion: 1,
          harnessVersion,
          generatedAt: new Date().toISOString(),
          sourceReadAt,
          readError,
          loopbackURL: loopbackURL(ctx),
          sessions: [...rows.values()]
            .sort((a, b) => b.updatedAt - a.updatedAt),
        }
        const operation = atomicWrite(outputPath(), snapshot)
        fileWriteInFlight = operation
        try { await operation } finally {
          if (fileWriteInFlight === operation) fileWriteInFlight = null
        }
      } while (pending && !disposed)
    } catch (error) {
      ctx.logger.warn('LoopFwd observer could not write its snapshot')
    } finally {
      writing = false
      if (pending && !disposed) queueMicrotask(() => { void writeSnapshot() })
    }
  }

  function schedule() {
    if (disposed) return
    pending = true
    queueMicrotask(() => { void writeSnapshot() })
  }

  ctx.on('api-session/added', summary => {
    if (!summary || typeof summary.running !== 'boolean' || !validTime(summary.updatedAt)) return
    ensure(summary.sessionId, {
      cwd: bounded(summary.cwd, MAX_PATH),
      running: summary.running === true,
      updatedAt: summary.updatedAt,
    })
    schedule()
  })
  ctx.on('api-session/removed', sessionId => {
    if (!validIdentity(sessionId)) return
    rows.delete(sessionId)
    revisions.delete(sessionId)
    // A bounded tombstone prevents an older in-flight list reviving deletion.
    if (removedDuringRead && removedDuringRead.size <= MAX_SESSIONS) removedDuringRead.add(sessionId)
    schedule()
  })
  ctx.on('api-session/status', (sessionId, running) => {
    if (typeof running !== 'boolean') return
    ensure(sessionId, { running: running === true, updatedAt: Date.now() })
    schedule()
  })
  ctx.on('api-session/activity', (sessionId, at) => {
    if (!validTime(at)) return
    ensure(sessionId, { updatedAt: at })
    schedule()
  })
  ctx.on('session/event', (session, event) => {
    if (!session || !event || !validTime(event.time)) return
    if (!['session/title', 'user/message', 'assistant/message', 'request/header'].includes(event.type)) return
    const update = {
      cwd: bounded(session.header?.cwd, MAX_PATH),
      updatedAt: event.time,
    }
    if (event.type === 'session/title') {
      update.title = bounded(event.data?.title, MAX_TITLE)
    } else if (event.type === 'user/message' && event.data?.source?.kind === 'user') {
      update.lastPrompt = bounded(textContent(event.data?.content), MAX_TEXT)
    } else if (event.type === 'assistant/message') {
      update.lastMessage = bounded(textContent(event.data?.message?.content), MAX_TEXT)
    } else if (event.type === 'request/header') {
      update.model = bounded(event.data?.header?.config?.model, MAX_TITLE)
    }
    ensure(session.id, update)
    schedule()
  })

  timer = setInterval(schedule, 2000)
  void writeSnapshot()
  ctx.effect(() => async () => {
    disposed = true
    clearInterval(timer)
    pending = false
    // Let an already-started atomic write finish before Cordis starts a
    // replacement observer. Never await an uncooperative session-list read.
    if (fileWriteInFlight) await fileWriteInFlight.catch(() => {})
  }, 'LoopFwd observer lifecycle')
}
