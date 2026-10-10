import assert from 'node:assert/strict'
import { once } from 'node:events'
import { connect, createServer } from 'node:net'
import { PerformanceObserver, performance } from 'node:perf_hooks'

assert.throws(() => new PerformanceObserver(null), { code: 'ERR_INVALID_ARG_TYPE' })
const delivered = []
const observer = new PerformanceObserver(function (list, owner) {
  assert.equal(this, observer)
  assert.equal(owner, observer)
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
