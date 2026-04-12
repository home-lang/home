#!/usr/bin/env bash
# Run the unit-test suite for individual compiler modules.
#
# Not every package is wired up here yet — only the ones whose source
# compiles cleanly. Adding new packages is a one-line append to the
# table below once the code compiles.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -z "${ZIG:-}" ]]; then
    ZIG="$(command -v zig 2>/dev/null || true)"
fi

if [[ -z "$ZIG" || ! -x "$ZIG" ]]; then
    echo "zig not found in PATH" >&2
    exit 2
fi

pass=0
fail=0
failed_modules=()

# A module entry is `<label>:<zig-test-args...>` joined with literal `|`.
# The label is what we print; the args after `:` go straight to `zig test`.
modules=(
    'checked_cast|packages/codegen/src/checked_cast.zig'
    'vec|packages/collections/src/vec.zig'
    'optimizer+scheduler+vectorizer+regalloc|packages/codegen/src/optimizer.zig'
    'monomorphization-cycle|packages/codegen/tests/monomorphization_cycle_test.zig'
    'unused_variable|--dep lexer -Mroot=packages/linter/src/rules/unused_variable.zig -Mlexer=packages/lexer/src/lexer.zig'
    'dead_code_after_return|--dep lexer -Mroot=packages/linter/src/rules/dead_code_after_return.zig -Mlexer=packages/lexer/src/lexer.zig'
    'const-fold|--dep ast --dep parser -Mroot=packages/parser/tests/const_fold_test.zig --dep lexer -Mast=packages/ast/src/ast.zig --dep ast --dep lexer --dep diagnostics --dep macros -Mparser=packages/parser/src/parser.zig -Mlexer=packages/lexer/src/lexer.zig --dep ast -Mdiagnostics=packages/diagnostics/src/diagnostics.zig --dep ast -Mmacros=packages/macros/src/macro_system.zig'
    'bounds_checking|--dep ast -Mroot=packages/types/src/bounds_checking.zig --dep lexer -Mast=packages/ast/src/ast.zig -Mlexer=packages/lexer/src/lexer.zig'
    'pattern_checker|--dep ast -Mroot=packages/types/src/pattern_checker.zig --dep lexer -Mast=packages/ast/src/ast.zig -Mlexer=packages/lexer/src/lexer.zig'
    'trait_codegen|--dep ast -Mroot=packages/codegen/src/trait_codegen.zig --dep lexer -Mast=packages/ast/src/ast.zig -Mlexer=packages/lexer/src/lexer.zig'
    'type_inference|--dep ast --dep traits -Mroot=packages/types/src/type_inference.zig --dep lexer -Mast=packages/ast/src/ast.zig --dep ast -Mtraits=packages/traits/src/traits.zig -Mlexer=packages/lexer/src/lexer.zig'
    'comptime|--dep ast -Mroot=packages/comptime/src/comptime.zig --dep lexer -Mast=packages/ast/src/ast.zig -Mlexer=packages/lexer/src/lexer.zig'
)

for entry in "${modules[@]}"; do
    label="${entry%%|*}"
    args="${entry#*|}"

    printf '== %-45s ' "$label"
    # shellcheck disable=SC2086
    if "$ZIG" test $args >/tmp/run_tests.log 2>&1; then
        # Pull the "All N tests passed." footer.
        tail -1 /tmp/run_tests.log
        pass=$((pass + 1))
    else
        echo "FAIL"
        sed 's/^/    /' /tmp/run_tests.log
        fail=$((fail + 1))
        failed_modules+=("$label")
    fi
done

echo
echo "================================================================"
echo "  $pass module(s) passed, $fail failed"
if [[ $fail -gt 0 ]]; then
    printf '  failed: %s\n' "${failed_modules[@]}"
fi
echo "================================================================"

exit $(( fail > 0 ? 1 : 0 ))
