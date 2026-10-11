import assert from 'node:assert/strict'
import * as fs from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { spawnSync } from 'node:child_process'
import { Worker } from 'node:worker_threads'

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
