import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const directory = mkdtempSync(join(tmpdir(), 'home-ffi-cache-test-'))
const cacheRoot = join(directory, 'cache')
mkdirSync(cacheRoot)
const children = []
try {
  const source = join(directory, 'headers.c')
  // Both public include conventions must work without a Node installation.
  writeFileSync(source, `
#include <node/node_api.h>
#include <node_api.h>
napi_value answer(napi_env env) {
  napi_value value;
  if (napi_create_int32(env, 42, &value) != napi_ok) return NULL;
  return value;
}
`)
  const entry = join(directory, 'compile.mjs')
  writeFileSync(entry, `
import assert from 'node:assert/strict';
import { cc } from 'bun:ffi';
const library = cc({ source: ${JSON.stringify(source)}, symbols: { answer: { args: ['napi_env'], returns: 'napi_value' } } });
try { assert.equal(library.symbols.answer(null), 42); } finally { library.close(); }
console.log('compiled');
`)
  const env = { ...process.env, HOME_NATIVE_VM: '1', BUN_TMPDIR: cacheRoot, TMPDIR: cacheRoot }
  delete env.HOME_CORPUS_FULL_VM
  delete env.HOME_NATIVE_RUN
  const runs = Array.from({ length: 4 }, () => new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ['run', entry], { env, stdio: ['ignore', 'pipe', 'pipe'] })
    children.push(child)
    let stdout = ''
    let stderr = ''
    const timer = setTimeout(() => child.kill('SIGKILL'), 15000)
    child.stdout.on('data', chunk => { stdout += chunk })
    child.stderr.on('data', chunk => { stderr += chunk })
    child.on('error', reject)
    child.on('close', (status, signal) => {
      clearTimeout(timer)
      resolve({ status, signal, stdout, stderr })
    })
  }))
  // Await every child before cleaning up, even when one reports a failure.
  const results = await Promise.allSettled(runs)
  for (const result of results) {
    assert.equal(result.status, 'fulfilled', String(result.reason))
    assert.equal(result.value.signal, null, result.value.stderr)
    assert.equal(result.value.status, 0, result.value.stderr)
    assert.equal(result.value.stdout.trim(), 'compiled')
  }
  const caches = readdirSync(cacheRoot).filter(name => name.startsWith('home-cc-'))
  assert.equal(caches.length, 1)
  const cache = join(cacheRoot, caches[0])
  const headers = ['node_api.h', 'node_api_types.h', 'js_native_api.h', 'js_native_api_types.h']
  assert.deepEqual(readdirSync(join(cache, 'node')).sort(), [...headers].sort())
  for (const name of headers) {
    const expected = readFileSync(new URL('../../packages/runtime/src/runtime/napi/' + name, import.meta.url))
    assert.deepEqual(readFileSync(join(cache, name)), expected)
    assert.deepEqual(readFileSync(join(cache, 'node', name)), expected)
  }
  assert.equal(readdirSync(cache).length, 12)
} finally {
  for (const child of children) {
    if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL')
  }
  rmSync(directory, { recursive: true })
}
console.log('native FFI concurrent header-cache regressions passed')
