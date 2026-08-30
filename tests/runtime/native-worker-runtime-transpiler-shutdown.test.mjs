import assert from 'node:assert/strict'
import { once } from 'node:events'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
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

const root = mkdtempSync(join(tmpdir(), 'home-runtime-transpiler-'))
try {
  const normalPath = join(root, 'normal.ts')
  writeFileSync(normalPath, 'export default (41 as number) + 1\n')
  assert.equal((await import(pathToFileURL(normalPath).href)).default, 42)
  assert.equal(getEventLoopStats().nativeWorkPoolJobs, 0)

  const largePath = join(root, 'large.ts')
  writeFileSync(largePath, `export default "${'x'.repeat(16 * 1024 * 1024)}"\n`)
  const workerPath = join(root, 'worker.mjs')
  const workerSource = `
    import { parentPort } from 'node:worker_threads';
    import { getEventLoopStats } from 'bun:internal-for-testing';
    void import('./large.ts');
    const started = Date.now();
    const poll = setInterval(() => {
      const jobs = getEventLoopStats().nativeWorkPoolJobs;
      if (jobs === 1 || Date.now() - started > 4000) {
        clearInterval(poll);
        parentPort.postMessage({ jobs });
      }
    }, 0);
  `
  writeFileSync(workerPath, workerSource)

  for (let iteration = 0; iteration < 3; iteration += 1) {
    const before = getEventLoopStats().cancelledRuntimeTranspilerJobs
    const worker = new Worker(workerPath)
    const [armed] = await withTimeout(once(worker, 'message'), 'runtime transpiler worker arm')
    assert.deepEqual(armed, { jobs: 1 })
    await withTimeout(worker.terminate(), 'runtime transpiler worker termination')
    assert.equal(getEventLoopStats().cancelledRuntimeTranspilerJobs, before + 1)
  }
} finally {
  rmSync(root, { recursive: true, force: true })
}

console.log('native worker runtime transpiler shutdown passed')
