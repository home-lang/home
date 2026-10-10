// Node supplies real descriptors; all adoption and I/O under test run in Home.
const assert = require('node:assert/strict')
const { fork } = require('node:child_process')
const net = require('node:net')
const dgram = require('node:dgram')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const [home, mode] = process.argv.slice(2)
assert.ok(['native-udp', 'dgram-fd', 'ipc-udp', 'tcp-zero', 'tcp-getter'].includes(mode))
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'home-fd-adoption-'))
const receiver = path.join(directory, 'receiver.cjs')
fs.writeFileSync(receiver, `
  const assert = require('node:assert/strict');
  const mode = ${JSON.stringify(mode)};
  let handle, port, phase = 0;
  process.on('uncaughtException', error => { console.error(error); process.exit(1); });
  async function adopt(expectedPort, received) {
    port = expectedPort;
    if (mode.startsWith('tcp-')) {
      let reads = 0;
      const options = { socket: {
        open(socket) { assert.equal(socket.fd, 0); if (mode === 'tcp-getter') assert.equal(reads, 1); process.send('adopted'); },
        data(socket, data) { assert.equal(data.toString(), 'ping'); socket.end('zero-fd'); },
        close() { process.disconnect(); },
        error(socket, error) { throw error; },
      }};
      if (mode === 'tcp-getter') Object.defineProperty(options, 'fd', { get() { reads++; return reads === 1 ? 0 : undefined; } });
      else options.fd = 0;
      await Bun.connect(options);
      return;
    }
    if (mode === 'native-udp') {
      handle = await Bun.udpSocket({ fd: 3, socket: { data(socket, data) { onData(data); } } });
    } else if (received) {
      handle = received;
      handle.on('message', onData);
    } else {
      handle = require('node:dgram').createSocket('udp4');
      await new Promise((resolve, reject) => { handle.once('error', reject); handle.bind({ fd: 3 }, resolve); });
      handle.on('message', onData);
    }
    const remote = mode === 'native-udp' ? handle.remoteAddress : handle.remoteAddress();
    assert.equal(remote.port, port);
    assert.equal(remote.address, '127.0.0.1');
    process.send('adopted');
  }
  function send(value) {
    if (mode === 'native-udp') assert.equal(handle.send(value), true);
    else handle.send(value, error => { if (error) throw error; });
  }
  function onData(data) {
    assert.equal(data.toString(), phase === 0 ? 'echo:connected' : mode === 'native-udp' ? 'echo:connected-again' : 'echo:reconnected');
    if (phase++ === 0) {
      if (mode === 'native-udp') {
        send('connected-again');
      } else {
        const native = handle._handle.socket;
        assert.equal(native.remoteAddress.port, port);
        handle.disconnect();
        assert.equal(native.remoteAddress, undefined);
        assert.throws(() => handle.remoteAddress(), { code: 'ERR_SOCKET_DGRAM_NOT_CONNECTED' });
        handle.connect(port, '127.0.0.1', () => send('reconnected'));
      }
    } else {
      if (mode === 'native-udp') {
        assert.ok(handle.port > 0);
        assert.ok(handle.address);
        assert.ok(handle.remoteAddress);
        handle.close();
        assert.equal(handle.port, undefined);
        assert.equal(handle.address, undefined);
        assert.equal(handle.remoteAddress, undefined);
      } else handle.close();
      process.disconnect();
    }
  }
  process.on('message', (message, received) => {
    if (message.port) adopt(message.port, received).catch(error => { console.error(error); process.exit(1); });
    if (message === 'send') send('connected');
  });
  process.send('ready');
`)
let child
let diagnostics = ''
let exchanged = false
let client
const resources = []
const deadline = setTimeout(() => {
  console.error('FD adoption timed out', mode, diagnostics)
  if (child) child.kill()
  if (client) client.destroy()
  for (const resource of resources) { try { resource.close() } catch {} }
  process.exitCode = 1
}, 10000)
function launch(stdio, source, port) {
  child = fork(receiver, [], {
    execPath: home, execArgv: [], stdio,
    env: { ...process.env, HOME_NATIVE_VM: '1', BUN_DEBUG_QUIET_LOGS: '1' },
  })
  child.stderr.on('data', value => { diagnostics += value })
  child.on('message', message => {
    if (message === 'ready') child.send({ port }, mode === 'ipc-udp' ? source : undefined)
    if (message === 'adopted') {
      if (mode.startsWith('tcp-')) { source.destroy(); client.write('ping') }
      else source.close(() => child.send('send'))
    }
  })
  child.on('exit', (code, signal) => {
    clearTimeout(deadline)
    for (const resource of resources) { try { resource.close() } catch {} }
    fs.rmSync(directory, { recursive: true, force: true })
    assert.equal(signal, null, diagnostics)
    assert.equal(code, 0, diagnostics)
    assert.ok(exchanged, diagnostics)
    console.log('Home preserves adopted descriptor state: ' + mode)
  })
}
if (mode.startsWith('tcp-')) {
  const server = net.createServer(socket => launch([socket._handle.fd, 'ignore', 'pipe', 'ipc'], socket, server.address().port))
  resources.push(server)
  server.listen(0, '127.0.0.1', () => {
    client = net.connect(server.address().port, '127.0.0.1')
    let data = ''
    client.setEncoding('utf8')
    client.on('data', value => { data += value })
    client.on('end', () => { assert.equal(data, 'zero-fd'); exchanged = true })
  })
} else {
  const echo = dgram.createSocket('udp4')
  const source = dgram.createSocket('udp4')
  resources.push(echo, source)
  echo.on('message', (data, peer) => {
    if (data.toString() === 'reconnected' || data.toString() === 'connected-again') exchanged = true
    echo.send('echo:' + data, peer.port, peer.address)
  })
  echo.bind(0, '127.0.0.1', () => source.bind(0, '127.0.0.1', () => {
    source.connect(echo.address().port, '127.0.0.1', () => {
      const stdio = mode === 'ipc-udp' ? ['ignore', 'ignore', 'pipe', 'ipc'] : ['ignore', 'ignore', 'pipe', Object.getOwnPropertySymbols(source).map(key => source[key]).find(state => state && state.handle && Number.isInteger(state.handle.fd)).handle.fd, 'ipc']
      launch(stdio, source, echo.address().port)
    })
  }))
}
