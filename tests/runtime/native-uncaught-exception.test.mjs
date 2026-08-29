import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const directory = mkdtempSync(join(tmpdir(), 'home-uncaught-exception-'))
const env = { ...process.env, HOME_NATIVE_VM: '1', HOME_NATIVE_RUN: '0', NO_COLOR: '1' }
function run(source) {
  const file = join(directory, 'entry.cjs')
  writeFileSync(file, source)
  const child = spawnSync(process.execPath, ['run', file], { env, encoding: 'utf8', timeout: 10000 })
  assert.equal(child.error, undefined)
  assert.equal(child.signal, null, child.stderr.slice(0, 1000))
  return child
}
try {
  const handled = run([
    'process.once("uncaughtException", error => {',
    '  if (error.message !== "handled-sentinel") throw new Error("wrong error");',
    '  console.log("handled");',
    '  Promise.resolve().then(() => console.log("microtask"));',
    '  setImmediate(() => console.log("immediate"));',
    '});',
    'throw new Error("handled-sentinel");',
  ].join('\n'))
  assert.equal(handled.status, 0, handled.stderr)
  assert.deepEqual(handled.stdout.trim().split('\n'), ['handled', 'microtask', 'immediate'])
  assert.equal(handled.stderr, '')

  const customExit = run('process.once("uncaughtException", () => { process.exitCode = 23; }); throw new Error("handled");')
  assert.equal(customExit.status, 23)
  assert.equal(customExit.stderr, '')

  const unhandled = run('throw new Error("unhandled-sentinel");')
  assert.equal(unhandled.status, 1)
  assert.match(unhandled.stderr, /error: unhandled-sentinel/)

  const throwingHandler = run('process.once("uncaughtException", () => { throw new Error("handler-sentinel"); }); throw new Error("original");')
  assert.notEqual(throwingHandler.status, 0)
  assert.match(throwingHandler.stderr, /handler-sentinel/)
} finally {
  rmSync(directory, { recursive: true })
}
console.log('native uncaught exception regressions passed')
