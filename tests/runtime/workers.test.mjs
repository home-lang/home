// Real-runtime Worker / MessageChannel / BroadcastChannel regression test.
//
// The worker Web primitives (MessageChannel port transfer, ArrayBuffer
// transfer, BroadcastChannel, and real cross-thread Worker roundtrip +
// terminate) are functionally complete in the full runtime, but the native
// JSC corpus runner cannot cover them: it runs under a restricted global that
// lacks `BroadcastChannel` and mishandles postMessage transfer lists, and it
// has no real threads. This file exercises the real behavior end-to-end via
// `home run`, guarding it against regression.
//
// Run via scripts/runtime-regression.sh (self-skips on non-JSC builds).
// Exits 0 iff every assertion passes; exits 1 on failure or watchdog timeout.

let failures = 0;
let pending = 0;
const ok = (cond, msg) => {
  if (!cond) {
    failures++;
    console.log("FAIL:", msg);
  } else {
    console.log("ok:  ", msg);
  }
};

const watchdog = setTimeout(() => {
  console.log("FAIL: watchdog timeout — a worker scenario did not complete");
  process.exit(1);
}, 20000);

const track = () => { pending++; };
const settle = () => {
  if (--pending === 0) {
    clearTimeout(watchdog);
    console.log(failures === 0 ? "ALL PASS" : "FAILURES=" + failures);
    process.exit(failures === 0 ? 0 : 1);
  }
};

// 1. MessageChannel: transfer a MessagePort through a port.
track();
(() => {
  const channel = new MessageChannel();
  const another = new MessageChannel();
  channel.port2.onmessage = (e) => {
    ok(e.data === "hello", "msgchannel: data === 'hello'");
    ok(e.ports && e.ports.length === 1, "msgchannel: e.ports has length 1");
    ok(e.ports && e.ports[0] instanceof MessagePort, "msgchannel: transferred value is a MessagePort");
    settle();
  };
  channel.port1.postMessage("hello", [another.port2]);
})();

// 2. MessageChannel: transfer an ArrayBuffer (ownership moves).
track();
(() => {
  const channel = new MessageChannel();
  const buf = new ArrayBuffer(8);
  channel.port2.onmessage = (e) => {
    ok(e.data instanceof ArrayBuffer, "msgchannel: transferred data is an ArrayBuffer");
    ok(e.data.byteLength === 8, "msgchannel: transferred ArrayBuffer byteLength 8");
    settle();
  };
  channel.port1.postMessage(buf, [buf]);
})();

// 3. BroadcastChannel: same-context roundtrip between two channels.
track();
(() => {
  const a = new BroadcastChannel("home-rt-ch");
  const b = new BroadcastChannel("home-rt-ch");
  b.onmessage = (e) => {
    ok(e.data === "ping", "broadcastchannel: receiver got 'ping'");
    a.close();
    b.close();
    settle();
  };
  a.postMessage("ping");
})();

// 4. Real cross-thread Worker: postMessage roundtrip, cross-thread transfer,
//    and terminate.
track();
(() => {
  const workerSrc = [
    'self.onmessage = (e) => {',
    '  if (e.data && e.data.cmd === "echo") {',
    '    self.postMessage({ reply: e.data.value * 2 });',
    '  } else if (e.data && e.data.cmd === "buf") {',
    '    const view = new Uint8Array(e.data.buf);',
    '    self.postMessage({ first: view[0], len: view.length });',
    '  }',
    '};',
  ].join("\n");
  const blob = new Blob([workerSrc], { type: "application/javascript" });
  const url = URL.createObjectURL(blob);
  const w = new Worker(url);
  let step = 0;
  w.onmessage = (e) => {
    if (step === 0) {
      ok(e.data.reply === 84, "worker: echo roundtrip 42*2 === 84");
      step = 1;
      const buf = new Uint8Array([7, 8, 9]).buffer;
      w.postMessage({ cmd: "buf", buf }, [buf]);
    } else {
      ok(e.data.first === 7 && e.data.len === 3, "worker: cross-thread transferred buffer first=7 len=3");
      w.terminate();
      settle();
    }
  };
  w.onerror = (e) => {
    ok(false, "worker: unexpected error " + (e && (e.message || e)));
    w.terminate();
    settle();
  };
  w.postMessage({ cmd: "echo", value: 42 });
})();
