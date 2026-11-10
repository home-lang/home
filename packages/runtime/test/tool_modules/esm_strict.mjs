import commonjs from './esm_strict_cjs.cjs';
function check(value, message) { if (!value) throw new Error(message); }
function throws(body, Constructor, message) {
  let caught;
  try { body(); } catch (error) { caught = error; }
  check(caught instanceof Constructor, message);
  operations++;
}
let operations = 0;
check(this === undefined, 'ESM top-level this is undefined'); operations++;
check((() => this)() === undefined, 'ESM arrow inherits undefined receiver'); operations++;
function receiver() { return this; }
check(receiver() === undefined, 'ESM function inherits strictness'); operations++;
const locked = {};
Object.defineProperty(locked, 'value', { value: 1 });
throws(() => { locked.value = 2; }, TypeError, 'ESM read-only assignment throws');
throws(() => { __home_esm_missing_binding = 1; }, ReferenceError, 'ESM undeclared assignment throws');
check(!Object.hasOwn(globalThis, '__home_esm_missing_binding'), 'ESM undeclared write does not leak'); operations++;
eval('var __home_esm_eval_local = 1');
check(typeof __home_esm_eval_local === 'undefined', 'strict direct eval keeps var local'); operations++;
throws(() => { delete locked.value; }, TypeError, 'strict delete rejects non-configurable property');
check(Function('return this')() === globalThis, 'Function constructor retains its own sloppy source'); operations++;
check(commonjs.operations === 4, 'ESM imports a real sloppy CommonJS control'); operations++;
check(operations === 10, 'sync ESM strictness denominator ' + operations);
