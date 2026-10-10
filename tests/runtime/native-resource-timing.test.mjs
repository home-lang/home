import assert from 'node:assert/strict'
import { PerformanceEntry, PerformanceObserver, PerformanceResourceTiming, performance } from 'node:perf_hooks'

const makeTiming = start => ({
  startTime: start, endTime: start + 10, finalServiceWorkerStartTime: 0,
  redirectStartTime: 0, redirectEndTime: 0, postRedirectStartTime: start,
  finalNetworkRequestStartTime: start + 2, finalNetworkResponseStartTime: start + 4,
  firstInterimNetworkResponseStartTime: start + 3, encodedBodySize: 20, decodedBodySize: 30,
  finalConnectionTimingInfo: { domainLookupStartTime: start, domainLookupEndTime: start + 1,
    connectionStartTime: start + 1, connectionEndTime: start + 2, secureConnectionStartTime: 0,
    ALPNNegotiatedProtocol: 'h2' }, renderBlocking: true,
})
performance.clearResourceTimings()
performance.setResourceTimingBufferSize(250)
assert.throws(() => new PerformanceResourceTiming(), { code: 'ERR_ILLEGAL_CONSTRUCTOR' })
const timing = makeTiming(10)
const resource = performance.markResourceTiming(timing, 'https://example.test/resource', 'fetch', globalThis, '', { contentType: 'text/plain', contentEncoding: 'gzip' }, 200, 'cache')
assert(resource instanceof PerformanceResourceTiming)
assert(resource instanceof PerformanceEntry)
assert.equal(Object.prototype.toString.call(resource), '[object PerformanceResourceTiming]')
assert.equal(resource.name, 'https://example.test/resource')
assert.equal(resource.entryType, 'resource')
assert.equal(resource.startTime, 10)
assert.equal(resource.duration, 10)
assert.equal(resource.responseStart, 13)
assert.equal(resource.finalResponseHeadersStart, 14)
assert.equal(resource.firstInterimResponseStart, 13)
assert.equal(resource.transferSize, 320)
assert.equal(resource.encodedBodySize, 20)
assert.equal(resource.decodedBodySize, 30)
assert.equal(resource.nextHopProtocol, 'h2')
assert.equal(resource.responseStatus, 200)
assert.equal(resource.deliveryType, 'cache')
assert.equal(resource.contentType, 'text/plain')
assert.equal(resource.contentEncoding, 'gzip')
assert.equal(resource.renderBlockingStatus, 'blocking')
const json = resource.toJSON()
assert.equal(json.name, resource.name)
assert.equal(json.responseStatus, 200)
timing.endTime = 25
assert.equal(resource.duration, 15)
assert.equal(resource.responseEnd, 25)
assert.equal(performance.getEntriesByName(resource.name, 'resource')[0], resource)
assert(performance.getEntries().includes(resource))
const copied = performance.getEntriesByType('resource')
copied.length = 0
assert.equal(performance.getEntriesByType('resource').length, 1)
const local = performance.markResourceTiming(makeTiming(20), 'local', 'fetch', globalThis, 'local')
assert.equal(local.transferSize, 0)
assert.throws(() => performance.markResourceTiming({}, 'invalid', 'fetch', globalThis, 'other'), { code: 'ERR_INTERNAL_ASSERTION' })
assert.throws(() => PerformanceResourceTiming.prototype.toJSON.call({}), { code: 'ERR_INVALID_THIS' })

let bufferedEntries
const buffered = new PerformanceObserver(list => { bufferedEntries = list.getEntries() })
buffered.observe({ type: 'resource', buffered: true })
await new Promise(resolve => setImmediate(resolve))
await new Promise(resolve => setImmediate(resolve))
assert.deepEqual(bufferedEntries, [resource, local])
buffered.disconnect()
performance.clearResourceTimings()
assert.deepEqual(performance.getEntriesByType('resource'), [])
performance.setResourceTimingBufferSize(1)
let fullEvents = 0
let handlerEvents = 0
performance.onresourcetimingbufferfull = () => { handlerEvents++ }
const onFull = () => { fullEvents++; performance.setResourceTimingBufferSize(2) }
performance.addEventListener('resourcetimingbufferfull', onFull)
const first = performance.markResourceTiming(makeTiming(30), 'first', 'fetch', globalThis, '')
const second = performance.markResourceTiming(makeTiming(40), 'second', 'fetch', globalThis, '')
assert.deepEqual(performance.getEntriesByType('resource'), [first])
await new Promise(resolve => setImmediate(resolve))
assert.deepEqual(performance.getEntriesByType('resource'), [first, second])
assert(fullEvents >= 1)
assert(handlerEvents >= 1)
performance.onresourcetimingbufferfull = null
performance.removeEventListener('resourcetimingbufferfull', onFull)
performance.clearResourceTimings()
performance.setResourceTimingBufferSize(250)
console.log('native Node resource timing fields, identity, live timing, timeline, buffered observer and overflow passed')
