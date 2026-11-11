import timers, {setImmediate as immediate, clearImmediate as cancel} from 'node:timers';
import promised, {setImmediate as nextCheck} from 'node:timers/promises';
import {createRequire} from 'node:module';
const [mode] = process.argv.slice(2);
function assert(value,label){if(!value)throw new Error(label);}
function throws(fn){let e;try{fn();}catch(error){e=error;}assert(e,'expected failure');return e;}
if(mode==='unref'){
  immediate(()=>{
    immediate(()=>console.log('unexpected callback')).unref();
    nextCheck('unexpected promise',{ref:false}).then(value=>console.log(value));
    console.log('UNREF IMMEDIATES REGISTERED');
  });
}else if(mode==='ref'){
  immediate(()=>console.log('REFERENCED IMMEDIATE FIRED')).unref().ref();
}else if(mode==='fatal'){
  process.on('uncaughtExceptionMonitor',()=>console.log('monitor'));
  process.on('exit',code=>console.log('exit '+code));
  immediate(()=>{throw new Error('immediate fatal witness');});
  immediate(()=>console.log('unexpected later callback'));
}else if(mode==='reject'||mode==='reject-listener'){
  process.on('exit',code=>console.log('exit '+code));
  if(mode==='reject-listener')process.on('unhandledRejection',e=>{assert(e==='immediate rejection witness','identity');console.log('rejected identity');});
  immediate(()=>Promise.reject('immediate rejection witness'));
}else if(mode==='guards'){
  const inputs=[{signal:{}},{unknown:true}];let count=0;
  for(const options of inputs){try{await nextCheck(42,options);throw new Error('unsupported option accepted');}catch(error){assert(error.code==='ERR_HOME_UNSUPPORTED','profile refusal');count++;}}
  assert(typeof globalThis.__home_tool_immediate_schedule==='undefined','native callback is private');
  console.log('HOME IMMEDIATE '+count+' REFUSALS OK');
}else if(mode==='contract'){
  const labels=[],failures=[];
  async function check(label,fn){
    let timeout;
    try{await Promise.race([Promise.resolve().then(fn),new Promise((resolve,reject)=>{timeout=setTimeout(()=>reject(new Error('Immediate contract timed out')),3000);})]);labels.push(label);}
    catch(error){failures.push({label,message:String(error),code:error.code});}
    finally{clearTimeout(timeout);}
  }
  await check('module/global/CJS identity and private native binding',()=>{
    const req=createRequire(import.meta.url);
    assert(typeof immediate==='function'&&typeof cancel==='function'&&typeof nextCheck==='function','actual immediate APIs');
    assert(timers===req('timers')&&timers===req('node:timers')&&immediate===globalThis.setImmediate&&cancel===globalThis.clearImmediate,'module identity');
    assert(promised===req('timers/promises')&&nextCheck===promised.setImmediate,'promise identity');
    assert(globalThis.__home_tool_immediate_schedule===undefined,'private binding');
  });
  await check('callbacks defer past current promise jobs and retain FIFO',()=>new Promise(resolve=>{
    const events=['registered'];
    immediate(()=>events.push('first'));immediate(()=>{events.push('second');assert(events.join(',')==='registered,job,first,second','check queue order');resolve();});
    Promise.resolve().then(()=>events.push('job'));
  }));
  await check('callback arguments and handle receiver are preserved',()=>new Promise(resolve=>{
    const value={actual:42};const handle=immediate(function(a,b){assert(this===handle&&a===value&&b==='actual','receiver and args');resolve();},value,'actual');
  }));
  await check('cancellation prevents execution and clears ref state',async()=>{
    let ran=false;const h=immediate(()=>ran=true);assert(h.hasRef(),'initial ref');assert(cancel(h)===undefined&&!h.hasRef(),'cancelled ref');
    await nextCheck();assert(!ran,'cancelled callback');
  });
  await check('nested immediates wait for the next batch',()=>new Promise(resolve=>{
    const events=[];
    immediate(()=>{events.push('first');immediate(()=>{events.push('nested');assert(events.join(',')==='first,second,nested','next batch');resolve();});});
    immediate(()=>events.push('second'));
  }));
  await check('microtask-created immediates wait behind the current batch',()=>new Promise(resolve=>{
    const events=[];
    immediate(()=>{events.push('first');Promise.resolve().then(()=>{events.push('job');immediate(()=>{events.push('nested');assert(events.join(',')==='first,job,second,nested','job/check batch');resolve();});});});
    immediate(()=>events.push('second'));
  }));
  await check('checkpoints run nextTick and promises between callbacks',()=>new Promise(resolve=>{
    const events=[];
    immediate(()=>{events.push('first');process.nextTick(()=>events.push('tick'));Promise.resolve().then(()=>events.push('job'));});
    immediate(()=>{events.push('second');assert(events.join(',')==='first,tick,job,second','callback checkpoint');resolve();});
  }));
  await check('timer-created immediate runs before its nested timeout',()=>new Promise((resolve,reject)=>{
    const events=[];
    setTimeout(()=>{
      try {
        events.push('timer');
        setTimeout(()=>events.push('timeout'),1);
        immediate(()=>events.push('check'));
        setTimeout(()=>{try{assert(events.join(',')==='timer,check,timeout','timer/check phases');resolve();}catch(error){reject(error);}},15);
      } catch(error) { reject(error); }
    },2);
  }));
  await check('promise jobs can cancel later callbacks in a batch',async()=>{
    let ran=false;let victim;
    immediate(()=>Promise.resolve().then(()=>cancel(victim)));
    victim=immediate(()=>ran=true);await nextCheck();assert(!ran,'checkpoint cancellation');
  });
  await check('ref and unref are idempotent and chainable',async()=>{
    const h=immediate(()=>{});assert(h.hasRef()&&h.unref()===h&&!h.hasRef()&&h.unref()===h&&!h.hasRef(),'unref');
    assert(h.ref()===h&&h.hasRef()&&h.ref()===h,'ref');await nextCheck();assert(!h.hasRef(),'fired handles not refed');
  });
  await check('fired handles cannot be resurrected during or after callback',()=>new Promise(resolve=>{
    const h=immediate(()=>{assert(!h.hasRef()&&h.ref()===h&&!h.hasRef(),'in-flight ref');Promise.resolve().then(()=>{h.ref();assert(!h.hasRef(),'after ref');resolve();});});
  }));
  await check('cancelled handles cannot be resurrected',async()=>{
    let ran=false;const h=immediate(()=>ran=true);cancel(h);h.ref().unref().ref();assert(!h.hasRef(),'cancelled ref');await nextCheck();assert(!ran,'cancelled remains absent');
  });
  await check('unref callbacks execute while other work keeps the host alive',()=>new Promise(resolve=>{
    let ran=false;immediate(()=>ran=true).unref();immediate(()=>{assert(ran,'unref work participates');resolve();});
  }));
  await check('timeout cancellation cannot cancel an Immediate handle',async()=>{
    let ran=false;const h=immediate(()=>ran=true);clearTimeout(h);await nextCheck();assert(ran,'handle domains');
    for(const value of [undefined,null,{},0,'1'])assert(cancel(value)===undefined,'unknown handles ignored');
  });
  await check('promise immediate resolves genuine values and validates ref',async()=>{
    const value={actual:42};assert(await nextCheck(value)===value&&await nextCheck(value,{ref:false})===value,'promise identity');
    let e;try{await nextCheck(42,{ref:'bad'});}catch(error){e=error;}assert(e?.code==='ERR_INVALID_ARG_TYPE','promise ref validation');
  });
  await check('invalid callbacks fail before scheduling',()=>{
    for(const value of [undefined,null,42,'source',{}])assert(throws(()=>immediate(value)).code==='ERR_INVALID_ARG_TYPE','callback validation');
  });
  await check('native immediate handles expose no numeric timeout id',()=>{
    const h=immediate(()=>{});assert(h[Symbol.toPrimitive]===undefined,'not a timeout id');cancel(h);
  });
  await check('handled throws preserve identity and allow the next callback',()=>new Promise(resolve=>{
    const reason={actual:42},events=[];
    process.once('uncaughtExceptionMonitor',(e,origin)=>{assert(e===reason&&origin==='uncaughtException','monitor identity');events.push('monitor');});
    process.once('uncaughtException',(e,origin)=>{assert(e===reason&&origin==='uncaughtException','handled identity');events.push('handled');});
    immediate(()=>{throw reason;});immediate(()=>{assert(events.join(',')==='monitor,handled','handled dispatch');resolve();});
  }));
  if(labels.length+failures.length!==18)throw new Error('wrong immediate denominator');
  console.log('NODE IMMEDIATE RESULTS '+JSON.stringify({checks:18,passed:labels.length,failures}));
  if(failures.length)throw new Error('Immediate contract failed');
  console.log('NODE IMMEDIATE 18 CHECKS OK');
}else throw new Error('Unknown immediate fixture mode');
