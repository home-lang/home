import assert from 'node:assert/strict'
import { AsyncLocalStorage, AsyncResource, createHook } from 'node:async_hooks'
import { EventEmitter, once } from 'node:events'
import { basename } from 'node:path'
import { Worker } from 'node:worker_threads'
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

// Native Worker events belong to creation, even if listeners are registered
// from another context. Restoring the caller also matters after each callback.
const workerStorage = new AsyncLocalStorage()
const workerEvents = []
const worker = workerStorage.run('worker-creation', () => new Worker(`
  const { parentPort } = require('node:worker_threads');
  parentPort.on('message', value => parentPort.postMessage(value));
`, { eval: true }))
let finishWorker
const workerDone = new Promise(resolve => { finishWorker = resolve })
workerStorage.run('worker-registration', () => {
  worker.on('online', function () {
    assert.equal(this, worker)
    workerEvents.push(['online', workerStorage.getStore()])
    worker.postMessage('payload')
  })
  worker.on('message', function (value) {
    assert.equal(this, worker)
    assert.equal(value, 'payload')
    workerEvents.push(['message', workerStorage.getStore()])
    worker.terminate()
  })
  worker.on('exit', function () {
    assert.equal(this, worker)
    workerEvents.push(['exit', workerStorage.getStore()])
    finishWorker()
  })
})
await workerDone
assert.deepEqual(workerEvents, [['online', 'worker-creation'], ['message', 'worker-creation'], ['exit', 'worker-creation']])
assert.equal(workerStorage.getStore(), undefined)

const failingWorker = workerStorage.run('worker-error', () => new Worker("throw new Error('resource-error-control')", { eval: true }))
const workerErrors = []
await new Promise(resolve => {
  failingWorker.on('error', error => {
    assert.match(error.message, /resource-error-control/)
    workerErrors.push(['error', workerStorage.getStore()])
  })
  failingWorker.on('exit', code => {
    assert.equal(code, 1)
    workerErrors.push(['exit', workerStorage.getStore()])
    resolve()
  })
})
assert.deepEqual(workerErrors, [['error', 'worker-error'], ['exit', 'worker-error']])
assert.equal(workerStorage.getStore(), undefined)

// Keep the server alive through the exchange. Resource disposal before waiting
// would test cancellation instead of successful WebSocket event delivery.
const socketStorage = new AsyncLocalStorage()
const server = Bun.serve({
  hostname: '127.0.0.1',
  port: 0,
  fetch(request, server) {
    if (new URL(request.url).pathname === '/reject') return new Response('upgrade rejected', { status: 400 })
    if (server.upgrade(request)) return
    return new Response('upgrade failed', { status: 400 })
  },
  websocket: { message(socket, data) { socket.send(data); socket.close() } },
})
try {
  const socket = socketStorage.run('socket-creation', () => new WebSocket(`ws://${server.hostname}:${server.port}`))
  assert.deepEqual(Reflect.ownKeys(socket), [], 'native context metadata must be private')
  const events = []
  let finish
  const done = new Promise(resolve => { finish = resolve })
  socketStorage.run('socket-registration', () => {
    socket.addEventListener('open', function () {
      assert.equal(this, socket)
      events.push(['open', socketStorage.getStore()])
      Bun.gc(true)
      socket.send('payload')
    })
    socket.onmessage = function (event) {
      assert.equal(this, socket)
      assert.equal(event.data, 'payload')
      events.push(['message', socketStorage.getStore()])
    }
    socket.addEventListener('close', function (event) {
      assert.equal(this, socket)
      assert.equal(event.code, 1000)
      events.push(['close', socketStorage.getStore()])
      finish()
    })
    socket.addEventListener('manual', () => events.push(['manual', socketStorage.getStore()]))
  })
  socketStorage.run('dispatch-caller', () => socket.dispatchEvent(new Event('manual')))
  assert.equal(socketStorage.getStore(), undefined)
  const failedSocket = socketStorage.run('socket-error', () => new WebSocket(`ws://${server.hostname}:${server.port}/reject`))
  const errors = []
  await new Promise(resolve => {
    socketStorage.run('error-registration', () => {
      failedSocket.addEventListener('error', () => errors.push(['error', socketStorage.getStore()]))
      failedSocket.addEventListener('close', event => {
        errors.push(['close', socketStorage.getStore(), event.code])
        resolve()
      })
    })
  })
  assert.deepEqual(errors, [['error', 'socket-error'], ['close', 'socket-error', 1002]])
  assert.equal(socketStorage.getStore(), undefined)
  await done
  assert.deepEqual(events, [['manual', 'dispatch-caller'], ['open', 'socket-creation'], ['message', 'socket-creation'], ['close', 'socket-creation']])
  assert.equal(socketStorage.getStore(), undefined)
  const socketWorker = new Worker(`
    const { AsyncLocalStorage } = require('node:async_hooks');
    const { parentPort, workerData } = require('node:worker_threads');
    const storage = new AsyncLocalStorage();
    storage.run('worker-socket', () => {
      const socket = new WebSocket(workerData);
      const events = [];
      socket.onopen = () => {
        events.push(['open', storage.getStore()]);
        Bun.gc(true);
        socket.send('from-worker');
      };
      socket.onmessage = event => events.push(['message', storage.getStore(), event.data]);
      socket.onclose = () => {
        events.push(['close', storage.getStore()]);
        parentPort.postMessage(events);
      };
    });
  `, { eval: true, workerData: `ws://${server.hostname}:${server.port}` })
  try {
    const [workerSocketEvents] = await once(socketWorker, 'message')
    assert.deepEqual(workerSocketEvents, [['open', 'worker-socket'], ['message', 'worker-socket', 'from-worker'], ['close', 'worker-socket']])
  } finally {
    await socketWorker.terminate()
  }
} finally {
  server.stop(true)
}
console.log('native Worker/WebSocket resource-context regressions passed')
