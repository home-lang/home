import assert from 'node:assert/strict'
import { AsyncLocalStorage, AsyncResource, createHook, executionAsyncId, triggerAsyncId, executionAsyncResource } from 'node:async_hooks'
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

assert.throws(() => new EventEmitterAsyncResource(), { code: 'ERR_INVALID_ARG_TYPE' })
assert.throws(() => new EventEmitterAsyncResource({}), { code: 'ERR_INVALID_ARG_TYPE' })
const namedEmitter = new EventEmitterAsyncResource('home-string-resource')
assert(namedEmitter.asyncResource instanceof AsyncResource)
assert.equal(namedEmitter.asyncResource.eventEmitter, namedEmitter)
assert.equal(namedEmitter.asyncId, namedEmitter.asyncResource.asyncId())
assert.equal(namedEmitter.triggerAsyncId, namedEmitter.asyncResource.triggerAsyncId())
assert.equal(Object.hasOwn(namedEmitter, 'asyncResource'), false)
assert.equal(Object.hasOwn(namedEmitter, 'triggerAsyncId'), false)
assert.throws(() => { namedEmitter.asyncResource = {} }, TypeError)
assert.throws(() => { namedEmitter.asyncId = 1 }, TypeError)
assert.throws(() => { namedEmitter.triggerAsyncId = 1 }, TypeError)
class ResourceChild extends EventEmitterAsyncResource {}
const resourceChild = new ResourceChild()
assert(resourceChild.asyncResource instanceof AsyncResource)
assert.equal(resourceChild.asyncResource.eventEmitter, resourceChild)
const capturedStore = new AsyncLocalStorage()
const capturedEmitter = capturedStore.run('resource-context', () => new EventEmitterAsyncResource({ name: 'home-capture-resource', captureRejections: true }))
assert.equal(Object.hasOwn(capturedEmitter, 'emit'), false)
const capturedFailure = new Error('resource rejection')
let resolveCapture
const captureReady = new Promise(resolve => { resolveCapture = resolve })
capturedEmitter.on('ordinary', function (value) {
  assert.equal(this, capturedEmitter)
  assert.equal(capturedStore.getStore(), 'resource-context')
  assert.equal(value, 11)
  return Promise.reject(capturedFailure)
})
capturedEmitter.on('error', function (error) {
  assert.equal(this, capturedEmitter)
  assert.equal(error, capturedFailure)
  assert.equal(capturedStore.getStore(), 'resource-context')
  resolveCapture()
})
assert.equal(capturedStore.run('caller-context', () => capturedEmitter.emit('ordinary', 11)), true)
await captureReady
assert.equal(capturedStore.getStore(), undefined)
let resolveDefaultCapture
const defaultCaptureReady = new Promise(resolve => { resolveDefaultCapture = resolve })
const priorCaptureDefault = EventEmitter.captureRejections
EventEmitter.captureRejections = true
let defaultCaptureEmitter
try {
  defaultCaptureEmitter = capturedStore.run('default-capture-context', () => new EventEmitterAsyncResource({ name: 'home-default-capture' }))
} finally {
  EventEmitter.captureRejections = priorCaptureDefault
}
assert.equal(Object.hasOwn(defaultCaptureEmitter, 'emit'), false)
defaultCaptureEmitter.on('ordinary', () => {
  assert.equal(capturedStore.getStore(), 'default-capture-context')
  return Promise.reject(capturedFailure)
})
defaultCaptureEmitter.on('error', error => {
  assert.equal(error, capturedFailure)
  assert.equal(capturedStore.getStore(), 'default-capture-context')
  resolveDefaultCapture()
})
assert.equal(defaultCaptureEmitter.emit('ordinary'), true)
await defaultCaptureReady
assert.equal(capturedStore.getStore(), undefined)
defaultCaptureEmitter.emitDestroy()
capturedEmitter.emitDestroy()
namedEmitter.emitDestroy()
resourceChild.emitDestroy()
capturedStore.disable()
console.log('native event resource constructor, association and capture context passed')

const resourceEvents = []
const observedIds = new Set()
const hook = createHook({
  init(id, type, trigger, owner) {
    if (type === 'home-real-resource' || type === 'TickObject') {
      observedIds.add(id)
      resourceEvents.push(['init', id, type, trigger, owner])
    }
  },
  before(id) { if (observedIds.has(id)) resourceEvents.push(['before', id, executionAsyncId()]) },
  after(id) { if (observedIds.has(id)) resourceEvents.push(['after', id, executionAsyncId()]) },
  destroy(id) { if (observedIds.has(id)) resourceEvents.push(['destroy', id]) },
})
const outerId = executionAsyncId()
const outerResource = executionAsyncResource()
hook.enable()
const realResource = new AsyncResource('home-real-resource', { triggerAsyncId: outerId, requireManualDestroy: true })
assert(realResource.asyncId() > 0)
assert.notEqual(realResource.asyncId(), outerId)
assert.equal(realResource.triggerAsyncId(), outerId)
const scopeMarker = new Error('resource scope marker')
assert.throws(() => realResource.runInAsyncScope(() => {
  assert.equal(executionAsyncId(), realResource.asyncId())
  assert.equal(triggerAsyncId(), outerId)
  assert.equal(executionAsyncResource(), realResource)
  throw scopeMarker
}), error => error === scopeMarker)
assert.equal(executionAsyncId(), outerId)
assert.equal(executionAsyncResource(), outerResource)
let tickId
await new Promise(resolve => realResource.runInAsyncScope(() => process.nextTick(() => {
  tickId = executionAsyncId()
  assert(tickId > 0)
  assert.notEqual(tickId, realResource.asyncId())
  assert.equal(triggerAsyncId(), realResource.asyncId())
  assert.equal(typeof executionAsyncResource().callback, 'function')
  resolve()
})))
realResource.emitDestroy()
realResource.emitDestroy()
await new Promise(resolve => setImmediate(resolve))
hook.disable()
const id = realResource.asyncId()
assert(resourceEvents.some(row => row[0] === 'init' && row[1] === id && row[4] === realResource))
assert.equal(resourceEvents.filter(row => row[0] === 'before' && row[1] === id).length, 2)
assert.equal(resourceEvents.filter(row => row[0] === 'after' && row[1] === id).length, 2)
assert.equal(resourceEvents.filter(row => row[0] === 'destroy' && row[1] === id).length, 2)
assert.equal(resourceEvents.filter(row => row[0] === 'before' && row[1] === tickId).length, 1)
assert.equal(resourceEvents.filter(row => row[0] === 'after' && row[1] === tickId).length, 1)
assert.equal(resourceEvents.filter(row => row[0] === 'destroy' && row[1] === tickId).length, 1)
console.log('native real resource IDs, scopes, hooks and nextTick lifecycle passed')
