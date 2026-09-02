import assert from 'node:assert/strict'

const js = new Bun.Transpiler({ loader: 'js' })

assert.equal(js.transformSync('(f(), g()) ? 1 : h();').trim(), 'f(), g() || h();')
assert.equal(js.transformSync('(f(), g()) ? h() : 1;').trim(), 'f(), g() && h();')

const blockExport = '{\n  function encrypt() {}\n}\nexport { encrypt }'
assert.throws(() => js.transformSync(blockExport), /"encrypt" is not declared in this file/)

const ts = new Bun.Transpiler({ loader: 'ts' })
assert.equal(ts.transformSync(blockExport).includes('export { encrypt }'), false)
assert.match(ts.transformSync('function encrypt() {}\nexport { encrypt }'), /export \{ encrypt \}/)
assert.match(ts.transformSync('{ var encrypt = 1 }\nexport { encrypt }'), /export \{ encrypt \}/)

const sloppy = js.transformSync('{ function f() {} }\nmodule.exports = f;')
assert.match(sloppy, /let f = function/)
assert.match(sloppy, /module\.exports = f/)

console.log('native transpiler parser semantics passed')
