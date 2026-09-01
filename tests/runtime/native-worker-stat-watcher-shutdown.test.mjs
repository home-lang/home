import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { once } from 'node:events'
import { mkdtempSync, rmSync, unwatchFile, watchFile, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Worker } from 'node:worker_threads'
import { getEventLoopStats } from 'bun:internal-for-testing'

const probeCount = getEventLoopStats().nativeWorkPoolThreads

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

const root = mkdtempSync(join(tmpdir(), 'home-stat-watcher-shutdown-'))
const path = join(root, 'watched.txt')
writeFileSync(path, 'before')

try {
  const { promise, resolve } = Promise.withResolvers()
  const listener = (current, previous) => {
    if (current.size !== previous.size) resolve()
  }
  watchFile(path, { interval: 5 }, listener)
  try {
    await new Promise(resolveDelay => setTimeout(resolveDelay, 50))
    writeFileSync(path, 'after-change')
    await withTimeout(promise, 'normal stat watcher change')
  } finally {
    unwatchFile(path, listener)
  }

  const destructingChild = spawnSync(
    process.execPath,
    ['-e', `require('node:fs').watchFile(${JSON.stringify(path)}, { interval: 5_000 }, () => {}); process.exit(0)`],
    {
      encoding: 'utf8',
      env: { ...process.env, BUN_DESTRUCT_VM_ON_EXIT: '1' },
      timeout: 15_000,
    },
  )
  assert.equal(destructingChild.error, undefined)
  assert.equal(destructingChild.signal, null, destructingChild.stderr)
  assert.equal(destructingChild.status, 0, destructingChild.stderr)

  const workerSource = `
    const { watchFile } = require('node:fs');
    const { parentPort, workerData } = require('node:worker_threads');
    const { getEventLoopStats } = require('bun:internal-for-testing');
    const targetStarted = getEventLoopStats().startedNativeWorkPoolProbeTasks + ${probeCount};
    for (let index = 0; index < ${probeCount}; index += 1) getEventLoopStats(false, true);
    const arm = () => {
      if (getEventLoopStats().startedNativeWorkPoolProbeTasks < targetStarted) {
        setTimeout(arm, 1);
        return;
      }
      globalThis.watcher = watchFile(workerData.path, { interval: 5_000 }, () => {});
      parentPort.postMessage({ jobs: getEventLoopStats().nativeWorkPoolJobs });
    };
    arm();
  `

  for (let iteration = 0; iteration < 3; iteration += 1) {
    const before = getEventLoopStats()
    const worker = new Worker(workerSource, { eval: true, workerData: { path } })
    let termination
    let released = false

    try {
      const [armed] = await withTimeout(once(worker, 'message'), 'stat watcher worker arm')
      assert.deepEqual(armed, { jobs: probeCount + 1 })

      let terminated = false
      termination = worker.terminate().then(exitCode => {
        terminated = true
        return exitCode
      })

      await new Promise(resolveDelay => setTimeout(resolveDelay, 50))
      assert.equal(terminated, false, 'worker teardown passed a blocked initial stat')

      getEventLoopStats(false, false, true)
      released = true
      const exitCode = await withTimeout(termination, 'stat watcher worker termination')
      assert.equal(typeof exitCode, 'number')
      assert.equal(
        getEventLoopStats().completedNativeWorkPoolProbeTasks,
        before.completedNativeWorkPoolProbeTasks + probeCount,
      )
      assert.equal(getEventLoopStats().cancelledStatWatcherTasks, before.cancelledStatWatcherTasks + 1)
    } finally {
      if (!released) getEventLoopStats(false, false, true)
      if (termination) await withTimeout(termination, 'stat watcher worker cleanup')
      else await withTimeout(worker.terminate(), 'stat watcher worker cleanup')
    }
  }
} finally {
  rmSync(root, { force: true, recursive: true })
}

console.log('native worker stat watcher shutdown passed')
