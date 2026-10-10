// Exercise the actual NODE_HANDLE protocol without Node's automatic ACK.
const assert = require('node:assert/strict')
const { fork } = require('node:child_process')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const home = process.argv[2]
const disconnect = process.argv[3] === 'disconnect'
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'home-handle-failure-'))
const script = path.join(directory, 'sender.cjs')
fs.writeFileSync(script, `
  const assert = require('node:assert/strict'), dgram = require('node:dgram');
  const expected = ${JSON.stringify(disconnect ? 'ERR_IPC_CHANNEL_CLOSED' : 'ERR_IPC_HANDLE_TRANSFER_FAILED')};
  let calls = 0, queuedCallbacks = 0, udp;
  const deadline = setTimeout(() => { console.error('handle callback missing'); process.exit(1); }, 5000);
  process.on('message', () => {
    udp = dgram.createSocket('udp4');
    udp.bind(0, '127.0.0.1', () => {
      const originalPort = udp.address().port;
      process.send({ payload: 'x'.repeat(2 * 1024 * 1024) }, udp, error => {
        calls++;
        assert.equal(calls, 1);
        assert.equal(error.code, expected);
        assert.equal(udp.address().port, originalPort);
        // Failed transfer must leave the original socket usable.
        udp.send('still-owned', originalPort, '127.0.0.1', error => { if (error) throw error; });
      });
      process.send('queued', error => {
        queuedCallbacks++;
        assert.equal(error ? error.code : null, expected === 'ERR_IPC_CHANNEL_CLOSED' ? expected : null);
      });
      udp.once('message', data => {
        assert.equal(data.toString(), 'still-owned');
        assert.equal(calls, 1);
        assert.equal(queuedCallbacks, 1);
        udp.close(() => {
          clearTimeout(deadline);
          console.error('handle failure callback and source ownership passed');
          if (process.connected) process.disconnect();
        });
      });
    });
  });
  process.send('ready');
`)
const child = fork(script, [], {
  execPath: home, execArgv: [],
  env: { ...process.env, HOME_NATIVE_VM: '1', BUN_DEBUG_QUIET_LOGS: '1' },
  stdio: ['ignore', 'ignore', 'pipe', 'ipc'],
})
let attempts = 0
let queuedMessages = 0
let diagnostics = ''
child.stderr.on('data', value => { diagnostics += value })
// Node installs handle conversion on this event. Replace just that protocol
// receiver to deliberately reject each received fd, closing our copy each time.
child.removeAllListeners('internalMessage')
child.on('internalMessage', (message, handle) => {
  assert.equal(message.cmd, 'NODE_HANDLE')
  assert.equal(message.type, 'dgram.Socket')
  assert.equal(message.msg.payload.length, 2 * 1024 * 1024)
  assert.ok(handle)
  attempts++
  handle.close()
  if (disconnect) child.disconnect()
  else child.send({ cmd: 'NODE_HANDLE_NACK' })
})
child.on('message', message => {
  if (message === 'ready') child.send('start')
  else { assert.equal(message, 'queued'); queuedMessages++ }
})
const deadline = setTimeout(() => { child.kill(); process.exitCode = 1 }, 10000)
child.on('exit', (code, signal) => {
  clearTimeout(deadline)
  fs.rmSync(directory, { recursive: true, force: true })
  assert.equal(signal, null, diagnostics)
  assert.equal(code, 0, diagnostics)
  assert.equal(attempts, disconnect ? 1 : 3)
  assert.equal(queuedMessages, disconnect ? 0 : 1)
  assert.match(diagnostics, /handle failure callback and source ownership passed/)
  console.log('Home fails rejected IPC handles without losing socket ownership')
})
