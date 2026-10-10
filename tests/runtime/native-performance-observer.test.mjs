import assert from 'node:assert/strict'
import { once } from 'node:events'
import { connect, createServer } from 'node:net'
import { PerformanceObserver, PerformanceObserverEntryList, performance } from 'node:perf_hooks'

assert.equal(PerformanceObserverEntryList.length, 0)
assert.equal(PerformanceObserverEntryList.prototype.getEntries.length, 0)
assert.equal(PerformanceObserverEntryList.prototype.getEntriesByType.length, 1)
assert.equal(PerformanceObserverEntryList.prototype.getEntriesByName.length, 1)
assert.throws(() => new PerformanceObserverEntryList(), { code: 'ERR_ILLEGAL_CONSTRUCTOR' })
for (const method of ['getEntries', 'getEntriesByName', 'getEntriesByType']) {
  assert.throws(() => PerformanceObserverEntryList.prototype[method].call({}), { code: 'ERR_INVALID_THIS' })
}
assert.throws(() => new PerformanceObserver(null), { code: 'ERR_INVALID_ARG_TYPE' })
const delivered = []
const observer = new PerformanceObserver(function (list, owner) {
  assert.equal(this, observer)
  assert.equal(owner, observer)
  assert(list instanceof PerformanceObserverEntryList)
  assert.equal(Object.prototype.toString.call(list), '[object PerformanceObserverEntryList]')
  assert.throws(() => list.getEntriesByType(), { code: 'ERR_MISSING_ARGS' })
  assert.throws(() => list.getEntriesByName(), { code: 'ERR_MISSING_ARGS' })
  const all = list.getEntries()
  const copy = list.getEntries()
  copy.length = 0
  assert.equal(list.getEntries().length, all.length)
  for (const entry of all) {
    assert(list.getEntriesByType({ toString: () => entry.entryType }).includes(entry))
    assert(list.getEntriesByName({ toString: () => entry.name }, null).includes(entry))
    assert(list.getEntriesByName(entry.name, entry.entryType).includes(entry))
  }
  delivered.push(...list.getEntries())
})
observer.observe({ entryTypes: ['net', 'mark'] })
assert.throws(() => observer.observe({ type: 'net' }), { name: 'InvalidModificationError' })
assert.throws(() => observer.observe({ entryTypes: 'net' }), { code: 'ERR_INVALID_ARG_TYPE' })
assert.throws(() => observer.observe({ type: 'net', entryTypes: ['mark'] }), { code: 'ERR_INVALID_ARG_VALUE' })
const empty = new PerformanceObserver(() => {})
empty.observe({ entryTypes: [] })
empty.observe({ type: 'mark' })
empty.disconnect()
const server = createServer(socket => socket.end())
server.listen(0, '127.0.0.1')
await once(server, 'listening')
performance.mark('before-connect')
const socket = connect({ port: server.address().port, host: '127.0.0.1' })
const closed = once(socket, 'close')
await once(socket, 'connect')
performance.mark('after-connect')
const records = observer.takeRecords()
assert(records.some(entry => entry.entryType === 'net' && entry.name === 'connect'))
assert(records.some(entry => entry.entryType === 'mark' && entry.name === 'after-connect'))
assert(records.every((entry, index) => index === 0 || records[index - 1].startTime <= entry.startTime))
assert.deepEqual(observer.takeRecords(), [])
await closed
await new Promise(resolve => setImmediate(resolve))
assert(!delivered.some(entry => entry.name === 'after-connect' || entry.entryType === 'net'))
performance.mark('discarded')
observer.disconnect()
observer.observe({ type: 'mark' })
performance.mark('fresh')
await new Promise(resolve => setImmediate(resolve))
await new Promise(resolve => setImmediate(resolve))
assert(!delivered.some(entry => entry.name === 'discarded'))
assert.equal(delivered.filter(entry => entry.name === 'fresh').length, 1)
observer.disconnect()
let batches = 0
let finishDelivery
const delivery = new Promise(resolve => { finishDelivery = resolve })
const mergedObserver = new PerformanceObserver(list => {
  batches++
  assert(list instanceof PerformanceObserverEntryList)
  const entries = list.getEntries()
  assert(entries.some(entry => entry.entryType === 'net'))
  assert(entries.some(entry => entry.name === 'merged-mark'))
  finishDelivery()
})
mergedObserver.observe({ entryTypes: ['net', 'mark'] })
const mergedSocket = connect({ port: server.address().port, host: '127.0.0.1' })
const mergedClosed = once(mergedSocket, 'close')
await once(mergedSocket, 'connect')
performance.mark('merged-mark')
await delivery
await mergedClosed
await new Promise(resolve => setImmediate(resolve))
assert.equal(batches, 1)
mergedObserver.disconnect()
const serverClosed = once(server, 'close')
server.close()
await serverClosed
performance.clearMarks()
console.log('native observer mixed queue draining, atomic validation, mode reset and callback receiver passed')
