import buffer,{Buffer} from 'node:buffer';
import {createRequire} from 'node:module';
import {writeFileSync} from 'node:fs';
const [mode,path]=process.argv.slice(2);
function assert(v,label){if(!v)throw new Error(label);}
function throws(fn){let e;try{fn();}catch(error){e=error;}assert(e,'expected failure');return e;}
const copy=Buffer.prototype.copy;
if(mode==='shared'){
  const memory=new SharedArrayBuffer(12),all=new Uint8Array(memory);all.set([0,1,2,3,4,5,6,7,8,9,10,11]);
  assert(copy.call(new Uint8Array(memory,0,8),new Uint8Array(memory,2,8),0,0,8)===8,'shared count');
  assert([...all].join(',')==='0,1,0,1,2,3,4,5,6,7,10,11','shared memmove');
  console.log('NATIVE BUFFER COPY SHARED 2 CHECKS OK');
}else if(mode==='profile'){
  const source=Buffer.from([0,1,2,3]),target=Buffer.alloc(4,0xaa);
  Object.defineProperty(source,'byteLength',{get(){throw new Error('public extent read');}});
  Object.defineProperty(target,'buffer',{get(){throw new Error('public backing read');}});
  assert(copy.call(source,target)===4&&target.toString('hex')==='00010203','native view metadata');
  console.log('HOME BUFFER COPY NATIVE METADATA PROFILE OK');
}else if(mode==='contract'){
  const labels=[],failures=[];
  function check(label,fn){try{fn();labels.push(label);}catch(error){failures.push({label,message:String(error),code:error.code});}}
  function source(){return Buffer.from([0,1,2,3,4]);}
  check('module aliases export the genuine copy method',()=>{const req=createRequire(import.meta.url);assert(req('buffer')===buffer&&req('node:buffer')===buffer&&typeof copy==='function','module identity');});
  check('whole binary copy and actual count',()=>{const s=Buffer.from([0,255,128,97,0]),d=Buffer.alloc(6,0xaa);assert(s.copy(d)===5&&d.toString('hex')==='00ff806100aa','binary bytes');});
  check('source/destination ranges preserve surrounding bytes',()=>{const d=Buffer.alloc(8,0xaa);assert(source().copy(d,2,1,4)===3&&d.toString('hex')==='aaaa010203aaaaaa','range bytes');});
  check('copy clamps to target and source physical lengths',()=>{const a=Buffer.alloc(2),b=Buffer.alloc(8,0xaa);assert(source().copy(a,0,1,99)===2&&a.toString('hex')==='0102','target clamp');assert(source().copy(b,1,3,99)===2&&b.toString('hex')==='aa0304aaaaaaaaaa','source clamp');});
  check('zero-length copies still validate target and indices',()=>{assert(Buffer.alloc(0).copy(Buffer.alloc(0))===0,'empty');assert(throws(()=>Buffer.alloc(0).copy({})).code==='ERR_INVALID_ARG_TYPE','empty target validation');assert(throws(()=>Buffer.alloc(0).copy(Buffer.alloc(0),0,0,-1)).code==='ERR_OUT_OF_RANGE','empty index validation');});
  check('out-of-range target returns zero after validating source',()=>{const d=Buffer.alloc(2,0xaa);assert(source().copy(d,999)===0&&d.toString('hex')==='aaaa','outside target');assert(throws(()=>source().copy(d,999,6,0)).code==='ERR_OUT_OF_RANGE','source validates first');});
  check('reversed and exhausted source ranges copy zero',()=>{const d=Buffer.alloc(5,0xaa);assert(source().copy(d,0,4,1)===0&&source().copy(d,0,5,5)===0&&d.toString('hex')==='aaaaaaaaaa','empty ranges');});
  check('self overlap towards higher addresses snapshots source bytes',()=>{const v=Buffer.from([0,1,2,3,4,5,6,7]);assert(v.copy(v,2,0,6)===6&&v.toString('hex')==='0001000102030405','forward memmove');});
  check('self overlap towards lower addresses snapshots source bytes',()=>{const v=Buffer.from([0,1,2,3,4,5,6,7]);assert(v.copy(v,0,2,8)===6&&v.toString('hex')==='0203040506070607','backward memmove');});
  check('different aliased ArrayBuffer views retain overlap semantics',()=>{const memory=new ArrayBuffer(10),all=new Uint8Array(memory);all.set([0,1,2,3,4,5,6,7,8,9]);const s=Buffer.from(memory,0,6),d=Buffer.from(memory,2,6);assert(s.copy(d)===6&&[...all].join(',')==='0,1,0,1,2,3,4,5,8,9','alias overlap');});
  check('borrowed Uint8Array source and target use real bytes',()=>{const d=new Uint8Array(5);assert(copy.call(new Uint8Array([0,255,128]),d,1)===3&&[...d].join(',')==='0,0,255,128,0','plain byte views');});
  check('genuine wide typed-array views copy byte representation',()=>{const raw=new Uint8Array([0,255,128,97]),d=Buffer.alloc(4);assert(copy.call(new Uint16Array(raw.buffer),d)===4&&d.toString('hex')==='00ff8061','wide source');const target=new Uint16Array(2);assert(copy.call(raw,target)===4&&[...new Uint8Array(target.buffer)].join(',')==='0,255,128,97','wide target');});
  check('DataView source and target copy only their visible windows',()=>{const raw=new Uint8Array([99,0,255,128,77]),d=Buffer.alloc(5,0xaa);assert(copy.call(new DataView(raw.buffer,1,3),d,1)===3&&d.toString('hex')==='aa00ff80aa','DataView source');const output=new Uint8Array([9,9,9,9,9]);assert(copy.call(new Uint8Array([0,255,128]),new DataView(output.buffer,1,3))===3&&[...output].join(',')==='9,0,255,128,9','DataView target');});
  check('constructor species and public set/subarray hooks are not invoked',()=>{const s=source(),d=Buffer.alloc(5);s.constructor={get [Symbol.species](){throw new Error('species');}};s.subarray=d.set=()=>{throw new Error('mutable method');};assert(copy.call(s,d)===5&&d.toString('hex')==='0001020304','intrinsic bytes');});
  check('offset strings booleans null and fractions are coerced',()=>{const d=Buffer.alloc(6,0xaa);assert(source().copy(d,'1',true,4.9)===3&&d.toString('hex')==='aa010203aaaa','coercion');assert(source().copy(d,null,null,1)===1,'null indices');});
  check('explicit nonfinite indices map to zero',()=>{for(const value of [NaN,Infinity,-Infinity]){const d=Buffer.alloc(6,0xaa);assert(source().copy(d,value,value,4)===4&&d.toString('hex')==='00010203aaaa','nonfinite start');assert(source().copy(d,0,0,value)===0,'explicit nonfinite end');}});
  check('negative floors and invalid starts fail before mutation',()=>{for(const args of [[-0.9,0,4],[0,-0.9,4],[0,0,-0.9],[0,6,0]]){const d=Buffer.alloc(6,0xaa);assert(throws(()=>copy.call(source(),d,...args)).code==='ERR_OUT_OF_RANGE'&&d.toString('hex')==='aaaaaaaaaaaa','bounds atomicity');}assert(throws(()=>source().copy(Buffer.alloc(5),0,0,1n)) instanceof TypeError,'BigInt coercion');});
  check('native brands precede index coercion',()=>{let calls=0;const p={valueOf(){calls++;return 0;}};for(const value of [{},new Proxy(Buffer.alloc(4),{}),Object.create(Uint8Array.prototype)])assert(throws(()=>copy.call(value,Buffer.alloc(4),p)).code==='ERR_INVALID_ARG_TYPE','source brand');assert(throws(()=>copy.call(source(),{},p)).code==='ERR_INVALID_ARG_TYPE'&&calls===0,'target brand order');});
  check('index hooks run once in order before bytes move',()=>{const events=[],s=source(),d=Buffer.alloc(6);const hook=(name,n)=>({valueOf(){events.push(name);if(name==='end')s[1]=42;return n;}});assert(s.copy(d,hook('target',1),hook('start',1),hook('end',4))===3&&events.join(',')==='target,start,end'&&d.toString('hex')==='002a02030000','observable order');const error=new Error('coercion witness');assert(throws(()=>s.copy(d,{valueOf(){throw error;}}))===error,'exception identity');});
  check('deterministic overlap matrix writes exact physical output',()=>{const s=Buffer.alloc(65536);for(let i=0;i<s.length;i++)s[i]=i%251;for(const [dst,start,end] of [[3,0,40000],[0,7,64000],[999,600,35000]]){const expected=Array.from(s),snapshot=expected.slice(start,end),count=Math.min(snapshot.length,s.length-dst);for(let i=0;i<count;i++)expected[dst+i]=snapshot[i];assert(s.copy(s,dst,start,end)===count&&s.every((v,i)=>v===expected[i]),'large alias copy');}writeFileSync(path,s);});
  if(labels.length+failures.length!==20)throw new Error('wrong copy denominator');
  console.log('NODE BUFFER COPY RESULTS '+JSON.stringify({checks:20,passed:labels.length,failures}));
  if(failures.length)throw new Error('Buffer copy contract failed');
  console.log('NODE BUFFER COPY 20 CHECKS OK');
}else throw new Error('Unknown copy fixture mode');
