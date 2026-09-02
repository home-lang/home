import assert from 'node:assert/strict'

const fixture = new URL(
  '../../packages/runtime/test/bun-corpus/bundler/transpiler/fixtures/lots-of-for-loop.js',
  import.meta.url,
)
const source = await Bun.file(fixture).text()
const transpiler = new Bun.Transpiler()
const stackOverflow = /Maximum call stack size exceeded/

await assert.rejects(import(fixture.href), stackOverflow)

for (let i = 0; i < 8; i++) {
  assert.throws(() => transpiler.transformSync(source), stackOverflow)
  assert.match(transpiler.transformSync(`export const sync${i} = ${i}`), new RegExp(`sync${i}`))

  await assert.rejects(transpiler.transform(source), stackOverflow)
  assert.match(await transpiler.transform(`export const async${i} = ${i}`), new RegExp(`async${i}`))
}

console.log('native transpiler stack overflow recovery passed')
