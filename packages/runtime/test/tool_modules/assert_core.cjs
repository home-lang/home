const assert = require('node:assert');
function check(value, message) { if (!value) throw new Error(message); }
check(assert === require('assert') && typeof assert.ok === 'function', 'module and ok identity');
let checks = 0;
for (const value of [true, 1, -1, 'x', {}, [], 1n, Symbol('truthy')]) { check(assert(value) === undefined, 'truthy return'); checks++; }
for (const value of [undefined, null, false, 0, -0, NaN, '', 0n]) {
  let error; try { assert(value, 'falsy witness'); } catch (caught) { error = caught; }
  check(error instanceof Error && error instanceof assert.AssertionError && error.code === 'ERR_ASSERTION' && error.name === 'AssertionError' && Object.is(error.actual,value) && error.expected === true && error.operator === '==' && error.generatedMessage === false && error.message === 'falsy witness', 'actual falsy failure'); checks++;
}
const shared = {}, symbol = Symbol('same');
const values = [undefined,null,false,true,0,-0,NaN,1,-1,Infinity,-Infinity,'','1',1n,shared,{},symbol,Symbol('same')];
for (const actual of values) for (const expected of values) for (const name of ['strictEqual','notStrictEqual']) {
  const shouldPass = name === 'strictEqual' ? Object.is(actual,expected) : !Object.is(actual,expected);
  let error, returned; try { returned = assert[name](actual,expected,'comparison witness'); } catch (caught) { error = caught; }
  if (shouldPass) check(error === undefined && returned === undefined, 'SameValue positive');
  else check(error instanceof assert.AssertionError && error.code === 'ERR_ASSERTION' && Object.is(error.actual,actual) && Object.is(error.expected,expected) && error.operator === name && error.generatedMessage === false, 'SameValue negative');
  checks++;
}
for (const name of ['strictEqual','notStrictEqual']) for (const args of [[],[undefined],[1]]) {
  let error; try { assert[name](...args); } catch (caught) { error=caught; }
  check(error instanceof TypeError && error.code === 'ERR_MISSING_ARGS','missing comparison args'); checks++;
}
const original = new RangeError('original identity');
for (const call of [()=>assert(false,original),()=>assert.strictEqual(1,2,original),()=>assert.notStrictEqual(1,1,original)]) {
  let caught; try { call(); } catch (error) { caught=error; }
  check(caught===original,'propagate original Error'); checks++;
}
for (const call of [()=>assert.strictEqual(1,2),()=>assert.notStrictEqual(1,1),()=>assert(false),()=>assert()]) {
  let caught; try { call(); } catch (error) { caught=error; }
  check(caught instanceof assert.AssertionError && caught.generatedMessage===true && typeof caught.message==='string' && caught.message.length>0,'generated diagnostic'); checks++;
}
const manual = new assert.AssertionError({actual:17,expected:42,operator:'strictEqual',message:'manual witness'});
check(manual instanceof Error && manual.code==='ERR_ASSERTION' && manual.actual===17 && manual.expected===42 && manual.operator==='strictEqual' && manual.generatedMessage===false,'public error constructor'); checks++;
const savedIs = Object.is;
let emptyMessage;
try { assert.ok(0,''); } catch (error) { emptyMessage=error; }
check(emptyMessage instanceof assert.AssertionError && emptyMessage.message==='' && emptyMessage.generatedMessage===false,'explicit empty ok message');
const noConversion={toString(){throw new Error('conversion must not replace assertion');}};
let conversionFailure;
try { assert.strictEqual(noConversion,{}); } catch(error) { conversionFailure=error; }
check(conversionFailure instanceof assert.AssertionError && conversionFailure.actual===noConversion,'retain object without conversion');
Object.is=function(){throw new Error('mutated public Object.is');};
try { assert.strictEqual(NaN,NaN); assert.notStrictEqual(0,-0); } finally { Object.is=savedIs; }
console.log('OK core assertions '+checks+' actual truthiness, SameValue, negative, error and argument checks');
