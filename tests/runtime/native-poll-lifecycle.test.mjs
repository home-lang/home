import assert from 'node:assert/strict'
import { once } from 'node:events'
import { createServer, connect } from 'node:net'

// Exercise ordinary FIN handling with both directions independently open.
const server = createServer({ allowHalfOpen: true })
server.listen(0, '127.0.0.1')
await once(server, 'listening')
const accepted = once(server, 'connection')
const client = connect({ port: server.address().port, host: '127.0.0.1', allowHalfOpen: true })
const clientConnected = once(client, 'connect')
const [peer] = await accepted
let request = ''
let response = ''
peer.setEncoding('utf8')
client.setEncoding('utf8')
peer.on('data', chunk => { request += chunk })
client.on('data', chunk => { response += chunk })
const peerEnd = once(peer, 'end')
const clientEnd = once(client, 'end')
const clientClose = once(client, 'close')
const peerClose = once(peer, 'close')
await clientConnected
client.end('request')
await peerEnd
assert.equal(request, 'request')
assert.equal(peer.writable, true)
peer.end('response')
await clientEnd
await Promise.all([clientClose, peerClose])
assert.equal(response, 'response')
const closed = once(server, 'close')
server.close()
await closed
console.log('native poll FIN, independent half-open writes and loop close passed')
