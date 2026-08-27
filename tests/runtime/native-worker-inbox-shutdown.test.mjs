// Native incoming-message inbox shutdown: https://github.com/home-lang/home/issues/469.
// This does not prove cancellation or reclamation of every generic C++ task.
// Node controls run this exact body with only the Home guard removed and --expose-gc.
import assert from 'node:assert/strict'
import { basename } from 'node:path'
import { MessageChannel, Worker } from 'node:worker_threads'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)

const collect = typeof Bun !== 'undefined' ? () => Bun.gc(true) : globalThis.gc
assert.equal(typeof collect, 'function', 'native Home GC or Node --expose-gc is required')
const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds))
const turn = () => new Promise(resolve => setImmediate(resolve))

async function bounded(promise, label, milliseconds = 4000) {
  let timer
  try {
    return await Promise.race([
      promise,
      new Promise((resolve, reject) => {
        timer = setTimeout(() => reject(new Error(label + ': timed out')), milliseconds)
      }),
    ])
  } finally {
    clearTimeout(timer)
  }
}

function observeClose(port) {
  const observation = { count: 0 }
  port.on('close', () => { observation.count++ })
  return observation
}

async function expectClosed(observations, label, forceGC = true) {
  // Releasing a terminated worker's JS wrapper can require GC. The invariant
  // is observable orphan closure, not an RSS threshold or a finalizer oracle.
  for (let attempt = 0; attempt < 70 && observations.some(item => item.count === 0); attempt++) {
    if (forceGC) collect()
    await sleep(10)
  }
  for (const observation of observations) {
    assert.equal(observation.count, 1, label + ': cancelled ownership must close each peer exactly once')
  }
  await turn()
  await turn()
  for (const observation of observations) assert.equal(observation.count, 1, label + ': duplicate close')
}

function makeWorker(code, workerData, transferList = []) {
  const owned = {
    worker: new Worker(code, { eval: true, workerData, transferList }),
    messages: [],
    errors: [],
    exits: [],
    waiters: new Map(),
  }
  let resolveExit
  owned.exit = new Promise(resolve => { resolveExit = resolve })
  owned.worker.on('message', message => {
    owned.messages.push(message)
    owned.waiters.get(message.type)?.(message)
  })
  owned.worker.on('error', error => owned.errors.push(error))
  owned.worker.on('exit', code => {
    owned.exits.push(code)
    resolveExit(code)
  })
  owned.message = type => {
    const found = owned.messages.find(message => message.type === type)
    if (found) return Promise.resolve(found)
    return new Promise(resolve => owned.waiters.set(type, resolve))
  }
  return owned
}

async function terminate(owned, label, duringTermination, retainWorker = false) {
  const promise = owned.worker.terminate()
  duringTermination?.(owned.worker)
  const code = await bounded(promise, label + ' termination')
  assert.equal(await bounded(owned.exit, label + ' exit'), code)
  assert.equal(Number.isInteger(code), true)
  assert.deepEqual(owned.exits, [code], label + ': exactly one exit event')
  // Do not keep the JS wrapper alive while testing whether cancelled native
  // tasks still own the worker/inbox. Deliberately preserve the evidence arrays.
  if (!retainWorker) owned.worker = null
}

let passed = 0
async function check(name, body) {
  const ports = new Set()
  const workers = []
  const gates = []
  const resources = {
    channel() {
      const channel = new MessageChannel()
      ports.add(channel.port1)
      ports.add(channel.port2)
      return channel
    },
    gate() {
      const gate = new Int32Array(new SharedArrayBuffer(32))
      gates.push(gate)
      return gate
    },
    worker(code, workerData, transferList) {
      const owned = makeWorker(code, workerData, transferList)
      workers.push(owned)
      return owned
    },
  }
  try {
    await bounded(body(resources), name, 7000)
    for (const owned of workers) {
      assert.deepEqual(owned.errors, [], name + ': worker errors')
      assert.equal(owned.exits.length, 1, name + ': exactly one completed worker exit')
    }
    passed++
    console.log('pass: ' + name)
  } finally {
    for (const gate of gates) {
      for (const index of [0, 2]) {
        Atomics.store(gate, index, 2)
        Atomics.notify(gate, index)
      }
    }
    for (const owned of workers) {
      if (owned.worker && owned.exits.length === 0) await terminate(owned, name + ' cleanup')
      owned.worker = null
    }
    for (const port of ports) port.close()
  }
}

const queuedWorker = `
  const { parentPort, workerData } = require('node:worker_threads');
  const gate = new Int32Array(workerData);
  parentPort.on('message', ({ port, id }) => {
    Atomics.add(gate, 1, 1);
    port.close();
    parentPort.postMessage({ type: 'delivered', id });
  });
  // Block a timer callback, not a message-drain callback. Messages sent after
  // this handshake must remain in a separately queued native worker task.
  setTimeout(() => {
    Atomics.store(gate, 0, 1);
    parentPort.postMessage({ type: 'blocked', executable: process.execPath });
    Atomics.wait(gate, 0, 1, 1000);
  }, 10);
`

await check('normal queued transfer delivers once and closes its peer', async ({ channel, gate, worker }) => {
  const state = gate()
  const pair = channel()
  const peer = observeClose(pair.port2)
  const owned = worker(queuedWorker, state.buffer)
  assert.equal((await bounded(owned.message('blocked'), 'normal handshake')).executable, process.execPath)
  assert.equal(Atomics.load(state, 0), 1)
  owned.worker.postMessage({ port: pair.port1, id: 'normal' }, [pair.port1])
  Atomics.store(state, 0, 2)
  Atomics.notify(state, 0)
  assert.equal((await bounded(owned.message('delivered'), 'normal delivery')).id, 'normal')
  await expectClosed([peer], 'normal delivery')
  assert.equal(Atomics.load(state, 1), 1)
  assert.equal(owned.messages.filter(message => message.type === 'delivered').length, 1)
  await terminate(owned, 'normal control cleanup')
})

await check('a retained terminated Worker releases its queued transfers without GC', async ({ channel, gate, worker }) => {
  const state = gate()
  const pair = channel()
  const peer = observeClose(pair.port2)
  const latePair = channel()
  const latePeer = observeClose(latePair.port2)
  const owned = worker(queuedWorker, state.buffer)
  await bounded(owned.message('blocked'), 'retained worker handshake')
  assert.equal(Atomics.load(state, 0), 1)
  owned.worker.postMessage({ port: pair.port1, id: 'queued' }, [pair.port1])
  await terminate(owned, 'retained worker cancellation', terminating => {
    terminating.postMessage({ port: latePair.port1, id: 'late' }, [latePair.port1])
  }, true)
  assert.ok(owned.worker instanceof Worker, 'retain the terminated JS Worker during closure checks')
  // No GC and no wrapper release: stopped native inbox ownership must be
  // discarded independently of whether the caller retains its Worker object.
  await expectClosed([peer, latePeer], 'retained worker inbox', false)
  assert.equal(Atomics.load(state, 1), 0)
  assert.deepEqual(owned.messages.map(message => message.type), ['blocked'])
})

for (let cycle = 0; cycle < 3; cycle++) {
  await check('cancel concurrent queued transfers without running their handler: cycle ' + cycle, async ({ channel, gate, worker }) => {
    const state = gate()
    const pair = channel()
    const peer = observeClose(pair.port2)
    const latePair = channel()
    const latePeer = observeClose(latePair.port2)
    const owned = worker(queuedWorker, state.buffer)
    assert.equal((await bounded(owned.message('blocked'), 'cancel handshake')).executable, process.execPath)
    assert.equal(Atomics.load(state, 0), 1)
    owned.worker.postMessage({ port: pair.port1, id: 'queued' }, [pair.port1])
    assert.equal(Atomics.load(state, 0), 1, 'worker must still be inside the blocked timer')
    await terminate(owned, 'queued cancellation', terminating => {
      // This is after the terminate request but before its exit callback,
      // not the separate completed-worker postMessage API contract.
      terminating.postMessage({ port: latePair.port1, id: 'late' }, [latePair.port1])
    })
    await expectClosed([peer, latePeer], 'cancelled and late transfers')
    assert.equal(Atomics.load(state, 1), 0, 'cancelled message handlers must not execute during shutdown')
    assert.deepEqual(owned.messages.map(message => message.type), ['blocked'])
  })
}

for (const cancel of [false, true]) {
  await check('worker-local transfer queues a regular close task: ' + (cancel ? 'cancelled' : 'normal'), async ({ channel, gate, worker }) => {
    const state = gate()
    const pair = channel()
    const peer = observeClose(pair.port2)
    const owned = worker(`
      const { MessageChannel, parentPort, workerData } = require('node:worker_threads');
      const state = new Int32Array(workerData.state);
      const port = workerData.port;
      const carrier = new MessageChannel();
      port.on('close', () => {
        Atomics.add(state, 1, 1);
        parentPort.postMessage({ type: 'local-close' });
      });
      carrier.port2.on('message', moved => {
        Atomics.add(state, 3, 1);
        moved.close();
        carrier.port1.close();
        carrier.port2.close();
        parentPort.postMessage({ type: 'local-delivered' });
      });
      setTimeout(() => {
        // Home MessagePort::disentangle posts the old wrapper close through
        // ScriptExecutionContext::postTask, the non-concurrent C++ task queue.
        carrier.port1.postMessage(port, [port]);
        Atomics.store(state, 0, 1);
        parentPort.postMessage({ type: 'blocked', executable: process.execPath });
        Atomics.wait(state, 0, 1, 1000);
      }, 10);
    `, { state: state.buffer, port: pair.port1 }, [pair.port1])
    assert.equal((await bounded(owned.message('blocked'), 'local transfer handshake')).executable, process.execPath)
    assert.equal(Atomics.load(state, 0), 1)
    assert.equal(Atomics.load(state, 1), 0)
    assert.equal(Atomics.load(state, 3), 0)
    if (cancel) {
      await terminate(owned, 'regular close-task cancellation')
    } else {
      Atomics.store(state, 0, 2)
      Atomics.notify(state, 0)
      await bounded(Promise.all([owned.message('local-close'), owned.message('local-delivered')]), 'local delivery control')
      await terminate(owned, 'local control cleanup')
    }
    await expectClosed([peer], 'worker-local transfer')
    assert.equal(Atomics.load(state, 1), cancel ? 0 : 1, 'regular close callback must not run when cancelled')
    assert.equal(Atomics.load(state, 3), cancel ? 0 : 1, 'queued local message must not run when cancelled')
    // This queues a regular close task and checks the shutdown JS boundary; peer
    // closure alone is not proof that every native close-task allocation freed.
  })
}

assert.equal(passed, 7)
console.log('native worker inbox-shutdown regressions passed: ' + passed)
