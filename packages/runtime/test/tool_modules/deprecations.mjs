import { deprecate } from 'node:util';
if (typeof deprecate !== 'function') throw Error('Missing deprecate: no cases executed');
const warnings = [];
process.on('warning', warning => warnings.push(warning));
const tick = () => new Promise(resolve => setImmediate(resolve));
const failures = [];
let groups = 0;
function check(value) { if (!value) throw Error('contract mismatch'); }
async function group(name, body) {
  groups++;
  try { await body(warnings.length); }
  catch (error) { failures.push({name, error:String(error)}); }
  await tick();
}
await group('receiver arguments and return identity', async start => {
  const marker = {}; let calls = 0;
  const fn = deprecate(function(a,b) { check(this.marker===marker && a===3 && b===4); calls++; return marker; }, 'forwarding', 'OWN_FORWARD');
  check(fn.call({marker},3,4)===marker && calls===1 && warnings.length===start);
  await tick(); check(warnings.length===start+1 && warnings[start].name==='DeprecationWarning' && warnings[start].code==='OWN_FORWARD');
});
await group('once per wrapper', async start => {
  let count=0; const fn=deprecate(()=>++count,'once wrapper');
  check(fn()===1 && fn()===2 && fn()===3); await tick();
  check(warnings.length===start+1 && warnings[start].code===undefined);
});
await group('shared code deduplication', async start => {
  const first=deprecate(()=>1,'first shared','OWN_SHARED');
  const second=deprecate(()=>2,'second shared','OWN_SHARED');
  check(first()===1 && second()===2); await tick();
  check(warnings.length===start+1 && warnings[start].message==='first shared');
});
await group('uncoded wrappers remain independent', async start => {
  deprecate(()=>{},'uncoded one')(); deprecate(()=>{},'uncoded two')(); await tick();
  check(warnings.length===start+2 && warnings[start].message==='uncoded one' && warnings[start+1].message==='uncoded two');
});
await group('distinct codes', async start => {
  deprecate(()=>{},'distinct a','OWN_DISTINCT_A')(); deprecate(()=>{},'distinct b','OWN_DISTINCT_B')(); await tick();
  check(warnings.length===start+2);
});
await group('original abrupt completion', async start => {
  const token={}; const fn=deprecate(()=>{throw token;},'abrupt','OWN_ABRUPT');
  for(let n=0;n<2;n++){let caught;try{fn();}catch(error){caught=error;}check(caught===token);}
  await tick();check(warnings.length===start+1);
});
await group('noDeprecation does not consume the warning', async start => {
  const saved=process.noDeprecation;let calls=0;const fn=deprecate(()=>++calls,'suppression','OWN_SUPPRESS');
  try{process.noDeprecation=true;check(fn()===1);await tick();check(warnings.length===start);process.noDeprecation=false;check(fn()===2);await tick();check(warnings.length===start+1);}
  finally{process.noDeprecation=saved;}
});
await group('constructor forwarding', async start => {
  function Original(value){this.value=value;} Original.extra=37;
  const Wrapped=deprecate(Original,'constructor','OWN_CONSTRUCT');const instance=new Wrapped(42);
  check(instance.value===42 && instance instanceof Original && instance instanceof Wrapped && Wrapped.extra===37);
  await tick();check(warnings.length===start+1);
});
await group('subclass new target', async start => {
  function Original(){this.target=new.target;}
  const Wrapped=deprecate(Original,'subclass','OWN_SUBCLASS');class Child extends Wrapped {}
  const value=new Child();check(value.target===Child && value instanceof Child && value instanceof Original);
  await tick();check(warnings.length===start+1);
});
await group('nonconstructible original', async start => {
  const Wrapped=deprecate(value=>value+1,'arrow','OWN_ARROW');check(Wrapped(4)===5);
  let caught;try{new Wrapped();}catch(error){caught=error;}check(caught instanceof TypeError);
  await tick();check(warnings.length===start+1);
});
await group('function metadata and static inheritance', async () => {
  function original(a,b){return a+b;} original.marker={};
  const wrapped=deprecate(original,'metadata','OWN_METADATA');const length=Object.getOwnPropertyDescriptor(wrapped,'length');
  check(wrapped.length===2 && wrapped.name==='deprecated' && Object.getPrototypeOf(wrapped)===original && wrapped.prototype===original.prototype && wrapped.marker===original.marker && length.configurable && !length.writable);
});
await group('modifyPrototype false', async start => {
  function Original(value){this.value=value;}
  const Wrapped=deprecate(Original,'plain wrapper','OWN_PLAIN',{modifyPrototype:false});const value=new Wrapped(9);
  check(Object.getPrototypeOf(Wrapped)===Function.prototype && Wrapped.prototype!==Original.prototype && Wrapped.length===0 && value.value===9 && value instanceof Wrapped && !(value instanceof Original));
  await tick();check(warnings.length===start+1);
});
await group('invalid code rejected at creation', async () => {
  let caught;try{deprecate(()=>{},'bad code',7);}catch(error){caught=error;}
  check(caught instanceof TypeError && caught.code==='ERR_INVALID_ARG_TYPE');
});
await group('message validation and warning attempt precede body', async () => {
  let calls=0;const wrapped=deprecate(()=>++calls,17);let caught;
  try{wrapped();}catch(error){caught=error;}
  check(caught instanceof TypeError && caught.code==='ERR_INVALID_ARG_TYPE' && calls===0 && wrapped()===1);
});
await group('observable warning hook', async start => {
  const saved=process.emitWarning;const calls=[];
  try{process.emitWarning=function(...args){calls.push(args);};const wrapped=deprecate(()=>5,'hook','OWN_HOOK');check(wrapped()===5 && wrapped()===5);check(calls.length===1 && calls[0][0]==='hook' && calls[0][1]==='DeprecationWarning' && calls[0][2]==='OWN_HOOK' && typeof calls[0][3]==='function');}
  finally{process.emitWarning=saved;}
  check(warnings.length===start);
});
await group('throwing warning hook preserves completion and code retry', async start => {
  const saved=process.emitWarning;const token={};let calls=0;const wrapped=deprecate(()=>++calls,'failed hook','OWN_HOOK_RETRY');
  try{process.emitWarning=function(){throw token;};let caught;try{wrapped();}catch(error){caught=error;}check(caught===token && calls===0 && wrapped()===1);}
  finally{process.emitWarning=saved;}
  deprecate(()=>{},'real retry','OWN_HOOK_RETRY')();await tick();check(warnings.length===start+1 && warnings[start].message==='real retry');
});
await group('class call and construction', async start => {
  class Original{constructor(value){this.value=value;}}
  const Wrapped=deprecate(Original,'class','OWN_CLASS');let caught;try{Wrapped();}catch(error){caught=error;}
  check(caught instanceof TypeError && new Wrapped(13).value===13);await tick();check(warnings.length===start+1);
});
await group('later suppression preserves function side effects', async start => {
  const saved=process.noDeprecation;let calls=0;const fn=deprecate(()=>++calls,'later suppression','OWN_LATER');
  try{fn();process.noDeprecation=true;check(fn()===2);await tick();check(warnings.length===start+1);}
  finally{process.noDeprecation=saved;}
});
await group('Error warning identity', async start => {
  const warning=new Error('original warning');warning.code='OWN_ERROR';
  check(deprecate(()=>23,warning)()===23);await tick();check(warnings.length===start+1 && warnings[start]===warning && warning.name==='Error');
});
await group('strict receiver without arguments', async start => {
  const fn=deprecate(function(){'use strict';return this;},'strict receiver','OWN_STRICT');
  check(fn()===undefined);await tick();check(warnings.length===start+1);
});
console.log('DEPRECATION RESULTS '+JSON.stringify({groups,passed:groups-failures.length,failures}));
if(groups!==20 || failures.length)throw Error('Deprecation contract failed');
