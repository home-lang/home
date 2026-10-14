import assert from 'node:assert/strict'
import vm from 'node:vm'
import { Session } from 'node:inspector/promises'
async function collect() {
  for (let i = 0; i < 20; i++) {
    await new Promise(resolve => setImmediate(resolve))
    if (globalThis.Bun) Bun.gc(true)
    else globalThis.gc()
    await new Promise(resolve => setImmediate(resolve))
  }
}
function createWeakContexts() {
  const first = vm.createContext({ answer: 41 }, { name: 'collect-first' })
  const second = vm.createContext({ answer: 42 }, { name: 'collect-second' })
  return [new WeakRef(first), new WeakRef(second)]
}
const weak = createWeakContexts()
await collect()
assert.deepEqual(weak.map(reference => reference.deref() !== undefined), [false, false])
const session = new Session()
session.connect()
const contexts = []
const destroyed = []
session.on('Runtime.executionContextCreated', event => contexts.push(event.params.context))
session.on('Runtime.executionContextDestroyed', event => destroyed.push(event.params.executionContextId))
await session.post('Runtime.enable')
const announced = (() => {
  const context = vm.createContext({}, { name: 'collect-announced' })
  return new WeakRef(context)
})()
const realm = contexts.find(context => context.name === 'collect-announced')
assert(realm)
await collect()
assert.equal(announced.deref(), undefined)
assert(destroyed.includes(realm.id))
session.disconnect()
const retained = vm.createContext({ answer: 42 }, { name: 'still-live' })
await collect()
assert.equal(vm.runInContext('answer', retained), 42)
console.log('VM globals collect without a cached structure root; announced unused realms retire on the owner loop')
