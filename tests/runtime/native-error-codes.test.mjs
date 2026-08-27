import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { basename } from 'node:path'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const env = { ...process.env, HOME_NATIVE_VM: '1', HOME_NATIVE_RUN: '0', NO_COLOR: '1' }
function run(source) {
  const child = spawnSync(process.execPath, ['--eval', source], { env, encoding: 'utf8', timeout: 10000 })
  assert.equal(child.error, undefined)
  assert.equal(child.signal, null)
  assert.equal(child.status, 0, child.stderr)
  return child
}

const warning = run('process.emitWarning("warning-sentinel", "DeprecationWarning", "DEP0170");')
assert.match(warning.stderr, /DeprecationWarning: warning-sentinel/)
assert.match(warning.stderr, /code:\s*"DEP0170"/)

const hidden = run('const e = new Error("hidden-sentinel"); Object.defineProperty(e, "code", { value: "E_HIDDEN" }); console.warn(e);')
assert.match(hidden.stderr, /code:\s*"E_HIDDEN"/)
assert.equal(hidden.stderr.match(/E_HIDDEN/g).length, 1)

const inherited = run('const e = new Error("inherited-sentinel"); Object.setPrototypeOf(e, Object.assign(Object.create(Error.prototype), { code: "E_INHERITED" })); console.warn(e);')
assert.match(inherited.stderr, /E_INHERITED/)

const accessor = run([
  'let reads = 0;',
  'const e = new Error("accessor-sentinel");',
  'Object.defineProperty(e, "code", { get() { reads++; throw new Error("getter must not execute"); } });',
  'console.warn(e);',
  'console.log(reads);',
].join('\n'))
assert.equal(accessor.stdout.trim(), '0')
assert.doesNotMatch(accessor.stderr, /getter must not execute/)
console.log('native error code regressions passed')
