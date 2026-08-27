// Known missing parentPort lifecycle: https://github.com/home-lang/home/issues/477.
// Node controls run this exact body with only the executable guard removed.
import assert from 'node:assert/strict'
import { basename } from 'node:path'
import { Worker } from 'node:worker_threads'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)

async function bounded(promise, label) {
  let timer
  try {
    return await Promise.race([
      promise,
      new Promise((resolve, reject) => {
        timer = setTimeout(() => reject(new Error(label + ': timed out')), 3000)
      }),
    ])
  } finally {
    clearTimeout(timer)
  }
}

const state = new Int32Array(new SharedArrayBuffer(4))
const worker = new Worker(`
  const { parentPort, workerData } = require('node:worker_threads');
  const state = new Int32Array(workerData);
  parentPort.on('message', () => { throw new Error('closed parentPort delivered a message'); });
  parentPort.on('close', () => Atomics.add(state, 0, 1));
  parentPort.postMessage('closing');
  parentPort.close();
`, { eval: true, workerData: state.buffer })
const messages = []
const errors = []
const exits = []
worker.on('message', message => messages.push(message))
worker.on('error', error => errors.push(error))
const exit = new Promise(resolve => {
  worker.on('exit', code => {
    exits.push(code)
    resolve(code)
  })
})

try {
  assert.equal(await bounded(exit, 'parentPort.close must permit natural worker exit'), 0)
  assert.deepEqual(messages, ['closing'])
  assert.deepEqual(errors, [])
  assert.deepEqual(exits, [0])
  assert.equal(Atomics.load(state, 0), 1, 'parentPort must dispatch close exactly once')
  console.log('parentPort close releases listeners and permits natural exit')
} finally {
  if (exits.length === 0) await bounded(worker.terminate(), 'worker cleanup')
}
