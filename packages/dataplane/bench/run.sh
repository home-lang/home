#!/usr/bin/env bash
#
# Benchmark the Home dataplane against nginx on the HTML (body-bound) workload.
# Linux only (the dataplane's perf path uses splice()). Needs: bun, nginx, oha, jq.
#
# Spawns one dataplane copy per core (reusePort) — the same multi-core model as
# nginx's `worker_processes auto`. Reports req/s for the direct origin, nginx
# (reverse_proxy), and the dataplane, all forwarding to the same origin.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DP="${DP_BIN:-$HERE/../zig-out/bin/dataplane}"
N="${N:-100000}"
C="${C:-50}"
ORIGIN_PORT="${ORIGIN_PORT:-8481}"
NGINX_PORT="${NGINX_PORT:-8482}"
DP_PORT="${DP_PORT:-8483}"
CORES="$(nproc 2>/dev/null || echo 1)"
TMP="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$TMP"; }
trap cleanup EXIT

[ -x "$DP" ] || { echo "dataplane binary not found at $DP (run: zig build -Doptimize=ReleaseFast)"; exit 1; }

# 1. Origin: ~16 KB HTML, keepalive + content-length (a Bun cluster, never the bottleneck).
cat > "$TMP/origin.ts" <<'EOF'
const para = '<p>Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris.</p>'
const sections: string[] = []
for (let i = 0; i < 40; i++) sections.push(`<section id="s${i}"><h2>Section ${i}</h2>${para}${para}</section>`)
const html = `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>bench</title></head><body><main><h1>Benchmark</h1>${sections.join('')}</main></body></html>`
Bun.serve({ port: Number(process.argv[2]), hostname: '127.0.0.1', reusePort: true, fetch() {
  return new Response(html, { headers: { 'content-type': 'text/html; charset=utf-8', 'content-length': String(html.length) } })
} })
EOF
for _ in $(seq 1 "$CORES"); do bun "$TMP/origin.ts" "$ORIGIN_PORT" & PIDS+=($!); done

# 2. nginx reverse_proxy → origin (best-case: HTTP/1.1 keepalive upstream pool).
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
nginx -p "$TMP" -c "$TMP/nginx.conf" & PIDS+=($!)

# 3. Dataplane → origin: one copy per core, sharing the port via reusePort.
for _ in $(seq 1 "$CORES"); do "$DP" "$DP_PORT" 127.0.0.1 "$ORIGIN_PORT" & PIDS+=($!); done

# Wait for listeners.
for port in "$ORIGIN_PORT" "$NGINX_PORT" "$DP_PORT"; do
  for _ in $(seq 1 50); do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break || sleep 0.1; done
done

rps() { oha -n "$N" -c "$C" --no-tui -j "http://127.0.0.1:$1/" | jq -r '.summary.requestsPerSec | floor'; }
# warm up
oha -n 2000 -c "$C" --no-tui "http://127.0.0.1:$DP_PORT/" >/dev/null 2>&1 || true

echo "## Dataplane vs nginx — HTML (~16 KB), $N reqs, $C concurrent, ${CORES} core(s)"
echo ""
echo "| target    | req/s |"
echo "|-----------|------:|"
printf "| direct    | %s |\n" "$(rps "$ORIGIN_PORT")"
printf "| nginx     | %s |\n" "$(rps "$NGINX_PORT")"
printf "| **dataplane** | **%s** |\n" "$(rps "$DP_PORT")"
