import assert from 'node:assert/strict'

const transpiler = new Bun.Transpiler({
  loader: 'js',
  target: 'node',
  minifyWhitespace: true,
})

const siblingSwitches = `
  switch (a()) { case 0: using x = { [s]() {} }; }
  switch (b()) { case 1: using y = { [t]() {} }; }
`
const lowered = transpiler.transformSync(siblingSwitches)
assert.doesNotThrow(() => new Bun.Transpiler({ loader: 'js' }).transformSync(lowered))
assert.equal(lowered.match(/finally/g)?.length, 2)

const bindings = Buffer.alloc(420, 'a,').toString()
const statement = `try {} catch ([${bindings}a]) {}\n`
const flood = Buffer.alloc(statement.length * 400, statement).toString()

let parseError
try {
  transpiler.transformSync(flood)
} catch (error) {
  parseError = error
}

assert.equal(parseError?.name, 'AggregateError')
assert.equal(parseError.errors.some(error => String(error.message).includes('has already been declared')), true)

console.log('native transpiler using and diagnostics passed')
