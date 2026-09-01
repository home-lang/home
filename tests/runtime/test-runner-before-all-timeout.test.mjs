import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const root = mkdtempSync(join(tmpdir(), 'home-test-timeout-'))
const fixture = join(root, 'before-all-timeout.test.mjs')

try {
  writeFileSync(
    fixture,
    `
      import { beforeAll, expect, setDefaultTimeout, test } from 'bun:test'

      beforeAll(() => setDefaultTimeout(250))

      test('inherits the default set by beforeAll', async () => {
        await Bun.sleep(75)
        expect(true).toBeTrue()
      })

      test('preserves an explicit timeout', async () => {
        await Bun.sleep(75)
        expect(true).toBeTrue()
      }, 500)
    `,
  )

  const child = spawnSync(process.execPath, ['test', fixture, '--timeout', '20'], {
    encoding: 'utf8',
    timeout: 10_000,
  })
  assert.equal(child.error, undefined)
  assert.equal(child.signal, null, child.stderr)
  assert.equal(child.status, 0, child.stderr)
  assert.match(child.stderr, /2 pass/)
} finally {
  rmSync(root, { force: true, recursive: true })
}

console.log('test runner beforeAll default timeout passed')
