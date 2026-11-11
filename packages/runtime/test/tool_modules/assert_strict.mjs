import assert, {strict as named} from 'node:assert';
import alias from 'assert';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url), strict=assert.strict, passed=[], failures=[];
function check(value,message){if(!value)throw new Error(message);}
function failure(fn,code){let error;try{fn();}catch(e){error=e;}check(error&&error.code===code,'expected actual '+code);return error;}
async function group(label,fn){try{await fn();passed.push(label);}catch(e){failures.push({label,error:String(e)});}}
await group('existing default assertion works',()=>check(assert===alias&&assert(true)===undefined,'default'));
await group('named callable strict export',()=>check(typeof strict==='function'&&strict===named&&strict!==assert,'distinct strict'));
await group('ESM strict aliases',async()=>{const a=await import('assert/strict'),b=await import('node:assert/strict');check(a.default===strict&&b.default===strict&&a.strict===strict&&b.strict===strict,'ESM aliases');});
await group('CommonJS strict aliases',()=>check(require('assert/strict')===strict&&require('node:assert/strict')===strict,'CJS aliases'));
await group('strict self and metadata',()=>check(strict.strict===strict&&strict.length===0&&strict.name==='strict','metadata'));
await group('real method and error identities',()=>check(strict.ok===assert.ok&&strict.AssertionError===assert.AssertionError&&strict.strictEqual===assert.strictEqual&&strict.notStrictEqual===assert.notStrictEqual,'identities'));
await group('strict comparison aliases',()=>check(strict.equal===strict.strictEqual&&strict.notEqual===strict.notStrictEqual,'aliases'));
await group('truthy values execute',()=>{for(const value of [true,1,-1,'x',{},[],1n,Symbol('x')])check(strict(value)===undefined,'truthy return');});
await group('falsy values really fail',()=>{for(const value of [false,0,-0,'',null,undefined,NaN]){const e=failure(()=>strict(value,'actual falsy'),'ERR_ASSERTION');check(e instanceof strict.AssertionError&&Object.is(e.actual,value)&&e.expected===true&&e.operator==='=='&&e.message==='actual falsy','failure fields');}});
await group('missing value diagnostic',()=>{const e=failure(()=>strict(),'ERR_ASSERTION');check(e.actual===undefined&&e.expected===true&&e.generatedMessage===true,'missing value');});
await group('Error message is rethrown',()=>{const original=new TypeError('actual plugin validation');let e;try{strict(false,original);}catch(caught){e=caught;}check(e===original,'original error identity');});
await group('equal uses strict types',()=>{const e=failure(()=>strict.equal(1,'1','type witness'),'ERR_ASSERTION');check(e.actual===1&&e.expected==='1'&&e.operator==='strictEqual','strict type failure');});
await group('equal accepts NaN SameValue',()=>check(strict.equal(NaN,NaN)===undefined,'NaN'));
await group('equal rejects signed zero',()=>{const e=failure(()=>strict.equal(0,-0),'ERR_ASSERTION');check(Object.is(e.actual,0)&&Object.is(e.expected,-0),'signed zero');});
await group('notEqual accepts signed zero',()=>check(strict.notEqual(0,-0)===undefined,'distinct zeros'));
await group('notEqual rejects NaN SameValue',()=>failure(()=>strict.notEqual(NaN,NaN),'ERR_ASSERTION'));
await group('comparison requires arguments',()=>{failure(()=>strict.equal(1),'ERR_MISSING_ARGS');failure(()=>strict.notEqual(1),'ERR_MISSING_ARGS');});
await group('detached call and ok remain real',()=>{check(strict.call({actual:'poison'},true)===undefined,'detached truthy');failure(()=>strict.call(null,false),'ERR_ASSERTION');failure(()=>strict.ok(false),'ERR_ASSERTION');});
console.log('STRICT ASSERT RESULTS '+JSON.stringify({groups:18,passed:passed.length,failures}));
if(passed.length!==18||failures.length)throw new Error('strict assertion contract incomplete');
console.log('STRICT ASSERT 18 GROUPS OK');
