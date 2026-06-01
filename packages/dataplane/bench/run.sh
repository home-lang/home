#!/usr/bin/env bash
#
# Benchmark the Home dataplane (both engines) against nginx. Linux only.
# Needs: bun, nginx, oha, jq. Sweeps body size × concurrency, median of 3 runs,
# one dataplane copy per core (reusePort) — the same multi-core model as nginx's
# `worker_processes auto`. Reports req/s for the direct origin, nginx, and the
# dataplane's poll + io_uring engines, all forwarding to the same origin.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DP="${DP_BIN:-$HERE/../zig-out/bin/dataplane}"
CORES="$(nproc 2>/dev/null || echo 1)"
RUNS="${RUNS:-3}"
CONCS="${CONCS:-50 256}"
ORIGIN_PORT=8481; NGINX_PORT=8482; DP_POLL_PORT=8483; DP_URING_PORT=8484
TMP="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; PIDS=(); rm -rf "$TMP"; }
trap cleanup EXIT

[ -x "$DP" ] || { echo "dataplane binary not found at $DP (run: zig build -Doptimize=ReleaseFast)"; exit 1; }

# Origin: serves a body of $1 bytes, keepalive + content-length (Bun cluster).
cat > "$TMP/origin.ts" <<'EOF'
const size = Number(process.argv[3])
const body = 'x'.repeat(size)
Bun.serve({ port: Number(process.argv[2]), hostname: '127.0.0.1', reusePort: true, fetch() {
  return new Response(body, { headers: { 'content-type': 'text/html; charset=utf-8', 'content-length': String(size) } })
} })
EOF

write_nginx_conf() {
  mkdir -p "$TMP/ngx"
  cat > "$TMP/nginx.conf" <<EOF
worker_processes auto;
daemon off;
pid $TMP/nginx.pid;
error_log $TMP/ngx/error.log crit;
events { worker_connections 8192; }
http {
  access_log off;
  client_body_temp_path $TMP/ngx/body;
  proxy_temp_path $TMP/ngx/proxy;
  fastcgi_temp_path $TMP/ngx/fastcgi;
  uwsgi_temp_path $TMP/ngx/uwsgi;
  scgi_temp_path $TMP/ngx/scgi;
  upstream origin { server 127.0.0.1:$ORIGIN_PORT; keepalive 64; }
  server {
    listen $NGINX_PORT reuseport;
    location / { proxy_pass http://origin; proxy_http_version 1.1; proxy_set_header Connection ""; }
  }
}
EOF
}

wait_port() { for _ in $(seq 1 80); do (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && return 0; sleep 0.1; done; return 1; }

# median of $RUNS oha runs (req/s, integer). args: port conc nreq.
# Each run is hard-capped by `timeout` so a stuck/buggy engine yields 0, not a
# hung CI job. oha's own --timeout bounds individual requests too.
median_rps() {
  local port="$1" conc="$2" n="$3" vals=() r
  for _ in $(seq 1 "$RUNS"); do
    r="$(timeout 30 oha -n "$n" -c "$conc" -t 5s --no-tui -j "http://127.0.0.1:$port/" 2>/dev/null | jq -r '.summary.requestsPerSec | floor' 2>/dev/null)"
    vals+=("${r:-0}")
  done
  printf '%s\n' "${vals[@]}" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'
}

bench_size() {
  local size="$1" n="$2" label="$3"
  for _ in $(seq 1 "$CORES"); do bun "$TMP/origin.ts" "$ORIGIN_PORT" "$size" & PIDS+=($!); done
  write_nginx_conf
  nginx -p "$TMP" -c "$TMP/nginx.conf" & PIDS+=($!)
  for _ in $(seq 1 "$CORES"); do "$DP" "$DP_POLL_PORT" 127.0.0.1 "$ORIGIN_PORT" poll & PIDS+=($!); done
  for _ in $(seq 1 "$CORES"); do "$DP" "$DP_URING_PORT" 127.0.0.1 "$ORIGIN_PORT" uring & PIDS+=($!); done
  wait_port "$ORIGIN_PORT"; wait_port "$NGINX_PORT"; wait_port "$DP_POLL_PORT"; wait_port "$DP_URING_PORT"
  oha -n 2000 -c 50 --no-tui "http://127.0.0.1:$DP_POLL_PORT/" >/dev/null 2>&1 || true # warm

  for c in $CONCS; do
    echo ""
    echo "### $label, $c concurrent ($n reqs, median of $RUNS, ${CORES} core(s))"
    echo ""
    echo "| target          | req/s |"
    echo "|-----------------|------:|"
    printf "| direct          | %s |\n" "$(median_rps "$ORIGIN_PORT" "$c" "$n")"
    printf "| nginx           | %s |\n" "$(median_rps "$NGINX_PORT" "$c" "$n")"
    printf "| dataplane poll  | %s |\n" "$(median_rps "$DP_POLL_PORT" "$c" "$n")"
    printf "| dataplane uring | %s |\n" "$(median_rps "$DP_URING_PORT" "$c" "$n")"
  done
  cleanup
  trap cleanup EXIT
  sleep 1
}

echo "# Dataplane benchmark (poll + io_uring engines vs nginx)"
bench_size 16384   "${N16:-50000}"  "HTML ~16 KB"
bench_size 1048576 "${N1M:-5000}"   "asset ~1 MB"
