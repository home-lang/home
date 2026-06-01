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

All byte movement is zero-copy `splice()` (socket→pipe→socket); the engine is a
**swappable io backend**, selected by an optional 4th arg:

- **`poll`** (default) — readiness-driven non-blocking `poll()` loop. Validated.
- **`uring`** — completion-driven `io_uring`: multishot accept + `IORING_OP_SPLICE`,
  batched submits. Each connection-half alternates one read-splice (src→pipe) and
  write-splices (pipe→dst), driven by completions; slots are generation-tagged and
  reference-counted for safe teardown.

A future **Home-native io module** is just a third backend behind the same seam.
No HTTP parsing yet — a TCP pump is the right *upper bound* for the single-upstream
benchmark (isolates the data path). Host routing + `X-Forwarded-*` rewrite are next.

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/dataplane <listenPort> <upstreamHost> <upstreamPort> [poll|uring]
```

Toolchain: the repo's pinned **Zig 0.17-dev** (`package.json` → `ziglang.org`),
talking the raw Linux syscall ABI (`std.os.linux`) directly. Needs a modern
Linux kernel (`splice` + `io_uring`).

## Benchmark

`bench/run.sh` (Linux; needs `bun`, `nginx`, `oha`, `jq`) starts an origin, nginx
(`reverse_proxy`), and both dataplane engines — all forwarding to the same origin
— and reports median req/s across a **body-size sweep** (~16 KB HTML, ~1 MB asset)
× **concurrency sweep** (50, 256). CI runs it on every change via
[`.github/workflows/dataplane-bench.yml`](../../.github/workflows/dataplane-bench.yml)
(or trigger it manually from the Actions tab); results land in the job summary.

```bash
zig build -Doptimize=ReleaseFast && bash bench/run.sh
```

## Roadmap

1. **v0** — splice TCP pump, `reusePort`, swappable backend. ✅
2. **io_uring** engine — single-shot accept + `IORING_OP_SPLICE`. ✅ works
   end-to-end (opt-in `uring` arg), but currently *slower* than `poll`: client fds
   are blocking, so every waiting read-splice parks in an io-wq worker thread —
   overhead that dominates on small, high-rate requests. **Next:** poll-then-splice
   (arm `IORING_OP_POLL_ADD`, splice only when readable, keep fds non-blocking) to
   drop io-wq and let it match/beat `poll`.
3. **kTLS** — terminate TLS in-kernel so encrypted bodies can *still* splice; the
   key to beating nginx on HTTPS body throughput.
4. HTTP/1.1 parse for host routing + `X-Forwarded-*`; HTTP/2; WebSocket.
5. Control-plane hand-off: consume certs/config from disk + reload on `SIGHUP`
   (the pattern rpx's cluster mode already uses).
6. A **Home-native io backend** behind the engine seam.

## Status — `poll` beats nginx on bodies, and the win grows with body size

Full Linux sweep (median of 3, 4-core runner, all proxies `reusePort` N-up like
nginx `worker_processes auto`):

| body  | conc | direct | nginx  | **poll** | uring  | poll ÷ nginx |
|-------|-----:|-------:|-------:|---------:|-------:|-------------:|
| 16 KB |   50 | 55,818 | 30,674 | **35,995** | 19,769 | **1.17×** |
| 16 KB |  256 | 62,804 | 33,421 | **39,776** | 21,223 | **1.19×** |
| 1 MB  |   50 |  6,999 |  1,484 |  **3,537** |  2,906 | **2.38×** |
| 1 MB  |  256 |  6,475 |  1,447 |  **3,151** |  2,874 | **2.18×** |

The thesis, confirmed: nginx copies proxied bodies through userspace; the dataplane
`splice()`s kernel→kernel and doesn't — so **the bigger the body, the bigger the
edge** (~1.18× at 16 KB → ~2.3× at 1 MB). This is the exact body-bound metric where
a Bun/JS proxy runs ~3× *behind* nginx.

`uring` works correctly and beats nginx ~2× on 1 MB, but trails `poll` (see roadmap
#2 — io-wq overhead from blocking fds). `poll` is the validated default. Next:
poll-then-splice to make `uring` competitive, then kTLS for HTTPS bodies.
