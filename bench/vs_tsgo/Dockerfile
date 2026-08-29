# syntax=docker/dockerfile:1

# Build from the repository root:
#   docker build -f bench/vs_tsgo/Dockerfile -t home-ts-frontend-bench .
#
# The repository and a native Linux ReleaseFast home-tsc are mounted at run
# time. The entrypoint installs the exact TS 6/TS 7 versions from corpus.toml,
# regenerates the shared corpus, runs every admission control, then measures.
FROM node:24.18.0-bookworm-slim@sha256:6f7b03f7c2c8e2e784dcf9295400527b9b1270fd37b7e9a7285cf83b6951452d

ARG TARGETARCH
ARG HYPERFINE_VERSION=1.20.0

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl python3; \
    case "$TARGETARCH" in \
        amd64) hyperfine_sha256=e0391897ffb490af8a6b64e0e4281ac2c8e10cbcbb875bd22a376f44cdb263ab ;; \
        arm64) hyperfine_sha256=a469c7173d646b216405e29c18ba348b180ce214e4a580d63c6b81034fe2ca27 ;; \
        *) echo "unsupported container architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/sharkdp/hyperfine/releases/download/v${HYPERFINE_VERSION}/hyperfine_${HYPERFINE_VERSION}_${TARGETARCH}.deb" -o /tmp/hyperfine.deb; \
    echo "${hyperfine_sha256}  /tmp/hyperfine.deb" | sha256sum -c -; \
    dpkg -i /tmp/hyperfine.deb; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/hyperfine.deb

COPY bench/vs_tsgo/container-entrypoint.sh /usr/local/bin/home-ts-bench
RUN chmod 0755 /usr/local/bin/home-ts-bench

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/home-ts-bench"]
CMD ["cold", "--runs", "30", "--warmup", "3"]
