const warnings=[];
function observe(warning){warnings.push(warning);}
process.on('warning',observe);
const tick=()=>new Promise(resolve=>setImmediate(resolve));
const failures=[];let groups=0;
function check(value){if(!value)throw Error('warning contract mismatch');}
async function group(name,body){groups++;try{await body(warnings.length);}catch(error){failures.push({name,error:String(error)});}await tick();}
await group('deferred warning event',async start=>{
  check(process.emitWarning('deferred warning')===undefined && warnings.length===start);await tick();
  check(warnings.length===start+1 && warnings[start] instanceof Error && warnings[start].name==='Warning');
});
await group('named options and detail',async start=>{
  process.emitWarning('owned fields',{type:'OwnedWarning',code:'OWN_FIELDS',detail:'physical detail'});await tick();
  check(warnings.length===start+1 && warnings[start].name==='OwnedWarning' && warnings[start].code==='OWN_FIELDS' && warnings[start].detail==='physical detail');
});
await group('Error identity and immutable existing fields',async start=>{
  const error=new Error('owned identity');error.code='OWN_ORIGINAL';error.detail='original detail';
  process.emitWarning(error,{type:'Ignored',code:'IGNORED',detail:'ignored detail'});await tick();
  check(warnings.length===start+1 && warnings[start]===error && error.name==='Error' && error.code==='OWN_ORIGINAL' && error.detail==='original detail');
});
await group('invalid warning values',async start=>{
  for(const value of [null,5,{},Symbol('warning')]){let caught;try{process.emitWarning(value);}catch(error){caught=error;}check(caught instanceof TypeError && caught.code==='ERR_INVALID_ARG_TYPE');}
  await tick();check(warnings.length===start);
});
await group('invalid type values',async start=>{
  for(const type of [null,7,[],true]){let caught;try{process.emitWarning('invalid type',type);}catch(error){caught=error;}check(caught instanceof TypeError && caught.code==='ERR_INVALID_ARG_TYPE');}
  await tick();check(warnings.length===start);
});
await group('invalid code',async start=>{
  let caught;try{process.emitWarning('invalid code',{code:7});}catch(error){caught=error;}
  check(caught instanceof TypeError && caught.code==='ERR_INVALID_ARG_TYPE');await tick();check(warnings.length===start);
});
await group('constructor overloads',async start=>{
  function marker(){}
  process.emitWarning('type overload',marker);process.emitWarning('code overload','OwnedWarning',marker);await tick();
  check(warnings.length===start+2 && warnings[start].name==='Warning' && warnings[start].code===undefined && warnings[start+1].name==='OwnedWarning' && warnings[start+1].code===undefined);
});
await group('deprecation suppression preserves ordinary warnings',async start=>{
  const saved=process.noDeprecation;
  try{process.noDeprecation=true;const error=new Error('suppressed error');error.name='DeprecationWarning';process.emitWarning('suppressed string','DeprecationWarning');process.emitWarning(error);process.emitWarning('not deprecated','OwnedWarning');await tick();check(warnings.length===start+1 && warnings[start].message==='not deprecated');}
  finally{process.noDeprecation=saved;}
});
await group('non-string detail is ignored',async start=>{
  process.emitWarning('ignored detail',{detail:{not:'a string'}});await tick();check(warnings.length===start+1 && warnings[start].detail===undefined);
});
await group('once warning listener',async start=>{
  let calls=0;process.once('warning',()=>calls++);process.emitWarning('once one');process.emitWarning('once two');await tick();check(warnings.length===start+2 && calls===1);
});
await group('listeners selected at delivery',async start=>{
  let added=0,removed=0;function early(){removed++;}function late(){added++;}
  process.on('warning',early);process.emitWarning('listener timing');process.off('warning',early);process.on('warning',late);await tick();process.off('warning',late);
  check(warnings.length===start+1 && added===1 && removed===0);
});
await group('default listener is removable',async start=>{
  const listeners=process.listeners('warning');process.removeAllListeners('warning');process.emitWarning('OWN_REMOVED_WARNING');await tick();
  for(const listener of listeners)process.on('warning',listener);
  check(warnings.length===start);
});
await group('direct warning listener throws propagate',async start=>{
  const token={};function fail(){throw token;}process.on('warning',fail);let caught;
  try{process.emit('warning',new Error('direct warning'));}catch(error){caught=error;}finally{process.off('warning',fail);}
  check(caught===token && warnings.length===start+1);
});
console.log('WARNING RESULTS '+JSON.stringify({groups,passed:groups-failures.length,failures}));
if(groups!==13 || failures.length)throw Error('Warning contract failed');
