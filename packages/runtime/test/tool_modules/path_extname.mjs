import path, { extname } from 'node:path';
import alias from 'path';
import posix, { extname as posixExtname } from 'node:path/posix';
import posixAlias from 'path/posix';
import { createRequire } from 'node:module';
const moduleRequire = createRequire(import.meta.url);
const vectors = moduleRequire('./path_extname.expected.json');
if (typeof extname !== 'function') throw new Error('Actual POSIX extname API is absent');
if (path !== alias || posix !== posixAlias || path.posix !== posix || path.extname !== extname || posixExtname !== extname)
  throw new Error('Path extension module identity differs');
if (vectors.cases.length < 500) throw new Error('Path extension oracle inventory is incomplete');
for (const [input, expected] of vectors.cases) {
  const actual = extname(input);
  if (actual !== expected) throw new Error('Actual extension mismatch: ' + JSON.stringify({ input, expected, actual }));
}
for (const item of vectors.errors) {
  let actual;
  try { extname(item.path); }
  catch (error) { actual = { name: error.name, code: error.code }; }
  if (JSON.stringify(actual) !== JSON.stringify(item.error)) throw new Error('Invalid extension input accepted or wrong error');
}
for (const input of [undefined, 0n, Symbol('path'), function() {}, new String('a.txt')]) {
  let rejected = false;
  try { extname(input); }
  catch (error) { rejected = error instanceof TypeError && error.code === 'ERR_INVALID_ARG_TYPE'; }
  if (!rejected) throw new Error('Non-string extension input accepted');
}
let coerced = false;
let coercionRejected = false;
try { extname({ toString() { coerced = true; return 'bad.txt'; } }); }
catch (error) { coercionRejected = error instanceof TypeError && error.code === 'ERR_INVALID_ARG_TYPE'; }
if (!coercionRejected || coerced) throw new Error('Extension input was accepted or coerced');
for (const code of [0xd800, 0xdc00]) {
  const unit = String.fromCharCode(code);
  const result = extname('/dir/file.' + unit + '///');
  if (result.length !== 2 || result.charCodeAt(1) !== code) throw new Error('Extension changed a UTF16 code unit');
}
const originalBasename = path.basename;
try {
  path.basename = function() { throw new Error('Public basename must not be called'); };
  if (extname.call(null, '/dir.ext/actual.js///') !== '.js') throw new Error('Extension depends on receiver or public basename');
}
finally { path.basename = originalBasename; }
console.log('OK actual POSIX extname lexical boundaries, aliases and validation');
