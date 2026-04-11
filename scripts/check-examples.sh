#!/usr/bin/env bash
# Validate every .home example in examples/ by running it through the compiler.
#
# Usage:   scripts/check-examples.sh
# Exit 0:  every example parses + type-checks + compiles cleanly.
# Exit 1:  one or more examples failed; per-file errors are printed inline.
#
# This is the CI gate for the examples directory. If you add a new example,
# either make it compile or move it under examples/wip/ where it is ignored.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOME_BIN="${HOME_BIN:-${ROOT}/zig-out/bin/home}"

if [[ ! -x "${HOME_BIN}" ]]; then
    echo "compiler binary not found at ${HOME_BIN}" >&2
    echo "build it first with: zig build" >&2
    exit 2
fi

shopt -s nullglob
fail_count=0
pass_count=0
skipped=()

for src in "${ROOT}"/examples/*.home "${ROOT}"/examples/*.hm; do
    name="$(basename "${src}")"

    # Allow opting an example out via a "// skip-ci: <reason>" line at the top.
    if head -n 1 "${src}" | grep -q '// skip-ci'; then
        skipped+=("${name}")
        continue
    fi

    if "${HOME_BIN}" check "${src}" >/tmp/check-examples.log 2>&1; then
        pass_count=$((pass_count + 1))
        echo "ok    ${name}"
    else
        fail_count=$((fail_count + 1))
        echo "FAIL  ${name}"
        sed 's/^/      /' /tmp/check-examples.log
    fi
done

echo
echo "examples: ${pass_count} ok, ${fail_count} failed, ${#skipped[@]} skipped"
if [[ ${#skipped[@]} -gt 0 ]]; then
    printf '  skipped: %s\n' "${skipped[@]}"
fi

exit $(( fail_count > 0 ? 1 : 0 ))
