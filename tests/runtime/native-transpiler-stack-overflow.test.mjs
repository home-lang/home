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

const nestedTransformScript = String.raw`
  const repeat = (fill, count) => Buffer.alloc(fill.length * count, fill).toString()
  const cases = [
    [{ loader: 'js' }, repeat('- ', 20_000) + '1'],
    [{ loader: 'js' }, repeat('f(', 20_000) + '1' + repeat(')', 20_000)],
    [{ loader: 'js' }, repeat('[', 20_000) + '1' + repeat(']', 20_000)],
    [{ loader: 'js' }, 'f() ? 1 : g()' + repeat(' || g()', 20_000) + ';'],
    [{ loader: 'js' }, 'let ' + repeat('[', 20_000) + 'x' + repeat(']', 20_000) + ' = y;'],
    [
      { loader: 'js', minify: true },
      'function f(){let x=1;return a' + repeat(' && a', 20_000) + ' && x}',
    ],
    [
      { loader: 'tsx', target: 'bun', minifyWhitespace: true, deadCodeElimination: true },
      repeat('{', 990) + 'let x = 1;' + repeat('}', 990),
    ],
  ]

  for (const [options, code] of cases) {
    try {
      new Bun.Transpiler(options).transformSync(code)
    } catch (error) {
      if (!/Maximum call stack size exceeded|StackOverflow/.test(String(error?.message))) throw error
    }
  }

  console.log('nested transforms completed')
`

const nestedTransform = Bun.spawnSync({
  cmd: [process.execPath, '-e', nestedTransformScript],
  stdout: 'pipe',
  stderr: 'pipe',
})

assert.equal(nestedTransform.signalCode, undefined)
assert.equal(nestedTransform.exitCode, 0, nestedTransform.stderr.toString())
assert.equal(nestedTransform.stdout.toString(), 'nested transforms completed\n')

console.log('native transpiler stack overflow recovery passed')
