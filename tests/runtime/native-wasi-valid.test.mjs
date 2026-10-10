import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { WASI } from 'node:wasi'

const output = []
const wasi = new WASI({ args: ['home', 'héllo'], env: { HOME_WASI_TEST: 'value' }, sendStdout: bytes => output.push(Buffer.from(bytes)) })
const module = new WebAssembly.Module(readFileSync(join(import.meta.dir, '../../packages/runtime/test/test/js/bun/wasm/hello-wasi.wasm')))
const instance = new WebAssembly.Instance(module, wasi.getImports(module))
wasi.start(instance)
assert.equal(Buffer.concat(output).toString(), 'hello world\n')

const previousBytes = Buffer.from(instance.exports.memory.buffer)
const previousHeader = Buffer.from(previousBytes.subarray(0, 8))
const memory = new WebAssembly.Memory({ initial: 1 })
wasi.setMemory(memory)
let bytes = Buffer.from(memory.buffer)
assert.equal(wasi.wasiImport.args_sizes_get(0, 4), 0)
assert.equal(bytes.readUInt32LE(0), 2)
assert.equal(bytes.readUInt32LE(4), Buffer.byteLength('home\0héllo\0'))
assert.deepEqual(previousBytes.subarray(0, 8), previousHeader)
assert.equal(wasi.wasiImport.args_get(16, 64), 0)
assert.equal(bytes.readUInt32LE(16), 64)
assert.equal(bytes.readUInt32LE(20), 69)
assert.equal(bytes.subarray(64, 64 + Buffer.byteLength('home\0héllo\0')).toString(), 'home\0héllo\0')
assert.equal(wasi.wasiImport.environ_sizes_get(0, 4), 0)
assert.equal(bytes.readUInt32LE(0), 1)
assert.equal(wasi.wasiImport.environ_get(16, 128), 0)
assert.equal(bytes.subarray(128, 128 + Buffer.byteLength('HOME_WASI_TEST=value\0')).toString(), 'HOME_WASI_TEST=value\0')

memory.grow(1)
bytes = Buffer.from(memory.buffer)
assert.equal(wasi.wasiImport.args_get(65536, 65600), 0)
assert.equal(bytes.readUInt32LE(65536), 65600)
assert.equal(bytes.subarray(65600, 65605).toString(), 'home\0')
console.log('native WASI valid module, arguments, environment and memory growth passed')
