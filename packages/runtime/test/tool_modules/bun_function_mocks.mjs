import { mock, spyOn } from 'bun:test';
const failures=[],passed=[];
function check(value){if(!value)throw new Error('predicate failed');}
function equal(a,b){check(JSON.stringify(a)===JSON.stringify(b));}
async function group(name,fn){try{await fn();passed.push(name);}catch(e){failures.push({name,error:String(e)});}}
await group('empty-and-real-implementation',()=>{let effects=0;const f=mock(x=>{effects++;return x*3;});check(mock()()===undefined&&f(4)===12&&effects===1);});
await group('argument-and-result-identities',()=>{const obj={},f=mock(x=>x),result=f(obj);check(result===obj&&f.mock.calls[0][0]===obj&&f.mock.results[0].value===obj);});
await group('receiver-context',()=>{const obj={n:4},f=mock(function(x){return this.n+x;});check(f.call(obj,3)===7&&f.mock.contexts[0]===obj&&f.mock.instances.length===0);});
await group('undefined-receiver',()=>{const f=mock(function(){'use strict';return this;});check(f()===undefined&&f.mock.contexts[0]===undefined);});
await group('last-call',()=>{const f=mock();check(f.mock.lastCall===undefined);f(1);f(2,3);check(f.mock.lastCall===f.mock.calls[1]);equal(f.mock.lastCall,[2,3]);});
await group('throw-identity-and-trace',()=>{const error={},f=mock(()=>{throw error;});let same=false;try{f('x');}catch(e){same=e===error;}check(same&&f.mock.results[0].type==='throw'&&f.mock.results[0].value===error);equal(f.mock.calls,[['x']]);});
await group('incomplete-during-call',()=>{let inside;const f=mock(()=>{inside=f.mock.results[0].type;return 4;});check(f()===4&&inside==='incomplete'&&f.mock.results[0].type==='return');});
await group('recursive-result-slots',()=>{const f=mock(n=>n===0?1:n*f(n-1));check(f(3)===6);equal(f.mock.calls,[[3],[2],[1],[0]]);equal(f.mock.results.map(r=>r.value),[6,2,1,1]);});
await group('global-invocation-order',()=>{const a=mock(),b=mock();a();b();a();check(a.mock.invocationCallOrder[0]<b.mock.invocationCallOrder[0]&&b.mock.invocationCallOrder[0]<a.mock.invocationCallOrder[1]);});
await group('implementation-reflection',()=>{function sum(a,b){return a+b;}const f=mock(sum);check(f.length===2&&f.name==='sum'&&f.getMockName()==='sum'&&f.getMockImplementation()===sum);});
await group('implementation-replacement',()=>{const f=mock(()=>1),next=()=>2;check(f.mockImplementation(next)===f&&f()===2&&f.getMockImplementation()===next);});
await group('once-order-and-default',()=>{const f=mock(()=>0);f.mockImplementationOnce(()=>1).mockReturnValueOnce(2).mockReturnValue(3);equal([f(),f(),f(),f()],[1,2,3,3]);});
await group('once-throw-consumed',()=>{const error={},f=mock(()=>3).mockImplementationOnce(()=>{throw error;});let same=false;try{f();}catch(e){same=e===error;}check(same&&f()===3);});
await group('return-this',()=>{const receiver={},f=mock().mockReturnThis();check(f.call(receiver)===receiver);});
await group('return-value-chain',()=>{const value={},f=mock();check(f.mockReturnValue(value)===f&&f()===value);});
await group('clear-keeps-implementation-and-queue',()=>{const f=mock(()=>3).mockReturnValueOnce(1).mockReturnValueOnce(2);f('old');const state=f.mock,calls=state.calls;check(f.mockClear()===f&&f.mock!==state&&f.mock.calls!==calls);equal(calls,[['old']]);check(f()===2&&f()===3);});
await group('clear-during-call',()=>{const f=mock(()=>{f.mockClear();return 4;});const old=f.mock;check(f()===4&&f.mock.calls.length===0&&old.calls.length===1);});
await group('reset-drops-implementation-and-queue',()=>{const f=mock(()=>3).mockReturnValueOnce(1);f.mockReset();check(f()===undefined&&f.getMockImplementation()===undefined&&f.mock.calls.length===1);});
await group('plain-restore-clears',()=>{const f=mock(()=>4);f(1);check(f.mockRestore()===f&&f.mock.calls.length===0&&f()===undefined);});
await group('mock-name',()=>{const f=mock();check(f.mockName('request')===f&&f.getMockName()==='request'&&f.name==='request');});
await group('async-promise-identity',async()=>{const p=Promise.resolve(8),f=mock(()=>p),actual=f();check(actual===p&&f.mock.results[0].value===p&&f.mock.results[0].type==='return'&&await actual===8);});
await group('resolved-once-and-default',async()=>{const f=mock().mockResolvedValue(3).mockResolvedValueOnce(1);check(await f()===1&&await f()===3);});
await group('rejected-once-and-default',async()=>{const a={},b={},f=mock().mockRejectedValue(b).mockRejectedValueOnce(a);let first,second;try{await f();}catch(e){first=e;}try{await f();}catch(e){second=e;}check(first===a&&second===b&&f.mock.results.every(r=>r.type==='return'));});
await group('own-method-spy-and-restore',()=>{const obj={n:2,f(x){return this.n+x;}},original=obj.f,s=spyOn(obj,'f');check(obj.f(3)===5&&s.mock.contexts[0]===obj);s.mockReturnValue(9);check(obj.f(1)===9);check(s.mockRestore()===s&&obj.f===original&&obj.f(4)===6&&s.mock.calls.length===0);});
await group('repeated-spy-identity',()=>{const obj={f(){return 1;}},s=spyOn(obj,'f');check(spyOn(obj,'f')===s);s.mockRestore();check(spyOn(obj,'f')!==s);obj.f.mockRestore();});
await group('own-descriptor-restored',()=>{const obj={};function original(){return 4;}Object.defineProperty(obj,'f',{value:original,writable:true,configurable:true,enumerable:false});const s=spyOn(obj,'f');check(obj.f()===4&&!Object.getOwnPropertyDescriptor(obj,'f').enumerable);s.mockRestore();const d=Object.getOwnPropertyDescriptor(obj,'f');check(d.value===original&&d.writable&&d.configurable&&!d.enumerable);});
await group('inherited-method-called',()=>{const proto={f(){return this.n;}},obj=Object.create(proto);obj.n=6;const s=spyOn(obj,'f');check(obj.f()===6&&s.mock.contexts[0]===obj);s.mockRestore();check(obj.f===proto.f&&obj.f()===6);});
await group('function-call-spy',()=>{function original(x){return this.n+x;}const s=spyOn(original,'call');check(original.call({n:3},4)===7);equal(s.mock.calls[0],[{n:3},4]);s.mockRestore();});
await group('symbol-method',()=>{const key=Symbol('f'),obj={[key](x){return x+1;}},s=spyOn(obj,key);check(obj[key](2)===3&&s.mock.calls[0][0]===2);s.mockRestore();});
await group('spy-reset-keeps-wrapper',()=>{const obj={f(){return 1;}},s=spyOn(obj,'f');s.mockReset();check(obj.f===s&&obj.f()===undefined);s.mockRestore();check(obj.f()===1);});
console.log('FUNCTION MOCK RESULTS '+JSON.stringify({groups:passed.length+failures.length,passed:passed.length,failures}));
if(failures.length)process.exitCode=1;
