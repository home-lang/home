// Node supplies descriptors; the receiving sockets execute in native Home.
const assert = require('node:assert/strict')
const { fork } = require('node:child_process')
const net = require('node:net')
const dgram = require('node:dgram')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

const home = process.argv[2]
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'home-receive-handles-'))
const script = path.join(directory, 'receiver.cjs')
fs.writeFileSync(script, `
  const assert = require('node:assert/strict');
  process.on('uncaughtException', error => { console.error(error); process.exit(1); });
  process.on('message', (message, handle) => {
    const kind = message.kind || message;
    if (kind === 'tcp') {
      assert.equal(message.payload.length, 2 * 1024 * 1024);
      handle.end('tcp-from-home');
    }
    if (kind === 'udp') {
      handle.once('message', (data, peer) => {
        assert.equal(data.toString(), 'ping');
        handle.send('udp-from-home', peer.port, peer.address, error => {
          if (error) throw error;
          handle.close();
        });
      });
      process.send('udp-ready');
    }
    if (kind === 'finish') process.disconnect();
  });
  process.send('ready');
`)

let child
let diagnostics = ''
let tcpDone = false
let udpDone = false
const listener = net.createServer(socket => {
  child.send({ kind: 'tcp', payload: 'x'.repeat(2 * 1024 * 1024) }, socket, { keepOpen: false })
  listener.close()
})
const udp = dgram.createSocket('udp4')
const deadline = setTimeout(() => {
  console.error('IPC handle receive timed out', { tcpDone, udpDone }, diagnostics)
  if (child) child.kill()
  process.exitCode = 1
}, 10000)
listener.listen(0, '127.0.0.1', () => {
  const port = listener.address().port
  child = fork(script, [], {
    execPath: home,
    execArgv: [],
    env: { ...process.env, HOME_NATIVE_VM: '1', BUN_DEBUG_QUIET_LOGS: '1' },
    stdio: ['ignore', 'ignore', 'pipe', 'ipc'],
  })
  child.stderr.on('data', value => { diagnostics += value })
  child.on('message', message => {
    if (message === 'ready') {
      const client = net.connect(port, '127.0.0.1')
      let data = ''
      client.setEncoding('utf8')
      client.on('data', value => { data += value })
      client.on('end', () => {
        assert.equal(data, 'tcp-from-home')
        tcpDone = true
        udp.bind(0, '127.0.0.1', () => child.send('udp', udp))
      })
    }
    if (message === 'udp-ready') {
      const port = udp.address().port
      udp.close(() => {
        const client = dgram.createSocket('udp4')
        client.on('message', data => {
          assert.equal(data.toString(), 'udp-from-home')
          udpDone = true
          client.close()
          child.send('finish')
        })
        client.send('ping', port, '127.0.0.1')
      })
    }
  })
  child.on('exit', (code, signal) => {
    clearTimeout(deadline)
    listener.close()
    try { udp.close() } catch {}
    fs.rmSync(directory, { recursive: true, force: true })
    assert.equal(signal, null, diagnostics)
    assert.equal(code, 0, diagnostics)
    assert.ok(tcpDone && udpDone, diagnostics)
    console.log('Home received TCP and UDP descriptors from Node')
  })
})
