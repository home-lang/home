import assert from 'node:assert/strict'
import { X509Certificate } from 'node:crypto'
import { once } from 'node:events'
import { readFileSync } from 'node:fs'
import net from 'node:net'
import { basename } from 'node:path'
import { Duplex } from 'node:stream'
import tls from 'node:tls'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const fixture = name => readFileSync(new URL(`../../packages/runtime/test/test/js/node/test/fixtures/keys/${name}`, import.meta.url))
const key = fixture('agent1-key.pem')
const cert = fixture('agent1-cert.pem')
const ca = fixture('ca1-cert.pem')
const leaf = new X509Certificate(cert)
const root = new X509Certificate(ca)

async function bounded(promise) {
  let timer
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('TLS context operation did not settle')), 5000)
    })])
  } finally { clearTimeout(timer) }
}

async function withServer(options, run) {
  const sockets = new Set()
  const seen = []
  const server = tls.createServer({ key, cert, ...options })
  server.on('connection', socket => {
    sockets.add(socket)
    socket.on('close', () => sockets.delete(socket))
  })
  server.on('tlsClientError', () => {})
  server.on('secureConnection', socket => {
    socket.on('error', () => {})
    seen.push({ authorized: socket.authorized, certificate: socket.getPeerCertificate(true), protocol: socket.getProtocol() })
    socket.end('verified bytes')
  })
  server.listen(0, '127.0.0.1')
  await bounded(once(server, 'listening'))
  try { await run(server.address().port, seen) } finally {
    const closed = once(server, 'close')
    for (const socket of sockets) socket.destroy()
    server.close()
    await bounded(closed)
  }
}

async function connect(port, options = {}) {
  let socket
  try {
    return await bounded(new Promise((resolve, reject) => {
      socket = tls.connect({ port, host: '127.0.0.1', servername: 'agent1', ca, rejectUnauthorized: true, ...options })
      const result = { body: '' }
      socket.on('data', chunk => { result.body += chunk.toString() })
      socket.on('error', error => { result.error = error })
      socket.on('secureConnect', () => {
        try {
          result.authorized = socket.authorized
          result.authorizationError = socket.authorizationError
          result.protocol = socket.getProtocol()
          result.certificate = socket.getPeerCertificate(true)
          result.abbreviated = socket.getPeerCertificate()
          result.x509 = socket.getPeerX509Certificate()
        } catch (error) { reject(error); socket.destroy() }
      })
      socket.on('close', () => resolve(result))
    }))
  } finally { socket?.destroy() }
}

// Private native handles and CA changes must remain isolated from peers and
// the internal cache, including after GC while connections retain their refs.
const a = tls.createSecureContext({})
const b = tls.createSecureContext({})
assert(a.context)
assert(b.context)
assert.notEqual(a.context, b.context)
assert.throws(() => a.context.addCACert(), /requires a certificate/)
assert.throws(() => a.context.addCACert(''), /requires a certificate/)
assert.throws(() => a.context.addCACert('not a certificate'), /Invalid CA certificate/)
a.context.addCACert(ca)
await withServer({}, async port => {
  const trusted = await connect(port, { ca: undefined, secureContext: a })
  assert.ifError(trusted.error)
  assert.equal(trusted.authorized, true)
  assert.equal(trusted.body, 'verified bytes')
  assert.equal(trusted.certificate.fingerprint256, leaf.fingerprint256)
  assert.equal(trusted.certificate.issuerCertificate.fingerprint256, root.fingerprint256)
  assert.equal(trusted.certificate.issuerCertificate.issuerCertificate, trusted.certificate.issuerCertificate)
  assert.equal(trusted.abbreviated.issuerCertificate, undefined)
  assert.equal(trusted.x509.fingerprint256, leaf.fingerprint256)
  Bun.gc(true)
  const untrusted = await connect(port, { ca: undefined, secureContext: b })
  assert(untrusted.error, 'CA mutation must not authorize a distinct context')
  const cached = await connect(port, { ca: undefined })
  assert(cached.error, 'CA mutation must not change the default cached trust store')
  const mismatch = await connect(port, { servername: 'wrong.example' })
  assert.equal(mismatch.error?.code, 'ERR_TLS_CERT_ALTNAME_INVALID')
  const optional = await connect(port, { servername: 'wrong.example', rejectUnauthorized: false })
  assert.ifError(optional.error)
  assert.equal(optional.authorized, false)
  assert.match(optional.authorizationError, /ALTNAME/)
})

// Exact negotiated versions prove that native option parsing and context
// hashing preserve each limit, not just that the JS properties are accepted.
for (const version of ['TLSv1.2', 'TLSv1.3']) {
  await withServer({ minVersion: version, maxVersion: version }, async (port, seen) => {
    const good = await connect(port, { minVersion: version, maxVersion: version })
    assert.ifError(good.error)
    assert.equal(good.protocol, version)
    assert.equal(seen.at(-1).protocol, version)
    const other = version === 'TLSv1.2' ? 'TLSv1.3' : 'TLSv1.2'
    const bad = await connect(port, { minVersion: other, maxVersion: other })
    assert(bad.error, 'disjoint TLS version ranges must reject')
    const recovered = await connect(port, { minVersion: version, maxVersion: version })
    assert.ifError(recovered.error)
    assert.equal(recovered.protocol, version)
  })
}

await withServer({ requestCert: true, rejectUnauthorized: true, ca }, async (port, seen) => {
  const mutual = await connect(port, { key, cert })
  assert.ifError(mutual.error)
  assert.equal(mutual.authorized, true)
  assert.equal(seen.at(-1).authorized, true)
  assert.equal(seen.at(-1).certificate.fingerprint256, leaf.fingerprint256)
  const accepted = seen.length
  const absent = await connect(port)
  assert.equal(absent.body, '', 'missing client certificate must not receive application bytes')
  assert.equal(seen.length, accepted, 'missing client certificate must not reach secureConnection')
})

// Binary PKCS#12 inputs, including an offset view, must retain exact DER bytes.
const pfx = fixture('agent1.pfx')
const pfxStorage = new Uint8Array(pfx.length + 12)
pfxStorage.set(pfx, 5)
for (const bytes of [pfx, pfxStorage.subarray(5, 5 + pfx.length)]) {
  const context = tls.createSecureContext({ pfx: bytes, passphrase: 'sample', ca })
  assert(context.context)
  await withServer({ requestCert: true, rejectUnauthorized: true, ca }, async (port, seen) => {
    const result = await connect(port, { secureContext: context })
    assert.ifError(result.error)
    assert.equal(seen.at(-1).authorized, true)
    assert.equal(seen.at(-1).certificate.fingerprint256, leaf.fingerprint256)
  })
}
assert.throws(() => tls.createSecureContext({ pfx, passphrase: 'wrong' }), /MAC verification failed/)
assert.throws(() => tls.createSecureContext({ pfx: fixture('cert-without-key.pfx'), passphrase: 'test' }), /Unable to load private key/)
assert.throws(() => tls.createSecureContext({ pfx: Buffer.alloc(0) }), /PFX certificate argument is mandatory/)

// A server over a generic Duplex has a separate native lifetime mode, but it
// must never apply client-side hostname verification to a client's certificate.
{
  let raw, duplex, wrapped, client
  const verified = Promise.withResolvers()
  const server = net.createServer(socket => {
    raw = socket
    raw.on('error', verified.reject)
    duplex = Duplex.from({ readable: socket, writable: socket })
    duplex.on('error', verified.reject)
    const context = tls.createSecureContext({ key, cert, ca, servername: 'not-the-client.example', requestCert: true, rejectUnauthorized: true })
    wrapped = new tls.TLSSocket(duplex, { isServer: true, secureContext: context, requestCert: true, rejectUnauthorized: true })
    wrapped.on('error', verified.reject)
    wrapped.on('close', () => verified.reject(new Error('TLS server closed before role verification')))
    wrapped.on('secure', () => {
      try {
        assert.equal(wrapped._handle.authorized, true)
        assert.equal(wrapped._handle.getAuthorizationError(), null)
        assert.equal(wrapped.getPeerCertificate().fingerprint256, leaf.fingerprint256)
        verified.resolve()
      } catch (error) { verified.reject(error) }
    })
  })
  server.listen(0, '127.0.0.1')
  await bounded(once(server, 'listening'))
  try {
    client = tls.connect({ port: server.address().port, host: '127.0.0.1', servername: 'agent1', key, cert, ca, rejectUnauthorized: true })
    client.on('error', verified.reject)
    await bounded(Promise.all([verified.promise, once(client, 'secureConnect')]))
    assert.equal(client.authorized, true)
  } finally {
    const closed = once(server, 'close')
    client?.destroy()
    wrapped?.destroy()
    duplex?.destroy()
    raw?.destroy()
    server.close()
    await bounded(closed)
  }
}

// Repeated detailed-chain conversions release owned server leaf / issuer refs.
await withServer({ requestCert: true, rejectUnauthorized: true, ca }, async port => {
  for (let i = 0; i < 24; i++) {
    const context = tls.createSecureContext({ key, cert, ca })
    const result = await connect(port, { secureContext: context })
    assert.ifError(result.error)
    assert.equal(result.certificate.fingerprint256, leaf.fingerprint256)
    assert.equal(result.certificate.issuerCertificate.fingerprint256, root.fingerprint256)
    Bun.gc(true)
  }
})
console.log('native TLS private contexts, CA isolation, chains, versions and PFX passed')
