import assert from 'node:assert/strict'
import { X509Certificate } from 'node:crypto'
import { once } from 'node:events'
import { readFileSync } from 'node:fs'
import { basename } from 'node:path'
import tls from 'node:tls'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)

const fixture = name => readFileSync(new URL(`../../packages/runtime/test/bun-corpus/js/node/test/fixtures/keys/${name}`, import.meta.url))
const alternateFixture = name => readFileSync(new URL(`../../packages/runtime/test/bun-corpus/js/node/tls/fixtures/${name}`, import.meta.url))
const key = fixture('agent1-key.pem')
const cert = fixture('agent1-cert.pem')
const alternateKey = alternateFixture('rsa_private.pem')
const alternateCert = alternateFixture('rsa_cert.crt')
const alternateFingerprint = new X509Certificate(alternateCert).fingerprint256

async function bounded(promise, message = 'TLS operation did not settle') {
  let timer
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(message)), 5000) }),
    ])
  } finally {
    clearTimeout(timer)
  }
}

async function listen(server, host = '127.0.0.1') {
  server.listen(0, host)
  await bounded(once(server, 'listening'))
  return server.address().port
}

async function closeServer(server) {
  const closed = once(server, 'close')
  server.close()
  await bounded(closed)
}

async function successfulConnection(port, options = {}) {
  const socket = tls.connect({ port, host: '127.0.0.1', rejectUnauthorized: false, ...options })
  socket.on('error', () => {})
  await bounded(once(socket, 'secureConnect'))
  const result = {
    alpn: socket.alpnProtocol,
    fingerprint: socket.getPeerCertificate().fingerprint256,
  }
  const closed = once(socket, 'close')
  socket.end()
  await bounded(closed)
  return result
}

// Exercise callback precedence, asynchronous suspension, wrapper and raw
// native contexts, dynamic ALPN, repeated handshakes, and forced GC together.
{
  const alternate = tls.createSecureContext({ key: alternateKey, cert: alternateCert })
  let sniCalls = 0
  let alpnCalls = 0
  const server = tls.createServer({
    key,
    cert,
    SNICallback(name, callback) {
      sniCalls++
      setImmediate(() => callback(null, name.startsWith('raw.') ? alternate.context : alternate))
    },
    ALPNCallback({ servername, protocols }) {
      alpnCalls++
      assert.match(servername, /^(?:raw|wrapped)\./)
      assert.deepEqual(protocols, ['http/1.1', 'h2'])
      return 'h2'
    },
  }, socket => socket.end())
  server.on('tlsClientError', error => { throw error })
  const port = await listen(server)
  for (let i = 0; i < 16; i++) {
    const prefix = i % 2 ? 'raw' : 'wrapped'
    const result = await successfulConnection(port, {
      servername: `${prefix}.${i}.example`,
      ALPNProtocols: ['http/1.1', 'h2'],
    })
    assert.equal(result.alpn, 'h2')
    assert.equal(result.fingerprint, alternateFingerprint)
    Bun.gc(true)
  }
  assert.equal(sniCalls, 16)
  assert.equal(alpnCalls, 16)
  await closeServer(server)
}

// A callback must run even when the requested name equals the listener's bind
// hostname; its per-connection choice takes precedence over the static tree.
{
  const selected = tls.createSecureContext({ key: alternateKey, cert: alternateCert })
  let calls = 0
  const server = tls.createServer({ key, cert, SNICallback(name, callback) {
    calls++
    assert.equal(name, 'localhost')
    callback(null, selected)
  } }, socket => socket.end())
  server.on('tlsClientError', error => { throw error })
  const port = await listen(server, 'localhost')
  const socket = tls.connect({ port, host: 'localhost', rejectUnauthorized: false })
  socket.on('error', () => {})
  await bounded(once(socket, 'secureConnect'))
  assert.equal(socket.getPeerCertificate().fingerprint256, alternateFingerprint)
  socket.destroy()
  assert.equal(calls, 1)
  await closeServer(server)
}

// Callback errors, invalid ALPN choices, and non-Error SNI rejections must all
// abort promptly and surface the original server-side failure exactly once.
for (const scenario of [
  { name: 'sync SNI throw', options: { SNICallback() { throw new Error('sync sni failure') } }, message: /sync sni failure/ },
  { name: 'async SNI non-Error', options: { SNICallback(_name, callback) { setImmediate(() => callback('non-error rejection')) } }, message: /SNI callback error/ },
  { name: 'invalid ALPN', options: { ALPNCallback() { return 'not-offered' } }, message: /did not match any/ },
]) {
  const errors = []
  const server = tls.createServer({ key, cert, ...scenario.options })
  server.on('tlsClientError', error => errors.push(error))
  const port = await listen(server)
  const socket = tls.connect({
    port,
    host: '127.0.0.1',
    servername: 'failure.example',
    ALPNProtocols: scenario.name === 'invalid ALPN' ? ['h2'] : undefined,
    rejectUnauthorized: false,
  })
  socket.on('error', () => {})
  await bounded(once(socket, 'error'), `${scenario.name} connection did not fail`)
  await bounded(new Promise(resolve => setImmediate(resolve)))
  assert.equal(errors.length, 1, scenario.name)
  assert.match(errors[0].message, scenario.message, scenario.name)
  await closeServer(server)
}

// A late async resolution after peer destruction is a safe no-op and still
// releases the borrowed native context.
{
  let resolveSNI
  const connections = new Set()
  const server = tls.createServer({ key, cert, SNICallback(_name, callback) {
    resolveSNI = () => callback(null, tls.createSecureContext({ key, cert }).context)
  } })
  server.on('connection', connection => {
    connections.add(connection)
    connection.on('close', () => connections.delete(connection))
  })
  server.on('tlsClientError', () => {})
  const port = await listen(server)
  const socket = tls.connect({ port, host: '127.0.0.1', servername: 'late.example', rejectUnauthorized: false })
  socket.on('error', () => {})
  await bounded(new Promise(resolve => setTimeout(resolve, 50)))
  const closed = once(socket, 'close')
  socket.destroy()
  await bounded(closed)
  resolveSNI()
  Bun.gc(true)
  await bounded(new Promise(resolve => setTimeout(resolve, 25)))
  for (const connection of connections) connection.destroy()
  await closeServer(server)
}

console.log('native TLS SNI suspension and ALPN callback lifecycle passed')
