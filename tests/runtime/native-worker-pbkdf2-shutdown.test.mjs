import assert from 'node:assert/strict'
import { pbkdf2 } from 'node:crypto'
import { once } from 'node:events'
import { Worker } from 'node:worker_threads'
import { getEventLoopStats } from 'bun:internal-for-testing'

const workerSource = `
  const { pbkdf2 } = require('node:crypto');
  const { parentPort } = require('node:worker_threads');
  const { getEventLoopStats } = require('bun:internal-for-testing');
  pbkdf2('password', 'salt', 16_000_000, 32, 'sha256', () => {});
  parentPort.postMessage({ jobs: getEventLoopStats().nativeWorkPoolJobs });
`

const withTimeout = async (promise, label) => {
  let timeout
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timeout = setTimeout(() => reject(new Error(`${label} timeout`)), 5_000)
      }),
    ])
  } finally {
    clearTimeout(timeout)
  }
}

const normalJobsBefore = getEventLoopStats().nativeWorkPoolJobs
const derived = await withTimeout(
  new Promise((resolve, reject) => {
    pbkdf2('password', 'salt', 1, 20, 'sha1', (error, result) => {
      if (error) reject(error)
      else resolve(result)
    })
  }),
  'normal PBKDF2 completion',
)
assert.equal(derived.toString('hex'), '0c60c80f961f0e71f3a9b524af6012062fe037a6')
assert.equal(getEventLoopStats().nativeWorkPoolJobs, normalJobsBefore)

for (let iteration = 0; iteration < 3; iteration += 1) {
  const before = getEventLoopStats().cancelledAnyTasks
  const worker = new Worker(workerSource, { eval: true })
  let terminated = false

  try {
    const [armed] = await withTimeout(once(worker, 'message'), 'PBKDF2 worker arm')
    assert.deepEqual(armed, { jobs: 1 })
    const exitCode = await withTimeout(worker.terminate(), 'PBKDF2 worker termination')
    terminated = true
    assert.equal(typeof exitCode, 'number')
    assert.equal(getEventLoopStats().cancelledAnyTasks, before + 1)
  } finally {
    if (!terminated) await withTimeout(worker.terminate(), 'PBKDF2 worker cleanup')
  }
}

console.log('native worker PBKDF2 shutdown passed')
