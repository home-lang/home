// Real-runtime HTTP/2 SERVER regression test.
//
// Exercises the actual `node:http2` server implementation (h2_frame_parser.zig)
// end-to-end against a real client over a real loopback socket — NOT the mocked
// `__home_http2_*` harness used by the native corpus runner (which cannot open
// real sockets). This is the regression guard for HTTP/2 server-side parity:
// the upstream `node-http2.test.js` cannot run under the native JSC corpus
// runner because it depends on Bun's subprocess-spawning test harness
// (`bunExe`/`nodeExe`), so this file is how the server path stays covered.
//
// Run via `scripts/runtime-regression.sh` (which probes for a JS-capable build
// first and skips gracefully on non-JSC targets). Exits 0 iff every assertion
// passes; exits 1 on the first failure or on a watchdog timeout.

const http2 = require("node:http2");

let failures = 0;
let pending = 0;
const log = (...a) => console.log(...a);
const ok = (cond, msg) => {
  if (!cond) {
    failures++;
    log("FAIL:", msg);
  } else {
    log("ok:  ", msg);
  }
};

// Watchdog: a hung scenario must fail the run, never wedge CI.
const watchdog = setTimeout(() => {
  log("FAIL: watchdog timeout — a scenario did not complete");
  process.exit(1);
}, 20000);

const track = () => {
  pending++;
};
const settle = () => {
  if (--pending === 0) {
    clearTimeout(watchdog);
    log(failures === 0 ? "ALL PASS" : "FAILURES=" + failures);
    process.exit(failures === 0 ? 0 : 1);
  }
};

// 1. Basic roundtrip: request headers, response status + custom headers, body.
track();
(() => {
  const server = http2.createServer();
  server.on("stream", (stream, headers) => {
    ok(headers[":method"] === "GET", "roundtrip: server saw :method GET");
    ok(headers[":path"] === "/hello", "roundtrip: server saw :path /hello");
    stream.respond({ ":status": 200, "content-type": "text/plain", "x-custom": "yo" });
    stream.end("world");
  });
  server.listen(0, () => {
    const client = http2.connect("http://localhost:" + server.address().port);
    client.on("error", (e) => ok(false, "roundtrip: client error " + (e && e.message)));
    const req = client.request({ ":path": "/hello", ":method": "GET" });
    let data = "";
    let resp = null;
    req.on("response", (h) => { resp = h; });
    req.on("data", (c) => { data += c; });
    req.on("end", () => {
      ok(resp && resp[":status"] == 200, "roundtrip: client got :status 200");
      ok(resp && resp["x-custom"] === "yo", "roundtrip: client got x-custom header");
      ok(data === "world", "roundtrip: client got body 'world'");
      client.close();
      server.close(settle);
    });
    req.end();
  });
})();

// 2. Trailers: server sends trailing headers after the body (END_STREAM on the
//    trailer HEADERS frame), client observes them via the "trailers" event.
track();
(() => {
  const server = http2.createServer();
  server.on("stream", (stream) => {
    stream.on("wantTrailers", () => stream.sendTrailers({ "x-trailer": "tail" }));
    stream.respond({ ":status": 200 }, { waitForTrailers: true });
    stream.end("body");
  });
  server.listen(0, () => {
    const client = http2.connect("http://localhost:" + server.address().port);
    const req = client.request({ ":path": "/" });
    let trailers = null;
    req.on("trailers", (h) => { trailers = h; });
    req.on("data", () => {});
    req.on("end", () => {
      ok(trailers && trailers["x-trailer"] === "tail", "trailers: client got x-trailer");
      client.close();
      server.close(settle);
    });
    req.end();
  });
})();

// 3. PING roundtrip: client PING is echoed by the server, callback fires with a
//    numeric duration.
track();
(() => {
  const server = http2.createServer();
  server.on("stream", (s) => { s.respond({ ":status": 200 }); s.end("x"); });
  server.listen(0, () => {
    const client = http2.connect("http://localhost:" + server.address().port);
    client.on("connect", () => {
      client.ping((err, duration) => {
        ok(!err, "ping: no error");
        ok(typeof duration === "number", "ping: duration is a number");
        const req = client.request({ ":path": "/" });
        req.on("data", () => {});
        req.on("end", () => { client.close(); server.close(settle); });
        req.end();
      });
    });
  });
})();

// 4. GOAWAY: closing the server drives a GOAWAY frame to the client.
track();
(() => {
  const server = http2.createServer();
  server.on("stream", (s) => { s.respond({ ":status": 200 }); s.end("x"); });
  server.listen(0, () => {
    const client = http2.connect("http://localhost:" + server.address().port);
    let goaway = false;
    client.on("goaway", () => { goaway = true; });
    client.on("connect", () => {
      const req = client.request({ ":path": "/" });
      req.on("data", () => {});
      req.on("end", () => {
        server.close();
        setTimeout(() => {
          ok(goaway, "goaway: client received GOAWAY on server.close");
          client.close();
          settle();
        }, 300);
      });
      req.end();
    });
  });
})();

// 5. RST_STREAM: client cancels an open stream, server observes the close.
track();
(() => {
  const server = http2.createServer();
  let serverClosed = false;
  server.on("stream", (s) => {
    s.on("close", () => { serverClosed = true; });
    s.respond({ ":status": 200 });
    // Intentionally left open so the client can reset it.
  });
  server.listen(0, () => {
    const client = http2.connect("http://localhost:" + server.address().port);
    const req = client.request({ ":path": "/" });
    req.on("response", () => req.close(http2.constants.NGHTTP2_CANCEL));
    req.on("close", () => {
      setTimeout(() => {
        ok(serverClosed, "rst_stream: server saw stream close after client cancel");
        client.close();
        server.close(settle);
      }, 200);
    });
    req.end();
  });
})();

// 6. CONTINUATION: a 20 KB header field must be split across CONTINUATION
//    frames on the wire and reassembled on both ends.
track();
(() => {
  const big = "a".repeat(20000);
  const server = http2.createServer();
  server.on("stream", (stream, headers) => {
    ok((headers["x-big"] || "").length === 20000, "continuation: server got 20k request header");
    stream.respond({ ":status": 200, "x-big-resp": big });
    stream.end("ok");
  });
  server.listen(0, () => {
    const client = http2.connect("http://localhost:" + server.address().port, { maxHeaderListSize: 200000 });
    const req = client.request({ ":path": "/", "x-big": big });
    let respBig = null;
    req.on("response", (h) => { respBig = h["x-big-resp"]; });
    req.on("data", () => {});
    req.on("end", () => {
      ok((respBig || "").length === 20000, "continuation: client got 20k response header");
      client.close();
      server.close(settle);
    });
    req.end();
  });
})();

// 7. Multiplexing: many concurrent streams on one connection stay independent.
track();
(() => {
  const N = 50;
  const server = http2.createServer();
  server.on("stream", (stream, headers) => {
    stream.respond({ ":status": 200 });
    stream.end("resp-" + headers["x-id"]);
  });
  server.listen(0, () => {
    const client = http2.connect("http://localhost:" + server.address().port);
    let completed = 0;
    let allMatch = true;
    for (let i = 0; i < N; i++) {
      const req = client.request({ ":path": "/", "x-id": String(i) });
      let data = "";
      req.on("data", (c) => { data += c; });
      req.on("end", () => {
        if (data !== "resp-" + i) allMatch = false;
        if (++completed === N) {
          ok(allMatch, "multiplex: all " + N + " concurrent streams matched");
          client.close();
          server.close(settle);
        }
      });
      req.end();
    }
  });
})();
