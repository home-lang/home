import assert from 'node:assert/strict'
import { createBrotliCompress, createDeflate, createZstdCompress } from 'node:zlib'

const codecs = [
  ['zlib', createDeflate],
  ['brotli', createBrotliCompress],
  ['zstd', createZstdCompress],
]

function beginNativeWrite(codec, input, output) {
  const handle = codec._handle
  const { promise, resolve, reject } = Promise.withResolvers()
  codec.once('error', reject)
  handle.buffer = input
  handle.cb = resolve
  handle.availOutBefore = output.byteLength
  handle.availInBefore = input.byteLength
  handle.inOff = 0
  handle.flushFlag = codec._finishFlushFlag
  handle.write(
    codec._finishFlushFlag,
    input,
    0,
    input.byteLength,
    output,
    0,
    output.byteLength,
  )
  return { handle, promise }
}

for (const [name, factory] of codecs) {
  {
    const codec = factory()
    try {
      const input = new Uint8Array(new ArrayBuffer(64)).fill(97)
      const output = new Uint8Array(new ArrayBuffer(1024))
      const inputBuffer = input.buffer
      const outputBuffer = output.buffer
      const { handle, promise } = beginNativeWrite(codec, input, output)

      const rejectedInput = new Uint8Array(new ArrayBuffer(8))
      const rejectedOutput = new Uint8Array(new ArrayBuffer(128))
      assert.throws(() => handle.write(
        codec._finishFlushFlag,
        rejectedInput,
        0,
        rejectedInput.byteLength,
        rejectedOutput,
        0,
        rejectedOutput.byteLength,
      ), { code: 'ERR_INVALID_STATE' })
      rejectedInput.buffer.transfer()
      rejectedOutput.buffer.transfer()
      assert.equal(rejectedInput.buffer.detached, true, `${name} does not pin a rejected input`)
      assert.equal(rejectedOutput.buffer.detached, true, `${name} does not pin a rejected output`)

      inputBuffer.transfer()
      outputBuffer.transfer()
      assert.equal(inputBuffer.detached, false, `${name} pins async input`)
      assert.equal(outputBuffer.detached, false, `${name} pins async output`)

      await promise

      inputBuffer.transfer()
      outputBuffer.transfer()
      assert.equal(inputBuffer.detached, true, `${name} releases async input`)
      assert.equal(outputBuffer.detached, true, `${name} releases async output`)
    } finally {
      codec.close()
    }
  }

  {
    const codec = factory()
    try {
      const input = new Uint8Array(new ArrayBuffer(8))
      const output = new Uint8Array(new ArrayBuffer(128))
      assert.throws(() => codec._handle.write(
        codec._finishFlushFlag,
        input,
        0,
        input.byteLength + 1,
        output,
        0,
        output.byteLength,
      ), { code: 'ERR_OUT_OF_RANGE' })
      input.buffer.transfer()
      output.buffer.transfer()
      assert.equal(input.buffer.detached, true, `${name} validates bounds before pinning input`)
      assert.equal(output.buffer.detached, true, `${name} validates bounds before pinning output`)
    } finally {
      codec.close()
    }
  }

  {
    const codec = factory()
    try {
      let input = new Uint8Array(new ArrayBuffer(64)).fill(98)
      let output = new Uint8Array(new ArrayBuffer(1024))
      const inputRef = new WeakRef(input)
      const outputRef = new WeakRef(output)
      const { handle, promise } = beginNativeWrite(codec, input, output)

      // Remove processChunk's extra input root as well as the local roots. The
      // generated pending fields must independently keep both views alive.
      handle.buffer = null
      input = null
      output = null
      Bun.gc(true)
      assert.ok(inputRef.deref(), `${name} roots async input`)
      assert.ok(outputRef.deref(), `${name} roots async output`)

      await promise

      let retained = 2
      for (let attempt = 0; attempt < 12; attempt++) {
        await Bun.sleep(1)
        Bun.gc(true)
        await Bun.sleep(1)
        retained = Number(Boolean(inputRef.deref())) + Number(Boolean(outputRef.deref()))
        if (retained === 0) break
      }
      assert.equal(retained, 0, `${name} clears completed buffer roots`)
    } finally {
      codec.close()
    }
  }

  {
    const codec = factory()
    try {
      const backing = new ArrayBuffer(2048)
      const input = new Uint8Array(backing, 0, 0)
      const output = new Uint8Array(backing, 512, 1024)
      const { promise } = beginNativeWrite(codec, input, output)

      // Input and output may share storage. Two successful pins require two
      // matching unpins; otherwise this transfer remains blocked after callback.
      backing.transfer()
      assert.equal(backing.detached, false, `${name} pins shared backing storage`)
      await promise
      backing.transfer()
      assert.equal(backing.detached, true, `${name} balances shared backing pins`)
    } finally {
      codec.close()
    }
  }
}

console.log('native compression lifetime regressions passed')
