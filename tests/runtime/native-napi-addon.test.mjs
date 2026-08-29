import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const require = createRequire(import.meta.url)
const directory = mkdtempSync(join(tmpdir(), 'home-native-addon-'))
try {
  const source = join(directory, 'addon.c')
  // The stable public Node-API declarations used here, kept self-contained so
  // this regression needs a C compiler but never downloads node-gyp/headers.
  writeFileSync(source, `
#include <stddef.h>
#include <stdint.h>
typedef struct napi_env__ *napi_env;
typedef struct napi_value__ *napi_value;
typedef struct napi_callback_info__ *napi_callback_info;
typedef int napi_status;
typedef napi_value (*napi_callback)(napi_env, napi_callback_info);
extern napi_status napi_create_function(napi_env, const char *, size_t, napi_callback, void *, napi_value *);
extern napi_status napi_get_cb_info(napi_env, napi_callback_info, size_t *, napi_value *, napi_value *, void **);
extern napi_status napi_create_int32(napi_env, int32_t, napi_value *);
extern napi_status napi_get_value_int32(napi_env, napi_value, int32_t *);
extern napi_status napi_set_named_property(napi_env, napi_value, const char *, napi_value);
extern napi_status napi_throw_error(napi_env, const char *, const char *);
static napi_value add(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value argv[2], result;
  void *data;
  if (napi_get_cb_info(env, info, &argc, argv, NULL, &data) != 0) return NULL;
  int32_t total = (int32_t)(intptr_t)data;
  for (size_t i = 0; i < argc; i++) {
    int32_t value;
    if (napi_get_value_int32(env, argv[i], &value) != 0) return NULL;
    total += value;
  }
  if (napi_create_int32(env, total, &result) != 0) return NULL;
  return result;
}
static napi_value fail(napi_env env, napi_callback_info info) {
  (void)info;
  napi_throw_error(env, "ERR_HOME_NATIVE_ADDON", "native addon sentinel");
  return NULL;
}
static napi_value initialize(napi_env env, napi_value exports) {
  napi_value function;
  if (napi_create_function(env, "add", (size_t)-1, add, (void *)(intptr_t)40, &function) != 0) return NULL;
  if (napi_set_named_property(env, exports, "add", function) != 0) return NULL;
  if (napi_create_function(env, "fail", (size_t)-1, fail, NULL, &function) != 0) return NULL;
  if (napi_set_named_property(env, exports, "fail", function) != 0) return NULL;
  return exports;
}
#ifdef LEGACY
struct napi_module {
  int nm_version;
  unsigned int nm_flags;
  const char *nm_filename;
  napi_value (*nm_register_func)(napi_env, napi_value);
  const char *nm_modname;
  void *nm_priv;
  void *reserved[4];
};
extern void napi_module_register(struct napi_module *);
static struct napi_module module = {1, 0, __FILE__, initialize, "home_native_addon", NULL, {NULL}};
__attribute__((constructor)) static void register_legacy(void) { napi_module_register(&module); }
#else
int32_t node_api_module_get_api_version_v1(void) { return 8; }
napi_value napi_register_module_v1(napi_env env, napi_value exports) { return initialize(env, exports); }
#endif
`)
  for (const legacy of [false, true]) {
    const binary = join(directory, legacy ? 'legacy.node' : 'modern.node')
    const flags = process.platform === 'darwin' ? ['-dynamiclib', '-undefined', 'dynamic_lookup'] : ['-shared', '-fPIC']
    const child = spawnSync(process.env.CC || 'cc', [...flags, ...(legacy ? ['-DLEGACY=1'] : []), source, '-o', binary], { encoding: 'utf8', timeout: 15000 })
    assert.equal(child.error, undefined)
    assert.equal(child.status, 0, child.stderr)
    assert.equal(child.signal, null)
    const addon = require(binary)
    assert.equal(addon.add(1, 2), 43)
    assert.equal(addon.add(), 40)
    assert.throws(() => addon.fail(), { code: 'ERR_HOME_NATIVE_ADDON', message: 'native addon sentinel' })
    Bun.gc(true)
    assert.equal(addon.add(2, 3), 45)
  }
} finally {
  rmSync(directory, { recursive: true })
}
console.log('native Node-API addon regressions passed')
