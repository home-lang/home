import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { once } from 'node:events'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Worker } from 'node:worker_threads'
import { getEventLoopStats } from 'bun:internal-for-testing'

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

const root = await mkdtemp(join(tmpdir(), 'home-blob-poll-shutdown-'))
const normalPath = join(root, 'normal.txt')

const createFifo = path => {
  const result = spawnSync('mkfifo', [path], { encoding: 'utf8' })
  assert.equal(result.error, undefined)
  assert.equal(result.signal, null, result.stderr)
  assert.equal(result.status, 0, result.stderr)
}

const workerSource = `
  const { parentPort, workerData } = require('node:worker_threads');
  const { getEventLoopStats } = require('bun:internal-for-testing');
  if (workerData.operation === 'read') void Bun.file(workerData.path).text();
  else void Bun.write(workerData.path, new Uint8Array(8 * 1024 * 1024));
  const reportWhenParked = () => {
    const stats = getEventLoopStats();
    if (stats.nativePollableWorkPoolJobs === 1 && stats.nativeWorkPoolJobs === 0) {
      parentPort.postMessage({ pollable: stats.nativePollableWorkPoolJobs, workers: stats.nativeWorkPoolJobs });
      return;
    }
    setTimeout(reportWhenParked, 1);
  };
  reportWhenParked();
`

const runParkedScenario = async operation => {
  const fifoPath = join(root, `${operation}.fifo`)
  createFifo(fifoPath)
  const holder = Bun.spawn({
    // Keep both FIFO ends open so startup cannot transiently report HUP before
    // the holder and worker have paired. The holder never transfers data: the
    // read stays empty and the large write fills the kernel buffer, then parks.
    cmd: ['sh', '-c', `exec 3<>"${fifoPath}"; sleep 30`],
    stdout: 'ignore',
    stderr: 'ignore',
  })
  const before = getEventLoopStats()
  const worker = new Worker(workerSource, {
    eval: true,
    workerData: { operation, path: fifoPath },
  })
  let termination

  try {
    const [parked] = await withTimeout(once(worker, 'message'), `${operation} worker park`)
    assert.deepEqual(parked, { pollable: 1, workers: 0 })

    termination = worker.terminate()
    const exitCode = await withTimeout(termination, `${operation} worker termination`)
    assert.equal(typeof exitCode, 'number')
    assert.equal(getEventLoopStats().cancelledWorkTasks, before.cancelledWorkTasks + 1)
  } finally {
    if (termination) await withTimeout(termination, `${operation} worker cleanup`)
    else await withTimeout(worker.terminate(), `${operation} worker cleanup`)
    holder.kill()
    await withTimeout(holder.exited, `${operation} FIFO holder cleanup`)
  }
}

try {
  await writeFile(normalPath, 'normal Blob I/O')
  assert.equal(await Bun.file(normalPath).text(), 'normal Blob I/O')
  assert.equal(await Bun.write(normalPath, 'updated Blob I/O'), 16)
  assert.equal(await readFile(normalPath, 'utf8'), 'updated Blob I/O')
  assert.equal(getEventLoopStats().nativePollableWorkPoolJobs, 0)

  await runParkedScenario('read')
  await runParkedScenario('write')
  assert.equal(getEventLoopStats().nativePollableWorkPoolJobs, 0)
} finally {
  await rm(root, { recursive: true, force: true })
}

console.log('native worker Blob poll shutdown passed')
