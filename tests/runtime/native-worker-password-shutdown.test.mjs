import assert from 'node:assert/strict'
import { once } from 'node:events'
import { Worker } from 'node:worker_threads'
import { getEventLoopStats } from 'bun:internal-for-testing'

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

const hash = await withTimeout(
  Bun.password.hash('normal-password', { algorithm: 'bcrypt', cost: 4 }),
  'normal password hash',
)
assert.equal(await withTimeout(Bun.password.verify('normal-password', hash), 'normal password verify'), true)
assert.equal(getEventLoopStats().nativeWorkPoolJobs, 0)

const workerSource = `
  const { parentPort } = require('node:worker_threads');
  const { getEventLoopStats } = require('bun:internal-for-testing');
  void Bun.password.hash('shutdown-password', { algorithm: 'bcrypt', cost: 11 });
  parentPort.postMessage({ jobs: getEventLoopStats().nativeWorkPoolJobs });
`

for (let iteration = 0; iteration < 3; iteration += 1) {
  const before = getEventLoopStats().cancelledAnyTasks
  const worker = new Worker(workerSource, { eval: true })
  let terminated = false

  try {
    const [armed] = await withTimeout(once(worker, 'message'), 'password worker arm')
    assert.deepEqual(armed, { jobs: 1 })
    const exitCode = await withTimeout(worker.terminate(), 'password worker termination')
    terminated = true
    assert.equal(typeof exitCode, 'number')
    assert.equal(getEventLoopStats().cancelledAnyTasks, before + 1)
  } finally {
    if (!terminated) await withTimeout(worker.terminate(), 'password worker cleanup')
  }
}


const verifyWorkerSource = `
  const { parentPort } = require('node:worker_threads');
  const { getEventLoopStats } = require('bun:internal-for-testing');
  const password = 'hello'.repeat(100);
  const hash = '$2b$10$PsJ3/W82mzNJoP0rSblfvet2ab9jZg2aH7tIxr1B8uFLJwuWk/jTi';
  void Bun.password.verify(password, hash);
  parentPort.postMessage({ jobs: getEventLoopStats().nativeWorkPoolJobs });
`

for (let iteration = 0; iteration < 2; iteration += 1) {
  const before = getEventLoopStats().cancelledAnyTasks
  const worker = new Worker(verifyWorkerSource, { eval: true })
  let terminated = false

  try {
    const [armed] = await withTimeout(once(worker, 'message'), 'password verify worker arm')
    assert.deepEqual(armed, { jobs: 1 })
    const exitCode = await withTimeout(worker.terminate(), 'password verify worker termination')
    terminated = true
    assert.equal(typeof exitCode, 'number')
    assert.equal(getEventLoopStats().cancelledAnyTasks, before + 1)
  } finally {
    if (!terminated) await withTimeout(worker.terminate(), 'password verify worker cleanup')
  }
}

console.log('native worker password shutdown passed')
