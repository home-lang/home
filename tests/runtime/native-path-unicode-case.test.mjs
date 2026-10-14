import assert from 'node:assert/strict'
import fs from 'node:fs'
import { posix, win32 } from 'node:path'

const rows = []
const pairs = [['É', 'é'], ['Ω', 'ω'], ['Я', 'я'], ['İ', 'i\u0307'], ['Σ', 'σ'], ['\u{10400}', '\u{10428}'], ['ẞ', 'ß'], ['ÀĀ', 'àā'], ['ΟΣ', 'ος'], ['ΟΣ', 'οσ'], ['\ud800Σ', '\ud800σ'], ['\udfffİ', '\udfffi\u0307']]
const collect = globalThis.gc || globalThis.Bun?.gc
function record(label, operation) {
  try { rows.push([label, { value: operation() }]) }
  catch (error) { rows.push([label, { error: error.name, code: error.code }]) }
}
for (const [i, [upper, lower]] of pairs.entries()) {
  for (const [j, [from, to]] of [
    [`C:\\${upper}\\file`, `C:\\${lower}\\file`],
    [`C:\\${upper}`, `C:\\${lower}\\Child.TXT`],
    [`C:\\${upper}\\Child.TXT`, `C:\\${lower}`],
    [`C:\\${upper}\\old\\file`, `C:\\${lower}\\New\\${upper}.TXT`],
    [`C:\\root\\${upper}\\a`, `D:\\root\\${lower}\\B`],
    [`\\\\${upper}\\share\\a`, `\\\\${lower}\\share\\B`],
    [`\\\\server\\${upper}\\a`, `\\\\SERVER\\${lower}\\B`],
    [`C:\\${upper}\\`, `C:\\${lower}\\`],
    [`C:\\prefixİ\\${upper}\\A`, `C:\\prefixi\u0307\\${lower}\\B`],
    [`\\\\${upper}\\share`, `\\\\OTHER\\${lower}\\file`],
    [`C:\\${upper}\\foo`, `C:\\${lower}\\foobar`],
  ].entries()) {
    record(`${i}/${j}/windows-relative`, () => win32.relative(from, to))
    record(`${i}/${j}/windows-resolve`, () => win32.resolve(from, to))
    record(`${i}/${j}/posix-relative`, () => posix.relative(from, to))
  }
  record(`${i}/unc-device-resolve`, () => win32.resolve(`\\\\${upper}\\share\\base`, `\\\\${lower}\\share\\Leaf`))
  record(`${i}/unc-validation-boundary`, () => win32.resolve(null, `\\\\${upper}\\share\\Leaf`))
  record(`${i}/unc-namespace`, () => win32.toNamespacedPath(`\\\\${upper}\\share\\${lower}`))
  collect?.()
}
// Different relative outputs force component offsets and original destination
// spelling to participate when lowercase expands either input.
for (const from of ['C:\\İ', 'C:\\İ\\a', 'C:\\i\u0307\\A', '\\\\İ\\share\\a', 'C:\\İ\\ΟΣ']) {
  for (const to of ['C:\\i\u0307\\Child', 'C:\\İ', 'C:\\Otherİ\\Leaf', 'D:\\İ\\Child', '\\\\i\u0307\\share\\B', 'C:\\İ\\ος\\NEW'])
    record(`expanded/${from}/${to}`, () => win32.relative(from, to))
}
const longFrom = 'C:\\' + 'İ\\É\\\ud800\\'.repeat(1800) + 'old'
const longTo = 'C:\\' + 'i\u0307\\é\\\ud800\\'.repeat(1800) + 'NEW'
record('long-expanded-relative', () => win32.relative(longFrom, longTo))
record('long-expanded-parent', () => win32.relative(longFrom, 'C:\\i\u0307'))
const target = process.argv[2]
assert.ok(target, 'supply an independent Node snapshot')
if (process.argv[3] === '--record') fs.writeFileSync(target, JSON.stringify(rows))
else {
  const reference = JSON.parse(fs.readFileSync(target, 'utf8'))
  assert.equal(rows.length, reference.length)
  for (let i = 0; i < rows.length; i++) assert.deepEqual(rows[i], reference[i], rows[i][0])
}
console.log(JSON.stringify({ versions: process.versions, comparisons: rows.length, mode: process.argv[3] === '--record' ? 'record' : 'compare' }))
