import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { createServer as createSecureServer } from 'node:https'
import { createServer as createTLSListener } from 'node:tls'
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
const hostnameURL = `http://localhost:${plain.address().port}/lookup`
const hostnameResponse = await fetch(hostnameURL)
assert.equal(await hostnameResponse.text(), 'connection')
await new Promise(resolve => setImmediate(resolve))
const lookup = performance.getEntriesByName(hostnameURL, 'resource')[0]
assert(lookup.domainLookupStart >= lookup.startTime)
assert(lookup.domainLookupEnd >= lookup.domainLookupStart)
assert(lookup.connectStart >= lookup.domainLookupEnd)
const plainClosed = once(plain, 'close'); plain.close(); await plainClosed

const fixture = join(import.meta.dir, '../../packages/runtime/test/test/js/node/http/fixtures')
const cert = readFileSync(join(fixture, 'openssl_localhost.crt'))
const ca = readFileSync(join(fixture, 'openssl_localhost_ca.pem'))
const secure = createSecureServer({ cert, key: readFileSync(join(fixture, 'openssl_localhost.key')), ALPNProtocols: ['http/1.1'] }, (req, res) => res.end('secure'))
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
assert.equal(entry.nextHopProtocol, 'http/1.1')
const reusedResponse = await fetch(secureURL + 'reused', { tls: { ca } })
assert.equal(await reusedResponse.text(), 'secure')
await new Promise(resolve => setImmediate(resolve))
const reusedTLS = performance.getEntriesByName(secureURL + 'reused', 'resource')[0]
assert.equal(reusedTLS.nextHopProtocol, 'http/1.1')
assert.equal(reusedTLS.secureConnectionStart, undefined)
const secureClosed = once(secure, 'close'); secure.close(); await secureClosed
const alpnServer = createTLSListener({ cert, key: readFileSync(join(fixture, 'openssl_localhost.key')), ALPNProtocols: ['http/1.1'] }, socket => {
  socket.once('data', () => socket.end('HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nalpn'))
})
alpnServer.listen(0, '127.0.0.1'); await once(alpnServer, 'listening')
const alpnURL = `https://127.0.0.1:${alpnServer.address().port}/`
const alpnResponse = await fetch(alpnURL, { tls: { ca } })
assert.equal(await alpnResponse.text(), 'alpn')
await new Promise(resolve => setImmediate(resolve))
assert.equal(performance.getEntriesByName(alpnURL, 'resource')[0].nextHopProtocol, 'http/1.1')
const alpnClosed = once(alpnServer, 'close'); alpnServer.close(); await alpnClosed
const preferred = createSecureServer({ cert, key: readFileSync(join(fixture, 'openssl_localhost.key')), ALPNProtocols: Buffer.from([8, ...Buffer.from('http/1.1'), 8, ...Buffer.from('http/1.0')]) }, (req, res) => res.end('selected'))
preferred.listen(0, '127.0.0.1'); await once(preferred, 'listening')
const preferredURL = `https://127.0.0.1:${preferred.address().port}/`
const preferredResponse = await fetch(preferredURL, { tls: { ca } })
assert.equal(await preferredResponse.text(), 'selected')
await new Promise(resolve => setImmediate(resolve))
assert.equal(performance.getEntriesByName(preferredURL, 'resource')[0].nextHopProtocol, 'http/1.1')
const preferredClosed = once(preferred, 'close'); preferred.close(); await preferredClosed
performance.clearResourceTimings()
console.log('native fresh/pooled TCP and verified TLS resource connection milestones passed')
