import buffer, {Buffer} from 'node:buffer';
import {createRequire} from 'node:module';
import {writeFileSync} from 'node:fs';
const [mode, path] = process.argv.slice(2);
function assert(value, label) { if (!value) throw new Error(label); }
function throws(fn) { let error; try { fn(); } catch (caught) { error = caught; } assert(error, 'expected failure'); return error; }
const specs = [['writeUInt8',1,false,false],['writeInt8',1,false,true],['writeUInt16LE',2,true,false],['writeUInt16BE',2,false,false],['writeInt16LE',2,true,true],['writeInt16BE',2,false,true],['writeUInt32LE',4,true,false],['writeUInt32BE',4,false,false],['writeInt32LE',4,true,true],['writeInt32BE',4,false,true]];
if (mode === 'guards') {
  const wide = new Uint16Array(4); Object.setPrototypeOf(wide, Uint8Array.prototype);
  const inputs = [{length:8}, wide, new Proxy(Buffer.alloc(8), {}), new DataView(new ArrayBuffer(8)), Object.create(Uint8Array.prototype)];
  for (const value of inputs) assert(throws(() => Buffer.prototype.writeUInt32LE.call(value,42,0)).code === 'ERR_HOME_UNSUPPORTED', 'non-byte receiver refusal');
  assert(new Uint16Array(wide.buffer)[0] === 0, 'forged wide storage unchanged');
  console.log('HOME BUFFER WRITES 5 RECEIVER GUARDS OK');
} else if (mode === 'contract') {
  const failures = [], labels = [];
  function check(label, fn) { try { fn(); labels.push(label); } catch (error) { failures.push({label,message:String(error),code:error.code}); } }
  function b() { return Buffer.alloc(8,0xaa); }
  check('module aliases expose actual fixed-width writers', () => {
    const req = createRequire(import.meta.url); assert(req('buffer') === buffer && req('node:buffer') === buffer && buffer.Buffer === Buffer, 'module identity');
    for (const [name] of specs) assert(typeof Buffer.prototype[name] === 'function' && Buffer.prototype[name].length === 1,'writer identity');
  });
  check('8-bit signed and unsigned exact byte encoding', () => {
    const v=b(); assert(v.writeUInt8(255)===1 && v.writeInt8(-128,1)===2 && v.toString('hex')==='ff80aaaaaaaaaaaa','8bit bytes');
  });
  check('16-bit endian and signed exact byte encoding', () => {
    const v=b(); v.writeUInt16LE(0xabcd,0); v.writeUInt16BE(0xabcd,2); v.writeInt16LE(-2,4); v.writeInt16BE(-32768,6);
    assert(v.toString('hex')==='cdababcdfeff8000','16bit bytes');
  });
  check('32-bit endian and signed exact byte encoding', () => {
    const v=Buffer.alloc(16); v.writeUInt32LE(0xfedcba98,0); v.writeUInt32BE(0xfedcba98,4); v.writeInt32LE(-2,8); v.writeInt32BE(-2147483648,12);
    assert(v.toString('hex')==='98badcfefedcba98feffffff80000000','32bit bytes');
  });
  check('all endpoints agree with independent DataView decoding', () => {
    for (const [name,width,little,signed] of specs) {
      const limit=2**(width*8), minimum=signed?-limit/2:0, maximum=signed?limit/2-1:limit-1;
      for (const value of [minimum,0,maximum]) {const v=b(); assert(v[name](value,1)===1+width,'return offset'); const d=new DataView(v.buffer,v.byteOffset,v.byteLength), read='get'+(signed?'Int':'Uint')+(width*8); assert(d[read](1,little)===value,'native DataView oracle');}
    }
  });
  check('deterministic 32-bit values retain full width', () => {
    let seed=0x12345678;
    for(let i=0;i<64;i++){seed=(Math.imul(seed,1664525)+1013904223)>>>0;const v=b();v.writeUInt32LE(seed);v.writeInt32BE(seed|0,4);const d=new DataView(v.buffer,v.byteOffset,8);assert(d.getUint32(0,true)===seed && d.getInt32(4,false)===(seed|0),'32bit oracle');}
  });
  check('value coercion accepts strings booleans null and NaN', () => {
    for(const [name,width] of specs)for(const [input,wanted] of [['42',42],[true,1],[null,0],[undefined,0],[NaN,0]]){const v=Buffer.alloc(width);v[name](input);assert(v[width===1||name.endsWith('LE')?0:width-1]===wanted,'coerced low byte');}
  });
  check('fractional values truncate after range validation', () => {
    for(const [name,width,little,signed] of specs){const v=Buffer.alloc(width);v[name](signed?-1.9:1.9);const d=new DataView(v.buffer,v.byteOffset,width), read='get'+(signed?'Int':'Uint')+(width*8);assert(d[read](0,little)===(signed?-1:1),'fraction conversion');}
  });
  check('invalid values never partially mutate bytes', () => {
    for(const [name,width,little,signed] of specs){const limit=2**(width*8),min=signed?-limit/2:0,max=signed?limit/2-1:limit-1;for(const value of [min-1,max+1,Infinity,-Infinity]){const v=b();assert(throws(()=>v[name](value,0)).code==='ERR_OUT_OF_RANGE' && v.every(x=>x===0xaa),'value bound atomicity');}}
  });
  check('offset types are not coerced', () => {
    let called=0;const offset={valueOf(){called++;return 0;}};
    for(const [name] of specs)for(const index of ['0',null,true,offset])assert(throws(()=>b()[name](1,index)).code==='ERR_INVALID_ARG_TYPE','offset type');
    assert(called===0,'offset coercion absent');
  });
  check('fractional and NaN offsets fail without writes', () => {
    for(const [name] of specs)for(const index of [0.5,NaN]){const v=b();assert(throws(()=>v[name](1,index)).code==='ERR_OUT_OF_RANGE' && v.every(x=>x===0xaa),'integer offset');}
  });
  check('short buffers and valid integer out-of-range offsets stay distinct', () => {
    for(const [name,width] of specs){assert(throws(()=>Buffer.alloc(width-1)[name](0,0)).code==='ERR_BUFFER_OUT_OF_BOUNDS','short view');for(const offset of [-1,Infinity,8])assert(throws(()=>b()[name](0,offset)).code==='ERR_OUT_OF_RANGE','outside view');}
  });
  check('Node value-range and offset-type error precedence', () => {
    for(const [name,width,little,signed] of specs){const max=signed?2**(width*8-1)-1:2**(width*8)-1;assert(throws(()=>b()[name](max+1,'bad')).code===(width===1?'ERR_INVALID_ARG_TYPE':'ERR_OUT_OF_RANGE'),'error order');}
  });
  check('throwing value conversion runs once before offset checks', () => {
    for(const [name] of specs){let calls=0;const sentinel=new Error('value witness'),v=b(),value={valueOf(){calls++;throw sentinel;}};assert(throws(()=>v[name](value,'bad'))===sentinel && calls===1 && v.every(x=>x===0xaa),'coercion order');}
  });
  check('unsigned spelling aliases share the same functions', () => {
    for(const [name] of specs.filter(x=>x[0].includes('UInt'))){assert(Buffer.prototype[name]===Buffer.prototype[name.replace('UInt','Uint')],'alias identity');const v=b();assert(v[name.replace('UInt','Uint')](42,0)>0,'alias execution');}
  });
  check('borrowed genuine Uint8Array receives actual bytes', () => {
    const v=new Uint8Array(4);assert(Buffer.prototype.writeUInt32LE.call(v,0xfedcba98,0)===4 && [...v].join(',')==='152,186,220,254','real native bytes');
  });
  check('subarray byte windows and shadowed lengths do not escape storage', () => {
    const all=Buffer.alloc(12,0xaa),v=all.subarray(3,7);Object.defineProperty(v,'length',{value:0});Object.defineProperty(v,'byteLength',{value:999});
    assert(v.writeUInt32BE(0x12345678)===4 && all.toString('hex')==='aaaaaa12345678aaaaaaaaaa','actual window');
    assert(throws(()=>v.writeUInt16LE(1,3)).code==='ERR_BUFFER_OUT_OF_BOUNDS' && all.toString('hex')==='aaaaaa12345678aaaaaaaaaa','window bound');
  });
  check('native filesystem stores every integer format independently', () => {
    const v=Buffer.alloc(26),values=[0xab,-7,0xcdef,0x1234,-12345,-23456,0xfedcba98,0x89abcdef,-123456789,-2147483648];let offset=0;
    for(let i=0;i<specs.length;i++)offset=v[specs[i][0]](values[i],offset);
    assert(offset===26,'full byte count');writeFileSync(path,v);
  });
  if(labels.length+failures.length!==18)throw new Error('wrong integer writer denominator');
  console.log('NODE BUFFER WRITES RESULTS '+JSON.stringify({checks:18,passed:labels.length,failures}));
  if(failures.length)throw new Error('Buffer integer write contract failed');
  console.log('NODE BUFFER WRITES 18 CHECKS OK');
} else throw new Error('Unknown fixture mode');
