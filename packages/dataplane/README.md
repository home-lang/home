# dataplane

A native reverse-proxy **hot path** — the byte-moving core of a reverse proxy,
meant to sit behind a high-level control plane (e.g. rpx's TypeScript daemon, or
a Home service) that owns config, TLS issuance, routing, DNS and `/etc/hosts`.

## Why it exists

A runtime/JS proxy (Bun, Node) is **body-bound**: every byte is copied through
userspace + GC, so even a bare `fetch` proxy is ~3× behind nginx serving a ~16 KB
HTML page. That's a platform ceiling, not a bug.

The thesis this package validates:

- For **reverse proxying**, nginx *also* copies bytes through userspace (its
  zero-copy `sendfile` is for static files). So a **no-GC, no-per-request-alloc**
  native proxy should already *match* nginx and crush a runtime proxy.
- On Linux, **`splice()`** moves bytes **kernel→kernel** (zero-copy), so it goes
  *past* nginx — we stop doing the copy nginx still does.

This is a natural fit for Home's no-GC systems model. The byte-move is abstracted
behind `Direction`, so Home's own `io_uring`/`splice` primitives can replace the
stock-Zig std calls used here.

## v0

A transparent **1:1 TCP proxy** (each client connection gets its own upstream
connection) on a single-threaded non-blocking `poll()` loop. Run one copy per
core with `SO_REUSEPORT` for multi-core (the bench does this; the kernel
load-balances on Linux). Byte movement:

- **copy path** (portable): `read()`/`write()` through a 64 KB buffer.
- **splice path** (Linux, `comptime`): `splice()` socket→pipe→socket, zero-copy.

No HTTP parsing yet — a TCP pump is the right *upper bound* for the single-upstream
benchmark (isolates the data path). Host routing + `X-Forwarded-*` rewrite are v1.

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/dataplane <listenPort> <upstreamHost> <upstreamPort>
```

Toolchain: the repo's pinned **Zig 0.17-dev** (`package.json` → `ziglang.org`).
The splice path needs any modern Linux kernel.

## Benchmark

`bench/run.sh` (Linux; needs `bun`, `nginx`, `oha`, `jq`) starts an origin, nginx
(`reverse_proxy`), and the dataplane — all forwarding to the same origin — and
reports req/s for a ~16 KB HTML page. CI runs it on every change via
[`.github/workflows/dataplane-bench.yml`](../../.github/workflows/dataplane-bench.yml)
(or trigger it manually from the Actions tab); results land in the job summary.

```bash
zig build -Doptimize=ReleaseFast && bash bench/run.sh
```

## Roadmap

1. **v0** — splice/copy TCP pump, `reusePort`, `poll()` loop. *(here)*
2. **io_uring** event loop (multishot accept, batched SQEs, registered buffers).
3. **kTLS** — terminate TLS in-kernel so encrypted bodies can *still* splice; the
   key to beating nginx on HTTPS body throughput.
4. HTTP/1.1 parse for host routing + `X-Forwarded-*`; HTTP/2; WebSocket.
5. Control-plane hand-off: consume certs/config from disk + reload on `SIGHUP`
   (the pattern rpx's cluster mode already uses).

## Status

Cross-compiles to Linux including the `splice` path; benchmarked vs nginx in CI.
The proxy logic (poll loop, EOF/half-close, splice state machine) is
correct-by-inspection and validated by the CI run.
