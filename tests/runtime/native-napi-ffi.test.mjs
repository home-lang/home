import assert from 'node:assert/strict'
import { cc } from 'bun:ffi'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const directory = mkdtempSync(join(tmpdir(), 'home-native-napi-'))
const libraries = []
try {
  const source = join(directory, 'napi.c')
  writeFileSync(source, `
#include <node/node_api.h>
#include <stdint.h>

napi_value greeting(napi_env env) {
  napi_value value;
  if (napi_create_string_utf8(env, "Hello, Napi!", NAPI_AUTO_LENGTH, &value) != napi_ok) return NULL;
  return value;
}
int set_data(napi_env env, int value) {
  return napi_set_instance_data(env, (void *)(intptr_t)value, NULL, NULL);
}
int get_data(napi_env env) {
  void *value = NULL;
  if (napi_get_instance_data(env, &value) != napi_ok) return -1;
  return (int)(intptr_t)value;
}
int type_of(napi_env env, napi_value value) {
  napi_valuetype type;
  return napi_typeof(env, value, &type) == napi_ok ? (int)type : -1;
}
napi_value object(napi_env env) {
  napi_value result, value;
  if (napi_create_object(env, &result) != napi_ok) return NULL;
  if (napi_create_int32(env, 42, &value) != napi_ok) return NULL;
  if (napi_set_named_property(env, result, "answer", value) != napi_ok) return NULL;
  return result;
}
int error_state(napi_env env, napi_value value) {
  int32_t number;
  napi_status status = napi_get_value_int32(env, value, &number);
  const napi_extended_error_info *info;
  if (napi_get_last_error_info(env, &info) != napi_ok || info->error_code != status) return -1;
  if (status != napi_number_expected) return -2;
  napi_value created;
  if (napi_create_int32(env, 123, &created) != napi_ok) return -3;
  if (napi_get_last_error_info(env, &info) != napi_ok) return -4;
  return info->error_code;
}
int wide_string_length(napi_env env, napi_value value) {
  char16_t buffer[32];
  size_t length = 0;
  if (napi_get_value_string_utf16(env, value, buffer, NAPI_AUTO_LENGTH, &length) != napi_ok) return -1;
  if (buffer[length] != 0) return -2;
  return (int)length;
}
int null_env_validation(void) {
  napi_value value;
  bool boolean;
  void *external;
  if (napi_create_object(NULL, &value) != napi_invalid_arg) return 1;
  if (napi_create_function(NULL, "fn", NAPI_AUTO_LENGTH, NULL, NULL, &value) != napi_invalid_arg) return 2;
  if (napi_create_external(NULL, NULL, NULL, NULL, &value) != napi_invalid_arg) return 3;
  if (napi_get_cb_info(NULL, NULL, NULL, NULL, NULL, NULL) != napi_invalid_arg) return 4;
  if (napi_get_value_bool(NULL, NULL, &boolean) != napi_invalid_arg) return 5;
  if (napi_get_value_external(NULL, NULL, &external) != napi_invalid_arg) return 6;
  if (napi_set_named_property(NULL, NULL, "value", NULL) != napi_invalid_arg) return 7;
  if (napi_throw_error(NULL, "ERR_TEST", "null env") != napi_invalid_arg) return 8;
  return 0;
}
`)
  const symbols = {
    greeting: { args: ['napi_env'], returns: 'napi_value' },
    set_data: { args: ['napi_env', 'int'], returns: 'int' },
    get_data: { args: ['napi_env'], returns: 'int' },
    type_of: { args: ['napi_env', 'napi_value'], returns: 'int' },
    object: { args: ['napi_env'], returns: 'napi_value' },
    error_state: { args: ['napi_env', 'napi_value'], returns: 'int' },
    wide_string_length: { args: ['napi_env', 'napi_value'], returns: 'int' },
    null_env_validation: { args: [], returns: 'int' },
  }
  for (let i = 0; i < 2; i++) libraries.push(cc({ source, symbols }))
  const [first, second] = libraries.map(library => library.symbols)
  assert.equal(first.greeting(null), 'Hello, Napi!')
  assert.deepEqual(first.object(null), { answer: 42 })
  assert.equal(first.set_data(null, 17), 0)
  assert.equal(second.set_data(null, 29), 0)
  assert.equal(first.get_data(null), 17)
  assert.equal(second.get_data(null), 29)
  for (const [value, type] of [[undefined, 0], [null, 1], [true, 2], [123, 3], ['hello', 4], [Symbol('key'), 5], [{}, 6], [() => {}, 7], [190n, 9]]) {
    assert.equal(first.type_of(null, value), type)
  }
  assert.equal(first.error_state(null, 'not a number'), 0)
  assert.equal(first.null_env_validation(), 0)
  assert.equal(first.wide_string_length(null, 'hello'), 5)
  assert.equal(first.wide_string_length(null, '🌍'), 2)
  Bun.gc(true)
  assert.equal(first.greeting(null), 'Hello, Napi!')
  assert.deepEqual(first.object(null), { answer: 42 })
} finally {
  for (const library of libraries) library.close()
  rmSync(directory, { recursive: true })
}
console.log('native Node-API FFI regressions passed')
