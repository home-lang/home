import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const directory = mkdtempSync(join(tmpdir(), 'home-napi-bootstrap-safety-'))
const reducedEnv = { ...process.env, NO_COLOR: '1' }
// Any nonempty override, including "0", enables these native paths.
for (const name of ['HOME_NATIVE_VM', 'HOME_CORPUS_FULL_VM', 'HOME_NATIVE_RUN', 'HOME_BUN_TEST_EXECUTABLE']) delete reducedEnv[name]
const nativeEnv = { ...reducedEnv, HOME_NATIVE_VM: '1', HOME_CORPUS_FULL_VM: '1' }
function run(file, env) {
  const child = spawnSync(process.execPath, ['test', file], { env, encoding: 'utf8', timeout: 20000 })
  assert.equal(child.error, undefined)
  assert.equal(child.signal, null, child.stderr)
  return { ...child, output: child.stdout + child.stderr }
}
try {
  const source = join(directory, 'addon.c')
  writeFileSync(source, `
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
typedef struct napi_env__ *napi_env;
typedef struct napi_value__ *napi_value;
extern int napi_create_int32(napi_env, int32_t, napi_value *);
extern int napi_set_named_property(napi_env, napi_value, const char *, napi_value);
static napi_value initialize(napi_env env, napi_value exports) {
  napi_value value;
  if (napi_create_int32(env, 42, &value) != 0) return NULL;
  if (napi_set_named_property(env, exports, "answer", value) != 0) return NULL;
  return exports;
}
__attribute__((constructor)) static void mark_loaded(void) {
  const char *path = getenv("HOME_NAPI_INIT_MARKER");
  if (path) { FILE *file = fopen(path, "w"); if (file) { fputs("loaded", file); fclose(file); } }
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
static struct napi_module module = {1, 0, __FILE__, initialize, "home_safety_addon", NULL, {NULL}};
__attribute__((constructor)) static void register_legacy(void) { napi_module_register(&module); }
#else
int32_t node_api_module_get_api_version_v1(void) { return 8; }
napi_value napi_register_module_v1(napi_env env, napi_value exports) { return initialize(env, exports); }
#endif
`)
  const corpus = join(directory, 'packages/runtime/test/test')
  mkdirSync(corpus, { recursive: true })
  const fixture = join(corpus, 'native-addon-safety.test.js')
  const marker = join(directory, 'constructor-ran')
  for (const legacy of [false, true]) {
    const binary = join(directory, legacy ? 'legacy.node' : 'modern.node')
    const flags = process.platform === 'darwin' ? ['-dynamiclib', '-undefined', 'dynamic_lookup'] : ['-shared', '-fPIC']
    const compiler = spawnSync(process.env.CC || 'cc', [...flags, ...(legacy ? ['-DLEGACY=1'] : []), source, '-o', binary], { encoding: 'utf8', timeout: 15000 })
    assert.equal(compiler.error, undefined)
    assert.equal(compiler.signal, null)
    assert.equal(compiler.status, 0, compiler.stderr)
    for (const mode of ['require', 'cached', 'direct']) {
      writeFileSync(fixture, [
        'const { test, expect } = require("bun:test");',
        mode === 'cached' ? `globalThis.__home_native_node_modules_by_path[${JSON.stringify(binary)}] = { __home_napi_module: true, answer: 42 };` : '',
        'test("native addon requires a real environment", () => {',
        mode === 'direct' ? `  globalThis.__home_loadNativeNodeModule(${JSON.stringify(binary)});` : `  expect(require(${JSON.stringify(binary)}).answer).toBe(42);`,
        '});',
      ].join('\n'))
      const reduced = run(fixture, { ...reducedEnv, HOME_NAPI_INIT_MARKER: marker })
      assert.equal(reduced.status, 1, reduced.output)
      assert.match(reduced.output, /tests passed: 0/)
      assert.match(reduced.output, /tests failed: 0/)
      assert.match(reduced.output, /tests unsupported: 1/)
      assert.match(reduced.output, /Native Node-API addons require the full Home runtime/)
      assert.equal(existsSync(marker), false, 'reduced adapter must reject before addon constructors run')
    }
    writeFileSync(fixture, `const { test, expect } = require("bun:test"); test("native addon initializes", () => expect(require(${JSON.stringify(binary)}).answer).toBe(42));`)
    const native = run(fixture, { ...nativeEnv, HOME_NAPI_INIT_MARKER: marker })
    assert.equal(native.status, 0, native.output)
    assert.match(native.output, /1 pass/)
    assert.match(native.output, /Ran 1 test across 1 file/)
    assert.equal(existsSync(marker), true)
    rmSync(marker)
  }
} finally {
  rmSync(directory, { recursive: true })
}
console.log('native Node-API bootstrap safety regressions passed')
