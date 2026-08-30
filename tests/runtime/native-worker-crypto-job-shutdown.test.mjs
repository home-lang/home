import assert from 'node:assert/strict'
import { scrypt, scryptSync } from 'node:crypto'
import { once } from 'node:events'
import { Worker } from 'node:worker_threads'
import { getEventLoopStats } from 'bun:internal-for-testing'

const normalOptions = { N: 1024, r: 8, p: 1, maxmem: 32 * 1024 * 1024 }
const expected = scryptSync('password', 'salt', 32, normalOptions)
const actual = await new Promise((resolve, reject) => {
  scrypt('password', 'salt', 32, normalOptions, (error, result) => {
    if (error) reject(error)
    else resolve(result)
  })
})
assert.deepEqual(actual, expected)
assert.equal(getEventLoopStats().nativeWorkPoolJobs, 0)

const workerSource = `
  const { scrypt } = require('node:crypto');
  const { parentPort } = require('node:worker_threads');
  const { getEventLoopStats } = require('bun:internal-for-testing');
  const options = { N: 65_536, r: 8, p: 1, maxmem: 128 * 1024 * 1024 };
  scrypt('password', 'salt', 64, options, () => {});
  parentPort.postMessage({ jobs: getEventLoopStats().nativeWorkPoolJobs });
`

const primeWorkerSource = `
  const { generatePrime } = require('node:crypto');
  const { parentPort } = require('node:worker_threads');
  const { getEventLoopStats } = require('bun:internal-for-testing');
  generatePrime(2048, { bigint: true }, () => {});
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

for (let iteration = 0; iteration < 3; iteration += 1) {
  const before = getEventLoopStats().cancelledAnyTasks
  const worker = new Worker(workerSource, { eval: true })
  let terminated = false

  try {
    const [armed] = await withTimeout(once(worker, 'message'), 'scrypt worker arm')
    assert.deepEqual(armed, { jobs: 1 })
    const exitCode = await withTimeout(worker.terminate(), 'scrypt worker termination')
    terminated = true
    assert.equal(typeof exitCode, 'number')
    assert.equal(getEventLoopStats().cancelledAnyTasks, before + 1)
  } finally {
    if (!terminated) await withTimeout(worker.terminate(), 'scrypt worker cleanup')
  }
}

for (let iteration = 0; iteration < 2; iteration += 1) {
  const before = getEventLoopStats().cancelledAnyTasks
  const worker = new Worker(primeWorkerSource, { eval: true })
  let terminated = false

  try {
    const [armed] = await withTimeout(once(worker, 'message'), 'generatePrime worker arm')
    assert.deepEqual(armed, { jobs: 1 })
    const exitCode = await withTimeout(worker.terminate(), 'generatePrime worker termination')
    terminated = true
    assert.equal(typeof exitCode, 'number')
    assert.equal(getEventLoopStats().cancelledAnyTasks, before + 1)
  } finally {
    if (!terminated) await withTimeout(worker.terminate(), 'generatePrime worker cleanup')
  }
}

console.log('native worker crypto job shutdown passed')
