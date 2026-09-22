import assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'
import { spawnSync } from 'node:child_process'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)

const root = mkdtempSync(join(tmpdir(), 'home-native-test-dispatch-'))
try {
  const mirror = join(root, 'packages', 'runtime', 'test')
  const corpus = join(mirror, 'test')
  mkdirSync(corpus, { recursive: true })
  writeFileSync(join(mirror, 'bunfig.toml'), '[test]\n')
  const fixture = join(corpus, 'nested-fixture.js')
  writeFileSync(fixture, `
    import { expect, test } from 'bun:test';
    test('explicit non-test fixture', () => {
      expect(process.execPath).toMatch(/home(?:-debug)?(?:\\.exe)?$/);
    });
  `)

  const env = { ...process.env, HOME_NATIVE_VM: '1', NO_COLOR: '1' }
  delete env.HOME_CORPUS_FULL_VM
  const child = spawnSync(process.execPath, ['test', fixture], {
    env,
    encoding: 'utf8',
    timeout: 15000,
  })
  assert.equal(child.error, undefined)
  assert.equal(child.signal, null, child.stderr)
  assert.equal(child.status, 0, child.stderr)
  assert.match(child.stdout, /^bun test v1\./)
  assert.match(child.stderr, /1 pass/)
  assert.match(child.stderr, /0 fail/)
} finally {
  rmSync(root, { recursive: true, force: true })
}

console.log('native test dispatch regressions passed')
