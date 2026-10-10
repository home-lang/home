import assert from 'node:assert/strict'
import { createServer } from 'node:https'
import { connect } from 'node:tls'
import { once } from 'node:events'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const fixture = join(dirname(fileURLToPath(import.meta.url)), '../../packages/runtime/test/test/js/node/http/fixtures')
const cert = readFileSync(join(fixture, 'openssl_localhost.crt'))
const key = readFileSync(join(fixture, 'openssl_localhost.key'))
const ca = readFileSync(join(fixture, 'openssl_localhost_ca.pem'))
assert.throws(() => createServer({ cert, key, ALPNProtocols: ['http/1.1'], ALPNCallback() {} }), { code: 'ERR_TLS_ALPN_CALLBACK_WITH_PROTOCOLS' })
assert.throws(() => createServer({ cert, key, ALPNCallback: true }), { code: 'ERR_INVALID_ARG_TYPE' })
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
console.log('native HTTPS ALPN callback arguments, offered selection and repeated handshakes passed')
