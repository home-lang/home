import dns from 'node:dns/promises';
if(Object.keys(dns).join(',')!=='lookup')throw new Error('Unimplemented DNS API advertised');
for(const name of ['resolve','resolve4','resolve6','resolveTxt','Resolver','setServers'])if(name in dns)throw new Error('Unimplemented DNS API advertised: '+name);
for(const hostname of ['éxample.com','a'.repeat(1025)]){
 let refused=false;try{dns.lookup(hostname)}catch(e){refused=e.code==='ERR_HOME_UNSUPPORTED'}
 if(!refused)throw new Error('DNS profile limit was not refused');
}
let refused=false;try{dns.lookup('localhost\0evil')}catch(e){refused=e.code==='ERR_INVALID_ARG_VALUE'}
if(!refused)throw new Error('Ambiguous NUL hostname was not refused');
if('__home_tool_dns_lookup' in globalThis || '__home_tool_dns_factory' in globalThis)throw new Error('Private DNS bridge leaked');
let strictFamily=false;try{dns.lookup('localhost',{family:'IPv4'})}catch(e){strictFamily=e.code==='ERR_INVALID_ARG_VALUE'}
if(!strictFamily)throw new Error('Node numeric-family contract changed');
let observations=0;const options={get all(){observations++;return true;},family:4};
const result=await dns.lookup('localhost',options);
if(observations!==1||!Array.isArray(result)||result.some(r=>r.family!==4))throw new Error('DNS options not snapshotted once');
console.log('HOME DNS PROFILE ASCII BOUND, PRIVATE BRIDGE, ONCE SNAPSHOT; RECORD RESOLVERS ABSENT');
