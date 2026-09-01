import assert from 'node:assert/strict'
import { once } from 'node:events'
import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Worker } from 'node:worker_threads'
import { $ } from 'bun'
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

const root = mkdtempSync(join(tmpdir(), 'home-shell-task-shutdown-'))
const normalDir = join(root, 'normal-dir')
const normalFile = join(root, 'normal-file')
const normalSource = join(root, 'normal-source')
const normalTarget = join(root, 'normal-target')
const normalCond = join(root, 'normal-cond')

try {
  writeFileSync(normalSource, 'move me')
  writeFileSync(normalCond, 'test me')
  writeFileSync(join(root, 'normal.glob'), 'match me')
  const [, , , condResult, globResult] = await Promise.all([
    $`mkdir ${normalDir}`.quiet(),
    $`touch ${normalFile}`.quiet(),
    $`mv ${normalSource} ${normalTarget}`.quiet(),
    $`[[ -f ${normalCond} ]]`.nothrow().quiet(),
    $`echo *.glob`.cwd(root).quiet(),
  ])
  assert.equal(existsSync(normalDir), true)
  assert.equal(existsSync(normalFile), true)
  assert.equal(existsSync(normalTarget), true)
  assert.equal(condResult.exitCode, 0)
  assert.equal(globResult.stdout.toString(), 'normal.glob\n')

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
      globalThis.shellJobs = [
        Bun.$\`mkdir \${workerData.mkdir}\`.quiet(),
        Bun.$\`touch \${workerData.touch}\`.quiet(),
        Bun.$\`mv \${workerData.mvSource} \${workerData.mvTarget}\`.quiet(),
        Bun.$\`[[ -f \${workerData.cond} ]]\`.nothrow().quiet(),
        Bun.$\`echo *.glob\`.cwd(workerData.root).quiet(),
      ];
      globalThis.shellCompletion = Promise.allSettled(globalThis.shellJobs);
      const waitForJobs = () => {
        const jobs = getEventLoopStats().nativeWorkPoolJobs;
        if (jobs < ${probeCount + 5}) {
          setTimeout(waitForJobs, 1);
          return;
        }
        parentPort.postMessage({ jobs });
      };
      waitForJobs();
    };
    arm();
  `

  for (let iteration = 0; iteration < 3; iteration += 1) {
    const iterationRoot = join(root, `worker-${iteration}`)
    await $`mkdir ${iterationRoot}`.quiet()
    const mvSource = join(iterationRoot, 'move-source')
    writeFileSync(mvSource, 'move me')
    writeFileSync(join(iterationRoot, 'match.glob'), 'match me')

    const before = getEventLoopStats()
    const worker = new Worker(workerSource, {
      eval: true,
      workerData: {
        root: iterationRoot,
        mkdir: join(iterationRoot, 'created-dir'),
        touch: join(iterationRoot, 'touched-file'),
        mvSource,
        mvTarget: join(iterationRoot, 'move-target'),
        cond: mvSource,
      },
    })
    let termination
    let released = false

    try {
      const [armed] = await withTimeout(once(worker, 'message'), 'shell worker arm')
      assert.deepEqual(armed, { jobs: probeCount + 5 })

      let terminated = false
      termination = worker.terminate().then(exitCode => {
        terminated = true
        return exitCode
      })

      await new Promise(resolveDelay => setTimeout(resolveDelay, 50))
      assert.equal(terminated, false, 'worker teardown passed blocked shell tasks')

      getEventLoopStats(false, false, true)
      released = true
      const exitCode = await withTimeout(termination, 'shell worker termination')
      assert.equal(typeof exitCode, 'number')
      assert.equal(
        getEventLoopStats().completedNativeWorkPoolProbeTasks,
        before.completedNativeWorkPoolProbeTasks + probeCount,
      )
      assert.equal(getEventLoopStats().cancelledShellTasks, before.cancelledShellTasks + 5)
    } finally {
      if (!released) getEventLoopStats(false, false, true)
      if (termination) await withTimeout(termination, 'shell worker cleanup')
      else await withTimeout(worker.terminate(), 'shell worker cleanup')
    }
  }
} finally {
  rmSync(root, { force: true, recursive: true })
}

console.log('native worker shell task shutdown passed')
