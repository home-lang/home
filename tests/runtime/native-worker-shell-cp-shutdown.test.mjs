import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { once } from 'node:events'
import { existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
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

const root = mkdtempSync(join(tmpdir(), 'home-shell-cp-shutdown-'))

const makeTree = path => {
  mkdirSync(join(path, 'nested'), { recursive: true })
  writeFileSync(join(path, 'root.txt'), 'root')
  writeFileSync(join(path, 'nested', 'child.txt'), 'child')
}

try {
  const normalSource = join(root, 'normal-source')
  const normalTarget = join(root, 'normal-target')
  makeTree(normalSource)
  await $`cp -R ${normalSource} ${normalTarget}`.quiet()
  assert.equal(readFileSync(join(normalTarget, 'root.txt'), 'utf8'), 'root')
  assert.equal(readFileSync(join(normalTarget, 'nested', 'child.txt'), 'utf8'), 'child')
  assert.equal(await $`cat ${join(normalTarget, 'root.txt')}`.text(), 'root')

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
      globalThis.shellJob = Bun.$\`cp -R \${workerData.source} \${workerData.target}\`.quiet();
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
    const source = join(root, `worker-source-${iteration}`)
    const target = join(root, `worker-target-${iteration}`)
    makeTree(source)

    const before = getEventLoopStats()
    const worker = new Worker(workerSource, { eval: true, workerData: { source, target } })
    let termination
    let released = false

    try {
      const [armed] = await withTimeout(once(worker, 'message'), 'shell cp worker arm')
      assert.deepEqual(armed, { jobs: probeCount + 1 })

      let terminated = false
      termination = worker.terminate().then(exitCode => {
        terminated = true
        return exitCode
      })

      await new Promise(resolveDelay => setTimeout(resolveDelay, 50))
      assert.equal(terminated, false, 'worker teardown passed a blocked shell cp graph')

      getEventLoopStats(false, false, true)
      released = true
      const exitCode = await withTimeout(termination, 'shell cp worker termination')
      assert.equal(typeof exitCode, 'number')
      assert.equal(
        getEventLoopStats().completedNativeWorkPoolProbeTasks,
        before.completedNativeWorkPoolProbeTasks + probeCount,
      )
      assert.equal(getEventLoopStats().cancelledShellTasks, before.cancelledShellTasks + 1)
      assert.equal(existsSync(target), true)
    } finally {
      if (!released) getEventLoopStats(false, false, true)
      if (termination) await withTimeout(termination, 'shell cp worker cleanup')
      else await withTimeout(worker.terminate(), 'shell cp worker cleanup')
    }
  }
} finally {
  rmSync(root, { force: true, recursive: true })
}

console.log('native worker shell cp shutdown passed')
