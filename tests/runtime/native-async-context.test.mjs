import assert from 'node:assert/strict'
import { AsyncLocalStorage, AsyncResource, createHook } from 'node:async_hooks'
import { EventEmitter, once } from 'node:events'
import { basename } from 'node:path'
import { setTimeout as delay, setImmediate as immediate, setInterval as interval } from 'node:timers/promises'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)

// Validation and an already-aborted signal must reject the returned promise.
assert.equal(once.constructor.name, 'AsyncFunction')
let invalid
assert.doesNotThrow(() => { invalid = once(null, 'data') })
await assert.rejects(invalid, TypeError)
const controller = new AbortController()
const reason = new Error('already aborted')
controller.abort(reason)
let aborted
assert.doesNotThrow(() => { aborted = once(new EventEmitter(), 'data', { signal: controller.signal }) })
await assert.rejects(aborted, error => error.name === 'AbortError' && error.cause === reason)

// Shared callbacks must remain independently removable and keep registration
// order. Double enable/disable must not duplicate or remove another hook.
const calls = []
const shared = (id, type) => {
  if (type === 'TickObject') {
    assert.ok(Number.isInteger(id) && id > 0)
    calls.push('shared')
  }
}
const first = createHook({ init: shared })
const middle = createHook({ init(id, type) { if (type === 'TickObject') calls.push('middle') } })
const last = createHook({ init: shared })
try {
  first.enable().enable()
  middle.enable()
  last.enable()
  first.disable().disable()
  process.nextTick(() => {})
  assert.deepEqual(calls, ['middle', 'shared'])
  calls.length = 0
  last.disable()
  first.enable()
  process.nextTick(() => {})
  assert.deepEqual(calls, ['middle', 'shared'])
} finally {
  first.disable()
  middle.disable()
  last.disable()
}

const storage = new AsyncLocalStorage()
let resource
await storage.run('captured', async () => {
  resource = new AsyncResource('home-context-control')
  await delay(1)
  assert.equal(storage.getStore(), 'captured')
  await immediate()
  assert.equal(storage.getStore(), 'captured')
  const ticker = interval(1, 'tick')
  try {
    assert.deepEqual(await ticker.next(), { value: 'tick', done: false })
    assert.equal(storage.getStore(), 'captured')
  } finally {
    await ticker.return()
  }
  const emitter = new EventEmitter()
  const event = once(emitter, 'data')
  process.nextTick(() => emitter.emit('data', 'payload'))
  assert.deepEqual(await event, ['payload'])
  assert.equal(storage.getStore(), 'captured')
})
assert.equal(storage.getStore(), undefined)
assert.equal(resource.runInAsyncScope(() => storage.getStore()), 'captured')
assert.equal(storage.getStore(), undefined)
storage.disable()
console.log('native events/async-context/timers regressions passed')
