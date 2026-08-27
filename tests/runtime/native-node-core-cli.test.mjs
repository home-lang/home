import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'

// These are native Home checks, not delegated Bun/Node compatibility results.
assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const env = {
  ...process.env,
  HOME_NATIVE_VM: '1',
  HOME_CORPUS_FULL_VM: '1',
  HOME_NATIVE_RUN: '0',
  NO_COLOR: '1',
}
function run(args) {
  const child = spawnSync(process.execPath, args, {
    env,
    encoding: 'utf8',
    timeout: 10000,
  })
  assert.equal(child.error, undefined)
  assert.equal(child.signal, null)
  return child
}

for (const [inputType, header] of [
  ['commonjs', 'const assert = require("node:assert/strict");'],
  ['module', 'import assert from "node:assert/strict";'],
]) {
  const source = header + ' assert.match(process.execPath, /home(?:-debug)?(?:\\.exe)?$/); console.log("native-eval-executed");'
  const success = run(['--input-type', inputType, '--eval', source])
  assert.equal(success.status, 0, success.stderr)
  assert.equal(success.stdout.trim(), 'native-eval-executed')

  const failure = run(['--input-type', inputType, '--eval', header + ' assert.ok(false, "native-assertion-sentinel");'])
  assert.equal(failure.status, 1)
  // Upstream only compares two extracted lines, allowing undefined ===
  // undefined when both children fail before evaluating the intended source.
  assert.match(failure.stderr, /AssertionError: native-assertion-sentinel/)
  assert.doesNotMatch(failure.stderr, /Module not found/)
}

const directory = mkdtempSync(join(tmpdir(), 'home-native-core-cli-'))
try {
  const fixture = join(directory, 'entry')
  writeFileSync(fixture, 'console.log(JSON.stringify(process.argv.slice(2)));')
  const implicit = run([fixture, 'test', '--no-warnings'])
  assert.equal(implicit.status, 0, implicit.stderr)
  assert.deepEqual(JSON.parse(implicit.stdout), ['test', '--no-warnings'])

  const missing = run([join(directory, 'missing-entry')])
  assert.equal(missing.status, 1)
  assert.match(missing.stderr, /not found/i)
  assert.match(missing.stderr, /missing-entry/)

  const testFile = join(directory, 'flags.test.js')
  writeFileSync(testFile, 'const { test } = require("node:test"); test("native test command", () => {});')
  const test = run(['--no-warnings', 'test', testFile])
  assert.equal(test.status, 0, test.stderr)
  assert.match(test.stdout + test.stderr, /1 pass/)
  assert.match(test.stdout + test.stderr, /Ran 1 test across 1 file/)
} finally {
  rmSync(directory, { recursive: true })
}
console.log('native node core CLI regressions passed')
