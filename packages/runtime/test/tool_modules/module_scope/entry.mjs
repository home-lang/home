const cases = [
  ['./const_require.mjs', 42],
  ['./let_bindings.mjs', ['own exports', 'own filename', 'own dirname', 'own module']],
  ['./var_bindings.mjs', [['undefined', 'undefined', 'undefined', 'undefined', 'undefined'], [1, 2, 3, 4, 5]]],
  ['./function_bindings.mjs', [1, 2, 3, 4]],
  ['./async_require.mjs', 43],
  ['./nested_bindings.mjs', [1, 2, 3, 4]],
  ['./generated_bindings.mjs', [11, 12, 13, 14]],
  ['./wrapper.cjs', ['function', 'object', 'object', 'string', 'string', 5, true]],
  ['./var_commonjs.cjs', [['function', 'object', 'string', 'string'], [1, 2, 3, 4]]],
];
let failed = 0;
for (const [specifier, expected] of cases) {
  try {
    const loaded = await import(specifier);
    const actual = specifier.endsWith('.cjs') ? loaded.default.result : loaded.result;
    if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error('Binding values differ: ' + JSON.stringify(actual));
  }
  catch (error) {
    failed++;
    console.error(specifier + ': ' + String(error));
  }
}
if (failed) throw new Error('Actual module binding witnesses failed: ' + failed + '/' + cases.length);
console.log('OK actual ESM binding scopes and preserved CommonJS parameters: 9 modules');
