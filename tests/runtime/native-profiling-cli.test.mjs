import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Session } from 'node:inspector/promises'
import { Worker } from 'node:worker_threads'
import vm from 'node:vm'

const dir = mkdtempSync(join(tmpdir(), 'home-native-profiling-'))
const workload = `function profileWork(){let result=0;for(let i=0;i<1000;i++)result+=Math.sqrt(i);return result}const end=performance.now()+150;while(performance.now()<end)profileWork();console.log('done')`
function run(flags, code = workload) {
  const child = spawnSync(process.execPath, [...flags, '-e', code], { cwd: dir, encoding: 'utf8', timeout: 30000 })
  assert.equal(child.error, undefined)
  assert.equal(child.signal, null)
  assert.equal(child.status, 0, child.stderr)
  return child
}
try {
  run(['--cpu-prof', '--cpu-prof-md', '--cpu-prof-name', 'sample', '--cpu-prof-dir', 'cpu/nested'])
  const cpu = JSON.parse(readFileSync(join(dir, 'cpu/nested/sample.cpuprofile'), 'utf8'))
  assert(cpu.nodes.length > 0)
  assert(cpu.samples.length > 0)
  assert.equal(cpu.samples.length, cpu.timeDeltas.length)
  assert(cpu.nodes.some(node => node.callFrame.functionName === 'profileWork'))
  const ids = new Set(cpu.nodes.map(node => node.id))
  assert(cpu.samples.every(id => ids.has(id)))
  assert.match(readFileSync(join(dir, 'cpu/nested/sample.md'), 'utf8'), /# CPU Profile/)
  // CLI and inspector use independent windows over the same native sampler.
  const sharedWorkload = `
    const { Session } = require('node:inspector');
    const { writeFileSync } = require('node:fs');
    function beforeSessionWork(){const until=performance.now()+150;let n=0;while(performance.now()<until){for(let i=0;i<1000;i++)n+=Math.sqrt(i)}return n}
    function duringSessionWork(){const until=performance.now()+150;let n=0;while(performance.now()<until){for(let i=0;i<1000;i++)n+=Math.sin(i)}return n}
    function afterSessionWork(){const until=performance.now()+150;let n=0;while(performance.now()<until){for(let i=0;i<1000;i++)n+=Math.cos(i)}return n}
    function secondSessionWork(){const until=performance.now()+150;let n=0;while(performance.now()<until){for(let i=0;i<1000;i++)n+=Math.tan(i)}return n}
    beforeSessionWork();
    const session=new Session(); session.connect();
    session.post('Profiler.enable');
    session.post('Profiler.setSamplingInterval',{interval:500});
    session.post('Profiler.start'); duringSessionWork();
    session.post('Profiler.stop', (error, result) => {
      if(error) throw error;
      writeFileSync('shared-session.json',JSON.stringify(result.profile));
    });
    session.disconnect(); afterSessionWork();
    const second=new Session(); second.connect(); second.post('Profiler.enable');
    second.post('Profiler.setSamplingInterval',{interval:3000});
    second.post('Profiler.start'); secondSessionWork();
    second.post('Profiler.stop',(error,result)=>{
      if(error) throw error;
      writeFileSync('shared-second.json',JSON.stringify(result.profile));
    }); second.disconnect();
  `
  run(['--cpu-prof', '--cpu-prof-md', '--cpu-prof-interval', '2000', '--cpu-prof-name', 'shared'], sharedWorkload)
  const sharedCLI = JSON.parse(readFileSync(join(dir, 'shared.cpuprofile'), 'utf8'))
  const sharedSession = JSON.parse(readFileSync(join(dir, 'shared-session.json'), 'utf8'))
  function sampledNames(profile) {
    const sampled = new Set(profile.samples)
    const nodeIDs = new Set(profile.nodes.map(node => node.id))
    assert(profile.samples.length > 0)
    assert.equal(profile.samples.length, profile.timeDeltas.length)
    assert(profile.samples.every(id => nodeIDs.has(id)))
    assert(profile.timeDeltas.every(delta => Number.isInteger(delta) && delta >= 0))
    return new Set(profile.nodes.filter(node => sampled.has(node.id)).map(node => node.callFrame.functionName))
  }
  const cliNames = sampledNames(sharedCLI)
  const sessionNames = sampledNames(sharedSession)
  for (const name of ['beforeSessionWork', 'duringSessionWork', 'afterSessionWork']) assert(cliNames.has(name), name)
  assert(sessionNames.has('duringSessionWork'))
  assert(!sessionNames.has('beforeSessionWork'))
  assert(!sessionNames.has('afterSessionWork'))
  const secondNames = sampledNames(JSON.parse(readFileSync(join(dir, 'shared-second.json'), 'utf8')))
  assert(secondNames.has('secondSessionWork'))
  assert(!secondNames.has('beforeSessionWork'))
  assert(!secondNames.has('afterSessionWork'))
  const sharedText = readFileSync(join(dir, 'shared.md'), 'utf8')
  for (const name of ['beforeSessionWork', 'duringSessionWork', 'afterSessionWork']) assert(sharedText.includes(name), name)
  // Process shutdown also exports the CLI samples with an active session.
  run(['--cpu-prof', '--cpu-prof-name', 'active.cpuprofile'], sharedWorkload + `
    const active=new Session(); active.connect(); active.post('Profiler.enable'); active.post('Profiler.start');
    duringSessionWork(); process.exit(0);
  `)
  assert(sampledNames(JSON.parse(readFileSync(join(dir, 'active.cpuprofile'), 'utf8'))).has('duringSessionWork'))
  const heap = run(['--heap-prof', '--heap-prof-name', 'sample.heapsnapshot', '--heap-prof-dir', 'heap/nested'], `globalThis.payload=Array.from({length:100},(_,i)=>({value:i}));process.exit(0)`)
  assert.match(heap.stderr, /Heap profile written to:/)
  const snapshot = JSON.parse(readFileSync(join(dir, 'heap/nested/sample.heapsnapshot'), 'utf8'))
  assert(snapshot.snapshot.node_count > 0)
  assert(snapshot.nodes.length > 0)
  assert(snapshot.edges.length > 0)
  assert(Array.isArray(snapshot.strings))
  run(['--heap-prof-md', '--heap-prof-name', 'sample.md', '--heap-prof-dir', 'heap'], `globalThis.payload=[1,2,3]`)
  assert.match(readFileSync(join(dir, 'heap/sample.md'), 'utf8'), /## GC Roots/)
  run(['--heap-prof'], `globalThis.payload=[1,2,3]`)
  assert(readdirSync(dir).some(name => /^Heap\.\d+\.\d+\.heapsnapshot$/.test(name)))
} finally {
  rmSync(dir, { recursive: true, force: true })
}

const session = new Session()
session.connect()
const notifications = []
session.on('inspectorNotification', message => notifications.push(message))
await session.post('Runtime.enable')
assert.equal((await session.post('Runtime.evaluate', { expression: '21 * 2', returnByValue: true })).result.value, 42)
assert(notifications.some(message => message.method === 'Runtime.executionContextCreated' && Number.isInteger(message.params.context.id)))
assert.throws(() => session.connectToMainThread(), { code: 'ERR_INSPECTOR_ALREADY_CONNECTED' })
await session.post('Profiler.enable')
await session.post('Profiler.start')
const worker = new Worker(`
  const { parentPort } = require('node:worker_threads');
  const { Session } = require('node:inspector');
  const session = new Session();
  session.connect();
  session.disconnect();
  parentPort.postMessage('done');
`, { eval: true })
const exited = new Promise((resolve, reject) => {
  worker.once('exit', resolve)
  worker.once('error', reject)
})
await new Promise((resolve, reject) => {
  worker.once('message', resolve)
  worker.once('error', reject)
})
assert.equal(await exited, 0)
function ownerProfileWork() {
  let value = 0
  for (let i = 0; i < 1000; i++) value += Math.sqrt(i)
  return value
}
const deadline = performance.now() + 150
while (performance.now() < deadline) ownerProfileWork()
const activeWorker = new Worker(`
  const { Session } = require('node:inspector');
  const session = new Session();
  session.connect();
  session.post('Profiler.enable');
  session.post('Profiler.start');
  const end = performance.now() + 100;
  while (performance.now() < end) Math.sqrt(42);
`, { eval: true })
assert.equal(await new Promise((resolve, reject) => {
  activeWorker.once('exit', resolve)
  activeWorker.once('error', reject)
}), 0)
const { profile } = await session.post('Profiler.stop')
assert(profile.samples.length > 0)
assert(profile.nodes.some(node => node.callFrame.functionName === 'ownerProfileWork'))
session.disconnect()

const sibling = new Session()
session.connect()
sibling.connect()
await sibling.post('Runtime.enable')
session.disconnect()
assert.equal((await sibling.post('Runtime.evaluate', { expression: '6 * 7', returnByValue: true })).result.value, 42)
sibling.disconnect()
const { Session: CallbackSession } = await import('node:inspector')
const callbackSession = new CallbackSession()
callbackSession.connect()
let nested = false
callbackSession.post('Runtime.evaluate', { expression: '2 + 2', returnByValue: true }, (error, result) => {
  assert.equal(error, null)
  assert.equal(result.result.value, 4)
  callbackSession.post('Runtime.evaluate', { expression: '3 + 3', returnByValue: true }, (error, inner) => {
    assert.equal(error, null)
    assert.equal(inner.result.value, 6)
    nested = true
    callbackSession.disconnect()
  })
})
assert.equal(nested, true)

const mainSession = new Session()
mainSession.connectToMainThread()
assert.equal((await mainSession.post('Runtime.evaluate', { expression: '7 * 6', returnByValue: true })).result.value, 42)
mainSession.disconnect()


// Context identities and remote objects come from the inspected native realms.
const realmBefore = vm.createContext({ answer: 41 }, { name: 'native-before-realm', origin: 'https://before.example' })
const realmSession = new Session()
const realmEvents = []
realmSession.connect()
realmSession.on('Runtime.executionContextCreated', event => realmEvents.push(event.params.context))
await realmSession.post('Runtime.enable')
const realmAfter = vm.createContext({ answer: 42 }, { name: 'native-after-realm', origin: 'https://after.example' })
await new Promise(resolve => setImmediate(resolve))
const remoteHandles = []
for (const [name, origin, value] of [
  ['native-before-realm', 'https://before.example', 41],
  ['native-after-realm', 'https://after.example', 42],
]) {
  const realm = realmEvents.find(context => context.name === name)
  assert(realm, name)
  assert.equal(realm.origin, origin)
  assert(Number.isInteger(realm.id))
  assert.equal((await realmSession.post('Runtime.evaluate', { expression: 'answer', contextId: realm.id, returnByValue: true })).result.value, value)
  const { result } = await realmSession.post('Runtime.evaluate', { expression: '({answer})', contextId: realm.id, objectGroup: 'native-realms' })
  assert.equal(typeof result.objectId, 'string')
  remoteHandles.push(result.objectId)
}
assert.notEqual(remoteHandles[0], remoteHandles[1])
const crossRealmResult = await realmSession.post('Runtime.callFunctionOn', {
  objectId: remoteHandles[0],
  functionDeclaration: 'function(other) { return this.answer + other.answer; }',
  arguments: [{ objectId: remoteHandles[1] }],
  returnByValue: true,
  objectGroup: 'native-realms',
})
assert.equal(crossRealmResult.result.value, 83)
for (let index = 0; index < remoteHandles.length; index++) {
  const properties = await realmSession.post('Runtime.getProperties', { objectId: remoteHandles[index], ownProperties: true })
  assert.equal(properties.result.find(property => property.name === 'answer').value.value, index === 0 ? 41 : 42)
  await realmSession.post('Runtime.releaseObject', { objectId: remoteHandles[index] })
}
for (const contextId of ['invalid', null, 1.5]) {
  await assert.rejects(realmSession.post('Runtime.evaluate', { expression: '42', contextId }), error => error.code === 'ERR_INSPECTOR_COMMAND' && error.message.includes('-32602'))
}
await assert.rejects(realmSession.post('Runtime.evaluate', { expression: '42', contextId: 2147483647 }), error => error.code === 'ERR_INSPECTOR_COMMAND')
// Missing objectId after maps are populated still dispatches owner evaluation.
assert.equal((await realmSession.post('Runtime.evaluate', { expression: '6 * 7', returnByValue: true })).result.value, 42)
await realmSession.post('Runtime.disable')
const notificationCount = realmEvents.length
const disabledRealm = vm.createContext({}, { name: 'native-disabled-realm' })
await new Promise(resolve => setImmediate(resolve))
assert.equal(realmEvents.length, notificationCount)
await realmSession.post('Runtime.enable')
await new Promise(resolve => setImmediate(resolve))
assert(realmEvents.some(context => context.name === 'native-disabled-realm'))
const metadataReads = []
const emptyNameRealm = vm.createContext({}, {
  get name() { metadataReads.push('name'); return '' },
  get origin() { metadataReads.push('origin'); return 'https://empty.example' },
})
await new Promise(resolve => setImmediate(resolve))
assert.deepEqual(metadataReads, ['name', 'origin'])
assert(realmEvents.some(context => context.name === '' && context.origin === 'https://empty.example'))
assert.equal(vm.createContext(emptyNameRealm, { get name() { throw new Error('must not read existing context metadata') } }), emptyNameRealm)
realmSession.disconnect()
assert.equal(vm.runInContext('answer', realmBefore), 41)
assert.equal(vm.runInContext('answer', realmAfter), 42)
assert(vm.isContext(disabledRealm))
