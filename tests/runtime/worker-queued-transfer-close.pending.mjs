// Known failing ownership regression: https://github.com/home-lang/home/issues/465.
// A queued worker task must release its transferred ports when termination
// cancels delivery. This is an assertion failure, not a skipped/parity pass.
// Run with HOME_NATIVE_VM=1 HOME_CORPUS_FULL_VM=1 home-debug run <this file>.
import assert from 'node:assert/strict'
import { basename } from 'node:path'
import { MessageChannel, Worker } from 'node:worker_threads'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
assert.equal(typeof Bun.gc, 'function', 'this regression requires native Home GC')

const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds))

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

async function probe(terminateBeforeDrain) {
  const label = terminateBeforeDrain ? 'terminate before queued delivery' : 'normal queued delivery'
  const gate = new Int32Array(new SharedArrayBuffer(4))
  const messages = []
  const errors = []
  const { port1, port2 } = new MessageChannel()
  let peerCloseCalls = 0
  let exited = false
  let worker = new Worker(`
    const { parentPort, workerData } = require('node:worker_threads');
    const gate = new Int32Array(workerData);
    parentPort.on('message', ({ port }) => {
      port.close();
      parentPort.postMessage('delivered');
    });
    // Block an ordinary timer callback, not the worker's message drain. A
    // message posted now therefore remains a separate queued native task.
    setTimeout(() => {
      Atomics.store(gate, 0, 1);
      parentPort.postMessage('blocked');
      Atomics.wait(gate, 0, 1, 1000);
      Atomics.store(gate, 0, 2);
    }, 10);
  `, { eval: true, workerData: gate.buffer })
  worker.on('message', message => messages.push(message))
  worker.on('error', error => errors.push(error))
  worker.on('exit', () => { exited = true })
  port2.on('close', () => { peerCloseCalls++ })

  try {
    await bounded(new Promise((resolve, reject) => {
      worker.once('message', message => {
        if (message === 'blocked') resolve()
        else reject(new Error(label + ': unexpected handshake ' + message))
      })
      worker.once('error', reject)
      worker.once('exit', code => reject(new Error(label + ': exited before handshake: ' + code)))
    }), label + ' handshake')
    assert.equal(Atomics.load(gate, 0), 1, label + ': worker must still be blocked')
    assert.equal(peerCloseCalls, 0, label + ': peer must initially be open')

    worker.postMessage({ port: port1 }, [port1])
    if (terminateBeforeDrain) {
      await bounded(worker.terminate(), label + ' shutdown')
      assert.equal(exited, true, label + ': termination must finish')
      assert.equal(messages.includes('delivered'), false, label + ': cancelled handler must not run')
      worker = null
    } else {
      Atomics.store(gate, 0, 2)
      Atomics.notify(gate, 0)
    }

    // Keep the test small: one transferred endpoint and at most 70 GC turns.
    // No RSS threshold or allocation stress is needed to expose ownership.
    for (let attempt = 0; attempt < 70 && !peerCloseCalls; attempt++) {
      Bun.gc(true)
      await sleep(10)
    }
    assert.deepEqual(errors, [], label + ': worker errors')
    if (!terminateBeforeDrain) assert.equal(messages.includes('delivered'), true)
    console.log(JSON.stringify({ terminateBeforeDrain, peerCloseCalls }))
    assert.equal(peerCloseCalls, 1, label + ': cancellation must close the orphaned transferred endpoint (#465)')
  } finally {
    Atomics.store(gate, 0, 2)
    Atomics.notify(gate, 0)
    try {
      if (worker && !exited) await bounded(worker.terminate(), label + ' cleanup')
    } finally {
      port1.close()
      port2.close()
    }
  }
}

await probe(false)
await probe(true)
console.log('worker queued-transfer close: 2 passed')
