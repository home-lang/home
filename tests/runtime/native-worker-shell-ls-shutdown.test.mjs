import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { once } from 'node:events'
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Worker } from 'node:worker_threads'
import { $ } from 'bun'
import { getEventLoopStats } from 'bun:internal-for-testing'

const probeCount = getEventLoopStats().nativeWorkPoolThreads

if (process.env.BUN_ENABLE_EXPERIMENTAL_SHELL_BUILTINS !== '1') {
  const child = spawnSync(process.execPath, ['run', import.meta.path], {
    encoding: 'utf8',
    env: { ...process.env, BUN_ENABLE_EXPERIMENTAL_SHELL_BUILTINS: '1' },
    timeout: 30_000,
  })
  assert.equal(child.error, undefined)
  assert.equal(child.signal, null, child.stderr)
  assert.equal(child.status, 0, child.stderr)
  process.stdout.write(child.stdout)
  process.exit(0)
}

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

const root = mkdtempSync(join(tmpdir(), 'home-shell-ls-shutdown-'))
const source = join(root, 'source')

try {
  mkdirSync(join(source, 'nested'), { recursive: true })
  writeFileSync(join(source, 'root.txt'), 'root')
  writeFileSync(join(source, 'nested', 'child.txt'), 'child')

  const normal = await $`ls -R ${source}`.quiet().text()
  assert.match(normal, /root\.txt/)
  assert.match(normal, /nested/)
  assert.match(normal, /child\.txt/)

  const workerSource = `
    const { parentPort, workerData } = require('node:worker_threads');
    const { getEventLoopStats } = require('bun:internal-for-testing');
    const targetStarted = getEventLoopStats().startedNativeWorkPoolProbeTasks + ${probeCount};
    for (let index = 0; index < ${probeCount}; index += 1) getEventLoopStats(false, true);
    const arm = () => {
      if (getEventLoopStats().startedNativeWorkPoolProbeTasks < targetStarted) {
        setTimeout(arm, 1);
        return;
      }
      globalThis.shellJob = Bun.$\`ls -R \${workerData.source}\`.quiet();
      globalThis.shellCompletion = Promise.resolve(globalThis.shellJob);
      const waitForJob = () => {
        const jobs = getEventLoopStats().nativeWorkPoolJobs;
        if (jobs < ${probeCount + 1}) {
          setTimeout(waitForJob, 1);
          return;
        }
        parentPort.postMessage({ jobs });
      };
      waitForJob();
    };
    arm();
  `

  for (let iteration = 0; iteration < 3; iteration += 1) {
    const before = getEventLoopStats()
    const worker = new Worker(workerSource, { eval: true, workerData: { source } })
    let termination
    let released = false

    try {
      const [armed] = await withTimeout(once(worker, 'message'), 'shell ls worker arm')
      assert.deepEqual(armed, { jobs: probeCount + 1 })

      let terminated = false
      termination = worker.terminate().then(exitCode => {
        terminated = true
        return exitCode
      })

      await new Promise(resolveDelay => setTimeout(resolveDelay, 50))
      assert.equal(terminated, false, 'worker teardown passed a blocked shell ls task')

      getEventLoopStats(false, false, true)
      released = true
      const exitCode = await withTimeout(termination, 'shell ls worker termination')
      assert.equal(typeof exitCode, 'number')
      assert.equal(
        getEventLoopStats().completedNativeWorkPoolProbeTasks,
        before.completedNativeWorkPoolProbeTasks + probeCount,
      )
      assert.equal(getEventLoopStats().cancelledShellTasks, before.cancelledShellTasks + 2)
    } finally {
      if (!released) getEventLoopStats(false, false, true)
      if (termination) await withTimeout(termination, 'shell ls worker cleanup')
      else await withTimeout(worker.terminate(), 'shell ls worker cleanup')
    }
  }
} finally {
  rmSync(root, { force: true, recursive: true })
}

console.log('native worker shell ls shutdown passed')
