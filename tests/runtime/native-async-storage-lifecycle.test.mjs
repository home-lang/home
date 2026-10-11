import assert from 'node:assert/strict'
import { AsyncLocalStorage, AsyncResource } from 'node:async_hooks'
import { EventEmitter, EventEmitterAsyncResource, captureRejectionSymbol } from 'node:events'

const first = new AsyncLocalStorage()
const second = new AsyncLocalStorage()
first.disable()
assert.equal(first.run('reactivated', () => first.getStore()), 'reactivated')
assert.equal(first.getStore(), undefined)
first.run('outer', () => {
  first.disable()
  assert.equal(first.getStore(), undefined)
})
assert.equal(first.getStore(), undefined)
first.run('outer', () => {
  first.enterWith('replacement')
  assert.equal(first.getStore(), 'replacement')
})
assert.equal(first.getStore(), undefined)

first.run('outer', () => second.run('other', () => {
  const marker = new Error('callback error')
  assert.throws(() => first.run('inner', () => { throw marker }), error => error === marker)
  assert.equal(first.getStore(), 'outer')
  first.exit(() => {
    assert.equal(first.getStore(), undefined)
    assert.equal(second.getStore(), 'other')
    first.run('temporary', () => assert.equal(first.getStore(), 'temporary'))
  })
  assert.equal(first.getStore(), 'outer')
  assert.equal(second.getStore(), 'other')
}))
assert.equal(first.getStore(), undefined)
assert.equal(second.getStore(), undefined)

first.disable()
first.exit(() => assert.equal(first.getStore(), undefined))
assert.equal(first.getStore(), undefined)
assert.throws(() => first.run('value', null), TypeError)
assert.throws(() => first.exit(null), TypeError)
assert.equal(first.getStore(), undefined)

let snapshot
let resource
const continuation = first.run('captured', async () => {
  snapshot = AsyncLocalStorage.snapshot()
  resource = new AsyncResource('home-lifecycle')
  await Promise.resolve()
  assert.equal(first.getStore(), 'captured')
})
assert.equal(first.getStore(), undefined)
await continuation
assert.equal(snapshot(() => first.getStore()), 'captured')
assert.equal(resource.runInAsyncScope(() => first.getStore()), 'captured')
first.disable()
assert.equal(snapshot(() => first.getStore()), undefined)
assert.equal(resource.runInAsyncScope(() => first.getStore()), undefined)
resource.emitDestroy()
console.log('native async storage restoration, disable, exit, snapshots and resources passed')

const captureEmitter = new EventEmitter({ captureRejections: true })
const capturedErrors = []
captureEmitter.on('error', error => capturedErrors.push(error))
const getterError = new Error('ordinary then getter failure')
captureEmitter.on('getter', () => ({ get then() { throw getterError } }))
assert.equal(captureEmitter.emit('getter'), true)
assert.deepEqual(capturedErrors, [getterError])
captureEmitter.on('value', () => ({ then: 42 }))
assert.equal(captureEmitter.emit('value'), true)
assert.deepEqual(capturedErrors, [getterError])
let thenReads = 0
let thenReceiver
const thenableError = new Error('ordinary thenable rejection')
const thenable = { get then() { thenReads++; return function (fulfilled, rejected) { thenReceiver = this; rejected(thenableError) } } }
captureEmitter.on('thenable', () => thenable)
assert.equal(captureEmitter.emit('thenable'), true)
await new Promise(resolve => setImmediate(resolve))
assert.equal(thenReads, 1)
assert.equal(thenReceiver, thenable)
assert.deepEqual(capturedErrors, [getterError, thenableError])
for (const result of [0, false, 'ordinary', {}, null, undefined]) {
  const valueEmitter = new EventEmitter({ captureRejections: true })
  valueEmitter.on('ordinary', () => result)
  assert.equal(valueEmitter.emit('ordinary'), true)
}
const rejectionOwner = new EventEmitter({ captureRejections: true })
const customError = new Error('custom rejection hook')
let customRejection
rejectionOwner[captureRejectionSymbol] = function (error, event, ...args) {
  assert.equal(this, rejectionOwner)
  customRejection = [error, event, ...args]
}
rejectionOwner.on('custom', () => ({ then(fulfilled, rejected) { rejected(customError) } }))
assert.equal(rejectionOwner.emit('custom', 1, 2), true)
await new Promise(resolve => setImmediate(resolve))
assert.deepEqual(customRejection, [customError, 'custom', 1, 2])
const emitterStore = new AsyncLocalStorage()
const scopedEmitter = emitterStore.run('emitter-created', () => new EventEmitterAsyncResource({ name: 'home-event-resource' }))
scopedEmitter.on('ordinary', function (value) {
  assert.equal(this, scopedEmitter)
  assert.equal(emitterStore.getStore(), 'emitter-created')
  assert.equal(value, 7)
})
assert.equal(emitterStore.run('caller', () => scopedEmitter.emit('ordinary', 7)), true)
assert.equal(scopedEmitter.emit('missing'), false)
assert.equal(emitterStore.getStore(), undefined)
scopedEmitter.emitDestroy()
emitterStore.disable()
console.log('native event thenable capture and async resource emit results passed')
