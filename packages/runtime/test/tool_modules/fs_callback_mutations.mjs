import fs from 'node:fs';
import { promisify } from 'node:util';
import { join } from 'node:path';
const root=process.argv[process.argv.indexOf('--root')+1];
if(!root)throw new Error('Physical fixture root required');
const file=name=>join(root,name);
let groups=0;const failures=[],doubles=[];
function equal(actual,expected){if(JSON.stringify(actual)!==JSON.stringify(expected))throw new Error('Expected '+JSON.stringify(expected)+', got '+JSON.stringify(actual));}
function code(body,expected){let error;try{body();}catch(e){error=e;}equal(error instanceof Error,true);equal(error.code,expected);}
async function check(name,body){++groups;try{await body();}catch(error){failures.push({name,message:String(error.message)});}}
function call(name,...args){return new Promise((resolve,reject)=>{let returned=false,calls=0;const result=fs[name](...args,function(...values){++calls;if(calls>1){doubles.push(name);return;}if(!returned){reject(new Error(name+' callback was synchronous'));return;}resolve(values);});equal(result,undefined);returned=true;});}
async function success(name,args,expectedCount=1){const values=await call(name,...args);if(values[0])throw values[0];equal(values.length,expectedCount);equal(values[0],null);return values[1];}
async function failure(name,args,expected){const values=await call(name,...args);equal(values[0] instanceof Error,true);equal(values[0].code,expected);return values[0];}
const methods=['readFile','writeFile','unlink','copyFile','mkdir','stat'];
await check('actual callback exports',()=>equal(methods.map(k=>typeof fs[k]),methods.map(()=>'function')));
await check('promisify still rejects unavailable functions',()=>code(()=>promisify(undefined),'ERR_INVALID_ARG_TYPE'));
await check('sync and promise aliases',()=>equal([typeof fs.unlinkSync,typeof fs.copyFileSync,typeof fs.promises.unlink,typeof fs.promises.copyFile],['function','function','function','function']));
await check('deferred text write and exact callback arity',async()=>{await success('writeFile',[file('text'),'A€\u0000B']);equal(fs.readFileSync(file('text'),'utf8'),'A€\u0000B');});
await check('binary view writes exact bytes',async()=>{const b=Uint8Array.from([7,0,255,65,8]);await success('writeFile',[file('binary'),b.subarray(1,4)]);equal(Array.from(fs.readFileSync(file('binary'))),[0,255,65]);});
await check('write flags captured before deferred IO',async()=>{fs.writeFileSync(file('append'),'FIRST');const opts={flag:'a'};const done=success('writeFile',[file('append'),'SECOND',opts]);opts.flag='w';await done;equal(fs.readFileSync(file('append'),'utf8'),'FIRSTSECOND');});
await check('write exclusive error leaves old bytes',async()=>{await failure('writeFile',[file('append'),'BAD',{flag:'wx'}],'EEXIST');equal(fs.readFileSync(file('append'),'utf8'),'FIRSTSECOND');});
await check('write missing parent reports real failure',async()=>{const e=await failure('writeFile',[file('absent/x'),'BAD'],'ENOENT');equal(e.path,file('absent/x'));});
await check('borrowed descriptor offset and lifetime',async()=>{const fd=fs.openSync(file('descriptor'),'w+');try{await success('writeFile',[fd,'A']);fs.writeFileSync(fd,'B');}finally{fs.closeSync(fd);}equal(fs.readFileSync(file('descriptor'),'utf8'),'AB');});
await check('null write options mean defaults',async()=>{await success('writeFile',[file('null'),'OK',null]);equal(fs.readFileSync(file('null'),'utf8'),'OK');});
await check('default mkdir callback arity',async()=>{await success('mkdir',[file('dir')]);equal(fs.statSync(file('dir')).isDirectory(),true);});
await check('recursive mkdir first-created path',async()=>equal(await success('mkdir',[file('tree/a/b'),{recursive:true}],2),file('tree')));
await check('existing recursive mkdir returns undefined',async()=>equal(await success('mkdir',[file('tree/a/b'),{recursive:true}],1),undefined));
await check('numeric mkdir mode',async()=>{await success('mkdir',[file('mode-number'),0o750]);equal(fs.statSync(file('mode-number')).mode&0o777,0o750);});
await check('string mkdir mode',async()=>{await success('mkdir',[file('mode-string'),'750']);equal(fs.statSync(file('mode-string')).mode&0o777,0o750);});
await check('mkdir file collision',()=>failure('mkdir',[file('text')],'EEXIST'));
await check('mkdir missing parent',()=>failure('mkdir',[file('missing/x')],'ENOENT'));
await check('mkdir existing directory',()=>failure('mkdir',[file('dir')],'EEXIST'));
await check('mkdir option snapshot',async()=>{const opts={recursive:true,mode:0o750};const done=success('mkdir',[file('captured/a'),opts],2);opts.recursive=false;opts.mode=0o700;equal(await done,file('captured'));equal(fs.statSync(file('captured/a')).mode&0o777,0o750);});
await check('unlink actually removes file',async()=>{fs.writeFileSync(file('delete'),'BYTES');await success('unlink',[file('delete')]);equal(fs.existsSync(file('delete')),false);});
await check('unlink missing path error',async()=>{const e=await failure('unlink',[file('missing')],'ENOENT');equal([e.syscall,e.path],['unlink',file('missing')]);});
await check('unlink removes symlink entry only',async()=>{await success('unlink',[file('unlink-link')]);equal(fs.readFileSync(file('unlink-target'),'utf8'),'KEEP');equal(fs.existsSync(file('unlink-link')),false);});
await check('unlink does not delete directories',async()=>{await failure('unlink',[file('dir')],process.platform==='darwin'?'EPERM':'EISDIR');equal(fs.statSync(file('dir')).isDirectory(),true);});
await check('stream real source bytes to new file',async()=>{await success('copyFile',[file('source.bin'),file('fresh-copy')]);equal(fs.statSync(file('fresh-copy')).size,fs.statSync(file('source.bin')).size);});
await check('existing destination inode and hardlinks survive',async()=>{const inode=fs.statSync(file('dest')).ino;await success('copyFile',[file('source.bin'),file('dest')]);equal(fs.statSync(file('dest')).ino,inode);equal(fs.statSync(file('dest-alias')).size,fs.statSync(file('source.bin')).size);});
await check('destination symlink followed without replacement',async()=>{await success('copyFile',[file('source.bin'),file('destination-link')]);equal(fs.lstatSync(file('destination-link')).isSymbolicLink(),true);equal(fs.statSync(file('destination-target')).size,fs.statSync(file('source.bin')).size);});
await check('same filename is a no-op',async()=>{await success('copyFile',[file('source.bin'),file('source.bin')]);equal(fs.statSync(file('source.bin')).size,1048593);});
await check('source hardlink alias is a no-op',async()=>{await success('copyFile',[file('source.bin'),file('source-alias')]);equal(fs.statSync(file('source-alias')).size,1048593);});
await check('exclusive copy leaves destination untouched',async()=>{await failure('copyFile',[file('source.bin'),file('exclusive-old'),fs.constants.COPYFILE_EXCL],'EEXIST');equal(fs.readFileSync(file('exclusive-old'),'utf8'),'UNCHANGED');});
await check('exclusive copy creates actual destination',()=>success('copyFile',[file('source.bin'),file('exclusive-new'),fs.constants.COPYFILE_EXCL]));
await check('missing copy source',async()=>{const e=await failure('copyFile',[file('not-present'),file('not-created')],'ENOENT');equal([e.syscall,e.path,e.dest],['copyfile',file('not-present'),file('not-created')]);equal(fs.existsSync(file('not-created')),false);});
await check('missing copy destination parent',()=>failure('copyFile',[file('source.bin'),file('not-dir/x')],'ENOENT'));
await check('copy rejects source directory',()=>failure('copyFile',[file('dir'),file('not-copy-dir')],process.platform==='darwin'?'ENOTSUP':'EISDIR'));
await check('copy rejects destination directory',()=>failure('copyFile',[file('source.bin'),file('dir')],'EISDIR'));
await check('real copy constants',()=>equal([fs.constants.COPYFILE_EXCL,fs.constants.COPYFILE_FICLONE,fs.constants.COPYFILE_FICLONE_FORCE],[1,2,4]));
await check('sync unlink',()=>{fs.writeFileSync(file('sync-delete'),'D');equal(fs.unlinkSync(file('sync-delete')),undefined);equal(fs.existsSync(file('sync-delete')),false);});
await check('sync copy',()=>{equal(fs.copyFileSync(file('source.bin'),file('sync-copy')),undefined);equal(fs.statSync(file('sync-copy')).size,1048593);});
await check('promise aliases execute actual mutations',async()=>{equal(await fs.promises.copyFile(file('source.bin'),file('promise-copy')),undefined);equal(await fs.promises.unlink(file('promise-copy')),undefined);equal(fs.existsSync(file('promise-copy')),false);});
await check('promisified mutations execute real IO',async()=>{const mkdir=promisify(fs.mkdir),write=promisify(fs.writeFile),copy=promisify(fs.copyFile),unlink=promisify(fs.unlink);equal(await mkdir(file('promisified')),undefined);equal(await write(file('promisified/a'),'REAL\0IO'),undefined);equal(await copy(file('promisified/a'),file('promisified/b')),undefined);equal(await unlink(file('promisified/a')),undefined);equal(fs.readFileSync(file('promisified/b'),'utf8'),'REAL\0IO');});
await check('missing callbacks reject synchronously',()=>{for(const [name,args]of [['writeFile',[file('no-callback'),'x']],['mkdir',[file('no-callback-dir')]],['unlink',[file('missing')]],['copyFile',[file('source.bin'),file('no-copy')]]])code(()=>fs[name](...args),'ERR_INVALID_ARG_TYPE');});
await check('bad callback paths reject synchronously',()=>{for(const [name,args]of [['writeFile',[null,'x',()=>{}]],['mkdir',[null,()=>{}]],['unlink',[null,()=>{}]],['copyFile',[null,file('no-copy'),()=>{}]]])code(()=>fs[name](...args),'ERR_INVALID_ARG_TYPE');});
await check('invalid write data rejects before scheduling',()=>{for(const v of [null,{},42])code(()=>fs.writeFile(file('invalid-data'),v,()=>{}),'ERR_INVALID_ARG_TYPE');});
await check('copy flag truncation and validation',async()=>{code(()=>fs.copyFile(file('source.bin'),file('bad-mode'),'0',()=>{}),'ERR_INVALID_ARG_TYPE');for(const v of [-1,8,NaN,Infinity])code(()=>fs.copyFile(file('source.bin'),file('bad-mode'),v,()=>{}),'ERR_OUT_OF_RANGE');await success('copyFile',[file('source.bin'),file('fractional-mode'),1.5]);});
await new Promise(resolve=>setTimeout(resolve,0));
console.log('FS MUTATION RESULTS '+JSON.stringify({groups,passed:groups-failures.length,failures,doubleCallbacks:doubles}));
if(groups!==43||failures.length||doubles.length)throw new Error('Filesystem mutation checks failed');
if(process.argv.includes('--home-profile')){for(const mode of [2,3,4,5,6,7])code(()=>fs.copyFile(file('source.bin'),file('unimplemented-clone'),mode,()=>{}),'ERR_HOME_UNSUPPORTED');console.log('HOME FS MUTATION PROFILE REAL OWNER-TASK IO; REFLINK FLAGS AND NONREGULAR COPY UNAVAILABLE');}
console.log('FS MUTATION 43 GROUPS OK');
