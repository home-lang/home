// Native lifecycle coverage for https://github.com/home-lang/home/issues/462.
// Reference controls execute this body without the Home guard under Node --expose-gc.
import assert from 'node:assert/strict'
import { basename } from 'node:path'
import { MessageChannel, MessagePort, Worker, receiveMessageOnPort } from 'node:worker_threads'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)

const turn = () => new Promise(resolve => setImmediate(resolve))
const collect = typeof Bun !== 'undefined' ? () => Bun.gc(true) : globalThis.gc
assert.equal(typeof collect, 'function', 'GC coverage requires native Bun.gc or Node --expose-gc')

function watchClose(port) {
  const calls = []
  let resolve
  const done = new Promise(complete => { resolve = complete })
  port.on('close', function (...args) {
    calls.push({ receiver: this, args })
    resolve()
  })
  return { calls, done }
}

function take(port) {
  const result = receiveMessageOnPort(port)
  assert.notEqual(result, undefined, 'queued payload must precede peer close')
  assert.equal(Object.hasOwn(result, 'message'), true)
  return result.message
}

let passed = 0
async function check(name, body) {
  const ports = new Set()
  const workers = []
  let timer
  const resources = {
    channel() {
      const channel = new MessageChannel()
      ports.add(channel.port1)
      ports.add(channel.port2)
      return channel
    },
    port(port) {
      assert.ok(port instanceof MessagePort)
      ports.add(port)
      return port
    },
    worker(code, port) {
      const worker = new Worker(code, { eval: true, workerData: { port }, transferList: [port] })
      const messages = []
      const waiters = new Map()
      const errors = []
      let exited = false
      let resolveExit
      const exit = new Promise(resolve => { resolveExit = resolve })
      worker.on('message', message => {
        messages.push(message)
        waiters.get(message.type)?.(message)
      })
      worker.on('error', error => errors.push(error))
      worker.on('exit', code => {
        exited = true
        resolveExit(code)
      })
      const owned = {
        worker,
        messages,
        errors,
        exit,
        get exited() { return exited },
        message(type) {
          const present = messages.find(message => message.type === type)
          if (present) return Promise.resolve(present)
          return new Promise(resolve => waiters.set(type, resolve))
        },
      }
      workers.push(owned)
      return owned
    },
  }
  try {
    await Promise.race([
      body(resources),
      new Promise((resolve, reject) => {
        timer = setTimeout(() => reject(new Error(name + ': timed out')), 5000)
      }),
    ])
    for (const owned of workers) assert.deepEqual(owned.errors, [], name + ': worker errors')
    passed++
    console.log('pass: ' + name)
  } finally {
    clearTimeout(timer)
    for (const port of ports) port.close()
    for (const owned of workers) {
      if (!owned.exited) await owned.worker.terminate()
    }
  }
}

await check('asynchronous both-end close, callbacks, and exactly-once delivery', async ({ channel }) => {
  const { port1, port2 } = channel()
  const first = watchClose(port1)
  const second = watchClose(port2)
  const callbacks = []
  function callback(...args) { callbacks.push({ receiver: this, args }) }
  port2.postMessage('discard this locally closed inbox')
  assert.equal(port1.close(callback), undefined)
  assert.equal(port1.close(callback), undefined)
  assert.equal(port1.close(function (...args) { callbacks.push({ receiver: this, args }) }), undefined)
  assert.deepEqual(first.calls, [])
  assert.deepEqual(second.calls, [])
  assert.deepEqual(callbacks, [])
  await Promise.all([first.done, second.done])
  await turn()
  assert.equal(first.calls.length, 1)
  assert.equal(second.calls.length, 1)
  assert.equal(receiveMessageOnPort(port1), undefined)
  assert.equal(receiveMessageOnPort(port2), undefined)
  assert.equal(callbacks.length, 2)
  for (const call of callbacks) {
    assert.equal(call.receiver, port1)
    assert.equal(call.args.length, 1)
    assert.ok(call.args[0] instanceof Event)
    assert.equal(call.args[0].type, 'close')
  }
  let lateCallback = false
  port1.close(() => { lateCallback = true })
  port2.close()
  await turn()
  await turn()
  assert.equal(lateCallback, false)
  assert.equal(first.calls.length, 1)
  assert.equal(second.calls.length, 1)
  for (const value of [undefined, null, false, 0, 'not a callback', {}]) {
    const ports = channel()
    const closed = watchClose(ports.port1)
    assert.doesNotThrow(() => ports.port1.close(value))
    await closed.done
  }
})

await check('accepted peer messages stay FIFO before peer close', async ({ channel }) => {
  const { port1, port2 } = channel()
  const seen = []
  const sender = watchClose(port1)
  const peer = watchClose(port2)
  port2.on('message', value => seen.push(value))
  port2.on('close', () => seen.push('closed'))
  for (const value of [0, false, undefined, 'last']) port1.postMessage(value)
  port1.close()
  await Promise.all([sender.done, peer.done])
  assert.deepEqual(seen, [0, false, undefined, 'last', 'closed'])
})

await check('immediate synchronous receive preserves the initial peer-close wake', async ({ channel }) => {
  const { port1, port2 } = channel()
  const sender = watchClose(port1)
  const peer = watchClose(port2)
  port1.postMessage('last')
  port1.close()
  // No yield, message listener, start(), or extra empty receive: the close
  // notification already queued by the sender must observe the drained inbox.
  assert.equal(take(port2), 'last')
  await Promise.all([sender.done, peer.done])
  assert.equal(peer.calls.length, 1)
})

await check('unstarted peer retains unread data until message delivery starts', async ({ channel }) => {
  const { port1, port2 } = channel()
  const sender = watchClose(port1)
  const peer = watchClose(port2)
  const seen = []
  port1.postMessage(1)
  port1.postMessage(2)
  port1.close()
  await sender.done
  await turn()
  assert.equal(peer.calls.length, 0)
  port2.on('message', value => seen.push(value))
  port2.on('close', () => seen.push('closed'))
  await peer.done
  assert.deepEqual(seen, [1, 2, 'closed'])
})

await check('unstarted synchronous receive consumes data before close control', async ({ channel }) => {
  const { port1, port2 } = channel()
  const sender = watchClose(port1)
  const peer = watchClose(port2)
  port1.postMessage(0)
  port1.postMessage(undefined)
  port1.close()
  await sender.done
  // Let the peer's initial close wake observe its still-unread inbox. The
  // sender's close callback alone is not a cross-end task-ordering barrier.
  await turn()
  await turn()
  assert.equal(peer.calls.length, 0)
  assert.equal(take(port2), 0)
  assert.equal(take(port2), undefined)
  await turn()
  assert.equal(peer.calls.length, 0)
  assert.equal(receiveMessageOnPort(port2), undefined)
  await peer.done
  assert.equal(peer.calls.length, 1)
})

await check('transfer closes old wrapper without closing new endpoint', async ({ channel, port }) => {
  const original = channel()
  const carrier = channel()
  const old = watchClose(original.port1)
  const peer = watchClose(original.port2)
  carrier.port1.postMessage(original.port1, [original.port1])
  const movedPort = port(take(carrier.port2))
  const moved = watchClose(movedPort)
  assert.equal(old.calls.length, 0)
  await old.done
  original.port1.close()
  await turn()
  assert.equal(peer.calls.length, 0)
  assert.equal(moved.calls.length, 0)
  original.port2.postMessage('still connected')
  assert.equal(take(movedPort), 'still connected')
  movedPort.close()
  await Promise.all([peer.done, moved.done])
  assert.equal(old.calls.length, 1)
  assert.equal(peer.calls.length, 1)
  assert.equal(moved.calls.length, 1)
})

await check('transfer before peer-close notification preserves buffered messages', async ({ channel, port }) => {
  const original = channel()
  const carrier = channel()
  const old = watchClose(original.port1)
  const peer = watchClose(original.port2)
  original.port2.postMessage('buffered')
  original.port2.close()
  carrier.port1.postMessage(original.port1, [original.port1])
  const movedPort = port(take(carrier.port2))
  const moved = watchClose(movedPort)
  const seen = []
  movedPort.on('message', value => seen.push(value))
  movedPort.on('close', () => seen.push('closed'))
  await Promise.all([old.done, peer.done, moved.done])
  assert.deepEqual(seen, ['buffered', 'closed'])
  for (const result of [old, peer, moved]) assert.equal(result.calls.length, 1)
})

await check('same-context reattachment inside handler preserves pending close', async ({ channel, port }) => {
  const original = channel()
  const carrier = channel()
  const sender = watchClose(original.port1)
  const old = watchClose(original.port2)
  const seen = []
  let movedReady
  const ready = new Promise((resolve, reject) => {
    original.port2.on('message', value => {
      try {
        seen.push('old:' + value)
        assert.equal(value, 1)
        carrier.port1.postMessage(original.port2, [original.port2])
        const movedPort = port(take(carrier.port2))
        movedReady = watchClose(movedPort)
        movedPort.on('message', value => seen.push('new:' + value))
        movedPort.on('close', () => seen.push('closed'))
        resolve()
      } catch (error) {
        reject(error)
      }
    })
  })
  original.port1.postMessage(1)
  original.port1.postMessage(2)
  original.port1.close()
  await ready
  await Promise.all([sender.done, old.done, movedReady.done])
  assert.deepEqual(seen, ['old:1', 'new:2', 'closed'])
  for (const result of [sender, old, movedReady]) assert.equal(result.calls.length, 1)
})

const workerPrelude = `
  const { parentPort, workerData } = require('node:worker_threads');
  const port = workerData.port;
`

await check('cross-worker peer closure reaches the owning worker', async ({ channel, worker }) => {
  const { port1, port2 } = channel()
  const local = watchClose(port1)
  const owned = worker(workerPrelude + `
    port.on('close', () => {
      parentPort.postMessage({ type: 'closed', executable: process.execPath });
      parentPort.close();
    });
    port.ref();
    parentPort.postMessage({ type: 'ready' });
  `, port2)
  await owned.message('ready')
  port1.close()
  const [, message] = await Promise.all([local.done, owned.message('closed')])
  assert.equal(message.executable, process.execPath)
  assert.equal(await owned.exit, 0)
  assert.equal(local.calls.length, 1)
})

await check('worker-initiated close preserves queued messages in parent', async ({ channel, worker }) => {
  const { port1, port2 } = channel()
  const local = watchClose(port1)
  const seen = []
  port1.on('message', value => seen.push(value))
  port1.on('close', () => seen.push('closed'))
  const owned = worker(workerPrelude + `
    port.on('close', () => {
      parentPort.postMessage({ type: 'closed', executable: process.execPath });
      parentPort.close();
    });
    port.postMessage(1);
    port.postMessage(2);
    port.close();
  `, port2)
  const [, message] = await Promise.all([local.done, owned.message('closed')])
  assert.equal(message.executable, process.execPath)
  assert.equal(await owned.exit, 0)
  assert.deepEqual(seen, [1, 2, 'closed'])
})

await check('worker termination notifies surviving peer without shutdown JavaScript', async ({ channel, worker }) => {
  const { port1, port2 } = channel()
  const local = watchClose(port1)
  const owned = worker(workerPrelude + `
    port.on('close', () => parentPort.postMessage({ type: 'unexpected-shutdown-js' }));
    port.ref();
    parentPort.postMessage({ type: 'ready', executable: process.execPath });
  `, port2)
  assert.equal((await owned.message('ready')).executable, process.execPath)
  const terminationCode = await owned.worker.terminate()
  await local.done
  assert.equal(await owned.exit, terminationCode)
  assert.equal(owned.messages.some(message => message.type === 'unexpected-shutdown-js'), false)
  assert.equal(local.calls.length, 1)
})

await check('GC retains pending close listeners until exactly-once dispatch', async () => {
  const count = 8
  const seen = Array(count * 2).fill(0)
  let resolve
  const done = new Promise(complete => { resolve = complete })
  // Do not retain the channel, ports, or listener receivers in a test registry:
  // only native pending-close ownership should keep these callbacks reachable.
  for (let index = 0; index < count; index++) {
    const { port1, port2 } = new MessageChannel()
    for (const [side, port] of [port1, port2].entries()) {
      port.on('close', () => {
        seen[index * 2 + side]++
        if (seen.every(value => value === 1)) resolve()
      })
    }
    port1.close()
  }
  collect()
  collect()
  await done
  collect()
  await turn()
  assert.deepEqual(seen, Array(count * 2).fill(1))
})

await check('closed and unread-orphan channel wrappers are collectable', async () => {
  function samples() {
    const ordinary = []
    const orphans = []
    for (let index = 0; index < 12; index++) {
      let channel = new MessageChannel()
      channel.port1.onmessage = () => {}
      channel.port2.onmessage = () => {}
      ordinary.push(new WeakRef(channel), new WeakRef(channel.port1), new WeakRef(channel.port2))
      channel.port1.close()
      channel.port2.close()
      channel = null
    }
    for (let index = 0; index < 12; index++) {
      let carrier = new MessageChannel()
      let inner = new MessageChannel()
      inner.port2.onmessage = () => {}
      inner.port2.postMessage('buffered')
      orphans.push(new WeakRef(carrier), new WeakRef(carrier.port1), new WeakRef(carrier.port2),
        new WeakRef(inner), new WeakRef(inner.port1), new WeakRef(inner.port2))
      carrier.port1.postMessage(inner.port1, [inner.port1])
      // Never receive the transferred endpoint. Discarding its carrier must
      // release both its unread inbox and the surviving inner peer's refs.
      carrier.port2.close()
      carrier.port1.close()
      carrier = null
      inner = null
    }
    return { ordinary, orphans }
  }

  const retained = new MessageChannel()
  const live = new WeakRef(retained.port2)
  try {
    const refs = samples()
    let ordinaryRemaining
    let orphanRemaining
    for (let attempt = 0; attempt < 12; attempt++) {
      // WeakRef dereference keeps a target alive for the current job. Yield
      // before each collection, and never save dereferenced targets in arrays.
      await turn()
      collect()
      await turn()
      ordinaryRemaining = refs.ordinary.reduce((count, ref) => count + Number(Boolean(ref.deref())), 0)
      orphanRemaining = refs.orphans.reduce((count, ref) => count + Number(Boolean(ref.deref())), 0)
      assert.equal(live.deref(), retained.port2, 'strongly retained positive control must survive GC')
      if (ordinaryRemaining === 0 && orphanRemaining === 0) break
    }
    assert.equal(ordinaryRemaining, 0, 'closed channel/port wrappers must be collectable')
    assert.equal(orphanRemaining, 0, 'unread transferred endpoints must not pin wrappers')
  } finally {
    retained.port1.close()
    retained.port2.close()
  }
  // No process.exit(): the external deadline also detects retained native
  // event-loop references. WeakRef collection alone does not prove that every
  // native allocation is freed; callback survival is a separate check above.
})

assert.equal(passed, 13)
console.log('native worker close-event regressions passed: ' + passed)
