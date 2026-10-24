// Independent standalone host acceptance; no camera bindings or codec process.
import assert from 'node:assert/strict'
import {createConnection} from 'node:net'
const host=process.argv[2]!
async function until(f:()=>boolean){const deadline=Date.now()+5000;while(!f()){if(Date.now()>deadline)throw Error('host acceptance deadline');await Bun.sleep(1)}}
function alive(pid:number){try{process.kill(pid,0);return true}catch{return false}}
function launch(command:string[]){
  const child=Bun.spawn([host,'20','--',...command],{stdio:['pipe','pipe','pipe','socket-fd']})
  const fd=child.stdio[3];assert.equal(typeof fd,'number')
  const socket=createConnection({fd} as any),records:{kind:number;status:number;supervisor:number;consumer:number}[]=[]
  const chunks:Buffer[]=[],err:Buffer[]=[];let buffered=Buffer.alloc(0),closed=false,protocolError:unknown
  socket.on('error',e=>{protocolError=e});socket.on('close',()=>{closed=true})
  socket.on('data',data=>{
    buffered=Buffer.concat([buffered,data]);if(buffered.length>64){protocolError=Error('excess control data');return}
    while(buffered.length>=32){const b=buffered.subarray(0,32);buffered=buffered.subarray(32)
      if(b.subarray(0,4).toString()!=='ZCO1'||b.readUInt32LE(12)!==0){protocolError=Error('control framing');return}
      records.push({kind:b.readUInt32LE(4),status:b.readUInt32LE(8),supervisor:Number(b.readBigUInt64LE(16)),consumer:Number(b.readBigUInt64LE(24))})
    }
  })
  // eslint-disable-next-line pickier/no-unused-vars -- References inside for-await are missed by this rule.
  async function drain(stream:ReadableStream<Uint8Array>,out:Buffer[]){for await(const bytes of stream){out.push(Buffer.from(bytes));assert(out.reduce((n,b)=>n+b.length,0)<65536)}}
  const readers=Promise.all([drain(child.stdout,chunks),drain(child.stderr,err)])
  return {child,socket,records,err,chunks,get closed(){return closed},async join(){const code=await child.exited;await readers;await until(()=>closed);if(protocolError)throw protocolError;return code}}
}
for(const expected of [0,42]){
  const p=launch([process.execPath,'-e',`const b=await Bun.stdin.text();process.stdout.write(b);process.exit(${expected})`])
  await until(()=>p.records.some(r=>r.kind===1))
  assert.equal(p.records[0].supervisor,p.child.pid);const consumer=p.records[0].consumer
  await p.child.stdin.write('owned media bytes');await p.child.stdin.flush();await p.child.stdin.end()
  assert.equal(await p.join(),expected);assert.equal(Buffer.concat(p.chunks).toString(),'owned media bytes')
  assert.equal(p.records.at(-1)?.kind,2);assert.equal(p.records.at(-1)?.status,expected);assert(!alive(consumer))
}
{
  const p=launch([process.execPath,'-e','process.on("SIGTERM",()=>{});process.stderr.write("ignoring term");setInterval(()=>{},1000)'])
  await until(()=>p.records.some(r=>r.kind===1)&&Buffer.concat(p.err).toString().includes('ignoring term'))
  const consumer=p.records[0].consumer;p.socket.end()
  assert.equal(await p.join(),125);await p.child.stdin.end();assert(!alive(consumer));assert(!alive(p.child.pid))
}
{
  const p=launch(['/no-such-home-video-consumer'])
  await until(()=>p.records.some(r=>r.kind===3))
  assert(p.records.find(r=>r.kind===3)!.status>0);assert.equal(await p.join(),125)
  await p.child.stdin.end()
}
const groupConsumer=process.argv[3]
if(groupConsumer)for(let i=0;i<50;i++){
  const p=launch([groupConsumer])
  await until(()=>p.records.length>0)
  assert.equal(p.records[0].kind,1,JSON.stringify(p.records))
  const consumer=p.records[0].consumer
  await p.child.stdin.write('bounded media');await p.child.stdin.flush();await p.child.stdin.end()
  assert.equal(await p.join(),0)
  assert.equal(Buffer.concat(p.chunks).toString(),'owned-group\nbounded media')
  assert.equal(p.records.at(-1)?.status,0);assert(!alive(consumer));assert(!alive(p.child.pid))
}
console.log('standalone host proves exec readiness, exact media EOF, exit status, control EOF cancellation and joined process exit')
