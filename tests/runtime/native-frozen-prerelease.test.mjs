import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const directory = mkdtempSync(join(tmpdir(), 'home-frozen-prerelease-'))
const env = { ...process.env, HOME_NATIVE_VM: '1', NO_COLOR: '1' }
function install() {
  const result = spawnSync(process.execPath, ['install', '--lockfile-only', '--frozen-lockfile'], {
    cwd: directory, env, encoding: 'utf8', timeout: 10000,
  })
  assert.equal(result.error, undefined)
  assert.equal(result.signal, null)
  return result
}

try {
  for (const version of ['1.0.0', '1.0.0-alpha.1', '1.0.0-canary.20250226T140704', '1.0.0-alpha.1+build.20250226T140704']) {
    const dependencies = { 'native-prerelease-fixture': version, 'native-stable-fixture': '1.0.0' }
    const manifest = { name: 'prerelease-root', dependencies }
    const lock = {
      lockfileVersion: 1,
      configVersion: 0,
      workspaces: { '': manifest },
      packages: {
        'native-prerelease-fixture': [`native-prerelease-fixture@${version}`, '', {}, ''],
        'native-stable-fixture': ['native-stable-fixture@1.0.0', '', {}, ''],
      },
    }
    writeFileSync(join(directory, 'package.json'), JSON.stringify(manifest))
    writeFileSync(join(directory, 'bun.lock'), JSON.stringify(lock))
    const unchanged = install()
    assert.equal(unchanged.status, 0, `${version}: ${unchanged.stderr}`)
    assert.deepEqual(Bun.JSONC.parse(readFileSync(join(directory, 'bun.lock'), 'utf8')), lock)

    // Removing a dependency is a real graph change; frozen validation must
    // still reject it. All resolutions are in the fixture, so no registry is needed.
    delete manifest.dependencies['native-stable-fixture']
    writeFileSync(join(directory, 'package.json'), JSON.stringify(manifest))
    const before = readFileSync(join(directory, 'bun.lock'))
    const changed = install()
    assert.equal(changed.status, 1, changed.stderr)
    assert.match(changed.stderr, /lockfile had changes, but lockfile is frozen/)
    assert.deepEqual(readFileSync(join(directory, 'bun.lock')), before)
  }
} finally {
  rmSync(directory, { recursive: true, force: true })
}
console.log('native frozen prerelease regressions passed')
