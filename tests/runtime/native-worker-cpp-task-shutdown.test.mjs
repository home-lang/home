import assert from 'node:assert/strict'
import { once } from 'node:events'
import { Worker } from 'node:worker_threads'
import { getEventLoopStats } from 'bun:internal-for-testing'

const workerSource = block => `
  const { parentPort } = require('node:worker_threads');
  const { getEventLoopStats } = require('bun:internal-for-testing');
  getEventLoopStats(true);
  parentPort.postMessage('armed');
  if (${block}) {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 10000);
  } else {
    parentPort.close();
  }
`

const snapshot = () => {
  const stats = getEventLoopStats()
  return {
    cancelled: stats.cancelledCppTasks,
    cleanupCancelled: stats.performedCleanupCppTasks,
    probePerformed: stats.performedShutdownProbeTasks,
    probeCleanupPerformed: stats.performedShutdownProbeCleanupActions,
  }
}

const delta = (after, before) => Object.fromEntries(
  Object.keys(after).map(key => [key, after[key] - before[key]]),
)

const waitForArmed = async worker => {
  let timeout
  try {
    const [message] = await Promise.race([
      once(worker, 'message'),
      new Promise((_, reject) => {
        timeout = setTimeout(() => {
          void worker.terminate()
          reject(new Error('worker arm timeout'))
        }, 5_000)
      }),
    ])
    assert.equal(message, 'armed')
  } finally {
    clearTimeout(timeout)
  }
}

const beforeNatural = snapshot()
const naturalWorker = new Worker(workerSource(false), { eval: true })
const naturalExit = once(naturalWorker, 'exit')
await waitForArmed(naturalWorker)
const [naturalExitCode] = await naturalExit
assert.equal(naturalExitCode, 0)
assert.deepEqual(delta(snapshot(), beforeNatural), {
  cancelled: 0,
  cleanupCancelled: 0,
  probePerformed: 1,
  probeCleanupPerformed: 1,
})

const beforeTerminated = snapshot()
const terminatedWorker = new Worker(workerSource(true), { eval: true })
await waitForArmed(terminatedWorker)
await terminatedWorker.terminate()
assert.deepEqual(delta(snapshot(), beforeTerminated), {
  cancelled: 1,
  cleanupCancelled: 1,
  probePerformed: 0,
  probeCleanupPerformed: 1,
})

console.log('native worker C++ task shutdown ownership passed')
