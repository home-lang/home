import {AsyncLocalStorage} from 'node:async_hooks';
import {setImmediate as nextCheck} from 'node:timers/promises';
function check(value,label){if(!value)throw new Error(label);}
const scope=new AsyncLocalStorage();
let groups=0;
const first=scope.run('first',()=>new Promise(resolve=>setImmediate(()=>{
  check(scope.getStore()==='first','callback context');
  Promise.resolve().then(()=>check(scope.getStore()==='first','callback promise context'));
  scope.enterWith('nested');
  setImmediate(()=>{check(scope.getStore()==='nested','nested callback context');resolve();});
})));
check(scope.getStore()===undefined,'registration restoration');
await first;
check(scope.getStore()===undefined,'callback restoration');
groups++;
const siblings=await Promise.all(['A','B'].map(value=>scope.run(value,async()=>{
  check(await nextCheck(value)===value&&scope.getStore()===value,'promise continuation context');return value;
})));
check(siblings.join(',')==='A,B'&&scope.getStore()===undefined,'sibling isolation');
groups++;
const reason={},events=[];
process.once('uncaughtExceptionMonitor',(e,origin)=>{check(e===reason&&origin==='uncaughtException'&&scope.getStore()==='throwing','monitor context');events.push('monitor');});
process.once('uncaughtException',(e,origin)=>{check(e===reason&&origin==='uncaughtException'&&scope.getStore()==='throwing','handler context');events.push('handled');});
scope.run('throwing',()=>setImmediate(()=>{throw reason;}));
await nextCheck();
check(events.join(',')==='monitor,handled'&&scope.getStore()===undefined,'exception restoration');
groups++;
check(groups===3,'actual context denominator');
console.log('NODE IMMEDIATE CONTEXT RESULTS '+JSON.stringify({groups,passed:groups,failures:[]}));
console.log('NODE IMMEDIATE CONTEXT 3 GROUPS OK');
