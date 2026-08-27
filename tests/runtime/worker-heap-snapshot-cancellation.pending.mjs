// Known failure: https://github.com/home-lang/home/issues/471.
// A queued snapshot must settle when its worker terminates; incoming message
// inbox cleanup does not cancel this separately owned generic native task.
// Node control runs this body with only the executable guard removed, but its
// snapshot/termination race can itself crash; that is not a passing control.
import assert from 'node:assert/strict'
import { basename } from 'node:path'
import { Worker } from 'node:worker_threads'

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
  assert.equal(message, 'blocked')
  assert.equal(Atomics.load(gate, 0), 1)
  // Snapshot work can interrupt a blocked worker and finish before termination.
  // Either a snapshot stream or ERR_WORKER_NOT_RUNNING is valid; a promise
  // abandoned by task cancellation is not. This checks bounded promise
  // settlement and the readable-stream interface, NOT snapshot payload validity.
  // Node 24.18 can crash during this race even when the stream is immediately
  // destroyed without consumption. Do not read its payload here. Full normal
  // snapshot validation is separate work; reproducing a crash is not required.
  const snapshot = worker.getHeapSnapshot().then(
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
  )
  assert.equal(Atomics.load(gate, 0), 1)
  const code = await bounded(worker.terminate(), 'worker termination')
  assert.deepEqual(exits, [code], 'termination must emit exactly one matching exit')
  const outcome = await bounded(snapshot, 'cancelled snapshot settlement')
  if (outcome.streamError) throw outcome.streamError
  if (outcome.error) {
    assert.equal(outcome.error.code, 'ERR_WORKER_NOT_RUNNING')
  } else {
    assert.equal(outcome.resolved, true)
  }
  assert.deepEqual(errors, [])
  console.log('worker snapshot cancellation settled correctly')
} finally {
  Atomics.store(gate, 0, 2)
  Atomics.notify(gate, 0)
  // Calling terminate again after exit 0 can itself hang on some runtimes.
  // Cleanup must preserve the snapshot failure, not replace it with an
  // unbounded second termination wait.
  if (exits.length === 0) await bounded(worker.terminate(), 'worker cleanup')
}
