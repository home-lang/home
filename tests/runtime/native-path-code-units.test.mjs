import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'

// Record Node's public results without involving filesystem path encoding.
// The same operations run under Home; JSON retains unpaired UTF-16 surrogates.
const rows = []
const collect = globalThis.gc || globalThis.Bun?.gc
function record(label, operation) {
  try {
    const result = operation()
    const value = result === undefined ? { kind: 'undefined' } : typeof result === 'symbol' ? { kind: 'symbol', description: result.description } : result
    rows.push([label, { value }])
  }
  catch (error) { rows.push([label, { error: error.name, code: error.code }]) }
}
const components = ['a\ud861b', 'a\udfffz', '\ud800\udc00', '\ud800\ud800', '\udc00\udc00', 'é', 'Ω', '😀', 'A\ud800.\udfff', 'a\0b', '', '.', '..']
for (const [platform, api] of [['posix', path.posix], ['win32', path.win32]]) {
  for (const [i, component] of components.entries()) {
    const prefix = platform === 'posix' ? '/root/' : 'C:\\root\\'
    const inputs = [component, prefix + component, prefix + component + '/file.' + component, '//server/' + component + '/share/../' + component, component + '/./../' + component + '/']
    for (const [j, input] of inputs.entries()) {
      for (const method of ['basename', 'dirname', 'extname', 'normalize', 'parse', 'resolve', 'isAbsolute', 'toNamespacedPath'])
        record(`${platform}/${i}/${j}/${method}`, () => api[method](input))
      record(`${platform}/${i}/${j}/roundtrip`, () => api.format(api.parse(input)))
      for (const [k, suffix] of ['', 'b', component, '\udfff', 'é'].entries())
        record(`${platform}/${i}/${j}/suffix/${k}`, () => api.basename(input, suffix))
      record(`${platform}/${i}/${j}/join`, () => api.join(prefix, input, 'é', component))
      record(`${platform}/${i}/${j}/relative`, () => api.relative(prefix + component, prefix + component + '/x.' + component))
      record(`${platform}/${i}/${j}/different-relative`, () => api.relative(prefix + component, prefix + 'é/' + component))
      record(`${platform}/${i}/${j}/resolve-mixed`, () => api.resolve('é', input, component))
    }
    for (const [j, object] of [
      { root: 'C:\\', dir: component, base: 'é' },
      { root: component, name: 'é', ext: component },
      { dir: '/é', name: component, ext: 'ext' },
      { dir: component, base: component, name: 'unused', ext: 'unused' },
    ].entries()) record(`${platform}/${i}/format/${j}`, () => api.format(object))
  }
  for (const method of ['basename', 'dirname', 'extname', 'normalize', 'parse', 'resolve', 'join', 'relative', 'isAbsolute', 'toNamespacedPath']) {
    for (const [i, value] of [undefined, null, 0, {}, [], Symbol('path')].entries())
      record(`${platform}/invalid/${method}/${i}`, () => api[method](value, '\ud800'))
  }
  record(`${platform}/format-getters`, () => {
    const reads = []
    const object = Object.fromEntries(['root', 'dir', 'base', 'name', 'ext'].map(key => [key, '']))
    for (const key of Object.keys(object)) Object.defineProperty(object, key, { get() { collect?.(); reads.push(key); return key === 'dir' ? '/\ud800' : key === 'name' ? '\udfff' : '' } })
    return { output: api.format(object), reads }
  })
  record(`${platform}/resolve-validation-short-circuit`, () => api.resolve(null, platform === 'posix' ? '/\ud800' : 'C:\\\ud800'))
  if (platform === 'win32') {
    for (const [i, args] of [
      [null, 'C:\\a\ud800'], [null, 'C:drive', '\\absolute\udfff'],
      [null, 'D:\\ignored', 'C:drive', '\\absolute\udfff'],
      [null, '//server/share/\ud800'], [null, 'C:drive', 'D:\\absolute\udfff'],
      [null, '\\rooted'], [null, 'relative\ud800'],
    ].entries()) record(`${platform}/resolve-read-boundary/${i}`, () => api.resolve(...args))
  }
  record(`${platform}/format-short-circuit`, () => {
    const reads = []
    const object = { get dir() { reads.push('dir'); return '/\ud800' }, get root() { reads.push('root'); return '/' }, get base() { reads.push('base'); return '\udfff' }, get name() { throw new Error('unread name') }, get ext() { throw new Error('unread ext') } }
    return { output: api.format(object), reads }
  })
  record(`${platform}/format-changing-root`, () => {
    let count = 0
    return api.format({ get root() { count++; return count === 1 ? '/\ud800' : '/' }, base: '\udfff' })
  })
  for (const [i, object] of [{ base: 12 }, { dir: '/x', base: 12 }, { root: '/x', name: 12, ext: '.txt' }, { dir: '/x', base: { toString() { return '\ud800' } } }].entries())
    record(`${platform}/format-coercion/${i}`, () => api.format(object))
  record(`${platform}/parse-retained-gc`, () => {
    const retained = []
    for (let i = 0; i < 64; i++) retained.push(api.parse(`/root/\ud800${i}/file.\udfff`))
    collect?.()
    return retained
  })
  const long = 'a/\ud800/'.repeat(3000) + 'file.\udfff'
  for (const method of ['join', 'normalize', 'resolve', 'parse', 'toNamespacedPath'])
    record(`${platform}/long/${method}`, () => api[method](long))
  record(`${platform}/long/relative`, () => api.relative(long, '/\ud800'))
}
const target = process.argv[2]
assert.ok(target, 'supply a Node snapshot path')
if (process.argv[3] === '--record') fs.writeFileSync(target, JSON.stringify(rows))
else {
  const reference = JSON.parse(fs.readFileSync(target, 'utf8'))
  assert.equal(rows.length, reference.length)
  for (let i = 0; i < rows.length; i++) assert.deepEqual(rows[i], reference[i], rows[i][0])
}
console.log(JSON.stringify({ runtime: process.versions, comparisons: rows.length, mode: process.argv[3] === '--record' ? 'record' : 'compare' }))
