import assert from 'node:assert/strict'
import { once } from 'node:events'
import { basename } from 'node:path'
import { createServer } from 'node:tls'
import { tls } from '../../packages/runtime/test/bun-corpus/harness.ts'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)

async function bounded(promise) {
  let timer
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('HTTP/2 operation did not settle')), 3000)
      }),
    ])
  } finally {
    clearTimeout(timer)
  }
}

function frame(type, flags, id, payload = Buffer.alloc(0)) {
  const header = Buffer.alloc(9)
  header.writeUIntBE(payload.length, 0, 3)
  header[3] = type
  header[4] = flags
  header.writeUInt32BE(id, 5)
  return Buffer.concat([header, payload])
}

function literal(name, value, indexed = false) {
  const bytes = Buffer.from(name, 'latin1')
  assert(bytes.length < 127 && value.length < 127)
  return Buffer.concat([Buffer.from([indexed ? 0x40 : 0x10, bytes.length]), bytes, Buffer.from([value.length]), Buffer.from(value)])
}

async function rawServer(onStream, run) {
  const sockets = new Set()
  const state = { connections: 0, resets: [] }
  const server = createServer({ ...tls, ALPNProtocols: ['h2'] }, socket => {
    const connection = ++state.connections
    sockets.add(socket)
    socket.on('close', () => sockets.delete(socket))
    socket.on('error', () => {})
    let buffered = Buffer.alloc(0)
    let preface = false
    socket.on('data', chunk => {
      buffered = Buffer.concat([buffered, chunk])
      if (!preface) {
        if (buffered.length < 24) return
        assert.equal(buffered.subarray(0, 24).toString(), 'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n')
        buffered = buffered.subarray(24)
        preface = true
        socket.write(frame(4, 0, 0))
      }
      while (buffered.length >= 9) {
        const length = buffered.readUIntBE(0, 3)
        if (buffered.length < length + 9) return
        const type = buffered[3]
        const flags = buffered[4]
        const id = buffered.readUInt32BE(5) & 0x7fffffff
        const payload = buffered.subarray(9, length + 9)
        buffered = buffered.subarray(length + 9)
        if (type === 4 && !(flags & 1)) socket.write(frame(4, 1, 0))
        if (type === 1) onStream(socket, id, connection)
        if (type === 3) state.resets.push(payload.readUInt32BE(0))
      }
    })
  })
  server.listen(0, '127.0.0.1')
  await bounded(once(server, 'listening'))
  try {
    await run(`https://localhost:${server.address().port}`, state)
  } finally {
    const closed = once(server, 'close')
    for (const socket of sockets) socket.destroy()
    server.close()
    await bounded(closed)
  }
}

const options = { protocol: 'http2', tls: { rejectUnauthorized: false } }
const respond = (socket, id, connection) => socket.write(frame(1, 5, id,
  Buffer.concat([Buffer.from([0x88]), literal('x-connection', String(connection))])))

// An idle session must retain the same verification-host identity as an active
// session. Port suffixes and DNS casing do not create a new identity.
await rawServer(respond, async (url, state) => {
  const connection = async host => {
    const response = await bounded(fetch(url, { ...options, headers: host ? { Host: host } : {} }))
    assert.equal(response.status, 200)
    await bounded(response.text())
    return response.headers.get('x-connection')
  }
  assert.equal(await connection('other.example'), '1')
  assert.equal(await connection(), '2')
  assert.equal(await connection('OTHER.EXAMPLE:443'), '1')
  assert.equal(await connection('localhost:443'), '2')
  assert.equal(await connection('third.example'), '3')
  assert.equal(await connection('other.example'), '1')
  assert.equal(state.connections, 3)
})

// Launch before handshakes complete, then again while responses are withheld.
// Equal hosts coalesce; a different host must use a distinct TLS connection.
let held = []
let notify
await rawServer((socket, id, connection) => {
  held.push([socket, id, connection])
  notify?.()
}, async (url, state) => {
  const request = host => bounded(fetch(url, { ...options, headers: { Host: host } }))
  const first = [request('a.example'), request('b.example'), request('A.EXAMPLE:443')]
  async function waitFor(count) {
    while (held.length < count) await bounded(new Promise(resolve => { notify = resolve }))
  }
  await waitFor(3)
  assert.equal(state.connections, 2)
  const second = [request('a.example'), request('b.example')]
  await waitFor(5)
  assert.equal(state.connections, 2)
  for (const args of held) respond(...args)
  held = []
  const responses = await Promise.all([...first, ...second])
  const ids = responses.map(response => response.headers.get('x-connection'))
  assert.equal(ids[0], ids[2])
  assert.equal(ids[0], ids[3])
  assert.equal(ids[1], ids[4])
  assert.notEqual(ids[0], ids[1])
  await bounded(Promise.all(responses.map(response => response.text())))
})

// Rejection must decode the entire HPACK block, including indexed fields after
// the invalid name. The following stream references that new table entry.
const invalid = ['x\0a', 'x\ra', 'x\na', 'x:a', 'x a', 'x\ta', 'X-a', 'x\x7f', 'x\x80', 'connection']
let requestNumber = 0
await rawServer((socket, id) => {
  const index = requestNumber++
  const fields = index % 2 === 0
    ? Buffer.concat([literal(invalid[index / 2], 'bad'), literal('x-after', String(index / 2), true)])
    : Buffer.from([0xbe]) // dynamic-table index 62: newest entry
  // Keep malformed streams open so rejection must send RST_STREAM; a stream
  // already closed by END_STREAM does not require a reset in either runtime.
  socket.write(frame(1, index % 2 === 0 ? 4 : 5, id, Buffer.concat([Buffer.from([0x88]), fields])))
}, async (url, state) => {
  for (let index = 0; index < invalid.length; index++) {
    const error = await bounded(fetch(url, options).then(() => assert.fail('malformed name reached Response'), error => error))
    assert.equal(error.code, 'HTTP2ProtocolError', JSON.stringify(invalid[index]))
    const response = await bounded(fetch(url, options))
    assert.equal(response.status, 200)
    assert.equal(response.headers.get('x-after'), String(index))
    await bounded(response.text())
  }
  assert.equal(state.connections, 1)
  assert.equal(state.resets.length, invalid.length)
  assert(state.resets.every(code => code === 1))
})

// lshpack rejects an empty literal name itself: this is a connection-level
// compression error, unlike valid HPACK carrying an invalid HTTP token above.
await rawServer((socket, id) => {
  socket.write(frame(1, 5, id, Buffer.concat([Buffer.from([0x88]), literal('', 'bad')])))
}, async url => {
  const error = await bounded(fetch(url, options).then(() => assert.fail('empty name reached Response'), error => error))
  assert.equal(error.code, 'HTTP2CompressionError')
})

console.log('native HTTP/2 verification-host isolation and HPACK rejection recovery passed')
