import assert from 'node:assert/strict'
import { basename } from 'node:path'
import { tls } from '../../packages/runtime/test/test/harness.ts'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)

async function bounded(promise) {
  let timer
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('native TLS/duplex request did not settle')), 3000)
      }),
    ])
  } finally {
    clearTimeout(timer)
  }
}

async function rejects(promise, code) {
  const error = await bounded(promise.then(() => assert.fail('request unexpectedly succeeded'), error => error))
  assert(error instanceof Error)
  if (code) assert.equal(error.code, code)
}

for (const protocol of ['h1', 'http3']) {
  for (const verification of [{}, { requestCert: true, rejectUnauthorized: false }, { requestCert: true, rejectUnauthorized: true }]) {
    let handled = 0
    const server = Bun.serve({
      hostname: '127.0.0.1', port: 0,
      tls: { ...tls, ...verification },
      http1: protocol === 'h1', http3: protocol === 'http3',
      fetch(request) {
        handled++
        if (request.method === 'GET') return new Response('healthy')
        const reader = request.body.getReader()
        return new Response(new ReadableStream({
          async pull(controller) {
            const { value, done } = await reader.read()
            if (done) controller.close()
            else controller.enqueue(Buffer.from(value).toString().toUpperCase())
          },
        }))
      },
    })
    let releaseUpload
    try {
      const options = { protocol, tls: { rejectUnauthorized: false } }
      if (verification.rejectUnauthorized) {
        // No client certificate was supplied: the server must enforce its
        // verification settings, not accept the request after an ABI shift.
        await rejects(fetch(server.url, options))
        assert.equal(handled, 0)
        continue
      }
      assert.equal(await bounded(fetch(server.url, options).then(r => r.text())), 'healthy')
      await rejects(fetch(server.url, { protocol, tls: { rejectUnauthorized: true } }))
      if (protocol === 'http3') {
        for (const custom of [{ ca: tls.cert }, { cert: tls.cert, key: tls.key }, { serverName: 'localhost' }]) {
          await rejects(fetch(server.url, {
            protocol, tls: { ...custom, rejectUnauthorized: false },
          }), 'HTTP3Unsupported')
        }
        let identityChecks = 0
        await rejects(fetch(server.url, {
          protocol,
          tls: {
            rejectUnauthorized: true,
            checkServerIdentity() { identityChecks++ },
          },
        }), 'HTTP3Unsupported')
        assert.equal(identityChecks, 0)
      }

      const gate = new Promise(resolve => { releaseUpload = resolve })
      let part = 0
      const body = new ReadableStream({
        async pull(controller) {
          if (part++ === 0) controller.enqueue('first')
          else if (part === 2) {
            await gate
            controller.enqueue('second')
          } else controller.close()
        },
      })
      const response = await bounded(fetch(server.url, { ...options, method: 'POST', body }))
      const reader = response.body.getReader()
      const first = await bounded(reader.read())
      assert.equal(first.done, false)
      let received = Buffer.from(first.value).toString()
      assert.equal(received, 'FIRST')
      releaseUpload()
      while (true) {
        const { value, done } = await bounded(reader.read())
        if (done) break
        received += Buffer.from(value).toString()
      }
      assert.equal(received, 'FIRSTSECOND')
      assert.equal(await bounded(fetch(server.url, options).then(r => r.text())), 'healthy')
    } finally {
      releaseUpload?.()
      server.stop(true)
    }
  }
}
console.log('native TLS verification, HTTP/3 trust boundaries and duplex progress passed')
