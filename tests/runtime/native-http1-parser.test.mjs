import assert from 'node:assert/strict'
import { once } from 'node:events'
import { basename } from 'node:path'
import http from 'node:http'
import net from 'node:net'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)

async function bounded(promise) {
  let timer
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('HTTP/1 parser operation did not settle')), 3000)
      }),
    ])
  } finally {
    clearTimeout(timer)
  }
}

async function rawRequest(port, fragments) {
  return bounded(new Promise((resolve, reject) => {
    const socket = net.connect(port, '127.0.0.1')
    let response = ''
    socket.setEncoding('latin1')
    socket.on('data', chunk => { response += chunk })
    socket.on('error', reject)
    socket.on('close', () => resolve(response))
    socket.on('connect', async () => {
      try {
        for (const fragment of fragments) {
          socket.write(fragment)
          await new Promise(resolve => setImmediate(resolve))
        }
      } catch (error) {
        reject(error)
      }
    })
  }))
}

const seen = []
const server = http.createServer((request, response) => {
  seen.push(request.url)
  response.end(request.url)
})
server.listen(0, '127.0.0.1')
await bounded(once(server, 'listening'))

try {
  // node:http enables strict method validation. A lowercase byte cannot be a
  // fragmented valid method and must terminate the connection immediately.
  assert.equal(
    await rawRequest(server.address().port, ['h']),
    'HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n',
  )
  assert.deepEqual(seen, [])

  // An uppercase fragment can still become a valid request and must remain
  // buffered until its request line is complete.
  const fragmented = await rawRequest(server.address().port, [
    'G',
    'ET /fragmented HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n',
  ])
  assert.match(fragmented, /^HTTP\/1\.1 200 OK\r\n/)
  assert(fragmented.endsWith('/fragmented'))
  assert.deepEqual(seen, ['/fragmented'])

  // Taking ownership of the parser must preserve synchronous same-buffer
  // keep-alive pipelining and isolate each request's URL and response.
  const pipelined = await rawRequest(server.address().port, [
    'GET /one HTTP/1.1\r\nHost: localhost\r\n\r\n'
      + 'GET /two HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n',
  ])
  assert.equal(pipelined.match(/HTTP\/1\.1 200 OK/g)?.length, 2)
  assert(pipelined.includes('\r\n\r\n/oneHTTP/1.1 200 OK\r\n'))
  assert(pipelined.endsWith('/two'))
  assert.deepEqual(seen, ['/fragmented', '/one', '/two'])
} finally {
  const closed = once(server, 'close')
  server.close()
  await bounded(closed)
}

console.log('native HTTP/1 strict-method rejection, fragmentation and pipelining passed')
