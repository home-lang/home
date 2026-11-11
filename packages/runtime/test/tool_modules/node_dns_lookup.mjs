import dns from 'node:dns/promises';
import legacy from 'dns/promises';
import fs from 'node:fs';
import net from 'node:net';
const { lookup } = dns, failures = [], passed = [];
async function group(name, fn) { try { if (!await fn()) throw new Error('predicate failed'); passed.push(name); } catch (error) { failures.push({ name, error: String(error) }); } }
function throws(fn, Type, code) { try { fn(); return false; } catch (e) { return e instanceof Type && e.code === code; } }
function equal(a, b) { return JSON.stringify(a) === JSON.stringify(b); }
const v4 = { address:'192.0.2.1', family:4 }, v6 = { address:'2001:db8::1', family:6 };
await group('legacy-alias', () => legacy.lookup === lookup);
await group('literal-v4-single', async () => equal(await lookup('192.0.2.1'), v4));
await group('literal-v6-single', async () => equal(await lookup('2001:db8::1'), v6));
await group('literal-all', async () => equal(await lookup('192.0.2.1', {all:true}), [v4]) && equal(await lookup('2001:db8::1', {all:true}), [v6]));
await group('literal-spelling-preserved', async () => (await lookup('2001:0DB8:0:0::1')).address === '2001:0DB8:0:0::1');
await group('literal-family-fast-path', async () => equal(await lookup('192.0.2.1', {family:6}),v4) && equal(await lookup('2001:db8::1', {family:4}),v6));
await group('literal-mapped-address', async () => equal(await lookup('::ffff:192.0.2.1'),{address:'::ffff:192.0.2.1',family:6}));
await group('null-options', async () => equal(await lookup('192.0.2.1', null), v4));
await group('numeric-family', async () => (await lookup('localhost', 4)).family === 4);
await group('native-default-shape', async () => { const r = await lookup('localhost'); return net.isIP(r.address) === r.family && Object.keys(r).sort().join(',') === 'address,family'; });
await group('native-all-verbatim', async () => { const r = await lookup('localhost',{all:true,verbatim:true}); return r.length > 0 && r.every(x => net.isIP(x.address) === x.family); });
const verbatim = await lookup('localhost',{all:true,verbatim:true});
const ordered = first => [...verbatim.filter(r => r.family === first),...verbatim.filter(r => r.family !== first)];
await group('ipv4first-order', async () => equal(await lookup('localhost',{all:true,order:'ipv4first'}),ordered(4)));
await group('ipv6first-order', async () => equal(await lookup('localhost',{all:true,order:'ipv6first'}),ordered(6)));
await group('legacy-verbatim-false', async () => equal(await lookup('localhost',{all:true,verbatim:false}),ordered(4)));
await group('order-overrides-verbatim', async () => equal(await lookup('localhost',{all:true,verbatim:false,order:'ipv6first'}),ordered(6)));
await group('family-filter', async () => (await lookup('localhost',{all:true,family:4})).every(r => r.family===4));
await group('deferred-promise-handler', async () => { let returned=false; const p=lookup('localhost',{all:true}).then(r => returned && r.length>0); returned=true; return await p; });
await group('options-snapshot', async () => { const o={all:true,family:4}; const p=lookup('localhost',o);o.all=false;o.family=6;const r=await p;return Array.isArray(r)&&r.length>0&&r.every(x=>x.family===4); });
await group('fresh-owned-result', async () => { const a=await lookup('localhost',{all:true}), b=await lookup('localhost',{all:true});a[0].address='fake';return a!==b && b[0].address!=='fake' && net.isIP(b[0].address)===b[0].family; });
await group('invalid-hostname-type', () => [7,{},true,[]].every(h => throws(()=>lookup(h),TypeError,'ERR_INVALID_ARG_TYPE')));
await group('invalid-options-type', () => [true,'IPv4',()=>{}].every(o => throws(()=>lookup('localhost',o),TypeError,'ERR_INVALID_ARG_TYPE')));
await group('invalid-family', () => [7,-1,'other',NaN,Infinity].every(f => throws(()=>lookup('localhost',{family:f}),TypeError,'ERR_INVALID_ARG_VALUE')));
await group('invalid-boolean-options', () => ['all','verbatim'].every(key => throws(()=>lookup('localhost',{[key]:1}),TypeError,'ERR_INVALID_ARG_TYPE')));
await group('invalid-order-and-hints', () => throws(()=>lookup('localhost',{order:'other'}),TypeError,'ERR_INVALID_ARG_VALUE') && throws(()=>lookup('localhost',{hints:'1'}),TypeError,'ERR_INVALID_ARG_TYPE') && throws(()=>lookup('localhost',{hints:1}),TypeError,'ERR_INVALID_ARG_VALUE'));
await group('zero-hints-and-null-fields', async () => equal(await lookup('192.0.2.1',{hints:0,family:null,all:null,order:null}),v4));
await group('real-system-failure-rejects', async () => {try{await lookup('home-ecosystem-repro.invalid',{all:true,verbatim:true});return false;}catch(e){return e.code==='ENOTFOUND' && e.syscall==='getaddrinfo';}});
await group('parallel-owned-lookups', async () => { const results=await Promise.all([lookup('localhost',{all:true}),lookup('localhost',{all:true}),lookup('192.0.2.1')]);return equal(results[0],results[1])&&equal(results[2],v4)&&results[0]!==results[1]; });
const queries=JSON.parse(fs.readFileSync(process.argv[2],'utf8')), actual=[];
await group('independent-physical-host-queries', async () => {
 for(const query of queries){
  try{const records=await lookup(query.hostname,{family:query.family,hints:query.hints,all:true,verbatim:true});actual.push({records});}
  catch(e){actual.push({failure:e.code});}
 }
 return actual.length===queries.length && actual.some(r=>r.records&&r.records.length>0);
});
console.log('DNS LOOKUP RESULTS '+JSON.stringify({groups:passed.length+failures.length,passed:passed.length,failures}));
console.log('DNS PHYSICAL HOST ANSWERS '+JSON.stringify(actual));
if(failures.length)process.exitCode=1;
