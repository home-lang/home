import assert from 'node:assert/strict'
import { PerformanceObserver, performance as nodePerformance } from 'node:perf_hooks'
import { createServer } from 'node:http'
import { once } from 'node:events'
import { gzipSync } from 'node:zlib'

performance.clearResourceTimings()
const payload = 'fetch resource body'
const compressed = gzipSync(payload)
const server = createServer((request, response) => {
  response.setHeader('content-type', 'text/plain')
  if (request.url === '/gzip') {
    response.setHeader('content-encoding', 'gzip')
    response.end(compressed)
  } else if (request.url === '/stream' || request.url === '/stream-cancel') {
    response.write('fetch ')
    setTimeout(() => response.end('resource body'), 10)
  } else response.end(payload)
})
server.listen(0, '127.0.0.1')
await once(server, 'listening')
const base = `http://127.0.0.1:${server.address().port}`
const observed = []
const observer = new PerformanceObserver(list => observed.push(...list.getEntries()))
observer.observe({ type: 'resource' })
for (const path of ['/plain', '/stream', '/gzip']) {
  const before = performance.now()
  const response = await fetch(base + path)
  assert.equal(await response.text(), payload)
  await new Promise(resolve => setImmediate(resolve))
  const entries = performance.getEntriesByName(base + path, 'resource')
  assert.equal(entries.length, 1)
  const entry = entries[0]
  assert.equal(nodePerformance.getEntriesByName(base + path, 'resource')[0], entry)
  assert.equal(entry.initiatorType, 'fetch')
  assert.equal(entry.responseStatus, 200)
  assert(entry.startTime >= before)
  assert(entry.responseEnd >= entry.responseStart)
  assert(entry.responseStart >= entry.requestStart)
  assert.equal(entry.decodedBodySize, Buffer.byteLength(payload))
  assert.equal(entry.encodedBodySize, path === '/gzip' ? compressed.length : Buffer.byteLength(payload))
  assert.equal(entry.contentType, 'text/plain')
}
const canceled = await fetch(base + '/stream-cancel')
await canceled.body.cancel()
await new Promise(resolve => setTimeout(resolve, 20))
assert.equal(performance.getEntriesByName(base + '/stream-cancel', 'resource').length, 1)
await new Promise(resolve => setImmediate(resolve))
assert.equal(observed.length, 4)
observer.disconnect()
const closed = once(server, 'close')
server.close()
await closed
performance.clearResourceTimings()
console.log('native fetch automatic resource timing, streamed completion, body sizes and shared observer identity passed')
