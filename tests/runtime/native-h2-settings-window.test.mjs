import assert from 'node:assert/strict'
import { once } from 'node:events'
import { basename } from 'node:path'
import { connect, createServer } from 'node:http2'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const payload = Buffer.alloc(256 * 1024, 97)
const server = createServer({ settings: { initialWindowSize: 16384, customSettings: { 1244: 456 } }, remoteCustomSettings: [55] })
server.on('stream', stream => {
  stream.respond({ ':status': 200 })
  stream.end(payload)
})
server.listen(0)
await once(server, 'listening')
const client = connect(`http://localhost:${server.address().port}`, {
  settings: { initialWindowSize: 4096, customSettings: { 55: 12, 155: 144 } },
  remoteCustomSettings: [1244],
})
try {
  await once(client, 'remoteSettings')
  assert.deepEqual(client.remoteSettings.customSettings, { 1244: 456 })
  const received = []
  client.on('localSettings', settings => received.push(settings.initialWindowSize))
  const update = settings => new Promise((resolve, reject) => client.settings(settings, error => error ? reject(error) : resolve()))
  await Promise.all([update({ initialWindowSize: 8192 }), update({ initialWindowSize: 32768 })])
  assert.deepEqual(received.slice(-2), [8192, 32768])
  assert.equal(client.localSettings.initialWindowSize, 32768)

  const before = client.localSettings.initialWindowSize
  client.setLocalWindowSize(128 * 1024)
  assert.equal(client.localSettings.initialWindowSize, before)
  assert.equal(client.state.effectiveLocalWindowSize, 128 * 1024)

  for (let index = 0; index < 4; index++) {
    const stream = client.request({ ':path': '/' })
    const chunks = []
    stream.on('data', chunk => chunks.push(chunk))
    await once(stream, 'end')
    assert.deepEqual(Buffer.concat(chunks), payload)
  }
  console.log('native ordered settings, custom settings and reusable window credit passed')
} finally {
  const closed = once(server, 'close')
  client.close()
  server.close()
  await closed
}
