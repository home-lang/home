import fs from 'node:fs';
import os from 'node:os';
import constants from 'node:constants';
import { join } from 'node:path';
const root=process.argv[process.argv.indexOf('--root')+1];
if(!root)throw new Error('Physical fixture root required');
let groups=0;const failures=[];
function equal(actual,expected){if(JSON.stringify(actual)!==JSON.stringify(expected))throw new Error('Expected '+JSON.stringify(expected)+', got '+JSON.stringify(actual));}
function check(name,body){++groups;try{body();}catch(error){failures.push({name,message:String(error.message)});}}
function caught(body){let error;try{body();}catch(e){error=e;}if(!(error instanceof Error))throw new Error('Expected real error');return error;}
let binding;
check('actual binding function',()=>equal(typeof process.binding,'function'));
check('constants lookup',()=>{binding=process.binding('constants');equal(typeof binding,'object');});
check('binding cache identity',()=>equal(process.binding('constants')===binding,true));
check('filesystem alias identity',()=>equal(binding.fs===fs.constants,true));
check('OS alias identity',()=>equal(binding.os===os.constants,true));
check('native errno namespace',()=>{for(const key of ['EBADF','ENOENT','EEXIST','EACCES','EINVAL','ENOMEM','EINTR','ENOTDIR','EISDIR','ENOSPC'])equal(Number.isInteger(os.constants.errno[key])&&os.constants.errno[key]>0,true);});
check('positive integer errno values',()=>{for(const key of Object.keys(os.constants.errno)){equal(key.startsWith('E'),true);equal(Number.isInteger(os.constants.errno[key])&&os.constants.errno[key]>0,true);}});
check('legacy errno aliases',()=>{for(const key of Object.keys(os.constants.errno))equal(constants[key],os.constants.errno[key]);});
check('legacy filesystem aliases',()=>{for(const key of ['O_CREAT','O_EXCL','O_RDWR','S_IFMT','S_IFREG','F_OK'])equal(constants[key],fs.constants[key]);});
check('private root has null prototype',()=>equal(Object.getPrototypeOf(binding),null));
check('OS namespaces have null prototypes',()=>{equal(Object.getPrototypeOf(os.constants),null);equal(Object.getPrototypeOf(os.constants.errno),null);});
check('errno entries are immutable',()=>{const d=Object.getOwnPropertyDescriptor(os.constants.errno,'ENOENT');equal([d.writable,d.enumerable,d.configurable],[false,true,false]);caught(()=>{os.constants.errno.ENOENT=12345;});});
check('public OS constants property descriptor',()=>{const d=Object.getOwnPropertyDescriptor(os,'constants');equal([d.writable,d.enumerable,d.configurable],[false,true,false]);});
check('binding function descriptor',()=>{const d=Object.getOwnPropertyDescriptor(process,'binding');equal([d.writable,d.enumerable,d.configurable],[true,true,true]);equal([process.binding.name,process.binding.length],['binding',1]);});
check('actual closed descriptor errno',()=>{const fd=fs.openSync(join(root,'descriptor'),'w');fs.closeSync(fd);const e=caught(()=>fs.closeSync(fd));equal([e.code,e.errno],['EBADF',-os.constants.errno.EBADF]);});
check('actual missing file errno',()=>{const e=caught(()=>fs.unlinkSync(join(root,'missing')));equal([e.code,e.errno],['ENOENT',-os.constants.errno.ENOENT]);});
check('actual exclusive creation errno',()=>{const path=join(root,'exclusive');fs.writeFileSync(path,'KEEP',{flag:'wx'});const e=caught(()=>fs.writeFileSync(path,'BAD',{flag:'wx'}));equal([e.code,e.errno],['EEXIST',-os.constants.errno.EEXIST]);equal(fs.readFileSync(path,'utf8'),'KEEP');});
check('temporary file native flags',()=>{const c=binding;equal((c.fs.O_CREAT|c.fs.O_EXCL|c.fs.O_RDWR),(fs.constants.O_CREAT|fs.constants.O_EXCL|fs.constants.O_RDWR));});
console.log('NATIVE CONSTANTS RESULTS '+JSON.stringify({groups,passed:groups-failures.length,failures}));
if(groups!==18||failures.length)throw new Error('Native constants checks failed');
const errno={};for(const key of Object.keys(os.constants.errno).sort())errno[key]=os.constants.errno[key];
console.log('NATIVE CONSTANTS SNAPSHOT '+JSON.stringify({errno,flags:{O_CREAT:binding.fs.O_CREAT,O_EXCL:binding.fs.O_EXCL,O_RDWR:binding.fs.O_RDWR}}));
if(process.argv.includes('--home-profile')){for(const name of ['buffer','fs','os','util','uv','crypto','zlib','natives','tty_wrap',undefined,null,42])equal(caught(()=>process.binding(name)).code,'ERR_HOME_UNSUPPORTED');for(const key of ['crypto','zlib','trace','internal'])equal(Object.hasOwn(binding,key),false);equal(Object.hasOwn(globalThis,'__home_tool_errno_constants'),false);console.log('HOME NATIVE CONSTANTS PROFILE REAL FS/OS ERRNO ONLY; OTHER PRIVATE BINDINGS UNAVAILABLE');}
console.log('NATIVE CONSTANTS 18 GROUPS OK');
