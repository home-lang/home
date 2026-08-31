import assert from 'node:assert/strict'
import { once } from 'node:events'
import { closeSync, exists, fstat, mkdtempSync, openSync, rmSync } from 'node:fs'
import { access, lstat, stat, statfs, writeFile } from 'node:fs/promises'
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

const root = mkdtempSync(join(tmpdir(), 'home-fs-task-shutdown-'))
const normalOutput = join(root, 'normal.txt')
const fstatAsync = fd =>
  new Promise((resolve, reject) => {
    fstat(fd, (error, stats) => {
      if (error) reject(error)
      else resolve(stats)
    })
  })

await withTimeout(writeFile(normalOutput, 'normal'), 'normal fs write')
await withTimeout(access(normalOutput), 'normal fs access')
assert.equal(await withTimeout(new Promise(resolve => exists(normalOutput, resolve)), 'normal fs exists'), true)
assert.equal((await withTimeout(stat(normalOutput), 'normal fs stat')).isFile(), true)
assert.equal((await withTimeout(lstat(normalOutput), 'normal fs lstat')).isFile(), true)
assert.equal((await withTimeout(statfs(root), 'normal fs statfs')).bsize > 0, true)
const normalFd = openSync(normalOutput, 'r')
assert.equal((await withTimeout(fstatAsync(normalFd), 'normal fs fstat')).isFile(), true)
assert.equal(getEventLoopStats().nativeWorkPoolJobs, 0)

const workerSource = `
  const { exists, fstat } = require('node:fs');
  const { access, lstat, stat, statfs, writeFile } = require('node:fs/promises');
  const { parentPort, workerData } = require('node:worker_threads');
  const { getEventLoopStats } = require('bun:internal-for-testing');
  const targetStarted = getEventLoopStats().startedNativeWorkPoolProbeTasks + ${probeCount};
  for (let index = 0; index < ${probeCount}; index += 1) getEventLoopStats(false, true);
  const arm = () => {
    if (getEventLoopStats().startedNativeWorkPoolProbeTasks < targetStarted) {
      setTimeout(arm, 1);
      return;
    }
    void access(workerData.existing);
    exists(workerData.existing, () => {});
    void writeFile(workerData.output, 'worker');
    void stat(workerData.existing);
    void lstat(workerData.existing);
    fstat(workerData.fd, () => {});
    void statfs(workerData.root);
    parentPort.postMessage({ jobs: getEventLoopStats().nativeWorkPoolJobs });
  };
  arm();
`

try {
  for (let iteration = 0; iteration < 2; iteration += 1) {
    const before = getEventLoopStats()
    const worker = new Worker(workerSource, {
      eval: true,
      workerData: {
        existing: import.meta.path,
        fd: normalFd,
        output: join(root, `worker-${iteration}.txt`),
        root,
      },
    })
    let termination
    let released = false

    try {
      const [armed] = await withTimeout(once(worker, 'message'), 'fs task worker arm')
      assert.deepEqual(armed, { jobs: probeCount + 7 })

      let terminated = false
      termination = worker.terminate().then(exitCode => {
        terminated = true
        return exitCode
      })

      await new Promise(resolve => setTimeout(resolve, 50))
      assert.equal(terminated, false, 'worker teardown passed blocked native jobs')

      getEventLoopStats(false, false, true)
      released = true
      const exitCode = await withTimeout(termination, 'fs task worker termination')
      assert.equal(typeof exitCode, 'number')
      assert.equal(getEventLoopStats().completedNativeWorkPoolProbeTasks, before.completedNativeWorkPoolProbeTasks + probeCount)
      assert.equal(getEventLoopStats().cancelledAnyTasks, before.cancelledAnyTasks + 7)
    } finally {
      if (!released) getEventLoopStats(false, false, true)
      if (termination) await withTimeout(termination, 'fs task worker cleanup')
      else await withTimeout(worker.terminate(), 'fs task worker cleanup')
    }
  }
} finally {
  closeSync(normalFd)
  rmSync(root, { force: true, recursive: true })
}

console.log('native worker fs task shutdown passed')
