import assert from 'node:assert/strict'
import { createHash, randomBytes } from 'node:crypto'
import { once } from 'node:events'
import { closeSync, fstatSync, mkdtempSync, openSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { createSecureServer } from 'node:http2'
import { connect, createServer } from 'node:net'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'
import { brotliDecompressSync, gunzipSync, inflateSync, zstdDecompressSync } from 'node:zlib'
import { tls } from '../../packages/runtime/test/test/harness.ts'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const digest = bytes => createHash('sha256').update(bytes).digest('hex')
const decoders = { gzip: gunzipSync, deflate: inflateSync, br: brotliDecompressSync, zstd: zstdDecompressSync }

async function bounded(promise) {
  let timer
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('compressed request did not settle')), 5000)
      }),
    ])
  } finally {
    clearTimeout(timer)
  }
}

async function serve(protocol, run) {
  const seen = []
  const cancellation = {}
  async function handle(path, method, headers, read) {
    if (path === '/cancel') {
      const gate = new Promise(resolve => { cancellation.finish = resolve })
      cancellation.entered()
      await gate
      return { status: 200, body: 'cancelled' }
    }
    if (path === '/slow') await Bun.sleep(20)
    const raw = await read()
    const encoding = headers.get('content-encoding') ?? ''
    const decoded = decoders[encoding] ? decoders[encoding](raw) : raw
    const result = { encoding, length: headers.get('content-length'), rawLength: raw.length, sha: digest(decoded), method }
    seen.push(result)
    if (path.startsWith('/redirect')) return { status: Number(path.slice(9)), headers: { location: '/final' }, body: '' }
    return { status: 200, headers: { 'content-type': 'application/json' }, body: JSON.stringify(result) }
  }
  if (protocol === 'http2') {
    const sessions = new Set()
    const server = createSecureServer(tls)
    server.on('session', session => { sessions.add(session); session.on('close', () => sessions.delete(session)) })
    server.on('stream', (stream, headers) => {
      stream.on('error', () => {})
      void (async () => {
        const response = await handle(headers[':path'], headers[':method'], new Headers(Object.entries(headers).filter(([name]) => !name.startsWith(':'))), async () => {
          const chunks = []
          for await (const chunk of stream) chunks.push(chunk)
          return Buffer.concat(chunks)
        })
        if (stream.destroyed) return
        stream.respond({ ':status': response.status, ...response.headers })
        stream.end(response.body)
      })().catch(error => { stream.destroy(error) })
    })
    server.listen(0, '127.0.0.1')
    await bounded(once(server, 'listening'))
    try {
      await run(`https://localhost:${server.address().port}`, seen, cancellation)
    } finally {
      const closed = once(server, 'close')
      for (const session of sessions) session.destroy()
      server.close()
      await bounded(closed)
    }
  } else {
    const server = Bun.serve({
      hostname: '127.0.0.1', port: 0, tls,
      http1: protocol === 'h1', http3: protocol === 'http3',
      async fetch(request) {
        const response = await handle(new URL(request.url).pathname, request.method, request.headers, async () => Buffer.from(await request.arrayBuffer()))
        return new Response(response.body, response)
      },
    })
    try { await run(String(server.url).replace(/\/$/, ''), seen, cancellation) } finally { server.stop(true) }
  }
}

const small = Buffer.from('request compression, levels and replay '.repeat(20))
const shared = randomBytes(300 * 1024)
const spilled = randomBytes(700 * 1024)
const directory = mkdtempSync(join(tmpdir(), 'home-fetch-compress-'))
const filename = join(directory, 'body.bin')
writeFileSync(filename, spilled)
const descriptor = openSync(filename, 'r')
try {
  for (const protocol of ['h1', 'http2', 'http3']) {
    await serve(protocol, async (url, seen, cancellation) => {
      const options = { protocol, tls: { rejectUnauthorized: false } }
      const request = async (body, compress, extra = {}, path = '/slow') => {
        const response = await bounded(fetch(url + path, { ...options, method: 'POST', body, compress, ...extra }))
        assert.equal(response.status, 200)
        return bounded(response.json())
      }
      const check = (result, bytes, encoding) => {
        assert.equal(result.sha, digest(bytes))
        assert.equal(result.encoding, encoding)
        assert.equal(Number(result.length), result.rawLength)
      }
      for (const encoding of Object.keys(decoders)) {
        for (const bytes of [small, shared, spilled]) {
          check(await request(bytes, encoding), bytes, encoding)
        }
        const levels = encoding === 'zstd' ? [1, 22] : encoding === 'br' ? [0, 11] : [0, 12]
        for (const level of levels) check(await request(small, { encoding, level }), small, encoding)
        for (const status of [307, 308]) {
          const start = seen.length
          check(await request(shared, encoding, {}, '/redirect' + status), shared, encoding)
          assert.equal(seen.length, start + 2)
          check(seen[start], shared, encoding)
        }
      }
      // Different encodings concurrently reuse HTTP-thread scratch. Reads are
      // delayed, and each body must retain its own bytes and framing length.
      await Promise.all(Array.from({ length: 12 }, async (_, index) => {
        const encoding = Object.keys(decoders)[index % 4]
        const bytes = Buffer.concat([Buffer.from(String(index)), index & 1 ? shared : spilled])
        check(await request(bytes, encoding), bytes, encoding)
      }))
      check(await request(Bun.file(filename), true), spilled, 'gzip')
      const slice = spilled.subarray(17, 17 + 64 * 1024)
      const fileBody = () => Bun.file(descriptor).slice(17, 17 + slice.length)
      check(await request(fileBody(), true), slice, 'gzip')
      Bun.gc(true)
      await Bun.sleep(20)
      const countDescriptors = () => process.platform === 'win32' ? null : readdirSync(process.platform === 'linux' ? '/proc/self/fd' : '/dev/fd').length
      const before = countDescriptors()
      for (let round = 0; round < 16; round++) check(await request(fileBody(), true), slice, 'gzip')
      Bun.gc(true)
      await Bun.sleep(20)
      assert.equal(fstatSync(descriptor).size, spilled.length, 'fetch must not close the caller-owned descriptor')
      if (before !== null) assert(countDescriptors() <= before + 1, 'file-body reads leaked duplicated descriptors')
      check(await request(small, false), small, '')
      check(await request(small, null), small, '')
      check(await request('', 'gzip'), Buffer.alloc(0), '')
      check(await request(small, 'gzip', { headers: { 'Content-Encoding': 'identity' } }), small, 'identity')
      const streamed = await request(new ReadableStream({ start(controller) { controller.enqueue(small); controller.close() } }), 'gzip')
      assert.equal(streamed.encoding, '')
      assert.equal(streamed.sha, digest(small))
      for (let round = 0; round < 3; round++) {
        const started = new Promise(resolve => { cancellation.entered = resolve })
        const controller = new AbortController()
        const reason = new Error(`cancel compressed ${protocol} ${round}`)
        const pending = fetch(url + '/cancel', {
          ...options, method: 'POST', body: spilled, compress: 'gzip', signal: controller.signal,
        }).then(() => assert.fail('cancelled request succeeded'), error => error)
        try {
          // The server has received headers, so compression ran and the
          // request-owned buffer exists before cancellation and collection.
          await bounded(started)
          controller.abort(reason)
          assert.equal(await bounded(pending), reason)
          Bun.gc(true)
        } finally {
          cancellation.finish?.()
        }
        check(await request('recovered', true), Buffer.from('recovered'), 'gzip')
      }
      check(await request('recovered', true), Buffer.from('recovered'), 'gzip')
    })
  }
} finally {
  closeSync(descriptor)
  rmSync(directory, { recursive: true, force: true })
}

// Exercise the actual CONNECT handshake and TLS tunnel, including writes that
// must retain compressed bytes while the outer and inner sockets make progress.
const proxySockets = new Set()
const proxy = createServer(client => {
  proxySockets.add(client)
  client.on('close', () => proxySockets.delete(client))
  let header = Buffer.alloc(0)
  let upstream
  client.on('error', () => upstream?.destroy())
  client.on('close', () => upstream?.destroy())
  const receive = chunk => {
    header = Buffer.concat([header, chunk])
    const end = header.indexOf('\r\n\r\n')
    if (end < 0) return
    client.removeListener('data', receive)
    const [method, address] = header.toString('latin1').split(' ')
    assert.equal(method, 'CONNECT')
    const target = new URL('http://' + address)
    assert(['localhost', '127.0.0.1'].includes(target.hostname))
    upstream = connect(Number(target.port), '127.0.0.1', () => {
      client.write('HTTP/1.1 200 Connection')
      setTimeout(() => {
        if (client.destroyed || upstream.destroyed) return
        client.write(' Established\r\nProxy-Agent: splitproxy\r\n\r\n')
        if (header.length > end + 4) upstream.write(header.subarray(end + 4))
        client.pipe(upstream).pipe(client)
      }, 5)
    })
    proxySockets.add(upstream)
    upstream.on('error', () => client.destroy())
    upstream.on('close', () => { proxySockets.delete(upstream); client.destroy() })
  }
  client.on('data', receive)
})
proxy.listen(0, '127.0.0.1')
await bounded(once(proxy, 'listening'))
try {
  await serve('h1', async url => {
    await bounded(assert.rejects(fetch(url, {
      protocol: 'h1', proxy: `http://127.0.0.1:${proxy.address().port}`,
      tls: { rejectUnauthorized: true },
    })))
    for (const encoding of Object.keys(decoders)) {
      for (const body of [shared, spilled]) {
        const response = await bounded(fetch(url + '/slow', {
          method: 'POST', body, compress: encoding, protocol: 'h1',
          proxy: `http://127.0.0.1:${proxy.address().port}`, tls: { rejectUnauthorized: false },
        }))
        assert.equal(response.status, 200)
        assert.equal(response.headers.get('proxy-agent'), null)
        const result = await bounded(response.json())
        assert.equal(result.encoding, encoding)
        assert.equal(result.sha, digest(body))
        assert.equal(Number(result.length), result.rawLength)
      }
    }
  })
} finally {
  const closed = once(proxy, 'close')
  for (const socket of proxySockets) socket.destroy()
  proxy.close()
  await bounded(closed)
}

for (const compress of [42, NaN, Symbol('compress'), [], {}, 'GZIP', 'snappy', { encoding: 1 }, { encoding: 'snappy' }]) {
  assert.throws(() => fetch('http://127.0.0.1:1', { method: 'POST', body: 'x', compress }), /compress/)
}
for (const encoding of Object.keys(decoders)) {
  for (const level of [-1, 99, 2.5, Infinity, '6']) {
    assert.throws(() => fetch('http://127.0.0.1:1', { method: 'POST', body: 'x', compress: { encoding, level } }), /compress\.level/)
  }
}
const thrown = new Error('compress getter')
for (const compress of [
  { get encoding() { throw thrown } },
  { encoding: 'gzip', get level() { throw thrown } },
]) {
  assert.throws(() => fetch('http://127.0.0.1:1', { method: 'POST', body: 'x', compress }), error => error === thrown)
}
console.log('native fetch compression encodings, ownership, levels and redirects passed')
