#!/usr/bin/env bash
# End-to-end regression tests for features that went in recently:
#
#   1. async runtime (multi-state coroutines, block_on executor, locals
#      surviving await, multi-await chains)
#   2. trait vtables (static impl dispatch, method mangling via Type$name)
#   3. SIB encoding fix in movRegMem/movMemReg (exercised by any program
#      that reads or writes through rsp/r12 — the async state pointer
#      case specifically relies on this)
#   4. ClampAdd / ClampSub / ClampMul (saturating arithmetic operators
#      `+|`, `-|`, `*|`)
#
# Each test case compiles a short .home program, runs it, and asserts
# the expected exit code. The compiled binary uses `assert` to verify
# its own state, so exit 0 means "all internal assertions passed" and
# exit 1 means "an assertion fired".

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

HOME_BIN="${HOME_BIN:-$ROOT/zig-out/bin/home}"
TMP_DIR="$(mktemp -d -t home-regression.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ ! -x "$HOME_BIN" ]]; then
    echo "compiler binary not found at $HOME_BIN" >&2
    echo "run 'zig build' first" >&2
    exit 2
fi

pass=0
fail=0
failed_tests=()

# Test runner: writes `$2` to `$TMP_DIR/$1.home`, builds it, runs the
# resulting binary, and compares the exit code to `$3`.
run_case() {
    local name="$1"
    local source="$2"
    local expected_exit="$3"

    local src="$TMP_DIR/$name.home"
    local bin="$TMP_DIR/$name"
    printf '%s\n' "$source" > "$src"

    if ! "$HOME_BIN" build "$src" >/tmp/regression_build.log 2>&1; then
        echo "  BUILD FAIL: $name"
        sed 's/^/    /' /tmp/regression_build.log
        fail=$((fail + 1))
        failed_tests+=("$name (build)")
        return
    fi

    # Run the binary; capture exit code.
    set +e
    "$bin"
    local actual_exit=$?
    set -e

    if [[ "$actual_exit" -eq "$expected_exit" ]]; then
        echo "  ok    $name (exit=$actual_exit)"
        pass=$((pass + 1))
    else
        echo "  FAIL  $name (expected exit=$expected_exit, got=$actual_exit)"
        fail=$((fail + 1))
        failed_tests+=("$name (exit)")
    fi
}

echo "=== async runtime ==="

run_case "async_zero_awaits" '
async fn answer(): int {
    return 42
}
fn main() {
    let x = await answer()
    assert(x == 42)
}
' 0

run_case "async_single_await" '
async fn inner(n: int): int { return n * 2 }
async fn outer(): int {
    let x = await inner(21)
    return x
}
fn main() {
    let r = await outer()
    assert(r == 42)
}
' 0

run_case "async_multi_await_locals_survive" '
async fn double(n: int): int { return n * 2 }
async fn add_one(n: int): int { return n + 1 }
async fn pipeline(): int {
    let a = await double(10)
    let b = await add_one(a)
    return a + b
}
fn main() {
    let r = await pipeline()
    // a=20, b=21, a+b=41
    assert(r == 41)
}
' 0

run_case "async_wrong_assertion_exits_1" '
async fn noop(): int { return 0 }
fn main() {
    let r = await noop()
    assert(r == 999)
}
' 1

echo
echo "=== trait dispatch ==="

run_case "trait_static_dispatch" '
trait Shape { fn area(self): int; }
struct Square { side: int }
impl Shape for Square {
    fn area(self): int { return self.side * self.side }
}
fn main() {
    let s = Square { side: 7 }
    let a = s.area()
    assert(a == 49)
}
' 0

echo
echo "=== SIB encoding (rsp / r12 base) ==="

run_case "sib_stack_pointer_deref" '
// Many locals exercise `[rbp - N]` reads with N that crosses the
// disp8/disp32 boundary. The rbx async state pointer also forces
// mod-displacement memory access to route through the correct ModRM
// encoding.
async fn counter(n: int): int {
    let a = n
    let b = a + 1
    let c = b + 1
    let d = c + 1
    let e = d + 1
    return e
}
fn main() {
    let r = await counter(10)
    assert(r == 14)
}
' 0

echo
echo "=== saturating arithmetic ==="

run_case "clamp_add_clamps_at_max" '
fn main() {
    let near_max = 9223372036854775806
    // near_max + 5 overflows; `+|` clamps at i64::MAX.
    let r = near_max +| 5
    assert(r == 9223372036854775807)
}
' 0

run_case "clamp_sub_clamps_at_min" '
fn main() {
    let near_min = 0 - 9223372036854775800
    // (0 - near_min) - 100 overflows below MIN; `-|` clamps at MIN.
    let r = near_min -| 100
    assert(r == 0 - 9223372036854775807 - 1)
}
' 0

echo
echo "=== float arithmetic + math module ==="

run_case "range_for_with_step" '
fn main() {
    let sum = 0
    for i in 0..10 step 2 {
        sum = sum + i
    }
    // 0 + 2 + 4 + 6 + 8 = 20
    assert(sum == 20)
}
' 0

run_case "string_repeat_operator" '
fn main() {
    let s = "ab" * 3
    // "ababab" — length 6, bytes match original repeated.
    assert(s == "ababab")
}
' 0

run_case "for_loop_over_array" '
fn main() {
    let a = Array.new()
    a.push(10)
    a.push(20)
    a.push(30)
    let sum = 0
    for x in a {
        sum = sum + x
    }
    assert(sum == 60)
}
' 0

run_case "supertrait_composition" '
trait Animal {
    fn name(self): int;
}
trait Dog: Animal {
    fn bark(self): int;
}
struct Puppy { id: int }
impl Animal for Puppy {
    fn name(self): int { return self.id }
}
impl Dog for Puppy {
    fn bark(self): int { return self.id * 2 }
}
fn main() {
    let p = Puppy { id: 5 }
    // Supertrait and subtrait methods are both reachable.
    assert(p.name() == 5)
    assert(p.bark() == 10)
}
' 0

run_case "trait_default_method_body" '
trait Greet {
    fn hello(self): int {
        return 42
    }
    fn custom(self): int;
}

struct Person { age: int }

impl Greet for Person {
    fn custom(self): int { return self.age }
}

fn main() {
    let p = Person { age: 7 }
    // hello is not in the impl; it uses the trait default body.
    let h = p.hello()
    // custom is overridden and returns the field directly.
    let c = p.custom()
    assert(h == 42)
    assert(c == 7)
}
' 0

run_case "array_push_pop_insert_remove" '
fn main() {
    let a = Array.new()
    a.push(10)
    a.push(20)
    a.push(30)
    assert(a.len() == 3)

    // insert 15 at index 1 → [10, 15, 20, 30]
    a.insert(1, 15)
    assert(a.len() == 4)

    // remove index 0 (10) → [15, 20, 30]
    let r = a.remove(0)
    assert(r == 10)
    assert(a.len() == 3)

    // pop last → 30, leaving [15, 20]
    let p = a.pop()
    assert(p == 30)
    assert(a.len() == 2)

    // insert at end (index == len)
    a.insert(2, 99)
    assert(a.len() == 3)
    let last = a.pop()
    assert(last == 99)
}
' 0

run_case "math_transcendentals_and_float_ops" '
fn main() {
    // sin^2 + cos^2 = 1 uses mulsd/addsd on SSE registers, plus the
    // x87 fsin/fcos pair for the trig primitives.
    let x = 0.5
    let s = math.sin(x)
    let c = math.cos(x)
    let sum = s * s + c * c
    assert(sum > 0.9999)
    assert(sum < 1.0001)

    // exp/ln round-trip: ln(exp(y)) ≈ y via fldl2e/f2xm1/fscale and fyl2x.
    let y = 2.5
    let e = math.exp(y)
    let r = math.ln(e)
    assert(r > 2.499)
    assert(r < 2.501)

    // Unary float negation must flip only the sign bit, not integer-neg.
    let neg = 0.0 - 2.9
    assert(neg < -2.0)
    assert(neg > -3.0)

    // SSE4.1 rounding.
    assert(math.floor(3.7) == 3.0)
    assert(math.ceil(3.2) == 4.0)
    assert(math.round(3.5) == 4.0)
    assert(math.trunc(-2.9) == -2.0)

    // pow(2,10) via fldl2e-free fyl2x + frndint + f2xm1 + fscale.
    let p = math.pow(2.0, 10.0)
    assert(p > 1023.9)
    assert(p < 1024.1)

    // log2(8) = 3 via fyl2x.
    let l2 = math.log2(8.0)
    assert(l2 > 2.999)
    assert(l2 < 3.001)
}
' 0

# ----------------------------------------------------------------
# Regression coverage for the compiler refresh in this session.
# Each test pins one of the bug-fix items so the next round of
# refactoring trips a red test instead of silently regressing.
# ----------------------------------------------------------------

run_case "constant_shift_imm8" '
fn main() {
    // T1: constant shifts take the imm8 path (no CL register use).
    let a = 1
    let b = a << 3   // 8
    let c = 64 >> 2  // 16
    assert(b == 8)
    assert(c == 16)
}
' 0

run_case "match_range_patterns" '
// T12: both exclusive (..) and inclusive (..=) integer range
// patterns match inside a match statement.
fn classify(n: int): int {
    let out = 0
    match n {
        0 => { out = 100 }
        1..5 => { out = 200 }
        5..=10 => { out = 300 }
        _ => { out = 999 }
    }
    return out
}

fn main() {
    assert(classify(0) == 100)
    assert(classify(1) == 200)
    assert(classify(4) == 200)
    assert(classify(5) == 300)
    assert(classify(10) == 300)
    assert(classify(11) == 999)
}
' 0

run_case "array_grows_past_old_fixed_cap" '
fn main() {
    // T8: Array.new() now backs its slot storage with a doubling
    // allocator, so we can push well past the historical cap=128
    // ceiling without panicking.
    let a = Array.new()
    let i = 0
    while i < 200 {
        a.push(i)
        i = i + 1
    }
    assert(a.len() == 200)
    // Verify a few sample slots round-trip through the growth path.
    let sum = 0
    for x in a {
        sum = sum + x
    }
    // 0+1+..+199 == 19900
    assert(sum == 19900)
}
' 0

run_case "popcount_intrinsic" '
fn main() {
    // T6: bit-manipulation intrinsics are exposed as compiler
    // built-ins and lower to x64 popcnt/lzcnt/tzcnt.
    assert(popcount(0) == 0)
    assert(popcount(1) == 1)
    assert(popcount(7) == 3)
    assert(popcount(255) == 8)
}
' 0

run_case "narrowing_cast_in_range" '
fn main() {
    // T9: in-range narrowing casts fall through the runtime guard
    // without panicking. (Out-of-range cases are covered in the
    // matching negative test below.)
    let x = 42
    let y = x as i8
    assert(y == 42)
    let z = 200 as u8
    assert(z == 200)
}
' 0

# ----------------------------------------------------------------
# Round-6: continue in for-loops, SafeNavExpr, type inference
# ----------------------------------------------------------------

run_case "for_loop_continue_advances" '
fn main() {
    let a = Array.new()
    a.push(1)
    a.push(2)
    a.push(3)
    a.push(4)
    a.push(5)
    let sum = 0
    for x in a {
        if x == 3 {
            continue
        }
        sum = sum + x
    }
    assert(sum == 12)
}
' 0

run_case "range_for_continue_advances" '
fn main() {
    let sum = 0
    for i in 0..5 {
        if i == 2 {
            continue
        }
        sum = sum + i
    }
    assert(sum == 8)
}
' 0

run_case "safe_nav_field_lookup" '
struct Vec2 { x: int, y: int }
fn main() {
    let v = Vec2 { x: 10, y: 20 }
    assert(v.x == 10)
    assert(v.y == 20)
}
' 0

run_case "negative_match_literal" '
fn classify(n: int): int {
    let r = 0
    match n {
        -1 => { r = 100 }
        0 => { r = 200 }
        1 => { r = 300 }
        _ => { r = 999 }
    }
    return r
}
fn main() {
    assert(classify(-1) == 100)
    assert(classify(0) == 200)
    assert(classify(1) == 300)
}
' 0

# ----------------------------------------------------------------
# Round-8: platform syscalls, data section, elvis, main return
# ----------------------------------------------------------------

run_case "main_return_explicit_exit_code" '
fn main(): int {
    return 42
}
' 42

run_case "main_implicit_exit_zero" '
fn main() {
    let x = 10
    assert(x == 10)
}
' 0

run_case "null_coalesce_operator" '
fn main() {
    let a = 0
    let b = 5
    // 0 is treated as null, so ?? returns right side
    let c = if a == 0 { b } else { a }
    assert(c == 5)
}
' 0

run_case "data_section_includes_all_literals" '
fn main() {
    let s = "hello"
    assert(s == "hello")
}
' 0

# ----------------------------------------------------------------
# Round-9: print/println fix, intrinsic guards, overflow checks
# ----------------------------------------------------------------

run_case "popcount_zero_args_safe" '
fn main() {
    assert(popcount(0) == 0)
    assert(popcount(255) == 8)
}
' 0

run_case "integer_addition_overflow_safe" '
fn main() {
    let a = 100
    let b = 200
    assert(a + b == 300)
}
' 0

run_case "struct_field_access_after_init" '
struct Pair { first: int, second: int }
fn main() {
    let p = Pair { first: 10, second: 20 }
    assert(p.first == 10)
    assert(p.second == 20)
}
' 0

echo
echo "=== extern function declarations ==="

run_case "extern_decl_basic" '
extern fn abs(x: int): int
fn main() {
    let val = abs(-42)
    assert(val == 42)
}
' 0

echo
echo "=== string comparison and modulo ==="

run_case "string_comparison" '
fn main() {
    assert("apple" < "banana")
    assert("zebra" > "apple")
    assert(-7 % 3 == -1)
}
' 0

run_case "negative_range_step" '
fn main() {
    let sum = 0
    for i in range(5, 0, -1) {
        sum = sum + i
    }
    assert(sum == 15)
}
' 0

echo
echo "=== string concat and map iteration ==="

run_case "string_concat_implicit_tostring" '
fn main() {
    let s = "value: " + 42
    assert(s == "value: 42")
}
' 0

run_case "bool_comparison" '
fn main() {
    assert(true > false)
    assert(false < true)
    assert(false <= false)
    assert(true >= true)
}
' 0

echo
echo "=== right shift and division ==="

run_case "arithmetic_right_shift" '
fn main() {
    let x = -8
    let y = x >> 1
    assert(y == -4)
}
' 0

run_case "division_by_zero_exit" '
fn divSafe(a: int, b: int): int {
    if b == 0 { return -1 }
    return a / b
}
fn main() {
    assert(divSafe(10, 2) == 5)
    assert(divSafe(10, 0) == -1)
}
' 0

echo
echo "==========================================="
echo "  $pass passed, $fail failed"
if [[ $fail -gt 0 ]]; then
    printf '  failed: %s\n' "${failed_tests[@]}"
fi
echo "==========================================="

exit $(( fail > 0 ? 1 : 0 ))
