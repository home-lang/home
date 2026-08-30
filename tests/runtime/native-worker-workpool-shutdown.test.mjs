import assert from 'node:assert/strict'
import { once } from 'node:events'
import { Worker } from 'node:worker_threads'
import { getEventLoopStats } from 'bun:internal-for-testing'

const workerSource = `
  const { parentPort } = require('node:worker_threads');
  const { getEventLoopStats } = require('bun:internal-for-testing');
  const stats = getEventLoopStats(false, true);
  parentPort.postMessage({ jobs: stats.nativeWorkPoolJobs });
`

const webCryptoWorkerSource = `
  const { parentPort } = require('node:worker_threads');
  const { getEventLoopStats } = require('bun:internal-for-testing');
  const payload = new Uint8Array(64 * 1024 * 1024);
  void crypto.subtle.digest('SHA-512', payload);
  parentPort.postMessage({ jobs: getEventLoopStats().nativeWorkPoolJobs });
`

const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds))

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

const waitForCount = async (key, expected) => {
  const deadline = Date.now() + 5_000
  while (getEventLoopStats()[key] < expected) {
    if (Date.now() >= deadline) throw new Error(`${key} did not reach ${expected}`)
    await delay(5)
  }
}

for (let iteration = 0; iteration < 4; iteration += 1) {
  const before = getEventLoopStats()
  const expectedStarted = before.startedNativeWorkPoolProbeTasks + 1
  const expectedCompleted = before.completedNativeWorkPoolProbeTasks + 1
  const worker = new Worker(workerSource, { eval: true })
  let termination
  let released = false

  try {
    const [armed] = await withTimeout(once(worker, 'message'), 'worker arm')
    assert.deepEqual(armed, { jobs: 1 })
    await waitForCount('startedNativeWorkPoolProbeTasks', expectedStarted)

    let terminated = false
    termination = worker.terminate().then(exitCode => {
      terminated = true
      return exitCode
    })

    await delay(50)
    assert.equal(terminated, false, 'worker teardown passed a blocked native work-pool job')

    getEventLoopStats(false, false, true)
    released = true
    const exitCode = await withTimeout(termination, 'worker termination')
    assert.equal(typeof exitCode, 'number')
    assert.equal(getEventLoopStats().completedNativeWorkPoolProbeTasks, expectedCompleted)
  } finally {
    if (!released) getEventLoopStats(false, false, true)
    if (termination) {
      await withTimeout(termination, 'worker cleanup')
    } else {
      await withTimeout(worker.terminate(), 'worker cleanup')
    }
  }
}

for (let iteration = 0; iteration < 4; iteration += 1) {
  const worker = new Worker(webCryptoWorkerSource, { eval: true })
  const [armed] = await withTimeout(once(worker, 'message'), 'WebCrypto worker arm')
  assert.ok(armed.jobs >= 1, 'WebCrypto did not register its native work-pool job')
  const exitCode = await withTimeout(worker.terminate(), 'WebCrypto worker termination')
  assert.equal(typeof exitCode, 'number')
}

console.log('native worker work-pool shutdown barrier passed')
