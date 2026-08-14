#!/usr/bin/env bash
#
# Render the social card at .config/og/card.html into docs/public/og.png.
#
# The card is HTML rather than a binary so it stays diffable and so the
# headline can be kept in step with the site. It is rendered at 2x and
# downscaled, which supersamples the type instead of shipping it soft.
#
# Requires Google Chrome (headless) and sips, both of which are on macOS by
# default once Chrome is installed.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
card="$root/.config/og/card.html"
out="$root/docs/public/og.png"

chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [[ ! -x "$chrome" ]]; then
  echo "error: Google Chrome not found at $chrome" >&2
  echo "       The card is rendered with headless Chrome; install it or render" >&2
  echo "       $card by hand at 1200x630." >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A throwaway profile keeps this away from the real browser profile.
"$chrome" \
  --headless=new \
  --disable-gpu \
  --hide-scrollbars \
  --no-first-run \
  --user-data-dir="$work/profile" \
  --force-device-scale-factor=2 \
  --window-size=1200,630 \
  --screenshot="$work/og@2x.png" \
  "file://$card" \
  2>/dev/null

mkdir -p "$(dirname "$out")"
cp "$work/og@2x.png" "$out"
sips -z 630 1200 "$out" >/dev/null

echo "wrote $out ($(du -h "$out" | cut -f1))"
