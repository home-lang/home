import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { basename } from 'node:path'
import { Readable, Writable } from 'node:stream'
import { pipeline } from 'node:stream/promises'
import { promisify } from 'node:util'
import { brotliCompressSync, brotliDecompress, brotliDecompressSync, createBrotliDecompress } from 'node:zlib'

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

// The pinned Rust NativeBrotli implementation preserves the enum suffix's
// leading underscore, including on callback and streaming error paths.
const decompress = promisify(brotliDecompress)
for (const [byte, code, errno] of [
  [0x01, 'ERR__ERROR_FORMAT_EXUBERANT_NIBBLE', -1],
  [0xff, 'ERR__ERROR_FORMAT_PADDING_2', -15],
  [0x11, 'ERR__ERROR_FORMAT_WINDOW_BITS', -13],
  [0x1c, 'ERR__ERROR_FORMAT_RESERVED', -2],
  [0x29, 'ERR__ERROR_FORMAT_PADDING_1', -14],
  [0x00, 'Z_BUF_ERROR', -5],
]) {
  const input = Buffer.alloc(4, byte)
  const expected = { name: 'Error', code, errno }
  assert.throws(() => brotliDecompressSync(input), expected)
  await assert.rejects(decompress(input), expected)
  let outputBytes = 0
  await assert.rejects(pipeline(
    Readable.from([input]),
    createBrotliDecompress(),
    new Writable({ write(chunk, encoding, callback) { outputBytes += chunk.length; callback() } }),
  ), expected)
  assert.equal(outputBytes, 0)
}
const valid = Buffer.from('Brotli recovers after corrupt input')
assert.deepEqual(await decompress(brotliCompressSync(valid)), valid)
console.log('native error code regressions passed')
