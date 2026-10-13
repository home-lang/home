import assert from 'node:assert/strict';
import vm from 'node:vm';
import { Session } from 'node:inspector/promises';
{
const context=vm.createContext({answer:41},{name:'promise-realm'});
const session=new Session();session.connect();const contexts=[];
session.on('Runtime.executionContextCreated',event=>contexts.push(event.params.context));await session.post('Runtime.enable');
const realm=contexts.find(context=>context.name==='promise-realm');assert(realm);
const promise=(await session.post('Runtime.evaluate',{expression:'Promise.resolve(answer + 1)',contextId:realm.id,objectGroup:'promise-regression'})).result;
const fake=(await session.post('Runtime.evaluate',{expression:'new (class Promise {})()',contextId:realm.id})).result;assert.notEqual(fake.subtype,'promise');
assert.equal(promise.subtype,'promise');assert.equal(typeof promise.objectId,'string');
const reply=await session.post('Runtime.awaitPromise',{promiseObjectId:promise.objectId,returnByValue:true});assert.equal(reply.result.value,42);
const object=(await session.post('Runtime.evaluate',{expression:'({answer})',contextId:realm.id,objectGroup:'promise-regression'})).result;
const called=await session.post('Runtime.callFunctionOn',{objectId:object.objectId,functionDeclaration:'async function() { return this.answer + 1; }',awaitPromise:true,returnByValue:true});assert.equal(called.result.value,42);
await session.post('Runtime.releaseObjectGroup',{objectGroup:'promise-regression'});
const pending=(await session.post('Runtime.evaluate',{expression:'new Promise(() => {})',contextId:realm.id})).result;const awaited=session.post('Runtime.awaitPromise',{promiseObjectId:pending.objectId,returnByValue:true});session.disconnect();await assert.rejects(awaited,error=>error.code==='ERR_INSPECTOR_CLOSED');assert.equal(vm.runInContext('answer',context),41);
console.log('realm promise handles and async function replies passed');
}

{
const context=vm.createContext({reads:0},{name:'accessor-realm'});
const session=new Session();session.connect();const contexts=[];
session.on('Runtime.executionContextCreated',event=>contexts.push(event.params.context));await session.post('Runtime.enable');
for(const contextId of [undefined,contexts.find(context=>context.name==='accessor-realm').id]) {
 const object=(await session.post('Runtime.evaluate',{expression:'globalThis.inspectorAccessorReads=0; ({plain:11,get accessor(){globalThis.inspectorAccessorReads++;return 22},set setter(value){}})',contextId,objectGroup:'accessor-regression'})).result;
 const all=await session.post('Runtime.getProperties',{objectId:object.objectId,ownProperties:true});assert(all.result.some(property=>property.name==='plain'));
 const accessors=await session.post('Runtime.getProperties',{objectId:object.objectId,ownProperties:true,accessorPropertiesOnly:true});assert.deepEqual(accessors.result.map(property=>property.name).sort(),['accessor','setter']);assert(accessors.result.every(property=>property.get||property.set));
 assert.equal((await session.post('Runtime.evaluate',{expression:'inspectorAccessorReads',contextId,returnByValue:true})).result.value,0);
 await assert.rejects(session.post('Runtime.getProperties',{objectId:object.objectId,accessorPropertiesOnly:'invalid'}),error=>error.code==='ERR_INSPECTOR_COMMAND'&&error.message.includes('-32602'));
}
await session.post('Runtime.releaseObjectGroup',{objectGroup:'accessor-regression'});session.disconnect();assert.equal(vm.runInContext('reads',context),0);
console.log('owner and realm accessor-only property descriptors passed');
}

{
const context=vm.createContext({},{name:'payload-realm'});const session=new Session();session.connect();const contexts=[];session.on('Runtime.executionContextCreated',event=>contexts.push(event.params.context));await session.post('Runtime.enable');
const payload={objectId:'literal-payload',promiseObjectId:'literal-promise',nested:{type:'object',objectId:'nested-payload'}};
for(const contextId of [undefined,contexts.find(context=>context.name==='payload-realm').id]) {
 const object=(await session.post('Runtime.evaluate',{expression:'({})',contextId})).result;
 const reply=await session.post('Runtime.callFunctionOn',{objectId:object.objectId,functionDeclaration:'function(argument){return argument}',arguments:[{value:payload}],returnByValue:true});assert.deepEqual(reply.result.value,payload);
 const byValue=await session.post('Runtime.evaluate',{expression:'('+JSON.stringify(payload)+')',contextId,returnByValue:true});assert.deepEqual(byValue.result.value,payload);
}
session.disconnect();assert(vm.isContext(context));console.log('literal object ID fields remain user data across inspector realms');
}
