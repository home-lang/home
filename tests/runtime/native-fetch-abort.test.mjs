import assert from 'node:assert/strict'
import { basename } from 'node:path'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)

async function bounded(promise) {
  let timer
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('aborted response did not settle')), 3000)
      }),
    ])
  } finally {
    clearTimeout(timer)
  }
}

const controllers = new Set()
const server = Bun.serve({
  hostname: '127.0.0.1', port: 0,
  fetch(request) {
    if (new URL(request.url).pathname === '/healthy') return new Response('healthy')
    return new Response(new ReadableStream({
      pull(controller) {
        controller.enqueue(new TextEncoder().encode('{"answer":'))
        return new Promise(() => {})
      },
    }))
  },
})

try {
  for (let round = 0; round < 2; round++) {
    for (const custom of [false, true]) {
      for (const method of ['arrayBuffer', 'bytes', 'blob', 'text', 'json', 'reader']) {
        const controller = new AbortController()
        controllers.add(controller)
        const reason = custom ? new Error('native abort ' + method) : undefined
        let cancellations = 0
        let observedReason
        let recovery
        const response = await fetch(server.url, {
          method: 'POST', signal: controller.signal,
          body: new ReadableStream({
            pull(source) {
              source.enqueue(new Uint8Array(64))
              return new Promise(() => {})
            },
            cancel(error) {
              cancellations++
              observedReason = error
              // Exercise reentry while the native upload sink is cancelling.
              controller.abort(new Error('second abort must be ignored'))
              Bun.gc(true)
              recovery = fetch(new URL('/healthy', server.url)).then(value => value.text())
            },
          }),
        })
        assert.equal(response.status, 200)
        let pending
        if (method === 'reader') {
          const reader = response.body.getReader()
          assert.equal((await reader.read()).done, false)
          pending = reader.read()
        } else {
          pending = response[method]()
        }
        const settled = pending.then(() => assert.fail('aborted body resolved'), error => error)
        controller.abort(reason)
        assert.equal(await bounded(settled), controller.signal.reason)
        assert.equal(cancellations, 1)
        assert.equal(observedReason, controller.signal.reason)
        assert.equal(await bounded(recovery), 'healthy')
        controllers.delete(controller)
      }
    }
  }
  console.log('native fetch abort settles bodies and preserves cancellation ownership')
} finally {
  for (const controller of controllers) controller.abort()
  server.stop(true)
}
