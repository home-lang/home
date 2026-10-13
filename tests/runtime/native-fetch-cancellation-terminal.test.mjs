import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { once } from 'node:events'
import { performance, PerformanceObserver } from 'node:perf_hooks'

const closed = new Map()
const server = createServer((request, response) => {
  let resolve
  closed.set(request.url, new Promise(done => { resolve = done }))
  response.on('close', resolve)
  response.writeHead(200, { 'content-type': 'text/plain' })
  response.write('partial')
})
server.listen(0, '127.0.0.1')
await once(server, 'listening')
const base = `http://127.0.0.1:${server.address().port}`
const entries = new Map()
const waiters = new Map()
const observer = new PerformanceObserver(list => {
  for (const entry of list.getEntries()) {
    entries.set(entry.name, entry)
    waiters.get(entry.name)?.(entry)
  }
})
observer.observe({ type: 'resource' })
const deadline = promise => {
  let timer
  return Promise.race([promise, new Promise((resolve, reject) => { timer = setTimeout(() => reject(new Error('native cancellation did not finish')), 5000) })]).finally(() => clearTimeout(timer))
}
try {
  for (const mode of ['cancel', 'abort']) {
    const url = `${base}/${mode}`
    const controller = new AbortController()
    const response = await fetch(url, { signal: controller.signal })
    if (mode === 'cancel') await response.body.cancel()
    else {
      controller.abort()
      await assert.rejects(response.text(), error => error.name === 'AbortError')
    }
    await deadline(closed.get(`/${mode}`))
    // Home's native resource producer reports actual termination milestones.
    // Node's resource timeline policy is independently observed by reference.
    if (globalThis.Bun) {
      const entry = entries.get(url) || await deadline(new Promise(resolve => waiters.set(url, resolve)))
      assert.equal(entry.responseStatus, 200)
      assert(entry.responseEnd >= entry.responseStart)
      assert(entry.responseStart >= entry.requestStart)
      assert.equal(entry.encodedBodySize, 7)
      assert.equal(entry.decodedBodySize, 7)
      assert.equal(performance.getEntriesByName(url, 'resource').length, 1)
    }
  }
} finally {
  observer.disconnect()
  server.closeAllConnections()
  await new Promise(resolve => server.close(resolve))
}
console.log('explicit response cancellation and abort terminate the native request and preserve measured timing')
