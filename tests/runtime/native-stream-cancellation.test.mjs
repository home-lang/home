import assert from 'node:assert/strict'
import { AsyncLocalStorage } from 'node:async_hooks'
import { basename } from 'node:path'
import { setImmediate as immediate } from 'node:timers/promises'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)

for (const flush of [false, true]) {
  const storage = new AsyncLocalStorage()
  const reason = { flush }
  let calls = 0
  let source
  let pulled = false
  const stream = storage.run('creation', () => new ReadableStream(source = {
    type: 'direct',
    pull(controller) { if (!pulled) { pulled = true; controller.write('hello'); if (flush) controller.flush() } },
    cancel(actualReason) {
      assert.equal(this, source)
      assert.equal(actualReason, reason)
      assert.equal(storage.getStore(), 'creation')
      Bun.gc(true)
      calls++
      return Promise.resolve('ignored result')
    },
  }))
  const reader = stream.getReader()
  const first = reader.read()
  if (flush) assert.equal((await first).value.byteLength, 5)
  const pending = flush ? reader.read() : first
  await storage.run('caller', async () => {
    assert.equal(await reader.cancel(reason), undefined)
    assert.equal(storage.getStore(), 'caller')
  })
  assert.deepEqual(await pending, { value: undefined, done: true })
  assert.deepEqual(await reader.read(), { value: undefined, done: true })
  await reader.cancel('again')
  assert.equal(calls, 1)
  assert.equal(storage.getStore(), undefined)
  reader.releaseLock()
}

for (const callback of ['cancel', 'close']) {
  let calls = 0
  const stream = new ReadableStream({ type: 'direct', pull() { assert.fail('lazy cancellation must not pull') }, [callback](reason) { assert.equal(reason, 'lazy'); calls++ } })
  await stream.cancel('lazy')
  await stream.cancel('again')
  assert.equal(calls, 1)
}

for (const asynchronous of [false, true]) {
  const error = new Error('cancel failure')
  const stream = new ReadableStream({ type: 'direct', pull() {}, cancel() { if (asynchronous) return Promise.reject(error); throw error } })
  const reader = stream.getReader()
  const pending = reader.read()
  await assert.rejects(reader.cancel(), actual => actual === error)
  assert.deepEqual(await pending, { value: undefined, done: true })
  await reader.cancel()
  reader.releaseLock()
}

const latePull = Promise.withResolvers()
const lateStream = new ReadableStream({ type: 'direct', pull() { return latePull.promise } })
const lateReader = lateStream.getReader()
const lateRead = lateReader.read()
await lateReader.cancel()
assert.deepEqual(await lateRead, { value: undefined, done: true })
latePull.reject(new Error('rejected after cancellation'))
await immediate()
lateReader.releaseLock()

const cancelCompletion = Promise.withResolvers()
let concurrentCalls = 0
const concurrentStream = new ReadableStream({ type: 'direct', cancel() { concurrentCalls++; return cancelCompletion.promise } })
const firstCancel = concurrentStream.cancel()
await concurrentStream.cancel()
assert.equal(concurrentCalls, 1)
cancelCompletion.resolve('ignored')
assert.equal(await firstCancel, undefined)

const closedStream = new ReadableStream({ type: 'direct', pull(controller) { controller.close() }, cancel() { assert.fail('closed stream must not invoke cancellation') } })
const closedReader = closedStream.getReader()
assert.deepEqual(await closedReader.read(), { value: undefined, done: true })
await closedReader.cancel()
closedReader.releaseLock()
const storedError = new Error('stored direct error')
const erroredStream = new ReadableStream({ type: 'direct', pull(controller) { controller.error(storedError) }, cancel() { assert.fail('errored stream must not invoke cancellation') } })
const erroredReader = erroredStream.getReader()
await assert.rejects(erroredReader.read(), actual => actual === storedError)
await assert.rejects(erroredReader.cancel(), actual => actual === storedError)
erroredReader.releaseLock()

let reader
const reentrant = new ReadableStream({ type: 'direct', pull() { reader.cancel('inside pull') } })
reader = reentrant.getReader()
assert.deepEqual(await reader.read(), { value: undefined, done: true })
reader.releaseLock()

const released = new ReadableStream({ type: 'direct', pull() {} })
const releasedReader = released.getReader()
const releasedRead = releasedReader.read()
releasedReader.releaseLock()
await assert.rejects(releasedRead, { code: 'ERR_STREAM_RELEASE_LOCK' })
await released.cancel()

for (const mode of ['default', 'byob']) {
  let calls = 0
  const stream = new ReadableStream({ type: mode === 'byob' ? 'bytes' : undefined, cancel(reason) { calls++; assert.equal(reason, 'bytes') } })
  const reader = stream.getReader(mode === 'byob' ? { mode } : undefined)
  const pending = mode === 'byob' ? reader.read(new Uint8Array(16)) : reader.read()
  await reader.cancel('bytes')
  assert.deepEqual(await pending, { value: undefined, done: true })
  await reader.closed
  assert.equal(calls, 1)
  reader.releaseLock()
}
console.log('native direct/default/BYOB cancellation regressions passed')
