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

const original = 'Home native Zstd completion'
const compressed = await withTimeout(Bun.zstdCompress(original), 'normal Zstd compression')
const decompressed = await withTimeout(Bun.zstdDecompress(compressed), 'normal Zstd decompression')
assert.equal(new TextDecoder().decode(decompressed), original)
assert.equal(getEventLoopStats().nativeWorkPoolJobs, 0)

const workerSource = `
  const { randomBytes } = require('node:crypto');
  const { parentPort } = require('node:worker_threads');
  const { getEventLoopStats } = require('bun:internal-for-testing');
  const input = randomBytes(16 * 1024 * 1024);
  void Bun.zstdCompress(input, { level: 22 });
  parentPort.postMessage({ jobs: getEventLoopStats().nativeWorkPoolJobs });
`

for (let iteration = 0; iteration < 3; iteration += 1) {
  const before = getEventLoopStats().cancelledAnyTasks
  const worker = new Worker(workerSource, { eval: true })
  let terminated = false

  try {
    const [armed] = await withTimeout(once(worker, 'message'), 'Zstd worker arm')
    assert.deepEqual(armed, { jobs: 1 })
    const exitCode = await withTimeout(worker.terminate(), 'Zstd worker termination')
    terminated = true
    assert.equal(typeof exitCode, 'number')
    assert.equal(getEventLoopStats().cancelledAnyTasks, before + 1)
  } finally {
    if (!terminated) await withTimeout(worker.terminate(), 'Zstd worker cleanup')
  }
}

console.log('native worker Zstd shutdown passed')
