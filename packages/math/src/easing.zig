// Home Programming Language - Easing Functions
// Interpolation and easing for animations, camera transitions, etc.
// Ported from C&C Generals engine for game compatibility

const std = @import("std");

/// Easing function type
pub fn Easing(comptime T: type) type {
    return struct {
        const Self = @This();

        // ============================================
        // Linear
        // ============================================

        /// Linear interpolation (no easing)
        pub fn linear(t: T) T {
            return t;
        }

        // ============================================
        // Quadratic (power of 2)
        // ============================================

        /// Quadratic ease-in: starts slow, accelerates
        pub fn easeInQuad(t: T) T {
            return t * t;
        }

        /// Quadratic ease-out: starts fast, decelerates
        pub fn easeOutQuad(t: T) T {
            return t * (2 - t);
        }

        /// Quadratic ease-in-out: slow start and end
        pub fn easeInOutQuad(t: T) T {
            if (t < 0.5) {
                return 2 * t * t;
            }
            return -1 + (4 - 2 * t) * t;
        }

        // ============================================
        // Cubic (power of 3)
        // ============================================

        /// Cubic ease-in
        pub fn easeInCubic(t: T) T {
            return t * t * t;
        }

        /// Cubic ease-out
        pub fn easeOutCubic(t: T) T {
            const t1 = t - 1;
            return t1 * t1 * t1 + 1;
        }

        /// Cubic ease-in-out
        pub fn easeInOutCubic(t: T) T {
            if (t < 0.5) {
                return 4 * t * t * t;
            }
            return (t - 1) * (2 * t - 2) * (2 * t - 2) + 1;
        }

        // ============================================
        // Quartic (power of 4)
        // ============================================

        /// Quartic ease-in
        pub fn easeInQuart(t: T) T {
            return t * t * t * t;
        }

        /// Quartic ease-out
        pub fn easeOutQuart(t: T) T {
            const t1 = t - 1;
            return 1 - t1 * t1 * t1 * t1;
        }

        /// Quartic ease-in-out
        pub fn easeInOutQuart(t: T) T {
            if (t < 0.5) {
                return 8 * t * t * t * t;
            }
            const t1 = t - 1;
            return 1 - 8 * t1 * t1 * t1 * t1;
        }

        // ============================================
        // Quintic (power of 5)
        // ============================================

        /// Quintic ease-in
        pub fn easeInQuint(t: T) T {
            return t * t * t * t * t;
        }

        /// Quintic ease-out
        pub fn easeOutQuint(t: T) T {
            const t1 = t - 1;
            return 1 + t1 * t1 * t1 * t1 * t1;
        }

        /// Quintic ease-in-out
        pub fn easeInOutQuint(t: T) T {
            if (t < 0.5) {
                return 16 * t * t * t * t * t;
            }
            const t1 = t - 1;
            return 1 + 16 * t1 * t1 * t1 * t1 * t1;
        }

        // ============================================
        // Sinusoidal
        // ============================================

        /// Sinusoidal ease-in
        pub fn easeInSine(t: T) T {
            return 1 - @cos(t * std.math.pi / 2);
        }

        /// Sinusoidal ease-out
        pub fn easeOutSine(t: T) T {
            return @sin(t * std.math.pi / 2);
        }

        /// Sinusoidal ease-in-out
        pub fn easeInOutSine(t: T) T {
            return -(@cos(std.math.pi * t) - 1) / 2;
        }

        // ============================================
        // Exponential
        // ============================================

        /// Exponential ease-in
        pub fn easeInExpo(t: T) T {
            if (t == 0) return 0;
            return std.math.pow(T, 2, 10 * (t - 1));
        }

        /// Exponential ease-out
        pub fn easeOutExpo(t: T) T {
            if (t == 1) return 1;
            return 1 - std.math.pow(T, 2, -10 * t);
        }

        /// Exponential ease-in-out
        pub fn easeInOutExpo(t: T) T {
            if (t == 0) return 0;
            if (t == 1) return 1;
            if (t < 0.5) {
                return std.math.pow(T, 2, 20 * t - 10) / 2;
            }
            return (2 - std.math.pow(T, 2, -20 * t + 10)) / 2;
        }

        // ============================================
        // Circular
        // ============================================

        /// Circular ease-in
        pub fn easeInCirc(t: T) T {
            return 1 - @sqrt(1 - t * t);
        }

        /// Circular ease-out
        pub fn easeOutCirc(t: T) T {
            const t1 = t - 1;
            return @sqrt(1 - t1 * t1);
        }

        /// Circular ease-in-out
        pub fn easeInOutCirc(t: T) T {
            if (t < 0.5) {
                return (1 - @sqrt(1 - 4 * t * t)) / 2;
            }
            return (@sqrt(1 - std.math.pow(T, -2 * t + 2, 2)) + 1) / 2;
        }

        // ============================================
        // Elastic
        // ============================================

        /// Elastic ease-in (spring effect)
        pub fn easeInElastic(t: T) T {
            if (t == 0) return 0;
            if (t == 1) return 1;
            const c4 = (2.0 * std.math.pi) / 3.0;
            return -std.math.pow(T, 2, 10 * t - 10) * @sin((t * 10 - 10.75) * c4);
        }

        /// Elastic ease-out
        pub fn easeOutElastic(t: T) T {
            if (t == 0) return 0;
            if (t == 1) return 1;
            const c4 = (2.0 * std.math.pi) / 3.0;
            return std.math.pow(T, 2, -10 * t) * @sin((t * 10 - 0.75) * c4) + 1;
        }

        /// Elastic ease-in-out
        pub fn easeInOutElastic(t: T) T {
            if (t == 0) return 0;
            if (t == 1) return 1;
            const c5 = (2 * std.math.pi) / 4.5;
            if (t < 0.5) {
                return -(std.math.pow(T, 2, 20 * t - 10) * @sin((20 * t - 11.125) * c5)) / 2;
            }
            return (std.math.pow(T, 2, -20 * t + 10) * @sin((20 * t - 11.125) * c5)) / 2 + 1;
        }

        // ============================================
        // Back (overshoots target then returns)
        // ============================================

        /// Back ease-in (slight reverse before acceleration)
        pub fn easeInBack(t: T) T {
            const c1: T = 1.70158;
            const c3: T = c1 + 1;
            return c3 * t * t * t - c1 * t * t;
        }

        /// Back ease-out (overshoots then returns)
        pub fn easeOutBack(t: T) T {
            const c1: T = 1.70158;
            const c3: T = c1 + 1;
            const t1 = t - 1;
            return 1 + c3 * t1 * t1 * t1 + c1 * t1 * t1;
        }

        /// Back ease-in-out
        pub fn easeInOutBack(t: T) T {
            const c1: T = 1.70158;
            const c2: T = c1 * 1.525;
            if (t < 0.5) {
                return (std.math.pow(T, 2 * t, 2) * ((c2 + 1) * 2 * t - c2)) / 2;
            }
            return (std.math.pow(T, 2 * t - 2, 2) * ((c2 + 1) * (t * 2 - 2) + c2) + 2) / 2;
        }

        // ============================================
        // Bounce
        // ============================================

        /// Bounce ease-out (bouncing ball effect)
        pub fn easeOutBounce(t: T) T {
            const n1: T = 7.5625;
            const d1: T = 2.75;

            if (t < 1 / d1) {
                return n1 * t * t;
            } else if (t < 2 / d1) {
                const t1 = t - 1.5 / d1;
                return n1 * t1 * t1 + 0.75;
            } else if (t < 2.5 / d1) {
                const t1 = t - 2.25 / d1;
                return n1 * t1 * t1 + 0.9375;
            } else {
                const t1 = t - 2.625 / d1;
                return n1 * t1 * t1 + 0.984375;
            }
        }

        /// Bounce ease-in
        pub fn easeInBounce(t: T) T {
            return 1 - easeOutBounce(1 - t);
        }

        /// Bounce ease-in-out
        pub fn easeInOutBounce(t: T) T {
            if (t < 0.5) {
                return (1 - easeOutBounce(1 - 2 * t)) / 2;
            }
            return (1 + easeOutBounce(2 * t - 1)) / 2;
        }

        // ============================================
        // Parabolic (C&C Generals specific)
        // ============================================

        /// Parabolic ease for camera transitions (matches original game)
        /// Creates smooth camera movement with gentle start and end
        pub fn parabolicEase(t: T) T {
            // Hermite-style parabolic: 3t² - 2t³
            return t * t * (3 - 2 * t);
        }

        /// Parabolic ease with configurable steepness
        pub fn parabolicEaseCustom(t: T, steepness: T) T {
            const t2 = t * t;
            const t3 = t2 * t;
            return (2 + steepness) * t3 - (3 + steepness) * t2 + steepness * t + (1 - steepness) * t2;
        }

        /// Camera zoom ease (smoother for zoom operations)
        pub fn cameraZoomEase(t: T) T {
            // Slower at extremes for precise zoom control
            return t * t * t * (t * (t * 6 - 15) + 10);
        }

        /// Camera rotation ease (minimal overshoot)
        pub fn cameraRotationEase(t: T) T {
            // Quintic for very smooth rotation
            const t3 = t * t * t;
            const t4 = t3 * t;
            const t5 = t4 * t;
            return 6 * t5 - 15 * t4 + 10 * t3;
        }

        // ============================================
        // Smoothstep variants
        // ============================================

        /// Smoothstep (standard Hermite interpolation)
        pub fn smoothstep(t: T) T {
            return t * t * (3 - 2 * t);
        }

        /// Smootherstep (Ken Perlin's improved version)
        pub fn smootherstep(t: T) T {
            return t * t * t * (t * (t * 6 - 15) + 10);
        }

        /// Inverse smoothstep (for reversing smoothstep animation)
        pub fn inverseSmoothstep(t: T) T {
            return 0.5 - @sin(std.math.asin(1 - 2 * t) / 3);
        }

        // ============================================
        // Utility functions
        // ============================================

        /// Clamp value between 0 and 1
        pub fn clamp01(t: T) T {
            if (t < 0) return 0;
            if (t > 1) return 1;
            return t;
        }

        /// Map value from one range to another
        pub fn map(value: T, in_min: T, in_max: T, out_min: T, out_max: T) T {
            return (value - in_min) * (out_max - out_min) / (in_max - in_min) + out_min;
        }

        /// Ping-pong between 0 and 1
        pub fn pingPong(t: T) T {
            const wrapped = @mod(t, 2.0);
            if (wrapped > 1.0) {
                return 2.0 - wrapped;
            }
            return wrapped;
        }
    };
}

// Type aliases
pub const Easingf = Easing(f32);
pub const Easingd = Easing(f64);

/// Function pointer type for easing functions
pub fn EasingFn(comptime T: type) type {
    return *const fn (T) T;
}

/// Named easing function enum for serialization/configuration
pub const EasingType = enum {
    linear,
    ease_in_quad,
    ease_out_quad,
    ease_in_out_quad,
    ease_in_cubic,
    ease_out_cubic,
    ease_in_out_cubic,
    ease_in_quart,
    ease_out_quart,
    ease_in_out_quart,
    ease_in_quint,
    ease_out_quint,
    ease_in_out_quint,
    ease_in_sine,
    ease_out_sine,
    ease_in_out_sine,
    ease_in_expo,
    ease_out_expo,
    ease_in_out_expo,
    ease_in_circ,
    ease_out_circ,
    ease_in_out_circ,
    ease_in_elastic,
    ease_out_elastic,
    ease_in_out_elastic,
    ease_in_back,
    ease_out_back,
    ease_in_out_back,
    ease_in_bounce,
    ease_out_bounce,
    ease_in_out_bounce,
    parabolic,
    smoothstep,
    smootherstep,
};

/// Get easing function by type
pub fn getEasingFn(comptime T: type, easing_type: EasingType) EasingFn(T) {
    const E = Easing(T);
    return switch (easing_type) {
        .linear => E.linear,
        .ease_in_quad => E.easeInQuad,
        .ease_out_quad => E.easeOutQuad,
        .ease_in_out_quad => E.easeInOutQuad,
        .ease_in_cubic => E.easeInCubic,
        .ease_out_cubic => E.easeOutCubic,
        .ease_in_out_cubic => E.easeInOutCubic,
        .ease_in_quart => E.easeInQuart,
        .ease_out_quart => E.easeOutQuart,
        .ease_in_out_quart => E.easeInOutQuart,
        .ease_in_quint => E.easeInQuint,
        .ease_out_quint => E.easeOutQuint,
        .ease_in_out_quint => E.easeInOutQuint,
        .ease_in_sine => E.easeInSine,
        .ease_out_sine => E.easeOutSine,
        .ease_in_out_sine => E.easeInOutSine,
        .ease_in_expo => E.easeInExpo,
        .ease_out_expo => E.easeOutExpo,
        .ease_in_out_expo => E.easeInOutExpo,
        .ease_in_circ => E.easeInCirc,
        .ease_out_circ => E.easeOutCirc,
        .ease_in_out_circ => E.easeInOutCirc,
        .ease_in_elastic => E.easeInElastic,
        .ease_out_elastic => E.easeOutElastic,
        .ease_in_out_elastic => E.easeInOutElastic,
        .ease_in_back => E.easeInBack,
        .ease_out_back => E.easeOutBack,
        .ease_in_out_back => E.easeInOutBack,
        .ease_in_bounce => E.easeInBounce,
        .ease_out_bounce => E.easeOutBounce,
        .ease_in_out_bounce => E.easeInOutBounce,
        .parabolic => E.parabolicEase,
        .smoothstep => E.smoothstep,
        .smootherstep => E.smootherstep,
    };
}

// ============================================
// Tests
// ============================================

test "linear easing" {
    const testing = std.testing;
    const E = Easing(f32);

    try testing.expectApproxEqAbs(@as(f32, 0.0), E.linear(0.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), E.linear(0.5), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), E.linear(1.0), 0.0001);
}

test "quadratic easing" {
    const testing = std.testing;
    const E = Easing(f32);

    // Ease-in should be slower at start
    try testing.expect(E.easeInQuad(0.5) < 0.5);

    // Ease-out should be faster at start
    try testing.expect(E.easeOutQuad(0.5) > 0.5);

    // All should hit 0 and 1 at endpoints
    try testing.expectApproxEqAbs(@as(f32, 0.0), E.easeInQuad(0.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), E.easeInQuad(1.0), 0.0001);
}

test "parabolic ease" {
    const testing = std.testing;
    const E = Easing(f32);

    // Endpoints
    try testing.expectApproxEqAbs(@as(f32, 0.0), E.parabolicEase(0.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), E.parabolicEase(1.0), 0.0001);

    // Midpoint should be 0.5 for symmetric ease
    try testing.expectApproxEqAbs(@as(f32, 0.5), E.parabolicEase(0.5), 0.0001);
}

test "smoothstep" {
    const testing = std.testing;
    const E = Easing(f32);

    // Smoothstep should equal parabolic ease (same formula)
    try testing.expectApproxEqAbs(E.parabolicEase(0.25), E.smoothstep(0.25), 0.0001);
    try testing.expectApproxEqAbs(E.parabolicEase(0.75), E.smoothstep(0.75), 0.0001);
}

test "bounce easing" {
    const testing = std.testing;
    const E = Easing(f32);

    // Endpoints
    try testing.expectApproxEqAbs(@as(f32, 0.0), E.easeOutBounce(0.0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), E.easeOutBounce(1.0), 0.0001);
}

test "easing function lookup" {
    const testing = std.testing;

    const fn_ptr = getEasingFn(f32, .parabolic);
    try testing.expectApproxEqAbs(@as(f32, 0.5), fn_ptr(0.5), 0.0001);
}
