// Node is the protocol peer; the sender executes in the native Home runtime.
const assert = require('node:assert/strict')
const { fork } = require('node:child_process')
const net = require('node:net')
const dgram = require('node:dgram')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

const home = process.argv[2]
const keepOpen = process.argv[3] === 'keep-open'
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'home-send-handles-'))
const script = path.join(directory, 'sender.cjs')
fs.writeFileSync(script, `
  const net = require('node:net'), dgram = require('node:dgram');
  const assert = require('node:assert/strict');
  const keepOpen = ${JSON.stringify(keepOpen)};
  let listener, udp;
  process.on('uncaughtException', error => { console.error(error); process.exit(1); });
  listener = net.createServer(socket => {
    // Exceeds the IPC socket's write buffer: SCM_RIGHTS must accompany only
    // the first positive write, while the whole envelope reaches the peer.
    process.send({ kind: 'tcp', payload: 'x'.repeat(2 * 1024 * 1024) }, socket, { keepOpen }, error => {
      if (error) throw error;
      if (keepOpen) {
        assert.equal(socket.readyState, 'open');
        socket.write('tcp-retained:', error => {
          if (error) throw error;
          socket.destroy();
          listener.close(() => process.send('tcp-ack'));
        });
      } else {
        listener.close(() => process.send('tcp-ack'));
      }
    });
  });
  listener.listen(0, '127.0.0.1', () => process.send({ tcpPort: listener.address().port }));
  process.on('message', kind => {
    if (kind === 'udp') {
      udp = dgram.createSocket('udp4');
      udp.bind(0, '127.0.0.1', () => process.send('udp', udp, error => {
        if (error) throw error;
        udp.close(() => process.send('udp-ack'));
      }));
    }
    if (kind === 'finish') process.disconnect();
  });
`)

let diagnostics = ''
let tcpDone = false
let tcpAck = false
let udpDone = false
let udpHandle
let client
let tcpHandle
const child = fork(script, [], {
  execPath: home,
  execArgv: [],
  env: { ...process.env, HOME_NATIVE_VM: '1', BUN_DEBUG_QUIET_LOGS: '1' },
  stdio: ['ignore', 'ignore', 'pipe', 'ipc'],
})
child.stderr.on('data', value => { diagnostics += value })
const deadline = setTimeout(() => {
  console.error('IPC handle send timed out', { tcpDone, tcpAck, udpDone }, diagnostics)
  child.kill()
  if (client) client.destroy()
  if (udpHandle) udpHandle.close()
  process.exitCode = 1
}, 10000)

child.on('message', (message, handle) => {
  const kind = message.kind || message
  if (message.tcpPort) {
    client = net.connect(message.tcpPort, '127.0.0.1')
    let data = ''
    client.setEncoding('utf8')
    client.on('data', value => { data += value })
    client.on('end', () => {
      assert.equal(data, keepOpen ? 'tcp-retained:tcp-from-node' : 'tcp-from-node')
      tcpDone = true
      if (tcpAck) child.send('udp')
    })
  }
  if (kind === 'tcp-ack') {
    tcpAck = true
    tcpHandle.end('tcp-from-node')
    if (tcpDone) child.send('udp')
  }
  if (kind === 'tcp') {
    assert.equal(message.payload.length, 2 * 1024 * 1024)
    assert.ok(handle instanceof net.Socket)
    tcpHandle = handle
  }
  if (kind === 'udp') {
    assert.ok(handle instanceof dgram.Socket)
    udpHandle = handle
    handle.once('message', (data) => {
      assert.equal(data.toString(), 'udp-from-node')
      udpDone = true
      handle.close()
      child.send('finish')
    })
  }
  if (kind === 'udp-ack') {
    const port = udpHandle.address().port
    const sender = dgram.createSocket('udp4')
    sender.send('udp-from-node', port, '127.0.0.1', error => {
      if (error) throw error
      sender.close()
    })
  }
})
child.on('exit', (code, signal) => {
  clearTimeout(deadline)
  fs.rmSync(directory, { recursive: true, force: true })
  assert.equal(signal, null, diagnostics)
  assert.equal(code, 0, diagnostics)
  assert.ok(tcpDone && tcpAck && udpDone, diagnostics)
  console.log('Home sent TCP and UDP descriptors to Node')
})
