import assert from 'node:assert/strict'
import { once } from 'node:events'
import { closeSync, exists, fstat, mkdtempSync, openSync, read, readv, realpathSync, rmSync, symlinkSync, write, writev } from 'node:fs'
import { access, lstat, mkdir, mkdtemp, open, readFile, readdir, readlink, realpath, stat, statfs, writeFile } from 'node:fs/promises'
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
const normalLink = join(root, 'normal-link')
const fstatAsync = fd =>
  new Promise((resolve, reject) => {
    fstat(fd, (error, stats) => {
      if (error) reject(error)
      else resolve(stats)
    })
  })
const readAsync = (fd, buffer, position) =>
  new Promise((resolve, reject) => {
    read(fd, buffer, 0, buffer.length, position, (error, bytesRead) => {
      if (error) reject(error)
      else resolve(bytesRead)
    })
  })
const readvAsync = (fd, buffers, position) =>
  new Promise((resolve, reject) => {
    readv(fd, buffers, position, (error, bytesRead) => {
      if (error) reject(error)
      else resolve(bytesRead)
    })
  })
const writeAsync = (fd, buffer, position) =>
  new Promise((resolve, reject) => {
    write(fd, buffer, 0, buffer.length, position, (error, bytesWritten) => {
      if (error) reject(error)
      else resolve(bytesWritten)
    })
  })
const writevAsync = (fd, buffers, position) =>
  new Promise((resolve, reject) => {
    writev(fd, buffers, position, (error, bytesWritten) => {
      if (error) reject(error)
      else resolve(bytesWritten)
    })
  })

await withTimeout(writeFile(normalOutput, 'normal'), 'normal fs write')
symlinkSync(normalOutput, normalLink)
await withTimeout(access(normalOutput), 'normal fs access')
assert.equal(await withTimeout(new Promise(resolve => exists(normalOutput, resolve)), 'normal fs exists'), true)
assert.equal((await withTimeout(stat(normalOutput), 'normal fs stat')).isFile(), true)
assert.equal((await withTimeout(lstat(normalOutput), 'normal fs lstat')).isFile(), true)
assert.equal((await withTimeout(statfs(root), 'normal fs statfs')).bsize > 0, true)
assert.equal(await withTimeout(mkdir(join(root, 'normal', 'nested'), { recursive: true }), 'normal fs mkdir'), join(root, 'normal'))
assert.equal((await withTimeout(mkdtemp(join(root, 'λ-normal-')), 'normal fs mkdtemp')).startsWith(join(root, 'λ-normal-')), true)
assert.equal((await withTimeout(readFile(normalOutput), 'normal fs readFile buffer')).toString(), 'normal')
assert.equal(await withTimeout(readFile(normalOutput, 'utf8'), 'normal fs readFile string'), 'normal')
assert.equal((await withTimeout(readlink(normalLink, { encoding: 'buffer' }), 'normal fs readlink buffer')).toString(), normalOutput)
assert.equal(await withTimeout(readlink(normalLink, 'utf8'), 'normal fs readlink string'), normalOutput)
const expectedRealPath = realpathSync(normalOutput)
assert.equal((await withTimeout(realpath(normalLink, { encoding: 'buffer' }), 'normal fs realpath buffer')).toString(), expectedRealPath)
assert.equal(await withTimeout(realpath(normalLink, 'utf8'), 'normal fs realpath string'), expectedRealPath)
const normalFileHandle = await withTimeout(open(normalOutput, 'r'), 'normal fs open')
assert.equal((await withTimeout(normalFileHandle.stat(), 'normal fs file handle stat')).isFile(), true)
await withTimeout(normalFileHandle.close(), 'normal fs file handle close')
const normalFd = openSync(normalOutput, 'r+')
assert.equal((await withTimeout(fstatAsync(normalFd), 'normal fs fstat')).isFile(), true)
const normalReadBuffer = Buffer.alloc(1)
assert.equal(await withTimeout(readAsync(normalFd, normalReadBuffer, 0), 'normal fs read'), 1)
assert.equal(normalReadBuffer.toString(), 'n')
const normalReadvBuffer = Buffer.alloc(1)
assert.equal(await withTimeout(readvAsync(normalFd, [normalReadvBuffer], 1), 'normal fs readv'), 1)
assert.equal(normalReadvBuffer.toString(), 'o')
assert.equal(await withTimeout(writeAsync(normalFd, Buffer.from('N'), 0), 'normal fs write'), 1)
assert.equal(await withTimeout(writevAsync(normalFd, [Buffer.from('O')], 1), 'normal fs writev'), 1)
assert.equal(await withTimeout(readFile(normalOutput, 'utf8'), 'normal fs positional writes'), 'NOrmal')
assert.equal((await withTimeout(readdir(root), 'normal fs readdir strings')).includes('normal.txt'), true)
assert.equal(
  (await withTimeout(readdir(root, { encoding: 'buffer' }), 'normal fs readdir buffers')).some(
    entry => new TextDecoder().decode(entry) === 'normal.txt',
  ),
  true,
)
assert.equal(
  (await withTimeout(readdir(root, { withFileTypes: true }), 'normal fs readdir dirents')).some(
    entry => entry.name === 'normal.txt' && entry.isFile(),
  ),
  true,
)
assert.equal(
  (await withTimeout(readdir(root, { recursive: true }), 'normal fs recursive readdir strings')).includes(join('normal', 'nested')),
  true,
)
assert.equal(
  (await withTimeout(readdir(root, { encoding: 'buffer', recursive: true }), 'normal fs recursive readdir buffers')).some(
    entry => new TextDecoder().decode(entry) === join('normal', 'nested'),
  ),
  true,
)
assert.equal(
  (await withTimeout(readdir(root, { recursive: true, withFileTypes: true }), 'normal fs recursive readdir dirents')).some(
    entry => entry.name === 'nested' && entry.isDirectory(),
  ),
  true,
)
assert.equal(getEventLoopStats().nativeWorkPoolJobs, 0)

const workerSource = `
  const { exists, fstat, read, readv, write, writev } = require('node:fs');
  const { access, lstat, mkdir, mkdtemp, open, readFile, readdir, readlink, realpath, stat, statfs, writeFile } = require('node:fs/promises');
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
    void mkdir(workerData.mkdirTarget, { recursive: true });
    void mkdtemp(workerData.mkdtempPrefix);
    void readFile(workerData.existing);
    void readFile(workerData.existing, 'utf8');
    void readlink(workerData.link, { encoding: 'buffer' });
    void readlink(workerData.link, 'utf8');
    void realpath(workerData.link, { encoding: 'buffer' });
    void realpath(workerData.link, 'utf8');
    void open(workerData.existing, 'r');
    void readdir(workerData.root);
    void readdir(workerData.root, { encoding: 'buffer' });
    void readdir(workerData.root, { withFileTypes: true });
    void readdir(workerData.root, { recursive: true });
    void readdir(workerData.root, { encoding: 'buffer', recursive: true });
    void readdir(workerData.root, { recursive: true, withFileTypes: true });
    read(workerData.fd, Buffer.alloc(1), 0, 1, 0, () => {});
    readv(workerData.fd, [Buffer.alloc(1)], 1, () => {});
    write(workerData.fd, Buffer.from('N'), 0, 1, 0, () => {});
    writev(workerData.fd, [Buffer.from('O')], 1, () => {});
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
        link: normalLink,
        mkdirTarget: join(root, `worker-dir-${iteration}`, 'nested'),
        mkdtempPrefix: join(root, `λ-worker-${iteration}-`),
      },
    })
    let termination
    let released = false

    try {
      const [armed] = await withTimeout(once(worker, 'message'), 'fs task worker arm')
      assert.deepEqual(armed, { jobs: probeCount + 26 })

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
      assert.equal(getEventLoopStats().cancelledAnyTasks, before.cancelledAnyTasks + 26)
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
