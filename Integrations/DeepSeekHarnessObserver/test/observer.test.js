import assert from 'node:assert/strict'
import { chmod, mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import fs from 'node:fs/promises'
import { syncBuiltinESMExports } from 'node:module'

import { apply, hostVersion } from '../lib/index.js'

async function waitFor(predicate, timeout = 1500) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    if (await predicate()) return
    await new Promise(resolve => setTimeout(resolve, 10))
  }
  assert.fail('Timed out waiting for observer state')
}

test('recovers after a failed write and emits a bounded private snapshot', async t => {
  const temporary = await mkdtemp(join(tmpdir(), 'loopfwd-observer-'))
  let dispose
  t.after(async () => {
    if (dispose) await dispose()
    delete process.env.DSH_HOME
    await chmod(temporary, 0o700)
    await rm(temporary, { recursive: true, force: true })
  })
  const blockedRoot = join(temporary, 'blocked')
  const workingRoot = join(temporary, 'working')
  await writeFile(blockedRoot, 'not a directory')
  process.env.DSH_HOME = blockedRoot

  const handlers = new Map()
  const effects = []
  const warnings = []
  let listFails = false
  let removed = false
  const ctx = {
    webStartup: { port: 4312 },
    logger: { warn: (...values) => warnings.push(values.join(' ')) },
    sessionController: {
      async list() {
        if (listFails) throw new Error('fixture read failure')
        return {
          items: removed ? [] : [{
            sessionId: 'session-a',
            cwd: '/tmp/project',
            running: true,
            updatedAt: Date.now(),
            projections: { values: { title: 'T'.repeat(200) } },
          }],
        }
      },
    },
    on(name, handler) { handlers.set(name, handler) },
    effect(factory) { effects.push(factory) },
  }

  apply(ctx)
  await waitFor(() => warnings.some(value => value.includes('could not write')))

  process.env.DSH_HOME = workingRoot
  handlers.get('session/event')(
    { id: 'session-a', header: { cwd: 'C'.repeat(1400) } },
    {
      type: 'user/message',
      time: Date.now(),
      data: { source: { kind: 'user' }, content: [{ type: 'text', text: 'P'.repeat(900) }] },
    },
  )

  const snapshotPath = join(workingRoot, 'integrations', 'loopfwd', 'web.json')
  await waitFor(async () => {
    try { return (await stat(snapshotPath)).isFile() } catch { return false }
  })

  const snapshot = JSON.parse(await readFile(snapshotPath, 'utf8'))
  assert.equal(snapshot.schemaVersion, 1)
  assert.equal(snapshot.harnessVersion, 'unknown')
  assert.ok(snapshot.sourceReadAt)
  assert.equal(snapshot.readError, null)
  assert.equal(snapshot.loopbackURL, 'http://127.0.0.1:4312')
  assert.equal(snapshot.sessions.length, 1)
  assert.equal(snapshot.sessions[0].title.length, 96)
  assert.equal(snapshot.sessions[0].lastPrompt.length, 512)
  assert.ok(snapshot.sessions[0].cwd.length <= 1024)
  assert.equal((await stat(snapshotPath)).mode & 0o777, 0o600)

  listFails = true
  handlers.get('api-session/activity')('session-a', Date.now())
  await waitFor(async () => JSON.parse(await readFile(snapshotPath, 'utf8')).readError !== null)
  const failed = JSON.parse(await readFile(snapshotPath, 'utf8'))
  assert.equal(failed.sourceReadAt, snapshot.sourceReadAt)
  assert.ok(failed.generatedAt >= snapshot.generatedAt)
  listFails = false
  removed = true
  handlers.get('api-session/removed')('session-a')
  await waitFor(async () => JSON.parse(await readFile(snapshotPath, 'utf8')).sessions.length === 0)

  dispose = effects[0]()
})

test('reports the actual CLI package version, not the observer target', async t => {
  const root = await mkdtemp(join(tmpdir(), 'loopfwd-host-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  await mkdir(join(root, 'lib'))
  const entry = join(root, 'lib', 'bin.js')
  await writeFile(entry, '')
  await writeFile(join(root, 'package.json'), JSON.stringify({ name: '@deepseek-ai/dsh', version: '0.1.1-rc.2' }))
  assert.equal(await hostVersion(entry), '0.1.1-rc.2')
  assert.equal(await hostVersion(join(root, 'missing')), 'unknown')
})

test('a non-cooperative read times out without accumulating requests and can recover', async t => {
  const root = await mkdtemp(join(tmpdir(), 'loopfwd-timeout-'))
  process.env.DSH_HOME = root
  let dispose
  let calls = 0
  let release
  const handlers = new Map()
  t.after(async () => {
    if (dispose) await dispose()
    delete process.env.DSH_HOME
    await rm(root, { recursive: true, force: true })
  })
  apply({
    webStartup: { port: 4312 }, logger: { warn() {} },
    sessionController: { list() {
      calls++
      return calls === 1 ? new Promise(resolve => { release = resolve }) : Promise.resolve({ items: [] })
    } },
    on(name, handler) { handlers.set(name, handler) },
    effect(factory) { dispose = factory() },
  })
  const file = join(root, 'integrations', 'loopfwd', 'web.json')
  const snapshot = async () => JSON.parse(await readFile(file, 'utf8'))
  await waitFor(async () => { try { return Boolean((await snapshot()).readError) } catch { return false } }, 3000)
  assert.equal((await snapshot()).sourceReadAt, null)
  const firstWrite = (await snapshot()).generatedAt
  handlers.get('api-session/activity')('session-a', Date.now())
  await waitFor(async () => (await snapshot()).generatedAt !== firstWrite)
  assert.equal(calls, 1)
  release({ items: [] })
  await new Promise(resolve => setImmediate(resolve))
  handlers.get('api-session/activity')('session-a', Date.now())
  await waitFor(async () => (await snapshot()).sourceReadAt !== null)
  assert.equal((await snapshot()).readError, null)
})

async function observedContext(t, initialItems) {
  const root = await mkdtemp(join(tmpdir(), 'loopfwd-list-contract-'))
  const originalRoot = process.env.DSH_HOME
  process.env.DSH_HOME = root
  const handlers = new Map()
  let dispose
  let list = async () => ({ items: initialItems })
  t.after(async () => {
    if (dispose) await dispose()
    if (originalRoot === undefined) delete process.env.DSH_HOME
    else process.env.DSH_HOME = originalRoot
    await rm(root, { recursive: true, force: true })
  })
  apply({
    webStartup: { port: 4312 }, logger: { warn() {} },
    sessionController: { list: () => list() },
    on(name, handler) { handlers.set(name, handler) },
    effect(factory) { dispose = factory() },
  })
  const path = join(root, 'integrations', 'loopfwd', 'web.json')
  const snapshot = async () => JSON.parse(await readFile(path, 'utf8'))
  await waitFor(async () => { try { return (await snapshot()).sourceReadAt !== null } catch { return false } })
  return {
    snapshot,
    dispose: () => dispose(),
    emit: (event, ...args) => handlers.get(event)(...args),
    list: fn => { list = fn },
    async refresh() {
      const previous = (await snapshot()).generatedAt
      // Unknown deletion schedules a read without manufacturing progress.
      handlers.get('api-session/removed')('synthetic-absent')
      await waitFor(async () => (await snapshot()).generatedAt !== previous)
      return snapshot()
    },
  }
}

test('list prompt clocks do not rewind live assistant progress or manufacture new progress', async t => {
  const old = Date.now() - 10 * 60_000
  const harness = await observedContext(t, [{ sessionId: 'a', running: true, updatedAt: old }])
  const progress = Date.now()
  harness.emit('session/event', { id: 'a' }, {
    type: 'assistant/message', time: progress, data: { message: { content: 'Synthetic reply' } },
  })
  await waitFor(async () => (await harness.snapshot()).sessions[0].updatedAt === progress)
  for (let i = 0; i < 3; i++) {
    const value = await harness.refresh()
    assert.equal(value.sessions[0].updatedAt, progress)
    assert.equal(value.sessions[0].lastMessage, 'Synthetic reply')
    assert.equal(value.readError, null)
  }
})

test('invalid and duplicate summaries preserve the last good list and successful-read time', async t => {
  const row = { sessionId: 'a', running: true, updatedAt: Date.now() - 1000 }
  const harness = await observedContext(t, [row])
  const original = await harness.snapshot()
  for (const items of [
    [{ ...row, running: false }, { ...row, sessionId: 'b', running: 'false' }],
    [row, row], [{ ...row, sessionId: ' a' }], [{ ...row, sessionId: '\0' }],
    [{ ...row, updatedAt: Infinity }], [{ ...row, updatedAt: Date.now() + 60_000 }],
    [{ ...row, updatedAt: '123' }], [null],
  ]) {
    harness.list(async () => ({ items }))
    const failed = await harness.refresh()
    assert.ok(failed.readError)
    assert.equal(failed.sourceReadAt, original.sourceReadAt)
    assert.deepEqual(failed.sessions, original.sessions)
  }
  harness.list(async () => ({ items: [] }))
  const recovered = await harness.refresh()
  assert.equal(recovered.readError, null)
  assert.equal(recovered.sessions.length, 0)
})

test('late list results cannot overwrite live status, lose a new session, or revive removal', async t => {
  const row = { sessionId: 'a', running: false, updatedAt: Date.now() - 1000 }
  const harness = await observedContext(t, [row])
  let releases = []
  harness.list(() => new Promise(resolve => { releases.push(resolve) }))
  harness.emit('api-session/removed', 'synthetic-absent')
  await waitFor(() => releases.length === 1)
  harness.emit('api-session/status', 'a', true)
  harness.emit('api-session/added', { sessionId: 'b', running: true, updatedAt: Date.now() })
  releases[0]({ items: [row] })
  await waitFor(() => releases.length === 2)
  // Inspect the first write while the follow-up read is still held. A later
  // correct snapshot must not mask a briefly wrong status or missing card.
  let value = await harness.snapshot()
  assert.equal(value.sessions.length, 2)
  assert.ok(value.sessions.every(item => item.running))
  const current = { items: [{ ...row, running: true }, { ...row, sessionId: 'b', running: true }] }
  harness.list(async () => current)
  releases[1](current)
  await waitFor(async () => (await harness.snapshot()).generatedAt !== value.generatedAt)

  releases = []
  harness.list(() => new Promise(resolve => { releases.push(resolve) }))
  harness.emit('api-session/removed', 'synthetic-absent')
  await waitFor(() => releases.length === 1)
  harness.emit('api-session/removed', 'a')
  releases[0]({ items: [row, { ...row, sessionId: 'b', running: true }] })
  await waitFor(() => releases.length === 2)
  value = await harness.snapshot()
  assert.ok(value.sessions.every(item => item.sessionId !== 'a'))
  assert.equal(value.readError, null)
  const remaining = { items: [{ ...row, sessionId: 'b', running: true }] }
  harness.list(async () => remaining)
  releases[1](remaining)
  await waitFor(async () => (await harness.snapshot()).generatedAt !== value.generatedAt)
})

test('a rejected concurrent session cannot be disguised as a successful complete read', async t => {
  const items = Array.from({ length: 512 }, (_, index) => ({
    sessionId: 'session-' + index, running: false, updatedAt: Date.now() - 1000,
  }))
  const harness = await observedContext(t, items)
  const original = await harness.snapshot()
  const releases = []
  harness.list(() => new Promise(resolve => { releases.push(resolve) }))
  harness.emit('api-session/removed', 'synthetic-absent')
  await waitFor(() => releases.length === 1)
  const added = { sessionId: 'new', running: true, updatedAt: Date.now() }
  harness.emit('api-session/added', added)
  releases[0]({ items })
  await waitFor(() => releases.length === 2)
  const incomplete = await harness.snapshot()
  assert.ok(incomplete.readError)
  assert.equal(incomplete.sourceReadAt, original.sourceReadAt)
  const updated = { items: [...items.slice(1), added] }
  harness.list(async () => updated)
  releases[1](updated)
  await waitFor(async () => (await harness.snapshot()).readError === null)
  assert.ok((await harness.snapshot()).sessions.some(item => item.sessionId === 'new'))
})

test('disposing an observer prevents a pending list from overwriting its replacement', async t => {
  const harness = await observedContext(t, [{ sessionId: 'a', running: true, updatedAt: Date.now() }])
  const original = await harness.snapshot()
  let release
  let entered = false
  harness.list(() => { entered = true; return new Promise(resolve => { release = resolve }) })
  harness.emit('api-session/removed', 'synthetic-absent')
  await waitFor(() => entered)
  await harness.dispose()
  release({ items: [] })
  // Drain the already-resolved promise and any accidental filesystem write.
  await new Promise(resolve => setTimeout(resolve, 50))
  assert.deepEqual(await harness.snapshot(), original)
})

test('replacement waits for the old observer atomic write without waiting for session reads', async t => {
  const harness = await observedContext(t, [{ sessionId: 'a', running: true, updatedAt: Date.now() }])
  const originalRename = fs.rename
  let entered = false
  let release
  const paused = new Promise(resolve => { release = resolve })
  const mocked = t.mock.method(fs, 'rename', async (...args) => {
    entered = true
    await paused
    return originalRename(...args)
  })
  syncBuiltinESMExports()
  t.after(() => { release(); mocked.mock.restore(); syncBuiltinESMExports() })
  harness.emit('api-session/status', 'a', false)
  await waitFor(() => entered)
  let stopped = false
  const stopping = harness.dispose().then(() => { stopped = true })
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(stopped, false, 'The old file write must be drained before replacement')
  release()
  await stopping
  assert.equal(stopped, true)
  mocked.mock.restore()
  syncBuiltinESMExports()
})
