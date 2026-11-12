import tty, { WriteStream } from 'node:tty';
import { Writable } from 'node:stream';
import { createRequire } from 'node:module';
import { readFileSync,readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
const require=createRequire(import.meta.url);
const fdDirectory=process.platform==='linux'?'/proc/self/fd':'/dev/fd';
readdirSync(fdDirectory);
const fdBefore=readdirSync(fdDirectory).length;
const stream=new WriteStream(1);
const fdDuring=readdirSync(fdDirectory).length;
const size=stream.getWindowSize();
let groups=0;const failures=[];
function equal(actual,expected){if(JSON.stringify(actual)!==JSON.stringify(expected))throw new Error('Expected '+JSON.stringify(expected)+', got '+JSON.stringify(actual));}
async function check(name,body){++groups;try{await body();}catch(error){failures.push({name,message:String(error.message)});}}
function errorCode(body,code){let error;try{body();}catch(e){error=e;}equal(error instanceof Error,true);equal(error.code,code);}
await check('shared aliases',()=>equal(require('tty')===require('node:tty'),true));
await check('named export identity',()=>equal(WriteStream===tty.WriteStream,true));
await check('real writable inheritance',()=>equal(stream instanceof Writable,true));
await check('real terminal classification',()=>equal([tty.isatty(1),tty.isatty(0),stream.isTTY],[true,false,true]));
await check('descriptor classification rejects coercion',()=>{for(const x of ['1',null,{},1.5,-1,Symbol('fd')])equal(tty.isatty(x),false);});
await check('no artificial public descriptor field',()=>equal(stream.fd,undefined));
await check('size fields',()=>equal(size,[stream.columns,stream.rows]));
await check('window size copy',()=>{const s=stream.getWindowSize();s[0]=-1;equal(stream.getWindowSize(),size);});
await check('no-color environment',()=>equal(stream.getColorDepth({}),1));
await check('color threshold',()=>equal([stream.hasColors(2,{}),stream.hasColors(16,{})],[true,false]));
await check('forced color depth',()=>equal([stream.getColorDepth({FORCE_COLOR:'2'}),stream.getColorDepth({FORCE_COLOR:'3'})],[8,24]));
await check('case-sensitive prefix and lowercase fallback',()=>equal(stream.getColorDepth({TERM:'XTERM-256COLOR'}),4));
await check('invalid environment',()=>{let e;try{stream.getColorDepth(null);}catch(x){e=x;}equal(e instanceof TypeError,true);});
await check('invalid color count types',()=>{for(const v of [null,'16',true])errorCode(()=>stream.hasColors(v,{}),'ERR_INVALID_ARG_TYPE');});
await check('invalid color count ranges',()=>{for(const v of [1,1.5,NaN,Infinity])errorCode(()=>stream.hasColors(v,{}),'ERR_OUT_OF_RANGE');});
await check('invalid descriptor types and ranges',()=>{for(const fd of [-1,1.5,'1',NaN])errorCode(()=>new WriteStream(fd),'ERR_INVALID_FD');});
await check('invalid native descriptor',()=>errorCode(()=>new WriteStream(999999),'ERR_TTY_INIT_FAILED'));
await check('native hooks are private',()=>equal([typeof globalThis.__home_tool_tty_factory,typeof globalThis.__home_tool_tty_colors_factory,typeof globalThis.__home_tool_tty_size],['undefined','undefined','undefined']));
await check('writable state before output',()=>equal([stream.writable,stream.destroyed,stream.writableEnded],[true,false,false]));
await check('UTF8 write and deferred acknowledgement',()=>new Promise((resolve,reject)=>{let returned=false;const accepted=stream.write('TTY €😀\n',error=>{try{if(error)throw error;equal(returned,true);resolve();}catch(e){reject(e);}});equal(typeof accepted,'boolean');returned=true;}));
await check('actual binary output',()=>new Promise((resolve,reject)=>stream.write(Buffer.from([0,255,65]),error=>error?reject(error):resolve())));
await check('actual cursor position',()=>new Promise((resolve,reject)=>stream.cursorTo(3,2,error=>error?reject(error):resolve())));
await check('actual cursor motion',()=>new Promise((resolve,reject)=>stream.moveCursor(-2,1,error=>error?reject(error):resolve())));
await check('actual clear line',()=>new Promise((resolve,reject)=>stream.clearLine(0,error=>error?reject(error):resolve())));
await check('actual clear screen',()=>new Promise((resolve,reject)=>stream.clearScreenDown(error=>error?reject(error):resolve())));
await check('native explicit refresh without spurious resize',()=>{let changes=0;const listener=()=>changes++;stream.on('resize',listener);stream._refreshSize();stream.removeListener('resize',listener);equal([stream.getWindowSize(),changes],[size,0]);});
const closed=new Promise(resolve=>stream.once('close',resolve));
await check('actual end acknowledgement',()=>new Promise((resolve,reject)=>{equal(stream.end('END\n',error=>error?reject(error):resolve()),stream);}));
await check('real destruction and close event',async()=>{stream.destroy();await closed;equal([stream.destroyed,stream.closed],[true,true]);});
await check('closed stream refuses output',()=>new Promise((resolve,reject)=>{const accepted=stream.write('NEVER',error=>{try{equal(error.code,'ERR_STREAM_WRITE_AFTER_END');resolve();}catch(e){reject(e);}});equal(accepted,false);}));
const oracle=JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)),'tty_color_oracle.json'),'utf8'));
const mismatches=[];
for(let i=0;i<oracle.cases.length;++i){const row=oracle.cases[i];const actual={depth:tty.WriteStream.prototype.getColorDepth(row.env),colors:oracle.counts.map(n=>tty.WriteStream.prototype.hasColors(n,row.env))};if(JSON.stringify(actual)!==JSON.stringify({depth:row.depth,colors:row.colors}))mismatches.push({index:i,env:row.env,expected:{depth:row.depth,colors:row.colors},actual});}
console.error('TTY STREAM RESULTS '+JSON.stringify({groups,passed:groups-failures.length,failures}));
console.error('TTY COLOR ORACLE RESULTS '+JSON.stringify({node:oracle.node,cases:oracle.cases.length,mismatches:mismatches.length,first:mismatches.slice(0,4)}));
console.error('TTY NATIVE WINDOW '+JSON.stringify({columns:size[0],rows:size[1],originalStillTerminal:tty.isatty(1)}));
if(process.argv.includes('--home-profile')){errorCode(()=>new WriteStream(1,{}),'ERR_HOME_UNSUPPORTED');equal(tty.isatty(1),true);equal(fdDuring,fdBefore+1);equal(readdirSync(fdDirectory).length,fdBefore);console.error('HOME TTY PROFILE OWNED DUPLICATE CLOSED; CALLER FD RETAINED; OPTIONS REFUSED; READ/RAW/AUTOMATIC RESIZE UNAVAILABLE');}
if(groups!==29||failures.length||mismatches.length)throw new Error('TTY stream execution failed');
