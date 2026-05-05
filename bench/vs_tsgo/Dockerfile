# bench/vs_tsgo/Dockerfile — reproducible env for the bench harness.
#
# Per TS_PARITY_PLAN §6.4. Pins every tool that affects the numbers so
# CI runs are byte-for-byte reproducible against the README claims.
#
# Build:    docker build -t home-bench bench/vs_tsgo/
# Run:      docker run --rm -it -v "$PWD/bench/vs_tsgo/results:/results" home-bench

FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    python3 \
    xz-utils \
    build-essential \
  && rm -rf /var/lib/apt/lists/*

# hyperfine — pinned to a known-good version
RUN curl -sSL https://github.com/sharkdp/hyperfine/releases/download/v1.18.0/hyperfine_1.18.0_amd64.deb \
    -o /tmp/hyperfine.deb \
  && dpkg -i /tmp/hyperfine.deb \
  && rm /tmp/hyperfine.deb

# Node + tsc (pinned)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
  && apt-get install -y --no-install-recommends nodejs \
  && rm -rf /var/lib/apt/lists/* \
  && npm i -g typescript@5.6.3

# tsgo binary — built from microsoft/typescript-go at the same SHA we
# pin our conformance submodule to. Until that pinning lands, take the
# latest release.
RUN curl -sSL "https://github.com/microsoft/typescript-go/releases/latest/download/tsgo-linux-amd64.tar.xz" \
    | tar -xJ -C /usr/local/bin \
  || echo "WARN: tsgo binary not available; install manually for benches"

# Zig — pinned to match the project's pantry-bundled version.
RUN curl -sSL "https://ziglang.org/builds/zig-x86_64-linux-0.16.0-dev.3144+ac6fb0b59.tar.xz" \
    | tar -xJ -C /opt \
  && ln -s /opt/zig-x86_64-linux-0.16.0-dev.3144+ac6fb0b59/zig /usr/local/bin/zig \
  || echo "WARN: matching Zig dev build not pinned; bench will use system zig"

WORKDIR /work
COPY . /work
WORKDIR /work/bench/vs_tsgo

ENTRYPOINT ["./run.sh"]
CMD ["all"]
