// Home Code Generation Package
// Exports all codegen modules

pub const native_codegen = @import("native_codegen.zig");
pub const kernel_codegen = @import("kernel_codegen.zig");
pub const home_kernel_codegen = @import("home_kernel_codegen.zig");
pub const llvm_codegen = @import("llvm_codegen.zig");
pub const wasm = @import("wasm.zig");
pub const arm64 = @import("arm64.zig");
pub const x64 = @import("x64.zig");
pub const elf = @import("elf.zig");

// Re-export commonly used types
pub const NativeCodegen = native_codegen.NativeCodegen;
pub const HomeKernelCodegen = home_kernel_codegen.HomeKernelCodegen;
pub const LLVMCodegen = llvm_codegen.LLVMCodegen;
pub const WasmCodegen = wasm.WasmCodegen;
pub const CodegenError = native_codegen.CodegenError;
