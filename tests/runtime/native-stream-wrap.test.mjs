// Flags: --expose-internals
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { PassThrough } from 'node:stream'

const require = createRequire(import.meta.url)
require('../../packages/runtime/test/bun-corpus/js/node/test/common')
const { internalBinding } = require('internal/test/binding')
const JSStreamSocket = require('internal/js_stream_socket')
const AsyncContextFrame = require('internal/async_context_frame')
const { enabledHooksExist } = require('internal/async_hooks')
const { addAbortSignalNoValidate } = require('internal/streams/add-abort-signal')
const binding = internalBinding('stream_wrap')

assert.equal(JSStreamSocket.StreamWrap, JSStreamSocket)
assert.equal(typeof AsyncContextFrame.current, 'function')
assert.equal(typeof enabledHooksExist, 'function')
assert.equal(typeof addAbortSignalNoValidate, 'function')
assert.deepEqual(
  [
    binding.kReadBytesOrError,
    binding.kArrayBufferOffset,
    binding.kBytesWritten,
    binding.kLastWriteWasAsync,
  ],
  [0, 1, 2, 3],
)
assert(binding.streamBaseState instanceof Int32Array)
assert.equal(binding.streamBaseState.length, 4)

for (const Request of [binding.ShutdownWrap, binding.WriteWrap]) {
  const request = new Request()
  assert.equal(request.oncomplete, null)
  assert.equal(request.callback, null)
  assert.equal(request.handle, null)
}

const transport = new PassThrough({ highWaterMark: 1 })
const socket = new JSStreamSocket(transport)
assert.equal(socket._handle._parentWrap, socket)

const writes = []
transport.on('data', chunk => writes.push(chunk.toString()))

const writeCompleted = new Promise((resolve, reject) => {
  socket.write(Buffer.from('owned'), error => error ? reject(error) : resolve())
})
const shutdown = new binding.ShutdownWrap()
let shutdownCalls = 0
const shutdownCompleted = new Promise(resolve => {
  shutdown.oncomplete = status => {
    shutdownCalls++
    assert.equal(status, 0)
    resolve()
  }
})
assert.equal(socket._handle.shutdown(shutdown), 0)
await Promise.all([writeCompleted, shutdownCompleted])
assert.deepEqual(writes, ['owned'])
assert.equal(shutdownCalls, 1)

const cancelledTransport = new PassThrough()
const cancelledSocket = new JSStreamSocket(cancelledTransport)
const cancelled = new binding.ShutdownWrap()
let cancellationCalls = 0
const cancellationCompleted = new Promise(resolve => {
  cancelled.oncomplete = status => {
    cancellationCalls++
    assert(status < 0)
    resolve()
  }
})
assert.equal(cancelledSocket._handle.shutdown(cancelled), 0)
cancelledSocket.destroy()
await cancellationCompleted
await new Promise(resolve => setImmediate(resolve))
assert.equal(cancellationCalls, 1)

console.log('native stream_wrap request surface and lifecycle passed')
