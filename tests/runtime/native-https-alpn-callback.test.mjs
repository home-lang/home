import assert from 'node:assert/strict'
import { createServer } from 'node:https'
import { connect, createServer as createTLSServer, TLSSocket } from 'node:tls'
import { once } from 'node:events'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const fixture = join(dirname(fileURLToPath(import.meta.url)), '../../packages/runtime/test/test/js/node/http/fixtures')
const cert = readFileSync(join(fixture, 'openssl_localhost.crt'))
const key = readFileSync(join(fixture, 'openssl_localhost.key'))
const ca = readFileSync(join(fixture, 'openssl_localhost_ca.pem'))
assert.throws(() => createServer({ cert, key, ALPNProtocols: ['http/1.1'], ALPNCallback() {} }), { code: 'ERR_TLS_ALPN_CALLBACK_WITH_PROTOCOLS' })
for (const ALPNCallback of [true, false, null, undefined]) {
  assert.doesNotThrow(() => createServer({ cert, key, ALPNCallback }))
}
assert.doesNotThrow(() => createServer({ cert, key, ALPNProtocols: ['http/1.1'], ALPNCallback: false }))
let calls = 0
let server
server = createServer({ cert, key, ALPNCallback(info) {
  calls++
  assert.equal(info.servername, 'localhost')
  assert.deepEqual(info.protocols, ['http/1.0', 'http/1.1'])
  return 'http/1.1'
} }, (req, res) => res.end('callback-selected'))
server.listen(0, '127.0.0.1'); await once(server, 'listening')
for (let index = 0; index < 2; index++) {
  const socket = connect({ host: '127.0.0.1', port: server.address().port, servername: 'localhost', ca, ALPNProtocols: ['http/1.0', 'http/1.1'] })
  await once(socket, 'secureConnect')
  assert.equal(socket.authorized, true)
  assert.equal(socket.alpnProtocol, 'http/1.1')
  let data = ''
  socket.setEncoding('utf8'); socket.on('data', chunk => { data += chunk })
  socket.end('GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n')
  await once(socket, 'close')
  assert(data.includes('callback-selected'))
}
assert.equal(calls, 2)
const closed = once(server, 'close'); server.close(); await closed
// ALPN identifiers are opaque bytes. Node decodes callback names as ASCII,
// but returns the first matching protocol's original bytes to the client.
const offeredBytes = Buffer.from([3, 0xe1, 0, 0x62, 3, 0x61, 0, 0x62, 8, ...Buffer.from('http/1.1')])
for (const useHTTPS of [true, false]) {
  let wireCalls = 0
  const options = { cert, key, ALPNCallback(info) {
    wireCalls++
    assert.deepEqual(info.protocols, ['a\0b', 'a\0b', 'http/1.1'])
    if (!useHTTPS) assert(this instanceof TLSSocket)
    return info.protocols[0]
  } }
  const binaryServer = useHTTPS
    ? createServer(options, (req, res) => res.end('wire-selected'))
    : createTLSServer(options, socket => socket.end('wire-selected'))
  binaryServer.listen(0, '127.0.0.1'); await once(binaryServer, 'listening')
  const socket = connect({ host: '127.0.0.1', port: binaryServer.address().port, servername: 'localhost', ca, ALPNProtocols: offeredBytes })
  await once(socket, 'secureConnect')
  assert.equal(socket.authorized, true)
  assert.equal(socket.alpnProtocol, 'á\0b')
  let data = ''
  socket.setEncoding('utf8'); socket.on('data', chunk => { data += chunk })
  if (useHTTPS) socket.write('GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n')
  await once(socket, 'end')
  assert(data.includes('wire-selected'))
  socket.destroy(); await once(socket, 'close')
  assert.equal(wireCalls, 1)
  const closed = once(binaryServer, 'close'); binaryServer.close(); await closed
}
console.log('native ALPN callback arguments, ASCII aliases, original wire selection and repeated handshakes passed')
