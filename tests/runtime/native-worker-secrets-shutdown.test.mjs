import assert from 'node:assert/strict'
import { once } from 'node:events'
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
    const secret = Bun.secrets.get({
      service: 'home-native-worker-shutdown-probe',
      name: 'missing-secret',
    });
    parentPort.postMessage({
      jobs: getEventLoopStats().nativeWorkPoolJobs,
      promise: secret instanceof Promise,
    });
  };
  arm();
`

for (let iteration = 0; iteration < 2; iteration += 1) {
  const before = getEventLoopStats()
  const worker = new Worker(workerSource, { eval: true })
  let termination
  let released = false

  try {
    const [armed] = await withTimeout(once(worker, 'message'), 'secrets worker arm')
    assert.deepEqual(armed, { jobs: probeCount + 1, promise: true })

    let terminated = false
    termination = worker.terminate().then(exitCode => {
      terminated = true
      return exitCode
    })

    await new Promise(resolve => setTimeout(resolve, 50))
    assert.equal(terminated, false, 'worker teardown passed blocked native jobs')

    getEventLoopStats(false, false, true)
    released = true
    const exitCode = await withTimeout(termination, 'secrets worker termination')
    assert.equal(typeof exitCode, 'number')
    assert.equal(getEventLoopStats().completedNativeWorkPoolProbeTasks, before.completedNativeWorkPoolProbeTasks + probeCount)
    assert.equal(getEventLoopStats().cancelledAnyTasks, before.cancelledAnyTasks + 1)
  } finally {
    if (!released) getEventLoopStats(false, false, true)
    if (termination) await withTimeout(termination, 'secrets worker cleanup')
    else await withTimeout(worker.terminate(), 'secrets worker cleanup')
  }
}

console.log('native worker secrets shutdown passed')
