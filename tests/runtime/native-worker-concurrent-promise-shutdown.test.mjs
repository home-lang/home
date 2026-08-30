import assert from 'node:assert/strict'
import { once } from 'node:events'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Worker } from 'node:worker_threads'
import { getEventLoopStats } from 'bun:internal-for-testing'

const workerSource = `
  const { parentPort } = require('node:worker_threads');
  const { getEventLoopStats } = require('bun:internal-for-testing');
  const source = 'export default "' + 'x'.repeat(16 * 1024 * 1024) + '"';
  void new Bun.Transpiler().transform(source);
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

const copyDirectory = mkdtempSync(join(tmpdir(), 'home-concurrent-promise-'))
try {
  const source = join(copyDirectory, 'source.txt')
  const destination = join(copyDirectory, 'destination.txt')
  await Bun.write(source, 'normal completion')
  assert.equal(await Bun.write(destination, Bun.file(source)), 17)
  assert.equal(readFileSync(destination, 'utf8'), 'normal completion')
} finally {
  rmSync(copyDirectory, { recursive: true, force: true })
}

for (let iteration = 0; iteration < 4; iteration += 1) {
  const before = getEventLoopStats().cancelledConcurrentPromiseTasks
  const worker = new Worker(workerSource, { eval: true })
  let terminated = false

  try {
    const [armed] = await withTimeout(once(worker, 'message'), 'transpiler worker arm')
    assert.deepEqual(armed, { jobs: 1 })
    const exitCode = await withTimeout(worker.terminate(), 'transpiler worker termination')
    terminated = true
    assert.equal(typeof exitCode, 'number')
    assert.equal(getEventLoopStats().cancelledConcurrentPromiseTasks, before + 1)
  } finally {
    if (!terminated) await withTimeout(worker.terminate(), 'transpiler worker cleanup')
  }
}

console.log('native worker concurrent Promise task shutdown passed')
