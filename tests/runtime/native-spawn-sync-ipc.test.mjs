import assert from 'node:assert/strict'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)

const directory = mkdtempSync(join(tmpdir(), 'home-native-sync-ipc-'))
try {
  writeFileSync(join(directory, 'package.json'), JSON.stringify({
    scripts: { ipc: 'printf "ipc-preserved\\n" >&3' },
  }))

  const child = Bun.spawn([process.execPath, 'run', '--silent', 'ipc'], {
    cwd: directory,
    env: {
      ...process.env,
      HOME_NATIVE_VM: '1',
      HOME_CORPUS_FULL_VM: '1',
      NODE_CHANNEL_FD: '3',
      NO_COLOR: '1',
    },
    stdio: ['ignore', 'pipe', 'pipe', 'pipe'],
  })
  const [stdout, stderr, ipc, code] = await Promise.all([
    child.stdout.text(),
    child.stderr.text(),
    Bun.file(child.stdio[3]).text(),
    child.exited,
  ])

  assert.deepEqual({ code, stdout, stderr, ipc }, {
    code: 0,
    stdout: '',
    stderr: '',
    ipc: 'ipc-preserved\n',
  })
  console.log('native synchronous spawn preserves IPC across exec')
} finally {
  rmSync(directory, { recursive: true, force: true })
}
