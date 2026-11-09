import fs, { access, constants } from 'node:fs';
import alias from 'fs';
import { promisify } from 'node:util';
function check(value, message) { if (!value) throw new Error(message); }
const root = process.argv[2];
const cases = JSON.parse(process.argv[3]);
check(typeof access === 'function' && access === fs.access && fs === alias, 'callback access module aliases');
function callbackAccess(path, mode) {
  return new Promise(function(resolve, reject) {
    let synchronous = true;
    const returned = access(path, mode, function(error) {
      try {
        check(!synchronous && arguments.length === 1, 'deferred single error argument');
        resolve(error);
      } catch (failure) { reject(failure); }
    });
    check(returned === undefined, 'callback access returns undefined');
    synchronous = false;
  });
}
function verifyError(error, code, path) {
  check(error && error.code === code && error.syscall === 'access' && error.path === path, 'native access errno: ' + path + ' ' + code);
}
const promisedAccess = promisify(access);
for (const [path, mode, code] of cases) {
  let error = await callbackAccess(path, mode);
  if (code) verifyError(error, code, path);
  else check(error === null, 'actual native access success ' + mode);
  error = undefined;
  let result;
  try { result = await promisedAccess(path, mode); } catch (caught) { error = caught; }
  if (code) verifyError(error, code, path);
  else check(!error && result === undefined, 'actual promisified permissions');
}
for (const mode of [undefined, null, 1.9, -0.9, 7.99]) check(await callbackAccess(root, mode) === null && await promisedAccess(root, mode) === undefined, 'Node mode normalization');
for (const mode of [NaN, Infinity, -Infinity, 8, -1, 4294967296, '0', true, {}, 0n]) {
  let error;
  try { access(root, mode, function() { throw new Error('invalid mode callback'); }); } catch (caught) { error = caught; }
  check(error && error.code === (typeof mode === 'number' ? 'ERR_OUT_OF_RANGE' : 'ERR_INVALID_ARG_TYPE'), 'mode validation is synchronous');
}
for (const invalid of [undefined, null, 42, {}]) {
  let error;
  try { access(root, 0, invalid); } catch (caught) { error = caught; }
  check(error && error.code === 'ERR_INVALID_ARG_TYPE', 'callback validation');
}
await new Promise(function(resolve, reject) { access(root, function(error) { if (error) reject(error); else resolve(); }); });
let nulError;
try { access('bad\0path', function() { throw new Error('NUL path callback'); }); } catch (error) { nulError = error; }
check(nulError && nulError.code === 'ERR_INVALID_ARG_VALUE', 'NUL path rejected before scheduling');
const created = root + '/callback-created';
fs.writeFileSync(created, 'real file');
check(await callbackAccess(created, constants.F_OK) === null, 'actual new file');
await fs.promises.rm(created);
verifyError(await callbackAccess(created), 'ENOENT', created);
console.log('OK callback access, actual permissions and errno, all modes, mutation and promisify');
