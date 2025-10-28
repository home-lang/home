// Home Programming Language - C Math Library FFI Example
// Demonstrates mathematical function bindings

const std = @import("std");
const ffi = @import("ffi");

// ============================================================================
// C Math Library Bindings
// ============================================================================

pub const CMath = struct {
    // Basic functions
    pub extern "c" fn sqrt(x: ffi.c_double) ffi.c_double;
    pub extern "c" fn pow(x: ffi.c_double, y: ffi.c_double) ffi.c_double;
    pub extern "c" fn exp(x: ffi.c_double) ffi.c_double;
    pub extern "c" fn log(x: ffi.c_double) ffi.c_double;
    pub extern "c" fn log10(x: ffi.c_double) ffi.c_double;

    // Trigonometric functions
    pub extern "c" fn sin(x: ffi.c_double) ffi.c_double;
    pub extern "c" fn cos(x: ffi.c_double) ffi.c_double;
    pub extern "c" fn tan(x: ffi.c_double) ffi.c_double;
    pub extern "c" fn asin(x: ffi.c_double) ffi.c_double;
    pub extern "c" fn acos(x: ffi.c_double) ffi.c_double;
    pub extern "c" fn atan(x: ffi.c_double) ffi.c_double;
    pub extern "c" fn atan2(y: ffi.c_double, x: ffi.c_double) ffi.c_double;

    // Hyperbolic functions
    pub extern "c" fn sinh(x: ffi.c_double) ffi.c_double;
    pub extern "c" fn cosh(x: ffi.c_double) ffi.c_double;
    pub extern "c" fn tanh(x: ffi.c_double) ffi.c_double;

    // Rounding and remainder functions
    pub extern "c" fn ceil(x: ffi.c_double) ffi.c_double;
    pub extern "c" fn floor(x: ffi.c_double) ffi.c_double;
    pub extern "c" fn round(x: ffi.c_double) ffi.c_double;
    pub extern "c" fn fmod(x: ffi.c_double, y: ffi.c_double) ffi.c_double;
    pub extern "c" fn fabs(x: ffi.c_double) ffi.c_double;

    // Other functions
    pub extern "c" fn hypot(x: ffi.c_double, y: ffi.c_double) ffi.c_double;
};

// ============================================================================
// Home-style Math Wrapper
// ============================================================================

pub const Math = struct {
    pub const PI = 3.14159265358979323846;
    pub const E = 2.71828182845904523536;

    pub fn sqrt(x: f64) f64 {
        return CMath.sqrt(x);
    }

    pub fn pow(x: f64, y: f64) f64 {
        return CMath.pow(x, y);
    }

    pub fn exp(x: f64) f64 {
        return CMath.exp(x);
    }

    pub fn log(x: f64) f64 {
        return CMath.log(x);
    }

    pub fn log10(x: f64) f64 {
        return CMath.log10(x);
    }

    pub fn sin(x: f64) f64 {
        return CMath.sin(x);
    }

    pub fn cos(x: f64) f64 {
        return CMath.cos(x);
    }

    pub fn tan(x: f64) f64 {
        return CMath.tan(x);
    }

    pub fn asin(x: f64) f64 {
        return CMath.asin(x);
    }

    pub fn acos(x: f64) f64 {
        return CMath.acos(x);
    }

    pub fn atan(x: f64) f64 {
        return CMath.atan(x);
    }

    pub fn atan2(y: f64, x: f64) f64 {
        return CMath.atan2(y, x);
    }

    pub fn sinh(x: f64) f64 {
        return CMath.sinh(x);
    }

    pub fn cosh(x: f64) f64 {
        return CMath.cosh(x);
    }

    pub fn tanh(x: f64) f64 {
        return CMath.tanh(x);
    }

    pub fn ceil(x: f64) f64 {
        return CMath.ceil(x);
    }

    pub fn floor(x: f64) f64 {
        return CMath.floor(x);
    }

    pub fn round(x: f64) f64 {
        return CMath.round(x);
    }

    pub fn abs(x: f64) f64 {
        return CMath.fabs(x);
    }

    pub fn mod(x: f64, y: f64) f64 {
        return CMath.fmod(x, y);
    }

    pub fn hypot(x: f64, y: f64) f64 {
        return CMath.hypot(x, y);
    }

    // Utility functions
    pub fn degreesToRadians(degrees: f64) f64 {
        return degrees * PI / 180.0;
    }

    pub fn radiansToDegrees(radians: f64) f64 {
        return radians * 180.0 / PI;
    }

    pub fn distance(x1: f64, y1: f64, x2: f64, y2: f64) f64 {
        const dx = x2 - x1;
        const dy = y2 - y1;
        return hypot(dx, dy);
    }

    pub fn angle(x1: f64, y1: f64, x2: f64, y2: f64) f64 {
        const dx = x2 - x1;
        const dy = y2 - y1;
        return atan2(dy, dx);
    }
};

// ============================================================================
// Example Usage
// ============================================================================

pub fn main() !void {
    std.debug.print("=== C Math Library FFI Example ===\n\n", .{});

    // Basic math operations
    std.debug.print("Basic Operations:\n", .{});
    std.debug.print("  sqrt(16) = {d:.6}\n", .{Math.sqrt(16.0)});
    std.debug.print("  pow(2, 10) = {d:.6}\n", .{Math.pow(2.0, 10.0)});
    std.debug.print("  exp(1) = {d:.6}\n", .{Math.exp(1.0)});
    std.debug.print("  log(e) = {d:.6}\n", .{Math.log(Math.E)});
    std.debug.print("  log10(100) = {d:.6}\n", .{Math.log10(100.0)});
    std.debug.print("\n", .{});

    // Trigonometric functions
    std.debug.print("Trigonometry:\n", .{});
    const angle = Math.degreesToRadians(45.0);
    std.debug.print("  sin(45°) = {d:.6}\n", .{Math.sin(angle)});
    std.debug.print("  cos(45°) = {d:.6}\n", .{Math.cos(angle)});
    std.debug.print("  tan(45°) = {d:.6}\n", .{Math.tan(angle)});
    std.debug.print("\n", .{});

    // Inverse trigonometric functions
    std.debug.print("Inverse Trigonometry:\n", .{});
    std.debug.print("  asin(0.5) = {d:.6} rad = {d:.2}°\n", .{
        Math.asin(0.5),
        Math.radiansToDegrees(Math.asin(0.5)),
    });
    std.debug.print("  acos(0.5) = {d:.6} rad = {d:.2}°\n", .{
        Math.acos(0.5),
        Math.radiansToDegrees(Math.acos(0.5)),
    });
    std.debug.print("  atan(1.0) = {d:.6} rad = {d:.2}°\n", .{
        Math.atan(1.0),
        Math.radiansToDegrees(Math.atan(1.0)),
    });
    std.debug.print("\n", .{});

    // Hyperbolic functions
    std.debug.print("Hyperbolic Functions:\n", .{});
    std.debug.print("  sinh(1) = {d:.6}\n", .{Math.sinh(1.0)});
    std.debug.print("  cosh(1) = {d:.6}\n", .{Math.cosh(1.0)});
    std.debug.print("  tanh(1) = {d:.6}\n", .{Math.tanh(1.0)});
    std.debug.print("\n", .{});

    // Rounding functions
    std.debug.print("Rounding:\n", .{});
    std.debug.print("  ceil(3.14) = {d:.6}\n", .{Math.ceil(3.14)});
    std.debug.print("  floor(3.14) = {d:.6}\n", .{Math.floor(3.14)});
    std.debug.print("  round(3.14) = {d:.6}\n", .{Math.round(3.14)});
    std.debug.print("  round(3.87) = {d:.6}\n", .{Math.round(3.87)});
    std.debug.print("\n", .{});

    // Practical examples
    std.debug.print("Practical Examples:\n", .{});

    // Distance between two points
    const p1_x = 0.0;
    const p1_y = 0.0;
    const p2_x = 3.0;
    const p2_y = 4.0;
    const dist = Math.distance(p1_x, p1_y, p2_x, p2_y);
    std.debug.print("  Distance between ({d}, {d}) and ({d}, {d}) = {d:.6}\n", .{
        p1_x, p1_y, p2_x, p2_y, dist,
    });

    // Angle between two points
    const ang = Math.angle(p1_x, p1_y, p2_x, p2_y);
    std.debug.print("  Angle = {d:.6} rad = {d:.2}°\n", .{
        ang,
        Math.radiansToDegrees(ang),
    });

    // Pythagorean theorem verification
    const a = 3.0;
    const b = 4.0;
    const c = Math.hypot(a, b);
    std.debug.print("  Pythagorean: {d}² + {d}² = {d}² (c = {d:.6})\n", .{
        a, b, c, c,
    });

    std.debug.print("\n✓ FFI Math Example Complete!\n", .{});
}
