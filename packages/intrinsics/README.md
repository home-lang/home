# Hardware Intrinsics

Comprehensive hardware intrinsics and low-level operations for the Home Programming Language. This package provides safe, efficient access to CPU features including SIMD, atomic operations, bit manipulation, cryptographic acceleration, and system-level instructions.

## Features

### SIMD Operations (`simd.zig`)
- Vector types and operations (add, sub, mul, div)
- Vector reductions (sum, min, max)
- Horizontal operations
- Fused multiply-add (FMA)
- Shuffle and permute operations
- Common vector sizes: Vec2f32, Vec4f32, Vec8f32, Vec4i32, etc.

### Bit Manipulation (`bits.zig`)
- Count leading/trailing zeros (CLZ, CTZ)
- Population count (POPCNT)
- Byte swap and bit reverse
- Find first/last set bit
- Rotate operations
- Bit field extract/insert
- Power-of-two detection and rounding

### BMI Instructions (`bmi.zig`)
BMI1:
- Extract lowest set bit (BLSI)
- Clear lowest set bit (BLSR)
- AND NOT (ANDN)
- Bit field extract (BEXTR)
- Trailing zero count (TZCNT)

BMI2:
- Parallel bits deposit (PDEP)
- Parallel bits extract (PEXT)
- Zero high bits (BZHI)
- Unsigned multiply (MULX)
- Shift operations without flags (SHLX, SHRX, SARX, RORX)

### Atomic Operations (`atomic.zig`)
- Atomic load/store with memory ordering
- Compare-and-swap (weak and strong)
- Fetch-and-add/sub/and/or/xor
- Fetch-and-min/max
- Memory fences and barriers
- Spin loop hints

### Floating-Point Operations (`float.zig`)
- FP classification (normal, subnormal, zero, infinity, NaN)
- Rounding modes (nearest, zero, positive, negative)
- Fused multiply-add variants (FMA, FMS, FNMA, FNMS)
- Reciprocal and reciprocal square root
- frexp/ldexp (mantissa/exponent manipulation)
- modf (integer/fractional parts)
- IEEE 754 remainder operations
- nextAfter (next representable value)

### Cryptographic Acceleration (`crypto.zig`)
- AES-NI availability detection
- SHA extensions detection
- CRC32 with hardware acceleration
- CRC32 software fallback
- Carry-less multiplication (PCLMULQDQ)
- Random number generation (RDRAND, RDSEED)

Note: Hardware-accelerated crypto operations require platform-specific inline assembly and are marked as compile errors for now. Software fallbacks are provided where applicable (e.g., CRC32).

### CPU Features (`cpu.zig`)
- Runtime CPU feature detection
- x86/x86_64: SSE, SSE2, SSE3, SSSE3, SSE4.1/4.2, AVX, AVX2, AVX512, FMA, AES, PCLMUL, POPCNT, BMI1/2, LZCNT
- ARM/AArch64: NEON, SVE, CRC32, Crypto, FP16, DotProd
- Cache line size detection
- Page size detection

### Memory Barriers (`memory_barriers.zig`)
- Full memory barrier
- Acquire/release barriers
- Load/store barriers
- Compiler barriers
- Custom fence with ordering

### Prefetch Operations (`prefetch.zig`)
- Prefetch for read/write
- Prefetch with locality hints (none, low, medium, high)
- Instruction cache prefetch
- Streaming (non-temporal) prefetch
- Prefetch for exclusive access
- Range prefetch with stride
- Next cache line prefetch

### System Instructions (`system.zig`)
- Debug trap and breakpoint
- Return address and frame address
- Compiler and memory barriers
- Pause/yield for spin loops
- Time stamp counter (RDTSC, RDTSCP)
- Cache line flush/writeback (CLFLUSH, CLFLUSHOPT, CLWB)
- TLB invalidation (INVLPG)
- Wait for interrupt/event (WFI, WFE, SEV)
- Instruction/data synchronization barriers (ISB, DSB, DMB)
- CPUID and feature detection (x86)
- System register access (ARM)
- Model-specific register access (x86 MSR)

## Usage

```zig
const intrinsics = @import("intrinsics");

// SIMD operations
const vec_a = intrinsics.simd.Vec4f32{ 1.0, 2.0, 3.0, 4.0 };
const vec_b = intrinsics.simd.Vec4f32{ 5.0, 6.0, 7.0, 8.0 };
const result = intrinsics.simd.vec4Add(vec_a, vec_b);

// Bit manipulation
const leading_zeros = intrinsics.clz(u32, 0x0000FFFF); // 16
const pop_count = intrinsics.popcount(u32, 0xFF); // 8

// BMI operations
const lowest_bit = intrinsics.bmi.BMI1.extractLowestSetBit(u32, 0b1010); // 0b0010

// Atomic operations
var atomic = intrinsics.AtomicValue(u32).init(0);
atomic.store(42, .seq_cst);
const old = atomic.fetchAdd(1, .seq_cst);

// Floating-point
const class = intrinsics.float.classify(f32, value);
const rounded = intrinsics.float.roundMode(f32, 3.7, .toward_zero); // 3.0

// CRC32
const crc = intrinsics.crypto.CRC32.crc32("Hello, World!");

// CPU features
const features = intrinsics.cpu.CpuFeatures.detect();
if (features.hasSimd()) {
    // Use SIMD optimizations
}

// Prefetch for performance
intrinsics.prefetch.prefetchRead(u32, &data[i], .high);

// System operations
const tsc = intrinsics.system.readTSC();
intrinsics.system.pause();
```

## Platform Support

- **x86/x86_64**: Full support for all features
- **ARM/AArch64**: Full support for ARM-specific features
- **Other architectures**: Software fallbacks where possible

## Testing

All intrinsics are thoroughly tested. Run tests with:

```bash
zig build test
```

Current test coverage: 38 tests passing

## Performance

All intrinsics are designed for zero-overhead abstraction:
- Inline functions where possible
- Compile-time feature detection
- No runtime overhead for availability checks
- Direct mapping to hardware instructions

## Safety

- Type-safe wrappers around raw assembly
- Compile-time architecture checks
- Runtime availability detection where needed
- Clear documentation of prerequisites and behavior

## Integration

This package is integrated into the Home Programming Language standard library and can be used directly:

```zig
const std = @import("std");
const intrinsics = @import("intrinsics");

pub fn optimizedLoop(data: []f32) f32 {
    const features = intrinsics.cpu.CpuFeatures.detect();

    if (features.avx2) {
        return simdSum(data);
    } else {
        return scalarSum(data);
    }
}
```
