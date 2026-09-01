import assert from 'node:assert/strict'
import { once } from 'node:events'
import { createBrotliCompress, createDeflate, createZstdCompress } from 'node:zlib'
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

const beginNativeWrite = factory => {
  const codec = factory()
  const input = new Uint8Array(64).fill(97)
  const output = new Uint8Array(1024)
  const handle = codec._handle
  const { promise, resolve, reject } = Promise.withResolvers()
  codec.once('error', reject)
  handle.buffer = input
  handle.cb = resolve
  handle.availOutBefore = output.byteLength
  handle.availInBefore = input.byteLength
  handle.inOff = 0
  handle.flushFlag = codec._finishFlushFlag
  handle.write(
    codec._finishFlushFlag,
    input,
    0,
    input.byteLength,
    output,
    0,
    output.byteLength,
  )
  return { codec, promise }
}

for (const factory of [createDeflate, createBrotliCompress, createZstdCompress]) {
  const { codec, promise } = beginNativeWrite(factory)
  try {
    await withTimeout(promise, 'normal node:zlib write')
  } finally {
    codec.close()
  }
}
assert.equal(getEventLoopStats().nativeWorkPoolJobs, 0)

const workerSource = `
  const { createBrotliCompress, createDeflate, createZstdCompress } = require('node:zlib');
  const { parentPort } = require('node:worker_threads');
  const { getEventLoopStats } = require('bun:internal-for-testing');
  const retained = [];
  const targetStarted = getEventLoopStats().startedNativeWorkPoolProbeTasks + ${probeCount};
  for (let index = 0; index < ${probeCount}; index += 1) getEventLoopStats(false, true);
  const beginNativeWrite = factory => {
    const codec = factory();
    const input = new Uint8Array(64 * 1024).fill(97);
    const output = new Uint8Array(256 * 1024);
    const handle = codec._handle;
    handle.buffer = input;
    handle.cb = () => {};
    handle.availOutBefore = output.byteLength;
    handle.availInBefore = input.byteLength;
    handle.inOff = 0;
    handle.flushFlag = codec._finishFlushFlag;
    handle.write(
      codec._finishFlushFlag,
      input,
      0,
      input.byteLength,
      output,
      0,
      output.byteLength,
    );
    retained.push(codec, input, output);
  };
  const arm = () => {
    if (getEventLoopStats().startedNativeWorkPoolProbeTasks < targetStarted) {
      setTimeout(arm, 1);
      return;
    }
    beginNativeWrite(createDeflate);
    beginNativeWrite(createBrotliCompress);
    beginNativeWrite(createZstdCompress);
    parentPort.postMessage({ jobs: getEventLoopStats().nativeWorkPoolJobs });
  };
  arm();
`

for (let iteration = 0; iteration < 3; iteration += 1) {
  const before = getEventLoopStats()
  const worker = new Worker(workerSource, { eval: true })
  let termination
  let released = false

  try {
    const [armed] = await withTimeout(once(worker, 'message'), 'node:zlib worker arm')
    assert.deepEqual(armed, { jobs: probeCount + 3 })

    let terminated = false
    termination = worker.terminate().then(exitCode => {
      terminated = true
      return exitCode
    })

    await new Promise(resolve => setTimeout(resolve, 50))
    assert.equal(terminated, false, 'worker teardown passed blocked node:zlib writes')

    getEventLoopStats(false, false, true)
    released = true
    const exitCode = await withTimeout(termination, 'node:zlib worker termination')
    assert.equal(typeof exitCode, 'number')
    assert.equal(
      getEventLoopStats().completedNativeWorkPoolProbeTasks,
      before.completedNativeWorkPoolProbeTasks + probeCount,
    )
    assert.equal(getEventLoopStats().cancelledNodeZlibTasks, before.cancelledNodeZlibTasks + 3)
  } finally {
    if (!released) getEventLoopStats(false, false, true)
    if (termination) await withTimeout(termination, 'node:zlib worker cleanup')
    else await withTimeout(worker.terminate(), 'node:zlib worker cleanup')
  }
}

console.log('native worker node:zlib shutdown passed')
