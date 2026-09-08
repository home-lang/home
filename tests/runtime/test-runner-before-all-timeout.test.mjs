// A test's timeout is resolved ONCE, when the test is declared — not when it
// starts running. Collection finishes before any beforeAll hook runs, so a
// setDefaultTimeout() call inside beforeAll arrives too late to affect tests
// that were already declared; only a top-level call precedes collection.
//
// This is Bun's behaviour (ScopeFunctions.rs resolves options.timeout at
// declaration and Execution.rs uses entry.timeout verbatim), and it is worth
// pinning because the alternative is a silent hazard: re-reading the override
// at test-start time hands every inherited test the raised default, so a file
// like js/node/dns/node-dns.test.js — which calls setDefaultTimeout(5 minutes)
// in beforeAll — stops being cut off at 5s and can sit for the full 300s.
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const root = mkdtempSync(join(tmpdir(), 'home-test-timeout-'))

function run(name, source, args) {
  const fixture = join(root, name)
  writeFileSync(fixture, source)
  const child = spawnSync(process.execPath, ['test', fixture, ...args], {
    encoding: 'utf8',
    timeout: 30_000,
  })
  assert.equal(child.error, undefined)
  assert.equal(child.signal, null, child.stderr)
  return child
}

try {
  // beforeAll runs after collection, so the raised default does NOT reach the
  // inherited test; the explicit per-test timeout is unaffected either way.
  const late = run(
    'before-all-timeout.test.mjs',
    `
      import { beforeAll, expect, setDefaultTimeout, test } from 'bun:test'

      beforeAll(() => setDefaultTimeout(250))

      test('does not inherit a default raised in beforeAll', async () => {
        await Bun.sleep(75)
        expect(true).toBeTrue()
      })

      test('preserves an explicit timeout', async () => {
        await Bun.sleep(75)
        expect(true).toBeTrue()
      }, 500)
    `,
    ['--timeout', '20'],
  )
  assert.match(late.stderr, /1 pass/, late.stderr)
  assert.match(late.stderr, /1 fail/, late.stderr)
  assert.match(late.stderr, /timed out after 20ms/, late.stderr)

  // A top-level call precedes collection, so it DOES apply.
  const early = run(
    'top-level-timeout.test.mjs',
    `
      import { expect, setDefaultTimeout, test } from 'bun:test'

      setDefaultTimeout(250)

      test('inherits a default set before collection', async () => {
        await Bun.sleep(75)
        expect(true).toBeTrue()
      })
    `,
    ['--timeout', '20'],
  )
  assert.equal(early.status, 0, early.stderr)
  assert.match(early.stderr, /1 pass/, early.stderr)
} finally {
  rmSync(root, { force: true, recursive: true })
}

console.log('test runner setDefaultTimeout resolution passed')
