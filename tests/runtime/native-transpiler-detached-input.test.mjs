import assert from 'node:assert/strict'

const transpiler = new Bun.Transpiler({ loader: 'js' })
const size = 1 << 20
const original = 'export const original = 12345;'

for (let run = 0; run < 16; run++) {
  const bytes = new Uint8Array(size).fill(0x20)
  new TextEncoder().encodeInto(original, bytes)
  const expected = transpiler.transformSync(new TextDecoder().decode(bytes), 'js')

  const promise = transpiler.transform(bytes, 'js')
  bytes.buffer.transfer(0)

  const decoys = []
  for (let i = 0; i < 8; i++) {
    const decoy = new Uint8Array(size).fill(0x20)
    new TextEncoder().encodeInto(`export const replaced${run}_${i} = ${i};`, decoy)
    decoys.push(decoy)
  }

  const output = await promise
  assert.equal(output, expected)
  assert.doesNotMatch(output, /replaced/)
  assert.equal(bytes.byteLength, 0)
  assert.equal(decoys.length, 8)
}

console.log('native transpiler detached input passed')
