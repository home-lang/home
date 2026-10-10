import assert from 'node:assert/strict'
import { createServer } from 'node:https'
import { connect } from 'node:tls'
import { once } from 'node:events'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

const fixture = join(import.meta.dir, '../../packages/runtime/test/test/js/node/http/fixtures')
const cert = readFileSync(join(fixture, 'openssl_localhost.crt'))
const key = readFileSync(join(fixture, 'openssl_localhost.key'))
const ca = readFileSync(join(fixture, 'openssl_localhost_ca.pem'))
async function negotiate(port, protocols, expected, hostname = 'localhost') {
  const socket = connect({ host: '127.0.0.1', port, servername: hostname, ca, ALPNProtocols: protocols })
  await once(socket, 'secureConnect')
  assert.equal(socket.authorized, true)
  assert.equal(socket.alpnProtocol, expected)
  socket.write('GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n')
  let data = ''
  socket.setEncoding('utf8'); socket.on('data', chunk => { data += chunk })
  await once(socket, 'end')
  assert(data.includes('alpn-storage'))
}
const encoded = Buffer.from([3, 97, 0, 98, 8, ...Buffer.from('http/1.1')])
const server = createServer({ cert, key, ALPNProtocols: encoded }, (req, res) => res.end('alpn-storage'))
server.listen(0, '127.0.0.1'); await once(server, 'listening')
encoded.fill(120)
await negotiate(server.address().port, ['a\0b', 'http/1.1'], 'a\0b')
await negotiate(server.address().port, ['http/1.1'], 'http/1.1')
const other = createServer({ cert, key, ALPNProtocols: ['http/1.1', 'a\0b'] }, (req, res) => res.end('alpn-storage'))
other.listen(0, '127.0.0.1'); await once(other, 'listening')
await negotiate(other.address().port, ['a\0b', 'http/1.1'], 'http/1.1')
const otherClosed = once(other, 'close'); other.close(); await otherClosed
const closed = once(server, 'close'); server.close(); await closed

const sni = Bun.serve({
  hostname: '127.0.0.1', port: 0,
  tls: [
    { cert, key, ALPNProtocols: Buffer.from([8, ...Buffer.from('http/1.0')]) },
    { cert, key, serverName: 'localhost', ALPNProtocols: Buffer.from([8, ...Buffer.from('http/1.1')]) },
  ],
  fetch() { return new Response('alpn-storage') },
})
await negotiate(sni.port, ['http/1.0', 'http/1.1'], 'http/1.1')
sni.stop(true)
console.log('native binary ALPN storage, input ownership, preference and SNI selector handoff passed')
