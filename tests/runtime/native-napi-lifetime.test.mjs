import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'
import { fileURLToPath } from 'node:url'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const directory = mkdtempSync(join(tmpdir(), 'home-napi-lifetime-'))
try {
  const source = join(directory, 'finalizers.c')
  writeFileSync(source, `
#include <node_api.h>
#include <stdio.h>
extern napi_status node_api_post_finalizer(napi_env env, napi_finalize finalize_cb, void *finalize_data, void *finalize_hint);
static napi_ref wrapped_ref;
static void instance_finalizer(napi_env env, void *data, void *hint) { puts("INSTANCE_FINALIZED"); }
static void external_finalizer(napi_env env, void *data, void *hint) { puts("EXTERNAL_FINALIZED"); }
static void cleanup(void *data) { puts("ENV_CLEANED"); }
static void posted_finalizer(napi_env env, void *data, void *hint) {
  puts("POSTED_FINALIZER");
  if (napi_delete_reference(env, wrapped_ref) != napi_ok) puts("DELETE_REF_FAILED");
  wrapped_ref = NULL;
}
static void wrap_finalizer(napi_env env, void *data, void *hint) {
  puts("WRAP_FINALIZED");
  if (node_api_post_finalizer(env, posted_finalizer, NULL, NULL) != napi_ok) puts("POST_FINALIZER_FAILED");
}
napi_value install(napi_env env) {
  napi_value value;
  if (napi_set_instance_data(env, NULL, instance_finalizer, NULL) != napi_ok) return NULL;
  if (napi_add_env_cleanup_hook(env, cleanup, NULL) != napi_ok) return NULL;
  if (napi_create_external(env, NULL, external_finalizer, NULL, &value) != napi_ok) return NULL;
  return value;
}
napi_value install_wrap(napi_env env) {
  napi_value value;
  if (napi_create_object(env, &value) != napi_ok) return NULL;
  if (napi_wrap(env, value, NULL, wrap_finalizer, NULL, &wrapped_ref) != napi_ok) return NULL;
  return value;
}
`)
  const binary = join(directory, 'finalizers.node')
  const flags = process.platform === 'darwin' ? ['-dynamiclib', '-undefined', 'dynamic_lookup'] : ['-shared', '-fPIC']
  const headers = fileURLToPath(new URL('../../packages/runtime/src/runtime/napi/', import.meta.url))
  const compiled = spawnSync(process.env.CC || 'cc', [...flags, '-I', headers, source, '-o', binary], { encoding: 'utf8', timeout: 15000 })
  assert.equal(compiled.error, undefined)
  assert.equal(compiled.status, 0, compiled.stderr)
  const entry = join(directory, 'lifetime.mjs')
  writeFileSync(entry, `
import assert from 'node:assert/strict';
import { cc, dlopen } from 'bun:ffi';
import { Worker, isMainThread, workerData } from 'node:worker_threads';
if (isMainThread && process.argv[2].endsWith('-worker')) {
  const worker = new Worker(import.meta.url, { workerData: process.argv[2].split('-')[0] });
  await new Promise((resolve, reject) => {
    worker.on('error', reject);
    worker.on('exit', code => code === 0 ? resolve() : reject(new Error('worker exit ' + code)));
  });
} else {
  const requestedMode = isMainThread ? process.argv[2] : workerData;
  const mode = requestedMode.split('-')[0];
  const exposeGc = requestedMode.endsWith('-expose-gc');
  const symbols = {
    install: { args: ['napi_env'], returns: 'napi_value' },
    install_wrap: { args: ['napi_env'], returns: 'napi_value' },
  };
  const library = mode === 'cc' ? cc({ source: ${JSON.stringify(source)}, symbols }) : dlopen(${JSON.stringify(binary)}, symbols);
  if (exposeGc) {
    assert.equal(typeof global.gc, 'function');
    let wrapped = library.symbols.install_wrap(null);
    assert.notEqual(wrapped, undefined);
    wrapped = null;
    global.gc();
    await Bun.sleep(0);
    global.gc();
    await Bun.sleep(0);
    console.log('GC_FINISHED');
    library.close();
    library.close();
  } else {
    globalThis.retainedExternal = library.symbols.install(null);
    globalThis.retainedWrapped = library.symbols.install_wrap(null);
    assert.notEqual(globalThis.retainedExternal, undefined);
    assert.notEqual(globalThis.retainedWrapped, undefined);
    library.close();
    library.close();
    Bun.gc(true);
    console.log('CLOSED');
  }
}
`)
  // Main-thread teardown is opt-in; workers always destroy their JSC heap.
  // Keep the external reachable until that final GC pass, after env cleanup.
  const env = { ...process.env, HOME_NATIVE_VM: '1', BUN_DESTRUCT_VM_ON_EXIT: '1' }
  delete env.HOME_CORPUS_FULL_VM
  delete env.HOME_NATIVE_RUN
  for (const mode of ['cc-worker', 'dlopen-worker', 'cc', 'dlopen']) {
    const child = spawnSync(process.execPath, ['run', entry, mode], { env, encoding: 'utf8', timeout: 15000 })
    assert.equal(child.error, undefined, mode)
    assert.equal(child.signal, null, mode + '\n' + child.stderr)
    assert.equal(child.status, 0, mode + '\n' + child.stderr)
    assert.equal(child.stderr, '', mode)
    const lines = child.stdout.trim().split(/\r?\n/)
    assert.equal(lines[0], 'CLOSED', mode)
    assert.deepEqual(
      lines.slice(1).sort(),
      ['ENV_CLEANED', 'EXTERNAL_FINALIZED', 'INSTANCE_FINALIZED', 'POSTED_FINALIZER', 'WRAP_FINALIZED'],
      mode,
    )
  }
  for (const mode of ['cc-expose-gc', 'dlopen-expose-gc']) {
    const child = spawnSync(process.execPath, ['--expose-gc', 'run', entry, mode], { env, encoding: 'utf8', timeout: 15000 })
    assert.equal(child.error, undefined, mode)
    assert.equal(child.signal, null, mode + '\n' + child.stderr)
    assert.equal(child.status, 0, mode + '\n' + child.stderr)
    assert.equal(child.stderr, '', mode)
    const lines = child.stdout.trim().split(/\r?\n/)
    assert.ok(lines.indexOf('WRAP_FINALIZED') < lines.indexOf('GC_FINISHED'), mode)
    assert.ok(lines.indexOf('POSTED_FINALIZER') < lines.indexOf('GC_FINISHED'), mode)
  }
} finally {
  rmSync(directory, { recursive: true })
}
console.log('native Node-API FFI lifetime regressions passed')
