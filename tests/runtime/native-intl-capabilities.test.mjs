import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
assert.equal(process.config.variables.v8_enable_i18n_support, 1)
assert.equal(Object.hasOwn(process.config.variables, 'v8_enable_i8n_support'), false)
assert.equal(new Intl.NumberFormat('de-DE').format(1234.5), '1.234,5')
const directory = mkdtempSync(join(tmpdir(), 'home-intl-capabilities-'))
const env = { ...process.env, HOME_NATIVE_VM: '1', HOME_CORPUS_FULL_VM: '1', HOME_NATIVE_RUN: '0', NO_COLOR: '1' }
function run(args) {
  const child = spawnSync(process.execPath, args, { env, encoding: 'utf8', timeout: 15000 })
  assert.equal(child.error, undefined)
  assert.equal(child.signal, null)
  assert.equal(child.status, 0, child.stderr)
  return child
}
try {
  writeFileSync(join(directory, 'check.mjs'), [
    'import assert from "node:assert/strict";',
    'import { domainToASCII, domainToUnicode } from "node:url";',
    'export function check() {',
    '  assert.equal(process.config.variables.v8_enable_i18n_support, 1);',
    '  assert.equal(Object.hasOwn(process.config.variables, "v8_enable_i8n_support"), false);',
    '  assert.equal(typeof process.versions.icu, "string");',
    '  assert.equal(new Intl.NumberFormat("de-DE").format(1234.5), "1.234,5");',
    '  assert.equal(domainToASCII("bücher.de"), "xn--bcher-kva.de");',
    '  assert.equal(domainToUnicode("xn--bcher-kva.de"), "bücher.de");',
    '  return "native-intl-verified";',
    '}',
  ].join('\n'))
  writeFileSync(join(directory, 'worker.mjs'), [
    'import { parentPort } from "node:worker_threads";',
    'import { check } from "./check.mjs";',
    'parentPort.postMessage(check());',
  ].join('\n'))
  const entry = join(directory, 'entry.mjs')
  writeFileSync(entry, [
    'import assert from "node:assert/strict";',
    'import { Worker } from "node:worker_threads";',
    'import { check } from "./check.mjs";',
    'console.log(check());',
    'const worker = new Worker(new URL("./worker.mjs", import.meta.url));',
    'const message = await new Promise((resolve, reject) => {',
    '  worker.once("message", resolve);',
    '  worker.once("error", reject);',
    '  worker.once("exit", code => { if (code) reject(new Error("worker exited " + code)); });',
    '});',
    'assert.equal(message, "native-intl-verified");',
    'await worker.terminate();',
    'console.log(message);',
  ].join('\n'))
  assert.deepEqual(run(['run', entry]).stdout.trim().split('\n'), ['native-intl-verified', 'native-intl-verified'])

  const testFile = join(directory, 'intl.test.mjs')
  writeFileSync(testFile, 'import { test } from "node:test"; import { check } from "./check.mjs"; test("native Intl capability", check);')
  const result = run(['test', testFile])
  assert.match(result.stdout + result.stderr, /1 pass/)
  assert.match(result.stdout + result.stderr, /Ran 1 test across 1 file/)
} finally {
  rmSync(directory, { recursive: true })
}
console.log('native Intl capability regressions passed')
