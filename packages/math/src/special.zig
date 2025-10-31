// Home Programming Language - Special Mathematical Functions
// Gamma, error functions, Bessel functions, etc.

const std = @import("std");
const basic = @import("basic.zig");
const transcendental = @import("transcendental.zig");

// Gamma function and related functions
pub const Gamma = struct {
    // Gamma function Γ(x)
    pub fn gamma(comptime T: type, x: T) T {
        // Use Stirling's approximation for large x
        if (x > 12.0) {
            const sqrt_2pi: T = 2.50662827463100050242;
            const log_result = (x - 0.5) * @log(x) - x + @log(sqrt_2pi);
            return @exp(log_result);
        }

        // Use Lanczos approximation for smaller values
        return lanczos(T, x);
    }

    // Natural log of gamma function
    pub fn lgamma(comptime T: type, x: T) T {
        return @log(gamma(T, x));
    }

    // Lanczos approximation for gamma function
    fn lanczos(comptime T: type, x: T) T {
        const g: T = 7.0;
        const coef = [_]T{
            0.99999999999980993,
            676.5203681218851,
            -1259.1392167224028,
            771.32342877765313,
            -176.61502916214059,
            12.507343278686905,
            -0.13857109526572012,
            9.9843695780195716e-6,
            1.5056327351493116e-7,
        };

        if (x < 0.5) {
            const pi: T = 3.14159265358979323846;
            return pi / (@sin(pi * x) * lanczos(T, 1.0 - x));
        }

        const z = x - 1.0;
        var accum: T = coef[0];
        for (coef[1..], 0..) |c, i| {
            accum += c / (z + @as(T, @floatFromInt(i + 1)));
        }

        const t = z + g + 0.5;
        const sqrt_2pi: T = 2.50662827463100050242;
        return sqrt_2pi * std.math.pow(T, t, z + 0.5) * @exp(-t) * accum;
    }

    // Factorial (uses gamma)
    pub fn factorial(comptime T: type, n: usize) T {
        return gamma(T, @as(T, @floatFromInt(n + 1)));
    }

    // Beta function B(x, y) = Γ(x)Γ(y)/Γ(x+y)
    pub fn beta(comptime T: type, x: T, y: T) T {
        return (gamma(T, x) * gamma(T, y)) / gamma(T, x + y);
    }
};

// Error function and related
pub const ErrorFunc = struct {
    // Error function erf(x)
    pub fn erf(comptime T: type, x: T) T {
        // Abramowitz and Stegun approximation
        const a1: T = 0.254829592;
        const a2: T = -0.284496736;
        const a3: T = 1.421413741;
        const a4: T = -1.453152027;
        const a5: T = 1.061405429;
        const p: T = 0.3275911;

        const sign: T = if (x < 0) -1.0 else 1.0;
        const abs_x = @abs(x);

        const t = 1.0 / (1.0 + p * abs_x);
        const t2 = t * t;
        const t3 = t2 * t;
        const t4 = t3 * t;
        const t5 = t4 * t;

        const y = 1.0 - (((((a5 * t5 + a4 * t4) + a3 * t3) + a2 * t2) + a1 * t) * @exp(-abs_x * abs_x));

        return sign * y;
    }

    // Complementary error function erfc(x) = 1 - erf(x)
    pub fn erfc(comptime T: type, x: T) T {
        return 1.0 - erf(T, x);
    }

    // Inverse error function
    pub fn erfInv(comptime T: type, x: T) T {
        // Rational approximation
        const a = [_]T{ 0.886226899, -1.645349621, 0.914624893, -0.140543331 };
        const b = [_]T{ -2.118377725, 1.442710462, -0.329097515, 0.012229801 };
        const c = [_]T{ -1.970840454, -1.624906493, 3.429567803, 1.641345311 };
        const d = [_]T{ 3.543889200, 1.637067800 };

        if (@abs(x) >= 1.0) return std.math.nan(T);

        const x2 = x * x;
        var num = a[0] + a[1] * x2 + a[2] * x2 * x2 + a[3] * x2 * x2 * x2;
        var den = 1.0 + b[0] * x2 + b[1] * x2 * x2 + b[2] * x2 * x2 * x2 + b[3] * x2 * x2 * x2 * x2;

        if (@abs(x) < 0.7) {
            return x * num / den;
        }

        const y = if (x < 0) -1.0 else 1.0;
        const z = @sqrt(-@log((1.0 - @abs(x)) / 2.0));
        num = c[0] + c[1] * z + c[2] * z * z + c[3] * z * z * z;
        den = 1.0 + d[0] * z + d[1] * z * z;

        return y * num / den;
    }
};

// Bessel functions (simplified implementations)
pub const Bessel = struct {
    // Bessel function of the first kind J₀(x)
    pub fn j0(comptime T: type, x: T) T {
        const abs_x = @abs(x);

        if (abs_x < 8.0) {
            const y = x * x;
            const ans1 = 57568490574.0 + y * (-13362590354.0 + y * (651619640.7 + y * (-11214424.18 + y * (77392.33017 + y * -184.9052456))));
            const ans2 = 57568490411.0 + y * (1029532985.0 + y * (9494680.718 + y * (59272.64853 + y * (267.8532712 + y))));
            return ans1 / ans2;
        }

        const z = 8.0 / abs_x;
        const y = z * z;
        const xx = abs_x - 0.785398164;
        const ans1 = 1.0 + y * (-0.1098628627e-2 + y * (0.2734510407e-4 + y * (-0.2073370639e-5 + y * 0.2093887211e-6)));
        const ans2 = -0.1562499995e-1 + y * (0.1430488765e-3 + y * (-0.6911147651e-5 + y * (0.7621095161e-6 - y * 0.934935152e-7)));
        const sqrt_val = @sqrt(0.636619772 / abs_x);
        return sqrt_val * (@cos(xx) * ans1 - z * @sin(xx) * ans2);
    }

    // Bessel function of the first kind J₁(x)
    pub fn j1(comptime T: type, x: T) T {
        const abs_x = @abs(x);

        if (abs_x < 8.0) {
            const y = x * x;
            const ans1 = x * (72362614232.0 + y * (-7895059235.0 + y * (242396853.1 + y * (-2972611.439 + y * (15704.48260 + y * -30.16036606)))));
            const ans2 = 144725228442.0 + y * (2300535178.0 + y * (18583304.74 + y * (99447.43394 + y * (376.9991397 + y))));
            return ans1 / ans2;
        }

        const z = 8.0 / abs_x;
        const y = z * z;
        const xx = abs_x - 2.356194491;
        const ans1 = 1.0 + y * (0.183105e-2 + y * (-0.3516396496e-4 + y * (0.2457520174e-5 + y * -0.240337019e-6)));
        const ans2 = 0.04687499995 + y * (-0.2002690873e-3 + y * (0.8449199096e-5 + y * (-0.88228987e-6 + y * 0.105787412e-6)));
        const sqrt_val = @sqrt(0.636619772 / abs_x);
        const result = sqrt_val * (@cos(xx) * ans1 - z * @sin(xx) * ans2);
        return if (x < 0.0) -result else result;
    }
};

// Zeta function (Riemann zeta)
pub fn zeta(comptime T: type, s: T) T {
    if (s == 1.0) return std.math.inf(T);

    // Simple series approximation
    var sum: T = 0.0;
    var n: T = 1.0;
    const max_terms: usize = 100;

    var i: usize = 0;
    while (i < max_terms) : (i += 1) {
        const term = 1.0 / std.math.pow(T, n, s);
        sum += term;
        if (term < 1e-10) break;
        n += 1.0;
    }

    return sum;
}

// Exponential integral Ei(x)
pub fn expIntegral(comptime T: type, x: T) T {
    const euler_mascheroni: T = 0.5772156649015329;

    if (x <= 0.0) return std.math.nan(T);

    if (x < 1.0) {
        // Series expansion
        var sum: T = 0.0;
        var term: T = x;
        var n: T = 1.0;

        var i: usize = 0;
        while (i < 100) : (i += 1) {
            sum += term / n;
            if (@abs(term) < 1e-10) break;
            n += 1.0;
            term *= x / n;
        }

        return euler_mascheroni + @log(x) + sum;
    }

    // Asymptotic expansion
    var sum: T = 0.0;
    var term: T = 1.0;

    var k: T = 1.0;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const new_term = term / x;
        sum += new_term;
        if (@abs(new_term) < 1e-10) break;
        term *= k;
        k += 1.0;
    }

    return @exp(x) * sum / x;
}

test "gamma function" {
    const testing = std.testing;

    // Γ(1) = 1
    try testing.expectApproxEqAbs(@as(f64, 1.0), Gamma.gamma(f64, 1.0), 0.001);

    // Γ(2) = 1! = 1
    try testing.expectApproxEqAbs(@as(f64, 1.0), Gamma.gamma(f64, 2.0), 0.001);

    // Γ(3) = 2! = 2
    try testing.expectApproxEqAbs(@as(f64, 2.0), Gamma.gamma(f64, 3.0), 0.01);

    // Γ(5) = 4! = 24
    try testing.expectApproxEqAbs(@as(f64, 24.0), Gamma.gamma(f64, 5.0), 0.1);
}

test "factorial" {
    const testing = std.testing;

    try testing.expectApproxEqAbs(@as(f64, 1.0), Gamma.factorial(f64, 0), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 1.0), Gamma.factorial(f64, 1), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 2.0), Gamma.factorial(f64, 2), 0.01);
    try testing.expectApproxEqAbs(@as(f64, 6.0), Gamma.factorial(f64, 3), 0.01);
    try testing.expectApproxEqAbs(@as(f64, 24.0), Gamma.factorial(f64, 4), 0.1);
    try testing.expectApproxEqAbs(@as(f64, 120.0), Gamma.factorial(f64, 5), 0.5);
}

test "error function" {
    const testing = std.testing;

    try testing.expectApproxEqAbs(@as(f64, 0.0), ErrorFunc.erf(f64, 0.0), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0.8427), ErrorFunc.erf(f64, 1.0), 0.001);
    try testing.expectApproxEqAbs(@as(f64, -0.8427), ErrorFunc.erf(f64, -1.0), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 1.0), ErrorFunc.erfc(f64, 0.0), 0.001);
}

test "bessel j0" {
    const testing = std.testing;

    try testing.expectApproxEqAbs(@as(f64, 1.0), Bessel.j0(f64, 0.0), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0.7652), Bessel.j0(f64, 1.0), 0.01);
}

test "bessel j1" {
    const testing = std.testing;

    try testing.expectApproxEqAbs(@as(f64, 0.0), Bessel.j1(f64, 0.0), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0.4401), Bessel.j1(f64, 1.0), 0.01);
}

test "zeta function" {
    const testing = std.testing;

    // ζ(2) = π²/6 ≈ 1.6449
    try testing.expectApproxEqAbs(@as(f64, 1.6449), zeta(f64, 2.0), 0.01);

    // ζ(4) ≈ 1.0823
    try testing.expectApproxEqAbs(@as(f64, 1.0823), zeta(f64, 4.0), 0.01);
}
