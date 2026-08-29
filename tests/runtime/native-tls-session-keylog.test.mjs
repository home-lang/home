import assert from 'node:assert/strict'
import { once } from 'node:events'
import { readFileSync } from 'node:fs'
import net from 'node:net'
import { basename } from 'node:path'
import { Duplex } from 'node:stream'
import tls from 'node:tls'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const fixture = name => readFileSync(new URL(`../../packages/runtime/test/bun-corpus/js/node/test/fixtures/keys/${name}`, import.meta.url))
const key = fixture('agent1-key.pem')
const cert = fixture('agent1-cert.pem')

async function bounded(promise) {
  let timer
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('TLS session/keylog operation did not settle')), 5000)
    })])
  } finally { clearTimeout(timer) }
}

async function listen(server) {
  server.listen(0, '127.0.0.1')
  await bounded(once(server, 'listening'))
  return server.address().port
}

async function closeServer(server) {
  const closed = once(server, 'close')
  server.close()
  await bounded(closed)
}

function validateKeylog(line) {
  assert(Buffer.isBuffer(line))
  assert(line.length > 0)
  assert.equal(line.at(-1), 0x0a)
  assert.match(line.toString(), /^(?:CLIENT|SERVER)_[A-Z0-9_]+ [0-9a-f]+ [0-9a-f]+\n$/i)
}

// A TLS 1.3 ticket can share a native read with application data. The session
// event must run first because the data consumer is allowed to destroy the
// socket synchronously.
{
  const serverKeylogs = []
  const server = tls.createServer({ key, cert }, socket => {
    socket.on('error', () => {})
    socket.on('data', () => socket.write('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok'))
  })
  server.on('keylog', (line, socket) => {
    assert(socket instanceof tls.TLSSocket)
    serverKeylogs.push(Buffer.from(line))
  })
  server.on('tlsClientError', () => {})
  const port = await listen(server)
  const order = []
  let session
  let keylog
  const client = tls.connect({ port, host: '127.0.0.1', rejectUnauthorized: false })
  client.on('error', () => {})
  client.once('session', value => {
    session = value
    order.push('session')
  })
  client.once('keylog', value => { keylog = value })
  client.once('secureConnect', () => client.write('x'))
  client.once('data', () => {
    order.push('data')
    client.destroy()
  })
  await bounded(once(client, 'close'))
  assert(Buffer.isBuffer(session))
  assert(session.length > 0)
  validateKeylog(keylog)
  assert.deepEqual(order, ['session', 'data'])
  assert(serverKeylogs.length > 0)
  validateKeylog(serverKeylogs[0])
  await closeServer(server)
  Bun.gc(true)
}

// A generic Duplex has no us_socket_t, so SSLWrapper must opt into and drain
// the same parked queues itself. Destroying from the session callback also
// proves it rechecks wrapper ownership before touching the SSL again.
{
  class SocketProxy extends Duplex {
    constructor(socket) {
      super()
      this.socket = socket
      socket.on('data', chunk => { if (!this.push(chunk)) socket.pause() })
      socket.on('end', () => this.push(null))
      socket.on('close', () => this.push(null))
      socket.on('error', error => this.destroy(error))
    }

    _read() { this.socket.resume() }
    _write(chunk, encoding, callback) { this.socket.write(chunk, encoding, callback) }
    _final(callback) { this.socket.end(callback) }
    _destroy(error, callback) { this.socket.destroy(); callback(error) }
  }

  const server = tls.createServer({ key, cert }, socket => {
    socket.on('error', () => {})
    socket.on('data', () => socket.end())
  })
  server.on('tlsClientError', () => {})
  const port = await listen(server)
  const raw = net.connect(port, '127.0.0.1')
  raw.on('error', () => {})
  await bounded(once(raw, 'connect'))
  const duplex = new SocketProxy(raw)
  duplex.on('error', () => {})
  const client = tls.connect({ socket: duplex, rejectUnauthorized: false })
  client.on('error', () => {})
  let session
  let keylog
  client.once('session', value => {
    session = value
    client.destroy()
  })
  client.once('keylog', value => { keylog = value })
  client.once('secureConnect', () => client.write('x'))
  await bounded(once(client, 'close'))
  assert(Buffer.isBuffer(session))
  assert(session.length > 0)
  validateKeylog(keylog)
  duplex.destroy()
  raw.destroy()
  await closeServer(server)
  Bun.gc(true)
}

console.log('native TLS session and keylog lifecycle passed')
