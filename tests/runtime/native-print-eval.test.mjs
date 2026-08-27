import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const env = { ...process.env, HOME_NATIVE_VM: '1', HOME_NATIVE_RUN: '0', NO_COLOR: '1' }
delete env.HOME_CORPUS_FULL_VM
const directory = mkdtempSync(join(tmpdir(), 'home-print-eval-'))
function run(args, options = {}) {
  const child = spawnSync(process.execPath, args, { env, encoding: 'utf8', timeout: 10000, ...options })
  const preload = Number.isInteger(child.pid) && child.pid > 0 ? '/tmp/home-eval-globals-' + child.pid + '.js' : null
  try {
    assert.equal(child.error, undefined)
    assert.equal(child.signal, null, JSON.stringify(args) + '\n' + child.stderr)
    // Native eval's generated preload must not accumulate after each child.
    assert.equal(existsSync(preload), false, 'generated preload leaked: ' + JSON.stringify(args))
    return child
  } finally {
    // A failing cleanup regression should not itself leave its child's file.
    if (preload) rmSync(preload, { force: true })
  }
}
function success(args, expected, options) {
  const child = run(args, options)
  assert.equal(child.status, 0, child.stderr)
  assert.equal(child.stderr, '')
  assert.equal(child.stdout.trim(), expected)
}
try {
  for (const prefix of [['-p'], ['--print'], ['--no-warnings', '-p'], ['--input-type', 'module', '--print']]) {
    success([...prefix, 'const value: number = 21; value * 2'], '42')
    success([...prefix, 'if (true) { 42 }'], '42')
    success([...prefix, 'console.log("before"); 42'], 'before\n42')
    success([...prefix, 'Promise.resolve(42)'], '42')
    success([...prefix, '(await 1) + 1'], '2')
    success([...prefix, 'new Promise(resolve => setTimeout(() => resolve(42), 10))'], '42')
    success([...prefix, 'new Promise(() => {})'], 'Promise { <pending> }')
    success([...prefix, 'typeof require("node:timers/promises").setInterval'], 'function')
    success([...prefix, 'JSON.stringify(process.argv.slice(1))', 'first', '--second'], '["first","--second"]')
    success([...prefix, 'JSON.stringify(process.argv.slice(1))', '--', 'first', '--', 'second'], '["first","--","second"]')
    success([...prefix, 'JSON.stringify(process._eval)'], JSON.stringify('JSON.stringify(process._eval)'))
    const earlyExit = run([...prefix, 'process.exit(7)'])
    assert.equal(earlyExit.status, 7)
    assert.equal(earlyExit.stdout, '')

    // An unref'ed timer must neither keep the child alive nor call its handler.
    // Upstream's stderr-only child assertion misses the latter failure because
    // the former reduced eval realm also loses rejected-promise diagnostics.
    for (const expression of [
      'require("node:timers/promises").setTimeout(150, null, {ref: false})',
      'require("node:timers/promises").setImmediate(null, {ref: false})',
      'require("node:timers/promises").setInterval(150, null, {ref: false})[Symbol.asyncIterator]().next()',
    ]) {
      const child = run([...prefix, expression + '.then(() => console.log("UNREF_TIMER_FIRED"))'])
      assert.equal(child.status, 0, child.stderr)
      assert.equal(child.stderr, '')
      assert.doesNotMatch(child.stdout, /UNREF_TIMER_FIRED/)
      assert.match(child.stdout, /Promise\s*\{\s*<pending>\s*\}/)
    }

    const failure = run([...prefix, 'throw new Error("native-print-sentinel")'])
    assert.equal(failure.status, 1)
    assert.match(failure.stderr, /error: native-print-sentinel/)
    assert.doesNotMatch(failure.stderr, /SyntaxError|Module not found/)
    for (const source of [
      'Promise.reject(new Error("native-print-rejected"))',
      'new Promise((resolve, reject) => setTimeout(() => reject(new Error("native-print-rejected")), 10))',
    ]) {
      const rejected = run([...prefix, source])
      assert.equal(rejected.status, 1)
      assert.match(rejected.stderr, /error: native-print-rejected/)
      assert.match(rejected.stderr, /Bun v/)
    }
  }
  success(['--eval', 'const value = 21; value * 2', '--print'], '42')
  for (const prefix of [['-e'], ['--eval'], ['--no-warnings', '--eval']]) {
    success([...prefix, 'console.log(JSON.stringify(process.argv.slice(1)))', '--', 'first', '--', 'second'], '["first","--","second"]')
    const source = 'console.log(JSON.stringify(process._eval)) // trailing comment'
    success([...prefix, source], JSON.stringify(source))
  }
  success(['eval', 'const value = 21; value * 2', '--print'], '42')
  success(['--no-warnings', '--eval', 'const value = 21; value * 2', '--print'], '42')
  success(['-p', 'import { basename } from "node:path"; basename(process.execPath)'], basename(process.execPath))
  writeFileSync(join(directory, 'value.ts'), 'export const value: number = 42;')
  success(['-p', 'import { value } from "./value.ts"; value'], '42', { cwd: directory })
  const exitCode = run(['-p', 'process.exitCode = 7; 42'])
  assert.equal(exitCode.status, 7)
  assert.equal(exitCode.stdout.trim(), '42')
} finally {
  rmSync(directory, { recursive: true })
}
console.log('native print/eval regressions passed')
