import assert from 'node:assert/strict'
import vm from 'node:vm'
import { Session } from 'node:inspector/promises'

const session = new Session()
session.connect()
const contexts = []
session.on('Runtime.executionContextCreated', event => contexts.push(event.params.context))
await session.post('Runtime.enable')
const context = vm.createContext({ answer: 41 }, { name: 'created-after-enable', origin: 'home://context-events' })
const realm = contexts.find(context => context.name === 'created-after-enable')
assert(realm, 'creation notification must arrive before createContext returns')
assert.equal(realm.origin, 'home://context-events')
assert.equal((await session.post('Runtime.evaluate', { contextId: realm.id, expression: 'answer + 1', returnByValue: true })).result.value, 42)
await session.post('Runtime.disable')
const silent = vm.createContext({}, { name: 'created-while-disabled' })
assert(!contexts.some(context => context.name === 'created-while-disabled'))
await session.post('Runtime.enable')
assert(contexts.some(context => context.name === 'created-while-disabled'))
session.disconnect()
assert.equal(vm.runInContext('answer', context), 41)
assert(vm.isContext(silent))

const detached = new Session()
detached.connect()
await detached.post('Runtime.enable')
let delivered = false
detached.on('Runtime.executionContextCreated', event => {
  if (event.params.context.name !== 'disconnect-during-creation') return
  delivered = true
  detached.disconnect()
  if (globalThis.Bun) Bun.gc(true)
})
const retained = vm.createContext({ answer: 42 }, { name: 'disconnect-during-creation' })
assert(delivered)
assert.equal(vm.runInContext('answer', retained), 42)
detached.connect()
assert.equal((await detached.post('Runtime.evaluate', { expression: '6 * 7', returnByValue: true })).result.value, 42)
detached.disconnect()
console.log('inspector context creation timing, disable/re-enable and callback detachment passed')
