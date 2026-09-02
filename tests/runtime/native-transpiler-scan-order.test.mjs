import assert from 'node:assert/strict'

const transpiler = new Bun.Transpiler({ loader: 'ts' })
const source = `
  export const loader: unknown = 1;
  export const action: unknown = 2;
  export default function route() {}
`

for (let i = 0; i < 128; i++) {
  const result = transpiler.scan(source)
  assert.deepEqual(result.exports, ['action', 'default', 'loader'])
}

console.log('native transpiler scan order passed')
