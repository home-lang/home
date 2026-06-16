#!/usr/bin/env bash
# Recount the parity numbers cited in README.md and the docs/PARITY-*.md
# pages, then print a markdown block ready to paste into the README's
# "Headline numbers" table.
#
# Usage:   scripts/measure-parity.sh [--markdown|--values|--diff]
#   --markdown  (default) print the headline-table block as markdown.
#   --values    print KEY=VALUE pairs for scripting.
#   --diff      compare current README values against fresh counts and
#               exit 1 if anything drifted.
#
# This script is intentionally pure-shell and dependency-free (uses
# only awk / grep / find / wc) so it runs anywhere the repo does. It
# does NOT run the TS conformance corpus — those numbers ratchet
# weekly and have their own reproducer (see README).

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

# -----------------------------------------------------------------
# Constants — values that aren't derivable from the working tree.
# -----------------------------------------------------------------

# Upstream Bun source file count, excluding test/codegen/*_jsc/*_macros.
# Pinned by packages/runtime/PORT_AUDIT_2026-05-18.md against Bun SHA
# fd0b6f1a. Refresh this constant when the audit doc moves forward.
BUN_UPSTREAM_FILES=1193

# Approximate full external `bun.X` surface (identifiers) as documented
# in the head comment of packages/compat/src/compat.zig.
BUN_COMPAT_SYMBOLS_TOTAL=103

# Approximate full LSP 3.18 method surface (denominator for routed%).
# Hand-counted from the LSP spec; refresh if the spec rev changes.
LSP_TOTAL_METHODS=70

# -----------------------------------------------------------------
# Live counts from the working tree.
# -----------------------------------------------------------------

count_runtime_files() {
    find packages/runtime/src -type f -name "*.zig" 2>/dev/null | wc -l | tr -d ' '
}

count_runtime_subsystems() {
    find packages/runtime/src -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '
}

count_node_files() {
    find packages/runtime/src/node -type f -name "*.zig" 2>/dev/null | wc -l | tr -d ' '
}

count_jsc_files() {
    find packages/runtime/src/jsc -type f -name "*.zig" 2>/dev/null | wc -l | tr -d ' '
}

count_compat_symbols() {
    # Tier-0 symbols are `pub const` or `pub fn` at top level of compat.zig,
    # plus the top-level namespaces `ast` and `fs` (which themselves
    # contain Index / Path). Count top-level `pub` declarations.
    grep -cE "^pub (const|fn) " packages/compat/src/compat.zig 2>/dev/null || echo 0
}

count_lsp_methods() {
    awk '/^pub const SUPPORTED_METHODS/,/^};/' \
        packages/ts_lsp_server/src/ts_lsp_server.zig 2>/dev/null \
        | grep -cE '^    "[^"]+"'
}

count_ts_diag_codes() {
    grep -cE "\.code = [0-9]+" packages/ts_diagnostics/src/ts_diagnostic_codes.zig 2>/dev/null \
        || echo 0
}

count_capability_rows() {
    # Status rows in the capability matrix: lines like `| <text> | <icon> ... |`
    grep -cE "^\| .* \| (✅|🚧|❌)" docs/CAPABILITY_MATRIX.md 2>/dev/null || echo 0
}

count_capability_stable() {
    grep -cE "^\| .* \| ✅" docs/CAPABILITY_MATRIX.md 2>/dev/null || echo 0
}

count_capability_partial() {
    grep -cE "^\| .* \| 🚧" docs/CAPABILITY_MATRIX.md 2>/dev/null || echo 0
}

count_capability_notyet() {
    grep -cE "^\| .* \| ❌" docs/CAPABILITY_MATRIX.md 2>/dev/null || echo 0
}

# -----------------------------------------------------------------
# Computed values
# -----------------------------------------------------------------

RUNTIME_FILES="$(count_runtime_files)"
RUNTIME_SUBSYSTEMS="$(count_runtime_subsystems)"
NODE_FILES="$(count_node_files)"
JSC_FILES="$(count_jsc_files)"
COMPAT_SYMBOLS="$(count_compat_symbols)"
LSP_METHODS="$(count_lsp_methods)"
TS_DIAG_CODES="$(count_ts_diag_codes)"
CAPABILITY_ROWS="$(count_capability_rows)"
CAPABILITY_STABLE="$(count_capability_stable)"
CAPABILITY_PARTIAL="$(count_capability_partial)"
CAPABILITY_NOTYET="$(count_capability_notyet)"

# pct(numerator, denominator) — prints decimal percent with 1 decimal place.
pct() {
    local num="$1" den="$2"
    if [[ "${den}" -eq 0 ]]; then echo "0.0"; return; fi
    awk -v n="${num}" -v d="${den}" 'BEGIN { printf "%.1f", (n / d) * 100 }'
}

RUNTIME_PCT="$(pct "${RUNTIME_FILES}" "${BUN_UPSTREAM_FILES}")"
COMPAT_PCT="$(pct "${COMPAT_SYMBOLS}" "${BUN_COMPAT_SYMBOLS_TOTAL}")"
LSP_PCT="$(pct "${LSP_METHODS}" "${LSP_TOTAL_METHODS}")"

# -----------------------------------------------------------------
# Output modes
# -----------------------------------------------------------------

print_markdown() {
    cat <<EOF
| Area | Coverage | Source |
|---|---|---|
| **TypeScript — coarse corpus** | **5,907 / 5,907 — 100%** | \`HOME_TS_CONFORMANCE_FULL=1\` against upstream conformance corpus |
| **TypeScript — exact (byte-for-byte)** | **4,179 / 5,907 — ~70.7%** | \`HOME_TS_CONFORMANCE_FULL=1 HOME_TS_CONFORMANCE_EXACT=1\`; 1,728 exact cases remain |
| **TypeScript — baseline-aware (19 folders)** | **586 / 586 — 100%** | per-fixture \`.errors.txt\` byte comparison |
| **TypeScript — named-category survey** | **86 / 86 — 100%** | \`assignmentCompatibility\` + \`comparable\` + \`inOperator\` + \`stringLiteral\` |
| **TypeScript — diagnostic codes** | **~${TS_DIAG_CODES} entries** | mirrors the full upstream \`diag(code, …)\` table |
| **LSP wire methods** | **${LSP_METHODS} / ~${LSP_TOTAL_METHODS} — ~${LSP_PCT}%** | \`SUPPORTED_METHODS\` in \`packages/ts_lsp_server/\` |
| **Bun runtime — source files ported** | **${RUNTIME_FILES} / ${BUN_UPSTREAM_FILES} — ~${RUNTIME_PCT}%** | substrate + JSC bring-up in progress |
| **Bun compat shim — \`bun.*\` symbols** | **${COMPAT_SYMBOLS} / ~${BUN_COMPAT_SYMBOLS_TOTAL} — ~${COMPAT_PCT}%** | Tier-0 lets vendored Bun source compile against Home's stdlib |
| **Node.js — \`node:*\` binding files** | **${NODE_FILES} files** | Zig substrate landing module-by-module |
| **JSC bring-up (Phase 12.2)** | **${JSC_FILES} files** | M1-M6 milestones landed |
| **Language features (capability matrix)** | **${CAPABILITY_STABLE} stable / ${CAPABILITY_PARTIAL} partial / ${CAPABILITY_NOTYET} not-yet — ${CAPABILITY_ROWS} total** | from docs/CAPABILITY_MATRIX.md |
EOF
}

print_values() {
    cat <<EOF
RUNTIME_FILES=${RUNTIME_FILES}
RUNTIME_SUBSYSTEMS=${RUNTIME_SUBSYSTEMS}
RUNTIME_PCT=${RUNTIME_PCT}
BUN_UPSTREAM_FILES=${BUN_UPSTREAM_FILES}
NODE_FILES=${NODE_FILES}
JSC_FILES=${JSC_FILES}
COMPAT_SYMBOLS=${COMPAT_SYMBOLS}
COMPAT_SYMBOLS_TOTAL=${BUN_COMPAT_SYMBOLS_TOTAL}
COMPAT_PCT=${COMPAT_PCT}
LSP_METHODS=${LSP_METHODS}
LSP_TOTAL_METHODS=${LSP_TOTAL_METHODS}
LSP_PCT=${LSP_PCT}
TS_DIAG_CODES=${TS_DIAG_CODES}
CAPABILITY_ROWS=${CAPABILITY_ROWS}
CAPABILITY_STABLE=${CAPABILITY_STABLE}
CAPABILITY_PARTIAL=${CAPABILITY_PARTIAL}
CAPABILITY_NOTYET=${CAPABILITY_NOTYET}
EOF
}

# diff_against_readme — exits 1 if any value in README.md drifted from
# the live count. Best-effort grep: extracts the raw N from rows in
# the headline table and compares against this run's number.
diff_against_readme() {
    local drift=0
    extract() {
        # Pull the leftmost integer (with optional commas) from the
        # first column of a markdown table cell. Used to find e.g.
        # `380` in `**380 / 1,193 — ~31.9%**`.
        local pattern="$1"
        local file="$2"
        grep -E "${pattern}" "${file}" 2>/dev/null \
            | head -1 \
            | grep -oE '\*\*[0-9,]+' \
            | head -1 \
            | tr -d '*,'
    }
    check() {
        local label="$1" expected="$2" actual="$3"
        if [[ -z "${expected}" ]]; then
            echo "  ? ${label}: could not parse README" >&2
            return
        fi
        if [[ "${expected}" != "${actual}" ]]; then
            echo "  ✗ ${label}: README=${expected} live=${actual}" >&2
            drift=1
        else
            echo "  ✓ ${label}: ${actual}" >&2
        fi
    }
    echo "Comparing README.md against live counts..." >&2
    check "runtime files"   "$(extract 'Bun runtime — source files ported' README.md)" "${RUNTIME_FILES}"
    check "node files"      "$(extract 'Node.js — .node:.. binding files' README.md)" "${NODE_FILES}"
    check "jsc files"       "$(extract 'JSC bring-up' README.md)"                       "${JSC_FILES}"
    check "compat symbols"  "$(extract 'Bun compat shim' README.md)"                    "${COMPAT_SYMBOLS}"
    check "LSP methods"     "$(extract 'LSP wire methods' README.md)"                   "${LSP_METHODS}"
    if [[ "${drift}" -ne 0 ]]; then
        echo "" >&2
        echo "README is stale. Re-run \`scripts/measure-parity.sh --markdown\` and paste" >&2
        echo "the result into the 'Headline numbers' table." >&2
        return 1
    fi
    echo "README is in sync." >&2
    return 0
}

mode="${1:-}"
case "${mode}" in
    ""|--markdown) print_markdown ;;
    --values)      print_values ;;
    --diff)        diff_against_readme ;;
    -h|--help)
        sed -n '2,12p' "$0"
        exit 0
        ;;
    *)
        echo "unknown mode: ${mode}" >&2
        echo "usage: $0 [--markdown|--values|--diff]" >&2
        exit 2
        ;;
esac
