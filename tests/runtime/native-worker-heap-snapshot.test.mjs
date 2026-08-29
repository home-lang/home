// Native snapshot ownership regression: https://github.com/home-lang/home/issues/471.
// A queued snapshot must settle when its worker terminates, and no parent-VM
// Strong handle may survive its owning VM or cross into a worker callback.
// Node 24.18 can crash during snapshot/termination races; do not repeat those
// as a required control. Verify normal snapshot payloads separately in Node.
import assert from 'node:assert/strict'
import { basename } from 'node:path'
import { Worker } from 'node:worker_threads'
import { spawn } from 'node:child_process'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)

async function bounded(promise, label, milliseconds = 3000) {
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

const gate = new Int32Array(new SharedArrayBuffer(4))
const worker = new Worker(`
  const { parentPort, workerData } = require('node:worker_threads');
  const gate = new Int32Array(workerData);
  setTimeout(() => {
    Atomics.store(gate, 0, 1);
    parentPort.postMessage('blocked');
    Atomics.wait(gate, 0, 1, 1000);
    Atomics.store(gate, 0, 2);
  }, 10);
`, { eval: true, workerData: gate.buffer })
const online = new Promise(resolve => worker.once('online', resolve))
const errors = []
const exits = []
worker.on('error', error => errors.push(error))
worker.on('exit', code => exits.push(code))
try {
  const message = await bounded(new Promise((resolve, reject) => {
    worker.once('message', resolve)
    worker.once('error', reject)
    worker.once('exit', code => reject(new Error('worker exited before handshake: ' + code)))
  }), 'worker handshake')
  await bounded(online, 'snapshot worker online')
  assert.equal(message, 'blocked')
  assert.equal(Atomics.load(gate, 0), 1)
  // Snapshot work can interrupt a blocked worker and finish before termination.
  // Either a snapshot stream or ERR_WORKER_NOT_RUNNING is valid; a promise
  // abandoned by task cancellation is not. This checks bounded promise
  // settlement and the readable-stream interface, NOT snapshot payload validity.
  // Node 24.18 can crash during this race even when the stream is immediately
  // destroyed without consumption. Do not read its payload here. Full normal
  // snapshot validation is separate work; reproducing a crash is not required.
  const snapshots = Array.from({ length: 6 }, () => worker.getHeapSnapshot().then(
    stream => {
      try {
        assert.equal(typeof stream?.on, 'function')
        assert.equal(typeof stream?.pipe, 'function')
        assert.equal(typeof stream?.destroy, 'function')
        assert.equal(typeof stream?.[Symbol.asyncIterator], 'function')
        return { resolved: true }
      } catch (streamError) {
        return { streamError }
      } finally {
        if (typeof stream?.destroy === 'function') stream.destroy()
      }
    },
    error => ({ error }),
  ))
  assert.equal(Atomics.load(gate, 0), 1)
  const code = await bounded(worker.terminate(), 'worker termination')
  assert.deepEqual(exits, [code], 'termination must emit exactly one matching exit')
  const outcomes = await bounded(Promise.all(snapshots), 'cancelled snapshot settlement')
  for (const outcome of outcomes) {
    if (outcome.streamError) throw outcome.streamError
    if (outcome.error) {
      assert.equal(outcome.error.code, 'ERR_WORKER_NOT_RUNNING')
    } else {
      assert.equal(outcome.resolved, true)
    }
  }
  await assert.rejects(worker.getHeapSnapshot(), { code: 'ERR_WORKER_NOT_RUNNING' })
  assert.deepEqual(errors, [])
  console.log('pass: six cancelled requests settle and stopped worker rejects')
} finally {
  Atomics.store(gate, 0, 2)
  Atomics.notify(gate, 0)
  // Calling terminate again after exit 0 can itself hang on some runtimes.
  // Cleanup must preserve the snapshot failure, not replace it with an
  // unbounded second termination wait.
  if (exits.length === 0) await bounded(worker.terminate(), 'worker cleanup')
}

// Self-exit uses the same owner-thread cancellation path without a parent
// terminate() request. Queue work before allowing the worker to exit itself.
const naturalGate = new Int32Array(new SharedArrayBuffer(4))
const natural = new Worker(`
  const { parentPort, workerData } = require('node:worker_threads');
  const gate = new Int32Array(workerData);
  setTimeout(() => {
    parentPort.postMessage('ready');
    Atomics.wait(gate, 0, 0, 2000);
    process.exit(0);
  }, 10);
`, { eval: true, workerData: naturalGate.buffer })
const naturalOnline = new Promise(resolve => natural.once('online', resolve))
const naturalExits = []
const naturalErrors = []
const naturalExit = new Promise(resolve => natural.on('exit', code => {
  naturalExits.push(code)
  resolve(code)
}))
natural.on('error', error => naturalErrors.push(error))
try {
  await bounded(new Promise((resolve, reject) => {
    natural.once('message', resolve)
    natural.once('error', reject)
  }), 'self-exit snapshot handshake')
  await bounded(naturalOnline, 'self-exit snapshot worker online')
  const requests = Array.from({ length: 4 }, () => natural.getHeapSnapshot().then(
    stream => { stream.destroy(); return { resolved: true } },
    error => ({ error }),
  ))
  Atomics.store(naturalGate, 0, 1)
  Atomics.notify(naturalGate, 0)
  assert.equal(await bounded(naturalExit, 'snapshot worker self-exit'), 0)
  for (const outcome of await bounded(Promise.all(requests), 'self-exit snapshot settlement')) {
    if (outcome.error) assert.equal(outcome.error.code, 'ERR_WORKER_NOT_RUNNING')
    else assert.equal(outcome.resolved, true)
  }
  assert.deepEqual(naturalExits, [0])
  assert.deepEqual(naturalErrors, [])
  console.log('pass: self-exit settles four outstanding snapshots')
} finally {
  Atomics.store(naturalGate, 0, 1)
  Atomics.notify(naturalGate, 0)
  if (naturalExits.length === 0) await bounded(natural.terminate(), 'snapshot self-exit cleanup')
}

const collect = typeof Bun !== 'undefined' ? () => Bun.gc(true) : globalThis.gc
assert.equal(typeof collect, 'function', 'native Home GC or Node --expose-gc is required')

// A successful round trip must still contain an actual snapshot, not an empty
// stand-in used merely to settle the request. Exercise concurrent requests and
// full GC while their parent-owned promises are rooted.
const active = new Worker(`
  const { parentPort } = require('node:worker_threads');
  globalThis.snapshotSentinel = { label: 'home-snapshot-live-payload', values: [1, 2, 3] };
  parentPort.on('message', () => {});
  parentPort.postMessage('ready');
`, { eval: true })
const activeOnline = new Promise(resolve => active.once('online', resolve))
let activeExited = false
const activeErrors = []
active.on('exit', () => { activeExited = true })
active.on('error', error => activeErrors.push(error))
try {
  await bounded(new Promise((resolve, reject) => {
    active.once('message', resolve)
    active.once('error', reject)
  }), 'active snapshot worker ready')
  await bounded(activeOnline, 'active snapshot worker online')
  const gc = setInterval(collect, 5)
  try {
    for (let iteration = 0; iteration < 3; iteration++) {
      const pending = Array.from({ length: 3 }, () => active.getHeapSnapshot())
      const streams = await bounded(Promise.all(pending), 'concurrent snapshot completion', 10000)
      for (const stream of streams) {
        let text = ''
        for await (const chunk of stream) text += chunk
        const payload = JSON.parse(text)
        assert.equal(typeof payload.snapshot.meta, 'object')
        assert.ok(payload.snapshot.node_count > 0)
        assert.ok(payload.snapshot.edge_count > 0)
        assert.ok(payload.nodes.length > 0)
        assert.ok(payload.edges.length > 0)
        assert.ok(payload.strings.includes('home-snapshot-live-payload'))
      }
    }
  } finally {
    clearInterval(gc)
  }
  assert.deepEqual(activeErrors, [])
  console.log('pass: nine concurrent snapshots preserve payload under parent GC')
} finally {
  if (!activeExited) await bounded(active.terminate(), 'active snapshot cleanup')
}

// The parent can disappear with either outbound requests or return
// notifications queued. It must release its own Strong handles before VM
// teardown; no request callback should run after it has entered shutdown.
for (const blockedChild of [true, false]) {
  const state = new Int32Array(new SharedArrayBuffer(16))
  const parent = new Worker(`
    const { Worker, parentPort, workerData } = require('node:worker_threads');
    const state = new Int32Array(workerData.state);
    const child = new Worker(\`
      const { parentPort, workerData } = require('node:worker_threads');
      const state = new Int32Array(workerData.state);
      parentPort.on('message', () => {});
      setTimeout(() => {
        parentPort.postMessage('ready');
        if (workerData.blockedChild) Atomics.wait(state, 0, 0, 2000);
      }, 10);
    \`, { eval: true, workerData });
    const childOnline = new Promise(resolve => child.once('online', resolve));
    child.on('error', error => { throw error; });
    child.once('message', async () => {
      await childOnline;
      for (let i = 0; i < 4; i++) child.getHeapSnapshot().then(
        stream => { Atomics.add(state, 1, 1); stream.destroy(); },
        () => Atomics.add(state, 1, 1),
      );
      parentPort.postMessage('pending');
      Atomics.wait(state, 2, 0, 2000);
    });
  `, { eval: true, workerData: { state: state.buffer, blockedChild } })
  const parentErrors = []
  let parentExited = false
  parent.on('error', error => parentErrors.push(error))
  parent.on('exit', () => { parentExited = true })
  try {
    assert.equal(await bounded(new Promise((resolve, reject) => {
      parent.once('message', resolve)
      parent.once('error', reject)
    }), 'snapshot parent handshake'), 'pending')
    // In the running-child case, allow real snapshot generation while the
    // parent is synchronously blocked. This exercises queued return delivery;
    // it is not a claim to deterministically control native scheduling.
    if (!blockedChild) await new Promise(resolve => setTimeout(resolve, 150))
    assert.equal(Atomics.load(state, 1), 0)
    await bounded(parent.terminate(), 'snapshot parent termination', 5000)
    assert.deepEqual(parentErrors, [])
    assert.equal(Atomics.load(state, 1), 0, 'shutdown ran a snapshot reaction')
    collect()
    console.log('pass: parent teardown with ' + (blockedChild ? 'blocked' : 'running') + ' snapshot child')
  } finally {
    Atomics.store(state, 0, 1)
    Atomics.notify(state, 0)
    Atomics.store(state, 2, 1)
    Atomics.notify(state, 2)
    if (!parentExited) await bounded(parent.terminate(), 'snapshot parent cleanup', 5000)
  }
}

// Main-thread destruction is an independent owner path from worker teardown.
// Keep the child alive and blocked while main exits with pending requests.
const processCode = `
  const { Worker } = require('node:worker_threads');
  const state = new Int32Array(new SharedArrayBuffer(4));
  const worker = new Worker(\`
    const { workerData, parentPort } = require('node:worker_threads');
    const state = new Int32Array(workerData);
    setTimeout(() => {
      parentPort.postMessage('blocked');
      Atomics.wait(state, 0, 0, 1000);
    }, 10);
  \`, { eval: true, workerData: state.buffer });
  const online = new Promise(resolve => worker.once('online', resolve));
  worker.on('error', error => { throw error; });
  worker.once('message', async () => {
    await online;
    for (let i = 0; i < 6; i++) worker.getHeapSnapshot().catch(() => {});
    console.log('main snapshot exit');
    process.exit(0);
  });
`
const childProcess = spawn(process.execPath, ['-e', processCode], {
  env: { ...process.env, HOME_NATIVE_VM: '1', BUN_DESTRUCT_VM_ON_EXIT: '1' },
  stdio: ['ignore', 'pipe', 'pipe'],
})
let output = ''
let stderr = ''
childProcess.stdout.on('data', chunk => { output += chunk })
childProcess.stderr.on('data', chunk => { stderr += chunk })
try {
  const result = await bounded(new Promise((resolve, reject) => {
    childProcess.once('error', reject)
    childProcess.once('close', (code, signal) => resolve({ code, signal }))
  }), 'main snapshot teardown', 10000)
  assert.deepEqual(result, { code: 0, signal: null }, stderr)
  assert.equal(output, 'main snapshot exit\n')
  assert.equal(stderr, '')
  console.log('pass: main VM teardown releases pending snapshot ownership')
} finally {
  if (childProcess.exitCode === null && childProcess.signalCode === null) childProcess.kill('SIGKILL')
}

console.log('6 native heap-snapshot ownership scenarios passed')
