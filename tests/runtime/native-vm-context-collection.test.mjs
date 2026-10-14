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
const timerContext = (() => {
  const context = vm.createContext({ answer: 42 }, { name: 'buffered-timer-context' })
  vm.runInContext('console.count("unobserved"); console.time("unobserved"); console.timeLog("unobserved", {answer}); console.timeEnd("unobserved")', context)
  return new WeakRef(context)
})()
await collect()
assert.notEqual(timerContext.deref(), undefined)

const session = new Session()
session.connect()
const contexts = []
const destroyed = []
const consoleEvents = []
session.on('Runtime.consoleAPICalled', event => consoleEvents.push(event.params))
session.on('Runtime.executionContextCreated', event => contexts.push(event.params.context))
session.on('Runtime.executionContextDestroyed', event => destroyed.push(event.params.executionContextId))
await session.post('Runtime.enable')
const buffered = contexts.find(context => context.name === 'buffered-timer-context')
assert(buffered)
const timerLog = consoleEvents.find(event => event.executionContextId === buffered.id && event.type === 'log' && /^unobserved: [\d.]+\s?ms$/.test(event.args[0]?.value))
assert(timerLog)
const properties = await session.post('Runtime.getProperties', { objectId: timerLog.args[1].objectId, ownProperties: true })
assert.equal(properties.result.find(property => property.name === 'answer').value.value, 42)
await session.post('Runtime.evaluate', { contextId: buffered.id, expression: 'console.clear()' })
await session.post('Runtime.releaseObjectGroup', { objectGroup: 'console' })
await session.post('Console.clearMessages')
await collect()
assert.equal(timerContext.deref(), undefined)

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
