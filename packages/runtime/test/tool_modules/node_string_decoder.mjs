import { StringDecoder } from 'node:string_decoder';
import bareDecoder from 'string_decoder';
import { createRequire, isBuiltin } from 'node:module';
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
const require = createRequire(import.meta.url);
const failures = [];
let groups = 0;
function equal(actual, expected) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error('Expected '+JSON.stringify(expected)+', got '+JSON.stringify(actual));
}
function check(name, body) { ++groups; try { body(); } catch(error) { failures.push({name,message:String(error.message)}); } }
function coded(body, code) { let error; try {body();} catch(caught) {error=caught;} equal(error instanceof TypeError,true); equal(error.code,code); }
check('real aliases',()=>{equal(require('string_decoder').StringDecoder===StringDecoder,true);equal(bareDecoder.StringDecoder===StringDecoder,true);});
check('shared namespace',()=>equal(require('string_decoder')===require('node:string_decoder'),true));
check('builtin classification',()=>{equal([isBuiltin('string_decoder'),isBuiltin('node:string_decoder'),isBuiltin('fs'),isBuiltin('not-a-builtin'),isBuiltin('node:node:fs'),isBuiltin('bun:test')],[true,true,true,false,false,false]);equal(isBuiltin({toString(){throw new Error('must not coerce');}}),false);});
check('UTF8 split euro',()=>{const d=new StringDecoder();equal([d.write(Buffer.from([226,130])),d.end(Buffer.from([172]))],['','€']);});
check('UTF8 scalar byte writes',()=>{const d=new StringDecoder();equal([240,159,152,128].map(x=>d.write(Buffer.from([x]))).concat(d.end()),['','','','😀','']);});
check('malformed prefix flush',()=>{const d=new StringDecoder();equal([d.write(Buffer.from([224,128])),d.end()],['','��']);});
check('reuse after end',()=>{const d=new StringDecoder();equal([d.write(Buffer.from([226])),d.end(),d.write(Buffer.from([65])),d.end()],['','�','A','']);});
check('UTF16LE scalar chunks',()=>{const d=new StringDecoder('utf16le');equal([d.write(Buffer.from([0,216])),d.end(Buffer.from([0,220]))],['','𐀀']);});
check('UTF16LE lone code unit',()=>{const d=new StringDecoder('ucs2');equal(d.end(Buffer.from([0,216])),'\ud800');});
check('UTF16LE odd byte',()=>equal(new StringDecoder('utf16le').end(Buffer.from([65])),''));
check('base64 carry',()=>{const d=new StringDecoder('base64');equal([d.write(Buffer.from([255])),d.write(Buffer.from([254])),d.write(Buffer.from([253])),d.end()],['','','//79','']);});
check('base64url carry',()=>{const d=new StringDecoder('base64url');equal([d.write(Buffer.from([255])),d.end()],['','_w']);});
check('ASCII mask',()=>equal(new StringDecoder('ascii').end(Buffer.from([255,65])),'\x7fA'));
check('Latin1 bytes',()=>equal(new StringDecoder('latin1').end(Buffer.from([0,128,255])),'\x00\x80ÿ'));
check('hex bytes',()=>equal(new StringDecoder('hex').end(Buffer.from([0,128,255])),'0080ff'));
check('typed byte ranges',()=>{const all=Uint8Array.from([0,65,66,0]);equal(new StringDecoder().end(new DataView(all.buffer,1,2)),'AB');equal(new StringDecoder().end(all.subarray(1,3)),'AB');});
check('pending bytes copied',()=>{const d=new StringDecoder();const input=Buffer.from([226,130]);equal(d.write(input),'');input.fill(65);equal(d.end(Buffer.from([172])),'€');});
check('encoding property is metadata',()=>{const d=new StringDecoder('hex');d.encoding='utf8';equal(d.end(Buffer.from([65])),'41');});
check('strings preserve pending',()=>{const d=new StringDecoder();equal([d.write(Buffer.from([226])),d.write('X'),d.end(Buffer.from([130,172]))],['','X','€']);});
check('invalid inputs',()=>{for(const value of [null,undefined,42,{},[65],new ArrayBuffer(1)])coded(()=>new StringDecoder().write(value),'ERR_INVALID_ARG_TYPE');});
check('unknown encodings',()=>{for(const value of [false,0,1,{},'raw','wat'])coded(()=>new StringDecoder(value),'ERR_UNKNOWN_ENCODING');});
check('encoding aliases',()=>equal([undefined,null,'','UTF-8','UCS-2','UTF-16LE','binary'].map(x=>new StringDecoder(x).encoding),['utf8','utf8','utf8','utf8','utf16le','utf16le','latin1']));
check('independent states',()=>{const a=new StringDecoder(),b=new StringDecoder();a.write(Buffer.from([226]));equal(b.end(Buffer.from([65])),'A');equal(a.end(Buffer.from([130,172])),'€');});
check('factory is private',()=>equal(typeof globalThis.__home_tool_string_decoder_factory,'undefined'));
check('text resets pending',()=>{const d=new StringDecoder();d.write(Buffer.from([226]));equal(d.text(Buffer.from([0,65]),1),'A');equal(d.end(),'');});
check('real pending storage',()=>{const d=new StringDecoder();d.write(Buffer.from([226]));equal([d.lastNeed,d.lastTotal,Buffer.isBuffer(d.lastChar),d.lastChar.length,d.lastChar[0]],[2,3,true,4,226]);});
check('end invalid argument',()=>coded(()=>new StringDecoder().end(null),'ERR_INVALID_ARG_TYPE'));
console.log('STRING DECODER RESULTS '+JSON.stringify({groups,passed:groups-failures.length,failures}));
const oracle = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)),'string_decoder_oracle.json'),'utf8'));
const mismatches = [];
for (let index=0;index<oracle.cases.length;++index) {
  const row=oracle.cases[index];const d=new StringDecoder(row.encoding);
  const actual=row.chunks.map(chunk=>[d.write(Buffer.from(chunk)),d.lastNeed,d.lastTotal]);
  actual.push([row.tail===null?d.end():d.end(Buffer.from(row.tail)),d.lastNeed,d.lastTotal]);
  actual.push([d.write(Buffer.from([65])),d.lastNeed,d.lastTotal]);actual.push([d.end(),d.lastNeed,d.lastTotal]);
  if(JSON.stringify(actual)!==JSON.stringify(row.expected)) mismatches.push({index,encoding:row.encoding,chunks:row.chunks,expected:row.expected,actual});
}
console.log('STRING DECODER ORACLE RESULTS '+JSON.stringify({node:oracle.node,cases:oracle.cases.length,mismatches:mismatches.length,first:mismatches.slice(0,4)}));
if(groups!==27 || failures.length || mismatches.length) throw new Error('StringDecoder execution failed');
const physical=process.argv.indexOf('--physical');
if(physical>=0) {
  const input=readFileSync(process.argv[physical+1]);const d=new StringDecoder();let result='';
  for(let i=0;i<input.length;i+=73)result+=d.write(input.subarray(i,i+73));
  result+=d.end();writeFileSync(process.argv[physical+2],result);
  console.log('STRING DECODER PHYSICAL '+input.length);
}
console.log('STRING DECODER 27 GROUPS OK');
