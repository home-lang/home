// Home Programming Language - Complex Numbers
// Complex number arithmetic and operations

const std = @import("std");
const basic = @import("basic.zig");
const transcendental = @import("transcendental.zig");

pub fn Complex(comptime T: type) type {
    return struct {
        real: T,
        imag: T,

        const Self = @This();

        // Constructor
        pub fn init(real: T, imag: T) Self {
            return .{ .real = real, .imag = imag };
        }

        // Create from polar coordinates
        pub fn fromPolar(r: T, theta: T) Self {
            return .{
                .real = r * @cos(theta),
                .imag = r * @sin(theta),
            };
        }

        // Arithmetic operations
        pub fn add(self: Self, other: Self) Self {
            return .{
                .real = self.real + other.real,
                .imag = self.imag + other.imag,
            };
        }

        pub fn sub(self: Self, other: Self) Self {
            return .{
                .real = self.real - other.real,
                .imag = self.imag - other.imag,
            };
        }

        pub fn mul(self: Self, other: Self) Self {
            return .{
                .real = self.real * other.real - self.imag * other.imag,
                .imag = self.real * other.imag + self.imag * other.real,
            };
        }

        pub fn div(self: Self, other: Self) Self {
            const denom = other.real * other.real + other.imag * other.imag;
            return .{
                .real = (self.real * other.real + self.imag * other.imag) / denom,
                .imag = (self.imag * other.real - self.real * other.imag) / denom,
            };
        }

        // Scalar operations
        pub fn scale(self: Self, scalar: T) Self {
            return .{
                .real = self.real * scalar,
                .imag = self.imag * scalar,
            };
        }

        // Negation
        pub fn neg(self: Self) Self {
            return .{
                .real = -self.real,
                .imag = -self.imag,
            };
        }

        // Complex conjugate
        pub fn conjugate(self: Self) Self {
            return .{
                .real = self.real,
                .imag = -self.imag,
            };
        }

        // Magnitude (absolute value)
        pub fn abs(self: Self) T {
            return @sqrt(self.real * self.real + self.imag * self.imag);
        }

        // Squared magnitude
        pub fn absSq(self: Self) T {
            return self.real * self.real + self.imag * self.imag;
        }

        // Phase angle (argument)
        pub fn arg(self: Self) T {
            return std.math.atan2(self.imag, self.real);
        }

        // Normalization (unit complex number)
        pub fn normalize(self: Self) Self {
            const magnitude = self.abs();
            return .{
                .real = self.real / magnitude,
                .imag = self.imag / magnitude,
            };
        }

        // Complex exponential
        pub fn exp(self: Self) Self {
            const exp_real = @exp(self.real);
            return .{
                .real = exp_real * @cos(self.imag),
                .imag = exp_real * @sin(self.imag),
            };
        }

        // Natural logarithm
        pub fn log(self: Self) Self {
            return .{
                .real = @log(self.abs()),
                .imag = self.arg(),
            };
        }

        // Power function
        pub fn pow(self: Self, exponent: Self) Self {
            // z^w = exp(w * ln(z))
            const ln_z = self.log();
            const w_ln_z = exponent.mul(ln_z);
            return w_ln_z.exp();
        }

        // Square root
        pub fn sqrt(self: Self) Self {
            const r = self.abs();
            const theta = self.arg();
            return fromPolar(@sqrt(r), theta / 2.0);
        }

        // Trigonometric functions
        pub fn sin(self: Self) Self {
            // sin(z) = (e^(iz) - e^(-iz)) / (2i)
            const i = init(0.0, 1.0);
            const iz = i.mul(self);
            const neg_iz = iz.neg();
            const exp_iz = iz.exp();
            const exp_neg_iz = neg_iz.exp();
            const diff = exp_iz.sub(exp_neg_iz);
            const two_i = init(0.0, 2.0);
            return diff.div(two_i);
        }

        pub fn cos(self: Self) Self {
            // cos(z) = (e^(iz) + e^(-iz)) / 2
            const i = init(0.0, 1.0);
            const iz = i.mul(self);
            const neg_iz = iz.neg();
            const exp_iz = iz.exp();
            const exp_neg_iz = neg_iz.exp();
            const sum = exp_iz.add(exp_neg_iz);
            return sum.scale(0.5);
        }

        pub fn tan(self: Self) Self {
            const sin_z = self.sin();
            const cos_z = self.cos();
            return sin_z.div(cos_z);
        }

        // Hyperbolic functions
        pub fn sinh(self: Self) Self {
            // sinh(z) = (e^z - e^(-z)) / 2
            const exp_z = self.exp();
            const exp_neg_z = self.neg().exp();
            const diff = exp_z.sub(exp_neg_z);
            return diff.scale(0.5);
        }

        pub fn cosh(self: Self) Self {
            // cosh(z) = (e^z + e^(-z)) / 2
            const exp_z = self.exp();
            const exp_neg_z = self.neg().exp();
            const sum = exp_z.add(exp_neg_z);
            return sum.scale(0.5);
        }

        pub fn tanh(self: Self) Self {
            const sinh_z = self.sinh();
            const cosh_z = self.cosh();
            return sinh_z.div(cosh_z);
        }

        // Comparison
        pub fn eql(self: Self, other: Self) bool {
            return self.real == other.real and self.imag == other.imag;
        }

        pub fn approxEql(self: Self, other: Self, tolerance: T) bool {
            return @abs(self.real - other.real) < tolerance and
                @abs(self.imag - other.imag) < tolerance;
        }

        // String representation (for debugging)
        pub fn format(
            self: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            if (self.imag >= 0) {
                try writer.print("{d} + {d}i", .{ self.real, self.imag });
            } else {
                try writer.print("{d} - {d}i", .{ self.real, -self.imag });
            }
        }
    };
}

test "complex construction" {
    const testing = std.testing;
    const C = Complex(f64);

    const z = C.init(3.0, 4.0);
    try testing.expectEqual(@as(f64, 3.0), z.real);
    try testing.expectEqual(@as(f64, 4.0), z.imag);
}

test "complex addition" {
    const testing = std.testing;
    const C = Complex(f64);

    const a = C.init(1.0, 2.0);
    const b = C.init(3.0, 4.0);
    const c = a.add(b);

    try testing.expectEqual(@as(f64, 4.0), c.real);
    try testing.expectEqual(@as(f64, 6.0), c.imag);
}

test "complex subtraction" {
    const testing = std.testing;
    const C = Complex(f64);

    const a = C.init(5.0, 7.0);
    const b = C.init(2.0, 3.0);
    const c = a.sub(b);

    try testing.expectEqual(@as(f64, 3.0), c.real);
    try testing.expectEqual(@as(f64, 4.0), c.imag);
}

test "complex multiplication" {
    const testing = std.testing;
    const C = Complex(f64);

    const a = C.init(1.0, 2.0);
    const b = C.init(3.0, 4.0);
    const c = a.mul(b);

    // (1 + 2i)(3 + 4i) = 3 + 4i + 6i + 8i² = 3 + 10i - 8 = -5 + 10i
    try testing.expectApproxEqAbs(@as(f64, -5.0), c.real, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 10.0), c.imag, 0.0001);
}

test "complex division" {
    const testing = std.testing;
    const C = Complex(f64);

    const a = C.init(2.0, 4.0);
    const b = C.init(1.0, 1.0);
    const c = a.div(b);

    // (2 + 4i) / (1 + i) = (2 + 4i)(1 - i) / 2 = (2 - 2i + 4i - 4i²) / 2 = (6 + 2i) / 2 = 3 + i
    try testing.expectApproxEqAbs(@as(f64, 3.0), c.real, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 1.0), c.imag, 0.0001);
}

test "complex conjugate" {
    const testing = std.testing;
    const C = Complex(f64);

    const z = C.init(3.0, 4.0);
    const conj = z.conjugate();

    try testing.expectEqual(@as(f64, 3.0), conj.real);
    try testing.expectEqual(@as(f64, -4.0), conj.imag);
}

test "complex magnitude" {
    const testing = std.testing;
    const C = Complex(f64);

    const z = C.init(3.0, 4.0);
    const magnitude = z.abs();

    try testing.expectApproxEqAbs(@as(f64, 5.0), magnitude, 0.0001);
}

test "complex polar form" {
    const testing = std.testing;
    const C = Complex(f64);

    const pi: f64 = 3.14159265358979323846;
    const z = C.fromPolar(5.0, pi / 4.0); // r=5, θ=45°

    try testing.expectApproxEqAbs(@as(f64, 3.5355), z.real, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 3.5355), z.imag, 0.001);
}

test "complex exponential" {
    const testing = std.testing;
    const C = Complex(f64);

    // e^(iπ) = -1 (Euler's formula)
    const pi: f64 = 3.14159265358979323846;
    const z = C.init(0.0, pi);
    const result = z.exp();

    try testing.expectApproxEqAbs(@as(f64, -1.0), result.real, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0.0), result.imag, 0.001);
}

test "complex sqrt" {
    const testing = std.testing;
    const C = Complex(f64);

    const z = C.init(3.0, 4.0);
    const sq = z.sqrt();
    const verify = sq.mul(sq);

    try testing.expectApproxEqAbs(z.real, verify.real, 0.001);
    try testing.expectApproxEqAbs(z.imag, verify.imag, 0.001);
}

test "complex scale" {
    const testing = std.testing;
    const C = Complex(f64);

    const z = C.init(2.0, 3.0);
    const scaled = z.scale(2.5);

    try testing.expectApproxEqAbs(@as(f64, 5.0), scaled.real, 0.0001);
    try testing.expectApproxEqAbs(@as(f64, 7.5), scaled.imag, 0.0001);
}
