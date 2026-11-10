import commonjs from './esm_strict_cjs.cjs';
function check(value, message) { if (!value) throw new Error(message); }
let operations = 0;
await Promise.resolve();
check(this === undefined, 'async ESM top-level this is undefined'); operations++;
check((() => this)() === undefined, 'async ESM arrow inherits undefined receiver'); operations++;
async function receiver() { await Promise.resolve(); return this; }
check(await receiver() === undefined, 'async ESM function inherits strictness'); operations++;
const locked = {};
Object.defineProperty(locked, 'value', { value: 1 });
let readonlyError;
try { locked.value = 2; } catch (error) { readonlyError = error; }
check(readonlyError instanceof TypeError, 'async ESM read-only assignment throws'); operations++;
check(commonjs.operations === 4, 'async ESM retains sloppy CommonJS control'); operations++;
check(operations === 5, 'async ESM strictness denominator ' + operations);
