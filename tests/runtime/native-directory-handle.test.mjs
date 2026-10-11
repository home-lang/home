import assert from 'node:assert/strict'
import * as fs from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { spawnSync } from 'node:child_process'
import { Worker } from 'node:worker_threads'
import { createHook, executionAsyncId, executionAsyncResource } from 'node:async_hooks'

{
const base=fs.mkdtempSync(join(tmpdir(),'home-directory-identity-'))
try {
 for(const mode of ['sync','async']) {
  const path=join(base,mode), moved=path+'-moved'
  fs.mkdirSync(path);fs.writeFileSync(join(path,'entry.txt'),'entry')
  const dir=mode==='sync'?fs.opendirSync(path):await fs.promises.opendir(path)
  fs.renameSync(path,moved)
  fs.mkdirSync(path);fs.writeFileSync(join(path,'replacement.txt'),'replacement')
  const entries=[]
  for(;;){const entry=mode==='sync'?dir.readSync():await dir.read();if(!entry)break;assert(entry instanceof fs.Dirent);entries.push(entry.name);assert(entry.isFile())}
  assert.deepEqual(entries,['entry.txt'])
  assert.equal(dir.path,path)
  if(mode==='sync')dir.closeSync();else await dir.close()
  assert.throws(()=>dir.readSync(),{code:'ERR_DIR_CLOSED'})
 }
 console.log('opened directory identity survives rename and replacement for sync and async reads')
} finally {fs.rmSync(base,{recursive:true,force:true})}
}

{
const base=fs.realpathSync(fs.mkdtempSync(join(tmpdir(),'home-directory-lifecycle-')))
const tick=()=>new Promise(resolve=>setImmediate(resolve))
const warnings=[]
process.on('warning',warning=>{if(warning.message==='Closing directory handle on garbage collection')warnings.push(warning.message)})
function ownedDescriptors(){
 const result=spawnSync('/usr/sbin/lsof',['-a','-p',String(process.pid),'-Fn'],{encoding:'utf8'})
 assert.equal(result.status,0)
 return result.stdout.split('\n').filter(line=>line.startsWith('n'+base))
}
async function list(dir,sync){
 const entries=[]
 for(;;){const entry=sync?dir.readSync():await dir.read();if(entry===null)break;assert(entry instanceof fs.Dirent);entries.push(entry)}
 return entries
}
try {
 const plain=join(base,'plain');fs.mkdirSync(plain)
 fs.writeFileSync(join(plain,'first.txt'),'first');fs.writeFileSync(join(plain,'é.txt'),'unicode')
 for(const bufferSize of [1,3,32]){
  const dir=fs.opendirSync(plain,{bufferSize});assert.equal(ownedDescriptors().length,1)
  assert.deepEqual((await list(dir,true)).map(entry=>entry.name).sort(),['first.txt','é.txt'])
  assert.equal(dir.readSync(),null);dir.closeSync();assert.equal(ownedDescriptors().length,0)
 }
 const urlDir=await fs.promises.opendir(pathToFileURL(plain));assert.equal(urlDir.path,plain);await urlDir.close()
 const bytes=Buffer.from(plain)
 const bufferDir=fs.opendirSync(bytes,{encoding:'buffer',bufferSize:1});assert.equal(bufferDir.path,bytes)
 const encoded=bufferDir.readSync();assert(Buffer.isBuffer(encoded.name));assert(Buffer.isBuffer(encoded.parentPath));assert.deepEqual(encoded.parentPath,bytes)
 bufferDir.closeSync()
 const tree=join(base,'tree');fs.mkdirSync(tree);fs.mkdirSync(join(tree,'child'));fs.writeFileSync(join(tree,'root.txt'),'root');fs.writeFileSync(join(tree,'child','nested.txt'),'nested');fs.symlinkSync(join(tree,'child'),join(tree,'link'))
 for(const sync of [true,false]){
  const dir=sync?fs.opendirSync(tree,{recursive:true,bufferSize:1}):await fs.promises.opendir(tree,{recursive:true,bufferSize:1})
  const entries=await list(dir,sync)
  assert.deepEqual(entries.map(entry=>entry.name).sort(),['child','link','nested.txt','root.txt'])
  assert.equal(entries.find(entry=>entry.name==='nested.txt').parentPath,join(tree,'child'))
  assert(entries.find(entry=>entry.name==='child').isDirectory());assert(entries.find(entry=>entry.name==='link').isSymbolicLink())
  if(sync)dir.closeSync();else await dir.close()
 }
 const captureA=join(base,'capture-a'), captureB=join(base,'capture-b')
 fs.mkdirSync(captureA);fs.mkdirSync(captureB);fs.writeFileSync(join(captureA,'original.txt'),'original');fs.writeFileSync(join(captureB,'other.txt'),'other')
 const mutable=Buffer.from(captureA)
 const opening=fs.promises.opendir(mutable)
 Buffer.from(captureB).copy(mutable)
 const captured=await opening
 assert.deepEqual((await list(captured,false)).map(entry=>entry.name),['original.txt'])
 await captured.close()
 const early=await fs.promises.opendir(plain)
 for await(const entry of early){assert(entry instanceof fs.Dirent);break}
 assert.throws(()=>early.readSync(),{code:'ERR_DIR_CLOSED'})
 assert.equal(ownedDescriptors().length,0)
 const queued=await fs.promises.opendir(plain,{bufferSize:1});const pending=queued.read();assert.throws(()=>queued.readSync(),{code:'ERR_DIR_CONCURRENT_OPERATION'});const closed=queued.close();assert(await pending);await closed
 assert.throws(()=>queued.readSync(),{code:'ERR_DIR_CLOSED'});assert.equal(ownedDescriptors().length,0)
 function abandon(){fs.opendirSync(plain)}
 abandon();assert.equal(ownedDescriptors().length,1)
 const gc=globalThis.Bun?.gc ?? globalThis.gc;assert.equal(typeof gc,'function')
 for(let i=0;i<3 && ownedDescriptors().length;i++){await tick();gc(true);await tick()}
 assert.equal(ownedDescriptors().length,0,'unreferenced directory descriptors close during GC')
 await tick()
 assert.deepEqual(warnings,['Closing directory handle on garbage collection'])
 const worker=new Worker(`const fs=require('node:fs');const {parentPort,workerData}=require('node:worker_threads');globalThis.directory=fs.opendirSync(workerData);parentPort.on('message',()=>{});parentPort.postMessage('opened')`,{eval:true,workerData:plain})
 await new Promise((resolve,reject)=>{worker.once('message',resolve);worker.once('error',reject)})
 assert.equal(ownedDescriptors().length,1)
 await worker.terminate();assert.equal(ownedDescriptors().length,0,'worker teardown retires owned descriptors')
 console.log('native directories stream entries, preserve encodings and recursion, serialize operations, and close on explicit close, iteration exit, GC and worker shutdown')
} finally {fs.rmSync(base,{recursive:true,force:true})}
}

// Native request completion and buffered callbacks preserve their API scopes.
{
const base=fs.mkdtempSync(join(tmpdir(),'home-directory-callbacks-'))
for(const name of ['a','b','c','d'])fs.writeFileSync(join(base,name),name)
const tick=()=>new Promise(resolve=>setImmediate(resolve))
try {
 const invalid=fs.opendirSync(base)
 assert.throws(()=>invalid.read(null),{code:'ERR_INVALID_ARG_TYPE'})
 assert.throws(()=>invalid.close(null),{code:'ERR_INVALID_ARG_TYPE'})
 invalid.closeSync()
 assert.throws(()=>invalid.read(()=>assert.fail('closed read callback must not run')),{code:'ERR_DIR_CLOSED'})
 assert.throws(()=>invalid.read(undefined),{code:'ERR_DIR_CLOSED'})
 await assert.rejects(invalid.read(),{code:'ERR_DIR_CLOSED'})
 await new Promise(resolve=>{let sync=true;const returned=invalid.close(function(error){assert.equal(sync,false);assert.equal(this,undefined);assert.equal(arguments.length,1);assert.equal(error.code,'ERR_DIR_CLOSED');resolve()});assert.equal(returned,undefined);sync=false})
 const dir=fs.opendirSync(base,{bufferSize:32})
 const requests=[]
 const hook=createHook({init(id,type,trigger,owner){if(type.startsWith('FSREQ'))requests.push({id,type,owner})}}).enable()
 let first
 try {
  await new Promise((resolve,reject)=>{let sync=true;const returned=dir.read(function(error,entry){try{assert.equal(sync,false);assert.equal(this,undefined);assert.equal(arguments.length,2);assert.equal(error,null);first=entry;assert.equal(requests.length,1);assert.equal(requests[0].type,'FSREQCALLBACK');assert.equal(executionAsyncId(),requests[0].id);assert.equal(executionAsyncResource(),requests[0].owner);resolve()}catch(error){reject(error)}});assert.equal(returned,undefined);sync=false})
  await tick()
  const count=requests.length
  await new Promise((resolve,reject)=>{let sync=true;let immediate;const returned=dir.read(function(error,entry){try{assert.equal(sync,false);assert.equal(this,undefined);assert.equal(error,null);assert.notEqual(entry.name,first.name);assert.notEqual(entry.name,immediate.name);assert.equal(requests.length,count);resolve()}catch(error){reject(error)}});assert.equal(returned,undefined);immediate=dir.readSync();sync=false})
 } finally {hook.disable();await dir.close()}
 const closing=fs.opendirSync(base)
 const closed=new Promise((resolve,reject)=>{const returned=closing.close(function(error){try{assert.equal(this,executionAsyncResource());assert.equal(this.constructor.name,'FSReqCallback');assert.equal(arguments.length,1);assert.equal(error,null);resolve()}catch(error){reject(error)}});assert.equal(returned,undefined)})
 assert.throws(()=>closing.readSync(),{code:'ERR_DIR_CLOSED'})
 await closed
 const errors=fs.opendirSync(base,{bufferSize:1});const marker=new Error('ordinary callback exception');const calls=[];let finish
 const done=new Promise(resolve=>{finish=resolve})
 errors.read(function(error,entry){calls.push([error,entry]);if(calls.length===1)throw marker;assert.equal(arguments.length,1);assert.equal(error,marker);assert.equal(entry,undefined);errors.close(()=>finish())})
 await done
 assert.equal(calls.length,2);assert.equal(calls[0][0],null);assert(calls[0][1] instanceof fs.Dirent)
 console.log('directory callback validation, receivers, argument counts, resource scope, buffered scheduling, close state and exception routing passed')
} finally {fs.rmSync(base,{recursive:true,force:true})}
}

// Callback exceptions preserve uncaught delivery on buffered and close paths.
{
const base=fs.mkdtempSync(join(tmpdir(),'home-directory-callback-errors-'))
for(const name of ['a','b','c'])fs.writeFileSync(join(base,name),name)
try {
 for(const operation of ['cached-read','close']){
  const dir=fs.opendirSync(base,{bufferSize:32})
  if(operation==='cached-read')assert(dir.readSync())
  const marker=new Error(operation+' callback marker')
  const events=[];let calls=0;let finish
  const done=new Promise(resolve=>{finish=resolve})
  function uncaught(error){assert.equal(error,marker);events.push('uncaught');if(operation==='cached-read')dir.closeSync();finish()}
  function rejection(error){events.push('rejection');if(operation==='cached-read')dir.closeSync();finish()}
  process.once('uncaughtException',uncaught);process.once('unhandledRejection',rejection)
  const cb=function(){calls++;throw marker}
  if(operation==='cached-read')dir.read(cb);else dir.close(cb)
  await done
  process.removeListener('uncaughtException',uncaught);process.removeListener('unhandledRejection',rejection)
  assert.deepEqual(events,['uncaught']);assert.equal(calls,1)
  assert.throws(()=>dir.readSync(),{code:'ERR_DIR_CLOSED'})
 }
 console.log('cached read and native close callback exceptions reach uncaughtException exactly once')
} finally {fs.rmSync(base,{recursive:true,force:true})}
}
