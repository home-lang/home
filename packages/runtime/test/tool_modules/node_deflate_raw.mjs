import zlib, { deflateRaw, deflateRawSync } from 'node:zlib';
import { writeFileSync } from 'node:fs';
const [mode, directory] = process.argv.slice(2);
function assert(value, message) { if (!value) throw new Error(message); }
function code(fn, expected) { try { fn(); } catch (e) { assert(e.code === expected, `${e.code} !== ${expected}`); return; } throw new Error('expected ' + expected); }
if (mode === 'fatal') {
  deflateRaw('actual', () => { console.log('RAW DEFLATE CALLBACK ENTERED'); throw new Error('RAW_DEFLATE_CALLBACK_FATAL'); });
} else if (mode === 'profile') {
  for (const options of [{ level: 1 }, { dictionary: Buffer.from('x') }, { flush: 2 }, { maxOutputLength: 10 }])
    code(() => deflateRawSync('actual', options), 'ERR_HOME_UNSUPPORTED');
  code(() => deflateRawSync(Buffer.alloc(2 * 1024 * 1024 + 1)), 'ERR_BUFFER_TOO_LARGE');
  code(() => deflateRawSync('actual',42), 'ERR_INVALID_ARG_TYPE');
  console.log('HOME RAW DEFLATE 6 PROFILE GUARDS OK');
} else if (mode === 'contract') {
  const labels = [], failures = [];
  async function check(label, fn) { try { await fn(); labels.push(label); } catch (e) { failures.push({ label, error: String(e) }); } }
  function save(name, value) { assert(Buffer.isBuffer(value), 'real Buffer result'); writeFileSync(directory + '/' + name + '.raw', value); }
  function asyncRaw(input, options) { return new Promise((resolve, reject) => { const cb = (e, result) => e ? reject(e) : resolve(result); const ret = options === undefined ? deflateRaw(input, cb) : deflateRaw(input, options, cb); assert(ret === undefined, 'undefined callback return'); }); }
  await check('real exports and arities', () => { assert(deflateRaw === zlib.deflateRaw && deflateRawSync === zlib.deflateRawSync, 'exports'); assert(deflateRaw.length === 3 && deflateRawSync.length === 2, 'arities'); });
  await check('empty raw stream', () => save('empty', deflateRawSync('')));
  await check('UTF-8 raw bytes', () => save('unicode', deflateRawSync('actual raw é😀\0')));
  await check('offset Uint8Array window', () => save('binary', deflateRawSync(Uint8Array.from([9,0,255,128,97,0,98,9]).subarray(1,7))));
  await check('wide typed array physical bytes', () => { const a = new Uint16Array(3); new Uint8Array(a.buffer).set([0,255,128,97,0,98]); save('wide', deflateRawSync(a)); });
  await check('offset DataView physical bytes', () => save('view', deflateRawSync(new DataView(Uint8Array.from([9,0,255,128,97,0,98,9]).buffer,1,6))));
  await check('invalid input types refuse', () => { for (const value of [1,null,undefined,{},[]]) code(() => deflateRawSync(value),'ERR_INVALID_ARG_TYPE'); });
  await check('ArrayBuffer physical bytes', () => save('arraybuffer',deflateRawSync(Uint8Array.from([0,255,128,97,0,98]).buffer))); 
  await check('callback validation before input', () => { code(() => deflateRaw(42,{},3),'ERR_INVALID_ARG_TYPE'); code(() => deflateRaw('x'),'ERR_INVALID_ARG_TYPE'); });
  await check('deferred callback after microtask', async () => { let sync=true, micro=false; const pending = new Promise((resolve,reject) => { const ret=deflateRaw('callback bytes',(error,result) => { try { assert(!sync && micro && error===null,'actual deferred success'); save('callback',result); resolve(); } catch(e) { reject(e); } }); assert(ret===undefined,'return'); }); Promise.resolve().then(()=>{micro=true;}); sync=false; await pending; });
  await check('callback accepts null default options', async () => save('null-options', await asyncRaw(Buffer.from([0,255,128,97,0,98]),null)));
  await check('concurrent independent callbacks', async () => { const values=await Promise.all(['one','two','three'].map(value=>asyncRaw(value))); for(let i=0;i<3;i++) save('concurrent-'+i,values[i]); });
  await check('default empty options', () => { save('empty-options',deflateRawSync('default bytes',{})); save('sync-null',deflateRawSync('default bytes',null)); });
  await check('real repeated payload compresses', () => { const result=deflateRawSync(Buffer.alloc(65536,97)); assert(result.length<1024,'actual compression'); save('large',result); });
  console.log('NODE RAW DEFLATE RESULTS '+JSON.stringify({checks:14,passed:labels.length,failures}));
  if(failures.length || labels.length!==14) throw new Error('raw deflate contract incomplete');
  console.log('NODE RAW DEFLATE 14 CHECKS OK');
} else throw new Error('select contract or profile');
