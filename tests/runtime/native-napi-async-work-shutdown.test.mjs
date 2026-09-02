import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { Worker } from 'node:worker_threads'
import { getEventLoopStats } from 'bun:internal-for-testing'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const directory = mkdtempSync(join(tmpdir(), 'home-napi-async-shutdown-'))
try {
  const source = join(directory, 'async-shutdown.c')
  writeFileSync(source, `
#include <node_api.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#ifdef _WIN32
#include <windows.h>
#define SLEEP_MS(ms) Sleep(ms)
#else
#include <unistd.h>
#define SLEEP_MS(ms) usleep((ms) * 1000)
#endif

static _Atomic int blockers_executed = 0;
static _Atomic int blockers_completed = 0;
static _Atomic int target_executed = 0;
static _Atomic int target_completed = 0;
static _Atomic int target_status = -1;
static _Atomic int target_js_status = -1;

struct work_data {
  napi_async_work work;
  napi_ref callback;
  int target;
};

static void execute(napi_env env, void *opaque) {
  (void)env;
  struct work_data *data = opaque;
  if (data->target) {
    atomic_fetch_add(&target_executed, 1);
    SLEEP_MS(10);
  } else {
    atomic_fetch_add(&blockers_executed, 1);
    SLEEP_MS(150);
  }
}

static void complete(napi_env env, napi_status status, void *opaque) {
  struct work_data *data = opaque;
  if (data->target) {
    atomic_store(&target_status, status);
    atomic_fetch_add(&target_completed, 1);
    napi_value callback;
    napi_value undefined;
    napi_status js_status = napi_get_reference_value(env, data->callback, &callback);
    if (js_status == napi_ok) js_status = napi_get_undefined(env, &undefined);
    if (js_status == napi_ok) js_status = napi_call_function(env, undefined, callback, 0, NULL, NULL);
    atomic_store(&target_js_status, js_status);
    napi_delete_reference(env, data->callback);
  } else {
    atomic_fetch_add(&blockers_completed, 1);
  }
  napi_delete_async_work(env, data->work);
  free(data);
}

static int queue_one(napi_env env, napi_value name, napi_value callback, int target) {
  struct work_data *data = calloc(1, sizeof(*data));
  if (data == NULL) return 0;
  data->target = target;
  if (target && napi_create_reference(env, callback, 1, &data->callback) != napi_ok) return 0;
  if (napi_create_async_work(env, NULL, name, execute, complete, data, &data->work) != napi_ok) return 0;
  if (napi_queue_async_work(env, data->work) != napi_ok) return 0;
  return 1;
}

static napi_value start(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2];
  napi_value name;
  int32_t blockers;
  if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc != 2) return NULL;
  if (napi_get_value_int32(env, argv[0], &blockers) != napi_ok) return NULL;
  if (napi_create_string_utf8(env, "shutdown-probe", NAPI_AUTO_LENGTH, &name) != napi_ok) return NULL;
  for (int32_t i = 0; i < blockers; i++) if (!queue_one(env, name, NULL, 0)) return NULL;
  if (!queue_one(env, name, argv[1], 1)) return NULL;
  return NULL;
}

static napi_value snapshot(napi_env env, napi_callback_info info) {
  (void)info;
  int values[6] = {
    atomic_load(&blockers_executed),
    atomic_load(&blockers_completed),
    atomic_load(&target_executed),
    atomic_load(&target_completed),
    atomic_load(&target_status),
    atomic_load(&target_js_status),
  };
  napi_value array;
  napi_value value;
  napi_create_array_with_length(env, 6, &array);
  for (uint32_t i = 0; i < 6; i++) {
    napi_create_int32(env, values[i], &value);
    napi_set_element(env, array, i, value);
  }
  return array;
}

static napi_value initialize(napi_env env, napi_value exports) {
  napi_value function;
  if (napi_create_function(env, "start", NAPI_AUTO_LENGTH, start, NULL, &function) != napi_ok) return NULL;
  if (napi_set_named_property(env, exports, "start", function) != napi_ok) return NULL;
  if (napi_create_function(env, "snapshot", NAPI_AUTO_LENGTH, snapshot, NULL, &function) != napi_ok) return NULL;
  if (napi_set_named_property(env, exports, "snapshot", function) != napi_ok) return NULL;
  return exports;
}

int32_t node_api_module_get_api_version_v1(void) { return 8; }
napi_value napi_register_module_v1(napi_env env, napi_value exports) { return initialize(env, exports); }
`)

  const binary = join(directory, 'async-shutdown.node')
  const flags = process.platform === 'darwin' ? ['-dynamiclib', '-undefined', 'dynamic_lookup'] : ['-shared', '-fPIC']
  const headers = fileURLToPath(new URL('../../packages/runtime/src/runtime/napi/', import.meta.url))
  const compiled = spawnSync(process.env.CC || 'cc', [...flags, '-std=c11', '-I', headers, source, '-o', binary], {
    encoding: 'utf8',
    timeout: 15_000,
  })
  assert.equal(compiled.error, undefined)
  assert.equal(compiled.signal, null)
  assert.equal(compiled.status, 0, compiled.stderr)

  const require = createRequire(import.meta.url)
  const addon = require(binary)
  const before = getEventLoopStats()
  const poolThreads = before.nativeWorkPoolThreads
  assert.ok(poolThreads > 0)

  let jsCompletions = 0
  const worker = new Worker(`
    const { parentPort, workerData } = require('node:worker_threads');
    const addon = require(workerData.binary);
    addon.start(workerData.poolThreads, () => parentPort.postMessage('JS_COMPLETE'));
    parentPort.postMessage('QUEUED');
    for (;;) {}
  `, { eval: true, workerData: { binary, poolThreads } })
  worker.on('message', message => {
    if (message === 'JS_COMPLETE') jsCompletions++
  })

  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('worker queue timeout')), 5_000)
    worker.on('error', reject)
    worker.on('message', message => {
      if (message === 'QUEUED') {
        clearTimeout(timeout)
        resolve()
      }
    })
  })

  const deadline = Date.now() + 5_000
  while (addon.snapshot()[0] !== poolThreads) {
    if (Date.now() >= deadline) throw new Error('native pool saturation timeout')
    await new Promise(resolve => setTimeout(resolve, 5))
  }

  assert.equal(await worker.terminate(), 1)
  assert.deepEqual(addon.snapshot(), [poolThreads, poolThreads, 1, 1, 0, 10])
  assert.equal(jsCompletions, 0)

  const after = getEventLoopStats()
  assert.equal(after.nativeWorkPoolJobs, 0)
  assert.equal(after.cancelledNapiAsyncWork - before.cancelledNapiAsyncWork, poolThreads + 1)
} finally {
  rmSync(directory, { recursive: true })
}

console.log('native Node-API async work shutdown ownership passed')
