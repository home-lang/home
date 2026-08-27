// Known failing nested-worker lifecycle: https://github.com/home-lang/home/issues/470.
// Parent termination must stop child workers before their queued JavaScript runs.
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

await check('parent termination cancels a nested worker transfer and late parent posts', async ({ channel, gate, worker }) => {
  const state = gate()
  const pair = channel()
  const peer = observeClose(pair.port2)
  const latePair = channel()
  const latePeer = observeClose(latePair.port2)
  const childCode = `
    const { parentPort, workerData } = require('node:worker_threads');
    const state = new Int32Array(workerData);
    parentPort.on('message', ({ port }) => {
      Atomics.add(state, 1, 1);
      port.close();
      parentPort.postMessage({ type: 'unexpected-child-delivery' });
    });
    setTimeout(() => {
      Atomics.store(state, 0, 1);
      parentPort.postMessage({ type: 'blocked' });
      Atomics.wait(state, 0, 1, 1000);
    }, 10);
  `
  const owned = worker(`
    const { Worker, parentPort, workerData } = require('node:worker_threads');
    const state = new Int32Array(workerData.state);
    const child = new Worker(${JSON.stringify(childCode)}, { eval: true, workerData: workerData.state });
    parentPort.on('message', ({ port }) => {
      Atomics.add(state, 3, 1);
      port.close();
      parentPort.postMessage({ type: 'unexpected-parent-delivery' });
    });
    child.on('error', error => parentPort.postMessage({ type: 'child-error', message: error.message }));
    child.on('message', message => {
      if (message.type !== 'blocked') {
        parentPort.postMessage(message);
        return;
      }
      child.postMessage({ port: workerData.port }, [workerData.port]);
      Atomics.store(state, 2, 1);
      parentPort.postMessage({ type: 'nested-queued', executable: process.execPath });
      Atomics.wait(state, 2, 1, 1000);
    });
  `, { state: state.buffer, port: pair.port1 }, [pair.port1])
  assert.equal((await bounded(owned.message('nested-queued'), 'nested handshake')).executable, process.execPath)
  assert.equal(Atomics.load(state, 0), 1, 'nested child must still be blocked')
  assert.equal(Atomics.load(state, 2), 1, 'parent worker must still be blocked')
  await terminate(owned, 'nested parent cancellation', terminating => {
    terminating.postMessage({ port: latePair.port1 }, [latePair.port1])
  })
  await expectClosed([peer, latePeer], 'nested and late transferred endpoints')
  assert.equal(Atomics.load(state, 1), 0, 'nested cancelled handler must never run')
  assert.equal(Atomics.load(state, 3), 0, 'parent cancelled handler must never run')
  assert.deepEqual(owned.messages.map(message => message.type), ['nested-queued'])
})

assert.equal(passed, 1)
console.log('nested worker termination regression passed')
