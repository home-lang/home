import assert from 'node:assert/strict'
import * as fsPromises from 'node:fs/promises'
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { spawnSync } from 'node:child_process'
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

const timerRows = []
const timerIds = new Map()
const timerHook = createHook({
  init(id, type, trigger, owner) {
    if (type === 'Timeout' || type === 'Immediate') {
      timerIds.set(owner, id)
      timerRows.push(['init', id, type, trigger, owner])
    }
  },
  before(id) { timerRows.push(['before', id]) },
  after(id) { timerRows.push(['after', id]) },
  destroy(id) { timerRows.push(['destroy', id]) },
})
const timerOrigin = new AsyncResource('home-timer-origin', { requireManualDestroy: true })
timerHook.enable()
let timeoutTimer
let immediateTimer
let intervalTimer
let canceledTimer
let intervalCalls = 0
let intervalId
let firstTimeoutId
let refreshTimeoutId
let finishTimeout
let finishImmediate
let finishInterval
const timeoutReady = new Promise(resolve => { finishTimeout = resolve })
const immediateReady = new Promise(resolve => { finishImmediate = resolve })
const intervalReady = new Promise(resolve => { finishInterval = resolve })
timerOrigin.runInAsyncScope(() => {
  timeoutTimer = setTimeout(function (value) {
    assert.equal(this, timeoutTimer)
    assert.equal(value, 3)
    assert.equal(executionAsyncResource(), timeoutTimer)
    assert.equal(triggerAsyncId(), timerOrigin.asyncId())
    firstTimeoutId = executionAsyncId()
    assert.equal(firstTimeoutId, timerIds.get(timeoutTimer))
    finishTimeout()
  }, 1, 3)
  immediateTimer = setImmediate(function () {
    assert.equal(this, immediateTimer)
    assert.equal(executionAsyncResource(), immediateTimer)
    assert.equal(executionAsyncId(), timerIds.get(immediateTimer))
    assert.equal(triggerAsyncId(), timerOrigin.asyncId())
    finishImmediate()
  })
  intervalTimer = setInterval(function () {
    assert.equal(executionAsyncResource(), intervalTimer)
    assert.equal(triggerAsyncId(), timerOrigin.asyncId())
    intervalId ??= executionAsyncId()
    assert.equal(executionAsyncId(), intervalId)
    if (++intervalCalls === 2) { clearInterval(intervalTimer); finishInterval() }
  }, 1)
  canceledTimer = setTimeout(() => assert.fail('canceled timer ran'), 60000)
  clearTimeout(canceledTimer)
})
await Promise.all([timeoutReady, immediateReady, intervalReady])
let finishRefresh
const refreshReady = new Promise(resolve => { finishRefresh = resolve })
// Keep the same callback signature while testing native refresh after completion.
timeoutTimer._onTimeout = function () {
  refreshTimeoutId = executionAsyncId()
  assert.equal(executionAsyncResource(), timeoutTimer)
  assert.equal(refreshTimeoutId, timerIds.get(timeoutTimer))
  finishRefresh()
}
timerOrigin.runInAsyncScope(() => timeoutTimer.refresh())
await refreshReady
await new Promise(resolve => setImmediate(resolve))
timerHook.disable()
assert.notEqual(refreshTimeoutId, firstTimeoutId)
assert.equal(timerRows.filter(row => row[0] === 'before' && row[1] === intervalId).length, 2)
assert.equal(timerRows.filter(row => row[0] === 'after' && row[1] === intervalId).length, 2)
for (const id of [firstTimeoutId, refreshTimeoutId, intervalId, timerIds.get(immediateTimer), timerIds.get(canceledTimer)]) {
  assert(Number.isInteger(id) && id > 0)
  assert.equal(timerRows.filter(row => row[0] === 'destroy' && row[1] === id).length, 1)
}
assert.equal(timerRows.filter(row => row[0] === 'before' && row[1] === timerIds.get(canceledTimer)).length, 0)
timerOrigin.emitDestroy()
console.log('native timeout, immediate, interval, cancel and refresh hooks passed')

const fsDirectory = mkdtempSync(join(tmpdir(), 'home-fs-hooks-'))
mkdirSync(join(fsDirectory, 'tree'))
writeFileSync(join(fsDirectory, 'tree', 'source.txt'), 'native request data')
const fsRows = []
const fsOwners = new Map()
const fsContext = new AsyncLocalStorage()
const fsOrigin = fsContext.run('fs-creation', () => new AsyncResource('home-fs-origin', { requireManualDestroy: true }))
const fsHook = createHook({
  init(id, type, trigger, owner) {
    if (type === 'FSREQPROMISE' || type === 'FSREQCALLBACK') {
      if (type === 'FSREQPROMISE') {
        assert.equal(owner.constructor.name, 'FSReqPromise')
        assert(owner.promise instanceof Promise)
      }
      fsOwners.set(id, owner)
      fsRows.push(['init', id, trigger])
    }
  },
  before(id) {
    if (fsOwners.has(id)) {
      assert.equal(executionAsyncId(), id)
      assert.equal(executionAsyncResource(), fsOwners.get(id))
      assert.equal(fsContext.getStore(), 'fs-creation')
      fsRows.push(['before', id])
    }
  },
  after(id) {
    if (fsOwners.has(id)) { assert.equal(executionAsyncId(), id); fsRows.push(['after', id]) }
  },
  destroy(id) { if (fsOwners.has(id)) fsRows.push(['destroy', id]) },
})
try {
  fsHook.enable()
  const operations = [
    () => fsPromises.stat(join(fsDirectory, 'tree', 'source.txt')),
    () => fsPromises.readFile(join(fsDirectory, 'tree', 'source.txt'), 'utf8'),
    () => fsPromises.writeFile(join(fsDirectory, 'write.txt'), 'written'),
    () => fsPromises.copyFile(join(fsDirectory, 'write.txt'), join(fsDirectory, 'copy.txt')),
    () => fsPromises.readdir(join(fsDirectory, 'tree'), { recursive: true }),
    () => fsPromises.cp(join(fsDirectory, 'tree'), join(fsDirectory, 'tree-copy'), { recursive: true }),
    () => fsPromises.stat(join(fsDirectory, 'ordinary-missing.txt')).then(() => assert.fail('missing stat resolved'), error => assert.equal(error.code, 'ENOENT')),
  ]
  for (const operation of operations) {
    const prior = fsRows.length
    await fsContext.run('fs-creation', () => fsOrigin.runInAsyncScope(() => operation().then(value => {
      assert.equal(fsContext.getStore(), 'fs-creation')
      return value
    })))
    const created = fsRows.slice(prior).filter(row => row[0] === 'init')
    assert(created.length > 0)
    assert.equal(created[0][2], fsOrigin.asyncId())
    assert.equal(fsContext.getStore(), undefined)
  }
  await new Promise(resolve => setImmediate(resolve))
  fsHook.disable()
  for (const id of fsOwners.keys()) {
    assert.equal(fsRows.filter(row => row[0] === 'before' && row[1] === id).length, 1)
    assert.equal(fsRows.filter(row => row[0] === 'after' && row[1] === id).length, 1)
    assert.equal(fsRows.filter(row => row[0] === 'destroy' && row[1] === id).length, 1)
  }
} finally {
  fsHook.disable()
  fsOrigin.emitDestroy()
  fsContext.disable()
  rmSync(fsDirectory, { recursive: true, force: true })
}
console.log('native filesystem request init, completion, failure and teardown hooks passed')

const callbackDirectory = mkdtempSync(join(tmpdir(), 'home-fs-callback-hooks-'))
const callbackPath = join(callbackDirectory, 'data.txt')
writeFileSync(callbackPath, 'callback payload')
const callbackContext = new AsyncLocalStorage()
const callbackOrigin = callbackContext.run('callback-creation', () => new AsyncResource('home-fs-callback-origin', { requireManualDestroy: true }))
const callbackRecords = []
const callbackOwners = new Map()
const callbackHook = createHook({
  init(id, type, trigger, owner) {
    if (type === 'FSREQCALLBACK') {
      callbackOwners.set(id, owner)
      callbackRecords.push(['init', id, trigger])
    }
  },
  before(id) { if (callbackOwners.has(id)) callbackRecords.push(['before', id]) },
  after(id) { if (callbackOwners.has(id)) callbackRecords.push(['after', id]) },
  destroy(id) { if (callbackOwners.has(id)) callbackRecords.push(['destroy', id]) },
})
const callbackFs = await import('node:fs')
function invokeCallback(operation) {
  return new Promise((resolve, reject) => callbackOrigin.runInAsyncScope(() => operation(function (error, value) {
    assert.equal(callbackContext.getStore(), 'callback-creation')
    const id = executionAsyncId()
    assert(callbackOwners.has(id))
    assert.equal(executionAsyncResource(), callbackOwners.get(id))
    if (error) reject(error)
    else resolve(value)
  })))
}
try {
  callbackHook.enable()
  assert.equal(await invokeCallback(done => callbackFs.readFile(callbackPath, 'utf8', done)), 'callback payload')
  await invokeCallback(done => callbackFs.writeFile(callbackPath, 'updated', done))
  assert.equal((await invokeCallback(done => callbackFs.stat(callbackPath, done))).size, 7)
  const fd = await invokeCallback(done => callbackFs.open(callbackPath, 'r', done))
  const buffer = Buffer.alloc(7)
  const bytesRead = await invokeCallback(done => callbackFs.read(fd, buffer, 0, 7, 0, (error, size, returned) => {
    if (!error) assert.equal(returned, buffer)
    done(error, size)
  }))
  assert.equal(bytesRead, 7)
  assert.equal(buffer.toString(), 'updated')
  await invokeCallback(done => callbackFs.close(fd, done))
  await assert.rejects(invokeCallback(done => callbackFs.stat(join(callbackDirectory, 'ordinary-missing'), done)), { code: 'ENOENT' })
  await new Promise(resolve => setImmediate(resolve))
  callbackHook.disable()
  assert(callbackOwners.size >= 6)
  for (const id of callbackOwners.keys()) {
    assert.equal(callbackRecords.filter(row => row[0] === 'before' && row[1] === id).length, 1)
    assert.equal(callbackRecords.filter(row => row[0] === 'after' && row[1] === id).length, 1)
    assert.equal(callbackRecords.filter(row => row[0] === 'destroy' && row[1] === id).length, 1)
  }
  assert.equal(callbackContext.getStore(), undefined)
} finally {
  callbackHook.disable()
  callbackOrigin.emitDestroy()
  callbackContext.disable()
  rmSync(callbackDirectory, { recursive: true, force: true })
}
console.log('native filesystem callback resource scope, results and cleanup passed')

const compoundDirectory = mkdtempSync(join(tmpdir(), 'home-fs-compound-hooks-'))
mkdirSync(join(compoundDirectory, 'child'))
writeFileSync(join(compoundDirectory, 'child', 'entry.txt'), 'x')
const compoundContext = new AsyncLocalStorage()
const compoundOrigin = compoundContext.run('compound-creation', () => new AsyncResource('home-compound-origin', { requireManualDestroy: true }))
const compoundOwners = new Map()
const compoundRows = []
const compoundHook = createHook({
  init(id, type, trigger, owner) { if (type === 'FSREQCALLBACK') { compoundOwners.set(id, owner); compoundRows.push(['init', id, trigger]) } },
  before(id) { if (compoundOwners.has(id)) compoundRows.push(['before', id]) },
  after(id) { if (compoundOwners.has(id)) compoundRows.push(['after', id]) },
  destroy(id) { if (compoundOwners.has(id)) compoundRows.push(['destroy', id]) },
})
function invokeCompound(operation) {
  return new Promise((resolve, reject) => compoundOrigin.runInAsyncScope(() => operation((error, value) => {
    assert.equal(compoundContext.getStore(), 'compound-creation')
    assert(compoundOwners.has(executionAsyncId()))
    assert.equal(executionAsyncResource(), compoundOwners.get(executionAsyncId()))
    if (error) reject(error)
    else resolve(value)
  })))
}
try {
  compoundHook.enable()
  await assert.rejects(invokeCompound(done => callbackFs.rm(join(compoundDirectory, 'child'), done)), { code: 'ERR_FS_EISDIR' })
  const opened = await invokeCompound(done => callbackFs.opendir(join(compoundDirectory, 'child'), done))
  assert.equal(opened.path, join(compoundDirectory, 'child'))
  const entry = await new Promise((resolve, reject) => opened.read((error, value) => error ? reject(error) : resolve(value)))
  assert.equal(entry.name, 'entry.txt')
  await new Promise((resolve, reject) => opened.close(error => error ? reject(error) : resolve()))
  await invokeCompound(done => callbackFs.rm(join(compoundDirectory, 'child'), { recursive: true }, done))
  await new Promise(resolve => setImmediate(resolve))
  compoundHook.disable()
  assert(compoundOwners.size >= 3)
  for (const id of compoundOwners.keys()) {
    assert.equal(compoundRows.filter(row => row[0] === 'before' && row[1] === id).length, 1)
    assert.equal(compoundRows.filter(row => row[0] === 'after' && row[1] === id).length, 1)
    assert.equal(compoundRows.filter(row => row[0] === 'destroy' && row[1] === id).length, 1)
  }
} finally {
  compoundHook.disable()
  compoundOrigin.emitDestroy()
  compoundContext.disable()
  rmSync(compoundDirectory, { recursive: true, force: true })
}
console.log('native compound rm/opendir callback validation and lifecycle passed')

for (const operation of ['close']) {
  const result = spawnSync(process.execPath, ['-e', `
    const fs=require('node:fs');const os=require('node:os');const path=require('node:path');
    const dirPath=fs.mkdtempSync(path.join(os.tmpdir(),'home-dir-callback-error-'));
    fs.writeFileSync(path.join(dirPath,'entry'),'x');
    const marker=new Error('directory callback marker');
    let rejection=false;process.once('unhandledRejection',()=>{rejection=true;process.exitCode=1});
    process.once('uncaughtException',error=>{
      if(error!==marker||rejection)process.exitCode=1;
      else console.log('directory callback uncaught marker');
      fs.rmSync(dirPath,{recursive:true,force:true});
    });
    fs.opendir(dirPath,(error,dir)=>{if(error)throw error;dir.${operation}(()=>{throw marker})});
  `], { encoding: 'utf8', timeout: 60000, env: { ...process.env, BUN_DEBUG_QUIET_LOGS: '1' } })
  assert.equal(result.error, undefined)
  assert.equal(result.signal, null)
  assert.equal(result.stdout.trim(), 'directory callback uncaught marker', result.stderr)
  assert.equal(result.status, 0, result.stderr)
}
console.log('native Dir close callback throws use uncaught exception delivery passed')
