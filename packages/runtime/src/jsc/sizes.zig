// Copied verbatim from bun/src/jsc/sizes.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.

//! This namespace contains JSC C++ type sizes/alignments exported from a code
//! generator. Do not rely on any of these values in new code. If possible,
//! rewrite old ones to use another approach.
//!
//! It is not reliable to interpret C++ classes as raw bytes, since the
//! memory layout is not guaranteed by the compiler.
pub const Bun_FFI_PointerOffsetToArgumentsList = 6;
pub const Bun_FFI_PointerOffsetToTypedArrayVector = 16;
