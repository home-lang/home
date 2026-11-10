function check(value, message) { if (!value) throw new Error(message); }
let operations = 0;
function receiver() { return this; }
check(receiver() === globalThis, 'CommonJS ordinary function stays sloppy'); operations++;
const locked = {};
Object.defineProperty(locked, 'value', { value: 1 });
locked.value = 2;
check(locked.value === 1, 'CommonJS read-only assignment stays silent'); operations++;
__home_esm_sloppy_control = 17;
check(globalThis.__home_esm_sloppy_control === 17, 'CommonJS undeclared assignment stays global'); operations++;
delete globalThis.__home_esm_sloppy_control;
check(!Object.hasOwn(globalThis, '__home_esm_sloppy_control'), 'CommonJS control cleans its global'); operations++;
check(operations === 4, 'CommonJS strictness control denominator ' + operations);
module.exports = { operations };
