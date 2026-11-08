import fs, { accessSync, constants } from 'node:fs';
import alias from 'fs';
import promises, { access } from 'node:fs/promises';
import promiseAlias from 'fs/promises';

function check(value, message) { if (!value) throw new Error(message); }
const root = process.argv[2];
const cases = JSON.parse(process.argv[3]);
check(fs === alias && fs.accessSync === accessSync, 'sync aliases');
check(fs.promises === promises && promises === promiseAlias && promises.access === access, 'promise aliases');
check(constants === fs.constants && constants === promises.constants, 'shared actual access constants');
for (const [key, value] of [['F_OK', 0], ['R_OK', 4], ['W_OK', 2], ['X_OK', 1]]) {
  const descriptor = Object.getOwnPropertyDescriptor(constants, key);
  check(descriptor.value === value && descriptor.enumerable && !descriptor.writable && !descriptor.configurable, 'constant descriptor: ' + key);
}
const descriptor = Object.getOwnPropertyDescriptor(fs, 'constants');
check(descriptor.enumerable && !descriptor.writable && !descriptor.configurable, 'fs constants descriptor');
function verifyError(error, code, path) {
  check(error && error.code === code && error.syscall === 'access' && error.path === path, 'actual access errno: ' + path + ' expected ' + code);
}
for (const [path, mode, code] of cases) {
  let error;
  let result;
  try { result = accessSync(path, mode); } catch (caught) { error = caught; }
  if (code) verifyError(error, code, path);
  else check(!error && result === undefined, 'actual synchronous access: ' + path + ' mode ' + mode);
  error = undefined;
  let pending;
  // Even errors return a genuine rejected promise rather than throwing early.
  try { pending = access(path, mode); } catch (caught) { throw new Error('access threw before returning a promise: ' + caught); }
  check(pending instanceof Promise, 'access promise identity');
  try { result = await pending; } catch (caught) { error = caught; }
  if (code) verifyError(error, code, path);
  else check(!error && result === undefined, 'actual promised access: ' + path + ' mode ' + mode);
}
for (const mode of [undefined, null, 1.9, -0.9, 7.99]) {
  check(accessSync(root, mode) === undefined && await access(root, mode) === undefined, 'Node mode normalization');
}
for (const mode of [NaN, Infinity, -Infinity, 8, -1, 4294967296, '0', true, {}, 0n]) {
  const code = typeof mode === 'number' ? 'ERR_OUT_OF_RANGE' : 'ERR_INVALID_ARG_TYPE';
  let error;
  try { accessSync(root, mode); } catch (caught) { error = caught; }
  check(error && error.code === code, 'sync invalid access mode');
  error = undefined;
  try { await access(root, mode); } catch (caught) { error = caught; }
  check(error && error.code === code, 'rejected invalid access mode');
}
console.log('OK native access permissions, all mode bits, aliases, symlinks, errno and rejected promises');
