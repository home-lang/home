import assert from 'node:assert/strict'
import fs from 'node:fs'
import { posix, win32 } from 'node:path'

const rows = []
const collect = globalThis.gc || globalThis.Bun?.gc
function record(label, operation) {
  try {
    const result = operation()
    const value = result === undefined ? { kind: 'undefined' } : typeof result === 'symbol' ? { kind: 'symbol', description: result.description } : typeof result === 'bigint' ? { kind: 'bigint', decimal: String(result) } : typeof result === 'number' && !Number.isFinite(result) ? { kind: 'number', decimal: String(result) } : result
    rows.push([label, { value }])
  } catch (error) { rows.push([label, { thrown: typeof error, name: error?.name, code: error?.code, message: typeof error === 'object' ? undefined : String(error) }]) }
}
const primitives = ['', 'txt', '.txt', '\ud800', '\udfff', '😀', '.', 0, 1, false, true, null, undefined, 0n, 12n, -0, NaN, Infinity, Symbol('field')]
const objects = [
  () => ({ 0: '.', toString() { return 'txt' } }),
  () => ({ toString() { return '.txt' } }),
  () => ({ toString() { return '' } }),
  () => new String('.txt'),
  () => new String(''),
  () => ({ 0: { toString() { throw new Error('index must not coerce') } }, toString() { return 'txt' } }),
  () => ['.'],
  () => [],
]
for (const [platform, api] of [['posix', posix], ['win32', win32]]) {
  for (const [i, value] of primitives.entries()) {
    for (const field of ['dir', 'root', 'base', 'name', 'ext'])
      record(`${platform}/primitive/${field}/${i}`, () => api.format({ dir: '/root', name: 'file', [field]: value }))
    record(`${platform}/base-identity/${i}`, () => api.format({ base: value }))
  }
  for (const [i, factory] of objects.entries()) {
    for (const field of ['dir', 'root', 'base', 'name', 'ext'])
      record(`${platform}/object/${field}/${i}`, () => api.format({ dir: '/root', name: 'file', [field]: factory() }))
    record(`${platform}/same-root/${i}`, () => { const value = factory(); return api.format({ dir: value, root: value, name: 'file', ext: factory() }) })
    record(`${platform}/base-direct/${i}`, () => { const value = factory(); return { same: api.format({ base: value }) === value } })
  }
  record(`${platform}/event-order`, () => {
    const events = []
    const value = label => ({ get 0() { collect?.(); events.push(label + '.0'); return '.' }, [Symbol.toPrimitive](hint) { collect?.(); events.push(label + ':' + hint); return label === 'ext' ? 'txt' : label } })
    const object = {}
    for (const key of ['dir', 'root', 'base', 'name', 'ext']) Object.defineProperty(object, key, { get() { collect?.(); events.push(key); return key === 'base' ? '' : value(key) } })
    return { output: api.format(object), events }
  })
  for (const thrown of [new Error('index'), 'index sentinel', 42])
    record(`${platform}/index-throws/${String(thrown)}`, () => api.format({ name: 'file', ext: { get 0() { throw thrown }, toString() { throw new Error('must not coerce after index throws') } } }))
  record(`${platform}/coercion-mutates-root`, () => {
    const object = { dir: '/original', root: '/original', name: { toString() { object.root = '/different'; return '\ud800' } }, ext: '.txt' }
    return api.format(object)
  })
  record(`${platform}/base-short-circuits`, () => api.format({ dir: '/root', base: { toString() { return '' } }, get name() { throw new Error('must not read name') }, get ext() { throw new Error('must not read ext') } }))
  record(`${platform}/fresh-index-gc`, () => api.format({ dir: { toString() { collect?.(); return '' } }, name: '\ud800', ext: { get 0() { collect?.(); return new String('.') }, toString() { collect?.(); return '' } } }))
  record(`${platform}/symbol-prototype-index`, () => {
    const descriptor = Object.getOwnPropertyDescriptor(Symbol.prototype, '0')
    Object.defineProperty(Symbol.prototype, '0', { configurable: true, get() { throw 'symbol index sentinel' } })
    try { return api.format({ name: 'file', ext: Symbol('ext') }) }
    finally { if (descriptor) Object.defineProperty(Symbol.prototype, '0', descriptor); else delete Symbol.prototype[0] }
  })
  record(`${platform}/long-coercions`, () => api.format({ dir: '\ud800/'.repeat(3000), name: 'n'.repeat(12000), ext: { 0: '.', toString() { return '\udfff'.repeat(12000) } } }))
}
const target = process.argv[2]
assert.ok(target, 'supply a Node snapshot')
if (process.argv[3] === '--record') fs.writeFileSync(target, JSON.stringify(rows))
else {
  const reference = JSON.parse(fs.readFileSync(target, 'utf8'))
  // JSON omits undefined error metadata consistently for both runtimes.
  const actual = JSON.parse(JSON.stringify(rows))
  assert.equal(actual.length, reference.length)
  for (let i = 0; i < actual.length; i++) assert.deepEqual(actual[i], reference[i], actual[i][0])
}
console.log(JSON.stringify({ versions: process.versions, comparisons: rows.length, mode: process.argv[3] === '--record' ? 'record' : 'compare' }))
