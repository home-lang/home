import assert from 'node:assert/strict'
import { once } from 'node:events'
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
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
        timeout = setTimeout(() => reject(new Error(`${label} timeout`)), 5_000)
      }),
    ])
  } finally {
    clearTimeout(timeout)
  }
}

const root = mkdtempSync(join(tmpdir(), 'home-archive-shutdown-'))
try {
  const archive = new Bun.Archive({
    'hello.txt': 'hello',
    'nested/world.txt': 'world',
  })
  const bytes = await withTimeout(archive.bytes(), 'normal archive bytes')
  const files = await withTimeout(new Bun.Archive(bytes).files(), 'normal archive files')
  assert.equal(await files.get('hello.txt').text(), 'hello')
  assert.equal(await files.get('nested/world.txt').text(), 'world')

  const archivePath = join(root, 'fixture.tar')
  await withTimeout(Bun.Archive.write(archivePath, archive), 'normal archive write')
  const extractPath = join(root, 'extracted')
  mkdirSync(extractPath)
  const diskArchive = new Bun.Archive(await Bun.file(archivePath).bytes())
  assert.equal(await withTimeout(diskArchive.extract(extractPath), 'normal archive extract'), 2)
  assert.equal(readFileSync(join(extractPath, 'hello.txt'), 'utf8'), 'hello')
  assert.equal(readFileSync(join(extractPath, 'nested/world.txt'), 'utf8'), 'world')
  assert.equal(getEventLoopStats().nativeWorkPoolJobs, 0)
} finally {
  rmSync(root, { recursive: true, force: true })
}

const workerSource = `
  const { randomBytes } = require('node:crypto');
  const { parentPort } = require('node:worker_threads');
  const { getEventLoopStats } = require('bun:internal-for-testing');
  const archive = new Bun.Archive(randomBytes(16 * 1024 * 1024), { compress: 'gzip', level: 12 });
  void archive.bytes();
  parentPort.postMessage({ jobs: getEventLoopStats().nativeWorkPoolJobs });
`

for (let iteration = 0; iteration < 3; iteration += 1) {
  const before = getEventLoopStats().cancelledArchiveTasks
  const worker = new Worker(workerSource, { eval: true })
  let terminated = false

  try {
    const [armed] = await withTimeout(once(worker, 'message'), 'archive worker arm')
    assert.deepEqual(armed, { jobs: 1 })
    const exitCode = await withTimeout(worker.terminate(), 'archive worker termination')
    terminated = true
    assert.equal(typeof exitCode, 'number')
    assert.equal(getEventLoopStats().cancelledArchiveTasks, before + 1)
  } finally {
    if (!terminated) await withTimeout(worker.terminate(), 'archive worker cleanup')
  }
}

console.log('native worker archive shutdown passed')
