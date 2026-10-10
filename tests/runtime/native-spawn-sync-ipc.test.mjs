import assert from 'node:assert/strict'
import { closeSync, fstatSync, mkdtempSync, openSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'
import { fileURLToPath } from 'node:url'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)

const directory = mkdtempSync(join(tmpdir(), 'home-native-sync-ipc-'))
try {
  writeFileSync(join(directory, 'package.json'), JSON.stringify({
    scripts: { ipc: 'printf "ipc-preserved\\n" >&3' },
  }))

  const child = Bun.spawn([process.execPath, 'run', '--silent', 'ipc'], {
    cwd: directory,
    env: {
      ...process.env,
      HOME_NATIVE_VM: '1',
      HOME_CORPUS_FULL_VM: '1',
      NODE_CHANNEL_FD: '3',
      NO_COLOR: '1',
    },
    stdio: ['ignore', 'pipe', 'pipe', 'pipe'],
  })
  const [stdout, stderr, ipc, code] = await Promise.all([
    child.stdout.text(),
    child.stderr.text(),
    Bun.file(child.stdio[3]).text(),
    child.exited,
  ])

  assert.deepEqual({ code, stdout, stderr, ipc }, {
    code: 0,
    stdout: '',
    stderr: '',
    ipc: 'ipc-preserved\n',
  })
  console.log('native synchronous spawn preserves IPC across exec')

  // Reject non-socket descriptors before taking ownership of the caller's fd.
  const ordinaryFile = join(directory, 'ordinary-file')
  writeFileSync(ordinaryFile, 'descriptor validation')
  const ordinaryFD = openSync(ordinaryFile, 'r')
  try {
    assert.throws(() => Bun.listen({ fd: ordinaryFD, socket: { data() {} } }), { code: 'ENOTSOCK' })
    assert.ok(fstatSync(ordinaryFD).isFile())
    await assert.rejects(async () => Bun.udpSocket({ fd: ordinaryFD, socket: { data() {} } }), { code: 'ENOTSOCK' })
    assert.ok(fstatSync(ordinaryFD).isFile())
  } finally {
    closeSync(ordinaryFD)
  }

  // Node supplies the protocol peer; the receiver and listener run in Home.
  // Closing Node's original listener must leave Home's transferred fd usable.
  const receiver = join(directory, 'receiver.cjs')
  writeFileSync(receiver, `
    const assert = require('node:assert/strict');
    const net = require('node:net');
    assert.match(process.execPath, /home(?:-debug)?$/);
    let listener;
    process.on('message', (message, handle) => {
      if (message === 'finish') {
        listener.close(() => process.disconnect());
        return;
      }
      assert.equal(message, 'listener');
      assert.ok(handle instanceof net.Server);
      listener = handle;
      listener.on('connection', socket => socket.end('from-home\\n'));
      process.send({ received: true, port: listener.address().port });
    });
    process.send({ ready: true });
  `)
  const peer = join(directory, 'peer.cjs')
  writeFileSync(peer, `
    const assert = require('node:assert/strict');
    const { fork } = require('node:child_process');
    const net = require('node:net');
    const listener = net.createServer();
    let child, diagnostics = '', transferred = false;
    const deadline = setTimeout(() => {
      if (child) child.kill();
      listener.close();
      console.error('IPC listener transfer timed out', diagnostics);
      process.exitCode = 1;
    }, 10000);
    listener.listen(0, '127.0.0.1', () => {
      const port = listener.address().port;
      child = fork(${JSON.stringify(receiver)}, [], {
        execPath: ${JSON.stringify(process.execPath)}, execArgv: [],
        env: { ...process.env, HOME_NATIVE_VM: '1', BUN_DEBUG_QUIET_LOGS: '1' },
        stdio: ['ignore', 'ignore', 'pipe', 'ipc'],
      });
      child.stderr.on('data', value => { diagnostics += value; });
      child.on('message', message => {
        if (message.ready) child.send('listener', listener);
        if (message.received) {
          assert.equal(message.port, port);
          listener.close(() => {
            const socket = net.connect(port, '127.0.0.1');
            let data = '';
            socket.setEncoding('utf8');
            socket.on('data', value => { data += value; });
            socket.on('end', () => {
              assert.equal(data, 'from-home\\n');
              transferred = true;
              child.send('finish');
            });
          });
        }
      });
      child.on('exit', (code, signal) => {
        clearTimeout(deadline);
        listener.close();
        assert.equal(signal, null, diagnostics);
        assert.equal(code, 0, diagnostics);
        assert.equal(transferred, true, diagnostics);
        console.log('native Home accepts and closes a Node-transferred IPC listener');
      });
    });
  `)
  const node = Bun.which('node')
  assert.ok(node, 'Node protocol peer must be available')
  const transfer = Bun.spawn([node, peer], { stdout: 'pipe', stderr: 'pipe' })
  const [transferOutput, transferErrors, transferCode] = await Promise.all([transfer.stdout.text(), transfer.stderr.text(), transfer.exited])
  assert.equal(transferCode, 0, transferErrors)
  assert.equal(transferOutput.trim(), 'native Home accepts and closes a Node-transferred IPC listener')
  console.log('native IPC listener transfer and descriptor ownership regressions passed')

  for (const [fixture, expected, option] of [
    ['ipc-receive-handles-peer.js', 'Home received TCP and UDP descriptors from Node'],
    ['ipc-send-handles-peer.js', 'Home sent TCP and UDP descriptors to Node'],
    ['ipc-send-handles-peer.js', 'Home sent TCP and UDP descriptors to Node', 'keep-open'],
    ['ipc-handle-failure-peer.js', 'Home fails rejected IPC handles without losing socket ownership'],
    ['ipc-handle-failure-peer.js', 'Home fails rejected IPC handles without losing socket ownership', 'disconnect'],
  ]) {
    const peerPath = fileURLToPath(new URL(`./fixtures/${fixture}`, import.meta.url))
    const peer = Bun.spawn([node, peerPath, process.execPath, ...(option ? [option] : [])], { stdout: 'pipe', stderr: 'pipe' })
    const [output, errors, code] = await Promise.all([peer.stdout.text(), peer.stderr.text(), peer.exited])
    assert.equal(code, 0, errors)
    assert.equal(output.trim(), expected)
    console.log(`native IPC ${fixture} (${option || 'default'}) with Node peer passed`)
    if (fixture !== 'ipc-handle-failure-peer.js') {
      const homePeer = Bun.spawn([process.execPath, 'run', peerPath, process.execPath, ...(option ? [option] : [])], {
        env: { ...process.env, HOME_NATIVE_VM: '1', BUN_DEBUG_QUIET_LOGS: '1' },
        stdout: 'pipe', stderr: 'pipe',
      })
      const [homeOutput, homeErrors, homeCode] = await Promise.all([homePeer.stdout.text(), homePeer.stderr.text(), homePeer.exited])
      assert.equal(homeCode, 0, homeErrors)
      assert.equal(homeOutput.trim(), expected)
      console.log(`native IPC ${fixture} (${option || 'default'}) with Home peer passed`)
    }
  }
  console.log('native bidirectional IPC TCP and UDP descriptor regressions passed')
} finally {
  rmSync(directory, { recursive: true, force: true })
}
