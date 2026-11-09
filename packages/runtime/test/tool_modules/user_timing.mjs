import hooks, { performance as p, PerformanceMark, PerformanceEntry } from 'node:perf_hooks';
import alias from 'perf_hooks';
function check(value,message){if(!value)throw new Error(message);}
check(hooks===alias && p===globalThis.performance && typeof p.mark==='function','real timing module');
check(PerformanceMark===globalThis.PerformanceMark && PerformanceEntry===globalThis.PerformanceEntry,'entry constructors');
p.clearMarks();
const lower=p.now(), first=p.mark('real-clock'), upper=p.now();
check(first instanceof PerformanceMark && first instanceof PerformanceEntry && first.name==='real-clock' && first.entryType==='mark' && first.duration===0 && first.detail===null,'actual mark fields');
check(first.startTime>=lower && first.startTime<=upper,'native mark timestamp bounds');
const start=process.hrtime.bigint();while(Number(process.hrtime.bigint()-start)<8000000){}
const second=p.mark('real-clock');check(second!==first && second.startTime-first.startTime>=1,'elapsed native mark timestamp');
p.clearMarks();
const explicit=p.mark('later',{startTime:9,detail:17});
const early=p.mark('early',{startTime:2,detail:'detail'});
const repeated=p.mark('later',{startTime:9,detail:false});
check(p.getEntries().map(e=>e.name).join(',')==='early,later,later','timeline order');
check(p.getEntriesByName('later').length===2 && p.getEntriesByName('later','mark')[1]===repeated && p.getEntriesByName('later','measure').length===0,'actual name and type selection');
check(p.getEntriesByType('mark').length===3 && p.getEntriesByType('measure').length===0,'actual registered entry types');
const snapshot=p.getEntries();snapshot.length=0;check(p.getEntries().length===3,'snapshot isolation');
check(explicit.toJSON().detail===17 && JSON.stringify(early)===JSON.stringify({name:'early',entryType:'mark',startTime:2,duration:0,detail:'detail'}),'entry serialization');
try{explicit.startTime=100;}catch{}check(explicit.startTime===9,'readonly entry');
const standalone=new PerformanceMark('standalone',{startTime:3,detail:1n});check(standalone.detail===1n && p.getEntriesByName('standalone').length===0,'constructor does not register itself');
const accesses=[];let detailReads=0;
const getter=p.mark('getters',{get startTime(){accesses.push('startTime');return 4;},get detail(){accesses.push('detail');return ++detailReads;}});
check(accesses.join(',')==='startTime,detail' && detailReads===1 && getter.detail===1,'ordered single option reads');
let invalidDetailReads=0;
try {new PerformanceMark('invalid-getter',{startTime:-1,get detail(){invalidDetailReads++;return 1;}});}catch{}
check(invalidDetailReads===0,'timestamp errors precede detail access');
for(const name of [undefined,null,42,{toString(){return 'named-object';}}]){const entry=p.mark(name,{startTime:1});check(entry.name===String(name),'name conversion');}
for(const fn of [()=>p.mark(),()=>p.getEntriesByName(),()=>p.getEntriesByType()]){let e;try{fn();}catch(error){e=error;}check(e instanceof TypeError && e.code==='ERR_MISSING_ARGS','required name argument');}
for(const value of [-1,-Infinity]){let e;try{p.mark('invalid',{startTime:value});}catch(error){e=error;}check(e instanceof TypeError && e.code==='ERR_PERFORMANCE_INVALID_TIMESTAMP','negative timestamp');}
for(const value of ['1',false,1n]){let e;try{p.mark('invalid',{startTime:value});}catch(error){e=error;}check(e instanceof TypeError && e.code==='ERR_INVALID_ARG_TYPE','timestamp type');}
for(const name of ['nodeStart','v8Start','environment','loopStart','loopExit','bootstrapComplete']){let e;try{p.mark(name);}catch(error){e=error;}check(e instanceof TypeError && e.code==='ERR_INVALID_ARG_VALUE','reserved native timing name');}
for(const fn of [()=>p.mark(Symbol('bad')),()=>p.getEntriesByName(Symbol('bad')),()=>p.clearMarks(Symbol('bad'))]){let e;try{fn();}catch(error){e=error;}check(e instanceof TypeError,'Symbol string refusal');}
for(const name of ['mark','getEntries','getEntriesByName','getEntriesByType','clearMarks']){let e;try{p[name].call({},'x');}catch(error){e=error;}check(e instanceof TypeError && e.code==='ERR_INVALID_THIS','Performance receiver');}
for(const fn of [()=>new PerformanceEntry(),()=>Object.getOwnPropertyDescriptor(PerformanceEntry.prototype,'name').get.call({}),()=>PerformanceEntry.prototype.toJSON.call({})]){let e;try{fn();}catch(error){e=error;}check(e instanceof TypeError,'entry brand');}
p.clearMarks();
const savedNow=p.now,savedDate=Date.now,savedHrtime=process.hrtime;
try{p.now=()=>-1;Date.now=()=>-2;process.hrtime=()=>[0,0];const m=p.mark('independent');check(m.startTime>=0 && m.startTime!==-1 && m.startTime!==-2,'mark uses protected native sample');}finally{p.now=savedNow;Date.now=savedDate;process.hrtime=savedHrtime;}
p.mark('remove',{startTime:0});p.mark('keep',{startTime:1});p.clearMarks('remove');check(p.getEntriesByName('remove').length===0 && p.getEntriesByName('keep').length===1,'selective clear');p.clearMarks();check(p.getEntries().length===0,'clear releases timeline');
console.log('OK real native User Timing marks, entries, order, queries, clearing, brands and validation');
