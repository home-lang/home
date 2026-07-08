#!/usr/bin/env bash
# Build the isolated lol-html C-API staticlib that HTMLRewriter links against.
#
# Why a separate staticlib (and not `libbun_rust.a`): the full bun Rust archive
# re-exports ~2200 runtime ABI symbols that Home now owns via ZigGeneratedClasses
# (ArchiveClass, ArrayBufferSink, ...), so linking it duplicate-symbol-explodes.
# `vendor/lolhtml/c-api` (crate `lol_html_c_api`) depends ONLY on the `lol_html`
# parser — no `bun_core` — so a `crate-type=staticlib` build yields the 96
# `lol_html_*` symbols plus a private Rust std and NOTHING of bun's ABI. Home
# links no other Rust staticlib, so the private std copy is not a conflict.
#
# Output: .native/liblolhtml.a (gitignored; ~6.6MB).
set -euo pipefail

BUN_ROOT="${HOME_BUN_ROOT:-$HOME/Code/bun}"
CAPI_DIR="$BUN_ROOT/vendor/lolhtml/c-api"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -d "$CAPI_DIR" ]; then
  echo "error: $CAPI_DIR not found (set HOME_BUN_ROOT to your bun checkout)" >&2
  exit 1
fi

export PATH="$HOME/.cargo/bin:/opt/homebrew/opt/llvm@21/bin:/opt/homebrew/bin:$PATH"
# bun's .cargo/config.toml forces `-fuse-ld=lld`, but lld isn't installed here
# and a staticlib/rlib only *archives* objects (the linker is used solely for
# build-script/proc-macro executables). RUSTFLAGS replaces the config rustflags
# entirely, so a single space drops the lld flag and the default linker is used.
export RUSTFLAGS=' '

echo "Building lol-html staticlib in $CAPI_DIR ..."
( cd "$CAPI_DIR" && cargo rustc --release --lib --crate-type staticlib )

SRC="$CAPI_DIR/target/release/liblolhtml.a"
DEST="$REPO_ROOT/.native/liblolhtml.a"
mkdir -p "$REPO_ROOT/.native"
cp "$SRC" "$DEST"

echo "Wrote $DEST"
echo "  lol_html_* symbols: $(nm "$DEST" 2>/dev/null | grep -c ' T _lol_html_')"
