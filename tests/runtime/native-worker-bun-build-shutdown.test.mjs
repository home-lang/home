import assert from 'node:assert/strict'
import { once } from 'node:events'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Worker } from 'node:worker_threads'
import { getEventLoopStats } from 'bun:internal-for-testing'

const probeCount = getEventLoopStats().nativeWorkPoolThreads

const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds))

const withTimeout = async (promise, label) => {
  let timeout
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timeout = setTimeout(() => reject(new Error(`${label} timeout`)), 15_000)
      }),
    ])
  } finally {
    clearTimeout(timeout)
  }
}

const fixtureDir = await mkdtemp(join(tmpdir(), 'home-build-shutdown-'))
const entrypoint = join(fixtureDir, 'entry.ts')
await writeFile(entrypoint, 'export const answer: number = 42\n')

try {
  const normal = await Bun.build({ entrypoints: [entrypoint], target: 'bun' })
  assert.equal(normal.success, true)
  assert.equal(normal.outputs.length, 1)
  assert.match(await normal.outputs[0].text(), /answer/)

  const workerSource = `
    const { parentPort } = require('node:worker_threads');
    const { getEventLoopStats } = require('bun:internal-for-testing');
    const targetStarted = getEventLoopStats().startedNativeWorkPoolProbeTasks + ${probeCount};
    for (let index = 0; index < ${probeCount}; index += 1) getEventLoopStats(false, true);
    const arm = () => {
      if (getEventLoopStats().startedNativeWorkPoolProbeTasks < targetStarted) {
        setTimeout(arm, 1);
        return;
      }
      void Bun.build({ entrypoints: [${JSON.stringify(entrypoint)}], target: 'bun' });
      void Bun.build({ entrypoints: [${JSON.stringify(entrypoint)}], target: 'browser' });
      parentPort.postMessage({ jobs: getEventLoopStats().nativeWorkPoolJobs });
    };
    arm();
  `

  const before = getEventLoopStats()
  const worker = new Worker(workerSource, { eval: true })
  let termination
  let released = false

  try {
    const [armed] = await withTimeout(once(worker, 'message'), 'Bun.build worker arm')
    assert.deepEqual(armed, { jobs: probeCount + 2 })

    let terminated = false
    termination = worker.terminate().then(exitCode => {
      terminated = true
      return exitCode
    })

    await delay(50)
    assert.equal(terminated, false, 'worker teardown passed admitted Bun.build jobs')

    getEventLoopStats(false, false, true)
    released = true
    const exitCode = await withTimeout(termination, 'Bun.build worker termination')
    assert.equal(typeof exitCode, 'number')
    assert.equal(
      getEventLoopStats().completedNativeWorkPoolProbeTasks,
      before.completedNativeWorkPoolProbeTasks + probeCount,
    )
    assert.equal(getEventLoopStats().cancelledAnyTasks, before.cancelledAnyTasks + 2)
  } finally {
    if (!released) getEventLoopStats(false, false, true)
    if (termination) await withTimeout(termination, 'Bun.build worker cleanup')
    else await withTimeout(worker.terminate(), 'Bun.build worker cleanup')
  }
} finally {
  await rm(fixtureDir, { recursive: true, force: true })
}

console.log('native worker Bun.build shutdown ownership passed')
