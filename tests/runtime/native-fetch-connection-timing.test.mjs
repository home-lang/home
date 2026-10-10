import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { createServer as createSecureServer } from 'node:https'
import { once } from 'node:events'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

performance.clearResourceTimings()
const plain = createServer((req, res) => res.end('connection'))
plain.listen(0, '127.0.0.1'); await once(plain, 'listening')
const url = `http://127.0.0.1:${plain.address().port}`
for (const suffix of ['/first', '/pooled']) {
  const response = await fetch(url + suffix)
  assert.equal(await response.text(), 'connection')
  await new Promise(resolve => setImmediate(resolve))
}
const first = performance.getEntriesByName(url + '/first', 'resource')[0]
assert(first.connectStart >= first.fetchStart)
assert(first.connectEnd >= first.connectStart)
assert(first.requestStart >= first.connectEnd)
assert.equal(first.secureConnectionStart, undefined)
const pooled = performance.getEntriesByName(url + '/pooled', 'resource')[0]
assert.equal(pooled.connectStart, undefined)
assert.equal(pooled.connectEnd, undefined)
assert.equal(pooled.secureConnectionStart, undefined)
const plainClosed = once(plain, 'close'); plain.close(); await plainClosed

const fixture = join(import.meta.dir, '../../packages/runtime/test/test/js/node/http/fixtures')
const cert = readFileSync(join(fixture, 'openssl_localhost.crt'))
const ca = readFileSync(join(fixture, 'openssl_localhost_ca.pem'))
const secure = createSecureServer({ cert, key: readFileSync(join(fixture, 'openssl_localhost.key')) }, (req, res) => res.end('secure'))
secure.listen(0, '127.0.0.1'); await once(secure, 'listening')
const secureURL = `https://127.0.0.1:${secure.address().port}/`
const response = await fetch(secureURL, { tls: { ca } })
assert.equal(await response.text(), 'secure')
await new Promise(resolve => setImmediate(resolve))
const entry = performance.getEntriesByName(secureURL, 'resource')[0]
assert(entry.connectStart >= entry.fetchStart)
assert(entry.secureConnectionStart >= entry.connectStart)
assert(entry.connectEnd >= entry.secureConnectionStart)
assert(entry.requestStart >= entry.connectEnd)
assert(entry.responseStart >= entry.requestStart)
const secureClosed = once(secure, 'close'); secure.close(); await secureClosed
performance.clearResourceTimings()
console.log('native fresh/pooled TCP and verified TLS resource connection milestones passed')
