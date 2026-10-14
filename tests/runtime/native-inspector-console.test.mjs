import assert from 'node:assert/strict'
import vm from 'node:vm'
import { Session } from 'node:inspector/promises'
const context = vm.createContext({ answer: 42 }, { name: 'console-regression-realm' })
const session = new Session()
session.connect()
const contexts = []
const events = []
session.on('Runtime.executionContextCreated', event => contexts.push(event.params.context))
session.on('Runtime.consoleAPICalled', event => events.push(event.params))
await session.post('Runtime.enable')
const realm = contexts.find(context => context.name === 'console-regression-realm')
assert(realm)
for (const contextId of [undefined, realm.id]) {
  const start = events.length
  await session.post('Runtime.evaluate', { contextId, expression: 'console.log("home-console-marker", 42, {answer: 42}); console.warn("home-console-warning", 43)' })
  await new Promise(resolve => setImmediate(resolve))
  const emitted = events.slice(start).filter(event => event.args[0]?.value?.startsWith('home-console-'))
  assert.equal(emitted.length, 2)
  assert.deepEqual(emitted.map(event => event.type), ['log', 'warning'])
  assert.equal(emitted[0].args[1].value, 42)
  assert.equal(emitted[1].args[1].value, 43)
  assert(Number.isFinite(emitted[0].timestamp) && emitted[0].timestamp > 0)
  if (contextId !== undefined) assert.equal(emitted[0].executionContextId, contextId)
  const object = emitted[0].args[2]
  assert.equal(object.type, 'object')
  assert.equal(typeof object.objectId, 'string')
  const properties = await session.post('Runtime.getProperties', { objectId: object.objectId, ownProperties: true })
  assert.equal(properties.result.find(property => property.name === 'answer').value.value, 42)
  await session.post('Runtime.releaseObject', { objectId: object.objectId })
}
// Counter and timer notifications carry the actual native operation result.
// Retain this realm through the final command so collection is not the oracle.
for (const contextId of [undefined, realm.id]) {
  const start = events.length
  await session.post('Runtime.evaluate', { contextId, expression: 'console.count("native-method-count"); console.count("native-method-count"); console.countReset("native-method-count"); console.count("native-method-count"); console.time("native-method-time"); console.timeLog("native-method-time", {answer: 46}); console.timeEnd("native-method-time"); console.groupEnd()' })
  const emitted = events.slice(start)
  assert.deepEqual(emitted.filter(event => event.type === 'count').map(event => event.args[0].value), ['native-method-count: 1', 'native-method-count: 2', 'native-method-count: 1'])
  const timing = emitted.find(event => event.type === 'log' && /^native-method-time: [\d.]+\s?ms$/.test(event.args[0]?.value))
  assert(timing)
  const properties = await session.post('Runtime.getProperties', { objectId: timing.args[1].objectId, ownProperties: true })
  assert.equal(properties.result.find(property => property.name === 'answer').value.value, 46)
  assert(emitted.some(event => event.type === 'timeEnd' && /^native-method-time: [\d.]+\s?ms$/.test(event.args[0]?.value)))
  assert(emitted.some(event => event.type === 'endGroup' && event.args[0]?.value === 'console.groupEnd'))
  await session.post('Runtime.evaluate', { contextId, expression: 'console.clear()' })
  assert(events.slice(start).some(event => event.type === 'clear' && event.args[0]?.value === 'console.clear'))
  await session.post('Runtime.releaseObjectGroup', { objectGroup: 'console' })
}
await session.post('Runtime.disable')
const previous = events.length
vm.runInContext('console.log("disabled-console-marker")', context)
await new Promise(resolve => setImmediate(resolve))
assert.equal(events.length, previous)
await session.post('Runtime.enable')
const second = new Session()
second.connect()
const secondEvents = []
second.on('Runtime.consoleAPICalled', event => secondEvents.push(event.params))
await second.post('Runtime.enable')
await session.post('Runtime.evaluate', { contextId: realm.id, expression: 'console.log("shared-console-marker", 44)' })
assert(events.some(event => event.args[0]?.value === 'shared-console-marker'))
assert(secondEvents.some(event => event.args[0]?.value === 'shared-console-marker'))
session.disconnect()
await second.post('Runtime.evaluate', { contextId: realm.id, expression: 'console.log("remaining-console-marker", 45)' })
assert(secondEvents.some(event => event.args[0]?.value === 'remaining-console-marker'))
second.disconnect()
assert.equal(vm.runInContext('answer', context), 42)
console.log('native inspector console events, realm object handles, runtime disable and independent sessions passed')
