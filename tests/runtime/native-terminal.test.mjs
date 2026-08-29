import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { readdirSync } from 'node:fs'
import { basename } from 'node:path'

assert.match(basename(process.execPath), /^home(?:-debug)?(?:\.exe)?$/)
const env = { ...process.env, HOME_NATIVE_VM: '1', HOME_CORPUS_FULL_VM: '1', NO_COLOR: '1' }
function child(name, source, fdLimit = false) {
  const args = ['-e', `
    import assert from 'node:assert/strict';
    ${source}
    console.log(${JSON.stringify(name)});
  `]
  const command = fdLimit ? '/bin/sh' : process.execPath
  const argv = fdLimit ? ['-c', 'ulimit -n 64; exec "$@"', 'home-terminal-fd-limit', process.execPath, ...args] : args
  const result = spawnSync(command, argv, { env, encoding: 'utf8', timeout: 15000 })
  assert.equal(result.error, undefined, `${name}: ${result.stderr}`)
  assert.equal(result.signal, null, `${name}: ${result.stderr}`)
  assert.equal(result.status, 0, `${name}: ${result.stderr}`)
  assert.equal(result.stdout.trim(), name)
  return result
}

// An unreferenced PTY must allow natural exit; the reference controls below
// must instead keep their child alive until an unreferenced timer closes it.
child('terminal-unref-exit', `
  const terminal = new Bun.Terminal({});
  terminal.unref(); terminal.unref();
`)
for (const reref of [false, true]) {
  const result = child(`terminal-ref-${reref}`, `
    const terminal = new Bun.Terminal({});
    ${reref ? 'terminal.unref(); terminal.ref(); terminal.ref();' : ''}
    setTimeout(() => { terminal.close(); process.stderr.write('closed'); }, 40).unref();
  `)
  assert.equal(result.stderr, 'closed', 'referenced PTY must keep the unreferenced close timer alive')
}

if (process.platform !== 'win32') {
  // Darwin sets PENDIN when restoring canonical mode; it is kernel state.
  const flags = terminal => terminal.localFlags & ~(process.platform === 'darwin' ? 0x20000000 : 0)
  const first = new Bun.Terminal({})
  const second = new Bun.Terminal({})
  try {
    const firstFlags = flags(first)
    second.localFlags &= ~8 // ECHO has the same value on Darwin and Linux.
    const secondFlags = flags(second)
    assert.notEqual(firstFlags, secondFlags)
    first.setRawMode(true)
    second.setRawMode(true)
    const secondRaw = flags(second)
    assert.notEqual(secondRaw, secondFlags, 'second PTY must independently enter raw mode')
    first.setRawMode(false)
    assert.equal(flags(first), firstFlags)
    assert.equal(flags(second), secondRaw, 'restoring first PTY must leave second raw')
    second.setRawMode(false)
    assert.equal(flags(second), secondFlags)
  }
  finally {
    first.close()
    second.close()
  }

  // Raw input exceeds the PTY queue. Verify every byte arrives, that the
  // queued remainder is owned after the caller mutates its buffer, and that
  // drain fires only after backpressure clears, with the correct receiver.
  child('terminal-backpressure', `
    const size = 1024 * 1024 + 17;
    let output = '', drains = 0;
    const ready = Promise.withResolvers(), complete = Promise.withResolvers();
    const proc = Bun.spawn([process.execPath, '-e', \`
      process.stdin.setRawMode(true);
      let count = 0;
      process.stdin.on('data', bytes => {
        for (const byte of bytes) if (byte !== 65) throw Error('input changed');
        count += bytes.length;
        if (count === \${size}) { process.stdout.write('TOTAL:' + count); process.exit(0); }
        if (count > \${size}) throw Error('excess input');
      });
      process.stdout.write('READY');
    \`], { env: process.env, terminal: {
      data(term, bytes) {
        assert.equal(term, proc.terminal);
        assert.ok(bytes instanceof Uint8Array);
        output += Buffer.from(bytes).toString();
        if (output.includes('READY')) ready.resolve();
        if (output.includes('TOTAL:' + size)) complete.resolve();
      },
      drain(term) { assert.equal(this, term); assert.equal(term, proc.terminal); drains++; }
    }});
    try {
      await ready.promise;
      const input = Buffer.alloc(size, 65);
      const written = proc.terminal.write(input);
      assert.ok(written < size, 'fixture must exercise backpressure');
      input.fill(66);
      await complete.promise;
      assert.equal(await proc.exited, 0);
      assert.ok(drains > 0, 'buffered data must report a drain');
    } finally { proc.kill(); proc.terminal.close(); }
  `)

  // Opening /dev/tty and querying its dimensions checks real
  // controlling-terminal/session setup, not just fd-based isatty detection.
  child('terminal-controlling-session', `
    let output = '';
    const eof = Promise.withResolvers();
    const proc = Bun.spawn(['/bin/sh', '-c', 'test -t 0 && test -t 1 && test -t 2 && stty size < /dev/tty'], {
      terminal: { cols: 117, rows: 39, data(t, data) { output += Buffer.from(data); }, exit() { eof.resolve(); } }
    });
    try { assert.equal(await proc.exited, 0); await eof.promise; assert.equal(output.trim(), '39 117'); }
    finally { proc.terminal.close(); }
  `)

  // Leave 0..3 slots for a constructor needing four descriptors. This
  // exercises both openpty failure and each master-dup failure under EMFILE.
  child('terminal-fd-exhaustion', `
    import { openSync, closeSync } from 'node:fs';
    const fds = [];
    function fill() {
      let added = 0;
      while (true) {
        try { fds.push(openSync('/dev/null', 'r')); added++; }
        catch (error) { assert.equal(error.code, 'EMFILE'); return added; }
      }
    }
    try {
      fill();
      for (let slots = 0; slots < 4; slots++) {
        for (let i = 0; i < slots; i++) closeSync(fds.pop());
        assert.throws(() => new Bun.Terminal({ name: 'failure-owned-name' }), /Failed to (open PTY|duplicate PTY file descriptor)/);
        assert.equal(fill(), slots, 'failed constructor must return every descriptor');
      }
    } finally { for (const fd of fds) closeSync(fd); }
    const terminal = new Bun.Terminal({});
    assert.equal(terminal.write('recovered'), 9);
    terminal.close();
  `, true)

  const countFDs = () => readdirSync(process.platform === 'linux' ? '/proc/self/fd' : '/dev/fd').length
  const before = countFDs()
  let disposedCallbacks = 0
  for (let round = 0; round < 48; round++) {
    const terminal = new Bun.Terminal({
      data() { disposedCallbacks++ },
      drain() { disposedCallbacks++ },
      exit() { disposedCallbacks++ },
    })
    terminal.write('discarded\n')
    const disposed = terminal[Symbol.asyncDispose]()
    assert.ok(disposed instanceof Promise)
    await disposed
    terminal.close()
    assert.equal(terminal.closed, true)
    assert.throws(() => terminal.write('closed'), /Terminal is closed/)
    const stdin = round % 2 ? new Blob([new Uint8Array(65536)]) : new Uint8Array(65536)
    assert.throws(() => Bun.spawn(['/missing-home-terminal-child'], { stdin, terminal: { name: 'owned-name' } }), e => e.code === 'ENOENT')
  }
  await Bun.sleep(20)
  Bun.gc(true)
  assert.equal(disposedCallbacks, 0, 'disposed terminals must suppress all callbacks')
  assert.equal(countFDs(), before, 'disposed and failed inline terminals must close all descriptors')

  // Closed/disposed wrappers must lose native strong roots, while a retained
  // live terminal remains reachable. Yield between GC and WeakRef checks.
  const live = new Bun.Terminal({})
  const liveRef = new WeakRef(live)
  async function retired() {
    const refs = []
    for (let i = 0; i < 32; i++) {
      const terminal = new Bun.Terminal({})
      refs.push(new WeakRef(terminal))
      if (i % 2) await terminal[Symbol.asyncDispose]()
      else terminal.close()
    }
    return refs
  }
  try {
    const refs = await retired()
    let remaining = refs.length
    for (let attempt = 0; attempt < 12; attempt++) {
      await Bun.sleep(1)
      Bun.gc(true)
      await Bun.sleep(1)
      remaining = refs.reduce((count, ref) => count + Number(Boolean(ref.deref())), 0)
      assert.equal(liveRef.deref(), live)
      if (!remaining) break
    }
    assert.equal(remaining, 0, 'retired terminal wrappers must be collectible')
  }
  finally { live.close() }

  // Close + GC re-enters the native reader from its own data callback.
  for (let round = 0; round < 24; round++) {
    const done = Promise.withResolvers()
    let exits = 0
    const terminal = new Bun.Terminal({
      data(term) { term.close(); Bun.gc(true); done.resolve() },
      exit(term) { exits++; term.close(); Bun.gc(true) },
    })
    terminal.write('close-during-read\n')
    await done.promise
    assert.equal(exits, 1)
    terminal.close()
    assert.equal(exits, 1)
  }
  assert.equal(countFDs(), before)
}
console.log('native terminal lifecycle passed')
