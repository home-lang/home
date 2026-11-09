import fs from 'node:fs';
import alias from 'fs';
import util from 'node:util';
import utilAlias from 'util';
function check(value, message) { if (!value) throw new Error(message); }
const root = process.argv[2];
const cases = JSON.parse(process.argv[3]);
const { promisify } = util;
check(util === utilAlias && fs === alias, 'module aliases');
check(typeof promisify === 'function' && promisify.custom === Symbol.for('nodejs.util.promisify.custom'), 'public custom symbol');
function add(a, b, callback) { callback(null, this.offset + a + b, 'ignored'); }
const marker = Symbol('descriptor');
Object.defineProperty(add, marker, { value: 41, enumerable: false, configurable: true });
let reads = 0;
Object.defineProperty(add, 'extra', { get() { reads++; return 42; }, configurable: true });
const wrapped = promisify(add);
check(wrapped.name === add.name && wrapped.length === add.length && wrapped[marker] === 41 && reads === 0, 'function descriptors copied without getters');
check(wrapped.extra === 42 && reads === 1 && Object.getPrototypeOf(wrapped) === Object.getPrototypeOf(add), 'getter and function prototype');
check(await wrapped.call({ offset: 10 }, 3, 4) === 17, 'receiver, argument order, first success value');
check(promisify(wrapped) === wrapped, 'wrapper idempotence');
const descriptor = Object.getOwnPropertyDescriptor(wrapped, promisify.custom);
check(descriptor.value === wrapped && !descriptor.enumerable && !descriptor.writable && descriptor.configurable, 'wrapper custom descriptor');
const sentinel = new Error('sentinel');
for (const original of [function(cb) { cb(sentinel); }, function() { throw sentinel; }]) {
  let caught;
  try { await promisify(original)(); } catch (error) { caught = error; }
  check(caught === sentinel, 'callback and synchronous throw rejection identity');
}
for (const error of [null, undefined, false, 0, '']) check(await promisify(function(cb) { cb(error, 7); })() === 7, 'falsy callback error');
check(await promisify(function(cb) { cb(null, 8); cb(sentinel); throw sentinel; })() === 8, 'first settlement');
check(await promisify(function(cb) { cb(null); })() === undefined, 'no success value');
function original() { throw new Error('custom original must not run'); }
function custom(value) { return Promise.resolve(value + 1); }
original[promisify.custom] = custom;
check(promisify(original) === custom && promisify(custom) === custom && await promisify(original)(8) === 9, 'custom identity and execution');
for (const invalid of [undefined, null, 1, {}, 'function']) {
  let error;
  try { promisify(invalid); } catch (caught) { error = caught; }
  check(error instanceof TypeError && error.code === 'ERR_INVALID_ARG_TYPE', 'invalid original');
}
original[promisify.custom] = 42;
let customError;
try { promisify(original); } catch (error) { customError = error; }
check(customError instanceof TypeError && customError.code === 'ERR_INVALID_ARG_TYPE', 'invalid custom');
function callbackStat(method, path, options) {
  return new Promise(function(resolve, reject) {
    let synchronous = true;
    const returned = method(path, options, function(error, result) {
      try {
        check(!synchronous, 'callback is asynchronous');
        check(arguments.length === (error ? 1 : 2), 'error-first callback arity');
        resolve({ error, result });
      } catch (failure) { reject(failure); }
    });
    check(returned === undefined, 'callback stat returns undefined');
    synchronous = false;
  });
}
function metadata(info, expected) {
  check(info && !(info instanceof Promise), 'actual metadata object');
  for (const [method, kind] of [['isFile', 'file'], ['isDirectory', 'directory'], ['isSymbolicLink', 'sym_link'], ['isBlockDevice', 'block_device'], ['isCharacterDevice', 'character_device'], ['isFIFO', 'named_pipe'], ['isSocket', 'unix_domain_socket']]) check(info[method]() === (kind === expected.kind), 'native kind ' + method);
  for (const key of ['size', 'ino', 'nlink']) check(info[key] === expected[key], 'native metadata ' + key);
  check(info.mtime instanceof Date && typeof info.mtimeMs === 'number', 'metadata date');
}
for (const [path, follow, expected] of cases) {
  const method = follow ? fs.stat : fs.lstat;
  for (const options of [undefined, null, { bigint: false }]) {
    const { error, result } = await callbackStat(method, path, options);
    if (expected.code) check(error && error.code === expected.code && error.path === path && error.syscall === (follow ? 'stat' : 'lstat') && result === undefined, 'actual native errno ' + path);
    else { check(error === null, 'null success error'); metadata(result, expected); }
  }
  let result, error;
  try { result = await promisify(method)(path); } catch (caught) { error = caught; }
  if (expected.code) check(error && error.code === expected.code && error.path === path, 'real promisified errno');
  else { check(!error, 'promisified stat success'); metadata(result, expected); }
  const suppressed = await callbackStat(method, path, { throwIfNoEntry: false });
  if (follow && (expected.code === 'ENOENT' || expected.code === 'ENOTDIR')) check(suppressed.error === null && suppressed.result === undefined, 'only native missing entry suppression');
  else if (expected.code) check(suppressed.error && suppressed.error.code === expected.code, 'other errors preserved');
  else metadata(suppressed.result, expected);
}
for (const invalid of [undefined, null, 42, {}]) {
  let error;
  try { fs.stat(root, {}, invalid); } catch (caught) { error = caught; }
  check(error instanceof TypeError && error.code === 'ERR_INVALID_ARG_TYPE', 'callback validation is synchronous');
}
await new Promise(function(resolve, reject) { fs.stat(root, function(error, info) { if (error) reject(error); else { check(info.isDirectory(), 'two argument overload'); resolve(); } }); });
fs.writeFileSync(root + '/plain', 'actual changed contents');
check((await promisify(fs.stat)(root + '/plain')).size === 23, 'real file mutation');
console.log('OK native callback stat/lstat, errno, deferred delivery and genuine promisify contracts');
