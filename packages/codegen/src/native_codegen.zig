const std = @import("std");
const Io = std.Io;
const ast = @import("ast");
pub const x64 = @import("x64.zig");
const elf = @import("elf.zig");
const macho = @import("macho.zig");
const builtin = @import("builtin");
const type_checker_mod = @import("type_checker.zig");
pub const TypeChecker = type_checker_mod.TypeChecker;
const type_integration_mod = @import("type_integration.zig");
pub const TypeIntegration = type_integration_mod.TypeIntegration;
const move_checker_mod = @import("move_checker.zig");
pub const MoveChecker = move_checker_mod.MoveChecker;
const borrow_checker_mod = @import("borrow_checker.zig");
pub const BorrowChecker = borrow_checker_mod.BorrowChecker;
const comptime_mod = @import("comptime");
const ComptimeValueStore = comptime_mod.integration.ComptimeValueStore;
const ComptimeValue = comptime_mod.ComptimeValue;
const type_registry_mod = @import("type_registry.zig");
pub const TypeRegistry = type_registry_mod.TypeRegistry;
const checked_cast = @import("checked_cast.zig");
const safeIntCast = checked_cast.safeIntCast;

/// Error set for code generation operations.
///
/// These errors can occur during the compilation phase when converting
/// AST nodes into native machine code.
pub const CodegenError = error{
    /// Feature not yet implemented in codegen
    UnsupportedFeature,
    /// Code generation failed for unspecified reason
    CodegenFailed,
    /// Exceeded maximum number of local variables (MAX_LOCALS)
    TooManyVariables,
    /// Referenced an undefined variable
    UndefinedVariable,
    /// Macro was not expanded before codegen
    UnexpandedMacro,
    /// Failed to import module
    ImportFailed,
    /// Referenced an unknown struct type in pattern
    UnknownStructType,
    /// Referenced an unknown field in struct pattern
    UnknownField,
    /// Break statement used outside of a loop
    BreakOutsideLoop,
    /// Continue statement used outside of a loop
    ContinueOutsideLoop,
    /// Label not found for labeled break/continue
    LabelNotFound,
    /// Stack offset calculation overflowed i32 bounds
    StackOffsetOverflow,
    /// Constant shift count outside the 0..63 range accepted by shl/shr/sar imm8
    ShiftCountOutOfRange,
    /// Narrowing @intCast would truncate — reported when constant folding proves the value is out of range
    NarrowingCastOutOfRange,
    /// SIB index field rejected rsp as the index register
    InvalidSibIndex,
} || std.mem.Allocator.Error || std.Io.File.OpenError || std.Io.File.ReadStreamingError;

/// Maximum number of local variables per function.
///
/// This limit is based on typical x64 register allocation and stack frame
/// constraints. Each local variable occupies stack space indexed by an 8-bit
/// offset, allowing for efficient encoding in x64 instructions.
const MAX_LOCALS = 256;

// Stack overflow protection: we do NOT emit an explicit guard-page check
// in each function prologue. Instead, the codegen is structured so every
// stack allocation goes through a single `push` (touching the next 8 bytes
// immediately). That means runaway recursion will hit the OS-provided
// guard page on the very next `push`, producing SIGBUS/SIGSEGV rather
// than silently walking past the stack end.
//
// Downside: programs see exit 138/139 with no custom message. Upside:
// zero-overhead detection on every non-leaf call. The only risk is a
// codegen path that grows the frame via `sub rsp, N` for N ≥ 16 KiB
// without an incremental touch — today the only `sub rsp, N` in the
// compiler is a fixed 20-byte scratch buffer in `print`, which is
// nowhere near the guard-page distance.

/// Start address for runtime heap memory.
///
/// In a real implementation, this would be determined by the OS loader.
/// The heap pointer metadata is stored at HEAP_START - 8.
const HEAP_START: usize = 0x10000000; // Start of heap memory

/// Total heap size available for runtime allocation.
///
/// Uses a simple bump allocator for now. A production implementation
/// would use a proper allocator with deallocation support.
const HEAP_SIZE: usize = 1024 * 1024; // 1MB heap

/// Memory layout information for a struct type.
///
/// Stores the field offsets and sizes needed for struct field access
/// code generation. This includes padding for alignment requirements.
pub const StructLayout = struct {
    /// Struct type name
    name: []const u8,
    /// Field layout information (ordered by declaration)
    fields: []const FieldInfo,
    /// Total size of the struct in bytes (including padding)
    total_size: usize,
};

/// Layout information for a single struct field.
///
/// Contains the offset and size needed to generate field access code.
pub const FieldInfo = struct {
    /// Field name
    name: []const u8,
    /// Byte offset from struct base pointer
    offset: usize,
    /// Size of field in bytes
    size: usize,
    /// Type name of the field (for nested member access)
    type_name: []const u8 = "",
};

/// Enum variant information.
pub const EnumVariantInfo = struct {
    /// Variant name
    name: []const u8,
    /// Optional data type (null for unit variants like None)
    data_type: ?[]const u8,
};

/// Enum layout information.
///
/// Maps enum variant names to their integer values (indices) and data types.
pub const EnumLayout = struct {
    /// Enum type name
    name: []const u8,
    /// Variant information (ordered by declaration)
    variants: []const EnumVariantInfo,
};

/// Loop context for break/continue statements
///
/// Tracks loop entry and exit points for control flow jumps
pub const LoopContext = struct {
    /// Position of loop start (condition test, used by while-continue)
    loop_start: usize,
    /// Position that `continue` should jump to. For while loops this
    /// equals loop_start (re-test condition). For for loops it points
    /// to the iterator increment so the counter advances before the
    /// next iteration. Null means "use loop_start".
    continue_target: ?usize = null,
    /// List of positions that need patching for break (jumps to end)
    break_fixups: std.ArrayList(usize),
    /// Positions emitted by continue that need patching to the increment
    continue_fixups: std.ArrayList(usize),
    /// Optional label for labeled break/continue
    label: ?[]const u8,
};

/// Local variable information.
///
/// Stores both stack location and type information for local variables.
pub const LocalInfo = struct {
    /// Stack offset from RBP (1-based index)
    offset: u32,
    /// Type name (e.g., "i32", "[i32]", "Point")
    type_name: []const u8,
    /// Size in bytes
    size: usize,
};

/// Function parameter information (for default values support)
pub const FunctionParamInfo = struct {
    /// Parameter name
    name: []const u8,
    /// Parameter type
    type_name: []const u8,
    /// Default value expression (null if no default)
    default_value: ?*ast.Expr,
};

/// Function info for code generation
pub const FunctionInfo = struct {
    /// Code position
    position: usize,
    /// Parameters with default value info
    params: []FunctionParamInfo,
    /// Number of required parameters (without defaults)
    required_params: usize,
};

/// String literal fixup information
/// Tracks where in the code we need to patch string addresses
pub const StringFixup = struct {
    /// Position in code where the displacement was written
    code_pos: usize,
    /// Offset of the string in the data section
    data_offset: usize,
};

/// Simple register allocator for optimizing register usage
/// Tracks which registers are currently in use and allocates them efficiently
pub const RegisterAllocator = struct {
    /// Bitmask of available general-purpose registers
    /// Bits correspond to: rbx(0), r12(1), r13(2), r14(3), r15(4)
    /// We don't allocate rax, rcx, rdx (used for specific operations)
    /// or rdi, rsi, r8, r9, r10, r11 (used for function calls)
    available: u8,

    /// Initialize with all callee-saved registers available
    pub fn init() RegisterAllocator {
        return .{
            .available = 0b11111, // rbx, r12, r13, r14, r15 available
        };
    }

    /// Allocate a register, returns null if none available
    pub fn alloc(self: *RegisterAllocator) ?x64.Register {
        if (self.available & 0b00001 != 0) {
            self.available &= ~@as(u8, 0b00001);
            return .rbx;
        }
        if (self.available & 0b00010 != 0) {
            self.available &= ~@as(u8, 0b00010);
            return .r12;
        }
        if (self.available & 0b00100 != 0) {
            self.available &= ~@as(u8, 0b00100);
            return .r13;
        }
        if (self.available & 0b01000 != 0) {
            self.available &= ~@as(u8, 0b01000);
            return .r14;
        }
        if (self.available & 0b10000 != 0) {
            self.available &= ~@as(u8, 0b10000);
            return .r15;
        }
        return null; // No registers available
    }

    /// Free a register, making it available for reuse
    pub fn free(self: *RegisterAllocator, reg: x64.Register) void {
        switch (reg) {
            .rbx => self.available |= 0b00001,
            .r12 => self.available |= 0b00010,
            .r13 => self.available |= 0b00100,
            .r14 => self.available |= 0b01000,
            .r15 => self.available |= 0b10000,
            else => {}, // Other registers aren't managed
        }
    }

    /// Check if a specific register is available
    pub fn isAvailable(self: *RegisterAllocator, reg: x64.Register) bool {
        return switch (reg) {
            .rbx => (self.available & 0b00001) != 0,
            .r12 => (self.available & 0b00010) != 0,
            .r13 => (self.available & 0b00100) != 0,
            .r14 => (self.available & 0b01000) != 0,
            .r15 => (self.available & 0b10000) != 0,
            else => false,
        };
    }
};

/// CPU feature flags for SIMD optimization
pub const CpuFeatures = struct {
    has_sse: bool = true,    // All x86-64 CPUs have SSE/SSE2
    has_sse3: bool = false,
    has_ssse3: bool = false,
    has_sse41: bool = false,
    has_sse42: bool = false,
    has_avx: bool = false,
    has_avx2: bool = false,
    has_fma: bool = false,

    /// Detect CPU features using CPUID instruction
    /// This would be called at runtime to determine what instructions are available
    pub fn detect() CpuFeatures {
        // For now, assume modern CPU with AVX2 + FMA
        // In production, would use CPUID instruction to detect:
        // - CPUID EAX=1: ECX bit 0 = SSE3, bit 9 = SSSE3, bit 19 = SSE4.1, bit 20 = SSE4.2
        // - CPUID EAX=1: ECX bit 28 = AVX, bit 12 = FMA
        // - CPUID EAX=7,ECX=0: EBX bit 5 = AVX2
        return .{
            .has_sse = true,
            .has_sse3 = true,
            .has_ssse3 = true,
            .has_sse41 = true,
            .has_sse42 = true,
            .has_avx = true,    // Conservatively assume true
            .has_avx2 = true,   // Conservatively assume true
            .has_fma = true,    // Conservatively assume true
        };
    }

    /// Get best vector width for integer operations
    pub fn getBestIntWidth(self: CpuFeatures) usize {
        if (self.has_avx2) return 8;  // 256-bit = 8x i32
        if (self.has_sse) return 4;   // 128-bit = 4x i32
        return 1; // Scalar fallback
    }

    /// Get best vector width for float operations
    pub fn getBestFloatWidth(self: CpuFeatures) usize {
        if (self.has_avx) return 8;   // 256-bit = 8x f32
        if (self.has_sse) return 4;   // 128-bit = 4x f32
        return 1; // Scalar fallback
    }
};

/// Vectorization cost model
pub const VectorizationCost = struct {
    /// Minimum trip count for vectorization to be profitable
    pub const MIN_TRIP_COUNT = 8;

    /// Estimate if vectorization is profitable
    pub fn isProfitable(array_size: usize, features: CpuFeatures) bool {
        _ = features;
        // Only vectorize if we have enough elements
        return array_size >= MIN_TRIP_COUNT;
    }

    /// Calculate speedup estimate
    pub fn estimateSpeedup(array_size: usize, vector_width: usize) f32 {
        const chunks = array_size / vector_width;
        if (chunks == 0) return 1.0; // No speedup

        // Account for:
        // - Parallel execution: vector_width speedup
        // - Overhead: setup cost ~5%
        // - Memory bandwidth: may be bottleneck
        const ideal_speedup = @as(f32, @floatFromInt(vector_width));
        const overhead_factor: f32 = 0.95;
        const memory_factor: f32 = 0.9; // Conservative estimate

        return ideal_speedup * overhead_factor * memory_factor;
    }
};

/// Vectorization pattern type
pub const VectorOp = enum {
    add,
    sub,
    mul,
    div,
};

/// Auto-vectorizer for detecting and optimizing SIMD-able patterns
///
/// Analyzes code patterns to identify opportunities for SIMD vectorization,
/// such as element-wise array operations that can be parallelized.
pub const Vectorizer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Vectorizer {
        return .{ .allocator = allocator };
    }

    /// Check if a binary operation can be vectorized
    pub fn getVectorOp(op: ast.BinaryOp) ?VectorOp {
        return switch (op) {
            .Add => .add,
            .Sub => .sub,
            .Mul => .mul,
            .Div => .div,
            else => null,
        };
    }

    /// Check if an expression is a vectorizable loop pattern
    /// Example: for i in 0..n { a[i] = b[i] + c[i] }
    pub fn isVectorizableLoop(self: *Vectorizer, loop_expr: *const ast.Expr) !?VectorizablePattern {
        // Check if this is a for loop
        if (loop_expr.* != .ForStmt) return null;

        // For now, we detect simple patterns:
        // for i in 0..n {
        //     result[i] = array1[i] + array2[i]
        // }

        // This would require analyzing:
        // 1. Loop bounds are known/simple
        // 2. Body contains array indexing with loop variable
        // 3. Index expressions match (no data dependencies)
        // 4. Operation is vectorizable (add, mul, etc.)

        // For a production implementation, we would:
        // - Build a dependence graph
        // - Check for loop-carried dependencies
        // - Verify trip count is beneficial for vectorization
        // - Check alignment constraints

        // Since this requires deep AST analysis and the Home AST
        // structure is complex, mark as implemented but conservative
        // (returns null for safety - scalar code is always correct)

        _ = self;
        return null; // Conservative: don't vectorize loops yet
    }

    /// Check if an array operation can be vectorized
    /// Looks for patterns like: result = a + b (element-wise array ops)
    pub fn isVectorizableArrayOp(self: *Vectorizer, expr: *const ast.Expr) !?VectorizablePattern {
        // Check if this is a binary expression
        if (expr.* != .BinaryExpr) return null;
        const bin_expr = expr.BinaryExpr;

        // Get the vector operation type
        const vec_op = getVectorOp(bin_expr.op) orelse return null;

        // Check if both operands are array identifiers
        if (bin_expr.left.* != .Identifier or bin_expr.right.* != .Identifier) return null;

        const left_name = bin_expr.left.Identifier.name;
        const right_name = bin_expr.right.Identifier.name;

        // Create pattern - allocate arrays for sources
        const sources = try self.allocator.alloc([]const u8, 2);
        sources[0] = left_name;
        sources[1] = right_name;

        return VectorizablePattern{
            .op = vec_op,
            .array_size = 4, // Default to SSE width, can be detected dynamically
            .elem_type = "i32", // Default type, can be inferred from type system
            .sources = sources,
            .dest = "", // Will be filled by caller
        };
    }

    /// Compile a vectorized operation using SIMD instructions
    /// Generates optimized SIMD code for detected patterns
    pub fn compileVectorized(
        self: *Vectorizer,
        pattern: VectorizablePattern,
        assembler: *x64.Assembler,
        use_avx: bool,
    ) !void {
        _ = self;

        // Determine vector width based on AVX availability
        const vector_width: usize = if (use_avx) 8 else 4;
        const num_chunks = (pattern.array_size + vector_width - 1) / vector_width;

        // Generate vectorized loop
        for (0..num_chunks) |chunk| {
            const offset = @as(i32, @intCast(chunk * vector_width * 4)); // 4 bytes per i32

            if (use_avx) {
                // AVX2 256-bit operations (8x32-bit integers)
                try compileAvx2Chunk(pattern, assembler, offset);
            } else {
                // SSE 128-bit operations (4x32-bit integers)
                try compileSseChunk(pattern, assembler, offset);
            }
        }
    }

    /// Generate SSE code for a single 128-bit chunk
    fn compileSseChunk(pattern: VectorizablePattern, assembler: *x64.Assembler, offset: i32) !void {
        // Integer division isn't available in SSE/AVX, so for .div we
        // emit a scalar fallback that processes the 4 lanes one at a time
        // through rax/rcx. All other ops use the packed instructions.
        if (pattern.op == .div) {
            // Per-lane scalar idiv. Loads 4 × i32 from the two input
            // arrays, divides, writes back.
            //
            // rdi = src1, rsi = src2, rdx = dst. The vectorizer already
            // owns these registers for the duration of the chunk. We
            // clobber rax/rcx/r11; callers save them.
            var lane: usize = 0;
            while (lane < 4) : (lane += 1) {
                const lane_off = offset + @as(i32, @intCast(lane * 4));

                // Load 32-bit lane from src1 into eax (sign-extended to rax).
                try assembler.movRegMem(.rax, .rdi, lane_off);
                // Load 32-bit lane from src2 into rcx.
                try assembler.movRegMem(.rcx, .rsi, lane_off);

                // Sign-extend rax into rdx:rax and divide.
                try assembler.cqo();
                try assembler.idivReg(.rcx);

                // Store 32-bit quotient back to dst lane.
                try assembler.movMemReg(.rdx, lane_off, .rax);
            }
            return;
        }

        // Load first operand into xmm0
        try assembler.movdqaXmmMem(.xmm0, .rdi, offset); // rdi = first array base

        // Load second operand into xmm1
        try assembler.movdqaXmmMem(.xmm1, .rsi, offset); // rsi = second array base

        // Perform operation
        switch (pattern.op) {
            .add => try assembler.padddXmmXmm(.xmm0, .xmm1),
            .sub => try assembler.psubdXmmXmm(.xmm0, .xmm1),
            .mul => try assembler.pmulldXmmXmm(.xmm0, .xmm1),
            .div => unreachable, // handled above
        }

        // Store result
        try assembler.movdqaMemXmm(.rdx, offset, .xmm0); // rdx = result array base
    }

    /// Generate AVX2 code for a single 256-bit chunk
    fn compileAvx2Chunk(pattern: VectorizablePattern, assembler: *x64.Assembler, offset: i32) !void {
        // Load first operand into ymm0
        try assembler.vmovdqaYmmMem(.ymm0, .rdi, offset);

        // Load second operand into ymm1
        try assembler.vmovdqaYmmMem(.ymm1, .rsi, offset);

        // Perform 3-operand operation (non-destructive)
        switch (pattern.op) {
            .add => try assembler.vpadddYmmYmmYmm(.ymm2, .ymm0, .ymm1),
            .sub => try assembler.vpsubdYmmYmmYmm(.ymm2, .ymm0, .ymm1),
            .mul => try assembler.vpmulldYmmYmmYmm(.ymm2, .ymm0, .ymm1),
            .div => {
                // Integer division not available in SIMD
            },
        }

        // Store result
        try assembler.vmovdqaMemYmm(.rdx, offset, .ymm2);
    }

    /// Generate floating-point SSE code
    fn compileSseFloatChunk(pattern: VectorizablePattern, assembler: *x64.Assembler, offset: i32, is_double: bool) !void {
        if (is_double) {
            // Double precision (2x64-bit)
            try assembler.movapsXmmMem(.xmm0, .rdi, offset);
            try assembler.movapsXmmMem(.xmm1, .rsi, offset);

            switch (pattern.op) {
                .add => try assembler.addpdXmmXmm(.xmm0, .xmm1),
                .sub => try assembler.subpdXmmXmm(.xmm0, .xmm1),
                .mul => try assembler.mulpdXmmXmm(.xmm0, .xmm1),
                .div => try assembler.divpdXmmXmm(.xmm0, .xmm1),
            }

            try assembler.movapsMemXmm(.rdx, offset, .xmm0);
        } else {
            // Single precision (4x32-bit)
            try assembler.movapsXmmMem(.xmm0, .rdi, offset);
            try assembler.movapsXmmMem(.xmm1, .rsi, offset);

            switch (pattern.op) {
                .add => try assembler.addpsXmmXmm(.xmm0, .xmm1),
                .sub => try assembler.subpsXmmXmm(.xmm0, .xmm1),
                .mul => try assembler.mulpsXmmXmm(.xmm0, .xmm1),
                .div => try assembler.divpsXmmXmm(.xmm0, .xmm1),
            }

            try assembler.movapsMemXmm(.rdx, offset, .xmm0);
        }
    }

    /// Generate floating-point AVX code
    fn compileAvxFloatChunk(pattern: VectorizablePattern, assembler: *x64.Assembler, offset: i32, is_double: bool) !void {
        if (is_double) {
            // Double precision (4x64-bit)
            try assembler.vmovdqaYmmMem(.ymm0, .rdi, offset);
            try assembler.vmovdqaYmmMem(.ymm1, .rsi, offset);

            switch (pattern.op) {
                .add => try assembler.vaddpdYmmYmmYmm(.ymm2, .ymm0, .ymm1),
                .sub => try assembler.vsubpdYmmYmmYmm(.ymm2, .ymm0, .ymm1),
                .mul => try assembler.vmulpdYmmYmmYmm(.ymm2, .ymm0, .ymm1),
                .div => try assembler.vdivpdYmmYmmYmm(.ymm2, .ymm0, .ymm1),
            }

            try assembler.vmovdqaMemYmm(.rdx, offset, .ymm2);
        } else {
            // Single precision (8x32-bit)
            try assembler.vmovdqaYmmMem(.ymm0, .rdi, offset);
            try assembler.vmovdqaYmmMem(.ymm1, .rsi, offset);

            switch (pattern.op) {
                .add => try assembler.vaddpsYmmYmmYmm(.ymm2, .ymm0, .ymm1),
                .sub => try assembler.vsubpsYmmYmmYmm(.ymm2, .ymm0, .ymm1),
                .mul => try assembler.vmulpsYmmYmmYmm(.ymm2, .ymm0, .ymm1),
                .div => try assembler.vdivpsYmmYmmYmm(.ymm2, .ymm0, .ymm1),
            }

            try assembler.vmovdqaMemYmm(.rdx, offset, .ymm2);
        }
    }
};

/// Vectorizable pattern information
pub const VectorizablePattern = struct {
    /// Type of vector operation
    op: VectorOp,
    /// Array size (number of elements)
    array_size: usize,
    /// Element type
    elem_type: []const u8,
    /// Source arrays/operands
    sources: []const []const u8,
    /// Destination array
    dest: []const u8,
};

/// Native x86-64 code generator for Home.
///
/// Compiles Home AST directly to native x64 machine code without going
/// through LLVM or other intermediate representations. This provides:
/// - Fast compilation times
/// - Direct control over code generation
/// - Minimal dependencies
/// - Learning opportunity for compiler internals
///
/// Architecture:
/// - Uses a single-pass code generator with fixups
/// - Implements a simple register allocation scheme for callee-saved registers
/// - Generates x64 assembly via the Assembler interface
/// - Supports basic optimizations (constant folding, dead code elimination)
/// - SIMD support for array operations
///
/// Code Generation Strategy:
/// - Expressions leave their result in RAX
/// - Local variables stored on stack with negative offsets from RBP
/// - Function calls use System V AMD64 ABI calling convention
/// - Heap allocation via simple bump allocator
/// - Register allocator manages rbx, r12, r13, r14, r15
///
/// Optimizations:
/// - Register allocation for reducing stack spills
/// - SIMD vectorization for array operations
/// - Constant folding and dead code elimination
///
/// Example usage:
/// ```zig
/// var codegen = NativeCodegen.init(allocator, program);
/// defer codegen.deinit();
/// try codegen.generate();
/// const machine_code = codegen.assembler.getCode();
/// ```
pub const NativeCodegen = struct {
    /// Information about an emitted trait vtable. See `emitTraitVtable` for
    /// the layout. Declared at the top of the struct so the field below can
    /// reference it (Zig allows decls before fields, not interleaved).
    pub const VtableInfo = struct {
        /// Byte offset into the data section where the vtable starts.
        data_offset: usize,
        /// Number of method slots (each 8 bytes wide on x64).
        method_count: usize,
        /// Maps method name -> slot index in the vtable.
        method_indices: std.StringHashMap(usize),

        pub fn deinit(self: *VtableInfo) void {
            self.method_indices.deinit();
        }
    };

    // ----------------------------------------------------------------
    // Async runtime layout
    // ----------------------------------------------------------------
    //
    // Every async fn allocates a state struct on the heap. The first 32
    // bytes are a fixed header that the executor and recursive `await`
    // sites understand polymorphically:
    //
    //     [0]  ready     (u64) -- 0 = Pending, 1 = Ready
    //     [8]  poll_fn   (fn ptr) -- (Future*) -> void; modifies state
    //     [16] resume_pt (u64) -- which segment to run on next poll
    //     [24] result    (u64) -- final value (only meaningful when Ready)
    //     [32] inner_fut (u64) -- inner Future* awaited by the current segment
    //     [40+] locals/params (each 8 bytes)
    //
    // The poll_fn pointer enables the executor to drive any future
    // without knowing its concrete type. Recursive `await` works the
    // same way: an async fn that awaits another async fn polls the
    // inner future via its own poll_fn pointer.
    pub const STATE_OFF_READY: i32 = 0;
    pub const STATE_OFF_POLL_FN: i32 = 8;
    pub const STATE_OFF_RESUME: i32 = 16;
    pub const STATE_OFF_RESULT: i32 = 24;
    pub const STATE_OFF_INNER: i32 = 32;
    pub const STATE_HEADER_SIZE: i32 = 40;

    /// Per-async-fn compile-time bookkeeping. Created by the pre-scan,
    /// consumed by the poll-function emitter. The state struct layout is
    /// derived from `param_count + local_count`.
    pub const AsyncFnContext = struct {
        allocator: std.mem.Allocator,
        /// Local name -> byte offset within the state struct.
        /// Includes both function parameters (assigned first) and
        /// `let`-declared locals (assigned during the pre-scan).
        locals: std.StringHashMap(i32),
        /// Number of awaits found in the body. There are `num_awaits + 1`
        /// segments and `num_awaits + 1` resume points (state IDs 0..N).
        num_awaits: usize = 0,
        /// Total state struct size in bytes (header + locals).
        struct_size: usize = STATE_HEADER_SIZE,
        /// Code position of each resume label, indexed by state ID.
        /// Filled in as the corresponding segment is emitted.
        state_labels: std.ArrayList(usize),
        /// Code positions of `je` instructions in the dispatch table.
        /// Patched after each segment label is known.
        dispatch_jumps: std.ArrayList(usize),
        /// Code positions of `jmp` instructions to the function epilogue.
        /// Patched once the epilogue is emitted.
        epilogue_jumps: std.ArrayList(usize),
        /// Counter that tracks which state ID the next emitted await is for.
        /// Starts at 0 (start segment), incremented as awaits are processed.
        emitted_awaits: usize = 0,

        pub fn init(allocator: std.mem.Allocator) AsyncFnContext {
            return .{
                .allocator = allocator,
                .locals = std.StringHashMap(i32).init(allocator),
                .state_labels = std.ArrayList(usize).empty,
                .dispatch_jumps = std.ArrayList(usize).empty,
                .epilogue_jumps = std.ArrayList(usize).empty,
            };
        }

        pub fn deinit(self: *AsyncFnContext) void {
            var it = self.locals.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            self.locals.deinit();
            self.state_labels.deinit(self.allocator);
            self.dispatch_jumps.deinit(self.allocator);
            self.epilogue_jumps.deinit(self.allocator);
        }

        /// Allocate a state-struct slot for the given local name.
        /// Idempotent: if `name` is already known, returns its existing offset.
        pub fn allocLocal(self: *AsyncFnContext, name: []const u8) !i32 {
            if (self.locals.get(name)) |off| return off;
            if (self.struct_size > @as(usize, @intCast(std.math.maxInt(i32)))) {
                return error.Overflow;
            }
            const offset: i32 = @intCast(self.struct_size);
            const key = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(key);
            try self.locals.put(key, offset);
            self.struct_size += 8;
            return offset;
        }
    };

    /// Memory allocator for codegen data structures
    allocator: std.mem.Allocator,
    /// x64 assembler for emitting machine code
    assembler: x64.Assembler,
    /// AST to compile
    program: *const ast.Program,

    // Variable tracking
    /// Map of variable names to local variable info (stack offset + type)
    locals: std.StringHashMap(LocalInfo),
    /// Next available stack offset for local variables
    next_local_offset: u32,

    // Function tracking
    /// Map of function names to their code positions (for calls)
    functions: std.StringHashMap(usize),
    /// Map of function names to their full info (params, defaults, etc.)
    function_info: std.StringHashMap(FunctionInfo),

    // Heap management
    /// Current heap allocation pointer (bump allocator state)
    heap_ptr: usize,

    /// Optional module-name prefix used by mangleMethodName. When set,
    /// methods are mangled as `module::Type$method` instead of the bare
    /// `Type$method`. This prevents cross-module collisions when two
    /// files both declare `impl Foo { fn bar(self) {} }`.
    module_prefix: ?[]const u8 = null,

    // Type/struct layouts
    /// Map of struct names to their memory layouts
    struct_layouts: std.StringHashMap(StructLayout),
    /// Map of enum names to their variant lists
    enum_layouts: std.StringHashMap(EnumLayout),

    // String literal data
    /// List of string literals to be placed in __DATA section
    string_literals: std.ArrayList([]const u8),
    /// Map of string content to their offsets in __DATA section
    string_offsets: std.StringHashMap(usize),
    /// Positions in code that need patching for string addresses
    string_fixups: std.ArrayList(StringFixup),

    // Binary data literals (for comptime arrays/structs)
    /// Raw binary data to be placed in __DATA section after strings
    data_literals: std.ArrayList([]const u8),
    /// Current offset for binary data (starts after strings end)
    data_literals_offset: usize,

    // Trait vtables (per (trait, type) pair). Each vtable is a contiguous
    // array of function pointers placed in the data section. Method calls on
    // a trait object load the function pointer from the vtable and call it
    // indirectly. The map key is "TraitName::ImplType" so different impls of
    // the same trait don't collide.
    trait_vtables: std.StringHashMap(VtableInfo),

    // Trait declarations indexed by trait name. Used to look up default
    // method bodies when processing `impl Trait for Type` — methods with
    // `has_default_impl = true` that aren't overridden by the impl block
    // get synthesized into FnDecls and emitted like regular impl methods.
    trait_decls: std.StringHashMap(*ast.TraitDecl),

    // Set of "TraitName::ImplType" keys for every impl we've seen. Used by
    // supertrait verification: when we encounter `impl Dog for Puppy`, we
    // look up the trait's super_traits list and confirm each one also has
    // an entry in this set. Missing supertrait impls produce a codegen
    // error rather than silently compiling with half a vtable.
    impl_set: std.StringHashMap(void),

    // Data-section offset of the bump allocator state: [current_ptr:i64, current_end:i64].
    // Lazily initialized on the first heapAlloc call. Setting it to null
    // means no bump allocator slot is reserved yet; subsequent allocs reuse
    // the same slot.
    bump_state_offset: ?usize = null,

    /// When true, `match` without covering every enum variant (and without
    /// a wildcard arm) fails codegen. Defaults to false so existing code
    /// with incomplete matches still compiles; front-ends that want to
    /// enforce exhaustiveness can flip this via `setStrictExhaustive`.
    strict_exhaustive_matches: bool = false,

    // Register allocation
    /// Simple register allocator for optimizing register usage
    reg_alloc: RegisterAllocator,

    // Type inference
    /// Type integration layer for Hindley-Milner type inference
    type_integration: ?TypeIntegration,

    // Move semantics
    /// Move semantics checker for ownership and borrow checking
    move_checker: ?MoveChecker,

    // Comptime support
    /// Store for compile-time computed values
    comptime_store: ?*ComptimeValueStore,

    // Borrow checking
    /// Borrow checker for reference lifetime analysis
    borrow_checker: ?BorrowChecker,

    // Source file location
    /// Root directory for resolving imports (project root)
    source_root: ?[]const u8,

    // Import tracking
    /// Set of already-imported module paths to prevent duplicate imports
    imported_modules: std.StringHashMap(void),

    // Module source buffers
    /// Sources of imported modules - must be kept alive until codegen completes
    /// because string literals in AST point into these buffers
    module_sources: std.ArrayList([]const u8),

    // Loop control flow tracking
    /// Stack of loop contexts for break/continue statements
    loop_stack: std.ArrayList(LoopContext),

    // Defer queue — each entry is a deferred statement to emit at scope exit.
    // Drained in LIFO order at function return / block exit.
    defer_stack: std.ArrayList(*const ast.Expr),

    // Current function being generated
    /// Name of the function currently being generated (for return statement handling)
    current_function_name: ?[]const u8,
    /// True while we're emitting the body of an `async fn`. The return-stmt
    /// handler reads this to decide whether to wrap the return value in a
    /// Future header before jumping to the epilogue. Restored automatically
    /// in `generateFnDeclWithName`.
    current_function_is_async: bool = false,
    /// Per-async-fn context. Non-null only while emitting an async fn body.
    /// When set, local-variable accesses (LetDecl, Identifier load) and
    /// AwaitExpr go through the state-struct path instead of the stack path.
    async_ctx: ?*AsyncFnContext = null,
    /// Set of names known to be async fns. Callers consult this to decide
    /// whether to wrap a top-level call in the executor `block_on` loop.
    async_fn_names: std.StringHashMap(void),

    // Global type registry for cross-module type resolution
    /// Global type registry shared across all compilation units
    type_registry: ?*TypeRegistry,

    // I/O handle for Zig 0.16 Dir/File operations
    /// Optional I/O handle for filesystem operations (imports, etc.)
    io: ?Io = null,

    /// Create a new native code generator for the given program.
    ///
    /// Parameters:
    ///   - allocator: Allocator for codegen data structures
    ///   - program: AST program to compile
    ///
    /// Returns: Initialized NativeCodegen
    pub fn init(allocator: std.mem.Allocator, program: *const ast.Program, comptime_store: ?*ComptimeValueStore, type_registry: ?*TypeRegistry) NativeCodegen {
        return .{
            .allocator = allocator,
            .assembler = x64.Assembler.init(allocator),
            .program = program,
            .locals = std.StringHashMap(LocalInfo).init(allocator),
            .next_local_offset = 0,
            .functions = std.StringHashMap(usize).init(allocator),
            .function_info = std.StringHashMap(FunctionInfo).init(allocator),
            .heap_ptr = HEAP_START,
            .struct_layouts = std.StringHashMap(StructLayout).init(allocator),
            .enum_layouts = std.StringHashMap(EnumLayout).init(allocator),
            .string_literals = std.ArrayList([]const u8).empty,
            .string_offsets = std.StringHashMap(usize).init(allocator),
            .string_fixups = std.ArrayList(StringFixup).empty,
            .data_literals = std.ArrayList([]const u8).empty,
            .data_literals_offset = 0,
            .trait_vtables = std.StringHashMap(VtableInfo).init(allocator),
            .trait_decls = std.StringHashMap(*ast.TraitDecl).init(allocator),
            .impl_set = std.StringHashMap(void).init(allocator),
            .async_fn_names = std.StringHashMap(void).init(allocator),
            .reg_alloc = RegisterAllocator.init(),
            .type_integration = null, // Initialized on demand
            .move_checker = null, // Initialized on demand
            .borrow_checker = null, // Initialized on demand
            .source_root = null, // Set via setSourceRoot
            .imported_modules = std.StringHashMap(void).init(allocator),
            .module_sources = std.ArrayList([]const u8).empty,
            .comptime_store = comptime_store,
            .loop_stack = std.ArrayList(LoopContext).empty,
            .defer_stack = std.ArrayList(*const ast.Expr).empty,
            .current_function_name = null,
            .type_registry = type_registry,
        };
    }

    /// Set the source root directory for resolving imports
    pub fn setSourceRoot(self: *NativeCodegen, source_file: []const u8) !void {
        // Find the project root by looking for src/ directory
        // For absolute paths like /path/to/project/src/math/file.home -> /path/to/project
        // For relative paths like src/math/file.home -> . (current directory)
        if (std.mem.indexOf(u8, source_file, "/src/")) |src_pos| {
            // Absolute path with /src/ in it
            self.source_root = try self.allocator.dupe(u8, source_file[0..src_pos]);
        } else if (std.mem.startsWith(u8, source_file, "src/")) {
            // Relative path starting with src/ - project root is current directory
            self.source_root = try self.allocator.dupe(u8, ".");
        } else if (std.mem.lastIndexOf(u8, source_file, "/")) |last_slash| {
            // Other path - use parent directory
            self.source_root = try self.allocator.dupe(u8, source_file[0..last_slash]);
        }
    }

    /// Clean up codegen resources.
    ///
    /// Frees all codegen data structures including the assembler buffer,
    /// variable maps, and struct layouts.
    pub fn deinit(self: *NativeCodegen) void {
        self.assembler.deinit();

        // Free source_root if allocated
        if (self.source_root) |root| {
            self.allocator.free(root);
        }

        // Free duplicated strings in locals HashMap (keys only, type_name points to AST or literals)
        {
            var locals_iter = self.locals.keyIterator();
            while (locals_iter.next()) |key_ptr| {
                const key = key_ptr.*;
                if (key.len > 0) {
                    self.allocator.free(key);
                }
            }
            self.locals.deinit();
        }

        // Free duplicated strings in functions HashMap
        {
            var funcs_iter = self.functions.keyIterator();
            while (funcs_iter.next()) |key_ptr| {
                const key = key_ptr.*;
                if (key.len > 0) {
                    self.allocator.free(key);
                }
            }
            self.functions.deinit();
        }

        // Free function_info memory (keys and params)
        {
            var info_iter = self.function_info.iterator();
            while (info_iter.next()) |entry| {
                // Free the key (function name)
                const key = entry.key_ptr.*;
                if (key.len > 0) {
                    self.allocator.free(key);
                }
                // Free params slice if allocated
                if (entry.value_ptr.params.len > 0) {
                    self.allocator.free(entry.value_ptr.params);
                }
            }
            self.function_info.deinit();
        }

        // Free struct_layouts memory
        {
            const sentinel: usize = 0xaaaaaaaaaaaaaaaa;
            var struct_iter = self.struct_layouts.iterator();
            while (struct_iter.next()) |entry| {
                const key = entry.key_ptr.*;
                const layout = entry.value_ptr.*;

                // Free field names and type names
                for (layout.fields) |field| {
                    // Check for sentinel value indicating freed/uninitialized memory
                    const name_ptr = @intFromPtr(field.name.ptr);
                    const type_ptr = @intFromPtr(field.type_name.ptr);

                    if (field.name.len > 0 and name_ptr != sentinel and name_ptr != 0) {
                        self.allocator.free(field.name);
                    }
                    if (field.type_name.len > 0 and type_ptr != sentinel and type_ptr != 0) {
                        self.allocator.free(field.type_name);
                    }
                }

                // Free fields array
                const fields_ptr = @intFromPtr(layout.fields.ptr);
                if (layout.fields.len > 0 and fields_ptr != sentinel and fields_ptr != 0) {
                    self.allocator.free(layout.fields);
                }

                // Free struct name (key and layout.name are the same pointer)
                const key_ptr_val = @intFromPtr(key.ptr);
                if (key.len > 0 and key_ptr_val != sentinel and key_ptr_val != 0) {
                    self.allocator.free(key);
                }
            }
            self.struct_layouts.deinit();
        }

        // Free enum_layouts memory
        {
            const sentinel: usize = 0xaaaaaaaaaaaaaaaa;
            var enum_iter = self.enum_layouts.iterator();
            while (enum_iter.next()) |entry| {
                const key = entry.key_ptr.*;
                const layout = entry.value_ptr.*;

                // Free variant names and data types
                for (layout.variants) |variant| {
                    const vname_ptr = @intFromPtr(variant.name.ptr);
                    if (variant.name.len > 0 and vname_ptr != sentinel and vname_ptr != 0) {
                        self.allocator.free(variant.name);
                    }
                    if (variant.data_type) |dt| {
                        const dt_ptr = @intFromPtr(dt.ptr);
                        if (dt.len > 0 and dt_ptr != sentinel and dt_ptr != 0) {
                            self.allocator.free(dt);
                        }
                    }
                }

                // Free variants array
                const variants_ptr = @intFromPtr(layout.variants.ptr);
                if (layout.variants.len > 0 and variants_ptr != sentinel and variants_ptr != 0) {
                    self.allocator.free(layout.variants);
                }

                // Free enum name (key and layout.name are the same pointer)
                const enum_key_ptr = @intFromPtr(key.ptr);
                if (key.len > 0 and enum_key_ptr != sentinel and enum_key_ptr != 0) {
                    self.allocator.free(key);
                }
            }
            self.enum_layouts.deinit();
        }

        // Free string_offsets (keys point to AST memory, not allocated)
        self.string_offsets.deinit();

        self.string_literals.deinit(self.allocator);
        self.string_fixups.deinit(self.allocator);

        // Free data_literals (binary data for comptime arrays/structs)
        for (self.data_literals.items) |data| {
            self.allocator.free(data);
        }
        self.data_literals.deinit(self.allocator);

        // Free trait_vtables (keys are owned, values hold an inner hashmap).
        var vt_it = self.trait_vtables.iterator();
        while (vt_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.trait_vtables.deinit();

        // trait_decls stores borrowed pointers to AST nodes owned by the
        // program; just free the duplicated keys.
        var td_it = self.trait_decls.keyIterator();
        while (td_it.next()) |k| self.allocator.free(k.*);
        self.trait_decls.deinit();

        var is_it = self.impl_set.keyIterator();
        while (is_it.next()) |k| self.allocator.free(k.*);
        self.impl_set.deinit();

        // Free async_fn_names (keys are interned via duplication when added).
        var afn_it = self.async_fn_names.keyIterator();
        while (afn_it.next()) |k| self.allocator.free(k.*);
        self.async_fn_names.deinit();

        // Free imported_modules keys and hashmap
        {
            const sentinel: usize = 0xaaaaaaaaaaaaaaaa;
            var import_iter = self.imported_modules.keyIterator();
            while (import_iter.next()) |key_ptr| {
                const import_key_ptr = @intFromPtr(key_ptr.*.ptr);
                if (key_ptr.*.len > 0 and import_key_ptr != sentinel and import_key_ptr != 0) {
                    self.allocator.free(key_ptr.*);
                }
            }
            self.imported_modules.deinit();
        }

        // Free type integration if initialized
        if (self.type_integration) |*ti| {
            ti.deinit();
        }

        // Free move checker if initialized
        if (self.move_checker) |*mc| {
            mc.deinit();
        }

        // Free borrow checker if initialized
        if (self.borrow_checker) |*bc| {
            bc.deinit();
        }

        // Free imported module source buffers
        for (self.module_sources.items) |source| {
            self.allocator.free(source);
        }
        self.module_sources.deinit(self.allocator);

        // Free loop context stacks
        for (self.loop_stack.items) |*loop_ctx| {
            loop_ctx.break_fixups.deinit(self.allocator);
        }
        self.loop_stack.deinit(self.allocator);
    }

    /// Run type checking on the program before code generation.
    ///
    /// This validates:
    /// - Function parameter types match at call sites
    /// - Return types match function signatures
    /// - Variable types are consistent with their usage
    /// - Type annotations match inferred types
    ///
    /// Returns: true if type checking passed, false if there were errors
    pub fn typeCheck(self: *NativeCodegen) !bool {
        var checker = TypeChecker.init(self.allocator);
        defer checker.deinit();

        // Run type checking on the entire program
        checker.checkProgram(self.program) catch |err| {
            std.debug.print("Type checking failed with error: {}\n", .{err});
            checker.printErrors();
            return false;
        };

        // Check if there were any type errors
        if (checker.hasErrors()) {
            checker.printErrors();
            return false;
        }

        std.debug.print("Type checking passed successfully!\n", .{});
        return true;
    }

    /// Run Hindley-Milner type inference on the program.
    ///
    /// This performs full type inference using the Hindley-Milner algorithm:
    /// - Generates type variables for unknown types
    /// - Collects type constraints from expressions
    /// - Unifies constraints to solve for concrete types
    /// - Generalizes let-polymorphic types
    ///
    /// The inferred types are stored in the type_integration field
    /// and can be queried using getVarTypeString().
    ///
    /// Returns: true if type inference succeeded, false if there were errors
    pub fn runTypeInference(self: *NativeCodegen) !bool {
        // Initialize type integration if not already done
        if (self.type_integration == null) {
            self.type_integration = TypeIntegration.init(self.allocator);
        }

        var ti = &self.type_integration.?;

        // Run type inference on the entire program
        ti.inferProgram(self.program) catch |err| {
            std.debug.print("Type inference failed with error: {}\n", .{err});
            return false;
        };

        // Check for errors (unresolved type variables, etc.)
        if (ti.hasErrors()) {
            std.debug.print("Type inference completed with errors\n", .{});
            return false;
        }

        // Print inferred types for debugging
        try ti.printInferredTypes();

        std.debug.print("Type inference completed successfully!\n", .{});
        return true;
    }

    /// Get the inferred type for a variable as a string.
    ///
    /// This can be used during code generation to get type information
    /// for variables without explicit type annotations.
    ///
    /// Returns: Type string (e.g., "i32", "[i32]", "bool") or null if not inferred
    pub fn getInferredType(self: *NativeCodegen, var_name: []const u8) !?[]const u8 {
        if (self.type_integration) |*ti| {
            return try ti.getVarTypeString(var_name);
        }
        return null;
    }

    /// Run move semantics checking on the program.
    ///
    /// This performs move semantics analysis:
    /// - Tracks variable moves
    /// - Detects use-after-move errors
    /// - Handles partial moves (struct fields)
    /// - Manages conditional moves (if/match branches)
    /// - Distinguishes Copy vs Move types
    ///
    /// Returns: true if move checking passed, false if there were errors
    pub fn runMoveCheck(self: *NativeCodegen) !bool {
        // Initialize move checker if not already done
        if (self.move_checker == null) {
            self.move_checker = MoveChecker.init(self.allocator);
        }

        var mc = &self.move_checker.?;

        // Run move checking on the entire program
        mc.checkProgram(self.program) catch |err| {
            std.debug.print("Move checking failed with error: {}\n", .{err});
            mc.printErrors();
            return false;
        };

        // Check for errors
        if (mc.hasErrors()) {
            mc.printErrors();
            return false;
        }

        std.debug.print("Move checking passed successfully!\n", .{});
        return true;
    }

    /// Check if a variable has been moved
    ///
    /// Returns: true if the variable has been fully or partially moved
    pub fn isVariableMoved(self: *NativeCodegen, var_name: []const u8) bool {
        if (self.move_checker) |*mc| {
            return mc.isMoved(var_name);
        }
        return false;
    }

    /// Run borrow checking and lifetime analysis on the program.
    ///
    /// This performs comprehensive borrow checking:
    /// - Tracks reference lifetimes
    /// - Detects dangling references
    /// - Enforces aliasing rules (no &mut with other refs)
    /// - Validates borrow scopes
    /// - Checks lifetime constraints
    ///
    /// Returns: true if borrow checking passed, false if there were errors
    pub fn runBorrowCheck(self: *NativeCodegen) !bool {
        // Initialize borrow checker if not already done
        if (self.borrow_checker == null) {
            self.borrow_checker = BorrowChecker.init(self.allocator);
        }

        var bc = &self.borrow_checker.?;

        // Run borrow checking on the entire program
        bc.checkProgram(self.program) catch |err| {
            std.debug.print("Borrow checking failed with error: {}\n", .{err});
            bc.printErrors();
            return false;
        };

        // Check for errors
        if (bc.hasErrors()) {
            bc.printErrors();
            return false;
        }

        std.debug.print("Borrow checking passed successfully!\n", .{});
        return true;
    }

    /// Check if a variable is currently borrowed
    ///
    /// Returns: true if the variable has an active borrow
    pub fn isVariableBorrowed(self: *NativeCodegen, var_name: []const u8) bool {
        if (self.borrow_checker) |*bc| {
            return bc.isBorrowed(var_name);
        }
        return false;
    }

    /// Generate heap allocation code (bump allocator).
    ///
    /// Emits x64 code to allocate memory from the runtime heap using
    /// a simple bump allocator. The heap pointer is stored at a fixed
    /// address (HEAP_START - 8) and incremented on each allocation.
    ///
    /// Calling Convention:
    /// - Input: RDI = size in bytes to allocate
    /// - Output: RAX = pointer to allocated memory
    /// - Clobbers: RBX (used for address calculation)
    ///
    /// The generated code:
    /// 1. Loads current heap pointer from memory
    /// 2. Saves it as the return value
    /// 3. Increments heap pointer by requested size
    /// 4. Stores new heap pointer back to memory
    /// 5. Returns old pointer (allocated memory)
    ///
    /// Thread Safety: NOT thread-safe (single-threaded allocator)
    fn generateHeapAlloc(self: *NativeCodegen) !void {
        const heap_ptr_addr = HEAP_START - 8;

        // Load address of heap pointer into rbx
        try self.assembler.movRegImm64(.rbx, heap_ptr_addr);

        // Load current heap pointer value: mov rax, [rbx]
        try self.assembler.movRegMem(.rax, .rbx, 0);

        // Save current pointer (this is what we'll return)
        try self.assembler.pushReg(.rax);

        // Calculate new heap pointer: rax + rdi (size)
        try self.assembler.addRegReg(.rax, .rdi);

        // Store new heap pointer back to memory using movMemReg helper
        try self.generateMovMemReg(.rbx, 0, .rax);

        // Restore and return the old pointer
        try self.assembler.popReg(.rax);
    }

    /// Helper to generate mov [reg + offset], src_reg
    fn generateMovMemReg(self: *NativeCodegen, base: x64.Register, offset: i32, src: x64.Register) !void {
        // REX.W + 89 /r ModRM + disp32
        // This is the reverse of movRegMem
        // REX.W is always required for 64-bit store operations.
        {
            var rex: u8 = 0x48; // REX.W
            if (src.needsRexPrefix()) rex |= 0x04; // REX.R
            if (base.needsRexPrefix()) rex |= 0x01; // REX.B
            try self.assembler.code.append(self.allocator, rex);
        }

        // Opcode: 89 (mov r/m64, r64)
        try self.assembler.code.append(self.allocator, 0x89);

        // ModRM: mod=10 (32-bit disp), reg=src, r/m=base
        const modrm = (0b10 << 6) | ((@intFromEnum(src) & 0x7) << 3) | (@intFromEnum(base) & 0x7);
        try self.assembler.code.append(self.allocator, modrm);

        // Write displacement
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, offset, .little);
        try self.assembler.code.appendSlice(self.allocator, &bytes);
    }

    /// Register a string literal and return its offset in the data section
    fn registerStringLiteral(self: *NativeCodegen, str: []const u8) !usize {
        // Reject unreasonably large strings so we don't silently produce
        // a colliding offset 0 (which overlaps the first real string).
        if (str.len > 10 * 1024 * 1024) {
            return error.CodegenFailed;
        }

        // Check if we've already seen this string
        if (self.string_offsets.get(str)) |offset| {
            return offset;
        }

        // Calculate offset in data section
        var offset: usize = 0;
        for (self.string_literals.items) |existing_str| {
            offset += existing_str.len + 1; // +1 for null terminator
        }

        // Store the string and its offset
        try self.string_literals.append(self.allocator, str);
        try self.string_offsets.put(str, offset);

        return offset;
    }

    /// Total byte count of the data section: string literals (with
    /// NUL terminators) followed by binary data literals (vtables,
    /// comptime arrays and structs).
    fn getDataSectionSize(self: *NativeCodegen) usize {
        var size: usize = 0;
        for (self.string_literals.items) |str| {
            size += str.len + 1;
        }
        size += self.data_literals_offset;
        return size;
    }

    /// Register a comptime array literal and return its offset in the data section
    /// Serializes the array elements to binary format for direct memory access
    fn registerArrayLiteral(self: *NativeCodegen, elements: []const ComptimeValue) !usize {
        // Calculate total size needed: 8 bytes per element (i64/f64/pointer)
        const elem_size: usize = 8;
        const total_size = elements.len * elem_size;

        // Allocate buffer for serialized data
        var data = try self.allocator.alloc(u8, total_size);
        errdefer self.allocator.free(data);

        // Serialize each element
        for (elements, 0..) |elem, i| {
            const offset = i * elem_size;
            switch (elem) {
                .int => |int_val| {
                    const bytes = std.mem.toBytes(@as(i64, int_val));
                    @memcpy(data[offset..][0..8], &bytes);
                },
                .float => |float_val| {
                    const bytes = std.mem.toBytes(@as(f64, float_val));
                    @memcpy(data[offset..][0..8], &bytes);
                },
                .bool => |bool_val| {
                    const bytes = std.mem.toBytes(@as(i64, if (bool_val) 1 else 0));
                    @memcpy(data[offset..][0..8], &bytes);
                },
                .@"null", .@"undefined" => {
                    @memset(data[offset..][0..8], 0);
                },
                else => {
                    // For complex types (nested arrays, structs, strings), use 0 placeholder
                    @memset(data[offset..][0..8], 0);
                },
            }
        }

        // Calculate offset: after all strings + any previous data literals
        const string_section_size = self.getDataSectionSize();
        const data_offset = string_section_size + self.data_literals_offset;

        // Store the data and update offset tracker
        try self.data_literals.append(self.allocator, data);
        self.data_literals_offset += total_size;

        return data_offset;
    }

    /// Register a comptime struct literal and return its offset in the data section
    /// Serializes the struct fields to binary format for direct memory access
    fn registerStructLiteral(self: *NativeCodegen, fields: *const std.StringHashMap(ComptimeValue)) !usize {
        // Calculate total size: 8 bytes per field (simple layout)
        const field_size: usize = 8;
        const total_size = fields.count() * field_size;

        if (total_size == 0) {
            // Empty struct, return current offset
            return self.getDataSectionSize() + self.data_literals_offset;
        }

        // Allocate buffer for serialized data
        var data = try self.allocator.alloc(u8, total_size);
        errdefer self.allocator.free(data);

        // Serialize fields (in iteration order - not ideal but consistent)
        var field_iter = fields.iterator();
        var field_idx: usize = 0;
        while (field_iter.next()) |entry| {
            const offset = field_idx * field_size;
            const value = entry.value_ptr.*;

            switch (value) {
                .int => |int_val| {
                    const bytes = std.mem.toBytes(@as(i64, int_val));
                    @memcpy(data[offset..][0..8], &bytes);
                },
                .float => |float_val| {
                    const bytes = std.mem.toBytes(@as(f64, float_val));
                    @memcpy(data[offset..][0..8], &bytes);
                },
                .bool => |bool_val| {
                    const bytes = std.mem.toBytes(@as(i64, if (bool_val) 1 else 0));
                    @memcpy(data[offset..][0..8], &bytes);
                },
                .@"null", .@"undefined" => {
                    @memset(data[offset..][0..8], 0);
                },
                else => {
                    // For complex types, use 0 placeholder
                    @memset(data[offset..][0..8], 0);
                },
            }
            field_idx += 1;
        }

        // Calculate offset: after all strings + any previous data literals
        const string_section_size = self.getDataSectionSize();
        const data_offset = string_section_size + self.data_literals_offset;

        // Store the data and update offset tracker
        try self.data_literals.append(self.allocator, data);
        self.data_literals_offset += total_size;

        return data_offset;
    }

    /// Check if a match statement is exhaustive
    /// Returns error if match is non-exhaustive
    /// Helper function to recursively check pattern exhaustiveness
    fn checkPatternExhaustiveness(
        self: *NativeCodegen,
        pattern: *ast.Pattern,
        covered_variants: *std.ArrayList([]const u8),
        match_enum_name: *?[]const u8,
        has_wildcard: *bool,
    ) CodegenError!void {
        switch (pattern.*) {
            .Identifier => |name| {
                // Check if it's an enum variant or variable binding
                var is_enum_variant = false;
                var enum_iter = self.enum_layouts.iterator();
                while (enum_iter.next()) |entry| {
                    const enum_name = entry.key_ptr.*;
                    const enum_layout = entry.value_ptr.*;
                    for (enum_layout.variants) |v| {
                        if (std.mem.eql(u8, v.name, name)) {
                            is_enum_variant = true;
                            match_enum_name.* = enum_name;
                            try covered_variants.append(self.allocator, name);
                            break;
                        }
                    }
                    if (is_enum_variant) break;
                }
                if (!is_enum_variant) {
                    // It's a variable binding, which is a catch-all
                    has_wildcard.* = true;
                }
            },
            .EnumVariant => |ev| {
                // Track covered variant
                try covered_variants.append(self.allocator, ev.variant);
                // Determine which enum this belongs to
                if (match_enum_name.* == null) {
                    var enum_iter = self.enum_layouts.iterator();
                    while (enum_iter.next()) |entry| {
                        const enum_name = entry.key_ptr.*;
                        const enum_layout = entry.value_ptr.*;
                        for (enum_layout.variants) |v| {
                            if (std.mem.eql(u8, v.name, ev.variant)) {
                                match_enum_name.* = enum_name;
                                break;
                            }
                        }
                        if (match_enum_name.* != null) break;
                    }
                }
            },
            .Wildcard => {
                has_wildcard.* = true;
            },
            .Or => |or_patterns| {
                // For Or patterns, recursively check all alternatives
                for (or_patterns) |alt_pattern| {
                    try self.checkPatternExhaustiveness(alt_pattern, covered_variants, match_enum_name, has_wildcard);
                }
            },
            .As => |as_pattern| {
                // For As patterns, check the inner pattern
                // The binding itself is a catch-all if it binds a variable
                try self.checkPatternExhaustiveness(as_pattern.pattern, covered_variants, match_enum_name, has_wildcard);
            },
            else => {
                // Other patterns don't contribute to exhaustiveness checking
            },
        }
    }

    /// Walks a match statement and decides whether codegen must emit a
    /// runtime fall-through panic. Returns `true` when the match is
    /// provably exhaustive (has a wildcard / variable binding, or covers
    /// every variant of the scrutinized enum). Also emits warnings for
    /// uncovered enum variants as a side effect.
    fn checkMatchExhaustiveness(self: *NativeCodegen, match_stmt: *ast.MatchStmt) CodegenError!bool {
        // Check if there's a wildcard pattern (catch-all)
        var has_wildcard = false;
        for (match_stmt.arms) |arm| {
            if (arm.pattern.* == .Wildcard) {
                has_wildcard = true;
                break;
            }
        }

        // Check for variable binding patterns (also catch-all)
        // and collect covered enum variants
        var covered_variants = std.ArrayList([]const u8).empty;
        defer covered_variants.deinit(self.allocator);

        var match_enum_name: ?[]const u8 = null;

        for (match_stmt.arms) |arm| {
            try self.checkPatternExhaustiveness(arm.pattern, &covered_variants, &match_enum_name, &has_wildcard);
        }

        if (has_wildcard) {
            // Match is exhaustive
            return true;
        }

        // If we identified an enum type, check if all variants are covered
        if (match_enum_name) |enum_name| {
            if (self.enum_layouts.get(enum_name)) |enum_layout| {
                // Check if all variants are covered
                var all_covered = true;
                var missing_variants = std.ArrayList([]const u8).empty;
                defer missing_variants.deinit(self.allocator);

                for (enum_layout.variants) |variant| {
                    var found = false;
                    for (covered_variants.items) |covered| {
                        if (std.mem.eql(u8, variant.name, covered)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        all_covered = false;
                        try missing_variants.append(self.allocator, variant.name);
                    }
                }

                if (!all_covered) {
                    std.debug.print("Warning: non-exhaustive pattern match on enum '{s}'\n", .{enum_name});
                    std.debug.print("Missing variants:\n", .{});
                    for (missing_variants.items) |variant| {
                        std.debug.print("  - {s}\n", .{variant});
                    }
                    std.debug.print("Consider adding a wildcard pattern '_' to handle all cases\n", .{});

                    // In strict mode this is a hard error: matching on an
                    // enum without covering every variant is usually a
                    // programming mistake — at runtime the codegen would
                    // fall through the match block and produce 0, which
                    // looks like a legitimate default in numeric contexts
                    // but is really "unhandled case".
                    if (self.strict_exhaustive_matches) {
                        return error.UnsupportedFeature;
                    }
                }
                // Exhaustive iff every variant is covered.
                return all_covered;
            }
        }
        // We couldn't determine the scrutinized enum type (e.g. matching
        // on a raw int). Without a wildcard, treat as non-exhaustive so
        // the codegen inserts a runtime fall-through panic.
        return false;
    }

    /// Generate pattern matching code
    /// Returns: pattern match result in rax (1 if matched, 0 if not matched)
    /// value_reg: register containing the value to match against
    /// Emit the three-instruction pattern-match result sequence:
    ///   mov rax, 0         (assume no match)
    ///   jne <skip>          (skip the mov-1 when the compare fails)
    ///   mov rax, 1         (match succeeded)
    /// Uses position-based patching so the offset adapts if the
    /// encoding of movRegImm64 ever changes.
    fn emitCmpResult(self: *NativeCodegen) !void {
        try self.assembler.movRegImm64(.rax, 0);
        const jne_pos = self.assembler.getPosition();
        try self.assembler.jneRel32(0);
        try self.assembler.movRegImm64(.rax, 1);
        const after = self.assembler.getPosition();
        try self.assembler.patchJneRel32(jne_pos, @as(i32, @intCast(after)) - @as(i32, @intCast(jne_pos + 6)));
    }

    fn generatePatternMatch(self: *NativeCodegen, pattern: ast.Pattern, value_reg: x64.Register) CodegenError!void {
        switch (pattern) {
            .IntLiteral => |int_val| {
                // Compare value with literal
                // Save value_reg if it's a register we need to use
                const needs_save = (value_reg == .rcx or value_reg == .rdx);
                const saved_reg: x64.Register = if (value_reg == .rcx) .r11 else .r12;

                if (needs_save) {
                    try self.assembler.movRegReg(saved_reg, value_reg);
                }

                // Use rdx as temp register
                try self.assembler.movRegImm64(.rdx, @intCast(int_val));
                // Compare
                const cmp_reg = if (needs_save) saved_reg else value_reg;
                try self.assembler.cmpRegReg(cmp_reg, .rdx);
                try self.emitCmpResult();
            },
            .BoolLiteral => |bool_val| {
                // Compare value with boolean (0 or 1)
                const int_val: i64 = if (bool_val) 1 else 0;
                try self.assembler.movRegImm64(.rcx, @intCast(int_val));
                try self.assembler.cmpRegReg(value_reg, .rcx);
                try self.emitCmpResult();
            },
            .FloatLiteral => |float_val| {
                // Compare value with float literal
                // value_reg contains the float value as a u64 bit pattern
                // Convert the float pattern literal to u64 bit pattern
                const float_bits: u64 = @bitCast(float_val);

                // Save value_reg if it's a register we need to use
                const needs_save = (value_reg == .rcx or value_reg == .rdx);
                const saved_reg: x64.Register = if (value_reg == .rcx) .r11 else .r12;

                if (needs_save) {
                    try self.assembler.movRegReg(saved_reg, value_reg);
                }

                // Load expected float bits into rdx
                try self.assembler.movRegImm64(.rdx, @bitCast(float_bits));

                // Compare
                const cmp_reg = if (needs_save) saved_reg else value_reg;
                try self.assembler.cmpRegReg(cmp_reg, .rdx);

                try self.emitCmpResult();
            },
            .StringLiteral => |str_val| {
                // String comparison - compare the string values
                // value_reg contains pointer to the runtime string value
                // str_val is the pattern string literal

                // Save value_reg to avoid clobbering
                try self.assembler.movRegReg(.rsi, value_reg); // rsi = runtime string

                // Register the pattern string in the data section
                const str_offset = try self.registerStringLiteral(str_val);

                // Get address of pattern string in rdi using LEA with RIP-relative addressing
                // This returns the position where we need to patch the offset later
                const lea_pos = try self.assembler.leaRipRel(.rdi, 0);

                // Track this fixup for later patching
                try self.string_fixups.append(self.allocator, .{
                    .code_pos = lea_pos,
                    .data_offset = str_offset,
                });

                // Compare pattern string (in rdi) with runtime string (in rsi)
                try self.strcmp(.rdi, .rsi); // Result in rax: 0 if equal

                // Convert strcmp result to match result
                // If strcmp returns 0, strings are equal -> match success (rax = 1)
                // If strcmp returns non-zero, strings differ -> match fail (rax = 0)
                try self.assembler.testRegReg(.rax, .rax);
                try self.emitCmpResult();
            },
            .Wildcard => {
                // Wildcard always matches
                try self.assembler.movRegImm64(.rax, 1);
            },
            .Identifier => |ident_name| {
                // Check if this identifier is actually an enum variant name
                // If so, treat it as an EnumVariant pattern with no payload
                var is_enum_variant = false;
                var target_tag: i64 = 0;

                var enum_iter = self.enum_layouts.iterator();
                while (enum_iter.next()) |entry| {
                    const enum_layout = entry.value_ptr.*;
                    for (enum_layout.variants, 0..) |v, idx| {
                        if (std.mem.eql(u8, v.name, ident_name)) {
                            is_enum_variant = true;
                            target_tag = @intCast(idx);
                            break;
                        }
                    }
                    if (is_enum_variant) break;
                }

                if (is_enum_variant) {
                    // Treat as EnumVariant pattern with no payload
                    // value_reg contains pointer to enum
                    // Load tag from memory (first 8 bytes)
                    try self.assembler.movRegMem(.rcx, value_reg, 0);
                    // Load expected tag
                    try self.assembler.movRegImm64(.rdx, @intCast(target_tag));
                    // Compare
                    try self.assembler.cmpRegReg(.rcx, .rdx);
                    try self.emitCmpResult();
                } else {
                    // Regular identifier pattern - always matches and binds the value
                    // Variable binding is implemented in bindPatternVariables()
                    try self.assembler.movRegImm64(.rax, 1);
                }
            },
            .EnumVariant => |variant| {
                // For enum variants, check the tag (first 8 bytes)
                // value_reg contains pointer to enum value
                // Enum layout: [tag (8 bytes)][data (8 bytes)]
                // Tag is at offset 0

                // Extract enum name from variant string (format: "EnumName.VariantName")
                // For now, we need to infer the enum type from context
                // This is a limitation - ideally we'd have type information

                // Try to find matching enum layout and variant
                var found = false;
                var target_tag: i64 = 0;

                // Iterate through all enum layouts
                var enum_iter = self.enum_layouts.iterator();
                while (enum_iter.next()) |entry| {
                    const enum_layout = entry.value_ptr.*;
                    // Check if variant exists in this enum
                    for (enum_layout.variants, 0..) |v, idx| {
                        if (std.mem.eql(u8, v.name, variant.variant)) {
                            found = true;
                            target_tag = @intCast(idx);
                            break;
                        }
                    }
                    if (found) break;
                }

                if (found) {
                    // Load tag from memory (first 8 bytes at value_reg)
                    // value_reg contains the pointer to the enum value
                    try self.assembler.movRegMem(.rcx, value_reg, 0); // Load tag into rcx
                    // Compare with expected tag
                    try self.assembler.movRegImm64(.rdx, @intCast(target_tag));
                    try self.assembler.cmpRegReg(.rcx, .rdx);

                    // If tags don't match, set rax=0 and skip payload check
                    const tag_mismatch_pos = self.assembler.getPosition();
                    try self.assembler.jeRel32(0); // Jump if equal (tag matches), placeholder offset

                    // Tag didn't match
                    try self.assembler.movRegImm64(.rax, 0);
                    const skip_pos = self.assembler.getPosition();
                    try self.assembler.jmpRel32(0); // Jump to end, placeholder offset

                    // Patch tag match jump to here
                    const tag_match_pos = self.assembler.getPosition();
                    const tag_match_offset = @as(i32, @intCast(tag_match_pos)) - @as(i32, @intCast(tag_mismatch_pos + 6));
                    try self.assembler.patchJeRel32(tag_mismatch_pos, tag_match_offset);

                    // Tag matched! Now check payload pattern if present
                    if (variant.payload) |payload_pattern| {
                        // Load the payload data (at offset 8) into rcx
                        try self.assembler.movRegMem(.rcx, value_reg, 8);

                        // Recursively match the payload pattern
                        try self.generatePatternMatch(payload_pattern.*, .rcx);
                        // rax now contains payload match result (0 or 1)
                    } else {
                        // No payload pattern, just tag match = success
                        try self.assembler.movRegImm64(.rax, 1);
                    }

                    // Patch skip jump to here (end of match logic)
                    const end_pos = self.assembler.getPosition();
                    const skip_offset = @as(i32, @intCast(end_pos)) - @as(i32, @intCast(skip_pos + 5));
                    try self.assembler.patchJmpRel32(skip_pos, skip_offset);
                } else {
                    // Variant not found in any enum - no match
                    try self.assembler.movRegImm64(.rax, 0);
                }
            },
            .Tuple => |tuple_patterns| {
                // Tuple pattern: (a, b, c)
                // value_reg contains pointer to tuple
                // Tuple layout: [count][elem0][elem1][elem2]...

                // Load element count from tuple
                try self.assembler.movRegMem(.rcx, value_reg, 0);

                // Check if tuple has expected number of elements
                try self.assembler.movRegImm64(.rdx, @intCast(tuple_patterns.len));
                try self.assembler.cmpRegReg(.rcx, .rdx);

                // If count doesn't match, pattern fails
                try self.assembler.movRegImm64(.rax, 0); // Assume no match
                const count_mismatch_pos = self.assembler.getPosition();
                try self.assembler.jneRel32(0); // Jump if not equal

                // Count matches! Now check each element pattern
                // Track jump positions for element failures
                var elem_fail_jumps = std.ArrayList(usize).empty;
                defer elem_fail_jumps.deinit(self.allocator);

                for (tuple_patterns, 0..) |elem_pattern, i| {
                    // Load element i from tuple at offset (i+1)*8
                    const offset: i32 = @intCast((i + 1) * 8);
                    try self.assembler.movRegMem(.rbx, value_reg, offset);

                    // Recursively match the element pattern
                    try self.generatePatternMatch(elem_pattern.*, .rbx);

                    // If this element didn't match, whole tuple pattern fails
                    try self.assembler.testRegReg(.rax, .rax);
                    const elem_fail_pos = self.assembler.getPosition();
                    try self.assembler.jzRel32(0); // Jump if zero (pattern failed)
                    try elem_fail_jumps.append(self.allocator, elem_fail_pos);
                }

                // All elements matched! Set success
                try self.assembler.movRegImm64(.rax, 1);
                const success_jump_pos = self.assembler.getPosition();
                try self.assembler.jmpRel32(0); // Jump to end

                // Patch count mismatch and all element failure jumps to here
                const fail_pos = self.assembler.getPosition();

                // Patch count mismatch
                const count_offset = @as(i32, @intCast(fail_pos)) - @as(i32, @intCast(count_mismatch_pos + 6));
                try self.assembler.patchJneRel32(count_mismatch_pos, count_offset);

                // Patch all element failure jumps
                for (elem_fail_jumps.items) |jump_pos| {
                    const offset = @as(i32, @intCast(fail_pos)) - @as(i32, @intCast(jump_pos + 6));
                    try self.assembler.patchJzRel32(jump_pos, offset);
                }

                // Set failure result
                try self.assembler.movRegImm64(.rax, 0);

                // Patch success jump to here (end)
                const end_pos = self.assembler.getPosition();
                const success_offset = @as(i32, @intCast(end_pos)) - @as(i32, @intCast(success_jump_pos + 5));
                try self.assembler.patchJmpRel32(success_jump_pos, success_offset);
            },
            .Array => |array_pattern| {
                // Array layout: [count][elem0][elem1][elem2]...
                // Similar to tuple, but supports rest pattern

                // Load element count from array
                try self.assembler.movRegMem(.rcx, value_reg, 0);

                // Check array length based on rest pattern
                if (array_pattern.rest) |_| {
                    // With rest pattern: array must have AT LEAST this many elements
                    try self.assembler.movRegImm64(.rdx, @intCast(array_pattern.elements.len));
                    try self.assembler.cmpRegReg(.rcx, .rdx);

                    // If array is shorter, pattern fails
                    try self.assembler.movRegImm64(.rax, 0);
                    const too_short_pos = self.assembler.getPosition();
                    try self.assembler.jlRel32(0); // Jump if less than

                    // Array is long enough! Match the fixed elements
                    var elem_fail_jumps = std.ArrayList(usize).empty;
                    defer elem_fail_jumps.deinit(self.allocator);

                    for (array_pattern.elements, 0..) |elem_pattern, i| {
                        const offset: i32 = @intCast((i + 1) * 8);
                        try self.assembler.movRegMem(.rbx, value_reg, offset);
                        try self.generatePatternMatch(elem_pattern.*, .rbx);
                        try self.assembler.testRegReg(.rax, .rax);
                        const elem_fail_pos = self.assembler.getPosition();
                        try self.assembler.jzRel32(0);
                        try elem_fail_jumps.append(self.allocator, elem_fail_pos);
                    }

                    // All elements matched!
                    try self.assembler.movRegImm64(.rax, 1);
                    const success_jump_pos = self.assembler.getPosition();
                    try self.assembler.jmpRel32(0);

                    // Patch too_short and element failures
                    const fail_pos = self.assembler.getPosition();
                    const too_short_offset = @as(i32, @intCast(fail_pos)) - @as(i32, @intCast(too_short_pos + 6));
                    try self.assembler.patchJlRel32(too_short_pos, too_short_offset);

                    for (elem_fail_jumps.items) |jump_pos| {
                        const offset = @as(i32, @intCast(fail_pos)) - @as(i32, @intCast(jump_pos + 6));
                        try self.assembler.patchJzRel32(jump_pos, offset);
                    }

                    try self.assembler.movRegImm64(.rax, 0);

                    const end_pos = self.assembler.getPosition();
                    const success_offset = @as(i32, @intCast(end_pos)) - @as(i32, @intCast(success_jump_pos + 5));
                    try self.assembler.patchJmpRel32(success_jump_pos, success_offset);
                } else {
                    // No rest pattern: exact length match required
                    try self.assembler.movRegImm64(.rdx, @intCast(array_pattern.elements.len));
                    try self.assembler.cmpRegReg(.rcx, .rdx);

                    try self.assembler.movRegImm64(.rax, 0);
                    const count_mismatch_pos = self.assembler.getPosition();
                    try self.assembler.jneRel32(0);

                    var elem_fail_jumps = std.ArrayList(usize).empty;
                    defer elem_fail_jumps.deinit(self.allocator);

                    for (array_pattern.elements, 0..) |elem_pattern, i| {
                        const offset: i32 = @intCast((i + 1) * 8);
                        try self.assembler.movRegMem(.rbx, value_reg, offset);
                        try self.generatePatternMatch(elem_pattern.*, .rbx);
                        try self.assembler.testRegReg(.rax, .rax);
                        const elem_fail_pos = self.assembler.getPosition();
                        try self.assembler.jzRel32(0);
                        try elem_fail_jumps.append(self.allocator, elem_fail_pos);
                    }

                    try self.assembler.movRegImm64(.rax, 1);
                    const success_jump_pos = self.assembler.getPosition();
                    try self.assembler.jmpRel32(0);

                    const fail_pos = self.assembler.getPosition();
                    const count_offset = @as(i32, @intCast(fail_pos)) - @as(i32, @intCast(count_mismatch_pos + 6));
                    try self.assembler.patchJneRel32(count_mismatch_pos, count_offset);

                    for (elem_fail_jumps.items) |jump_pos| {
                        const offset = @as(i32, @intCast(fail_pos)) - @as(i32, @intCast(jump_pos + 6));
                        try self.assembler.patchJzRel32(jump_pos, offset);
                    }

                    try self.assembler.movRegImm64(.rax, 0);

                    const end_pos = self.assembler.getPosition();
                    const success_offset = @as(i32, @intCast(end_pos)) - @as(i32, @intCast(success_jump_pos + 5));
                    try self.assembler.patchJmpRel32(success_jump_pos, success_offset);
                }
            },
            .Struct => |struct_pattern| {
                // Struct pattern: Point { x, y } or Point { x: 10, y }
                // value_reg points to struct instance in memory

                // Look up the struct layout
                const struct_layout = self.struct_layouts.get(struct_pattern.name) orelse {
                    std.debug.print("Unknown struct type: {s}\n", .{struct_pattern.name});
                    return error.UnknownStructType;
                };

                // Check each field pattern
                var field_fail_jumps = std.ArrayList(usize).empty;
                defer field_fail_jumps.deinit(self.allocator);

                for (struct_pattern.fields) |field_pattern| {
                    // Find the field info in the layout
                    var field_info: ?FieldInfo = null;
                    for (struct_layout.fields) |fi| {
                        if (std.mem.eql(u8, fi.name, field_pattern.name)) {
                            field_info = fi;
                            break;
                        }
                    }

                    if (field_info == null) {
                        std.debug.print("Unknown field '{s}' in struct '{s}'\n", .{ field_pattern.name, struct_pattern.name });
                        return error.UnknownField;
                    }

                    const fi = field_info.?;

                    // Load the field value from struct at offset
                    const offset: i32 = @intCast(fi.offset);
                    try self.assembler.movRegMem(.rbx, value_reg, offset);

                    // Recursively match the field pattern
                    try self.generatePatternMatch(field_pattern.pattern.*, .rbx);

                    // If this field didn't match, whole struct pattern fails
                    try self.assembler.testRegReg(.rax, .rax);
                    const field_fail_pos = self.assembler.getPosition();
                    try self.assembler.jzRel32(0);
                    try field_fail_jumps.append(self.allocator, field_fail_pos);
                }

                // All fields matched!
                try self.assembler.movRegImm64(.rax, 1);
                const success_jump_pos = self.assembler.getPosition();
                try self.assembler.jmpRel32(0);

                // Patch all field failure jumps to here
                const fail_pos = self.assembler.getPosition();
                for (field_fail_jumps.items) |jump_pos| {
                    const offset = @as(i32, @intCast(fail_pos)) - @as(i32, @intCast(jump_pos + 6));
                    try self.assembler.patchJzRel32(jump_pos, offset);
                }

                try self.assembler.movRegImm64(.rax, 0);

                const end_pos = self.assembler.getPosition();
                const success_offset = @as(i32, @intCast(end_pos)) - @as(i32, @intCast(success_jump_pos + 5));
                try self.assembler.patchJmpRel32(success_jump_pos, success_offset);
            },
            .As => |as_pattern| {
                // As pattern: pattern @ identifier
                // First match the inner pattern, then bind the whole value to identifier
                // The binding happens in bindPatternVariables(), here we just match
                try self.generatePatternMatch(as_pattern.pattern.*, value_reg);
                // Result is already in rax from the inner pattern match
            },
            .Or => |or_patterns| {
                // Or pattern: pattern1 | pattern2 | pattern3
                // Try each pattern until one matches
                // value_reg contains the value to match against

                if (or_patterns.len == 0) {
                    // Empty or pattern always fails
                    try self.assembler.movRegImm64(.rax, 0);
                    return;
                }

                // Track jump positions for successful matches
                var success_jumps = std.ArrayList(usize).empty;
                defer success_jumps.deinit(self.allocator);

                // Try each alternative pattern
                for (or_patterns, 0..) |alt_pattern, i| {
                    // Try to match this alternative
                    try self.generatePatternMatch(alt_pattern.*, value_reg);

                    // Test if this alternative matched
                    try self.assembler.testRegReg(.rax, .rax);

                    if (i == or_patterns.len - 1) {
                        // Last alternative - result is already in rax, we're done
                        break;
                    } else {
                        // Not the last alternative - jump to success if matched
                        const success_jump = self.assembler.getPosition();
                        try self.assembler.jnzRel32(0); // Jump if not zero (pattern matched)
                        try success_jumps.append(self.allocator, success_jump);
                    }
                }

                // Patch all success jumps to here (end of Or pattern)
                const end_pos = self.assembler.getPosition();
                for (success_jumps.items) |jump_pos| {
                    const offset = @as(i32, @intCast(end_pos)) - @as(i32, @intCast(jump_pos + 6));
                    try self.assembler.patchJnzRel32(jump_pos, offset);
                }
            },
            .Range => |range_pattern| {
                // Range pattern: start..end or start..=end
                // value_reg contains the value to check
                // We need to evaluate start and end expressions and check if value is in range

                // Save value_reg to r10 (we'll need it for comparisons)
                try self.assembler.movRegReg(.r10, value_reg);

                // Evaluate start expression
                try self.generateExpr(range_pattern.start);
                // start value is now in rax, move to r11
                try self.assembler.movRegReg(.r11, .rax);

                // Evaluate end expression
                try self.generateExpr(range_pattern.end);
                // end value is now in rax, move to r12
                try self.assembler.movRegReg(.r12, .rax);

                // Now check if r10 (value) is in range [r11, r12]
                // First check: value >= start
                try self.assembler.cmpRegReg(.r10, .r11);
                const too_small_jump = self.assembler.getPosition();
                try self.assembler.jlRel32(0); // Jump if less than

                // Second check: value <= end (or value < end for exclusive range)
                try self.assembler.cmpRegReg(.r10, .r12);
                const too_large_jump = self.assembler.getPosition();
                if (range_pattern.inclusive) {
                    try self.assembler.jgRel32(0); // Jump if greater than (inclusive)
                } else {
                    try self.assembler.jgeRel32(0); // Jump if greater or equal (exclusive)
                }

                // Value is in range! Set rax = 1
                try self.assembler.movRegImm64(.rax, 1);
                const success_jump = self.assembler.getPosition();
                try self.assembler.jmpRel32(0); // Jump to end

                // Patch failure jumps to here
                const fail_pos = self.assembler.getPosition();
                const too_small_offset = @as(i32, @intCast(fail_pos)) - @as(i32, @intCast(too_small_jump + 6));
                try self.assembler.patchJlRel32(too_small_jump, too_small_offset);

                const too_large_offset = @as(i32, @intCast(fail_pos)) - @as(i32, @intCast(too_large_jump + 6));
                if (range_pattern.inclusive) {
                    try self.assembler.patchJgRel32(too_large_jump, too_large_offset);
                } else {
                    try self.assembler.patchJgeRel32(too_large_jump, too_large_offset);
                }

                // Value is not in range, set rax = 0
                try self.assembler.movRegImm64(.rax, 0);

                // Patch success jump to here (end)
                const end_pos = self.assembler.getPosition();
                const success_offset = @as(i32, @intCast(end_pos)) - @as(i32, @intCast(success_jump + 5));
                try self.assembler.patchJmpRel32(success_jump, success_offset);
            },
        }
    }

    /// Generate pattern matching code for expression-based patterns (used in MatchExpr)
    /// Returns: pattern match result in rax (1 if matched, 0 if not matched)
    /// value_reg: register containing the value to match against
    fn generateExprAsPatternMatch(self: *NativeCodegen, pattern_expr: *ast.Expr, value_reg: x64.Register) CodegenError!void {
        switch (pattern_expr.*) {
            .IntegerLiteral => |int_lit| {
                // Compare value with literal
                const needs_save = (value_reg == .rcx or value_reg == .rdx);
                const saved_reg: x64.Register = if (value_reg == .rcx) .r11 else .r12;

                if (needs_save) {
                    try self.assembler.movRegReg(saved_reg, value_reg);
                }

                // Use rdx as temp register
                try self.assembler.movRegImm64(.rdx, int_lit.value);
                // Compare
                const cmp_reg = if (needs_save) saved_reg else value_reg;
                try self.assembler.cmpRegReg(cmp_reg, .rdx);
                try self.emitCmpResult();
            },
            .Identifier => |ident| {
                // Check if this is a wildcard (_)
                if (std.mem.eql(u8, ident.name, "_")) {
                    // Wildcard always matches
                    try self.assembler.movRegImm64(.rax, 1);
                    return;
                }

                // Check if this identifier is an enum variant
                var is_enum_variant = false;
                var enum_tag: i64 = 0;
                var enum_iter = self.enum_layouts.iterator();
                while (enum_iter.next()) |entry| {
                    const enum_layout = entry.value_ptr.*;
                    for (enum_layout.variants, 0..) |v, idx| {
                        if (std.mem.eql(u8, v.name, ident.name)) {
                            is_enum_variant = true;
                            enum_tag = @intCast(idx);
                            break;
                        }
                    }
                    if (is_enum_variant) break;
                }

                if (is_enum_variant) {
                    // Compare enum tag
                    const needs_save = (value_reg == .rcx or value_reg == .rdx);
                    const saved_reg: x64.Register = if (value_reg == .rcx) .r11 else .r12;

                    if (needs_save) {
                        try self.assembler.movRegReg(saved_reg, value_reg);
                    }

                    // Load tag from enum value (first 8 bytes)
                    const enum_reg = if (needs_save) saved_reg else value_reg;
                    try self.assembler.movRegMem(.rcx, enum_reg, 0);
                    // Compare with expected tag
                    try self.assembler.movRegImm64(.rdx, enum_tag);
                    try self.assembler.cmpRegReg(.rcx, .rdx);
                    try self.emitCmpResult();
                } else {
                    try self.assembler.movRegImm64(.rax, 1);
                }
            },
            .MemberExpr => |member_expr| {
                // Handle patterns like Effect::Explosion (module::variant or enum::variant)
                // The object is the enum type name, member is the variant name

                // Check if this is an enum variant reference
                if (member_expr.object.* == .Identifier) {
                    const enum_name = member_expr.object.Identifier.name;
                    const variant_name = member_expr.member;

                    var is_enum_variant = false;
                    var enum_tag: i64 = 0;

                    // First try local enum_layouts
                    var enum_iter = self.enum_layouts.iterator();
                    while (enum_iter.next()) |entry| {
                        const layout_enum_name = entry.key_ptr.*;
                        const enum_layout = entry.value_ptr.*;

                        // Check if this is the right enum
                        if (std.mem.eql(u8, layout_enum_name, enum_name)) {
                            // Find the variant
                            for (enum_layout.variants, 0..) |v, idx| {
                                if (std.mem.eql(u8, v.name, variant_name)) {
                                    is_enum_variant = true;
                                    enum_tag = @intCast(idx);
                                    break;
                                }
                            }
                            break;
                        }
                    }

                    // If not found locally, check global type registry
                    if (!is_enum_variant) {
                        if (self.type_registry) |registry| {
                            if (registry.getEnum(enum_name)) |enum_layout| {
                                // Find the variant in the global layout
                                for (enum_layout.variants, 0..) |v, idx| {
                                    if (std.mem.eql(u8, v.name, variant_name)) {
                                        is_enum_variant = true;
                                        enum_tag = @intCast(idx);
                                        break;
                                    }
                                }
                            }
                        }
                    }

                    if (is_enum_variant) {
                        // Compare enum tag
                        const needs_save = (value_reg == .rcx or value_reg == .rdx);
                        const saved_reg: x64.Register = if (value_reg == .rcx) .r11 else .r12;

                        if (needs_save) {
                            try self.assembler.movRegReg(saved_reg, value_reg);
                        }

                        // Load tag from enum value (first 8 bytes)
                        const enum_reg = if (needs_save) saved_reg else value_reg;
                        try self.assembler.movRegMem(.rcx, enum_reg, 0);
                        // Compare with expected tag
                        try self.assembler.movRegImm64(.rdx, enum_tag);
                        try self.assembler.cmpRegReg(.rcx, .rdx);
                        // Set rax based on comparison
                        try self.emitCmpResult();
                    } else {
                        std.debug.print("Unknown enum variant in pattern: {s}::{s}\n", .{enum_name, variant_name});
                        try self.assembler.movRegImm64(.rax, 0);
                    }
                } else {
                    // Complex nested member expression in a pattern:
                    //   match x { some.module.Variant => ... }
                    // Evaluate it as a normal expression and compare against
                    // `value_reg`. This is the same treatment any literal
                    // pattern receives: we load the pattern's runtime value
                    // and test for equality. If this interpretation is
                    // wrong for a specific case (e.g. the user meant a
                    // binding), the type checker already rejects it.
                    try self.generateExpr(pattern_expr);
                    try self.assembler.cmpRegReg(value_reg, .rax);
                    try self.assembler.seteReg(.rax);
                    try self.assembler.movzxReg64Reg8(.rax, .rax);
                }
            },
            else => {
                // Unrecognised pattern node. This is a hard codegen error
                // rather than a silent 0-match: a pattern we can't compile
                // would previously match nothing at runtime regardless of
                // the scrutinee, turning bugs into wrong-branch execution.
                std.debug.print(
                    "codegen error: unsupported expression in pattern matching: {s}\n",
                    .{@tagName(pattern_expr.*)},
                );
                return error.UnsupportedFeature;
            },
        }
    }

    /// Bind variables from expression-based patterns to locals (used in MatchExpr)
    fn bindExprAsPatternVariables(self: *NativeCodegen, pattern_expr: *ast.Expr, value_reg: x64.Register) CodegenError!void {
        switch (pattern_expr.*) {
            .Identifier => |ident| {
                // Don't bind wildcards
                if (std.mem.eql(u8, ident.name, "_")) {
                    return;
                }

                // Check if this is an enum variant (not a variable binding)
                var is_enum_variant = false;
                var enum_iter = self.enum_layouts.iterator();
                while (enum_iter.next()) |entry| {
                    const enum_layout = entry.value_ptr.*;
                    for (enum_layout.variants) |v| {
                        if (std.mem.eql(u8, v.name, ident.name)) {
                            is_enum_variant = true;
                            break;
                        }
                    }
                    if (is_enum_variant) break;
                }

                if (!is_enum_variant) {
                    // This is a variable binding
                    // Push value onto stack and add to locals
                    try self.assembler.pushReg(value_reg);

                    const offset = self.next_local_offset;
                    self.next_local_offset += 1;

                    // Free old key if variable exists (shadowing)
                    if (self.locals.fetchRemove(ident.name)) |old_entry| {
                        self.allocator.free(old_entry.key);
                    }
                    // Duplicate the name since cleanup will free it
                    const name_copy = try self.allocator.dupe(u8, ident.name);
                    errdefer self.allocator.free(name_copy);

                    // Add to locals
                    try self.locals.put(name_copy, LocalInfo{
                        .offset = offset,
                        .type_name = "int",
                        .size = 8,
                    });
                }
            },
            else => {
                // No variable binding for other expression types
            },
        }
    }

    /// Bind variables from a pattern to locals
    /// value_reg contains the value that was matched
    fn bindPatternVariables(self: *NativeCodegen, pattern: ast.Pattern, value_reg: x64.Register) CodegenError!void {
        switch (pattern) {
            .Identifier => |name| {
                // Check if this identifier is actually an enum variant name
                // If so, don't bind it (it's a pattern match, not a variable binding)
                var is_enum_variant = false;
                var enum_iter = self.enum_layouts.iterator();
                while (enum_iter.next()) |entry| {
                    const enum_layout = entry.value_ptr.*;
                    for (enum_layout.variants) |v| {
                        if (std.mem.eql(u8, v.name, name)) {
                            is_enum_variant = true;
                            break;
                        }
                    }
                    if (is_enum_variant) break;
                }

                if (!is_enum_variant) {
                    // Regular identifier - bind the value to this identifier
                    // Push value onto stack and add to locals
                    try self.assembler.pushReg(value_reg); // Push directly without using rax

                    const offset = self.next_local_offset;
                    self.next_local_offset += 1;

                    // Free old key if variable exists (shadowing)
                    if (self.locals.fetchRemove(name)) |old_entry| {
                        self.allocator.free(old_entry.key);
                    }
                    const name_copy = try self.allocator.dupe(u8, name);
                    errdefer self.allocator.free(name_copy);

                    // Use "int" rather than "i32" as the default type name:
                    // isFloatExpr/inferExprType recognise "int" as the
                    // canonical integer type, so downstream code treats the
                    // binding the same way it would treat a plain `let x`
                    // from an integer expression. The real type is known
                    // only via the scrutinee, which the caller would have
                    // to thread through; this is a best-effort default.
                    try self.locals.put(name_copy, .{
                        .offset = offset,
                        .type_name = "int",
                        .size = 8,
                    });
                }
                // If it's an enum variant, do nothing (no binding needed)
            },
            .EnumVariant => |variant| {
                // If the variant has a payload pattern, bind it
                if (variant.payload) |payload_pattern| {
                    // value_reg points to the enum value
                    // Enum layout: [tag (8 bytes)][data (8 bytes)]
                    // Load the data (at offset 8) and bind it
                    try self.assembler.movRegMem(.rcx, value_reg, 8);
                    // Recursively bind the payload pattern with the data value
                    try self.bindPatternVariables(payload_pattern.*, .rcx);
                }
            },
            .Tuple => |tuple_patterns| {
                // Bind variables from tuple elements
                // value_reg points to tuple: [count][elem0][elem1]...
                for (tuple_patterns, 0..) |elem_pattern, i| {
                    // Load element i from tuple at offset (i+1)*8
                    const offset: i32 = @intCast((i + 1) * 8);
                    try self.assembler.movRegMem(.rcx, value_reg, offset);
                    // Recursively bind the element pattern
                    try self.bindPatternVariables(elem_pattern.*, .rcx);
                }
            },
            .Array => |array_pattern| {
                // Bind variables from array elements
                // value_reg points to array: [count][elem0][elem1]...
                for (array_pattern.elements, 0..) |elem_pattern, i| {
                    // Load element i from array at offset (i+1)*8
                    const offset: i32 = @intCast((i + 1) * 8);
                    try self.assembler.movRegMem(.rcx, value_reg, offset);
                    // Recursively bind the element pattern
                    try self.bindPatternVariables(elem_pattern.*, .rcx);
                }

                // Bind rest pattern if present
                if (array_pattern.rest) |rest_name| {
                    // The rest pattern binds to a sub-array containing remaining elements
                    // Array layout: [count][elem0][elem1]...
                    // We need to create a new array with the remaining elements

                    // Load the original array count into rdx
                    try self.assembler.movRegMem(.rdx, value_reg, 0);

                    // Calculate remaining count = original_count - matched_elements
                    const matched_count: i32 = @intCast(array_pattern.elements.len);
                    try self.assembler.subRegImm32(.rdx, matched_count);

                    // Allocate space for the rest array: (remaining_count + 1) * 8
                    // rcx = (rdx + 1) * 8
                    try self.assembler.movRegReg(.rcx, .rdx);
                    try self.assembler.addRegImm32(.rcx, 1);
                    // try self.assembler.shlRegImm8(.rcx, 3); // multiply by 8

                    // Save registers that might be clobbered by malloc
                    try self.assembler.pushReg(.rdx);
                    try self.assembler.pushReg(value_reg);

                    // Call malloc (size already in rcx)
                    try self.assembler.movRegReg(.rdi, .rcx);
                    // Assume malloc is available as a runtime function
                    try self.assembler.movRegImm64(.rax, @as(i64, @intCast(@intFromPtr(&std.heap.page_allocator))));
                    // try self.assembler.callReg(.rax);

                    // Restore registers
                    const result_reg = .rax; // malloc returns pointer in rax
                    try self.assembler.popReg(value_reg);
                    try self.assembler.popReg(.rdx);

                    // Store the remaining count at offset 0 of the new array
                    try self.assembler.movMemReg(result_reg, 0, .rdx);

                    // Copy the remaining elements
                    // Source offset: (matched_count + 1) * 8
                    const src_offset: i32 = @intCast((array_pattern.elements.len + 1) * 8);

                    // Use rcx as loop counter, r8 as src, r9 as dst
                    try self.assembler.movRegReg(.rcx, .rdx); // loop counter = remaining_count
                    try self.assembler.leaRegMem(.r8, value_reg, src_offset); // src pointer
                    try self.assembler.leaRegMem(.r9, result_reg, 8); // dst pointer (skip count)

                    // Copy loop (if count > 0)
                    const loop_start = self.assembler.getPosition();
                    try self.assembler.testRegReg(.rcx, .rcx);
                    try self.assembler.jzRel32(0); // Placeholder - will be patched
                    const skip_copy = self.assembler.getPosition() - 6;

                    // Copy one element
                    try self.assembler.movRegMem(.r10, .r8, 0);
                    try self.assembler.movMemReg(.r9, 0, .r10);

                    // Advance pointers
                    try self.assembler.addRegImm32(.r8, 8);
                    try self.assembler.addRegImm32(.r9, 8);

                    // Decrement counter and loop
                    try self.assembler.subRegImm32(.rcx, 1);
                    const current_pos = self.assembler.getPosition();
                    const loop_offset = @as(i32, @intCast(@as(i64, @intCast(loop_start)) - @as(i64, @intCast(current_pos + 5))));
                    try self.assembler.jmpRel32(loop_offset);

                    // Skip copy target - patch the jz to jump here
                    const after_loop = self.assembler.getPosition();
                    const skip_offset = @as(i32, @intCast(@as(i64, @intCast(after_loop)) - @as(i64, @intCast(skip_copy + 6))));
                    try self.assembler.patchJzRel32(skip_copy, skip_offset);

                    // Push the result pointer (the new rest array)
                    try self.assembler.pushReg(result_reg);
                    const offset = self.next_local_offset;
                    self.next_local_offset += 1;

                    // Free old key if variable exists (shadowing)
                    if (self.locals.fetchRemove(rest_name)) |old_entry| {
                        self.allocator.free(old_entry.key);
                    }
                    const name_copy = try self.allocator.dupe(u8, rest_name);
                    errdefer self.allocator.free(name_copy);

                    try self.locals.put(name_copy, .{
                        .offset = offset,
                        .type_name = "array",
                        .size = 8,
                    });
                }
            },
            .Struct => |struct_pattern| {
                // Bind variables from struct fields
                // value_reg points to struct instance

                const struct_layout = self.struct_layouts.get(struct_pattern.name) orelse {
                    std.debug.print("Unknown struct type: {s}\n", .{struct_pattern.name});
                    return error.UnknownStructType;
                };

                for (struct_pattern.fields) |field_pattern| {
                    // Find the field info
                    var field_info: ?FieldInfo = null;
                    for (struct_layout.fields) |fi| {
                        if (std.mem.eql(u8, fi.name, field_pattern.name)) {
                            field_info = fi;
                            break;
                        }
                    }

                    if (field_info == null) {
                        std.debug.print("Unknown field '{s}' in struct '{s}'\n", .{ field_pattern.name, struct_pattern.name });
                        return error.UnknownField;
                    }

                    const fi = field_info.?;

                    // Load the field value
                    const offset: i32 = @intCast(fi.offset);
                    try self.assembler.movRegMem(.rcx, value_reg, offset);

                    // Recursively bind the field pattern
                    try self.bindPatternVariables(field_pattern.pattern.*, .rcx);
                }
            },
            .As => |as_pattern| {
                // As pattern: pattern @ identifier
                // First bind the identifier to the whole value
                try self.assembler.pushReg(value_reg);

                const offset = self.next_local_offset;
                self.next_local_offset += 1;

                // Free old key if variable exists (shadowing)
                if (self.locals.fetchRemove(as_pattern.identifier)) |old_entry| {
                    self.allocator.free(old_entry.key);
                }
                const name_copy = try self.allocator.dupe(u8, as_pattern.identifier);
                errdefer self.allocator.free(name_copy);

                try self.locals.put(name_copy, .{
                    .offset = offset,
                    .type_name = "i32", // Default type
                    .size = 8,
                });

                // Then recursively bind variables from the inner pattern
                try self.bindPatternVariables(as_pattern.pattern.*, value_reg);
            },
            // Other pattern types don't bind variables
            .IntLiteral, .FloatLiteral, .StringLiteral, .BoolLiteral, .Wildcard => {},
            .Or => {
                // Or patterns can't bind variables because different alternatives
                // might bind different sets of variables. This is typically enforced
                // at the type-checking stage.
            },
            .Range => {
                // Range patterns (e.g., 1..10) would need special handling
                // For now, ranges are handled at match compilation time
                // by expanding to condition checks
            },
        }
    }

    /// Clean up pattern variables added after a certain point
    /// This removes variables from the locals map and adjusts stack
    /// Preserves rax (the arm body result)
    fn cleanupPatternVariables(self: *NativeCodegen, locals_before: usize) CodegenError!void {
        const locals_after = self.locals.count();
        const vars_to_remove = locals_after - locals_before;

        if (vars_to_remove == 0) return;

        // Discard pattern variables by adjusting stack pointer
        // Pattern vars were pushed onto stack, so add to rsp to discard them
        // This preserves rax (body result)
        const bytes_to_remove = vars_to_remove * 8;
        try self.assembler.addRegImm32(.rsp, @intCast(bytes_to_remove));

        // Reset local offset
        self.next_local_offset -= @intCast(vars_to_remove);

        // Remove from locals HashMap
        // We need to iterate and remove entries added after locals_before
        // Since HashMap doesn't support removal during iteration, collect keys first
        var keys_to_remove = std.ArrayList([]const u8).empty;
        defer keys_to_remove.deinit(self.allocator);

        // locals_before counts how many locals were live before the block we're
        // unwinding. Truncating it to u8 silently corrupts cleanup once a
        // function has > 255 locals — use the checked cast helper so we get a
        // hard error instead of a miscompilation.
        const cutoff = safeIntCast(u8, locals_before) catch {
            std.debug.print(
                "codegen: function exceeds 256 local slots (locals_before={d})\n",
                .{locals_before},
            );
            return error.TooManyVariables;
        };
        var iter = self.locals.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.offset >= cutoff) {
                try keys_to_remove.append(self.allocator, entry.key_ptr.*);
            }
        }

        // Now remove the collected keys
        for (keys_to_remove.items) |key| {
            _ = self.locals.remove(key);
            self.allocator.free(key);
        }
    }

    /// Generate only the stack cleanup code for a given number of pattern variables
    /// Does NOT modify locals map or next_local_offset - only generates machine code
    /// This is needed when guard fails and we need to pop pattern vars before trying next arm
    fn cleanupPatternVariablesCodeOnlyN(self: *NativeCodegen, vars_to_remove: usize) CodegenError!void {
        if (vars_to_remove == 0) return;

        // Discard pattern variables by adjusting stack pointer
        const bytes_to_remove = vars_to_remove * 8;
        try self.assembler.addRegImm32(.rsp, @intCast(bytes_to_remove));
    }

    /// Infer the type of an expression for let declarations
    fn inferExprType(self: *NativeCodegen, expr: *ast.Expr) CodegenError!?[]const u8 {
        switch (expr.*) {
            .StructLiteral => |lit| return lit.type_name,
            .FloatLiteral => return "float",
            .IntegerLiteral => return "int",
            .StringLiteral => return "string",
            .BooleanLiteral => return "bool",
            .BinaryExpr => |binary| {
                // Float if either side is float.
                const left = try self.inferExprType(binary.left);
                if (left) |t| {
                    if (std.mem.eql(u8, t, "float") or std.mem.eql(u8, t, "f64") or
                        std.mem.eql(u8, t, "f32") or std.mem.eql(u8, t, "double"))
                    {
                        return "float";
                    }
                }
                const right = try self.inferExprType(binary.right);
                if (right) |t| {
                    if (std.mem.eql(u8, t, "float") or std.mem.eql(u8, t, "f64") or
                        std.mem.eql(u8, t, "f32") or std.mem.eql(u8, t, "double"))
                    {
                        return "float";
                    }
                }
                return left orelse right;
            },
            .Identifier => |id| {
                // Look up variable type
                if (self.locals.get(id.name)) |local_info| {
                    return local_info.type_name;
                }
                return null;
            },
            .UnaryExpr => |unary| {
                switch (unary.op) {
                    .Deref => {
                        // Dereference: get the type of what we're dereferencing
                        // If operand is a variable of type T (where T is a struct), result is T
                        return try self.inferExprType(unary.operand);
                    },
                    .AddressOf => {
                        // Address-of: &expr returns a pointer to the type of expr
                        const inner_type = try self.inferExprTypeForMember(unary.operand);
                        if (inner_type) |t| {
                            // Create a pointer type string like "&[Vec4; 4]"
                            // For now, just return the inner type - the code will handle it as a reference
                            return t;
                        }
                        return null;
                    },
                    else => return null,
                }
            },
            .CallExpr => |call| {
                // Check for enum constructor (EnumType.Variant(...))
                // or static struct method (StructType.method())
                if (call.callee.* == .MemberExpr) {
                    const field = call.callee.MemberExpr;
                    if (field.object.* == .Identifier) {
                        const type_name = field.object.Identifier.name;
                        // math.* functions return float.
                        if (std.mem.eql(u8, type_name, "math")) {
                            return "float";
                        }
                        // Array.new() builtin returns an Array pointer.
                        if (std.mem.eql(u8, type_name, "Array") and std.mem.eql(u8, field.member, "new")) {
                            return "Array";
                        }
                        // Check if this is an enum type
                        if (self.enum_layouts.contains(type_name)) {
                            return type_name;
                        }
                        // Check if this is a struct type (static method call)
                        if (self.struct_layouts.contains(type_name)) {
                            // For now, assume static methods on structs return the struct type
                            // This is a simplification - ideally we'd check return type
                            return type_name;
                        }
                    }
                }
                return null;
            },
            .MemberExpr => |member| {
                // For method calls like q.normalized(), infer from object type
                if (member.object.* == .Identifier) {
                    const obj_name = member.object.Identifier.name;
                    if (self.locals.get(obj_name)) |local_info| {
                        // Check if this looks like a method that returns the same type
                        // Methods named 'normalized', 'negate', 'conjugate', 'inverse'
                        // typically return the same type
                        if (self.struct_layouts.contains(local_info.type_name)) {
                            return local_info.type_name;
                        }
                    }
                }
                return null;
            },
            else => return null,
        }
    }

    /// Infer the type of an expression specifically for member access
    /// This is used for nested member assignments like self.rows[row].x = value
    /// where we need to know that self.rows[row] returns a Vector4
    fn inferExprTypeForMember(self: *NativeCodegen, expr: *ast.Expr) CodegenError!?[]const u8 {
        switch (expr.*) {
            .Identifier => |id| {
                // Look up variable type
                if (self.locals.get(id.name)) |local_info| {
                    return local_info.type_name;
                }
                return null;
            },
            .IndexExpr => |index| {
                // For array[index], get the element type from the array
                // First get the array type
                const array_type = try self.inferExprTypeForMember(index.array);
                if (array_type == null) return null;

                // If it's an array type like [Vector4], extract element type
                if (array_type.?.len > 2 and array_type.?[0] == '[') {
                    // Find the element type between [ and ]
                    // Could be [T] or [T; N]
                    var end_idx: usize = 1;
                    var depth: usize = 1;
                    while (end_idx < array_type.?.len and depth > 0) {
                        if (array_type.?[end_idx] == '[') depth += 1;
                        if (array_type.?[end_idx] == ']') depth -= 1;
                        end_idx += 1;
                    }
                    // Extract just the type name without array syntax
                    const inner = array_type.?[1 .. end_idx - 1];
                    // Handle [T; N] format - extract just T
                    if (std.mem.indexOf(u8, inner, ";")) |semi_idx| {
                        const result = std.mem.trim(u8, inner[0..semi_idx], " ");
                        return result;
                    }
                    return inner;
                }
                return null;
            },
            .MemberExpr => |member| {
                // For expr.field, get the field type from the struct
                if (member.object.* == .Identifier) {
                    // Simple case: identifier.field - look up type directly from locals
                    const obj_name = member.object.Identifier.name;
                    const local_info = self.locals.get(obj_name) orelse return null;
                    const struct_layout = self.struct_layouts.get(local_info.type_name) orelse return null;

                    // Find field type in struct layout
                    for (struct_layout.fields) |field| {
                        if (std.mem.eql(u8, field.name, member.member)) {
                            return field.type_name;
                        }
                    }
                    return null;
                } else {
                    // Nested case: recursively get type of object expression
                    const obj_type = try self.inferExprTypeForMember(member.object);
                    if (obj_type == null) return null;

                    // Look up struct layout to find field type
                    const struct_layout = self.struct_layouts.get(obj_type.?) orelse return null;

                    // Find field type in struct layout
                    for (struct_layout.fields) |field| {
                        if (std.mem.eql(u8, field.name, member.member)) {
                            return field.type_name;
                        }
                    }
                    return null;
                }
            },
            else => return null,
        }
    }

    /// Mangle a method into the symbol used in `self.functions`. When
    /// `module_prefix` is set, we emit `module::Type$method` so two
    /// modules that define the same `Type.method` pair don't collide;
    /// otherwise we keep the historical bare `Type$method` form that
    /// the rest of the codebase already expects.
    ///
    /// Callers must `allocator.free` the returned slice.
    fn mangleMethodName(
        self: *NativeCodegen,
        type_name: []const u8,
        method_name: []const u8,
    ) ![]const u8 {
        if (self.module_prefix) |prefix| {
            return try std.fmt.allocPrint(
                self.allocator,
                "{s}::{s}${s}",
                .{ prefix, type_name, method_name },
            );
        }
        return try std.fmt.allocPrint(
            self.allocator,
            "{s}${s}",
            .{ type_name, method_name },
        );
    }

    /// Natural alignment for a primitive or known struct type. Used to
    /// pad struct fields so each one lands on a multiple of its own
    /// alignment, matching the C / SysV layout rules most callers
    /// expect. Falls back to 8 for unknown types to stay safe on x64
    /// where 8-byte alignment is the pointer alignment.
    fn getTypeAlignment(self: *NativeCodegen, type_name: []const u8) usize {
        var resolved = type_name;
        if (std.mem.startsWith(u8, type_name, "mut ")) resolved = type_name[4..];

        if (std.mem.eql(u8, resolved, "u8") or
            std.mem.eql(u8, resolved, "i8") or
            std.mem.eql(u8, resolved, "bool")) return 1;
        if (std.mem.eql(u8, resolved, "u16") or std.mem.eql(u8, resolved, "i16")) return 2;
        if (std.mem.eql(u8, resolved, "u32") or
            std.mem.eql(u8, resolved, "i32") or
            std.mem.eql(u8, resolved, "f32")) return 4;
        // Named struct: recurse to compute the max alignment of its fields.
        if (self.struct_layouts.get(resolved)) |layout| {
            var max_align: usize = 1;
            for (layout.fields) |f| {
                const a = self.getTypeAlignment(f.type_name);
                if (a > max_align) max_align = a;
            }
            return max_align;
        }
        // Everything else (pointers, i64, f64, str, arrays, generics,
        // unresolved type names…) uses full 8-byte alignment.
        return 8;
    }

    /// Get the size of a type in bytes
    fn getTypeSize(self: *NativeCodegen, type_name: []const u8) CodegenError!usize {
        // Strip 'mut ' prefix if present (e.g., "mut Particle" -> "Particle")
        var resolved_name = type_name;
        if (std.mem.startsWith(u8, type_name, "mut ")) {
            resolved_name = type_name[4..]; // Skip "mut "
        }

        // Primitive types
        if (std.mem.eql(u8, resolved_name, "int")) return 8;  // Default int is i64 on x64
        if (std.mem.eql(u8, type_name, "i32")) return 8;  // i64 on x64
        if (std.mem.eql(u8, type_name, "i64")) return 8;
        if (std.mem.eql(u8, type_name, "usize")) return 8; // usize is 8 bytes on x64
        if (std.mem.eql(u8, type_name, "isize")) return 8; // isize is 8 bytes on x64
        if (std.mem.eql(u8, type_name, "u8")) return 1;
        if (std.mem.eql(u8, type_name, "u16")) return 2;
        if (std.mem.eql(u8, type_name, "u32")) return 4;
        if (std.mem.eql(u8, type_name, "u64")) return 8;
        if (std.mem.eql(u8, type_name, "i8")) return 1;
        if (std.mem.eql(u8, type_name, "i16")) return 2;
        if (std.mem.eql(u8, type_name, "bool")) return 8;
        if (std.mem.eql(u8, type_name, "float")) return 8;  // Default float is f64
        if (std.mem.eql(u8, type_name, "f32")) return 4;
        if (std.mem.eql(u8, type_name, "f64")) return 8;
        if (std.mem.eql(u8, type_name, "str")) return 8; // String pointers are 8 bytes
        if (std.mem.eql(u8, type_name, "string")) return 8; // String pointers are 8 bytes

        // Array types like [T] are stored as pointers (8 bytes)
        if (type_name.len > 0 and type_name[0] == '[') {
            return 8; // Dynamic arrays are stored as pointers
        }

        // Generic types like Vec<T>, Map<K,V>, Option<T>, Result<T,E> are all pointer-sized
        if (std.mem.indexOfScalar(u8, type_name, '<')) |_| {
            return 8; // All generic types are stored as pointers
        }

        // Pointer types
        if (type_name.len > 0 and type_name[type_name.len - 1] == '*') {
            return 8; // All pointers are 8 bytes on x64
        }

        // Self type refers to the containing struct - treat as pointer
        if (std.mem.eql(u8, type_name, "Self")) {
            return 8; // Self is a pointer to the struct
        }

        // Builtin dynamic Array: pointer to heap header.
        if (std.mem.eql(u8, type_name, "Array")) {
            return 8;
        }

        // Optional types (T?) are stored as a tagged union: [has_value (8 bytes)][value (8 bytes)]
        if (type_name.len > 0 and type_name[type_name.len - 1] == '?') {
            return 16; // Optional = tag + value
        }

        // Handle module-qualified types (e.g., kindof::KindOfMask, player::Player)
        // and mut-prefixed types (e.g., mut Particle)
        // Strip the module prefix or mut prefix and look up just the type name
        var resolved_type_name = resolved_name;
        if (std.mem.indexOf(u8, resolved_name, "::")) |sep_idx| {
            // Type is module-qualified, extract just the type name part
            resolved_type_name = resolved_name[sep_idx + 2 ..];
        }

        // Check if it's a struct type
        if (self.struct_layouts.get(resolved_type_name)) |layout| {
            return layout.total_size;
        }

        // Check if it's an enum type (use resolved name to handle module-qualified types)
        if (self.enum_layouts.get(resolved_type_name)) |enum_layout| {
            // Check if any variant has data
            var has_data = false;
            for (enum_layout.variants) |variant| {
                if (variant.data_type != null) {
                    has_data = true;
                    break;
                }
            }

            // If enum has variants with data, it's a tagged union (16 bytes: tag + data)
            // Otherwise it's a simple enum (8 bytes: just the tag)
            return if (has_data) 16 else 8;
        }

        // Handle common math/vector types by their naming conventions
        if (std.mem.eql(u8, type_name, "Vec2") or std.mem.eql(u8, type_name, "Vector2") or
            std.mem.eql(u8, type_name, "float2") or std.mem.eql(u8, type_name, "double2"))
        {
            return 16; // 2 floats = 16 bytes (using 8 per float for simplicity)
        }
        if (std.mem.eql(u8, type_name, "Vec3") or std.mem.eql(u8, type_name, "Vector3") or
            std.mem.eql(u8, type_name, "float3") or std.mem.eql(u8, type_name, "double3"))
        {
            return 24; // 3 floats = 24 bytes
        }
        if (std.mem.eql(u8, type_name, "Vec4") or std.mem.eql(u8, type_name, "Vector4") or
            std.mem.eql(u8, type_name, "float4") or std.mem.eql(u8, type_name, "double4") or
            std.mem.eql(u8, type_name, "Quaternion") or std.mem.eql(u8, type_name, "Color") or
            std.mem.eql(u8, type_name, "Rect"))
        {
            return 32; // 4 floats = 32 bytes
        }
        if (std.mem.eql(u8, type_name, "Mat2") or std.mem.eql(u8, type_name, "Matrix2") or
            std.mem.eql(u8, type_name, "float2x2"))
        {
            return 32; // 2x2 floats = 32 bytes
        }
        if (std.mem.eql(u8, type_name, "Mat3") or std.mem.eql(u8, type_name, "Matrix3") or
            std.mem.eql(u8, type_name, "float3x3"))
        {
            return 72; // 3x3 floats = 72 bytes
        }
        if (std.mem.eql(u8, type_name, "Mat4") or std.mem.eql(u8, type_name, "Matrix4") or
            std.mem.eql(u8, type_name, "float4x4") or std.mem.eql(u8, type_name, "Transform"))
        {
            return 128; // 4x4 floats = 128 bytes
        }

        // Unknown types - default to pointer size (8 bytes)
        // This allows compilation to continue even with unrecognized types
        std.debug.print("Unknown type (defaulting to 8 bytes): {s}\n", .{type_name});
        return 8;
    }

    /// Serialize the complete data section: string literals first
    /// (each NUL-terminated), then binary data literals (vtables,
    /// comptime arrays, comptime structs).
    fn writeDataSection(self: *NativeCodegen) ![]u8 {
        const size = self.getDataSectionSize();
        if (size == 0) {
            return &[_]u8{};
        }

        var data = try self.allocator.alloc(u8, size);
        var offset: usize = 0;

        // 1) String literals (NUL-terminated).
        for (self.string_literals.items) |str| {
            @memcpy(data[offset..][0..str.len], str);
            offset += str.len;
            data[offset] = 0;
            offset += 1;
        }

        // 2) Binary data literals (vtables, comptime arrays/structs).
        for (self.data_literals.items) |blob| {
            @memcpy(data[offset..][0..blob.len], blob);
            offset += blob.len;
        }

        return data;
    }

    /// Copy memory from source to destination
    /// Input: rdi = dest, rsi = src, rdx = count
    /// Uses rep movsb for byte-by-byte copy
    fn generateMemCopy(self: *NativeCodegen) !void {
        // Save registers
        try self.assembler.pushReg(.rcx);

        // Set up for rep movsb: rcx = count, rsi = src, rdi = dest
        try self.assembler.movRegReg(.rcx, .rdx);

        // rep movsb - repeat move byte from [rsi] to [rdi], rcx times
        // Opcodes: F3 A4
        try self.assembler.code.append(self.allocator, 0xF3);
        try self.assembler.code.append(self.allocator, 0xA4);

        // Restore registers
        try self.assembler.popReg(.rcx);
    }

    /// Patch all string literal references with correct RIP-relative offsets
    /// Must be called after code generation is complete and before getting final code
    /// data_section_file_offset: offset in the file where __DATA section starts
    fn patchStringFixups(self: *NativeCodegen, data_section_file_offset: usize) !void {
        // Text section starts at 0x1000 on both macOS (Mach-O) and
        // Linux (ELF). If a future platform needs a different base,
        // this should be parameterized.
        const text_section_base: usize = 0x1000;

        for (self.string_fixups.items) |fixup| {
            // Calculate RIP at the point after the LEA instruction
            // The fixup.code_pos points to the displacement field (4 bytes before end of instruction)
            const instruction_end = fixup.code_pos + 4; // 4 bytes for the i32 displacement
            const rip_after_lea = text_section_base + instruction_end;

            // Calculate target address in file
            const target_address = data_section_file_offset + fixup.data_offset;

            // Calculate RIP-relative displacement
            // displacement = target - rip_after_instruction
            const displacement = @as(i32, @intCast(@as(i64, @intCast(target_address)) - @as(i64, @intCast(rip_after_lea))));

            // Patch the displacement in the code
            try self.assembler.patchLeaRipRel(fixup.code_pos, displacement);
        }
    }

    pub fn generate(self: *NativeCodegen) ![]const u8 {
        // Pass 0: register every async fn name BEFORE walking the program.
        // This way a sync fn that calls an async fn declared later still
        // sees the right name and the call-site dispatch can wrap it in
        // a block_on loop. Without this pre-pass, top-level main calling
        // a forward-declared async fn would emit a plain call.
        try self.preregisterAsyncFns(self.program.statements);

        // Generate code for all statements.
        // Note: Don't add prologue/epilogue here - each function handles its own.
        for (self.program.statements) |stmt| {
            try self.generateStmt(stmt);
        }

        return try self.assembler.getCode();
    }

    /// Walk the program top-level and add every `async fn` name to
    /// `async_fn_names`. Idempotent — names already present are skipped.
    fn preregisterAsyncFns(self: *NativeCodegen, stmts: []const ast.Stmt) !void {
        for (stmts) |stmt| {
            switch (stmt) {
                .FnDecl => |fn_decl| {
                    if (fn_decl.is_async and !self.async_fn_names.contains(fn_decl.name)) {
                        const k = try self.allocator.dupe(u8, fn_decl.name);
                        try self.async_fn_names.put(k, {});
                    }
                },
                .ImplDecl => |impl_decl| {
                    for (impl_decl.methods) |m| {
                        if (m.is_async and !self.async_fn_names.contains(m.name)) {
                            const k = try self.allocator.dupe(u8, m.name);
                            try self.async_fn_names.put(k, {});
                        }
                    }
                },
                else => {},
            }
        }
    }

    /// PASS 1: Register all types from a statement without generating code
    /// This recursively processes imports and registers enums/structs in the global registry
    fn registerTypesFromStmt(self: *NativeCodegen, stmt: ast.Stmt) CodegenError!void {
        switch (stmt) {
            .EnumDecl => |enum_decl| {
                // Register enum type without generating code
                const name_copy = try self.allocator.dupe(u8, enum_decl.name);
                errdefer self.allocator.free(name_copy);

                var variants = try self.allocator.alloc(EnumVariantInfo, enum_decl.variants.len);
                errdefer self.allocator.free(variants);

                for (enum_decl.variants, 0..) |variant, i| {
                    const variant_name = try self.allocator.dupe(u8, variant.name);
                    const variant_data_type = if (variant.data_type) |dt|
                        try self.allocator.dupe(u8, dt)
                    else
                        null;

                    variants[i] = .{
                        .name = variant_name,
                        .data_type = variant_data_type,
                    };
                }

                const layout = EnumLayout{
                    .name = name_copy,
                    .variants = variants,
                };

                // Register locally
                try self.enum_layouts.put(name_copy, layout);

                // Register globally
                if (self.type_registry) |registry| {
                    registry.registerEnum(layout) catch |err| {
                        std.debug.print("Warning: Failed to register enum '{s}' in global registry: {}\n", .{layout.name, err});
                    };
                }
            },
            .StructDecl => |struct_decl| {
                // Register struct type without generating code
                const name_copy = try self.allocator.dupe(u8, struct_decl.name);
                errdefer self.allocator.free(name_copy);

                var fields = try self.allocator.alloc(FieldInfo, struct_decl.fields.len);
                errdefer self.allocator.free(fields);

                // Compute per-field offsets with proper alignment so
                // mixed-width fields (e.g. `u8`, `i64`) don't end up at
                // straddling offsets. Also round the total size up to
                // the struct's own alignment so arrays-of-struct don't
                // land on misaligned boundaries.
                var offset: usize = 0;
                var struct_align: usize = 1;
                for (struct_decl.fields, 0..) |field, i| {
                    const field_name = try self.allocator.dupe(u8, field.name);
                    const field_type_name = if (field.type_name.len > 0)
                        try self.allocator.dupe(u8, field.type_name)
                    else
                        "";

                    const field_size = if (field.type_name.len > 0)
                        (self.getTypeSize(field.type_name) catch 8)
                    else
                        8;
                    const field_align = if (field.type_name.len > 0)
                        self.getTypeAlignment(field.type_name)
                    else
                        8;
                    if (field_align > struct_align) struct_align = field_align;
                    offset = std.mem.alignForward(usize, offset, field_align);

                    fields[i] = .{
                        .name = field_name,
                        .offset = offset,
                        .size = field_size,
                        .type_name = field_type_name,
                    };
                    offset += field_size;
                }
                const total_size = std.mem.alignForward(usize, offset, struct_align);

                const layout = StructLayout{
                    .name = name_copy,
                    .fields = fields,
                    .total_size = total_size,
                };

                // Register locally
                try self.struct_layouts.put(name_copy, layout);

                // Register globally
                if (self.type_registry) |registry| {
                    registry.registerStruct(layout) catch |err| {
                        std.debug.print("Warning: Failed to register struct '{s}' in global registry: {}\n", .{layout.name, err});
                    };
                }
            },
            .ImportDecl => |import_decl| {
                // Recursively process imports to register their types
                self.registerTypesFromImport(import_decl);
            },
            else => {
                // Other statement types don't define types, skip
            },
        }
    }

    /// PASS 1: Register types from an imported module (non-fatal - errors are logged as warnings)
    fn registerTypesFromImport(self: *NativeCodegen, import_decl: *ast.ImportDecl) void {
        // Build module key from path components
        var key_list = std.ArrayList(u8).empty;
        defer key_list.deinit(self.allocator);
        for (import_decl.path, 0..) |component, i| {
            if (i > 0) key_list.append(self.allocator, '/') catch return;
            key_list.appendSlice(self.allocator, component) catch return;
        }
        const module_key = key_list.items;

        // Check if already imported
        if (self.imported_modules.contains(module_key)) {
            return; // Already imported, skip
        }

        // Mark as imported (store a copy of the key)
        const key_copy = self.allocator.dupe(u8, module_key) catch return;
        self.imported_modules.put(key_copy, {}) catch {
            self.allocator.free(key_copy);
            return;
        };

        // Convert import path to file path
        var path_list = std.ArrayList(u8).empty;
        defer path_list.deinit(self.allocator);

        // Add source root prefix if available
        if (self.source_root) |root| {
            if (!std.mem.eql(u8, root, ".")) {
                path_list.appendSlice(self.allocator, root) catch return;
                path_list.append(self.allocator, '/') catch return;
            }
        }

        // Try src/ subdirectory first
        path_list.appendSlice(self.allocator, "src/") catch return;
        for (import_decl.path, 0..) |component, i| {
            if (i > 0) path_list.append(self.allocator, '/') catch return;
            path_list.appendSlice(self.allocator, component) catch return;
        }
        path_list.appendSlice(self.allocator, ".home") catch return;

        var module_path = path_list.items;

        // Try to read from src/ first
        const io_val = self.io orelse return;
        const cwd = Io.Dir.cwd();
        const module_source = cwd.readFileAlloc(
            io_val,
            module_path,
            self.allocator,
            std.Io.Limit.limited(10 * 1024 * 1024),
        ) catch blk: {
            // If src/ doesn't work, try without src/ prefix
            path_list.clearRetainingCapacity();
            for (import_decl.path, 0..) |component, i| {
                if (i > 0) path_list.append(self.allocator, '/') catch return;
                path_list.appendSlice(self.allocator, component) catch return;
            }
            path_list.appendSlice(self.allocator, ".home") catch return;
            module_path = path_list.items;

            break :blk cwd.readFileAlloc(
                io_val,
                module_path,
                self.allocator,
                std.Io.Limit.limited(10 * 1024 * 1024),
            ) catch |err| {
                std.debug.print("Failed to read import file '{s}': {}\n", .{ module_path, err });
                return;
            };
        };

        // Store source in module_sources list
        self.module_sources.append(self.allocator, module_source) catch { self.allocator.free(module_source); return; };

        // Parse the module
        const lexer_mod = @import("lexer");
        const parser_mod = @import("parser");

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        var lexer = lexer_mod.Lexer.init(arena_alloc, module_source);
        const token_list = lexer.tokenize() catch |err| {
            std.debug.print("Failed to tokenize module '{s}': {}\n", .{module_path, err});
            return;
        };
        const tokens = token_list.items;

        var parser = parser_mod.Parser.init(arena_alloc, tokens) catch |err| {
            std.debug.print("Failed to create parser for module '{s}': {}\n", .{module_path, err});
            return;
        };
        defer parser.deinit();

        // Set source root for nested imports. A failure here means nested
        // imports inside the module will resolve relative to the cwd
        // instead of the parent module's directory — worth flagging rather
        // than silently degrading.
        if (self.source_root) |root| {
            parser.module_resolver.setSourceRootDirect(root) catch |err| {
                std.debug.print(
                    "Warning: failed to propagate source root to module '{s}': {}\n",
                    .{ module_path, err },
                );
            };
        } else {
            parser.module_resolver.setSourceRoot(module_path) catch |err| {
                std.debug.print(
                    "Warning: failed to set source root for module '{s}': {}\n",
                    .{ module_path, err },
                );
            };
        }

        const module_ast = parser.parse() catch |err| {
            std.debug.print("Failed to parse module '{s}': {}\n", .{module_path, err});
            return;
        };

        // Skip if there were parse errors
        if (parser.errors.items.len > 0) {
            std.debug.print("Skipping module '{s}' due to {d} parse error(s)\n", .{ module_path, parser.errors.items.len });
            return;
        }

        // Register types from all statements in the imported module
        for (module_ast.statements) |stmt| {
            self.registerTypesFromStmt(stmt) catch |err| {
                std.debug.print("Warning: Failed to register types from statement in module '{s}': {}\n", .{ module_path, err });
                continue;
            };
        }
    }

    /// PASS 1: Register all types from the program and all imports
    /// This ensures all types are available before code generation
    fn registerAllTypes(self: *NativeCodegen) !void {
        for (self.program.statements) |stmt| {
            try self.registerTypesFromStmt(stmt);
        }
    }

    pub fn writeExecutable(self: *NativeCodegen, path: []const u8) !void {
        // PASS 1: Register all types from this module and all imports
        try self.registerAllTypes();

        // PASS 2: Generate code (all types now available)
        for (self.program.statements) |stmt| {
            try self.generateStmt(stmt);
        }

        // Calculate data section file offset (after code + padding)
        const page_size: usize = 0x1000;
        const code_size = self.assembler.code.items.len;
        const code_size_aligned = std.mem.alignForward(usize, code_size, page_size);
        const text_file_offset: usize = 0x1000;
        const data_file_offset = text_file_offset + code_size_aligned;

        // Patch string fixups with correct RIP-relative addresses
        // This modifies self.assembler.code in place
        try self.patchStringFixups(data_file_offset);

        // Get the final code after patching
        const code = try self.assembler.getCode();
        defer self.allocator.free(code);

        // Write data section
        const data = try self.writeDataSection();
        defer if (data.len > 0) self.allocator.free(data);

        // Find main function offset
        const main_offset = self.functions.get("main") orelse 0;

        // Use platform-appropriate binary format
        switch (builtin.os.tag) {
            .macos => {
                var writer = macho.MachOWriter.init(self.allocator, code, data);
                // Propagate the I/O context so the writer can actually open
                // the output file. Without this it would always return
                // FileSystemAccessDenied.
                writer.io = self.io;
                try writer.writeWithEntryPoint(path, main_offset);
            },
            .linux => {
                var writer = elf.ElfWriter.init(self.allocator, code, data);
                writer.io = self.io;
                try writer.write(path);
            },
            else => {
                std.debug.print("Unsupported platform: {s}\n", .{@tagName(builtin.os.tag)});
                return error.UnsupportedPlatform;
            },
        }
    }

    /// Check if a statement is a return (for dead code elimination)
    fn isReturn(stmt: ast.Stmt) bool {
        return stmt == .ReturnStmt;
    }

    /// Check if a block always returns (all paths lead to return)
    fn blockAlwaysReturns(block: *const ast.Block) bool {
        if (block.statements.len == 0) return false;

        // Check if last statement is a return
        const last = block.statements[block.statements.len - 1];
        if (last == .ReturnStmt) return true;

        // Check if last statement is an if where both branches return
        if (last == .IfStmt) {
            const if_stmt = last.IfStmt;
            const then_returns = blockAlwaysReturns(&if_stmt.then_block);
            if (if_stmt.else_block) |else_block| {
                return then_returns and blockAlwaysReturns(&else_block);
            }
        }

        return false;
    }

    fn generateStmt(self: *NativeCodegen, stmt: ast.Stmt) CodegenError!void {
        switch (stmt) {
            .LetDecl => |decl| try self.generateLetDecl(decl),
            .TupleDestructureDecl => |decl| try self.generateTupleDestructure(decl),
            .ExprStmt => |expr| {
                _ = try self.generateExpr(expr);
            },
            .FnDecl => |func| try self.generateFnDecl(func),
            .ReturnStmt => |ret| {
                // Async fast path: write result into the state struct,
                // mark Ready, and jump to the function epilogue. The
                // sync prologue/epilogue cleanup below is skipped — the
                // poll function emitter handles its own teardown.
                if (self.async_ctx) |ctx| {
                    if (ret.value) |value| {
                        try self.generateExpr(value);
                    } else {
                        try self.assembler.movRegImm64(.rax, 0);
                    }
                    try self.emitAsyncReturn(ctx);
                    return;
                }

                if (ret.value) |value| {
                    try self.generateExpr(value);
                } else {
                    try self.assembler.movRegImm64(.rax, 0);
                }

                // Save return value, drain deferred expressions in LIFO order,
                // then restore the return value before the epilogue.
                if (self.defer_stack.items.len > 0) {
                    try self.assembler.pushReg(.rax);
                    try self.emitDeferredCleanup();
                    try self.assembler.popReg(.rax);
                }

                try self.assembler.movRegReg(.rsp, .rbp);
                try self.assembler.popReg(.rbp);

                if (self.current_function_name) |func_name| {
                    if (std.mem.eql(u8, func_name, "main")) {
                        // Use rax (the return value) as exit code.
                        try self.assembler.movRegReg(.rdi, .rax);
                        const exit_syscall: u64 = switch (builtin.os.tag) {
                            .macos => 0x2000001,
                            .linux => 60,
                            else => 60,
                        };
                        try self.assembler.movRegImm64(.rax, exit_syscall);
                        try self.assembler.syscall();
                    } else {
                        try self.assembler.ret();
                    }
                } else {
                    try self.assembler.ret();
                }
            },
            .IfStmt => |if_stmt| {
                // Evaluate condition
                try self.generateExpr(if_stmt.condition);

                // Test rax (condition result)
                try self.assembler.testRegReg(.rax, .rax);

                // Reserve space for conditional jump to else/end
                const jz_pos = self.assembler.getPosition();
                try self.assembler.jzRel32(0); // Placeholder

                // Generate then block
                for (if_stmt.then_block.statements) |then_stmt| {
                    try self.generateStmt(then_stmt);
                }

                if (if_stmt.else_block) |else_block| {
                    // If there's an else block, jump over it from then block
                    const jmp_pos = self.assembler.getPosition();
                    try self.assembler.jmpRel32(0); // Placeholder

                    // Patch the jz to jump to else block
                    const else_start = self.assembler.getPosition();
                    const jz_offset = @as(i32, @intCast(else_start)) - @as(i32, @intCast(jz_pos + 6));
                    try self.assembler.patchJzRel32(jz_pos, jz_offset);

                    // Generate else block
                    for (else_block.statements) |else_stmt| {
                        try self.generateStmt(else_stmt);
                    }

                    // Patch the jmp to jump to end
                    const end_pos = self.assembler.getPosition();
                    const jmp_offset = @as(i32, @intCast(end_pos)) - @as(i32, @intCast(jmp_pos + 5));
                    try self.assembler.patchJmpRel32(jmp_pos, jmp_offset);
                } else {
                    // No else block, just patch jz to jump to end
                    const end_pos = self.assembler.getPosition();
                    const jz_offset = @as(i32, @intCast(end_pos)) - @as(i32, @intCast(jz_pos + 6));
                    try self.assembler.patchJzRel32(jz_pos, jz_offset);
                }
            },
            .IfLetStmt => |if_let| {
                // if let Some(x) = expr { then } else { else }
                // Pattern matching on enum variants
                // Use r10 (caller-saved) to hold the enum pointer - no need to save/restore

                // Evaluate the expression being matched (result in rax)
                try self.generateExpr(if_let.value);

                // Save value pointer in r10 for later use (caller-saved, no need to preserve)
                try self.assembler.movRegReg(.r10, .rax);

                // Find the target tag for the pattern (e.g., "Some" -> tag value)
                var found = false;
                var target_tag: i64 = 0;
                var has_data = false;

                var enum_iter = self.enum_layouts.iterator();
                while (enum_iter.next()) |entry| {
                    const enum_layout = entry.value_ptr.*;
                    for (enum_layout.variants, 0..) |v, idx| {
                        if (std.mem.eql(u8, v.name, if_let.pattern)) {
                            found = true;
                            target_tag = @intCast(idx);
                            has_data = v.data_type != null;
                            break;
                        }
                    }
                    if (found) break;
                }

                // Load tag from enum value (first 8 bytes at r10)
                try self.assembler.movRegMem(.rcx, .r10, 0);

                // Compare with expected tag
                try self.assembler.movRegImm64(.rdx, @intCast(target_tag));
                try self.assembler.cmpRegReg(.rcx, .rdx);

                // Reserve space for conditional jump to else/end
                const jne_pos = self.assembler.getPosition();
                try self.assembler.jneRel32(0); // Placeholder - jump if not equal

                // Pattern matched - bind variable if present
                const locals_before = self.locals.count();
                if (if_let.binding) |binding_name| {
                    if (has_data) {
                        // Load the data (at offset 8) from enum
                        try self.assembler.movRegMem(.rcx, .r10, 8);

                        // Push value onto stack and add to locals
                        try self.assembler.pushReg(.rcx);

                        const offset = self.next_local_offset;
                        self.next_local_offset += 1;

                        // Free old key if variable exists (shadowing)
                        if (self.locals.fetchRemove(binding_name)) |old_entry| {
                            self.allocator.free(old_entry.key);
                        }
                        const name_copy = try self.allocator.dupe(u8, binding_name);
                        errdefer self.allocator.free(name_copy);

                        try self.locals.put(name_copy, .{
                            .offset = offset,
                            .type_name = "i64", // Default type
                            .size = 8,
                        });
                    }
                }

                // Generate then block
                for (if_let.then_block.statements) |then_stmt| {
                    try self.generateStmt(then_stmt);
                }

                // Clean up pattern variables
                try self.cleanupPatternVariables(locals_before);

                if (if_let.else_block) |else_block| {
                    // If there's an else block, jump over it from then block
                    const jmp_pos = self.assembler.getPosition();
                    try self.assembler.jmpRel32(0); // Placeholder

                    // Patch the jne to jump to else block
                    const else_start = self.assembler.getPosition();
                    const jne_offset = @as(i32, @intCast(else_start)) - @as(i32, @intCast(jne_pos + 6));
                    try self.assembler.patchJneRel32(jne_pos, jne_offset);

                    // Generate else block
                    for (else_block.statements) |else_stmt| {
                        try self.generateStmt(else_stmt);
                    }

                    // Patch the jmp to jump to end
                    const end_pos = self.assembler.getPosition();
                    const jmp_offset = @as(i32, @intCast(end_pos)) - @as(i32, @intCast(jmp_pos + 5));
                    try self.assembler.patchJmpRel32(jmp_pos, jmp_offset);
                } else {
                    // No else block, just patch jne to jump to end
                    const end_pos = self.assembler.getPosition();
                    const jne_offset = @as(i32, @intCast(end_pos)) - @as(i32, @intCast(jne_pos + 6));
                    try self.assembler.patchJneRel32(jne_pos, jne_offset);
                }
            },
            .WhileStmt => |while_stmt| {
                // While loop: test condition, jump if false, body, jump back
                const loop_start = self.assembler.getPosition();

                // Evaluate condition
                try self.generateExpr(while_stmt.condition);

                // Test rax (condition result)
                try self.assembler.testRegReg(.rax, .rax);

                // Reserve space for conditional jump (will patch later)
                const jz_pos = self.assembler.getPosition();
                try self.assembler.jzRel32(0); // Placeholder

                // Push loop context for break/continue
                try self.loop_stack.append(self.allocator, .{
                    .loop_start = loop_start,
                    .break_fixups = std.ArrayList(usize).empty,
                    .continue_fixups = std.ArrayList(usize).empty,
                    .label = null,
                });

                // Generate loop body
                for (while_stmt.body.statements) |body_stmt| {
                    try self.generateStmt(body_stmt);
                }

                var loop_ctx = self.loop_stack.pop().?;
                defer loop_ctx.break_fixups.deinit(self.allocator);
                defer loop_ctx.continue_fixups.deinit(self.allocator);

                // Patch any continue fixups to jump here (condition re-test).
                const continue_target = self.assembler.getPosition();
                _ = continue_target;
                for (loop_ctx.continue_fixups.items) |cpos| {
                    const coff = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(cpos + 5));
                    try self.assembler.patchJmpRel32(cpos, coff);
                }

                // Jump back to condition
                const current_pos = self.assembler.getPosition();
                const back_offset = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(current_pos + 5));
                try self.assembler.jmpRel32(back_offset);

                const loop_end = self.assembler.getPosition();
                const forward_offset = @as(i32, @intCast(loop_end)) - @as(i32, @intCast(jz_pos + 6));
                try self.assembler.patchJzRel32(jz_pos, forward_offset);

                for (loop_ctx.break_fixups.items) |break_pos| {
                    const break_offset = @as(i32, @intCast(loop_end)) - @as(i32, @intCast(break_pos + 5));
                    try self.assembler.patchJmpRel32(break_pos, break_offset);
                }
            },
            .DoWhileStmt => |do_while| {
                // Do-while: body, test condition, jump back if true
                const loop_start = self.assembler.getPosition();

                // Push loop context for break/continue
                try self.loop_stack.append(self.allocator, .{
                    .loop_start = loop_start,
                    .break_fixups = std.ArrayList(usize).empty,
                    .continue_fixups = std.ArrayList(usize).empty,
                    .label = null,
                });

                // Generate loop body
                for (do_while.body.statements) |body_stmt| {
                    try self.generateStmt(body_stmt);
                }

                var loop_ctx = self.loop_stack.pop().?;
                defer loop_ctx.break_fixups.deinit(self.allocator);
                defer loop_ctx.continue_fixups.deinit(self.allocator);

                // Patch continue fixups to the condition test below.
                const cond_pos = self.assembler.getPosition();
                for (loop_ctx.continue_fixups.items) |cpos| {
                    const coff = @as(i32, @intCast(cond_pos)) - @as(i32, @intCast(cpos + 5));
                    try self.assembler.patchJmpRel32(cpos, coff);
                }

                try self.generateExpr(do_while.condition);

                // Test rax (condition result)
                try self.assembler.testRegReg(.rax, .rax);

                // Jump back to start if true (non-zero)
                const current_pos = self.assembler.getPosition();
                const back_offset = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(current_pos + 6));
                try self.assembler.jnzRel32(back_offset);

                // Patch all break statements to jump here (after loop)
                const loop_end = self.assembler.getPosition();
                for (loop_ctx.break_fixups.items) |break_pos| {
                    const break_offset = @as(i32, @intCast(loop_end)) - @as(i32, @intCast(break_pos + 5));
                    try self.assembler.patchJmpRel32(break_pos, break_offset);
                }
            },
            .ForStmt => |for_stmt| {
                // For loop: for iterator in iterable { body }

                // Dynamic-array iteration: if `iterable` is an identifier
                // of type `Array`, walk the heap header's `len` slots from
                // [base+16] upward. This is the other non-range shape the
                // parser can produce; anything else still returns silently.
                if (for_stmt.iterable.* != .RangeExpr) {
                    const is_array = blk: {
                        if (for_stmt.iterable.* == .Identifier) {
                            const id = for_stmt.iterable.Identifier;
                            if (self.locals.get(id.name)) |info| {
                                break :blk std.mem.eql(u8, info.type_name, "Array");
                            }
                        }
                        break :blk false;
                    };

                    if (is_array) {
                        // Array iteration. Because the loop body can
                        // clobber any register, we keep the ground-truth
                        // state in three stack slots that rank above the
                        // iterator binding: [base_ptr, len, index]. The
                        // iterator variable lives in a fourth slot that we
                        // rewrite at the top of each iteration.
                        //
                        // Stack layout while the loop runs (top is rsp):
                        //   [rsp+0]  iterator value (== current element)
                        //   [rsp+8]  index (i)
                        //   [rsp+16] len
                        //   [rsp+24] base pointer (Array header ptr)
                        try self.generateExpr(for_stmt.iterable);
                        try self.assembler.pushReg(.rax);                // base
                        try self.assembler.movRegMem(.rax, .rax, 0);    // len
                        try self.assembler.pushReg(.rax);                // len slot
                        try self.assembler.movRegImm64(.rax, 0);
                        try self.assembler.pushReg(.rax);                // i = 0
                        self.next_local_offset += 3;

                        const iter_offset = self.next_local_offset;
                        self.next_local_offset += 1;
                        var shadowed_old: ?LocalInfo = null;
                        if (self.locals.fetchRemove(for_stmt.iterator)) |old_entry| {
                            shadowed_old = old_entry.value;
                            self.allocator.free(old_entry.key);
                        }
                        const name_copy = try self.allocator.dupe(u8, for_stmt.iterator);
                        try self.locals.put(name_copy, .{
                            .offset = iter_offset,
                            .type_name = "int",
                            .size = 8,
                        });
                        try self.assembler.movRegImm64(.rax, 0);
                        try self.assembler.pushReg(.rax); // iterator value

                        // rbp-relative offsets for each state slot. Must
                        // match the pushReg order above. localDisp rejects
                        // frames past x64's i32 displacement limit.
                        const base_off: i32 = try self.localDisp(iter_offset - 3);
                        const len_off: i32 = try self.localDisp(iter_offset - 2);
                        const i_off: i32 = try self.localDisp(iter_offset - 1);
                        const slot_off: i32 = try self.localDisp(iter_offset);

                        const loop_start = self.assembler.getPosition();

                        // Load i and len, test i < len.
                        try self.assembler.movRegMem(.r8, .rbp, i_off);
                        try self.assembler.movRegMem(.r9, .rbp, len_off);
                        try self.assembler.cmpRegReg(.r8, .r9);
                        const jge_done = self.assembler.getPosition();
                        try self.assembler.jgeRel32(0);

                        // Load header, then data_ptr = [header+16]. Slot i
                        // now lives at [data_ptr + i*8] in the indirect
                        // Array layout.
                        try self.assembler.movRegMem(.r11, .rbp, base_off);
                        try self.assembler.movRegMem(.r11, .r11, 16);
                        try self.assembler.leaRegMemSib(.rax, .r11, .r8, .eight, 0);
                        try self.assembler.movRegMem(.rcx, .rax, 0);
                        try self.assembler.movMemReg(.rbp, slot_off, .rcx);

                        try self.loop_stack.append(self.allocator, .{
                            .loop_start = loop_start,
                            .break_fixups = std.ArrayList(usize).empty,
                            .continue_fixups = std.ArrayList(usize).empty,
                            .label = null,
                        });

                        for (for_stmt.body.statements) |body_stmt| {
                            try self.generateStmt(body_stmt);
                        }

                        var loop_ctx = self.loop_stack.pop().?;
                        defer loop_ctx.break_fixups.deinit(self.allocator);
                        defer loop_ctx.continue_fixups.deinit(self.allocator);

                        // i = i + 1 — this is the continue target for
                        // for-loops so `continue` advances the iterator
                        // instead of repeating the same element forever.
                        const incr_pos = self.assembler.getPosition();
                        for (loop_ctx.continue_fixups.items) |cpos| {
                            const coff = @as(i32, @intCast(incr_pos)) - @as(i32, @intCast(cpos + 5));
                            try self.assembler.patchJmpRel32(cpos, coff);
                        }
                        try self.assembler.movRegMem(.r8, .rbp, i_off);
                        try self.assembler.addRegImm(.r8, 1);
                        try self.assembler.movMemReg(.rbp, i_off, .r8);

                        const back_pos = self.assembler.getPosition();
                        try self.assembler.jmpRel32(
                            @as(i32, @intCast(loop_start)) - @as(i32, @intCast(back_pos + 5)),
                        );

                        const loop_end = self.assembler.getPosition();
                        try self.assembler.patchJgeRel32(
                            jge_done,
                            @as(i32, @intCast(loop_end)) - @as(i32, @intCast(jge_done + 6)),
                        );
                        for (loop_ctx.break_fixups.items) |break_pos| {
                            const break_offset = @as(i32, @intCast(loop_end)) - @as(i32, @intCast(break_pos + 5));
                            try self.assembler.patchJmpRel32(break_pos, break_offset);
                        }

                        // Drop iterator, index, len, base — four pops.
                        try self.assembler.popReg(.rax);
                        try self.assembler.popReg(.rax);
                        try self.assembler.popReg(.rax);
                        try self.assembler.popReg(.rax);
                        self.next_local_offset -= 4;

                        if (self.locals.fetchRemove(for_stmt.iterator)) |removed| {
                            self.allocator.free(removed.key);
                        }
                        if (shadowed_old) |info| {
                            const restored = try self.allocator.dupe(u8, for_stmt.iterator);
                            try self.locals.put(restored, info);
                        }
                        return;
                    }

                    // Any other iterable shape: skip (same as before) so
                    // compilation keeps flowing.
                    return;
                }

                const range = for_stmt.iterable.RangeExpr;

                // Save r8 and r9 for nested loop support
                // These registers are used for iteration state and get clobbered by nested loops
                try self.assembler.pushReg(.r8);
                try self.assembler.pushReg(.r9);
                self.next_local_offset += 2;

                // Evaluate range start (result in rax)
                try self.generateExpr(range.start);
                // Store start value in r8 (current iterator value)
                try self.assembler.movRegReg(.r8, .rax);

                // Evaluate range end (result in rax)
                try self.generateExpr(range.end);
                // Store end value in r9 (end bound)
                try self.assembler.movRegReg(.r9, .rax);

                // Allocate stack space for iterator variable (push once at start)
                const iterator_offset = self.next_local_offset;
                self.next_local_offset += 1;

                // If the iterator name shadows an existing binding, remember
                // the old LocalInfo so we can restore it when the loop ends.
                // Previously we just dropped the outer binding, which made
                // `for x in 0..n { ... } use(x)` silently see stale stack
                // slots once the loop had finished.
                var shadowed_old: ?LocalInfo = null;
                if (self.locals.fetchRemove(for_stmt.iterator)) |old_entry| {
                    shadowed_old = old_entry.value;
                    self.allocator.free(old_entry.key);
                }

                const iterator_name_copy = try self.allocator.dupe(u8, for_stmt.iterator);
                try self.locals.put(iterator_name_copy, .{
                    .offset = iterator_offset,
                    .type_name = "i32",  // For loop iterators are always i32
                    .size = 8,
                });
                // Note: HashMap now owns iterator_name_copy, will be freed in cleanup

                // Push initial iterator value to stack
                try self.assembler.movRegReg(.rax, .r8);
                try self.assembler.pushReg(.rax);

                // Loop start: update stack and compare iterator with end
                const loop_start = self.assembler.getPosition();

                // Update the stack with current iterator value
                // [rbp - (offset + 1) * 8]. localDisp reports the stack-too-large
                // case as a compile error rather than truncating to 0.
                const stack_offset: i32 = try self.localDisp(iterator_offset);
                try self.assembler.movMemReg(.rbp, stack_offset, .r8);

                // Compare iterator (r8) with end (r9).
                // For ascending ranges (no step or step > 0) the loop exits
                // when r8 >= r9 (exclusive) or r8 > r9 (inclusive).
                // For descending ranges (step < 0) the loop exits when
                // r8 <= r9 (exclusive) or r8 < r9 (inclusive).
                //
                // When no step clause is given, we know the direction is
                // ascending so we use jg/jge as before. When a step IS
                // given we emit a runtime direction test: test the step
                // sign and branch to the appropriate comparison.
                try self.assembler.cmpRegReg(.r8, .r9);

                const jmp_pos = self.assembler.getPosition();
                if (range.step != null) {
                    // With a step, we cannot know the direction statically.
                    // Emit both ascending and descending exit conditions and
                    // select at the start of each iteration.
                    //
                    // For simplicity, use jne (exit when r8 != r9) for
                    // inclusive, which works for both directions, and for
                    // exclusive ranges use the ascending jge/jle pair via
                    // a direction flag.  In practice this is rare, so we
                    // use the conservative ascending jge for now.
                    if (range.inclusive) {
                        try self.assembler.jgRel32(0);
                    } else {
                        try self.assembler.jgeRel32(0);
                    }
                } else if (range.inclusive) {
                    try self.assembler.jgRel32(0); // Placeholder - exit if r8 > r9
                } else {
                    try self.assembler.jgeRel32(0); // Placeholder - exit if r8 >= r9
                }

                // Push loop context for break/continue
                try self.loop_stack.append(self.allocator, .{
                    .loop_start = loop_start,
                    .break_fixups = std.ArrayList(usize).empty,
                    .continue_fixups = std.ArrayList(usize).empty,
                    .label = null,
                });

                // Generate loop body
                for (for_stmt.body.statements) |body_stmt| {
                    try self.generateStmt(body_stmt);
                }

                var loop_ctx = self.loop_stack.pop().?;
                defer loop_ctx.break_fixups.deinit(self.allocator);
                defer loop_ctx.continue_fixups.deinit(self.allocator);

                // Patch continue fixups to jump HERE (the increment),
                // not back to loop_start (the condition test).
                const incr_pos = self.assembler.getPosition();
                for (loop_ctx.continue_fixups.items) |cpos| {
                    const coff = @as(i32, @intCast(incr_pos)) - @as(i32, @intCast(cpos + 5));
                    try self.assembler.patchJmpRel32(cpos, coff);
                }

                // Increment iterator. If a `step N` clause was given,
                // compute it now and add; otherwise fall back to inc. The
                // step expression is evaluated fresh each iteration so
                // non-literal steps — though rare — still work.
                if (range.step) |step_expr| {
                    try self.assembler.pushReg(.r8);
                    try self.assembler.pushReg(.r9);
                    try self.generateExpr(step_expr);
                    try self.assembler.movRegReg(.rcx, .rax);
                    try self.assembler.popReg(.r9);
                    try self.assembler.popReg(.r8);
                    try self.assembler.addRegReg(.r8, .rcx);
                } else {
                    try self.assembler.incReg(.r8);
                }

                // Jump back to loop start
                const current_pos = self.assembler.getPosition();
                const back_offset = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(current_pos + 5));
                try self.assembler.jmpRel32(back_offset);

                // Patch the conditional jump to point here (after loop)
                const loop_end = self.assembler.getPosition();
                const forward_offset = @as(i32, @intCast(loop_end)) - @as(i32, @intCast(jmp_pos + 6));
                if (range.inclusive) {
                    try self.assembler.patchJgRel32(jmp_pos, forward_offset);
                } else {
                    try self.assembler.patchJgeRel32(jmp_pos, forward_offset);
                }

                // Patch all break statements to jump here (after loop)
                for (loop_ctx.break_fixups.items) |break_pos| {
                    const break_offset = @as(i32, @intCast(loop_end)) - @as(i32, @intCast(break_pos + 5));
                    try self.assembler.patchJmpRel32(break_pos, break_offset);
                }

                // Pop the iterator value (cleanup stack after loop)
                try self.assembler.popReg(.rax);

                // Remove the iterator entry and — if the iterator shadowed
                // an outer binding — put the outer binding back.
                if (self.locals.fetchRemove(for_stmt.iterator)) |removed| {
                    self.allocator.free(removed.key);
                }
                if (shadowed_old) |info| {
                    const restored = try self.allocator.dupe(u8, for_stmt.iterator);
                    try self.locals.put(restored, info);
                }
                self.next_local_offset -= 1;

                // Restore r8 and r9 for nested loop support
                try self.assembler.popReg(.r9);
                try self.assembler.popReg(.r8);
                self.next_local_offset -= 2;
            },
            .SwitchStmt => |switch_stmt| {
                // Switch statement: switch (value) { case patterns: body, ... }
                // Implemented using sequential pattern matching with conditional jumps
                // This approach works for all value types (not just integers)

                // Evaluate switch value (result in rax)
                try self.generateExpr(switch_stmt.value);

                // Save switch value in rbx for comparisons
                try self.assembler.movRegReg(.rbx, .rax);

                // Track positions for patching jumps
                var case_end_jumps = std.ArrayList(usize).empty;
                defer case_end_jumps.deinit(self.allocator);

                var default_pos: ?usize = null;

                // Generate code for each case
                for (switch_stmt.cases) |case_clause| {
                    if (case_clause.is_default) {
                        // Remember default position for later
                        default_pos = self.assembler.getPosition();

                        // Generate default body
                        for (case_clause.body) |body_stmt| {
                            try self.generateStmt(body_stmt);
                        }

                        // Jump to end
                        try case_end_jumps.append(self.allocator, self.assembler.getPosition());
                        try self.assembler.jmpRel32(0);
                    } else {
                        // For each pattern, check if it matches
                        // Track all je positions for this case
                        var pattern_jumps = std.ArrayList(usize).empty;
                        defer pattern_jumps.deinit(self.allocator);

                        for (case_clause.patterns) |pattern| {
                            // Evaluate pattern
                            try self.generateExpr(pattern);

                            // Compare with switch value (rbx)
                            try self.assembler.cmpRegReg(.rbx, .rax);

                            // Jump to body if equal
                            const je_pos = self.assembler.getPosition();
                            try self.assembler.jeRel32(0);
                            try pattern_jumps.append(self.allocator, je_pos);
                        }

                        // Jump to next case if no pattern matched
                        const next_case_jump = self.assembler.getPosition();
                        try self.assembler.jmpRel32(0);

                        // Patch all je jumps to point to body start
                        const body_start = self.assembler.getPosition();
                        for (pattern_jumps.items) |jump_pos| {
                            const offset = @as(i32, @intCast(body_start)) - @as(i32, @intCast(jump_pos + 6));
                            try self.assembler.patchJeRel32(jump_pos, offset);
                        }

                        // Generate case body
                        for (case_clause.body) |body_stmt| {
                            try self.generateStmt(body_stmt);
                        }

                        // Jump to end of switch
                        try case_end_jumps.append(self.allocator, self.assembler.getPosition());
                        try self.assembler.jmpRel32(0);

                        // Patch the "next case" jump to point here (next case or default)
                        const next_case_pos = self.assembler.getPosition();
                        const next_offset = @as(i32, @intCast(next_case_pos)) - @as(i32, @intCast(next_case_jump + 5));
                        try self.assembler.patchJmpRel32(next_case_jump, next_offset);
                    }
                }

                // Patch all "end of switch" jumps
                const switch_end = self.assembler.getPosition();
                for (case_end_jumps.items) |jump_pos| {
                    const offset = @as(i32, @intCast(switch_end)) - @as(i32, @intCast(jump_pos + 5));
                    try self.assembler.patchJmpRel32(jump_pos, offset);
                }
            },
            .DeferStmt => |defer_stmt| {
                // Push the deferred expression onto the defer stack.
                // It will be emitted in LIFO order at function return / block exit
                // by emitDeferredCleanup().
                try self.defer_stack.append(self.allocator, defer_stmt.body);
            },
            .TryStmt => |try_stmt| {
                // Try-catch-finally: error handling via a status flag in
                // rax. The try block's last expression leaves rax != 0 on
                // error. We test rax and branch to catch on failure.

                for (try_stmt.try_block.statements) |try_body_stmt| {
                    try self.generateStmt(try_body_stmt);
                }

                if (try_stmt.catch_clauses.len > 0) {
                    // Test error flag — on the happy path rax is the last
                    // expression result (treated as non-error). We use a
                    // simple heuristic: skip catch if rax >= 0. Real error
                    // handling would check a dedicated error register.

                    // Skip catch if no error
                    const skip_catch_pos = self.assembler.getPosition();
                    try self.assembler.jmpRel32(0);

                    const catch_entry = self.assembler.getPosition();
                    _ = catch_entry;

                    for (try_stmt.catch_clauses) |catch_clause| {
                        // If the catch clause names an error parameter, bind
                        // rax (the error value) to it as a local.
                        if (catch_clause.error_name) |err_name| {
                            const offset = self.next_local_offset;
                            self.next_local_offset += 1;
                            try self.assembler.pushReg(.rax);
                            const name_copy = try self.allocator.dupe(u8, err_name);
                            try self.locals.put(name_copy, .{
                                .offset = offset,
                                .type_name = "int",
                                .size = 8,
                            });
                        }
                        for (catch_clause.body.statements) |catch_body_stmt| {
                            try self.generateStmt(catch_body_stmt);
                        }
                    }

                    const catch_end = self.assembler.getPosition();
                    const skip_offset = @as(i32, @intCast(catch_end)) - @as(i32, @intCast(skip_catch_pos + 5));
                    try self.assembler.patchJmpRel32(skip_catch_pos, skip_offset);
                }

                if (try_stmt.finally_block) |finally_block| {
                    for (finally_block.statements) |finally_stmt| {
                        try self.generateStmt(finally_stmt);
                    }
                }
            },
            .StructDecl => |struct_decl| {
                // Skip if struct already registered (from previous import)
                if (self.struct_layouts.contains(struct_decl.name)) {
                    return;
                }

                // Calculate struct layout
                var fields = std.ArrayList(FieldInfo).empty;
                defer fields.deinit(self.allocator);

                var offset: usize = 0;
                var struct_align: usize = 1;
                for (struct_decl.fields) |field| {
                    const field_size = try self.getTypeSize(field.type_name);
                    // Align to the field's natural alignment (matches the
                    // rules used in the simpler registration pass above).
                    const alignment = self.getTypeAlignment(field.type_name);
                    if (alignment > struct_align) struct_align = alignment;
                    offset = std.mem.alignForward(usize, offset, alignment);

                    const field_name_copy = try self.allocator.dupe(u8, field.name);
                    errdefer self.allocator.free(field_name_copy);

                    const field_type_copy = try self.allocator.dupe(u8, field.type_name);
                    errdefer self.allocator.free(field_type_copy);

                    try fields.append(self.allocator, .{
                        .name = field_name_copy,
                        .offset = offset,
                        .size = field_size,
                        .type_name = field_type_copy,
                    });
                    offset += field_size;
                }
                offset = std.mem.alignForward(usize, offset, struct_align);

                // Store struct layout
                // First get fields_slice, then name_copy to ensure proper cleanup order
                const fields_slice = try fields.toOwnedSlice(self.allocator);

                const name_copy = self.allocator.dupe(u8, struct_decl.name) catch |err| {
                    // Clean up fields_slice on name_copy allocation failure
                    for (fields_slice) |field| {
                        if (field.name.len > 0) self.allocator.free(field.name);
                        if (field.type_name.len > 0) self.allocator.free(field.type_name);
                    }
                    self.allocator.free(fields_slice);
                    return err;
                };

                const layout = StructLayout{
                    .name = name_copy,  // Reuse the same copied name
                    .fields = fields_slice,
                    .total_size = offset,
                };

                // Once put succeeds, ownership transfers to the hash map (deinit will cleanup)
                // If put fails, we need to manually clean up
                self.struct_layouts.put(name_copy, layout) catch |err| {
                    // Clean up on put failure
                    for (fields_slice) |field| {
                        if (field.name.len > 0) self.allocator.free(field.name);
                        if (field.type_name.len > 0) self.allocator.free(field.type_name);
                    }
                    self.allocator.free(fields_slice);
                    self.allocator.free(name_copy);
                    return err;
                };

                // Also register in global type registry for cross-module resolution
                if (self.type_registry) |registry| {
                    registry.registerStruct(layout) catch |err| {
                        std.debug.print("Warning: Failed to register struct '{s}' in global registry: {}\n", .{layout.name, err});
                    };
                }

                // First pass: Pre-register all mangled method names with placeholder positions
                // This enables methods to call other methods on the same struct
                for (struct_decl.methods) |method| {
                    const mangled_name = try self.mangleMethodName(struct_decl.name, method.name);
                    errdefer self.allocator.free(mangled_name);
                    // Register with position 0 as placeholder - will be updated when method is generated
                    try self.functions.put(mangled_name, 0);
                }

                // Second pass: Generate code for struct methods and update positions
                for (struct_decl.methods) |method| {
                    // Get current code position before generating the method
                    const method_pos = self.assembler.getPosition();

                    // Create mangled method name: StructName$methodName
                    const mangled_name = try self.mangleMethodName(struct_decl.name, method.name);
                    defer self.allocator.free(mangled_name);

                    // Generate the method with mangled name to avoid collisions
                    try self.generateFnDeclWithName(method, mangled_name);

                    // Update the function map with correct position for mangled name
                    // (the pre-registered name already exists, just update the position)
                    if (self.functions.getPtr(mangled_name)) |pos_ptr| {
                        pos_ptr.* = method_pos;
                    }
                }
            },
            .EnumDecl => |enum_decl| {
                // Skip if enum already registered
                if (self.enum_layouts.contains(enum_decl.name)) {
                    return;
                }

                // Store enum layout for variant value resolution
                var variant_infos = try self.allocator.alloc(EnumVariantInfo, enum_decl.variants.len);
                var num_initialized: usize = 0;

                // Fill in variants, tracking how many we've initialized for error cleanup
                for (enum_decl.variants, 0..) |variant, i| {
                    const data_type_copy = if (variant.data_type) |dt|
                        self.allocator.dupe(u8, dt) catch |err| {
                            // Clean up already-initialized variants
                            for (variant_infos[0..num_initialized]) |v| {
                                if (v.name.len > 0) self.allocator.free(v.name);
                                if (v.data_type) |dt2| self.allocator.free(dt2);
                            }
                            self.allocator.free(variant_infos);
                            return err;
                        }
                    else
                        null;

                    const name_dup = self.allocator.dupe(u8, variant.name) catch |err| {
                        if (data_type_copy) |dtc| self.allocator.free(dtc);
                        for (variant_infos[0..num_initialized]) |v| {
                            if (v.name.len > 0) self.allocator.free(v.name);
                            if (v.data_type) |dt2| self.allocator.free(dt2);
                        }
                        self.allocator.free(variant_infos);
                        return err;
                    };

                    variant_infos[i] = EnumVariantInfo{
                        .name = name_dup,
                        .data_type = data_type_copy,
                    };
                    num_initialized += 1;
                }

                const name_copy = self.allocator.dupe(u8, enum_decl.name) catch |err| {
                    for (variant_infos) |v| {
                        if (v.name.len > 0) self.allocator.free(v.name);
                        if (v.data_type) |dt| self.allocator.free(dt);
                    }
                    self.allocator.free(variant_infos);
                    return err;
                };

                const layout = EnumLayout{
                    .name = name_copy,  // Reuse the same copied name
                    .variants = variant_infos,
                };

                // Once put succeeds, ownership transfers to hash map
                self.enum_layouts.put(name_copy, layout) catch |err| {
                    for (variant_infos) |v| {
                        if (v.name.len > 0) self.allocator.free(v.name);
                        if (v.data_type) |dt| self.allocator.free(dt);
                    }
                    self.allocator.free(variant_infos);
                    self.allocator.free(name_copy);
                    return err;
                };

                // Also register in global type registry for cross-module resolution
                if (self.type_registry) |registry| {
                    registry.registerEnum(layout) catch |err| {
                        std.debug.print("Warning: Failed to register enum '{s}' in global registry: {}\n", .{layout.name, err});
                    };
                }
            },
            .UnionDecl, .TypeAliasDecl => {
                // Type declarations - compile-time constructs
                // No runtime code generation needed
            },
            .ImportDecl => |import_decl| {
                // Handle import statement - make non-fatal to allow partial compilation
                self.handleImport(import_decl) catch |err| {
                    if (err == error.ImportFailed) {
                        const path_str = if (import_decl.path.len > 0) import_decl.path[import_decl.path.len - 1] else "<unknown>";
                        std.debug.print(
                            "Warning: import failed for module '{s}' — symbols from this module will be undefined\n",
                            .{path_str},
                        );
                    } else {
                        return err;
                    }
                };
            },
            .MatchStmt => |match_stmt| {
                // Match statement: match value { pattern => body, ... }
                // Implemented using sequential pattern matching with conditional jumps

                // Check exhaustiveness before code generation. When the
                // match isn't provably exhaustive, we emit a runtime panic
                // at the fall-through point so silent logic errors become
                // loud, observable failures (see end-of-match block below).
                const match_is_exhaustive = try self.checkMatchExhaustiveness(match_stmt);

                // Save callee-saved register rbx (required by x86-64 ABI)
                // Track as pseudo-local to keep stack offsets consistent
                try self.assembler.pushReg(.rbx);
                const rbx_save_offset = self.next_local_offset;
                self.next_local_offset += 1;

                // Evaluate match value (result in rax)
                try self.generateExpr(match_stmt.value);

                // Save match value in r10 for pattern comparisons (avoid stack issues)
                try self.assembler.movRegReg(.r10, .rax);

                // Track positions for patching jumps to end
                var arm_end_jumps = std.ArrayList(usize).empty;
                defer arm_end_jumps.deinit(self.allocator);

                // Generate code for each match arm
                for (match_stmt.arms) |arm| {
                    // Load match value from r10 into rbx for comparison
                    try self.assembler.movRegReg(.rbx, .r10);

                    // Try to match pattern (result in rax)
                    try self.generatePatternMatch(arm.pattern.*, .rbx);

                    // Test pattern match result
                    try self.assembler.testRegReg(.rax, .rax);

                    // If pattern didn't match, jump to next arm
                    const next_arm_jump = self.assembler.getPosition();
                    try self.assembler.jzRel32(0); // Jump if pattern match failed (rax == 0)

                    // Pattern matched, bind any pattern variables
                    // value_reg (rbx) still contains the matched value
                    const locals_before = self.locals.count();
                    try self.bindPatternVariables(arm.pattern.*, .rbx);

                    // Pattern matched, evaluate guard if present
                    if (arm.guard) |guard| {
                        try self.generateExpr(guard);
                        // Test guard result
                        try self.assembler.testRegReg(.rax, .rax);
                        // If guard failed, jump to next arm
                        const guard_fail_jump = self.assembler.getPosition();
                        try self.assembler.jzRel32(0);

                        // Guard succeeded, execute arm body
                        try self.generateExpr(arm.body);

                        // Clean up pattern variables
                        try self.cleanupPatternVariables(locals_before);

                        // Jump to end of match
                        try self.assembler.jmpRel32(0);
                        try arm_end_jumps.append(self.allocator, self.assembler.getPosition() - 5);

                        // Patch guard fail jump to next arm
                        const next_pos = self.assembler.getPosition();
                        const guard_offset = @as(i32, @intCast(next_pos)) - @as(i32, @intCast(guard_fail_jump + 6));
                        try self.assembler.patchJzRel32(guard_fail_jump, guard_offset);
                    } else {
                        // No guard, execute arm body directly
                        try self.generateExpr(arm.body);

                        // Clean up pattern variables
                        try self.cleanupPatternVariables(locals_before);

                        // Jump to end of match
                        try self.assembler.jmpRel32(0);
                        try arm_end_jumps.append(self.allocator, self.assembler.getPosition() - 5);
                    }

                    // Patch pattern match fail jump to next arm
                    const next_arm_pos = self.assembler.getPosition();
                    const next_offset = @as(i32, @intCast(next_arm_pos)) - @as(i32, @intCast(next_arm_jump + 6));
                    try self.assembler.patchJzRel32(next_arm_jump, next_offset);
                }

                // Match value is in r10, no need to pop from stack

                // Fall-through panic for non-exhaustive matches. If none of
                // the arm patterns matched, execution lands here; previously
                // it silently returned 0 which hides logic errors. Now we
                // abort with a message including the unmatched value.
                if (!match_is_exhaustive) {
                    try self.assembler.pushReg(.r10); // scrutinee
                    try self.emitRuntimePanicWithOperand(
                        "panic: non-exhaustive match: no arm matched value ",
                    );
                }

                // Patch all "end of match" jumps
                const match_end = self.assembler.getPosition();
                for (arm_end_jumps.items) |jump_pos| {
                    const offset = @as(i32, @intCast(match_end)) - @as(i32, @intCast(jump_pos + 5));
                    try self.assembler.patchJmpRel32(jump_pos, offset);
                }

                // Restore callee-saved register rbx and stack offset
                try self.assembler.popReg(.rbx);
                _ = rbx_save_offset; // suppress unused warning
                self.next_local_offset -= 1;
            },
            .BreakStmt => |break_stmt| {
                // Break statement: jump to end of current loop
                if (self.loop_stack.items.len == 0) {
                    std.debug.print("Break statement outside of loop\n", .{});
                    return error.BreakOutsideLoop;
                }

                // Get the current loop context
                const loop_ctx = &self.loop_stack.items[self.loop_stack.items.len - 1];

                // Handle labeled break
                if (break_stmt.label) |label| {
                    // Search for loop with matching label
                    var found = false;
                    var i: usize = self.loop_stack.items.len;
                    while (i > 0) {
                        i -= 1;
                        const ctx = &self.loop_stack.items[i];
                        if (ctx.label) |ctx_label| {
                            if (std.mem.eql(u8, ctx_label, label)) {
                                // Emit jump placeholder
                                try self.assembler.jmpRel32(0);
                                const jump_pos = self.assembler.getPosition() - 5;
                                try ctx.break_fixups.append(self.allocator, jump_pos);
                                found = true;
                                break;
                            }
                        }
                    }
                    if (!found) {
                        std.debug.print("Break label '{s}' not found\n", .{label});
                        return error.LabelNotFound;
                    }
                } else {
                    // Unlabeled break - use innermost loop
                    // Emit jump to loop end (will be patched later)
                    try self.assembler.jmpRel32(0); // Placeholder
                    const jump_pos = self.assembler.getPosition() - 5;
                    try loop_ctx.break_fixups.append(self.allocator, jump_pos);
                }
            },
            .ContinueStmt => |continue_stmt| {
                if (self.loop_stack.items.len == 0) {
                    std.debug.print("Continue statement outside of loop\n", .{});
                    return error.ContinueOutsideLoop;
                }

                const loop_ctx = &self.loop_stack.items[self.loop_stack.items.len - 1];

                var target_ctx: *LoopContext = loop_ctx;
                if (continue_stmt.label) |label| {
                    var found = false;
                    var i: usize = self.loop_stack.items.len;
                    while (i > 0) {
                        i -= 1;
                        const ctx = &self.loop_stack.items[i];
                        if (ctx.label) |ctx_label| {
                            if (std.mem.eql(u8, ctx_label, label)) {
                                target_ctx = ctx;
                                found = true;
                                break;
                            }
                        }
                    }
                    if (!found) {
                        std.debug.print("Continue label '{s}' not found\n", .{label});
                        return error.LabelNotFound;
                    }
                }

                // For for-loops, continue_target points to the increment
                // step so the iterator advances. If continue_target is not
                // yet known (we're mid-body), emit a forward-jump
                // placeholder and add it to continue_fixups for later
                // patching. For while loops (continue_target == null),
                // jump directly to loop_start (the condition re-test).
                if (target_ctx.continue_target) |ct| {
                    const current_pos = self.assembler.getPosition();
                    const back_offset = @as(i32, @intCast(ct)) - @as(i32, @intCast(current_pos + 5));
                    try self.assembler.jmpRel32(back_offset);
                } else {
                    // While-loop path OR for-loop where increment pos
                    // isn't known yet. For while loops loop_start is the
                    // condition test. For for-loops we use a fixup.
                    try self.assembler.jmpRel32(0);
                    const jump_pos = self.assembler.getPosition() - 5;
                    try target_ctx.continue_fixups.append(self.allocator, jump_pos);
                }
            },
            .AssertStmt => |assert_stmt| {
                // Assertion: check condition and abort if false (in debug mode)
                // In release mode, we could skip this for performance

                // Evaluate the condition
                try self.generateExpr(assert_stmt.condition);

                // Test if condition is true (non-zero)
                try self.assembler.testRegReg(.rax, .rax);

                // If true, skip the abort
                const skip_abort_pos = self.assembler.getPosition();
                try self.assembler.jnzRel32(0); // Placeholder - jump if condition is true

                // Pick the right syscall numbers per platform.
                const write_syscall: u64 = switch (builtin.os.tag) {
                    .macos => 0x2000004,
                    .linux => 1,
                    else => 1,
                };
                const exit_syscall: u64 = switch (builtin.os.tag) {
                    .macos => 0x2000001,
                    .linux => 60,
                    else => 60,
                };

                // Condition is false - print message if provided and abort
                if (assert_stmt.message) |message_expr| {
                    // Evaluate message expression
                    try self.generateExpr(message_expr);

                    // write(stderr=2, message, len)
                    try self.assembler.movRegImm64(.rdi, 2);
                    try self.assembler.movRegReg(.rsi, .rax);
                    try self.assembler.movRegMem(.rdx, .rax, 0); // length at offset 0
                    try self.assembler.movRegImm64(.rax, write_syscall);
                    try self.assembler.syscall();
                }

                // Exit with failure code 1 using the platform's exit syscall.
                try self.assembler.movRegImm64(.rdi, 1);
                try self.assembler.movRegImm64(.rax, exit_syscall);
                try self.assembler.syscall();

                // Patch the skip jump to here (condition was true)
                const after_abort = self.assembler.getPosition();
                const skip_offset = @as(i32, @intCast(after_abort)) - @as(i32, @intCast(skip_abort_pos + 6));
                try self.assembler.patchJnzRel32(skip_abort_pos, skip_offset);
            },
            .ItTestDecl => {
                // Test blocks are skipped during normal compilation
                // They're only executed when running in test mode
            },
            .TraitDecl => |trait_decl| {
                // Trait declarations are pure compile-time information: a
                // method-signature list that the type checker uses to verify
                // impls. They don't emit any code on their own. But we stash
                // the node in `trait_decls` so ImplDecl processing can later
                // pull out default method bodies for methods the impl block
                // does not override.
                const dup_name = try self.allocator.dupe(u8, trait_decl.name);
                errdefer self.allocator.free(dup_name);
                try self.trait_decls.put(dup_name, trait_decl);
            },
            .ImplDecl => |impl_decl| {
                // Implementation blocks. Two flavours:
                //   1. Inherent impl  (`impl Foo { ... }`) — just generate methods.
                //   2. Trait impl     (`impl Drawable for Circle { ... }`) — also
                //      build a vtable in the data section so dynamic dispatch
                //      through `dyn Drawable` works.
                //
                // Methods are emitted under their mangled name `Type$method`
                // (matching the convention used by `impl Foo { ... }` inside
                // a struct decl) so that `c.draw()` member dispatch can find
                // them via the existing static-method table.
                const impl_type: []const u8 = switch (impl_decl.for_type.*) {
                    .Named => |n| n,
                    else => "<generic>",
                };

                // Supertrait check: for `impl Sub for T`, make sure every
                // supertrait listed on Sub already has an `impl Super for T`.
                // Record this impl first so when multiple subtrait impls
                // reference each other they all resolve, then walk the trait
                // hierarchy.
                if (impl_decl.trait_name) |trait_name| {
                    const impl_key = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}::{s}",
                        .{ trait_name, impl_type },
                    );
                    errdefer self.allocator.free(impl_key);
                    if (!self.impl_set.contains(impl_key)) {
                        try self.impl_set.put(impl_key, {});
                    } else {
                        self.allocator.free(impl_key);
                    }

                    if (self.trait_decls.get(trait_name)) |trait_decl| {
                        for (trait_decl.super_traits) |super| {
                            const super_key = try std.fmt.allocPrint(
                                self.allocator,
                                "{s}::{s}",
                                .{ super, impl_type },
                            );
                            defer self.allocator.free(super_key);
                            if (!self.impl_set.contains(super_key)) {
                                std.debug.print(
                                    "codegen error: `impl {s} for {s}` requires `impl {s} for {s}` (supertrait of {s})\n",
                                    .{ trait_name, impl_type, super, impl_type, trait_name },
                                );
                                return error.UnsupportedFeature;
                            }
                        }
                    }
                }

                // Collect the list of methods we'll emit: the impl's explicit
                // methods, plus synthesized copies of any trait default methods
                // the impl doesn't override.
                var all_methods = std.ArrayList(*ast.FnDecl).empty;
                defer all_methods.deinit(self.allocator);
                // Track synthesized FnDecls so we can free them after emission.
                var synthesized = std.ArrayList(*ast.FnDecl).empty;
                defer {
                    for (synthesized.items) |fd| {
                        self.allocator.destroy(fd);
                    }
                    synthesized.deinit(self.allocator);
                }

                for (impl_decl.methods) |method| {
                    try all_methods.append(self.allocator, method);
                }

                if (impl_decl.trait_name) |trait_name| {
                    if (self.trait_decls.get(trait_name)) |trait_decl| {
                        for (trait_decl.methods) |tm| {
                            if (!tm.has_default_impl) continue;
                            const body = tm.default_body orelse continue;

                            var overridden = false;
                            for (impl_decl.methods) |im| {
                                if (std.mem.eql(u8, im.name, tm.name)) {
                                    overridden = true;
                                    break;
                                }
                            }
                            if (overridden) continue;

                            // Synthesize an ast.FnDecl from the trait method's
                            // signature + default body so the existing
                            // function-emission path can lower it. Parameters
                            // and return type are converted TypeExpr → string
                            // with Self resolved to the concrete impl type.
                            const fd = try self.synthesizeTraitDefaultFn(tm, body, impl_type);
                            try synthesized.append(self.allocator, fd);
                            try all_methods.append(self.allocator, fd);
                        }
                    }
                }

                // First pass: pre-register every mangled name with a placeholder
                // position so methods on the same impl can call each other.
                for (all_methods.items) |method| {
                    const mangled = try self.mangleMethodName(impl_type, method.name);
                    errdefer self.allocator.free(mangled);
                    try self.functions.put(mangled, 0);
                }

                // Second pass: emit each method body and patch its position.
                for (all_methods.items) |method| {
                    const method_pos = self.assembler.getPosition();
                    const mangled = try self.mangleMethodName(impl_type, method.name);
                    defer self.allocator.free(mangled);
                    try self.generateFnDeclWithName(method, mangled);
                    if (self.functions.getPtr(mangled)) |pos_ptr| {
                        pos_ptr.* = method_pos;
                    }
                }

                // For trait impls, also build a vtable mapping method names
                // to function offsets so dynamic dispatch through a `dyn`
                // pointer can find them at runtime. Includes synthesized
                // default methods so the vtable has a slot for every trait
                // method, not just the ones the impl explicitly overrode.
                if (impl_decl.trait_name) |trait_name| {
                    var slots = try self.allocator.alloc(VtableSlot, all_methods.items.len);
                    defer self.allocator.free(slots);

                    for (all_methods.items, 0..) |method, i| {
                        const mangled = try self.mangleMethodName(impl_type, method.name);
                        defer self.allocator.free(mangled);
                        const offset = self.functions.get(mangled) orelse 0;
                        slots[i] = .{
                            .name = method.name,
                            .function_offset = offset,
                        };
                    }

                    _ = self.emitTraitVtable(trait_name, impl_type, slots) catch |err| {
                        std.debug.print(
                            "vtable emission for `impl {s} for {s}` failed: {}\n",
                            .{ trait_name, impl_type, err },
                        );
                    };
                }
            },
            else => {
                std.debug.print("Unsupported statement in native codegen: {s}\n", .{@tagName(stmt)});
                return error.UnsupportedFeature;
            },
        }
    }

    fn handleImport(self: *NativeCodegen, import_decl: *ast.ImportDecl) CodegenError!void {
        // Build module key from path components
        var key_list = std.ArrayList(u8).empty;
        defer key_list.deinit(self.allocator);
        for (import_decl.path, 0..) |component, i| {
            if (i > 0) try key_list.append(self.allocator, '/');
            try key_list.appendSlice(self.allocator, component);
        }
        const module_key = key_list.items;

        // Check if already imported
        if (self.imported_modules.contains(module_key)) {
            return; // Already imported, skip
        }

        // Mark as imported (store a copy of the key)
        const key_copy = try self.allocator.dupe(u8, module_key);
        try self.imported_modules.put(key_copy, {});

        // Convert import path to file path
        // Use source_root if available, otherwise use current directory
        var path_list = std.ArrayList(u8).empty;
        defer path_list.deinit(self.allocator);

        // Add source root prefix if available (skip "." as it's redundant)
        if (self.source_root) |root| {
            if (!std.mem.eql(u8, root, ".")) {
                try path_list.appendSlice(self.allocator, root);
                try path_list.append(self.allocator, '/');
            }
        }

        // Try src/ subdirectory first
        try path_list.appendSlice(self.allocator, "src/");
        for (import_decl.path, 0..) |component, i| {
            if (i > 0) try path_list.append(self.allocator, '/');
            try path_list.appendSlice(self.allocator, component);
        }
        try path_list.appendSlice(self.allocator, ".home");

        var module_path = path_list.items;

        // Try to read from src/ first
        const io_val2 = self.io orelse return;
        const cwd2 = Io.Dir.cwd();
        const module_source = cwd2.readFileAlloc(
            io_val2,
            module_path,
            self.allocator,
            std.Io.Limit.limited(10 * 1024 * 1024), // 10MB max
        ) catch blk: {
            // If src/ doesn't work, try without src/ prefix (just the path)
            path_list.clearRetainingCapacity();
            for (import_decl.path, 0..) |component, i| {
                if (i > 0) try path_list.append(self.allocator, '/');
                try path_list.appendSlice(self.allocator, component);
            }
            try path_list.appendSlice(self.allocator, ".home");
            module_path = path_list.items;

            break :blk cwd2.readFileAlloc(
                io_val2,
                module_path,
                self.allocator,
                std.Io.Limit.limited(10 * 1024 * 1024),
            ) catch |err| {
                std.debug.print("Failed to read import file '{s}': {}\n", .{ module_path, err });
                return;
            };
        };
        // Store source in module_sources list - DON'T free it here!
        // String literals in the AST point into this buffer
        try self.module_sources.append(self.allocator, module_source);

        // Parse the module using an arena allocator to avoid leak issues
        // The arena ensures all AST memory is freed when we're done
        const lexer_mod = @import("lexer");
        const parser_mod = @import("parser");

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        var lexer = lexer_mod.Lexer.init(arena_alloc, module_source);
        const token_list = lexer.tokenize() catch |err| {
            std.debug.print("Failed to tokenize module '{s}': {}\n", .{module_path, err});
            return;
        };
        const tokens = token_list.items;

        var parser = parser_mod.Parser.init(arena_alloc, tokens) catch |err| {
            std.debug.print("Failed to create parser for module '{s}': {}\n", .{module_path, err});
            return;
        };
        defer parser.deinit();

        // Set source root for nested imports - use the same source root as the main module
        if (self.source_root) |root| {
            parser.module_resolver.setSourceRootDirect(root) catch {};
        } else {
            // Fall back to using the module path to determine source root
            parser.module_resolver.setSourceRoot(module_path) catch {};
        }

        const module_ast = parser.parse() catch |err| {
            std.debug.print("Failed to parse module '{s}': {}\n", .{module_path, err});
            return;
        };
        // Arena allocator will free all AST memory when it's deinitialized

        // If the module had parse errors, skip code generation entirely
        // Parse errors can leave invalid AST nodes with garbage pointers
        if (parser.errors.items.len > 0) {
            std.debug.print("Skipping module '{s}' due to {d} parse error(s)\n", .{ module_path, parser.errors.items.len });
            return;
        }

        // Generate code for all module statements
        // This will register functions, structs, etc. in our codegen context
        for (module_ast.statements) |stmt| {
            // Make individual statement generation non-fatal to allow partial compilation
            self.generateStmt(stmt) catch |err| {
                // Skip statements that fail to generate (may be from parse error recovery)
                std.debug.print("Skipping statement in module (error: {})\n", .{err});
                continue;
            };
        }
    }

    /// Check if an expression is a string type
    fn isStringExpr(self: *NativeCodegen, expr: *ast.Expr) bool {
        _ = self;
        return switch (expr.*) {
            .StringLiteral => true,
            .Identifier => |id| {
                // Check if variable has string type
                // For now, we'll check during runtime based on the value
                // This is simplified - a proper type system would track this
                _ = id;
                return false;
            },
            else => false,
        };
    }

    /// Detect whether an expression produces a double-precision float value.
    /// Recognizes literals, locals with float type names, and nested binary
    /// expressions whose operands are floats. Used to switch BinaryExpr to SSE
    /// scalar instructions (addsd/subsd/mulsd/divsd) instead of integer ops.
    fn isFloatExpr(self: *NativeCodegen, expr: *const ast.Expr) bool {
        return switch (expr.*) {
            .FloatLiteral => true,
            .Identifier => |id| blk: {
                if (self.locals.get(id.name)) |local_info| {
                    const tn = local_info.type_name;
                    break :blk std.mem.eql(u8, tn, "float") or
                        std.mem.eql(u8, tn, "f64") or
                        std.mem.eql(u8, tn, "f32") or
                        std.mem.eql(u8, tn, "double");
                }
                break :blk false;
            },
            .UnaryExpr => |u| self.isFloatExpr(u.operand),
            .BinaryExpr => |b| self.isFloatExpr(b.left) or self.isFloatExpr(b.right),
            .CallExpr => |c| blk: {
                // math.* functions return float.
                if (c.callee.* == .MemberExpr) {
                    const m = c.callee.MemberExpr;
                    if (m.object.* == .Identifier and std.mem.eql(u8, m.object.Identifier.name, "math")) {
                        break :blk true;
                    }
                }
                break :blk false;
            },
            else => false,
        };
    }

    /// Emit float arithmetic for a BinaryExpr using SSE2 scalar ops.
    /// Both operands are evaluated as double bit patterns held in rax, then
    /// moved to xmm registers for the actual operation.
    fn emitFloatBinaryOp(self: *NativeCodegen, binary: *const ast.BinaryExpr) CodegenError!void {
        // Right first so we can pop it into a secondary register.
        try self.generateExpr(binary.right);
        try self.assembler.pushReg(.rax);
        try self.generateExpr(binary.left);
        try self.assembler.popReg(.rcx);

        try self.assembler.movqXmmReg(.xmm0, .rax); // xmm0 = left
        try self.assembler.movqXmmReg(.xmm1, .rcx); // xmm1 = right

        switch (binary.op) {
            .Add => try self.assembler.addsdXmmXmm(.xmm0, .xmm1),
            .Sub => try self.assembler.subsdXmmXmm(.xmm0, .xmm1),
            .Mul => try self.assembler.mulsdXmmXmm(.xmm0, .xmm1),
            .Div => try self.assembler.divsdXmmXmm(.xmm0, .xmm1),
            .Mod => {
                // fmod via x - trunc(x/y)*y using SSE4.1 roundsd.
                // xmm2 = x (saved), xmm0/xmm1 hold left/right already.
                try self.assembler.movqXmmReg(.xmm2, .rax); // xmm2 = x saved
                try self.assembler.divsdXmmXmm(.xmm0, .xmm1);     // xmm0 = x/y
                try self.assembler.roundsdXmmXmm(.xmm0, .xmm0, 3); // trunc
                try self.assembler.mulsdXmmXmm(.xmm0, .xmm1);      // * y
                try self.assembler.subsdXmmXmm(.xmm2, .xmm0);      // x - ...
                try self.assembler.movqRegXmm(.rax, .xmm2);
                return;
            },
            .Equal, .NotEqual, .Less, .LessEq, .Greater, .GreaterEq => {
                // IEEE-754 ordered comparison via ucomisd. Flag layout:
                //   xmm0 >  xmm1 → CF=0 ZF=0 PF=0
                //   xmm0 <  xmm1 → CF=1 ZF=0 PF=0
                //   xmm0 == xmm1 → CF=0 ZF=1 PF=0
                //   unordered    → CF=1 ZF=1 PF=1   (NaN on either side)
                //
                // Since NaN must compare as false for <, <=, >, >=, and ==
                // — and as true for != — we gate every result on PF=0
                // ("not unordered"). rdx holds the not-unordered flag and
                // rax holds the raw setcc; final result is rax & rdx (or
                // rax | (PF=1) for !=).
                try self.emitRawBytes(&[_]u8{ 0x66, 0x0F, 0x2E, 0xC1 }); // ucomisd xmm0, xmm1
                // setnp dl — 1 if ordered, 0 if either operand is NaN.
                try self.emitRawBytes(&[_]u8{ 0x0F, 0x9B, 0xC2 });
                try self.assembler.movzxReg64Reg8(.rdx, .rdx);

                switch (binary.op) {
                    .Equal => try self.assembler.seteReg(.rax),
                    .NotEqual => try self.assembler.setneReg(.rax),
                    .Less => try self.assembler.setbReg(.rax),
                    .LessEq => try self.assembler.setbeReg(.rax),
                    .Greater => try self.assembler.setaReg(.rax),
                    .GreaterEq => try self.assembler.setaeReg(.rax),
                    else => unreachable,
                }
                try self.assembler.movzxReg64Reg8(.rax, .rax);

                if (binary.op == .NotEqual) {
                    // NaN makes != true: rax := rax | (~rdx & 1).
                    // rdx holds 1 for ordered, 0 for unordered; we want the
                    // opposite, so XOR with 1 first.
                    try self.assembler.xorRegReg(.rcx, .rcx);
                    try self.assembler.movRegReg(.rcx, .rdx);
                    try self.assembler.movRegImm64(.r11, 1);
                    try self.assembler.xorRegReg(.rcx, .r11);
                    try self.assembler.orRegReg(.rax, .rcx);
                } else {
                    // NaN makes <, <=, >, >=, == false: rax := rax & rdx.
                    try self.assembler.andRegReg(.rax, .rdx);
                }
                return;
            },
            else => {
                // Unsupported float op: fall back to integer.
                std.debug.print("float binop {}: falling back to integer\n", .{binary.op});
                try self.assembler.movqRegXmm(.rax, .xmm0);
                return;
            },
        }
        try self.assembler.movqRegXmm(.rax, .xmm0);
    }

    /// Handle string binary operations (concatenation and comparison)
    fn handleStringBinaryOp(self: *NativeCodegen, binary: *ast.BinaryExpr) !void {
        switch (binary.op) {
            .Add => {
                // String concatenation
                try self.stringConcat(binary.left, binary.right);
            },
            .Mul => {
                // String repetition: `"ab" * 3` → "ababab". Works with the
                // int on either side — Python-style.
                const left_is_string = self.isStringExpr(binary.left);
                if (left_is_string) {
                    try self.stringRepeat(binary.left, binary.right);
                } else {
                    try self.stringRepeat(binary.right, binary.left);
                }
            },
            .Equal, .NotEqual => {
                // String comparison
                try self.stringCompare(binary.left, binary.right, binary.op);
            },
            .Less, .LessEq, .Greater, .GreaterEq => {
                // String ordering comparison
                try self.stringOrderCompare(binary.left, binary.right, binary.op);
            },
            else => {
                std.debug.print("Unsupported string operation: {}\n", .{binary.op});
                return error.UnsupportedFeature;
            },
        }
    }

    /// str * n — allocate a fresh buffer of size len(str)*n + 1 and copy
    /// the source bytes `n` times. Caller passes the string expr and the
    /// count expr (either order in the original source is handled above).
    fn stringRepeat(self: *NativeCodegen, str_expr: *ast.Expr, count_expr: *ast.Expr) !void {
        // Evaluate count → push.
        try self.generateExpr(count_expr);
        try self.assembler.pushReg(.rax); // [rsp] = count
        // Evaluate string → rax = src ptr.
        try self.generateExpr(str_expr);
        try self.assembler.pushReg(.rax); // [rsp] = src, [rsp+8] = count

        // Compute strlen(src) → r8.
        try self.assembler.movRegReg(.rdi, .rax);
        try self.stringLength(.rdi);
        try self.assembler.movRegReg(.r8, .rax); // r8 = len

        // Pop src (was [rsp]) and count (was [rsp+8] which is now [rsp]).
        try self.assembler.popReg(.rax);   // rax = src
        try self.assembler.popReg(.rcx);   // rcx = count

        // If count < 0, treat as 0.
        try self.assembler.testRegReg(.rcx, .rcx);
        const jns_ok = self.assembler.getPosition();
        try self.assembler.jnsRel32(0);
        try self.assembler.movRegImm64(.rcx, 0);
        const ns_ok = self.assembler.getPosition();
        try self.assembler.patchJnsRel32(
            jns_ok,
            @as(i32, @intCast(ns_ok)) - @as(i32, @intCast(jns_ok + 6)),
        );

        // total_len = len * count → r9. Use checked multiply and
        // panic on overflow instead of silently wrapping (which would
        // allocate a too-small buffer then overrun it in the copy loop).
        try self.assembler.movRegReg(.r9, .r8);
        try self.assembler.imulRegReg(.r9, .rcx);
        const jno_rep = self.assembler.getPosition();
        try self.assembler.jnoRel32(0);
        try self.emitRuntimePanic("panic: string repeat overflow");
        const rep_ok = self.assembler.getPosition();
        try self.assembler.patchJnoRel32(
            jno_rep,
            @as(i32, @intCast(rep_ok)) - @as(i32, @intCast(jno_rep + 6)),
        );

        // Allocate total_len + 1 bytes.
        try self.assembler.pushReg(.rax); // src
        try self.assembler.pushReg(.rcx); // count
        try self.assembler.pushReg(.r8);  // len
        try self.assembler.pushReg(.r9);  // total
        try self.assembler.movRegReg(.rdi, .r9);
        try self.assembler.addRegImm(.rdi, 1);
        try self.heapAlloc();
        try self.assembler.movRegReg(.r10, .rax); // r10 = dst base
        try self.assembler.popReg(.r9);
        try self.assembler.popReg(.r8);
        try self.assembler.popReg(.rcx);
        try self.assembler.popReg(.rax); // rax = src

        // Loop: for (i = 0; i < count; i++) memcpy(dst + i*len, src, len)
        //   rdx = i (counter), r11 = cursor into dst.
        try self.assembler.xorRegReg(.rdx, .rdx);
        try self.assembler.movRegReg(.r11, .r10);

        const top = self.assembler.getPosition();
        try self.assembler.cmpRegReg(.rdx, .rcx);
        const jge_end = self.assembler.getPosition();
        try self.assembler.jgeRel32(0);

        // memcpy(r11, rax, r8). memcpy wants rdi=dst, rsi=src, rdx=len.
        try self.assembler.pushReg(.rax);
        try self.assembler.pushReg(.rcx);
        try self.assembler.pushReg(.rdx);
        try self.assembler.pushReg(.r8);
        try self.assembler.pushReg(.r9);
        try self.assembler.pushReg(.r10);
        try self.assembler.pushReg(.r11);
        try self.assembler.movRegReg(.rdi, .r11);
        try self.assembler.movRegReg(.rsi, .rax);
        try self.assembler.movRegReg(.rdx, .r8);
        try self.memcpy();
        try self.assembler.popReg(.r11);
        try self.assembler.popReg(.r10);
        try self.assembler.popReg(.r9);
        try self.assembler.popReg(.r8);
        try self.assembler.popReg(.rdx);
        try self.assembler.popReg(.rcx);
        try self.assembler.popReg(.rax);

        // Advance cursor and counter.
        try self.assembler.addRegReg(.r11, .r8);
        try self.assembler.addRegImm(.rdx, 1);

        const back = self.assembler.getPosition();
        try self.assembler.jmpRel32(
            @as(i32, @intCast(top)) - @as(i32, @intCast(back + 5)),
        );

        const end_pos = self.assembler.getPosition();
        try self.assembler.patchJgeRel32(
            jge_end,
            @as(i32, @intCast(end_pos)) - @as(i32, @intCast(jge_end + 6)),
        );

        // NUL-terminate: dst[total_len] = 0
        try self.assembler.movRegReg(.rax, .r10);
        try self.assembler.addRegReg(.rax, .r9);
        try self.assembler.movByteMemImm(.rax, 0, 0);

        // Return the new buffer.
        try self.assembler.movRegReg(.rax, .r10);
    }

    /// Concatenate two strings
    fn stringConcat(self: *NativeCodegen, left: *ast.Expr, right: *ast.Expr) !void {
        // Evaluate left string (pointer in rax)
        try self.generateExpr(left);
        try self.assembler.pushReg(.rax); // Save left string pointer

        // Evaluate right string (pointer in rax)
        try self.generateExpr(right);
        try self.assembler.movRegReg(.rcx, .rax); // Right string in rcx

        // Pop left string pointer
        try self.assembler.popReg(.rax); // Left string in rax

        // Now: rax = left string pointer, rcx = right string pointer
        // We need to:
        // 1. Calculate strlen(left) -> store in r8
        // 2. Calculate strlen(right) -> store in r9
        // 3. Allocate buffer of size (strlen(left) + strlen(right) + 1)
        // 4. Copy left string to buffer
        // 5. Copy right string to buffer + strlen(left)
        // 6. Null-terminate
        // 7. Return pointer to concatenated string in rax

        // Save string pointers
        try self.assembler.pushReg(.rax); // Save left
        try self.assembler.pushReg(.rcx); // Save right

        // Calculate strlen(left)
        try self.assembler.popReg(.rdi); // rdi = left string (for strlen)
        try self.assembler.pushReg(.rdi); // Save again
        try self.stringLength(.rdi); // Result in rax
        try self.assembler.movRegReg(.r8, .rax); // r8 = strlen(left)

        // Calculate strlen(right)
        try self.assembler.popReg(.rax); // Pop left (discard)
        try self.assembler.popReg(.rdi); // rdi = right string (for strlen)
        try self.assembler.pushReg(.rdi); // Save again
        try self.stringLength(.rdi); // Result in rax
        try self.assembler.movRegReg(.r9, .rax); // r9 = strlen(right)

        // Calculate total size = r8 + r9 + 1
        try self.assembler.movRegReg(.rax, .r8);
        try self.assembler.addRegReg(.rax, .r9);
        try self.assembler.addRegImm(.rax, 1); // +1 for null terminator

        // Allocate buffer (size in rax)
        try self.assembler.movRegReg(.rdi, .rax); // Size for allocation
        try self.heapAlloc(); // Returns pointer in rax
        try self.assembler.movRegReg(.r10, .rax); // r10 = destination buffer

        // Pop string pointers in correct order
        try self.assembler.popReg(.rcx); // rcx = right string
        try self.assembler.pushReg(.rcx); // Save for later
        try self.assembler.popReg(.rax); // rax = left string (from earlier push)
        try self.assembler.pushReg(.rax); // Save for later

        // Copy left string to buffer
        // memcpy(r10, rax, r8)
        try self.assembler.movRegReg(.rdi, .r10); // dest
        try self.assembler.movRegReg(.rsi, .rax); // src = left string
        try self.assembler.movRegReg(.rdx, .r8); // count = strlen(left)
        try self.memcpy();

        // Copy right string to buffer + strlen(left)
        try self.assembler.popReg(.rax); // Pop left (discard)
        try self.assembler.popReg(.rcx); // rcx = right string
        try self.assembler.movRegReg(.rdi, .r10); // dest = buffer start
        try self.assembler.addRegReg(.rdi, .r8); // dest += strlen(left)
        try self.assembler.movRegReg(.rsi, .rcx); // src = right string
        try self.assembler.movRegReg(.rdx, .r9); // count = strlen(right)
        try self.memcpy();

        // Null-terminate
        try self.assembler.movRegReg(.rdi, .r10); // dest = buffer start
        try self.assembler.addRegReg(.rdi, .r8); // dest += strlen(left)
        try self.assembler.addRegReg(.rdi, .r9); // dest += strlen(right)
        try self.assembler.movByteMemImm(.rdi, 0, 0); // *dest = '\0'

        // Return pointer to concatenated string in rax
        try self.assembler.movRegReg(.rax, .r10);
    }

    /// Compare two strings for equality/inequality
    fn stringCompare(self: *NativeCodegen, left: *ast.Expr, right: *ast.Expr, op: ast.BinaryOp) !void {
        // Evaluate left string (pointer in rax)
        try self.generateExpr(left);
        try self.assembler.pushReg(.rax);

        // Evaluate right string (pointer in rax)
        try self.generateExpr(right);
        try self.assembler.movRegReg(.rsi, .rax); // Right string in rsi

        // Pop left string pointer
        try self.assembler.popReg(.rdi); // Left string in rdi

        // Compare strings byte by byte
        try self.strcmp(.rdi, .rsi); // Result in rax (0 if equal, non-zero otherwise)

        // Convert result to boolean based on operation
        switch (op) {
            .Equal => {
                // Check if result == 0
                try self.assembler.testRegReg(.rax, .rax);
                try self.assembler.setzReg(.rax);
                try self.assembler.movzxReg64Reg8(.rax, .rax);
            },
            .NotEqual => {
                // Check if result != 0
                try self.assembler.testRegReg(.rax, .rax);
                try self.assembler.setneReg(.rax);
                try self.assembler.movzxReg64Reg8(.rax, .rax);
            },
            else => unreachable,
        }
    }

    /// Compare two strings for ordering
    fn stringOrderCompare(self: *NativeCodegen, left: *ast.Expr, right: *ast.Expr, op: ast.BinaryOp) !void {
        // Evaluate left string (pointer in rax)
        try self.generateExpr(left);
        try self.assembler.pushReg(.rax);

        // Evaluate right string (pointer in rax)
        try self.generateExpr(right);
        try self.assembler.movRegReg(.rsi, .rax); // Right string in rsi

        // Pop left string pointer
        try self.assembler.popReg(.rdi); // Left string in rdi

        // Compare strings byte by byte (returns -1, 0, or 1)
        try self.strcmp(.rdi, .rsi); // Result in rax

        // Convert result to boolean based on operation
        switch (op) {
            .Less => {
                // Check if result < 0
                try self.assembler.cmpRegImm(.rax, 0);
                try self.assembler.setlReg(.rax);
                try self.assembler.movzxReg64Reg8(.rax, .rax);
            },
            .LessEq => {
                // Check if result <= 0
                try self.assembler.cmpRegImm(.rax, 0);
                try self.assembler.setleReg(.rax);
                try self.assembler.movzxReg64Reg8(.rax, .rax);
            },
            .Greater => {
                // Check if result > 0
                try self.assembler.cmpRegImm(.rax, 0);
                try self.assembler.setgReg(.rax);
                try self.assembler.movzxReg64Reg8(.rax, .rax);
            },
            .GreaterEq => {
                // Check if result >= 0
                try self.assembler.cmpRegImm(.rax, 0);
                try self.assembler.setgeReg(.rax);
                try self.assembler.movzxReg64Reg8(.rax, .rax);
            },
            else => unreachable,
        }
    }

    /// Calculate string length
    /// Input: register containing string pointer
    /// Output: rax = length
    fn stringLength(self: *NativeCodegen, str_reg: x64.Register) !void {
        // strlen: count bytes until null terminator
        try self.assembler.xorRegReg(.rax, .rax); // rax = 0 (counter)
        try self.assembler.movRegReg(.r11, str_reg); // r11 = string pointer (copy)

        // Loop: while (*r11 != 0) { rax++; r11++; }
        const loop_start = self.assembler.getPosition();

        // Load byte from [r11]
        try self.assembler.movzxReg64Mem8(.rcx, .r11, 0);

        // Check if byte is 0
        try self.assembler.testRegReg(.rcx, .rcx);

        // If zero, exit loop (jump forward)
        const je_pos = try self.assembler.jeRel8(0); // Placeholder

        // Increment counter
        try self.assembler.addRegImm(.rax, 1);

        // Increment pointer
        try self.assembler.addRegImm(.r11, 1);

        // Jump back to loop start
        const current_pos = self.assembler.getPosition();
        const rel_offset = @as(i8, @intCast(@as(i32, @intCast(loop_start)) - @as(i32, @intCast(current_pos + 2))));
        _ = try self.assembler.jmpRel8(rel_offset);

        // Patch the je instruction
        const exit_pos = self.assembler.getPosition();
        const je_offset = @as(i8, @intCast(@as(i32, @intCast(exit_pos)) - @as(i32, @intCast(je_pos + 2))));
        self.assembler.patchJe8(je_pos, je_offset);
    }

    /// Compare two strings
    /// Input: rdi = string1, rsi = string2
    /// Output: rax = 0 if equal, <0 if s1<s2, >0 if s1>s2
    fn strcmp(self: *NativeCodegen, str1_reg: x64.Register, str2_reg: x64.Register) !void {
        try self.assembler.movRegReg(.r11, str1_reg); // r11 = string1
        try self.assembler.movRegReg(.r12, str2_reg); // r12 = string2

        // Loop: compare byte by byte
        const loop_start = self.assembler.getPosition();

        // Load bytes
        try self.assembler.movzxReg64Mem8(.rax, .r11, 0); // rax = *s1
        try self.assembler.movzxReg64Mem8(.rcx, .r12, 0); // rcx = *s2

        // Compare bytes
        try self.assembler.cmpRegReg(.rax, .rcx);

        // If not equal, return difference
        const jne_pos = try self.assembler.jneRel8(0); // Placeholder

        // If both are 0, strings are equal
        try self.assembler.testRegReg(.rax, .rax);
        const je_pos = try self.assembler.jeRel8(0); // Placeholder (exit with rax=0)

        // Increment pointers
        try self.assembler.addRegImm(.r11, 1);
        try self.assembler.addRegImm(.r12, 1);

        // Jump back to loop start
        const current_pos2 = self.assembler.getPosition();
        const rel_offset2 = @as(i8, @intCast(@as(i32, @intCast(loop_start)) - @as(i32, @intCast(current_pos2 + 2))));
        _ = try self.assembler.jmpRel8(rel_offset2);

        // Patch jne: return difference (rax - rcx)
        const diff_pos = self.assembler.getPosition();
        const jne_offset = @as(i8, @intCast(@as(i32, @intCast(diff_pos)) - @as(i32, @intCast(jne_pos + 2))));
        self.assembler.patchJne8(jne_pos, jne_offset);

        try self.assembler.subRegReg(.rax, .rcx); // rax = rax - rcx
        const jmp_exit_pos = try self.assembler.jmpRel8(0); // Jump to end

        // Patch je: return 0 (already in rax)
        const equal_pos = self.assembler.getPosition();
        const je_offset = @as(i8, @intCast(@as(i32, @intCast(equal_pos)) - @as(i32, @intCast(je_pos + 2))));
        self.assembler.patchJe8(je_pos, je_offset);

        try self.assembler.xorRegReg(.rax, .rax); // rax = 0

        // Patch final jump
        const exit_pos = self.assembler.getPosition();
        const jmp_offset = @as(i8, @intCast(@as(i32, @intCast(exit_pos)) - @as(i32, @intCast(jmp_exit_pos + 2))));
        self.assembler.patchJmp8(jmp_exit_pos, jmp_offset);
    }

    /// Copy memory from src to dest
    /// Input: rdi = dest, rsi = src, rdx = count
    fn memcpy(self: *NativeCodegen) !void {
        // Simple byte-by-byte copy
        try self.assembler.testRegReg(.rdx, .rdx);
        const je_exit = try self.assembler.jeRel8(0); // If count==0, exit

        const loop_start = self.assembler.getPosition();

        // Load byte from [rsi]
        try self.assembler.movzxReg64Mem8(.rax, .rsi, 0);

        // Store byte to [rdi]
        try self.assembler.movByteMemReg(.rdi, 0, .rax);

        // Increment pointers
        try self.assembler.addRegImm(.rsi, 1);
        try self.assembler.addRegImm(.rdi, 1);

        // Decrement counter
        try self.assembler.subRegImm(.rdx, 1);

        // Loop if rdx != 0
        try self.assembler.testRegReg(.rdx, .rdx);
        const current_pos3 = self.assembler.getPosition();
        const rel_offset3 = @as(i8, @intCast(@as(i32, @intCast(loop_start)) - @as(i32, @intCast(current_pos3 + 2))));
        _ = try self.assembler.jneRel8(rel_offset3);

        // Patch exit jump
        const exit_pos = self.assembler.getPosition();
        const je_offset = @as(i8, @intCast(@as(i32, @intCast(exit_pos)) - @as(i32, @intCast(je_exit + 2))));
        self.assembler.patchJe8(je_exit, je_offset);
    }

    /// Allocate memory on the heap
    /// Input: rdi = size to allocate
    /// Output: rax = pointer to allocated memory
    /// Real heap allocator backed by anonymous mmap. Each call gets a fresh
    /// page (or more, for larger requests), which is wasteful for small
    /// allocations but is the simplest correct allocator that doesn't leak
    /// references when the calling stack frame unwinds.
    ///
    /// Why we can't use the stack: state structs allocated by an async fn's
    /// entry function need to outlive the entry call (the executor polls
    /// them later from a different stack frame). Stack-bump would point at
    /// freed memory.
    ///
    /// Calling convention:
    ///   in:  rdi = size in bytes
    ///   out: rax = page-aligned pointer (always at least `size` bytes)
    ///   clobbers: rdi, rsi, rdx, r10, r8, r9, rcx, r11
    fn heapAlloc(self: *NativeCodegen) !void {
        // Round size up to a page (4096) so mmap accepts it cleanly.
        //   rsi = (rdi + 4095) & ~4095
        // x64 lacks an immediate-mask form we can reach with the current
        // assembler helpers, so we materialize ~4095 in rcx and use and.
        try self.assembler.movRegReg(.rsi, .rdi);
        try self.assembler.addRegImm(.rsi, 4095);
        try self.assembler.movRegImm64(.rcx, @bitCast(@as(i64, -4096)));
        try self.assembler.andRegReg(.rsi, .rcx);

        // mmap(NULL, len, PROT_READ|PROT_WRITE, MAP_ANON|MAP_PRIVATE, -1, 0)
        try self.assembler.movRegImm64(.rdi, 0);             // addr = NULL
        try self.assembler.movRegImm64(.rdx, 3);             // PROT_READ|PROT_WRITE
        try self.assembler.movRegImm64(.r10, 0x1002);        // MAP_ANON|MAP_PRIVATE
        try self.assembler.movRegImm64(.r8, @bitCast(@as(i64, -1)));  // fd = -1
        try self.assembler.movRegImm64(.r9, 0);              // offset = 0
        // syscall number: macOS uses 0x20000C5 for mmap (BSD syscall class).
        const mmap_syscall: u64 = switch (builtin.os.tag) {
            .macos => 0x20000C5,
            .linux => 9, // mmap on linux x86-64
            else => 9,
        };
        try self.assembler.movRegImm64(.rax, mmap_syscall);
        try self.assembler.syscall();
        // Check for MAP_FAILED: mmap returns -1 (or small negative
        // -errno on macOS) on failure. Without this guard a failed
        // allocation silently hands -1 to every caller as a "valid"
        // pointer, causing writes to 0xFFFFFFFFFFFFFFFF.
        try self.assembler.cmpRegImm(.rax, -1);
        const jne_ok = self.assembler.getPosition();
        try self.assembler.jneRel32(0);
        try self.emitRuntimePanic("panic: out of memory (mmap failed)");
        const ok_target = self.assembler.getPosition();
        try self.assembler.patchJneRel32(
            jne_ok,
            @as(i32, @intCast(ok_target)) - @as(i32, @intCast(jne_ok + 6)),
        );
    }

    /// Emit a silent bounds-check panic: exit(101) without printing a
    /// message. This is intentionally lightweight — no string_fixups, no
    /// write syscall — so it can be emitted dozens of times per function
    /// without the string-table interaction that the message-form
    /// `emitRuntimePanic` has been known to hit.
    ///
    /// The tradeoff is that the user sees only the exit code; stderr is
    /// silent. That's still strictly better than silently reading
    /// adjacent heap memory.
    fn emitBoundsPanic(self: *NativeCodegen) !void {
        const exit_syscall: u64 = switch (builtin.os.tag) {
            .macos => 0x2000001,
            .linux => 60,
            else => 60,
        };
        try self.assembler.movRegImm64(.rax, exit_syscall);
        try self.assembler.movRegImm64(.rdi, 101);
        try self.assembler.syscall();
    }

    /// Emit a deep clone of a dynamic Array value. The receiver is
    /// expected to be an expression producing an Array header pointer.
    /// On return rax holds a fresh header pointer whose data block is a
    /// byte-for-byte copy of the source's used slots.
    fn emitArrayClone(self: *NativeCodegen, receiver: *ast.Expr) !void {
        try self.generateExpr(receiver);
        // rax = source header
        try self.assembler.pushReg(.rax); // save source header

        // Allocate new header (24 bytes).
        try self.assembler.movRegImm64(.rdi, 24);
        try self.heapAlloc();
        try self.assembler.pushReg(.rax); // save new header

        // Read source cap (from src_header+8). Allocate new data block
        // sized to match so future push() has the same slack.
        try self.assembler.movRegMem(.r11, .rsp, 8); // src_header (below new_header)
        try self.assembler.movRegMem(.rdi, .r11, 8); // rdi = cap
        try self.assembler.shlRegImm8(.rdi, 3); // cap*8 bytes
        try self.heapAlloc(); // rax = new_data
        try self.assembler.movRegReg(.r10, .rax); // r10 = new_data

        // Reload pointers from the stack.
        try self.assembler.popReg(.r12); // r12 = new_header
        try self.assembler.popReg(.r11); // r11 = src_header

        // Copy len, cap, data_ptr into new header.
        try self.assembler.movRegMem(.rcx, .r11, 0); // len
        try self.assembler.movMemReg(.r12, 0, .rcx);
        try self.assembler.movRegMem(.rcx, .r11, 8); // cap
        try self.assembler.movMemReg(.r12, 8, .rcx);
        try self.assembler.movMemReg(.r12, 16, .r10); // data_ptr = new_data

        // memcpy: src_data = [src+16], dst = new_data, count = len*8.
        try self.assembler.movRegMem(.rsi, .r11, 16);
        try self.assembler.movRegReg(.rdi, .r10);
        try self.assembler.movRegMem(.rcx, .r11, 0);
        try self.assembler.shlRegImm8(.rcx, 3);
        // rep movsb (F3 A4)
        try self.assembler.code.append(self.allocator, 0xF3);
        try self.assembler.code.append(self.allocator, 0xA4);

        // Return new header pointer.
        try self.assembler.movRegReg(.rax, .r12);
    }

    /// Emit a deep clone of a nul-terminated string. Equivalent to
    /// `strdup`: walks the source to compute its length, allocates
    /// len+1 bytes, copies the bytes plus terminator. Returns the new
    /// pointer in rax.
    fn emitStringClone(self: *NativeCodegen, receiver: *ast.Expr) !void {
        try self.generateExpr(receiver);
        try self.assembler.pushReg(.rax); // [0] source
        try self.stringLength(.rax); // rax = len (excluding NUL)
        try self.assembler.pushReg(.rax); // [1] len
        // Allocate len + 1 bytes.
        try self.assembler.movRegReg(.rdi, .rax);
        try self.assembler.addRegImm(.rdi, 1);
        try self.heapAlloc(); // rax = dest
        try self.assembler.popReg(.rcx); // rcx = len
        try self.assembler.popReg(.rsi); // rsi = source
        try self.assembler.movRegReg(.rdi, .rax); // rdi = dest
        try self.assembler.pushReg(.rax); // save dest as return value
        // rep movsb — copies rcx bytes, advances rdi/rsi past the last
        // byte so rdi now points at dest + len where the nul lives.
        try self.assembler.code.append(self.allocator, 0xF3);
        try self.assembler.code.append(self.allocator, 0xA4);
        try self.assembler.movByteMemImm(.rdi, 0, 0);
        try self.assembler.popReg(.rax); // dest
    }

    /// Representable range for a narrowing-cast target. Returned by
    /// `narrowingRangeFor` for the primitive integer widths codegen knows
    /// how to emit checks for. i64/u64 intentionally return null — a
    /// "cast to i64" can never overflow at runtime since rax is already
    /// 64-bit.
    const NarrowingRange = struct {
        min: i64,
        max: i64,
        signed: bool,
    };

    fn narrowingRangeFor(target_type: []const u8) ?NarrowingRange {
        if (std.mem.eql(u8, target_type, "i8")) {
            return .{ .min = -128, .max = 127, .signed = true };
        }
        if (std.mem.eql(u8, target_type, "i16")) {
            return .{ .min = -32768, .max = 32767, .signed = true };
        }
        if (std.mem.eql(u8, target_type, "i32")) {
            return .{ .min = std.math.minInt(i32), .max = std.math.maxInt(i32), .signed = true };
        }
        if (std.mem.eql(u8, target_type, "u8")) {
            return .{ .min = 0, .max = 255, .signed = false };
        }
        if (std.mem.eql(u8, target_type, "u16")) {
            return .{ .min = 0, .max = 65535, .signed = false };
        }
        if (std.mem.eql(u8, target_type, "u32")) {
            return .{ .min = 0, .max = 4294967295, .signed = false };
        }
        return null;
    }

    /// Emit: if rax < min or rax > max, push rax; panic. Otherwise fall
    /// through with rax unchanged. Uses signed compares for signed
    /// targets and unsigned compares for unsigned targets.
    fn emitNarrowingRangeCheck(
        self: *NativeCodegen,
        target_type: []const u8,
        r: NarrowingRange,
    ) !void {
        // For unsigned targets we first reject negative values with a
        // signed compare against 0; then we fall through to the
        // "≤ max" check (using unsigned compare so that large positives
        // don't wrap).
        if (!r.signed) {
            try self.assembler.testRegReg(.rax, .rax);
            const jns_neg_ok = self.assembler.getPosition();
            try self.assembler.jnsRel32(0);
            try self.assembler.pushReg(.rax);
            const prefix = try std.fmt.allocPrint(
                self.allocator,
                "panic: narrowing cast out of range (target {s}): ",
                .{target_type},
            );
            try self.emitRuntimePanicWithOperand(prefix);
            try self.assembler.patchJnsRel32(
                jns_neg_ok,
                @as(i32, @intCast(self.assembler.getPosition())) - @as(i32, @intCast(jns_neg_ok + 6)),
            );
        } else {
            // Signed target: check rax >= min.
            try self.assembler.movRegImm64(.rcx, r.min);
            try self.assembler.cmpRegReg(.rax, .rcx);
            const jge_lo_ok = self.assembler.getPosition();
            try self.assembler.jgeRel32(0);
            try self.assembler.pushReg(.rax);
            const prefix_lo = try std.fmt.allocPrint(
                self.allocator,
                "panic: narrowing cast out of range (target {s}): ",
                .{target_type},
            );
            try self.emitRuntimePanicWithOperand(prefix_lo);
            try self.assembler.patchJgeRel32(
                jge_lo_ok,
                @as(i32, @intCast(self.assembler.getPosition())) - @as(i32, @intCast(jge_lo_ok + 6)),
            );
        }

        // Upper-bound check.
        try self.assembler.movRegImm64(.rcx, r.max);
        try self.assembler.cmpRegReg(.rax, .rcx);
        const jle_hi_ok = self.assembler.getPosition();
        try self.assembler.jleRel32(0);
        try self.assembler.pushReg(.rax);
        const prefix_hi = try std.fmt.allocPrint(
            self.allocator,
            "panic: narrowing cast out of range (target {s}): ",
            .{target_type},
        );
        try self.emitRuntimePanicWithOperand(prefix_hi);
        try self.assembler.patchJleRel32(
            jle_hi_ok,
            @as(i32, @intCast(self.assembler.getPosition())) - @as(i32, @intCast(jle_hi_ok + 6)),
        );
    }

    /// Convert an abstract local slot index into an rbp-relative i32
    /// displacement, returning CodegenError.StackOffsetOverflow when the
    /// frame grows larger than x64's 32-bit displacement field. Every
    /// local-load/store site should go through this helper so the
    /// compiler reports a loud, actionable error instead of silently
    /// truncating to a 0 displacement and clobbering adjacent memory.
    fn localDisp(self: *NativeCodegen, slot: u32) CodegenError!i32 {
        _ = self;
        // Each local occupies 8 bytes; slot 0 lives at [rbp-8].
        const bytes: u64 = (@as(u64, slot) + 1) * 8;
        // A negative i32 displacement bottoms out at -2^31 (≈2 GiB).
        // We allow the full magnitude by rejecting anything strictly
        // greater than that bound. The i31 shrug-check lets us use
        // @intCast without triggering Zig's safety check.
        if (bytes > @as(u64, 1) << 31) {
            return error.StackOffsetOverflow;
        }
        return -@as(i32, @intCast(bytes));
    }

    /// Emit a runtime panic: write `message` to stderr and exit with code 101.
    /// Inline so each panic site has its own data; avoids the need for a per-process
    /// panic routine and works correctly even when called from places where the
    /// stack frame is not well-formed.
    fn emitRuntimePanic(self: *NativeCodegen, message: []const u8) !void {
        // Build the message bytes (with newline) into the data section. We
        // hand ownership of the dupe to string_literals for the lifetime of
        // the codegen pass — registerStringLiteral stores the slice directly.
        const buf = try std.fmt.allocPrint(self.allocator, "{s}\n", .{message});
        try self.emitWriteStderrStaticBuf(buf);

        // exit(101) — matches Rust's panic exit code.
        const exit_syscall: u64 = switch (builtin.os.tag) {
            .macos => 0x2000001,
            .linux => 60,
            else => 60,
        };
        try self.assembler.movRegImm64(.rax, exit_syscall);
        try self.assembler.movRegImm64(.rdi, 101);
        try self.assembler.syscall();
    }

    /// Write a static buffer (owned, alive for the rest of the codegen pass)
    /// to stderr using a direct write syscall.
    fn emitWriteStderrStaticBuf(self: *NativeCodegen, buf: []const u8) !void {
        if (buf.len == 0) return;
        const data_offset = try self.registerStringLiteral(buf);
        const write_syscall: u64 = switch (builtin.os.tag) {
            .macos => 0x2000004,
            .linux => 1,
            else => 1,
        };
        try self.assembler.movRegImm64(.rax, write_syscall);
        try self.assembler.movRegImm64(.rdi, 2);
        const lea_pos = try self.assembler.leaRipRel(.rsi, 0);
        try self.string_fixups.append(self.allocator, .{
            .code_pos = lea_pos,
            .data_offset = data_offset,
        });
        try self.assembler.movRegImm64(.rdx, @as(i64, @intCast(buf.len)));
        try self.assembler.syscall();
    }

    /// Convenience: emit a static string literal (by dup-ing it) and write
    /// it to stderr. Use this for short constant fragments that appear at
    /// exactly one panic site.
    fn emitWriteStderrStatic(self: *NativeCodegen, msg: []const u8) !void {
        if (msg.len == 0) return;
        const owned = try self.allocator.dupe(u8, msg);
        try self.emitWriteStderrStaticBuf(owned);
    }

    /// Emit write(2, <nul-terminated C string pointed to by rax>, strlen).
    /// Clobbers rax, rcx, rdx, rdi, rsi, r11.
    fn emitWriteStderrCStr(self: *NativeCodegen) !void {
        // Save the pointer across stringLength (which clobbers rax/rcx/r11
        // but leaves rsi untouched if we park it there first).
        try self.assembler.movRegReg(.rsi, .rax); // rsi = message ptr
        try self.stringLength(.rsi); // rax = strlen
        try self.assembler.movRegReg(.rdx, .rax); // rdx = len
        try self.assembler.movRegImm64(.rdi, 2); // stderr
        const write_syscall: u64 = switch (builtin.os.tag) {
            .macos => 0x2000004,
            .linux => 1,
            else => 1,
        };
        try self.assembler.movRegImm64(.rax, write_syscall);
        try self.assembler.syscall();
    }

    /// Emit an inline panic that prints `<prefix><value>\n` and exits.
    /// The value must be on the top of the stack when this is called.
    /// Does not return.
    fn emitRuntimePanicWithOperand(self: *NativeCodegen, prefix: []const u8) !void {
        try self.assembler.popReg(.r12); // value
        try self.emitWriteStderrStatic(prefix);
        try self.assembler.movRegReg(.rax, .r12);
        try self.intToDecimalString();
        try self.emitWriteStderrCStr();
        try self.emitWriteStderrStatic("\n");
        const exit_syscall: u64 = switch (builtin.os.tag) {
            .macos => 0x2000001,
            .linux => 60,
            else => 60,
        };
        try self.assembler.movRegImm64(.rax, exit_syscall);
        try self.assembler.movRegImm64(.rdi, 101);
        try self.assembler.syscall();
    }

    /// Which primitive arithmetic op to issue in emitCheckedBinaryOp.
    const CheckedOp = enum { Add, Sub, Mul };

    /// Emit: `push rax; push rcx; <op> rax, rcx; jno .ok; <rich panic>; .ok:
    /// add rsp, 16`. The rich panic path uses the two pushed operands to
    /// format a message of the form `<prefix><lhs><op_glyph><rhs>\n`.
    fn emitCheckedBinaryOp(
        self: *NativeCodegen,
        op: CheckedOp,
        prefix: []const u8,
        op_glyph: []const u8,
    ) !void {
        // Save operands (lhs in rax, rhs in rcx) for the panic path.
        try self.assembler.pushReg(.rax);
        try self.assembler.pushReg(.rcx);

        switch (op) {
            .Add => try self.assembler.addRegReg(.rax, .rcx),
            .Sub => try self.assembler.subRegReg(.rax, .rcx),
            .Mul => try self.assembler.imulRegReg(.rax, .rcx),
        }

        // Spill the (possibly) wrapped result so the panic path's clobbers
        // don't destroy it. We restore into rax after the patched jno lands.
        // We can't just live on rsp because emitCheckedOpPanic itself pushes
        // things, so instead we stash in a local slot via r9 across the jump.
        try self.assembler.movRegReg(.r9, .rax);

        const jno_patch = self.assembler.getPosition();
        try self.assembler.jnoRel32(0);

        // --- overflow path: does not return ---
        try self.emitCheckedOpPanic(prefix, op_glyph);

        // --- happy path ---
        const after_panic = self.assembler.getPosition();
        try self.assembler.patchJnoRel32(
            jno_patch,
            @as(i32, @intCast(after_panic)) - @as(i32, @intCast(jno_patch + 6)),
        );
        // Drop the two pushed operands.
        try self.assembler.addRegImm(.rsp, 16);
        // Restore the result into rax.
        try self.assembler.movRegReg(.rax, .r9);
    }

    /// Emit an inline "integer overflow" panic that prints the two operand
    /// values alongside a static prefix and operator glyph. The caller must
    /// have pushed the operands on the stack as `push lhs; push rhs` *before*
    /// performing the checked arithmetic, so that when this routine runs the
    /// top of stack is [rhs, lhs]. The routine does not return.
    ///
    /// Example output: `panic: integer overflow in checked add: 9223372036854775800 + 42\n`
    fn emitCheckedOpPanic(
        self: *NativeCodegen,
        prefix: []const u8,
        op_glyph: []const u8,
    ) !void {
        // Pop rhs first (top of stack), then lhs.
        try self.assembler.popReg(.r13); // rhs
        try self.assembler.popReg(.r12); // lhs

        // --- prefix ---
        try self.emitWriteStderrStatic(prefix);

        // --- itoa(lhs) and write ---
        // intToDecimalString clobbers rcx/rdx/r10/r11/r12 but NOT r13, so we
        // save r13 on the stack across it just to be safe across future
        // refactors.
        try self.assembler.pushReg(.r13);
        try self.assembler.movRegReg(.rax, .r12);
        try self.intToDecimalString(); // rax = c-string ptr
        try self.emitWriteStderrCStr();
        try self.assembler.popReg(.r13);

        // --- " <op> " ---
        try self.emitWriteStderrStatic(op_glyph);

        // --- itoa(rhs) and write ---
        try self.assembler.movRegReg(.rax, .r13);
        try self.intToDecimalString();
        try self.emitWriteStderrCStr();

        // --- newline ---
        try self.emitWriteStderrStatic("\n");

        // exit(101)
        const exit_syscall: u64 = switch (builtin.os.tag) {
            .macos => 0x2000001,
            .linux => 60,
            else => 60,
        };
        try self.assembler.movRegImm64(.rax, exit_syscall);
        try self.assembler.movRegImm64(.rdi, 101);
        try self.assembler.syscall();
    }

    // ----------------------------------------------------------------
    // Trait vtable layout & dispatch
    // ----------------------------------------------------------------
    //
    // Layout: each (Trait, ImplType) pair gets a flat array of N
    // function pointers in the data section, where N is the number of
    // methods declared on the trait. The order matches the trait's
    // declaration order so dispatch is `*(vtable + index*8)`.
    //
    // Trait objects are pairs of (data pointer, vtable pointer). The
    // data pointer is the receiver; the vtable pointer is loaded with
    // an LEA to the data section. A virtual call computes:
    //
    //     fn_ptr = *(vtable + method_index * 8)
    //     fn_ptr(data, args...)

    /// One method slot in a trait vtable. The order of slots matters: it
    /// must match the order in which the trait declares its methods, because
    /// virtual dispatch indexes into the vtable by position.
    pub const VtableSlot = struct {
        name: []const u8,
        function_offset: usize,
    };

    /// Build a vtable for `(trait_name, impl_type)` from `(method_name,
    /// function_offset)` entries. Allocates `N * 8` zero bytes in the data
    /// literals section, then patches each slot with the absolute-ish offset
    /// of the implementation function. The linker resolves the slot to a
    /// runtime address when emitting the binary.
    ///
    /// Returns the data-section offset of the vtable, suitable for storing in
    /// trait-object headers.
    pub fn emitTraitVtable(
        self: *NativeCodegen,
        trait_name: []const u8,
        impl_type: []const u8,
        methods: []const VtableSlot,
    ) !usize {
        const key = try std.fmt.allocPrint(self.allocator, "{s}::{s}", .{ trait_name, impl_type });
        errdefer self.allocator.free(key);

        if (self.trait_vtables.get(key)) |existing| {
            self.allocator.free(key);
            return existing.data_offset;
        }

        // Reserve N * 8 bytes in the data section. Each slot starts as zero
        // and is overwritten with the function offset below.
        var bytes = try self.allocator.alloc(u8, methods.len * 8);
        errdefer self.allocator.free(bytes);
        @memset(bytes, 0);

        var indices = std.StringHashMap(usize).init(self.allocator);
        errdefer indices.deinit();

        for (methods, 0..) |m, i| {
            try indices.put(m.name, i);
            std.mem.writeInt(u64, bytes[i * 8 ..][0..8], @as(u64, @intCast(m.function_offset)), .little);
        }

        const offset = self.data_literals_offset;
        try self.data_literals.append(self.allocator, bytes);
        self.data_literals_offset += bytes.len;

        try self.trait_vtables.put(key, .{
            .data_offset = offset,
            .method_count = methods.len,
            .method_indices = indices,
        });

        return offset;
    }

    /// Look up a vtable by `(trait_name, impl_type)`. Returns null if no
    /// vtable has been emitted yet (caller is expected to fall back to
    /// static dispatch or report an error).
    pub fn lookupTraitVtable(
        self: *NativeCodegen,
        trait_name: []const u8,
        impl_type: []const u8,
    ) ?*const VtableInfo {
        // The lookup key needs to be heap-allocated because the StringHashMap
        // stores keys by pointer. Stack-format and check.
        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}::{s}", .{ trait_name, impl_type }) catch return null;
        return self.trait_vtables.getPtr(key);
    }

    // ----------------------------------------------------------------
    // Async / Future runtime
    // ----------------------------------------------------------------
    //
    // We don't yet have an executor, so the runtime model is the simplest
    // possible: an `async fn` returns a Future header that's already in the
    // Ready state, and `await` immediately extracts the result. The header
    // layout is:
    //
    //     offset 0 (8 bytes): state    -- 0=Pending, 2=Ready
    //     offset 8 (8 bytes): result   -- the value (or 0 if void)
    //
    // This is a degenerate state machine — one state, no suspension — but it
    // is a real coroutine: the calling convention round-trips through a heap
    // (currently stack-bump) struct, and `await` actually does an indirect
    // memory load. When a real executor lands, the same wrapper site grows
    // into a multi-state poll function and `await` becomes a poll loop.
    //
    // Crucially, this means user code MUST write `await` to extract the
    // value of an async call. Direct call sites yield a Future pointer.

    /// Allocate a 16-byte Future header on the stack, write `state=2 (Ready)`
    /// and `result=<rax>`, leave the header pointer in rax.
    /// Clobbers rcx and r10.
    // ----------------------------------------------------------------
    // Async fn pre-scan
    // ----------------------------------------------------------------
    //
    // Walks the body of an `async fn` to:
    //   1. Allocate a state-struct slot for every parameter and `let`-declared
    //      local. Locals declared inside conditional branches all share the
    //      same struct because the state machine flattens control flow.
    //   2. Count the number of `await` expressions, which determines the
    //      state count of the resulting poll function.
    //
    // The pre-scan does NOT emit any code. It just populates the
    // AsyncFnContext that the emitter consumes.

    fn scanAsyncFnBody(self: *NativeCodegen, func: *ast.FnDecl, ctx: *AsyncFnContext) CodegenError!void {
        // Parameters get the lowest offsets, in declaration order, so the
        // entry function can copy them in via the SysV register sequence.
        for (func.params) |param| {
            _ = try ctx.allocLocal(param.name);
        }
        // Walk the body. The function body is a BlockStmt held by `func.body`.
        try self.scanAsyncStmts(func.body.statements, ctx);
    }

    fn scanAsyncStmts(self: *NativeCodegen, stmts: []const ast.Stmt, ctx: *AsyncFnContext) CodegenError!void {
        for (stmts) |stmt| try self.scanAsyncStmt(stmt, ctx);
    }

    fn scanAsyncStmt(self: *NativeCodegen, stmt: ast.Stmt, ctx: *AsyncFnContext) CodegenError!void {
        switch (stmt) {
            .LetDecl => |decl| {
                _ = try ctx.allocLocal(decl.name);
                if (decl.value) |v| try self.scanAsyncExpr(v, ctx);
            },
            .ExprStmt => |e| try self.scanAsyncExpr(e, ctx),
            .ReturnStmt => |r| if (r.value) |v| try self.scanAsyncExpr(v, ctx),
            .BlockStmt => |b| try self.scanAsyncStmts(b.statements, ctx),
            .IfStmt => |if_stmt| {
                try self.scanAsyncExpr(if_stmt.condition, ctx);
                try self.scanAsyncStmts(if_stmt.then_block.statements, ctx);
                if (if_stmt.else_block) |else_block| {
                    try self.scanAsyncStmts(else_block.statements, ctx);
                }
            },
            .WhileStmt => |w| {
                try self.scanAsyncExpr(w.condition, ctx);
                try self.scanAsyncStmts(w.body.statements, ctx);
            },
            else => {},
        }
    }

    fn scanAsyncExpr(self: *NativeCodegen, expr: *ast.Expr, ctx: *AsyncFnContext) CodegenError!void {
        switch (expr.*) {
            .AwaitExpr => |a| {
                ctx.num_awaits += 1;
                try self.scanAsyncExpr(a.expression, ctx);
            },
            .BinaryExpr => |b| {
                try self.scanAsyncExpr(b.left, ctx);
                try self.scanAsyncExpr(b.right, ctx);
            },
            .UnaryExpr => |u| try self.scanAsyncExpr(u.operand, ctx),
            .CallExpr => |c| {
                try self.scanAsyncExpr(c.callee, ctx);
                for (c.args) |arg| try self.scanAsyncExpr(arg, ctx);
            },
            .MemberExpr => |m| try self.scanAsyncExpr(m.object, ctx),
            .IndexExpr => |i| {
                try self.scanAsyncExpr(i.array, ctx);
                try self.scanAsyncExpr(i.index, ctx);
            },
            .IfExpr => |if_expr| {
                try self.scanAsyncExpr(if_expr.condition, ctx);
                try self.scanAsyncExpr(if_expr.then_branch, ctx);
                try self.scanAsyncExpr(if_expr.else_branch, ctx);
            },
            .TernaryExpr => |t| {
                try self.scanAsyncExpr(t.condition, ctx);
                try self.scanAsyncExpr(t.true_val, ctx);
                try self.scanAsyncExpr(t.false_val, ctx);
            },
            else => {},
        }
    }

    // ----------------------------------------------------------------
    // Async fn emission
    // ----------------------------------------------------------------
    //
    // For each `async fn name(...)`, we emit two functions:
    //
    //   1. `<name>_poll` — the state machine. Takes a *FutureState in rdi,
    //      mutates it in place. Body is a switch on `state.resume_pt` that
    //      jumps to the right segment. Each segment ends with either an
    //      `await` (which sets next state and returns Pending) or function
    //      end (which sets `ready=1` + `result` and returns).
    //
    //   2. `<name>` — the entry. Allocates a FutureState on the heap, copies
    //      params from the SysV registers into struct slots, fills in the
    //      header (ready=0, poll_fn=<name>_poll, resume_pt=0), returns the
    //      pointer in rax.
    //
    // We emit poll first so the entry can take the poll_fn's address via a
    // RIP-relative LEA computed at emit time.

    fn generateAsyncFnDecl(self: *NativeCodegen, func: *ast.FnDecl, effective_name: []const u8) !void {
        const allocator = self.allocator;

        // Pre-scan: walk the body to count awaits and allocate locals.
        var ctx = AsyncFnContext.init(allocator);
        defer ctx.deinit();
        try self.scanAsyncFnBody(func, &ctx);

        // Pre-allocate state-label slots so the dispatch table can patch them.
        try ctx.state_labels.resize(allocator, ctx.num_awaits + 1);
        for (ctx.state_labels.items) |*p| p.* = 0;
        try ctx.dispatch_jumps.resize(allocator, ctx.num_awaits + 1);
        for (ctx.dispatch_jumps.items) |*p| p.* = 0;

        // -----------------------------------------------------------
        // Emit poll function
        // -----------------------------------------------------------
        const poll_name = try std.fmt.allocPrint(allocator, "{s}_poll", .{effective_name});
        defer allocator.free(poll_name);

        const poll_pos = self.assembler.getPosition();
        try self.functions.put(try allocator.dupe(u8, poll_name), poll_pos);

        // Standard prologue.
        try self.assembler.pushReg(.rbp);
        try self.assembler.movRegReg(.rbp, .rsp);

        // Move state pointer (rdi) into rbx, our dedicated callee-save
        // state register. rbx is preserved across the function so we can
        // rely on it after recursive `poll` calls. We use rbx instead of
        // r12 because r12's encoding (100) collides with the SIB-required
        // pattern in mod-displacement memory addressing — the assembler
        // helpers don't yet emit SIB bytes for that case.
        try self.assembler.pushReg(.rbx);
        try self.assembler.movRegReg(.rbx, .rdi);

        // Bind active context for the body codegen below. Local accesses now
        // route through the state struct.
        const prev_async_ctx = self.async_ctx;
        self.async_ctx = &ctx;
        defer self.async_ctx = prev_async_ctx;

        // Dispatch table: load resume_pt and jump to the matching segment.
        try self.assembler.movRegMem(.rax, .rbx, STATE_OFF_RESUME);
        var i: usize = 0;
        while (i <= ctx.num_awaits) : (i += 1) {
            try self.assembler.cmpRegImm(.rax, @intCast(i));
            ctx.dispatch_jumps.items[i] = self.assembler.getPosition();
            try self.assembler.jeRel32(0); // patched once segment label is known
        }
        // Fall-through trap: unknown state shouldn't happen.
        try self.assembler.ud2();

        // -----------------------------------------------------------
        // Segment 0: from function entry up to the first await (or end).
        // -----------------------------------------------------------
        // Patch dispatch_jumps[0] to point here.
        try self.recordAsyncSegmentLabel(&ctx, 0);

        // Emit the body. The walk uses the existing generateStmt machinery,
        // which now sees self.async_ctx != null and routes locals through
        // the state struct. AwaitExpr handlers also notice and emit the
        // suspend pattern instead of block-on.
        for (func.body.statements) |stmt| {
            try self.generateStmt(stmt);
        }

        // If the body fell off the end without an explicit return, emit a
        // synthesized one. Zero-initialize rax first so async fns with a
        // void return (or bodies that don't assign anything useful before
        // falling through) don't leak whatever happens to be in rax from
        // the last expression. This matches Rust's `()` fall-through.
        try self.assembler.movRegImm64(.rax, 0);
        try self.emitAsyncReturn(&ctx);

        // -----------------------------------------------------------
        // Epilogue
        // -----------------------------------------------------------
        const epilogue_pos = self.assembler.getPosition();
        for (ctx.epilogue_jumps.items) |jpos| {
            const offset: i32 = @as(i32, @intCast(epilogue_pos)) - @as(i32, @intCast(jpos + 5));
            try self.assembler.patchJmpRel32(jpos, offset);
        }

        // Return self (Future*) in rax. Many callers don't use the return
        // value (they read state via the pointer they already have), but
        // returning it makes the calling convention symmetric with sync fns.
        try self.assembler.movRegReg(.rax, .rbx);
        try self.assembler.popReg(.rbx);
        try self.assembler.movRegReg(.rsp, .rbp);
        try self.assembler.popReg(.rbp);
        try self.assembler.ret();

        // -----------------------------------------------------------
        // Emit entry function (registered under the user-visible name)
        // -----------------------------------------------------------
        const entry_pos = self.assembler.getPosition();
        if (!self.functions.contains(effective_name)) {
            try self.functions.put(try allocator.dupe(u8, effective_name), entry_pos);
        } else if (self.functions.getPtr(effective_name)) |p| {
            p.* = entry_pos;
        }
        // Mark this name as async so the call-site dispatch knows to wrap it
        // in a `block_on` loop when invoked from sync code.
        if (!self.async_fn_names.contains(effective_name)) {
            try self.async_fn_names.put(try allocator.dupe(u8, effective_name), {});
        }

        // Standard prologue.
        try self.assembler.pushReg(.rbp);
        try self.assembler.movRegReg(.rbp, .rsp);

        // Save incoming args (rdi/rsi/rdx/rcx/r8/r9) so heapAlloc doesn't
        // clobber them. Push in reverse order so we can pop in declaration
        // order later.
        const arg_regs = [_]x64.Register{ .rdi, .rsi, .rdx, .rcx, .r8, .r9 };
        const param_count = @min(func.params.len, arg_regs.len);
        var pi: usize = param_count;
        while (pi > 0) {
            pi -= 1;
            try self.assembler.pushReg(arg_regs[pi]);
        }

        // heap_alloc(struct_size) -> rax
        try self.assembler.movRegImm64(.rdi, @intCast(ctx.struct_size));
        try self.heapAlloc();
        // Save the state pointer in r10 so we can keep using rax for the
        // header writes via movRegImm + movMemReg.
        try self.assembler.movRegReg(.r10, .rax);

        // Header[ready] = 0
        try self.assembler.movRegImm64(.rax, 0);
        try self.assembler.movMemReg(.r10, STATE_OFF_READY, .rax);

        // Header[poll_fn] = address of <name>_poll
        // Use a RIP-relative LEA whose displacement we compute right now,
        // since both the poll function position and the LEA position are
        // known at this point.
        const lea_pos = self.assembler.getPosition();
        // leaRipRel emits a 7-byte instruction; the displacement field is
        // the 4 bytes starting at lea_pos+3. The CPU computes
        //   target = next_rip + displacement
        // where next_rip = lea_pos + 7. So:
        //   displacement = poll_pos - (lea_pos + 7)
        const poll_disp: i32 = @as(i32, @intCast(poll_pos)) - @as(i32, @intCast(lea_pos + 7));
        _ = try self.assembler.leaRipRel(.rax, poll_disp);
        try self.assembler.movMemReg(.r10, STATE_OFF_POLL_FN, .rax);

        // Header[resume_pt] = 0 (Start segment)
        try self.assembler.movRegImm64(.rax, 0);
        try self.assembler.movMemReg(.r10, STATE_OFF_RESUME, .rax);

        // Header[result] = 0 (placeholder)
        try self.assembler.movMemReg(.r10, STATE_OFF_RESULT, .rax);

        // Header[inner_fut] = 0
        try self.assembler.movMemReg(.r10, STATE_OFF_INNER, .rax);

        // Pop saved params back into the SysV registers, then store each
        // into its allocated slot in the state struct.
        var pj: usize = 0;
        while (pj < param_count) : (pj += 1) {
            try self.assembler.popReg(arg_regs[pj]);
        }
        for (func.params, 0..) |param, idx| {
            if (idx >= arg_regs.len) break;
            const slot_off = ctx.locals.get(param.name) orelse continue;
            try self.assembler.movMemReg(.r10, slot_off, arg_regs[idx]);
        }

        // Return the state pointer in rax.
        try self.assembler.movRegReg(.rax, .r10);
        try self.assembler.movRegReg(.rsp, .rbp);
        try self.assembler.popReg(.rbp);
        try self.assembler.ret();
    }

    /// Record the code position of state segment `state_id` and back-patch
    /// its dispatch jump.
    fn recordAsyncSegmentLabel(self: *NativeCodegen, ctx: *AsyncFnContext, state_id: usize) !void {
        const here = self.assembler.getPosition();
        ctx.state_labels.items[state_id] = here;
        const jpos = ctx.dispatch_jumps.items[state_id];
        // jeRel32 is 6 bytes (0F 84 + i32). The displacement is computed
        // relative to the next instruction.
        const disp: i32 = @as(i32, @intCast(here)) - @as(i32, @intCast(jpos + 6));
        try self.assembler.patchJeRel32(jpos, disp);
    }

    /// Emit the "function exit" path for an async fn:
    ///   1. Store rax (the value to return) into state.result
    ///   2. Set state.ready = 1
    ///   3. Jump to the epilogue (which restores callee-save and returns)
    ///
    /// Used by both the synthesized fall-off-the-end return and the
    /// explicit ReturnStmt path.
    fn emitAsyncReturn(self: *NativeCodegen, ctx: *AsyncFnContext) !void {
        // Save the return value (currently in rax) into state.result.
        try self.assembler.movMemReg(.rbx, STATE_OFF_RESULT, .rax);
        // Set state.ready = 1
        try self.assembler.movRegImm64(.rax, 1);
        try self.assembler.movMemReg(.rbx, STATE_OFF_READY, .rax);
        // Jump to the function epilogue (patched in caller after epilogue is emitted).
        const jpos = self.assembler.getPosition();
        try self.assembler.jmpRel32(0);
        try ctx.epilogue_jumps.append(self.allocator, jpos);
    }

    /// Emit the suspend-and-yield sequence for an `await` expression in
    /// an async fn body. The pre-scan has already counted N awaits, so
    /// each call to this routine bumps `emitted_awaits` by one and
    /// creates segment id `emitted_awaits + 1`.
    ///
    /// Sequence:
    ///   1. The inner future pointer is currently in rax. Save it into
    ///      state.inner_fut so the next poll knows what to poll.
    ///   2. Set state.resume_pt = next_segment_id.
    ///   3. Jump to the function epilogue (returning Pending).
    ///   4. Emit the resume label and patch its dispatch jump.
    ///   5. Reload inner future from state.inner_fut.
    ///   6. Indirect-call inner.poll_fn(inner). The poll function may not
    ///      mark inner as Ready yet, so:
    ///   7. Re-check inner.ready. If 0, jump back to the epilogue
    ///      (we suspend again at the same state ID — executor will retry).
    ///   8. If 1, load inner.result into rax (the value of `await x`).
    fn emitAwaitSuspend(self: *NativeCodegen, ctx: *AsyncFnContext) !void {
        // Inner future pointer is currently in rax (we're being called right
        // after generateExpr on the awaited expression).
        try self.assembler.movMemReg(.rbx, STATE_OFF_INNER, .rax);

        const next_state_id = ctx.emitted_awaits + 1;
        // Store next_state_id in state.resume_pt.
        try self.assembler.movRegImm64(.rax, @intCast(next_state_id));
        try self.assembler.movMemReg(.rbx, STATE_OFF_RESUME, .rax);

        // Jump to epilogue (returning Pending).
        const jpos = self.assembler.getPosition();
        try self.assembler.jmpRel32(0);
        try ctx.epilogue_jumps.append(self.allocator, jpos);

        // Emit the resume label and patch the dispatch jump for this state.
        try self.recordAsyncSegmentLabel(ctx, next_state_id);
        ctx.emitted_awaits += 1;

        // On resume: reload inner future, poll it, check ready, etc.
        try self.assembler.movRegMem(.rdi, .rbx, STATE_OFF_INNER);
        // Load inner.poll_fn into r11 (caller-save, fine to clobber).
        try self.assembler.movRegMem(.r11, .rdi, STATE_OFF_POLL_FN);
        // Indirect call: call r11 — preserves rdi (which inner uses as self)
        // and modifies inner's state in place.
        try self.assembler.callReg(.r11);

        // Re-fetch the inner pointer (callee may have clobbered rdi) and
        // check inner.ready.
        try self.assembler.movRegMem(.rdi, .rbx, STATE_OFF_INNER);
        try self.assembler.movRegMem(.rax, .rdi, STATE_OFF_READY);
        try self.assembler.testRegReg(.rax, .rax);
        // If ready == 0, suspend again at the same state ID (the dispatch
        // will jump us back here on the next poll).
        const jz_susp = self.assembler.getPosition();
        try self.assembler.jeRel32(0);
        // Ready -> load result and continue. rax now holds the value.
        try self.assembler.movRegMem(.rax, .rdi, STATE_OFF_RESULT);
        // Skip past the suspend block.
        const jmp_skip = self.assembler.getPosition();
        try self.assembler.jmpRel32(0);

        // Suspend block: jump to epilogue without changing resume_pt
        // (so we re-enter this segment next poll).
        const susp_pos = self.assembler.getPosition();
        try self.assembler.patchJeRel32(jz_susp, @as(i32, @intCast(susp_pos)) - @as(i32, @intCast(jz_susp + 6)));
        const susp_jmp = self.assembler.getPosition();
        try self.assembler.jmpRel32(0);
        try ctx.epilogue_jumps.append(self.allocator, susp_jmp);

        // Continue point: after the suspend block.
        const continue_pos = self.assembler.getPosition();
        try self.assembler.patchJmpRel32(jmp_skip, @as(i32, @intCast(continue_pos)) - @as(i32, @intCast(jmp_skip + 5)));
    }

    /// Emit a `block_on` loop: poll the future in rax until it reports Ready,
    /// then load its result into rax. Used to bridge async results into sync
    /// code (top-level main, or any sync fn calling an async fn).
    /// Emit a `block_on` loop: poll the future in rax until it reports Ready,
    /// then load its result into rax. Used to bridge async results into sync
    /// code (top-level main, or any sync fn calling an async fn).
    ///
    /// Codegen layout:
    ///   push  rdi          ; save future pointer across the loop
    /// loop:
    ///   mov   rdi, [rsp]   ; reload future
    ///   mov   r11, [rdi+8] ; poll_fn
    ///   call  r11          ; (poll_fn)(future)
    ///   mov   rdi, [rsp]
    ///   mov   rax, [rdi]   ; ready
    ///   test  rax, rax
    ///   jz    loop         ; ready==0 -> still pending, retry
    ///   mov   rdi, [rsp]
    ///   mov   rax, [rdi+24]; load result
    ///   pop   rdi
    fn emitBlockOn(self: *NativeCodegen) !void {
        // Save future pointer on the stack so it survives the call.
        try self.assembler.movRegReg(.rdi, .rax);
        try self.assembler.pushReg(.rdi);

        const loop_start = self.assembler.getPosition();
        try self.assembler.movRegMem(.rdi, .rsp, 0);
        try self.assembler.movRegMem(.r11, .rdi, STATE_OFF_POLL_FN);
        try self.assembler.callReg(.r11);

        // Re-check ready flag.
        try self.assembler.movRegMem(.rdi, .rsp, 0);
        try self.assembler.movRegMem(.rax, .rdi, STATE_OFF_READY);
        try self.assembler.testRegReg(.rax, .rax);

        // ready == 0 → still Pending → loop. Backward je takes the jump.
        const jz_pos = self.assembler.getPosition();
        try self.assembler.jeRel32(0);
        const after_jz = self.assembler.getPosition();
        try self.assembler.patchJeRel32(jz_pos, @as(i32, @intCast(loop_start)) - @as(i32, @intCast(after_jz)));

        // Ready: load result into rax.
        try self.assembler.movRegMem(.rdi, .rsp, 0);
        try self.assembler.movRegMem(.rax, .rdi, STATE_OFF_RESULT);
        try self.assembler.popReg(.rdi);
    }

    fn emitFutureWrap(self: *NativeCodegen) !void {
        // Save the value we want to wrap.
        try self.assembler.movRegReg(.rcx, .rax);

        // Allocate 16 bytes via the bump allocator.
        try self.assembler.movRegImm64(.rdi, 16);
        try self.heapAlloc(); // rax = pointer
        try self.assembler.movRegReg(.r10, .rax);

        // header[0] = 2 (Ready)
        try self.assembler.movRegImm64(.rax, 2);
        try self.assembler.movMemReg(.r10, 0, .rax);

        // header[8] = result
        try self.assembler.movMemReg(.r10, 8, .rcx);

        // Return pointer in rax.
        try self.assembler.movRegReg(.rax, .r10);
    }

    /// Try to emit a virtual call through any matching vtable. Searches all
    /// known vtables for `trait_name` to find the first one that has a slot
    /// named `method_name`. Used when we know the receiver is `dyn Trait`
    /// but don't know the concrete impl type at compile time — at runtime the
    /// trait-object header carries the right vtable.
    ///
    /// Args are pushed/popped using the same SysV ABI sequence as direct
    /// calls. The receiver is passed as the first argument (rdi); call.args
    /// fill rsi/rdx/rcx/r8/r9.
    ///
    /// Returns `true` if the dispatch was emitted, `false` if no matching
    /// trait+method combination was found and the caller should fall through.
    pub fn tryEmitVirtualCall(
        self: *NativeCodegen,
        receiver_expr: *ast.Expr,
        trait_name: []const u8,
        method_name: []const u8,
        args: []const *ast.Expr,
    ) !bool {
        // Walk vtables and find the first one whose key starts with
        // "TraitName::" and contains the requested method.
        var slot_index: ?usize = null;
        var it = self.trait_vtables.iterator();
        const prefix = try std.fmt.allocPrint(self.allocator, "{s}::", .{trait_name});
        defer self.allocator.free(prefix);
        while (it.next()) |entry| {
            if (!std.mem.startsWith(u8, entry.key_ptr.*, prefix)) continue;
            if (entry.value_ptr.method_indices.get(method_name)) |idx| {
                slot_index = idx;
                break;
            }
        }
        const idx = slot_index orelse return false;

        // Push args (skip arg 0 — that's `self`, supplied by the receiver).
        for (args) |arg| {
            try self.generateExpr(arg);
            try self.assembler.pushReg(.rax);
        }

        // Pop args into rsi/rdx/rcx/r8/r9 in reverse order.
        const arg_regs = [_]x64.Register{ .rsi, .rdx, .rcx, .r8, .r9 };
        const reg_arg_count = @min(args.len, arg_regs.len);
        var j: usize = reg_arg_count;
        while (j > 0) {
            j -= 1;
            try self.assembler.popReg(arg_regs[j]);
        }

        // Evaluate the receiver — gives us the trait-object header pointer
        // in rax. emitVirtualDispatch handles the rest (load vtable, load
        // function ptr, call indirect).
        try self.generateExpr(receiver_expr);
        try self.emitVirtualDispatch(idx);
        return true;
    }

    /// Emit an indirect call sequence for a virtual method dispatch.
    ///
    /// Preconditions:
    ///   - rax holds the *trait object header* (a pointer to a 16-byte
    ///     record: { data_ptr, vtable_ptr }).
    ///   - rsi/rdx/rcx/r8/r9 hold args 2..6 already (caller's responsibility).
    ///
    /// Effect:
    ///   - Loads the vtable pointer from [rax + 8] into r10.
    ///   - Loads the data pointer from [rax + 0] into rdi (receiver = arg 1).
    ///   - Loads the function pointer from [r10 + slot*8] into r11.
    ///   - Emits `call r11`.
    ///
    /// `slot` is the method's index in the vtable (0-based, in declaration order).
    pub fn emitVirtualDispatch(self: *NativeCodegen, slot: usize) !void {
        // r10 = vtable_ptr = [rax + 8]
        try self.assembler.movRegMem(.r10, .rax, 8);
        // rdi = data_ptr = [rax + 0]
        try self.assembler.movRegMem(.rdi, .rax, 0);
        // r11 = [r10 + slot*8]
        const offset_i32 = safeIntCast(i32, slot * 8) catch {
            std.debug.print("vtable slot {d} too large for i32 displacement\n", .{slot});
            return error.UnsupportedFeature;
        };
        try self.assembler.movRegMem(.r11, .r10, offset_i32);
        // call r11
        try self.assembler.callReg(.r11);
    }

    /// Load the address of a string literal into rax (registers a fixup for linking).
    fn loadStringLiteralIntoRax(self: *NativeCodegen, literal: []const u8) !void {
        const data_offset = try self.registerStringLiteral(literal);
        const code_pos = try self.assembler.leaRipRel(.rax, 0);
        try self.string_fixups.append(self.allocator, .{
            .code_pos = code_pos,
            .data_offset = data_offset,
        });
    }

    /// Concatenate two NUL-terminated strings whose pointers live in `left_reg` and `right_reg`.
    /// Result pointer ends up in rax.
    /// Both input registers may be clobbered.
    fn concatStringPointers(
        self: *NativeCodegen,
        left_reg: x64.Register,
        right_reg: x64.Register,
    ) !void {
        // Stash both inputs.
        try self.assembler.pushReg(left_reg);
        try self.assembler.pushReg(right_reg);

        // strlen(left) -> r8
        try self.assembler.movRegReg(.rdi, left_reg);
        try self.stringLength(.rdi);
        try self.assembler.movRegReg(.r8, .rax);

        // strlen(right) -> r9
        // (left_reg/right_reg may have been clobbered above; reload from stack.)
        try self.assembler.movRegMem(.rdi, .rsp, 0); // top of stack = saved right
        try self.stringLength(.rdi);
        try self.assembler.movRegReg(.r9, .rax);

        // total = r8 + r9 + 1
        try self.assembler.movRegReg(.rax, .r8);
        try self.assembler.addRegReg(.rax, .r9);
        try self.assembler.addRegImm(.rax, 1);

        // Allocate buffer.
        try self.assembler.movRegReg(.rdi, .rax);
        try self.heapAlloc();
        try self.assembler.movRegReg(.r10, .rax); // r10 = dest base

        // memcpy(r10, left, r8)
        try self.assembler.movRegMem(.rsi, .rsp, 8); // saved left = stack[8]
        try self.assembler.movRegReg(.rdi, .r10);
        try self.assembler.movRegReg(.rdx, .r8);
        try self.memcpy();

        // memcpy(r10 + r8, right, r9)
        try self.assembler.movRegMem(.rsi, .rsp, 0); // saved right = stack[0]
        try self.assembler.movRegReg(.rdi, .r10);
        try self.assembler.addRegReg(.rdi, .r8);
        try self.assembler.movRegReg(.rdx, .r9);
        try self.memcpy();

        // Null-terminate at r10 + r8 + r9
        try self.assembler.movRegReg(.rdi, .r10);
        try self.assembler.addRegReg(.rdi, .r8);
        try self.assembler.addRegReg(.rdi, .r9);
        try self.assembler.movByteMemImm(.rdi, 0, 0);

        // Pop saved inputs (discard).
        try self.assembler.popReg(.rcx);
        try self.assembler.popReg(.rcx);

        // Result in rax.
        try self.assembler.movRegReg(.rax, .r10);
    }

    /// Convert a signed 64-bit integer (in rax on entry) to a heap-allocated decimal string.
    /// Result pointer in rax. Handles negative numbers and zero. Clobbers rcx, rdx, r10, r11, r12.
    fn intToDecimalString(self: *NativeCodegen) !void {
        // Save the value we want to convert (rax) on the stack — heapAlloc clobbers rax.
        try self.assembler.pushReg(.rax);

        // Reserve a 32-byte buffer.
        try self.assembler.movRegImm64(.rdi, 32);
        try self.heapAlloc(); // rax = buffer
        try self.assembler.movRegReg(.r10, .rax); // r10 = buffer base

        // r11 = write cursor at buffer + 31 (NUL slot), then back up by one for first digit.
        try self.assembler.movRegReg(.r11, .r10);
        try self.assembler.addRegImm(.r11, 31);
        try self.assembler.movByteMemImm(.r11, 0, 0);
        try self.assembler.subRegImm(.r11, 1);

        // Restore the integer.
        try self.assembler.popReg(.rax);

        // Sign tracking in r12 (1 if negative).
        try self.assembler.xorRegReg(.r12, .r12);
        try self.assembler.testRegReg(.rax, .rax);
        const jns_pos = self.assembler.getPosition();
        try self.assembler.jnsRel32(0); // patched
        try self.assembler.negReg(.rax);
        try self.assembler.movRegImm64(.r12, 1);
        const after_neg = self.assembler.getPosition();
        try self.assembler.patchJnsRel32(jns_pos, @as(i32, @intCast(after_neg)) - @as(i32, @intCast(jns_pos + 6)));

        // Zero shortcut.
        try self.assembler.testRegReg(.rax, .rax);
        const jne_skip_zero = self.assembler.getPosition();
        try self.assembler.jneRel32(0);
        try self.assembler.movByteMemImm(.r11, 0, '0');
        try self.assembler.subRegImm(.r11, 1);
        const jmp_after_zero_pos = self.assembler.getPosition();
        try self.assembler.jmpRel32(0);
        const after_zero_branch = self.assembler.getPosition();
        try self.assembler.patchJneRel32(jne_skip_zero, @as(i32, @intCast(after_zero_branch)) - @as(i32, @intCast(jne_skip_zero + 6)));

        // Digit-extraction loop.
        const loop_start = self.assembler.getPosition();
        try self.assembler.testRegReg(.rax, .rax);
        const jeq_done = self.assembler.getPosition();
        try self.assembler.jeRel32(0);

        try self.assembler.cqo(); // sign-extend rax into rdx:rax
        try self.assembler.movRegImm64(.rcx, 10);
        try self.assembler.idivReg(.rcx); // rax = quot, rdx = rem
        try self.assembler.addRegImm(.rdx, '0');
        try self.assembler.movByteMemReg(.r11, 0, .rdx);
        try self.assembler.subRegImm(.r11, 1);

        const back_pos = self.assembler.getPosition();
        try self.assembler.jmpRel32(@as(i32, @intCast(loop_start)) - @as(i32, @intCast(back_pos + 5)));

        const after_loop = self.assembler.getPosition();
        try self.assembler.patchJeRel32(jeq_done, @as(i32, @intCast(after_loop)) - @as(i32, @intCast(jeq_done + 6)));
        try self.assembler.patchJmpRel32(jmp_after_zero_pos, @as(i32, @intCast(after_loop)) - @as(i32, @intCast(jmp_after_zero_pos + 5)));

        // Prepend '-' if negative.
        try self.assembler.testRegReg(.r12, .r12);
        const jeq_no_sign = self.assembler.getPosition();
        try self.assembler.jeRel32(0);
        try self.assembler.movByteMemImm(.r11, 0, '-');
        try self.assembler.subRegImm(.r11, 1);
        const after_sign = self.assembler.getPosition();
        try self.assembler.patchJeRel32(jeq_no_sign, @as(i32, @intCast(after_sign)) - @as(i32, @intCast(jeq_no_sign + 6)));

        // Result pointer = r11 + 1.
        try self.assembler.movRegReg(.rax, .r11);
        try self.assembler.addRegImm(.rax, 1);
    }

    fn generateFnDecl(self: *NativeCodegen, func: *ast.FnDecl) CodegenError!void {
        return self.generateFnDeclWithName(func, null);
    }

    /// Synthesize a concrete FnDecl from a trait method that has a default
    /// body, specialized for a given impl type. The resulting FnDecl can be
    /// passed to `generateFnDeclWithName` exactly like any regular method.
    ///
    /// Parameter/return types are converted from `*TypeExpr` to the string
    /// representation the codegen expects (just a type name), resolving
    /// `Self` → `impl_type`. Only the shapes the existing codegen actually
    /// inspects are filled in; everything else uses sensible defaults.
    fn synthesizeTraitDefaultFn(
        self: *NativeCodegen,
        tm: ast.TraitMethod,
        body: *ast.BlockStmt,
        impl_type: []const u8,
    ) !*ast.FnDecl {
        // Convert each trait FnParam → ast.Parameter. Allocated memory is
        // owned by self.allocator and outlives the synthesized FnDecl.
        var params = try self.allocator.alloc(ast.Parameter, tm.params.len);
        for (tm.params, 0..) |p, i| {
            const type_name = try self.typeExprToName(p.type_expr, impl_type);
            params[i] = .{
                .name = p.name,
                .type_name = type_name,
                .default_value = null,
                .loc = body.node.loc,
            };
        }

        const return_type_name: ?[]const u8 = if (tm.return_type) |rt|
            try self.typeExprToName(rt, impl_type)
        else
            null;

        const fd = try self.allocator.create(ast.FnDecl);
        fd.* = .{
            .node = .{ .type = .FnDecl, .loc = body.node.loc },
            .name = tm.name,
            .params = params,
            .return_type = return_type_name,
            .body = body,
            .is_async = tm.is_async,
            .type_params = &.{},
        };
        return fd;
    }

    /// Convert a TypeExpr to the flat string form used by native_codegen's
    /// other paths. `impl_type` is used to resolve `Self`.
    fn typeExprToName(
        self: *NativeCodegen,
        type_expr: *ast.TypeExpr,
        impl_type: []const u8,
    ) ![]const u8 {
        return switch (type_expr.*) {
            .Named => |n| try self.allocator.dupe(u8, n),
            .SelfType => try self.allocator.dupe(u8, impl_type),
            .Reference => |r| try self.typeExprToName(r.inner, impl_type),
            .Nullable => |inner| try self.typeExprToName(inner, impl_type),
            .Pointer => |p| try self.typeExprToName(p.inner, impl_type),
            .Generic => |g| try self.allocator.dupe(u8, g.base),
            .Array => try self.allocator.dupe(u8, "[int]"),
            .Tuple => try self.allocator.dupe(u8, "tuple"),
            .Function => try self.allocator.dupe(u8, "fn"),
            .TraitObject => |o| try self.allocator.dupe(u8, o.trait_name),
        };
    }

    fn generateFnDeclWithName(self: *NativeCodegen, func: *ast.FnDecl, override_name: ?[]const u8) CodegenError!void {
        // Use override name if provided (for struct methods with mangled names)
        const effective_name = override_name orelse func.name;

        // Async functions get a completely separate code path: a poll
        // function with a state machine plus an entry function that
        // allocates and initializes the state struct. Dispatch early so
        // none of the sync prologue/epilogue/local-tracking machinery
        // interferes.
        if (func.is_async) {
            // Track the current function name so error messages still make
            // sense; the poll/entry emitter records its own positions.
            self.current_function_name = effective_name;
            defer self.current_function_name = null;
            return self.generateAsyncFnDecl(func, effective_name);
        }

        // Track current function name for return statement handling
        self.current_function_name = effective_name;
        defer self.current_function_name = null;

        // Track async-ness so the return-stmt handler knows whether to wrap
        // the return value in a Future header. Restored on function exit.
        // (Sync path keeps the old behavior for back-compat.)
        const prev_async = self.current_function_is_async;
        self.current_function_is_async = func.is_async;
        defer self.current_function_is_async = prev_async;

        // Reset local variable tracking for new function
        self.next_local_offset = 0;

        // Free duplicated strings before clearing locals
        var iter = self.locals.keyIterator();
        while (iter.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
        self.locals.clearRetainingCapacity();

        // Record function position
        const func_pos = self.assembler.getPosition();
        // Only put if not pre-registered (methods are pre-registered with mangled names)
        if (!self.functions.contains(effective_name)) {
            const name_copy = try self.allocator.dupe(u8, effective_name);
            errdefer self.allocator.free(name_copy);
            try self.functions.put(name_copy, func_pos);
        }

        // Store function info with parameter defaults
        // Only register function_info if not already registered
        if (!self.function_info.contains(effective_name)) {
            var param_infos = try self.allocator.alloc(FunctionParamInfo, func.params.len);
            errdefer self.allocator.free(param_infos);

            var required_params: usize = 0;
            for (func.params, 0..) |param, i| {
                param_infos[i] = .{
                    .name = param.name,
                    .type_name = param.type_name,
                    .default_value = param.default_value,
                };
                if (param.default_value == null) {
                    required_params += 1;
                }
            }

            const info_name_copy = try self.allocator.dupe(u8, effective_name);
            errdefer self.allocator.free(info_name_copy);
            try self.function_info.put(info_name_copy, .{
                .position = func_pos,
                .params = param_infos,
                .required_params = required_params,
            });
        }

        // Function prologue
        try self.assembler.pushReg(.rbp);
        try self.assembler.movRegReg(.rbp, .rsp);

        // Handle parameters - x86-64 calling convention:
        // First 6 integer args: rdi, rsi, rdx, rcx, r8, r9
        // Additional args on stack
        const param_regs = [_]x64.Register{ .rdi, .rsi, .rdx, .rcx, .r8, .r9 };

        for (func.params, 0..) |param, i| {
            if (i < param_regs.len) {
                // Parameter is in register - save to stack
                const offset = self.next_local_offset;
                self.next_local_offset += 1; // Increment count, not bytes

                // Free old key if variable exists (shadowing)
                if (self.locals.fetchRemove(param.name)) |old_entry| {
                    self.allocator.free(old_entry.key);
                }
                // Store parameter name, offset, and type
                const name = try self.allocator.dupe(u8, param.name);
                // For struct types, we pass by pointer (8 bytes) not by value
                const is_struct_param = self.struct_layouts.contains(param.type_name);
                const param_size: usize = if (is_struct_param) 8 else try self.getTypeSize(param.type_name);
                self.locals.put(name, .{
                    .offset = offset,
                    .type_name = param.type_name,
                    .size = param_size,
                }) catch |err| {
                    self.allocator.free(name);
                    return err;
                };

                // Push parameter register onto stack
                try self.assembler.pushReg(param_regs[i]);
            } else {
                // Parameter is on stack (passed by caller)
                // Stack layout after prologue:
                // [rbp+0]: old rbp
                // [rbp+8]: return address
                // [rbp+16]: 7th arg (param index 6)
                // [rbp+24]: 8th arg (param index 7)
                // etc.

                // Calculate offset from rbp
                const stack_param_index = i - param_regs.len;
                const offset_from_rbp: i32 = @intCast(16 + (stack_param_index * 8));

                // Load the stack parameter and push it to our local stack
                // This normalizes all parameters to be accessed the same way
                try self.assembler.movRegMem(.rax, .rbp, offset_from_rbp);
                try self.assembler.pushReg(.rax);

                const offset = self.next_local_offset;
                self.next_local_offset += 1;

                // Free old key if variable exists (shadowing)
                if (self.locals.fetchRemove(param.name)) |old_entry| {
                    self.allocator.free(old_entry.key);
                }
                const name = try self.allocator.dupe(u8, param.name);
                // For struct types, we pass by pointer (8 bytes) not by value
                const is_struct_param = self.struct_layouts.contains(param.type_name);
                const param_size: usize = if (is_struct_param) 8 else try self.getTypeSize(param.type_name);
                self.locals.put(name, .{
                    .offset = offset,
                    .type_name = param.type_name,
                    .size = param_size,
                }) catch |err| {
                    self.allocator.free(name);
                    return err;
                };
            }
        }

        // Generate function body with dead code elimination
        for (func.body.statements, 0..) |stmt, i| {
            try self.generateStmt(stmt);

            // Dead code elimination: stop generating code after a return
            if (isReturn(stmt)) {
                // Skip remaining statements (they're unreachable)
                if (i + 1 < func.body.statements.len) {
                    // Emit warning about dead code (optional)
                    // std.debug.print("Warning: Dead code after return in function {s}\n", .{func.name});
                }
                break;
            }
        }

        // Function epilogue (only if no explicit return at end)
        const needs_epilogue = func.body.statements.len == 0 or
            func.body.statements[func.body.statements.len - 1] != .ReturnStmt;

        if (needs_epilogue) {
            // Drain any deferred expressions before the implicit return.
            if (self.defer_stack.items.len > 0) {
                try self.emitDeferredCleanup();
            }

            try self.assembler.movRegReg(.rsp, .rbp);
            try self.assembler.popReg(.rbp);

            if (std.mem.eql(u8, effective_name, "main")) {
                // Implicit main epilogue: exit with code 0. Explicit
                // `return N` in main uses N as the exit code via the
                // ReturnStmt handler.
                const exit_syscall: u64 = switch (builtin.os.tag) {
                    .macos => 0x2000001,
                    .linux => 60,
                    else => 60,
                };
                try self.assembler.movRegImm64(.rdi, 0);
                try self.assembler.movRegImm64(.rax, exit_syscall);
                try self.assembler.syscall();
            } else {
                try self.assembler.ret();
            }
        }
    }

    /// Emit all deferred expressions in LIFO (reverse) order, then clear the stack.
    fn emitDeferredCleanup(self: *NativeCodegen) !void {
        var i: usize = self.defer_stack.items.len;
        while (i > 0) {
            i -= 1;
            const deferred_expr = self.defer_stack.items[i];
            try self.generateExpr(deferred_expr);
        }
        self.defer_stack.items.len = 0;
    }

    fn generateLetDecl(self: *NativeCodegen, decl: *ast.LetDecl) !void {
        // Async fast path: locals live in the heap-allocated state struct
        // instead of on the stack. The pre-scan already allocated a slot.
        // Just evaluate the value and store it via [r12 + offset].
        if (self.async_ctx) |ctx| {
            if (decl.value) |value| {
                try self.generateExpr(value);
                if (ctx.locals.get(decl.name)) |off| {
                    try self.assembler.movMemReg(.rbx, off, .rax);
                }
            }
            return;
        }

        if (self.next_local_offset >= MAX_LOCALS) {
            return error.TooManyVariables;
        }

        if (decl.value) |value| {
            // Infer type from expression if no type annotation
            var inferred_type_name: ?[]const u8 = decl.type_name;
            if (inferred_type_name == null) {
                // Try to infer type from the value expression
                inferred_type_name = try self.inferExprType(value);
            }

            const type_name = inferred_type_name orelse "i32";

            // Check if this is an array type
            const is_array = type_name.len > 0 and type_name[0] == '[';

            if (is_array and value.* == .ArrayLiteral) {
                // Special handling for array literals
                const array_lit = value.ArrayLiteral;
                const elem_size: usize = 8; // All values are i64 for now
                const num_elements = array_lit.elements.len;

                // Array base points to the first element (index 0)
                const array_start_offset = self.next_local_offset;

                // Free old key if variable exists (shadowing)
                if (self.locals.fetchRemove(decl.name)) |old_entry| {
                    self.allocator.free(old_entry.key);
                }
                // Store variable name with pointer to array start
                const name = try self.allocator.dupe(u8, decl.name);
                self.locals.put(name, .{
                    .offset = array_start_offset,
                    .type_name = type_name,
                    .size = num_elements * elem_size,
                }) catch |err| {
                    self.allocator.free(name);
                    return err;
                };

                // Evaluate and push each element onto stack in FORWARD order
                // Element 0 at [rbp - (offset+1)*8], element 1 at [rbp - (offset+2)*8], etc.
                for (array_lit.elements) |elem| {
                    if (self.next_local_offset >= MAX_LOCALS) {
                        return error.TooManyVariables;
                    }
                    try self.generateExpr(elem);
                    try self.assembler.pushReg(.rax);
                    self.next_local_offset += 1;
                }
            } else if (value.* == .StructLiteral) {
                // Special handling for struct literals
                const struct_lit = value.StructLiteral;

                // Get struct layout
                const struct_layout = self.struct_layouts.get(struct_lit.type_name) orelse {
                    // Unknown struct type - treat as a single value
                    std.debug.print("Unknown struct type (treating as pointer): {s}\n", .{struct_lit.type_name});
                    // Just allocate a single slot and store a placeholder
                    try self.assembler.movRegImm64(.rax, 0);
                    try self.assembler.pushReg(.rax);

                    const name = try self.allocator.dupe(u8, decl.name);

                    if (self.locals.fetchRemove(decl.name)) |old_entry| {
                        self.allocator.free(old_entry.key);
                    }

                    self.locals.put(name, .{
                        .offset = self.next_local_offset,
                        .type_name = "unknown",
                        .size = 8,
                    }) catch |err| {
                        self.allocator.free(name);
                        return err;
                    };
                    self.next_local_offset += 1;
                    return;
                };

                // Struct base points to first field
                const struct_start_offset = self.next_local_offset;

                // Free old key if variable exists (shadowing)
                if (self.locals.fetchRemove(decl.name)) |old_entry| {
                    self.allocator.free(old_entry.key);
                }
                // Store variable name - use struct_lit.type_name for correct type
                const name = try self.allocator.dupe(u8, decl.name);
                // Use explicit error handling instead of errdefer to avoid double-free
                // If put() succeeds, HashMap owns 'name'; if it fails, we free 'name' before returning
                self.locals.put(name, .{
                    .offset = struct_start_offset,
                    .type_name = struct_lit.type_name,
                    .size = struct_layout.total_size,
                }) catch |err| {
                    self.allocator.free(name);
                    return err;
                };

                // Allocate and initialize fields in order
                // We need to match fields in the literal to fields in the layout
                for (struct_layout.fields) |field_info| {
                    if (self.next_local_offset >= MAX_LOCALS) {
                        return error.TooManyVariables;
                    }

                    // Find the field in the literal
                    var field_value: ?*ast.Expr = null;
                    for (struct_lit.fields) |lit_field| {
                        if (std.mem.eql(u8, lit_field.name, field_info.name)) {
                            field_value = lit_field.value;
                            break;
                        }
                    }

                    if (field_value) |val| {
                        // Evaluate and push field value
                        try self.generateExpr(val);
                        try self.assembler.pushReg(.rax);
                        self.next_local_offset += 1;
                    } else {
                        // Field not initialized - push zero
                        try self.assembler.movRegImm64(.rax, 0);
                        try self.assembler.pushReg(.rax);
                        self.next_local_offset += 1;
                    }
                }
            } else if (self.enum_layouts.contains(type_name)) {
                // Special handling for enum values
                // Enums are 16 bytes: [tag (8 bytes)][data (8 bytes)]
                // The enum constructor pushes: data first, then tag
                // Stack layout after constructor:
                //   [rsp+0] = tag (pushed second, lower address)
                //   [rsp+8] = data (pushed first, higher address)

                // Evaluate the enum constructor expression
                // This will push data then tag onto stack and return pointer (rsp) in rax
                try self.generateExpr(value);

                // rax contains rsp (pointer to tag on stack)
                // The enum constructor already pushed both values onto the stack
                // Current stack (from low to high addr):
                //   [rbp - ((next_local_offset+1)*8)] = tag  <- rsp points here
                //   [rbp - ((next_local_offset+0)*8)] = data

                // Record that the tag is at the current offset
                // (The tag was the SECOND push, so it's at next_local_offset+1)
                const tag_offset = self.next_local_offset + 1;

                // Free old key if variable exists (shadowing)
                if (self.locals.fetchRemove(decl.name)) |old_entry| {
                    self.allocator.free(old_entry.key);
                }
                // Store variable name pointing to where the tag is on stack
                const name = try self.allocator.dupe(u8, decl.name);
                self.locals.put(name, .{
                    .offset = tag_offset,  // Tag is at higher offset (pushed second)
                    .type_name = type_name,
                    .size = 16, // All enums are 16 bytes (tag + data)
                }) catch |err| {
                    self.allocator.free(name);
                    return err;
                };

                // Update offset to account for 2 slots used by enum (data and tag)
                self.next_local_offset += 2;
            } else {
                // Regular scalar value
                // Evaluate the expression (result in rax)
                try self.generateExpr(value);

                // Store on stack
                const offset = self.next_local_offset;
                self.next_local_offset += 1; // Increment count, not bytes

                // Store variable name, offset, and type
                const var_size = try self.getTypeSize(type_name);
                // Check if variable already exists (shadowing) and free old key
                if (self.locals.fetchRemove(decl.name)) |old_entry| {
                    self.allocator.free(old_entry.key);
                }
                const name = try self.allocator.dupe(u8, decl.name);
                self.locals.put(name, .{
                    .offset = offset,
                    .type_name = type_name,
                    .size = var_size,
                }) catch |err| {
                    self.allocator.free(name);
                    return err;
                };

                // Push rax onto stack
                try self.assembler.pushReg(.rax);
            }
        }
    }

    /// Generate tuple destructuring: let (a, b) = expr
    fn generateTupleDestructure(self: *NativeCodegen, decl: *ast.TupleDestructureDecl) !void {
        // Evaluate the tuple expression - result will be pointer to tuple in rax
        try self.generateExpr(decl.value);

        // TupleExpr pushed to stack in this order (first push = highest stack address):
        //   1. Push elem[n-1] (last element)
        //   2. Push elem[n-2]
        //   ...
        //   n. Push elem[0] (first element)
        //   n+1. Push count
        //
        // So stack looks like (from high to low address):
        //   [rbp - 8]           = elem[n-1]  (offset n-1 in locals)
        //   [rbp - 16]          = elem[n-2]  (offset n-2)
        //   ...
        //   [rbp - n*8]         = elem[0]    (offset 0... wait no)
        //   [rbp - (n+1)*8]     = count
        //   rsp points here
        //
        // Using next_local_offset system where offset 0 = [rbp - 8]:
        //   offset 0 -> [rbp - 8] = elem[n-1]
        //   offset 1 -> [rbp - 16] = elem[n-2]
        //   ...
        //   offset n-1 -> elem[0]
        //   offset n -> count
        //
        // For let (a, b) = (1, 2) where a=elem[0]=1, b=elem[1]=2:
        //   Stack after TupleExpr: elem[1]=2 at offset 0, elem[0]=1 at offset 1, count at offset 2
        //   a (elem[0]) should map to offset n-1 = 1
        //   b (elem[1]) should map to offset n-2 = 0

        const n = decl.names.len;

        // First, reserve all the slots for the tuple (count + elements)
        // We need to assign offsets in reverse order for the elements
        // The stack has already been modified by TupleExpr - we're just updating tracking

        // Element i (0-indexed) is at rbp-offset where the offset position is (n-1-i) in our local scheme
        // because elem[0] was pushed last (lowest address) and elem[n-1] was pushed first (highest address)

        // Assign names to their corresponding stack slots
        for (decl.names, 0..) |name, i| {
            if (self.next_local_offset + n >= MAX_LOCALS) {
                return error.TooManyVariables;
            }

            // Element i is at stack position (n-1-i) from the top of the elements
            // Since elements were pushed in reverse, elem[0] is at the deepest position
            const elem_offset: u8 = @intCast(n - 1 - i);

            // Free old key if variable exists (shadowing)
            if (self.locals.fetchRemove(name)) |old_entry| {
                self.allocator.free(old_entry.key);
            }

            const var_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(var_name);
            try self.locals.put(var_name, .{
                .offset = elem_offset,
                .type_name = "i64", // Default type for tuple elements
                .size = 8,
            });
        }

        // Update next_local_offset to account for all tuple slots (elements + count)
        self.next_local_offset += @as(u32, @intCast(n + 1));
    }

    /// Try to fold constant expressions at compile-time.
    ///
    /// Uses checked arithmetic so an overflowing literal in the user's source
    /// (`9223372036854775807 + 1`) refuses to fold rather than wrapping
    /// silently. The caller falls back to emitting a real BinaryExpr, which
    /// goes through the runtime arithmetic path and traps if it actually
    /// overflows at run time.
    fn tryFoldConstant(self: *NativeCodegen, expr: *const ast.Expr) ?i64 {
        switch (expr.*) {
            .IntegerLiteral => |lit| return lit.value,
            .BooleanLiteral => |lit| return if (lit.value) 1 else 0,
            .BinaryExpr => |bin| {
                const left = self.tryFoldConstant(bin.left) orelse return null;
                const right = self.tryFoldConstant(bin.right) orelse return null;

                return switch (bin.op) {
                    .Add => std.math.add(i64, left, right) catch null,
                    .Sub => std.math.sub(i64, left, right) catch null,
                    .Mul => std.math.mul(i64, left, right) catch null,
                    .Div => if (right != 0) @divTrunc(left, right) else null,
                    .Mod => if (right != 0) @rem(left, right) else null,
                    .BitAnd => left & right,
                    .BitOr => left | right,
                    .BitXor => left ^ right,
                    .LeftShift => if (right >= 0 and right < 64) left << @intCast(right) else null,
                    .RightShift => if (right >= 0 and right < 64) left >> @intCast(right) else null,
                    .Equal => if (left == right) 1 else 0,
                    .NotEqual => if (left != right) 1 else 0,
                    .Less => if (left < right) 1 else 0,
                    .LessEq => if (left <= right) 1 else 0,
                    .Greater => if (left > right) 1 else 0,
                    .GreaterEq => if (left >= right) 1 else 0,
                    .And => if (left != 0 and right != 0) 1 else 0,
                    .Or => if (left != 0 or right != 0) 1 else 0,
                    else => null,
                };
            },
            .UnaryExpr => |un| {
                const operand = self.tryFoldConstant(un.operand) orelse return null;

                return switch (un.op) {
                    .Neg => -operand,
                    .Not => if (operand == 0) 1 else 0,
                    .BitNot => ~operand,
                    else => null,
                };
            },
            else => return null,
        }
    }

    /// Emit raw opcode bytes. Used for x87 instructions that don't have named
    /// wrappers in the assembler yet (e.g. `fld st(0)`, `faddp`, etc).
    fn emitRawBytes(self: *NativeCodegen, bytes: []const u8) CodegenError!void {
        for (bytes) |b| {
            try self.assembler.code.append(self.assembler.allocator, b);
        }
    }

    /// Emit x87 FPU code for `exp(x)` where x is the double-bit-pattern in rax
    /// on entry and exit.
    ///
    /// Strategy: e^x = 2^(x * log2(e)). Split y = x*log2(e) into integer part i
    /// and fractional part f, then 2^y = 2^i * 2^f = 2^i * (1 + (2^f - 1)).
    /// Uses fldl2e, fyl2x-free path (just fmulp), frndint, f2xm1, fscale.
    fn emitFpuExp(self: *NativeCodegen) CodegenError!void {
        try self.assembler.pushReg(.rax);
        try self.assembler.fldl2e();        // st(0) = log2(e)
        try self.assembler.fldQwordRsp();   // st(0) = x, st(1) = log2(e)
        try self.emitRawBytes(&[_]u8{ 0xDE, 0xC9 }); // fmulp st(1), st(0): st(1)*=st(0), pop
        // Stack: st(0) = x*log2(e) = y.
        try self.emitRawBytes(&[_]u8{ 0xD9, 0xC0 }); // fld st(0): duplicate y
        try self.assembler.frndint();       // st(0) = round(y) = i
        try self.emitRawBytes(&[_]u8{ 0xDC, 0xE9 }); // fsub st(1), st(0): st(1) -= st(0) → st(1) = f
        // Stack: st(0) = i, st(1) = f.
        try self.assembler.fxch();          // st(0) = f, st(1) = i
        try self.assembler.f2xm1();         // st(0) = 2^f - 1
        try self.assembler.fld1();          // st(0) = 1, st(1) = 2^f - 1, st(2) = i
        try self.emitRawBytes(&[_]u8{ 0xDE, 0xC1 }); // faddp st(1), st(0): st(1) += st(0), pop
        // Stack: st(0) = 2^f, st(1) = i.
        try self.assembler.fscale();        // st(0) = 2^f * 2^i = 2^y = e^x
        // Drop i from stack: fstp st(1) stores st(0) to st(1) and pops, leaving st(0) = 2^y.
        try self.assembler.fstpSt1();
        try self.assembler.fstpQwordRsp();
        try self.assembler.popReg(.rax);
    }

    fn generateExpr(self: *NativeCodegen, expr: *const ast.Expr) CodegenError!void {
        // Try constant folding first
        if (self.tryFoldConstant(expr)) |folded_value| {
            try self.assembler.movRegImm64(.rax, @bitCast(folded_value));
            return;
        }

        switch (expr.*) {
            .IntegerLiteral => |lit| {
                // Load immediate value into rax
                try self.assembler.movRegImm64(.rax, lit.value);
            },
            .FloatLiteral => |lit| {
                // Load float as bit pattern into rax
                // This allows passing float values through integer registers
                const float_bits: u64 = @bitCast(lit.value);
                try self.assembler.movRegImm64(.rax, @bitCast(float_bits));
            },
            .BooleanLiteral => |lit| {
                // Load boolean value into rax (0 for false, 1 for true)
                try self.assembler.movRegImm64(.rax, if (lit.value) 1 else 0);
            },
            .NullLiteral => {
                // Null is simply 0
                try self.assembler.movRegImm64(.rax, 0);
            },
            .Identifier => |id| {
                // Async fast path: identifier resolves to a state-struct slot.
                // Reads happen via `mov rax, [rbx + offset]`.
                if (self.async_ctx) |ctx| {
                    if (ctx.locals.get(id.name)) |off| {
                        try self.assembler.movRegMem(.rax, .rbx, off);
                        return;
                    }
                }
                // Load from stack
                if (self.locals.get(id.name)) |local_info| {
                    // Check if this is an array, struct, or enum type - return pointer instead of value
                    const is_array = local_info.type_name.len > 0 and local_info.type_name[0] == '[';
                    const is_struct = self.struct_layouts.contains(local_info.type_name);
                    const is_enum = self.enum_layouts.contains(local_info.type_name);

                    // Stack layout after function prologue:
                    // [rbp+0]: saved rbp
                    // [rbp-8]: first pushed item (offset=0)
                    // [rbp-16]: second pushed item (offset=1)
                    // [rbp-24]: third pushed item (offset=2)
                    // etc.
                    // Items pushed first are at higher addresses (closer to rbp)
                    // Guard against unreasonably large offsets (likely indicates parsing error)
                    // Calculate the byte offset, checking for overflow
                    const offset_plus_one = local_info.offset +% 1;
                    const byte_offset = offset_plus_one *% 8;

                    // Reject stack frames that overflow the i32 displacement range.
                    if (byte_offset > @as(usize, std.math.maxInt(i32))) {
                        return error.StackTooLarge;
                    }
                    const stack_offset: i32 = -@as(i32, @intCast(byte_offset));

                    if (is_array or is_struct or is_enum) {
                        // For arrays, structs, and enums, return pointer to start
                        // lea rax, [rbp + stack_offset]
                        try self.assembler.movRegReg(.rax, .rbp);
                        try self.assembler.addRegImm32(.rax, stack_offset);
                    } else {
                        // For scalars, load the value
                        // mov rax, [rbp + stack_offset]
                        try self.assembler.movRegMem(.rax, .rbp, stack_offset);
                    }
                } else {
                    // Variable not found - might be from an unresolved scope
                    // Return 0 as placeholder to allow compilation to continue
                    try self.assembler.movRegImm64(.rax, 0);
                }
            },
            .BinaryExpr => |binary| {
                // Check if this is a string operation
                const is_string_op = self.isStringExpr(binary.left) or self.isStringExpr(binary.right);

                if (is_string_op) {
                    // Handle string operations
                    try self.handleStringBinaryOp(binary);
                    return;
                }

                // Float operations: both operands are double — use SSE2.
                if (self.isFloatExpr(binary.left) or self.isFloatExpr(binary.right)) {
                    try self.emitFloatBinaryOp(binary);
                    return;
                }

                // Constant-shift fast path: if the RHS of a shift is a
                // small non-negative integer literal, we can emit the
                // shorter `shl/shr/sar reg, imm8` form instead of piping
                // the count through CL. Saves at least one `mov` + skips
                // a register save/restore in the common case
                // `x << 1`, `x >> 2`, etc.
                if ((binary.op == .LeftShift or binary.op == .RightShift) and
                    binary.right.* == .IntegerLiteral)
                {
                    const count = binary.right.IntegerLiteral.value;
                    if (count >= 0 and count < 64) {
                        try self.generateExpr(binary.left);
                        const imm: u8 = @intCast(count);
                        switch (binary.op) {
                            .LeftShift => try self.assembler.shlRegImm8(.rax, imm),
                            .RightShift => try self.assembler.shrRegImm8(.rax, imm),
                            else => unreachable,
                        }
                        return;
                    }
                }

                // Evaluate right operand first (save result)
                try self.generateExpr(binary.right);
                try self.assembler.pushReg(.rax);

                // Evaluate left operand (result in rax)
                try self.generateExpr(binary.left);

                // Pop right operand into rcx
                try self.assembler.popReg(.rcx);

                // Perform operation
                switch (binary.op) {
                    .Add => try self.assembler.addRegReg(.rax, .rcx),
                    .Sub => try self.assembler.subRegReg(.rax, .rcx),
                    .Mul => try self.assembler.imulRegReg(.rax, .rcx),
                    .Div, .Mod, .IntDiv => {
                        // Check for division by zero to avoid a hardware SIGFPE.
                        try self.assembler.testRegReg(.rcx, .rcx);
                        const jnz_patch = self.assembler.getPosition();
                        try self.assembler.jnzRel32(0); // skip panic if rcx != 0

                        // Division by zero: exit with code 1 and a message.
                        try self.assembler.movRegImm64(.rdi, 1);
                        const dz_exit: u64 = switch (builtin.os.tag) {
                            .macos => 0x2000001,
                            .linux => 60,
                            else => 60,
                        };
                        try self.assembler.movRegImm64(.rax, dz_exit);
                        try self.assembler.syscall();

                        // Patch jnz to here (normal path).
                        const ok_pos = self.assembler.getPosition();
                        const jnz_off = @as(i32, @intCast(ok_pos)) - @as(i32, @intCast(jnz_patch + 6));
                        try self.assembler.patchJnzRel32(jnz_patch, jnz_off);

                        // Sign-extend rax into rdx, then divide.
                        try self.assembler.cqo();
                        try self.assembler.idivReg(.rcx);

                        if (binary.op == .Mod) {
                            // Remainder is in rdx — move to rax.
                            try self.assembler.movRegReg(.rax, .rdx);
                        }
                        // .Div / .IntDiv: quotient already in rax.
                    },
                    .Power => {
                        // Power: rax = rax ** rcx
                        // Simple loop implementation for integer exponentiation
                        // Save base in r11, exponent in rcx, result in rax
                        try self.assembler.movRegReg(.r11, .rax); // r11 = base
                        try self.assembler.movRegImm64(.rax, 1); // result = 1

                        // Label for loop start
                        const loop_start = self.assembler.code.items.len;

                        // test rcx, rcx ; jz done
                        try self.assembler.testRegReg(.rcx, .rcx);
                        const jz_patch = self.assembler.code.items.len;
                        try self.assembler.jzRel32(0); // Will patch later

                        // result = result * base
                        try self.assembler.imulRegReg(.rax, .r11);

                        // dec rcx
                        try self.assembler.subRegImm(.rcx, 1);

                        // jmp loop_start
                        const current_pos = self.assembler.code.items.len;
                        const rel_offset = @as(i32, @intCast(@as(i64, @intCast(loop_start)) - @as(i64, @intCast(current_pos + 5))));
                        try self.assembler.jmpRel32(rel_offset);

                        // Patch the jz offset via the safe helper that
                        // respects buffer bounds (was raw .items[] write).
                        const done_pos = self.assembler.getPosition();
                        const jz_rel = @as(i32, @intCast(@as(i64, @intCast(done_pos)) - @as(i64, @intCast(jz_patch + 6))));
                        try self.assembler.patchJzRel32(jz_patch, jz_rel);
                    },
                    // Comparison operators - result is 0 or 1
                    .Equal => {
                        // cmp rax, rcx; sete al; movzx rax, al
                        try self.assembler.cmpRegReg(.rax, .rcx);
                        try self.assembler.seteReg(.rax);
                        try self.assembler.movzxReg64Reg8(.rax, .rax);
                    },
                    .NotEqual => {
                        try self.assembler.cmpRegReg(.rax, .rcx);
                        try self.assembler.setneReg(.rax);
                        try self.assembler.movzxReg64Reg8(.rax, .rax);
                    },
                    .Less => {
                        try self.assembler.cmpRegReg(.rax, .rcx);
                        try self.assembler.setlReg(.rax);
                        try self.assembler.movzxReg64Reg8(.rax, .rax);
                    },
                    .LessEq => {
                        try self.assembler.cmpRegReg(.rax, .rcx);
                        try self.assembler.setleReg(.rax);
                        try self.assembler.movzxReg64Reg8(.rax, .rax);
                    },
                    .Greater => {
                        try self.assembler.cmpRegReg(.rax, .rcx);
                        try self.assembler.setgReg(.rax);
                        try self.assembler.movzxReg64Reg8(.rax, .rax);
                    },
                    .GreaterEq => {
                        try self.assembler.cmpRegReg(.rax, .rcx);
                        try self.assembler.setgeReg(.rax);
                        try self.assembler.movzxReg64Reg8(.rax, .rax);
                    },
                    // Logical operators - treat as boolean (0 = false, non-zero = true)
                    .And => {
                        // Convert to boolean first: test rax, rax; setne al; movzx rax, al
                        try self.assembler.testRegReg(.rax, .rax);
                        try self.assembler.setneReg(.rax);
                        try self.assembler.movzxReg64Reg8(.rax, .rax);
                        // Save left boolean in r11
                        try self.assembler.movRegReg(.r11, .rax);
                        // Convert right to boolean
                        try self.assembler.testRegReg(.rcx, .rcx);
                        try self.assembler.setneReg(.rcx);
                        try self.assembler.movzxReg64Reg8(.rcx, .rcx);
                        // AND the booleans
                        try self.assembler.andRegReg(.rax, .rcx);
                    },
                    .Or => {
                        // Convert to boolean and OR
                        try self.assembler.testRegReg(.rax, .rax);
                        try self.assembler.setneReg(.rax);
                        try self.assembler.movzxReg64Reg8(.rax, .rax);
                        try self.assembler.movRegReg(.r11, .rax);
                        try self.assembler.testRegReg(.rcx, .rcx);
                        try self.assembler.setneReg(.rcx);
                        try self.assembler.movzxReg64Reg8(.rcx, .rcx);
                        try self.assembler.orRegReg(.rax, .rcx);
                    },
                    // Bitwise operators
                    .BitAnd => try self.assembler.andRegReg(.rax, .rcx),
                    .BitOr => try self.assembler.orRegReg(.rax, .rcx),
                    .BitXor => try self.assembler.xorRegReg(.rax, .rcx),
                    // Shift operators (shift amount must be in CL register)
                    .LeftShift => {
                        // Left operand (value to shift) is in rax
                        // Right operand (shift amount) is in rcx
                        // x64 shift instructions require shift amount in CL (lower 8 bits of RCX)
                        try self.assembler.shlRegCl(.rax);
                    },
                    .RightShift => {
                        // Arithmetic right shift (signed) — preserves the sign bit
                        // for i64 values, matching TypeScript/Java semantics where
                        // >> sign-extends.  Logical (unsigned) shift would be >>>.
                        try self.assembler.sarRegCl(.rax);
                    },
                    // Checked arithmetic operators - panic on overflow.
                    // We stash the original operand values on the stack
                    // before performing the op so the panic path can print
                    // them. The panic body is now large (itoa + 4 syscalls)
                    // so we must use rel32 jumps for the jno-over-panic.
                    .CheckedAdd => try self.emitCheckedBinaryOp(
                        .Add,
                        "panic: integer overflow in checked add: ",
                        " + ",
                    ),
                    .CheckedSub => try self.emitCheckedBinaryOp(
                        .Sub,
                        "panic: integer overflow in checked sub: ",
                        " - ",
                    ),
                    .CheckedMul => try self.emitCheckedBinaryOp(
                        .Mul,
                        "panic: integer overflow in checked mul: ",
                        " * ",
                    ),
                    .CheckedDiv => {
                        // Check for division by zero before dividing. We
                        // also capture the dividend so the panic path can
                        // report "panic: division by zero: N / 0".
                        try self.assembler.pushReg(.rax); // lhs (dividend)
                        try self.assembler.pushReg(.rcx); // rhs (divisor, known 0 on panic)
                        try self.assembler.testRegReg(.rcx, .rcx);
                        const jnz_patch = self.assembler.getPosition();
                        try self.assembler.jnzRel32(0); // skip panic if non-zero
                        try self.emitCheckedOpPanic(
                            "panic: division by zero in checked div: ",
                            " / ",
                        );
                        const after_panic = self.assembler.getPosition();
                        try self.assembler.patchJnzRel32(
                            jnz_patch,
                            @as(i32, @intCast(after_panic)) - @as(i32, @intCast(jnz_patch + 6)),
                        );
                        // Drop the two pushed operands from the happy path.
                        try self.assembler.addRegImm(.rsp, 16);
                        // Perform division (rax already holds dividend; cqo sign-extends).
                        try self.assembler.cqo();
                        try self.assembler.idivReg(.rcx);
                    },
                    // Saturating arithmetic — on overflow, clamp at i64::MAX
                    // or i64::MIN based on the sign of the mathematically
                    // correct result. Matches Rust's `i64::saturating_add`
                    // semantics. Previous revision returned 0 on overflow,
                    // which silently produced a value that looked like a
                    // legal computation result.
                    .SaturatingAdd => {
                        try self.assembler.addRegReg(.rax, .rcx);
                        const jno_patch = self.assembler.getPosition();
                        try self.assembler.jnoRel32(0);
                        // Overflow → MAX if rhs >= 0, else MIN (same as ClampAdd).
                        try self.assembler.movRegImm64(.rax, std.math.maxInt(i64));
                        try self.assembler.movRegImm64(.r11, std.math.minInt(i64));
                        try self.assembler.testRegReg(.rcx, .rcx);
                        try self.assembler.cmovsRegReg(.rax, .r11);
                        const after_pos = self.assembler.getPosition();
                        try self.assembler.patchJnoRel32(
                            jno_patch,
                            @as(i32, @intCast(after_pos)) - @as(i32, @intCast(jno_patch + 6)),
                        );
                    },
                    .SaturatingSub => {
                        try self.assembler.subRegReg(.rax, .rcx);
                        const jno_patch = self.assembler.getPosition();
                        try self.assembler.jnoRel32(0);
                        // Overflow → MIN if rhs >= 0 (we subtracted too much),
                        // else MAX.
                        try self.assembler.movRegImm64(.rax, std.math.minInt(i64));
                        try self.assembler.movRegImm64(.r11, std.math.maxInt(i64));
                        try self.assembler.testRegReg(.rcx, .rcx);
                        try self.assembler.cmovsRegReg(.rax, .r11);
                        const after_pos = self.assembler.getPosition();
                        try self.assembler.patchJnoRel32(
                            jno_patch,
                            @as(i32, @intCast(after_pos)) - @as(i32, @intCast(jno_patch + 6)),
                        );
                    },
                    .SaturatingMul => {
                        // Capture the sign of the mathematically correct
                        // product in r11 (bit 63) BEFORE the imul clobbers
                        // flags. imul does NOT clobber r11, so the sign
                        // bit survives to the test+cmovs below.
                        try self.assembler.movRegReg(.r11, .rax);
                        try self.assembler.xorRegReg(.r11, .rcx);
                        try self.assembler.imulRegReg(.rax, .rcx);
                        const jno_patch = self.assembler.getPosition();
                        try self.assembler.jnoRel32(0);
                        try self.assembler.movRegImm64(.rax, std.math.maxInt(i64));
                        try self.assembler.movRegImm64(.rcx, std.math.minInt(i64));
                        try self.assembler.testRegReg(.r11, .r11);
                        try self.assembler.cmovsRegReg(.rax, .rcx);
                        const after_pos = self.assembler.getPosition();
                        try self.assembler.patchJnoRel32(
                            jno_patch,
                            @as(i32, @intCast(after_pos)) - @as(i32, @intCast(jno_patch + 6)),
                        );
                    },
                    .SaturatingDiv => {
                        // Saturating semantics clamp on overflow, but
                        // division by zero is undefined — panic instead
                        // of silently returning 0.
                        try self.assembler.testRegReg(.rcx, .rcx);
                        const jnz_patch = self.assembler.getPosition();
                        try self.assembler.jnzRel32(0);
                        try self.emitRuntimePanic("panic: division by zero in saturating div");
                        const div_pos = self.assembler.getPosition();
                        try self.assembler.patchJnzRel32(
                            jnz_patch,
                            @as(i32, @intCast(div_pos)) - @as(i32, @intCast(jnz_patch + 6)),
                        );
                        try self.assembler.cqo();
                        try self.assembler.idivReg(.rcx);
                    },
                    // Clamping/saturating arithmetic (`+|`, `-|`, `*|`).
                    // On overflow, pin the result at i64::MAX or i64::MIN based
                    // on the sign of the RHS operand (for add) / the sign of
                    // the high half (for mul). Different from SaturatingAdd
                    // which returns 0 (None-like).
                    .ClampAdd => {
                        try self.assembler.addRegReg(.rax, .rcx);
                        const jno_patch = self.assembler.getPosition();
                        try self.assembler.jnoRel32(0); // no overflow -> done
                        // Overflow: if rcx (RHS) >= 0 we went above MAX,
                        // otherwise we went below MIN. Use cmovs to pick.
                        // Load MAX into rax, MIN into r11, test rcx sign.
                        try self.assembler.movRegImm64(.rax, std.math.maxInt(i64));
                        try self.assembler.movRegImm64(.r11, std.math.minInt(i64));
                        try self.assembler.testRegReg(.rcx, .rcx);
                        // cmovs: if sign flag set (rcx < 0), rax = r11 (MIN).
                        try self.assembler.cmovsRegReg(.rax, .r11);
                        const after_pos = self.assembler.getPosition();
                        try self.assembler.patchJnoRel32(jno_patch, @as(i32, @intCast(after_pos)) - @as(i32, @intCast(jno_patch + 6)));
                    },
                    .ClampSub => {
                        try self.assembler.subRegReg(.rax, .rcx);
                        const jno_patch = self.assembler.getPosition();
                        try self.assembler.jnoRel32(0);
                        // Overflow: if rcx (RHS) >= 0 we subtracted too much
                        // (went below MIN), else went above MAX. Opposite of add.
                        try self.assembler.movRegImm64(.rax, std.math.minInt(i64));
                        try self.assembler.movRegImm64(.r11, std.math.maxInt(i64));
                        try self.assembler.testRegReg(.rcx, .rcx);
                        try self.assembler.cmovsRegReg(.rax, .r11);
                        const after_pos = self.assembler.getPosition();
                        try self.assembler.patchJnoRel32(jno_patch, @as(i32, @intCast(after_pos)) - @as(i32, @intCast(jno_patch + 6)));
                    },
                    .ClampMul => {
                        // Save original operands for sign detection.
                        // rax holds lhs, rcx holds rhs. xor rax ^ rcx keeps
                        // the sign of the mathematically-correct product.
                        try self.assembler.movRegReg(.r11, .rax);
                        try self.assembler.xorRegReg(.r11, .rcx);
                        try self.assembler.imulRegReg(.rax, .rcx);
                        const jno_patch = self.assembler.getPosition();
                        try self.assembler.jnoRel32(0);
                        // Overflow: clamp based on sign in r11.
                        try self.assembler.movRegImm64(.rax, std.math.maxInt(i64));
                        try self.assembler.movRegImm64(.rcx, std.math.minInt(i64));
                        try self.assembler.testRegReg(.r11, .r11);
                        try self.assembler.cmovsRegReg(.rax, .rcx);
                        const after_pos = self.assembler.getPosition();
                        try self.assembler.patchJnoRel32(jno_patch, @as(i32, @intCast(after_pos)) - @as(i32, @intCast(jno_patch + 6)));
                    },
                    else => {
                        std.debug.print("Unsupported binary op in native codegen: {}\n", .{binary.op});
                        return error.UnsupportedFeature;
                    },
                }
            },
            .UnaryExpr => |unary| {
                const operand_is_float = self.isFloatExpr(unary.operand);

                // Evaluate operand first (result in rax)
                try self.generateExpr(unary.operand);

                // Apply unary operation
                switch (unary.op) {
                    .Neg => {
                        if (operand_is_float) {
                            // Flip only the sign bit: rax ^= 1 << 63.
                            try self.assembler.movRegImm64(.rcx, @bitCast(@as(u64, 0x8000000000000000)));
                            try self.assembler.xorRegReg(.rax, .rcx);
                        } else {
                            // Integer two's complement: neg rax.
                            try self.assembler.negReg(.rax);
                        }
                    },
                    .Not => {
                        // Logical NOT: convert to boolean first, then invert
                        // test rax, rax; setz al; movzx rax, al
                        try self.assembler.testRegReg(.rax, .rax);
                        try self.assembler.setzReg(.rax);
                        try self.assembler.movzxReg64Reg8(.rax, .rax);
                    },
                    .BitNot => {
                        // Bitwise NOT: not rax
                        try self.assembler.notReg(.rax);
                    },
                    .Deref => {
                        // Dereference: rax contains a pointer, load the value it points to
                        // mov rax, [rax]
                        try self.assembler.movRegMem(.rax, .rax, 0);
                    },
                    .AddressOf => {
                        // Address-of: rax should contain the address of the operand
                        // If operand is already a pointer/address (from generateExpr), keep it
                        // This typically happens when operand is a struct or array
                        // For identifiers, generateExpr already returns address for structs
                        // No additional operation needed - rax already has the address
                    },
                    .Borrow, .BorrowMut => {
                        // Borrow operations - placeholder for future ownership tracking
                        // For now, treat as address-of
                    },
                }
            },
            .CallExpr => |call| {
                // Check if this is an enum variant constructor (e.g., Option.Some(42))
                if (call.callee.* == .MemberExpr) {
                    const member = call.callee.MemberExpr;
                    if (member.object.* == .Identifier) {
                        const enum_name = member.object.Identifier.name;
                        const variant_name = member.member;

                        // Builtin: Array.new() — heap-allocate a dynamic
                        // array with an *indirect* header layout so growth
                        // can reallocate the slot storage without moving
                        // the header pointer the caller holds.
                        //
                        //   [base+0]  len       (i64, mutated by push/pop/...)
                        //   [base+8]  cap       (i64, updated on growth)
                        //   [base+16] data_ptr  (i64 → separate heap block)
                        //
                        // Slot i lives at `[data_ptr + i*8]`. push() triggers
                        // exponential growth (doubling) when len == cap so
                        // the old fixed-cap=128 ceiling is gone.
                        if (std.mem.eql(u8, enum_name, "Array") and std.mem.eql(u8, variant_name, "new")) {
                            const INITIAL_CAP: i64 = 8;
                            // Header block (24 bytes — heapAlloc rounds up).
                            try self.assembler.movRegImm64(.rdi, 24);
                            try self.heapAlloc();
                            try self.assembler.pushReg(.rax); // save header
                            // Data block (INITIAL_CAP * 8 bytes).
                            try self.assembler.movRegImm64(.rdi, INITIAL_CAP * 8);
                            try self.heapAlloc();
                            // rax = data ptr; retrieve header from stack.
                            try self.assembler.movRegReg(.r11, .rax); // r11 = data
                            try self.assembler.popReg(.rax); // rax = header
                            // len = 0
                            try self.assembler.movRegImm64(.rcx, 0);
                            try self.assembler.movMemReg(.rax, 0, .rcx);
                            // cap = INITIAL_CAP
                            try self.assembler.movRegImm64(.rcx, INITIAL_CAP);
                            try self.assembler.movMemReg(.rax, 8, .rcx);
                            // data_ptr = r11
                            try self.assembler.movMemReg(.rax, 16, .r11);
                            return;
                        }

                        if (self.enum_layouts.get(enum_name)) |enum_layout| {
                            // Find the variant
                            var variant_index: ?usize = null;
                            var variant_info: ?EnumVariantInfo = null;
                            for (enum_layout.variants, 0..) |v, i| {
                                if (std.mem.eql(u8, v.name, variant_name)) {
                                    variant_index = i;
                                    variant_info = v;
                                    break;
                                }
                            }

                            if (variant_index) |idx| {
                                // Create enum value on stack
                                // Layout: [tag (8 bytes)][data (8 bytes if present)]
                                // Tag is the variant index

                                // Evaluate argument if present
                                if (variant_info.?.data_type != null) {
                                    if (call.args.len > 0) {
                                        try self.generateExpr(call.args[0]);
                                        // Data value is in rax
                                        try self.assembler.pushReg(.rax); // Push data
                                    } else {
                                        // No arg provided but expected - push 0
                                        try self.assembler.movRegImm64(.rax, 0);
                                        try self.assembler.pushReg(.rax);
                                    }
                                } else {
                                    // No data for this variant - push 0 as placeholder
                                    try self.assembler.movRegImm64(.rax, 0);
                                    try self.assembler.pushReg(.rax);
                                }

                                // Push tag (variant index)
                                try self.assembler.movRegImm64(.rax, @intCast(idx));
                                try self.assembler.pushReg(.rax);

                                // Return pointer to the enum value on stack
                                // lea rax, [rsp]
                                try self.assembler.movRegReg(.rax, .rsp);

                                return;
                            }
                        }
                    }

                    // Check for method call: instance.method(args)
                    // The instance becomes the first argument (self)
                    const method_name = member.member;

                    // Try to find struct type from the instance
                    var found_struct_name: ?[]const u8 = null;

                    // Track whether this is an instance method or static method call
                    var is_static_call = false;

                    // First, check if the object is a local variable (including 'self')
                    if (member.object.* == .Identifier) {
                        const obj_name = member.object.Identifier.name;
                        if (self.locals.get(obj_name)) |local_info| {
                            // Trait-object dispatch path: a local typed
                            // `dyn TraitName` is a 16-byte header (data ptr +
                            // vtable ptr). We resolve the method index by
                            // walking the vtable's method_indices map and
                            // emit an indirect call instead of going through
                            // the static-method table.
                            if (local_info.type_name.len > 4 and std.mem.startsWith(u8, local_info.type_name, "dyn ")) {
                                const trait_name = std.mem.trim(u8, local_info.type_name[4..], " ");
                                if (try self.tryEmitVirtualCall(member.object, trait_name, method_name, call.args)) {
                                    return;
                                }
                            }

                            // We have a local variable - check its type
                            if (self.struct_layouts.contains(local_info.type_name)) {
                                // It's a struct type - check if the method exists
                                const mangled_method_name = try self.mangleMethodName(local_info.type_name, method_name);
                                defer self.allocator.free(mangled_method_name);
                                if (self.functions.contains(mangled_method_name)) {
                                    found_struct_name = local_info.type_name;
                                }
                            }
                        } else if (self.struct_layouts.contains(obj_name)) {
                            // Object is a struct type name itself - this is a static method call
                            // e.g., Vec3.zero()
                            const mangled_method_name = try self.mangleMethodName(obj_name, method_name);
                            defer self.allocator.free(mangled_method_name);
                            if (self.functions.contains(mangled_method_name)) {
                                found_struct_name = obj_name;
                                is_static_call = true;
                            }
                        }
                    }

                    // If not found via local variable type, search all struct layouts
                    if (found_struct_name == null) {
                        var iterator = self.struct_layouts.iterator();
                        while (iterator.next()) |entry| {
                            const struct_name = entry.key_ptr.*;
                            const mangled_method_name = try self.mangleMethodName(struct_name, method_name);
                            defer self.allocator.free(mangled_method_name);

                            if (self.functions.contains(mangled_method_name)) {
                                found_struct_name = struct_name;
                                break;
                            }
                        }
                    }

                    if (found_struct_name) |struct_name| {
                        // Found a method - generate method call
                        const mangled_name = try self.mangleMethodName(struct_name, method_name);
                        defer self.allocator.free(mangled_name);

                        if (self.functions.get(mangled_name)) |func_pos| {
                            const arg_regs = [_]x64.Register{ .rdi, .rsi, .rdx, .rcx, .r8, .r9 };

                            if (is_static_call) {
                                // Static method call - no self parameter
                                // Just push the explicit arguments
                                for (call.args) |arg| {
                                    try self.generateExpr(arg);
                                    try self.assembler.pushReg(.rax);
                                }

                                const total_args = call.args.len;
                                const reg_arg_count = @min(total_args, arg_regs.len);

                                // Pop arguments into correct registers (in reverse order)
                                if (reg_arg_count > 0) {
                                    var j: usize = reg_arg_count;
                                    while (j > 0) {
                                        j -= 1;
                                        try self.assembler.popReg(arg_regs[j]);
                                    }
                                }
                            } else {
                                // Instance method call - pass struct by pointer as first argument
                                // Evaluate the object expression - for struct identifiers,
                                // generateExpr already returns a pointer to the struct
                                try self.generateExpr(member.object);
                                try self.assembler.pushReg(.rax);

                                // Push remaining arguments
                                for (call.args) |arg| {
                                    try self.generateExpr(arg);
                                    try self.assembler.pushReg(.rax);
                                }

                                // Total args = 1 (self) + call.args.len
                                const total_args = 1 + call.args.len;
                                const reg_arg_count = @min(total_args, arg_regs.len);

                                // Pop arguments into correct registers (in reverse order)
                                if (reg_arg_count > 0) {
                                    var j: usize = reg_arg_count;
                                    while (j > 0) {
                                        j -= 1;
                                        try self.assembler.popReg(arg_regs[j]);
                                    }
                                }
                            }

                            // Calculate relative offset to function
                            const current_pos = self.assembler.getPosition();
                            const rel_offset = @as(i32, @intCast(func_pos)) - @as(i32, @intCast(current_pos + 5));
                            try self.assembler.callRel32(rel_offset);

                            return;
                        }
                    }

                    // Handle built-in methods like len() on arrays/strings
                    if (std.mem.eql(u8, method_name, "len")) {
                        // array.len() or string.len() - return length
                        // For now, arrays store length at offset 0
                        try self.generateExpr(member.object);
                        // rax now has pointer to array - length is stored at offset 0
                        // For arrays, we store: [length (8 bytes)][capacity (8 bytes)][data pointer (8 bytes)]
                        // Length is at the base address
                        try self.assembler.movRegMem(.rax, .rax, 0);
                        return;
                    }

                    // string.char_at(index) - get character at index
                    if (std.mem.eql(u8, method_name, "char_at")) {
                        if (call.args.len > 0) {
                            // Get index first
                            try self.generateExpr(call.args[0]);
                            try self.assembler.pushReg(.rax); // save index
                            // Get string pointer
                            try self.generateExpr(member.object);
                            try self.assembler.popReg(.rcx); // restore index
                            // rax has string ptr, rcx has index
                            // Add index to pointer: rax = rax + rcx
                            try self.assembler.addRegReg(.rax, .rcx);
                            // Load 8 bytes at [rax] - for strings this loads the char (byte)
                            // The caller is expected to handle single byte if needed
                            try self.assembler.movRegMem(.rax, .rax, 0);
                        } else {
                            try self.assembler.movRegImm64(.rax, 0);
                        }
                        return;
                    }

                    // string.upper() and string.lower() - ASCII case conversion.
                    // Allocates a new heap buffer (via heapAlloc, currently a stack
                    // bump allocator) and copies the string with case applied.
                    if (std.mem.eql(u8, method_name, "upper") or std.mem.eql(u8, method_name, "lower")) {
                        const to_upper = std.mem.eql(u8, method_name, "upper");
                        try self.generateExpr(member.object); // rax = string ptr
                        try self.assembler.pushReg(.rax); // save src

                        // Compute length.
                        try self.assembler.movRegReg(.rdi, .rax);
                        try self.stringLength(.rdi); // rax = len
                        try self.assembler.movRegReg(.r8, .rax); // r8 = len

                        // Allocate len+1 bytes.
                        try self.assembler.movRegReg(.rdi, .rax);
                        try self.assembler.addRegImm(.rdi, 1);
                        try self.heapAlloc(); // rax = dst
                        try self.assembler.movRegReg(.r10, .rax); // r10 = dst

                        // Loop: for i in 0..len { c = src[i]; if cased adjust; dst[i] = c }
                        try self.assembler.popReg(.r11); // r11 = src
                        try self.assembler.xorRegReg(.rcx, .rcx); // rcx = i

                        const loop_start = self.assembler.getPosition();
                        try self.assembler.cmpRegReg(.rcx, .r8);
                        const jeq_done = self.assembler.getPosition();
                        try self.assembler.jeRel32(0);

                        // Load byte: rax = (u64) src[rcx]
                        try self.assembler.movRegReg(.rax, .r11);
                        try self.assembler.addRegReg(.rax, .rcx);
                        try self.assembler.movzxReg64Mem8(.rdx, .rax, 0);

                        // Conditional case adjust. We branch on range:
                        //   upper: if 'a' <= b <= 'z' then b -= 32
                        //   lower: if 'A' <= b <= 'Z' then b += 32
                        const lo: i64 = if (to_upper) 'a' else 'A';
                        const hi: i64 = if (to_upper) 'z' else 'Z';
                        try self.assembler.cmpRegImm(.rdx, @intCast(lo));
                        const jl_skip = self.assembler.getPosition();
                        try self.assembler.jlRel32(0);
                        try self.assembler.cmpRegImm(.rdx, @intCast(hi));
                        const jg_skip = self.assembler.getPosition();
                        try self.assembler.jgRel32(0);
                        if (to_upper) {
                            try self.assembler.subRegImm(.rdx, 32);
                        } else {
                            try self.assembler.addRegImm(.rdx, 32);
                        }
                        const skip_target = self.assembler.getPosition();
                        try self.assembler.patchJlRel32(jl_skip, @as(i32, @intCast(skip_target)) - @as(i32, @intCast(jl_skip + 6)));
                        try self.assembler.patchJgRel32(jg_skip, @as(i32, @intCast(skip_target)) - @as(i32, @intCast(jg_skip + 6)));

                        // Store byte: dst[i] = dl
                        try self.assembler.movRegReg(.rax, .r10);
                        try self.assembler.addRegReg(.rax, .rcx);
                        try self.assembler.movByteMemReg(.rax, 0, .rdx);

                        // i++
                        try self.assembler.addRegImm(.rcx, 1);

                        const back = self.assembler.getPosition();
                        try self.assembler.jmpRel32(@as(i32, @intCast(loop_start)) - @as(i32, @intCast(back + 5)));

                        const done = self.assembler.getPosition();
                        try self.assembler.patchJeRel32(jeq_done, @as(i32, @intCast(done)) - @as(i32, @intCast(jeq_done + 6)));

                        // NUL-terminate at dst[len].
                        try self.assembler.movRegReg(.rax, .r10);
                        try self.assembler.addRegReg(.rax, .r8);
                        try self.assembler.movByteMemImm(.rax, 0, 0);

                        // Result pointer in rax.
                        try self.assembler.movRegReg(.rax, .r10);
                        return;
                    }

                    // string.substring(start, end) or array.slice(start, end)
                    if (std.mem.eql(u8, method_name, "substring") or std.mem.eql(u8, method_name, "slice")) {
                        // Real implementation: copy bytes [start, end) into a fresh
                        // heap buffer and NUL-terminate. start/end clamped at >= 0
                        // by caller; we don't bounds-check yet.
                        if (call.args.len < 2) {
                            try self.generateExpr(member.object);
                            return;
                        }
                        // Evaluate end, then start, then source.
                        try self.generateExpr(call.args[1]);
                        try self.assembler.pushReg(.rax);
                        try self.generateExpr(call.args[0]);
                        try self.assembler.pushReg(.rax);
                        try self.generateExpr(member.object); // rax = src
                        try self.assembler.popReg(.rcx); // rcx = start
                        try self.assembler.popReg(.rdx); // rdx = end

                        // length = end - start
                        try self.assembler.subRegReg(.rdx, .rcx);
                        try self.assembler.movRegReg(.r8, .rdx); // r8 = len

                        // Allocate len + 1
                        try self.assembler.movRegReg(.rdi, .r8);
                        try self.assembler.addRegImm(.rdi, 1);
                        try self.assembler.pushReg(.rax); // save src
                        try self.assembler.pushReg(.rcx); // save start
                        try self.assembler.pushReg(.r8); // save len
                        try self.heapAlloc(); // rax = dst
                        try self.assembler.movRegReg(.r10, .rax);
                        try self.assembler.popReg(.r8);
                        try self.assembler.popReg(.rcx);
                        try self.assembler.popReg(.rax);

                        // memcpy(r10, src + start, len)
                        try self.assembler.addRegReg(.rax, .rcx); // src + start
                        try self.assembler.movRegReg(.rsi, .rax);
                        try self.assembler.movRegReg(.rdi, .r10);
                        try self.assembler.movRegReg(.rdx, .r8);
                        try self.memcpy();

                        // NUL terminate
                        try self.assembler.movRegReg(.rax, .r10);
                        try self.assembler.addRegReg(.rax, .r8);
                        try self.assembler.movByteMemImm(.rax, 0, 0);

                        try self.assembler.movRegReg(.rax, .r10);
                        return;
                    }

                    // arr.push(value) — append to a heap-backed dynamic Array.
                    //
                    // Layout: [len:i64 @ 0][cap:i64 @ 8][elem_0 @ 16][elem_1 @ 24]...
                    //
                    //   rax ← array base pointer
                    //   rcx ← len, rdx ← cap
                    //   if len >= cap: runtime panic (fixed-capacity for now)
                    //   addr = base + 16 + len*8
                    //   [addr] = value
                    //   len += 1; [base] = len
                    if (std.mem.eql(u8, method_name, "push") or std.mem.eql(u8, method_name, "append")) {
                        if (call.args.len == 0) return;

                        // Evaluate value → stash on stack.
                        try self.generateExpr(call.args[0]);
                        try self.assembler.pushReg(.rax);
                        // Evaluate receiver → rax = array header pointer.
                        try self.generateExpr(member.object);
                        try self.assembler.pushReg(.rax); // save header across grow

                        // Load len, cap.
                        try self.assembler.movRegMem(.rcx, .rax, 0); // len
                        try self.assembler.movRegMem(.rdx, .rax, 8); // cap

                        // If len < cap, skip the grow path.
                        try self.assembler.cmpRegReg(.rcx, .rdx);
                        const jl_skip_grow = self.assembler.getPosition();
                        try self.assembler.jlRel32(0);

                        // --- grow path: double cap, allocate new data,
                        //     memcpy old slots over, update header. Clobbers
                        //     a lot so we treat the header slot on the stack
                        //     as the source of truth and reload it.
                        // rax still holds the header (we saved it above).
                        try self.assembler.movRegReg(.r11, .rax); // r11 = header
                        try self.assembler.movRegMem(.rdx, .r11, 8); // rdx = old_cap
                        // new_cap = old_cap * 2 (stored in rdi for the alloc).
                        try self.assembler.movRegReg(.rdi, .rdx);
                        try self.assembler.shlRegImm8(.rdi, 1);
                        // Keep old_cap on the stack so we can compute the
                        // memcpy length after heapAlloc clobbers everything.
                        try self.assembler.pushReg(.rdx); // old_cap
                        // new_size_bytes = new_cap * 8.
                        try self.assembler.shlRegImm8(.rdi, 3);
                        try self.heapAlloc(); // rax = new_data
                        try self.assembler.popReg(.rdx); // rdx = old_cap
                        // Stack is now back to [rsp+0]=header, [rsp+8]=value.
                        try self.assembler.movRegMem(.r11, .rsp, 0); // r11 = header
                        // new_cap = old_cap << 1 into [header+8].
                        try self.assembler.movRegReg(.r8, .rdx);
                        try self.assembler.shlRegImm8(.r8, 1);
                        try self.assembler.movMemReg(.r11, 8, .r8);
                        // old_data = [header+16]; save, then overwrite.
                        try self.assembler.movRegMem(.r9, .r11, 16);
                        try self.assembler.movMemReg(.r11, 16, .rax);
                        // memcpy: rdi = new_data (rax), rsi = old_data (r9),
                        //         rcx = len*8. We only need to copy the
                        //         in-use slots, not the full old capacity.
                        try self.assembler.movRegMem(.rcx, .r11, 0); // len
                        try self.assembler.shlRegImm8(.rcx, 3);
                        try self.assembler.movRegReg(.rdi, .rax);
                        try self.assembler.movRegReg(.rsi, .r9);
                        // rep movsb (F3 A4) — copies rcx bytes from
                        // [rsi] to [rdi], incrementing both.
                        try self.assembler.code.append(self.allocator, 0xF3);
                        try self.assembler.code.append(self.allocator, 0xA4);
                        // Reload len/cap for the happy path below.
                        try self.assembler.movRegMem(.rax, .rsp, 0); // header (top of stack)
                        try self.assembler.movRegMem(.rcx, .rax, 0); // len
                        try self.assembler.movRegMem(.rdx, .rax, 8); // cap

                        // --- happy path: cap has room for one more element ---
                        const grow_skip = self.assembler.getPosition();
                        try self.assembler.patchJlRel32(
                            jl_skip_grow,
                            @as(i32, @intCast(grow_skip)) - @as(i32, @intCast(jl_skip_grow + 6)),
                        );

                        // r11 = data_ptr = [header+16]
                        try self.assembler.popReg(.r11); // r11 = header
                        try self.assembler.movRegMem(.r8, .r11, 16); // r8 = data_ptr
                        // slot_addr = data_ptr + len*8
                        try self.assembler.leaRegMemSib(.r8, .r8, .rcx, .eight, 0);
                        // Pop pushed value into rax, store at [r8].
                        try self.assembler.popReg(.rax);
                        try self.assembler.movMemReg(.r8, 0, .rax);
                        // len += 1
                        try self.assembler.movRegMem(.rcx, .r11, 0);
                        try self.assembler.addRegImm(.rcx, 1);
                        try self.assembler.movMemReg(.r11, 0, .rcx);
                        try self.assembler.movRegReg(.rax, .rcx);
                        return;
                    }

                    // arr.pop() — returns and removes the last element.
                    //   if len == 0: panic
                    //   len -= 1
                    //   return [data_ptr + len*8]
                    if (std.mem.eql(u8, method_name, "pop")) {
                        try self.generateExpr(member.object);
                        try self.assembler.movRegReg(.r11, .rax); // r11 = header
                        try self.assembler.movRegMem(.rcx, .r11, 0); // len

                        // Guard: len > 0.
                        try self.assembler.testRegReg(.rcx, .rcx);
                        const jnz_ok = self.assembler.getPosition();
                        try self.assembler.jnzRel32(0);
                        try self.emitRuntimePanic("array.pop: empty array");
                        const ok_target = self.assembler.getPosition();
                        try self.assembler.patchJnzRel32(jnz_ok, @as(i32, @intCast(ok_target)) - @as(i32, @intCast(jnz_ok + 6)));

                        // len -= 1; [base] = len
                        try self.assembler.subRegImm(.rcx, 1);
                        try self.assembler.movMemReg(.r11, 0, .rcx);

                        // data_ptr = [base+16]; addr = data_ptr + len*8
                        try self.assembler.movRegMem(.r8, .r11, 16);
                        try self.assembler.leaRegMemSib(.r8, .r8, .rcx, .eight, 0);
                        try self.assembler.movRegMem(.rax, .r8, 0);
                        return;
                    }

                    // arr.insert(index, value) — shift right and insert.
                    //   guard: len < cap, 0 <= index <= len
                    //   for i from len..index+1 step -1: slot[i] = slot[i-1]
                    //   slot[index] = value; len += 1
                    if (std.mem.eql(u8, method_name, "insert")) {
                        if (call.args.len < 2) return;

                        // Evaluate value → push.
                        try self.generateExpr(call.args[1]);
                        try self.assembler.pushReg(.rax);
                        // Evaluate index → push.
                        try self.generateExpr(call.args[0]);
                        try self.assembler.pushReg(.rax);
                        // Evaluate receiver → rax = base.
                        try self.generateExpr(member.object);
                        try self.assembler.movRegReg(.r11, .rax); // r11 = base
                        try self.assembler.popReg(.r9);  // r9 = index
                        try self.assembler.popReg(.r10); // r10 = value

                        // Load header.
                        try self.assembler.movRegMem(.rcx, .r11, 0); // len (= old length)
                        try self.assembler.movRegMem(.rdx, .r11, 8); // cap
                        try self.assembler.movRegMem(.r12, .r11, 16); // data_ptr

                        // Bounds checks: len < cap (capacity) and index <=
                        // len. Both use the silent `emitBoundsPanic` helper
                        // so we never introduce the extra string_fixups
                        // that the `emitRuntimePanic` path would add.
                        //
                        // NOTE: the push() path handles growth via a proper
                        // doubling allocator; insert() still bails if a new
                        // element would overflow cap. Callers that need
                        // growth + insert should push() then shuffle.
                        try self.assembler.cmpRegReg(.rcx, .rdx);
                        const jb_cap_ok = self.assembler.getPosition();
                        try self.assembler.jbRel32(0);
                        try self.emitBoundsPanic();
                        const cap_ok = self.assembler.getPosition();
                        try self.assembler.patchJbRel32(
                            jb_cap_ok,
                            @as(i32, @intCast(cap_ok)) - @as(i32, @intCast(jb_cap_ok + 6)),
                        );

                        // index (r9) must be in [0, len]. Treat as unsigned.
                        try self.assembler.cmpRegReg(.r9, .rcx);
                        const jbe_idx_ok = self.assembler.getPosition();
                        try self.assembler.jbeRel32(0);
                        try self.emitBoundsPanic();
                        const idx_ok = self.assembler.getPosition();
                        try self.assembler.patchJbeRel32(
                            jbe_idx_ok,
                            @as(i32, @intCast(idx_ok)) - @as(i32, @intCast(jbe_idx_ok + 6)),
                        );

                        // Shift elements right: for (i = len; i > index; i--) slot[i] = slot[i-1]
                        // Loop counter i in r8 starts at len.
                        try self.assembler.movRegReg(.r8, .rcx);

                        const shift_top = self.assembler.getPosition();
                        try self.assembler.cmpRegReg(.r8, .r9);
                        const jle_done = self.assembler.getPosition();
                        try self.assembler.jleRel32(0);

                        // slot[i] = slot[i-1] (addresses off of data_ptr in r12)
                        try self.assembler.leaRegMemSib(.rax, .r12, .r8, .eight, 0);
                        try self.assembler.movRegMem(.rdx, .rax, -8);
                        try self.assembler.movMemReg(.rax, 0, .rdx);

                        try self.assembler.subRegImm(.r8, 1);
                        const back = self.assembler.getPosition();
                        try self.assembler.jmpRel32(@as(i32, @intCast(shift_top)) - @as(i32, @intCast(back + 5)));

                        const shift_done = self.assembler.getPosition();
                        try self.assembler.patchJleRel32(jle_done, @as(i32, @intCast(shift_done)) - @as(i32, @intCast(jle_done + 6)));

                        // slot[index] = value  (data_ptr + index*8)
                        try self.assembler.leaRegMemSib(.rax, .r12, .r9, .eight, 0);
                        try self.assembler.movMemReg(.rax, 0, .r10);

                        // len += 1; [base] = len
                        try self.assembler.movRegMem(.rcx, .r11, 0);
                        try self.assembler.addRegImm(.rcx, 1);
                        try self.assembler.movMemReg(.r11, 0, .rcx);
                        try self.assembler.movRegReg(.rax, .rcx);
                        return;
                    }

                    // arr.remove(index) — remove and return the element at index.
                    //   value = slot[index]
                    //   for i from index..len-1: slot[i] = slot[i+1]
                    //   len -= 1; return value
                    if (std.mem.eql(u8, method_name, "remove")) {
                        if (call.args.len == 0) return;

                        try self.generateExpr(call.args[0]);
                        try self.assembler.pushReg(.rax);
                        try self.generateExpr(member.object);
                        try self.assembler.movRegReg(.r11, .rax); // r11 = base
                        try self.assembler.popReg(.r9); // r9 = index

                        try self.assembler.movRegMem(.rcx, .r11, 0); // len

                        // Bounds check: index (r9) < len (rcx). Unsigned
                        // compare so negative indices fall in the panic
                        // bucket as well.
                        try self.assembler.cmpRegReg(.r9, .rcx);
                        const jb_ok = self.assembler.getPosition();
                        try self.assembler.jbRel32(0);
                        try self.emitBoundsPanic();
                        const ok_target = self.assembler.getPosition();
                        try self.assembler.patchJbRel32(
                            jb_ok,
                            @as(i32, @intCast(ok_target)) - @as(i32, @intCast(jb_ok + 6)),
                        );

                        // data_ptr = [base+16] (cached in r12 for all addressing)
                        try self.assembler.movRegMem(.r12, .r11, 16);

                        // Save removed value in r10: [data_ptr + index*8]
                        try self.assembler.leaRegMemSib(.rax, .r12, .r9, .eight, 0);
                        try self.assembler.movRegMem(.r10, .rax, 0);

                        // Shift left: for (i = index; i < len - 1; i++) slot[i] = slot[i+1]
                        // Loop counter = r8 = i, starts at index.
                        try self.assembler.movRegReg(.r8, .r9); // i = index
                        // end = len - 1 → rdx
                        try self.assembler.movRegReg(.rdx, .rcx);
                        try self.assembler.subRegImm(.rdx, 1);

                        const shift_top = self.assembler.getPosition();
                        try self.assembler.cmpRegReg(.r8, .rdx);
                        const jge_done = self.assembler.getPosition();
                        try self.assembler.jgeRel32(0);

                        // dst = data_ptr + i*8; src = dst + 8
                        try self.assembler.leaRegMemSib(.rax, .r12, .r8, .eight, 0);
                        try self.assembler.movRegMem(.rcx, .rax, 8);
                        try self.assembler.movMemReg(.rax, 0, .rcx);

                        try self.assembler.addRegImm(.r8, 1);
                        const back = self.assembler.getPosition();
                        try self.assembler.jmpRel32(@as(i32, @intCast(shift_top)) - @as(i32, @intCast(back + 5)));

                        const shift_done = self.assembler.getPosition();
                        try self.assembler.patchJgeRel32(jge_done, @as(i32, @intCast(shift_done)) - @as(i32, @intCast(jge_done + 6)));

                        // len -= 1; [base] = len
                        try self.assembler.movRegMem(.rcx, .r11, 0);
                        try self.assembler.subRegImm(.rcx, 1);
                        try self.assembler.movMemReg(.r11, 0, .rcx);

                        try self.assembler.movRegReg(.rax, .r10);
                        return;
                    }

                    // object.clone() / object.copy() — deep-copy for the
                    // types we know how to clone (dynamic Array, string).
                    // Anything else falls back to identity because we
                    // don't yet have a generic "Copy" trait machinery.
                    if (std.mem.eql(u8, method_name, "clone") or std.mem.eql(u8, method_name, "copy")) {
                        // Decide clone strategy from the static type we can
                        // see at codegen time. If the receiver is a local
                        // of type "Array" we emit an array clone; if we
                        // can prove it's a string (literal or typed local)
                        // we emit a strdup; otherwise identity.
                        var kind: enum { array, string, identity } = .identity;
                        if (member.object.* == .Identifier) {
                            const id = member.object.Identifier;
                            if (self.locals.get(id.name)) |info| {
                                if (std.mem.eql(u8, info.type_name, "Array")) {
                                    kind = .array;
                                } else if (std.mem.eql(u8, info.type_name, "str") or
                                    std.mem.eql(u8, info.type_name, "string"))
                                {
                                    kind = .string;
                                }
                            }
                        } else if (member.object.* == .StringLiteral) {
                            kind = .string;
                        }

                        switch (kind) {
                            .identity => {
                                try self.generateExpr(member.object);
                            },
                            .array => try self.emitArrayClone(member.object),
                            .string => try self.emitStringClone(member.object),
                        }
                        return;
                    }

                    // Default: try to generate as unknown method call but don't error
                    // This allows the game to compile even with unimplemented methods
                }

                // x64 calling convention: rdi, rsi, rdx, rcx, r8, r9 for first 6 args
                if (call.callee.* == .Identifier) {
                    const func_name = call.callee.Identifier.name;

                    // Check if it's a known function
                    if (self.functions.get(func_name)) |func_pos| {
                        // x64 System V ABI: first 6 integer args in registers, rest on stack
                        const arg_regs = [_]x64.Register{ .rdi, .rsi, .rdx, .rcx, .r8, .r9 };

                        // Get function info for default parameter and named argument handling
                        const func_info = self.function_info.get(func_name);
                        const total_params = if (func_info) |info| info.params.len else call.args.len;

                        // Resolve arguments: build an array of expressions for each parameter position
                        // Start with null for each position
                        var resolved_args: [16]?*ast.Expr = .{null} ** 16;

                        // Fill in positional arguments
                        for (call.args, 0..) |arg, idx| {
                            if (idx < resolved_args.len) {
                                resolved_args[idx] = arg;
                            }
                        }

                        // Fill in named arguments by matching parameter names
                        if (func_info) |info| {
                            for (call.named_args) |named_arg| {
                                // Find the parameter index for this named argument
                                for (info.params, 0..) |param, param_idx| {
                                    if (std.mem.eql(u8, param.name, named_arg.name)) {
                                        if (param_idx < resolved_args.len) {
                                            resolved_args[param_idx] = named_arg.value;
                                        }
                                        break;
                                    }
                                }
                            }
                        }

                        const total_args = @max(call.args.len + call.named_args.len, total_params);
                        const reg_arg_count = @min(total_args, arg_regs.len);

                        // Push stack arguments first (args 7+) in reverse order
                        // This is required by System V ABI: caller pushes in reverse
                        if (total_args > arg_regs.len) {
                            var i: usize = total_args;
                            while (i > arg_regs.len) {
                                i -= 1;
                                if (resolved_args[i]) |arg_expr| {
                                    try self.generateExpr(arg_expr);
                                } else if (func_info) |info| {
                                    // Use default value
                                    if (i < info.params.len and info.params[i].default_value != null) {
                                        try self.generateExpr(info.params[i].default_value.?);
                                    } else {
                                        try self.assembler.movRegImm64(.rax, 0);
                                    }
                                } else {
                                    try self.assembler.movRegImm64(.rax, 0);
                                }
                                try self.assembler.pushReg(.rax);
                            }
                        }

                        // Evaluate register arguments and push onto stack first
                        var i: usize = 0;
                        while (i < reg_arg_count) : (i += 1) {
                            if (resolved_args[i]) |arg_expr| {
                                try self.generateExpr(arg_expr);
                            } else if (func_info) |info| {
                                // Use default value
                                if (i < info.params.len and info.params[i].default_value != null) {
                                    try self.generateExpr(info.params[i].default_value.?);
                                } else {
                                    try self.assembler.movRegImm64(.rax, 0);
                                }
                            } else {
                                try self.assembler.movRegImm64(.rax, 0);
                            }
                            try self.assembler.pushReg(.rax);
                        }

                        // Pop arguments into correct registers (in reverse order)
                        if (reg_arg_count > 0) {
                            var j: usize = reg_arg_count;
                            while (j > 0) {
                                j -= 1;
                                try self.assembler.popReg(arg_regs[j]);
                            }
                        }

                        // Calculate relative offset to function
                        const current_pos = self.assembler.getPosition();
                        const rel_offset = @as(i32, @intCast(func_pos)) - @as(i32, @intCast(current_pos + 5));
                        try self.assembler.callRel32(rel_offset);

                        // Clean up stack arguments (args 7+) after the call
                        // Each arg is 8 bytes
                        if (total_args > arg_regs.len) {
                            const stack_args = total_args - arg_regs.len;
                            const stack_bytes: i32 = @intCast(stack_args * 8);
                            try self.assembler.addRegImm(.rsp, stack_bytes);
                        }

                        return;
                    }

                    // Handle built-in functions
                    if (std.mem.eql(u8, func_name, "print") or
                        std.mem.eql(u8, func_name, "println"))
                    {
                        const is_println = std.mem.eql(u8, func_name, "println");
                        if (call.args.len > 0) {
                            try self.generateExpr(call.args[0]);

                            // Convert the value to a printable string.
                            // Strings: rax is already a NUL-terminated pointer.
                            // Integers: convert to decimal string first.
                            const is_str = self.isStringExpr(call.args[0]);
                            if (!is_str) {
                                try self.intToDecimalString();
                            }

                            // Write the NUL-terminated string at rax to stdout.
                            try self.assembler.movRegReg(.rsi, .rax);
                            try self.stringLength(.rsi);
                            try self.assembler.movRegReg(.rdx, .rax);
                            try self.assembler.movRegImm64(.rdi, 1); // stdout
                            const write_syscall: u64 = switch (builtin.os.tag) {
                                .macos => 0x2000004,
                                .linux => 1,
                                else => 1,
                            };
                            try self.assembler.movRegImm64(.rax, write_syscall);
                            try self.assembler.syscall();
                        }
                        if (is_println) {
                            // Write "\n" to stdout.
                            const nl = try self.allocator.dupe(u8, "\n");
                            try self.emitWriteStderrStaticBuf(nl);
                        }
                        return;
                    }

                    // Bit-manipulation intrinsics. Each takes a single
                    // 64-bit integer argument and returns an integer in
                    // rax. LZCNT / TZCNT / POPCNT require their respective
                    // CPUID bits, but modern x64 (Haswell+) has them all.
                    if (std.mem.eql(u8, func_name, "popcount") or
                        std.mem.eql(u8, func_name, "bit_count"))
                    {
                        if (call.args.len != 1) {
                            try self.assembler.movRegImm64(.rax, 0);
                        } else {
                            try self.generateExpr(call.args[0]);
                            try self.assembler.popcntRegReg(.rax, .rax);
                        }
                        return;
                    }
                    if (std.mem.eql(u8, func_name, "leading_zeros") or
                        std.mem.eql(u8, func_name, "clz"))
                    {
                        if (call.args.len != 1) {
                            try self.assembler.movRegImm64(.rax, 0);
                        } else {
                            try self.generateExpr(call.args[0]);
                            try self.assembler.lzcntRegReg(.rax, .rax);
                        }
                        return;
                    }
                    if (std.mem.eql(u8, func_name, "trailing_zeros") or
                        std.mem.eql(u8, func_name, "ctz"))
                    {
                        if (call.args.len != 1) {
                            try self.assembler.movRegImm64(.rax, 0);
                        } else {
                            try self.generateExpr(call.args[0]);
                            try self.assembler.tzcntRegReg(.rax, .rax);
                        }
                        return;
                    }
                    if (std.mem.eql(u8, func_name, "bit_scan_forward") or
                        std.mem.eql(u8, func_name, "bsf"))
                    {
                        if (call.args.len != 1) {
                            try self.assembler.movRegImm64(.rax, 0);
                        } else {
                            try self.generateExpr(call.args[0]);
                            try self.assembler.bsfRegReg(.rax, .rax);
                        }
                        return;
                    }
                    if (std.mem.eql(u8, func_name, "bit_scan_reverse") or
                        std.mem.eql(u8, func_name, "bsr"))
                    {
                        if (call.args.len != 1) {
                            try self.assembler.movRegImm64(.rax, 0);
                        } else {
                            try self.generateExpr(call.args[0]);
                            try self.assembler.bsrRegReg(.rax, .rax);
                        }
                        return;
                    }

                    if (std.mem.eql(u8, func_name, "assert")) {
                        // Assert function: checks condition and exits if false
                        if (call.args.len > 0) {
                            try self.generateExpr(call.args[0]);

                            // Test condition
                            try self.assembler.testRegReg(.rax, .rax);

                            // If true (non-zero), skip exit
                            const jnz_pos = self.assembler.getPosition();
                            try self.assembler.jnzRel32(0);

                            // Condition false - exit with code 1
                            const exit_syscall: u64 = switch (builtin.os.tag) {
                                .macos => 0x2000001,
                                .linux => 60,
                                else => 60,
                            };
                            try self.assembler.movRegImm64(.rax, exit_syscall);
                            try self.assembler.movRegImm64(.rdi, 1); // exit code 1
                            try self.assembler.syscall();

                            // Patch jump to here (continue execution)
                            const assert_end = self.assembler.getPosition();
                            const jnz_offset = @as(i32, @intCast(assert_end)) - @as(i32, @intCast(jnz_pos + 6));
                            try self.assembler.patchJnzRel32(jnz_pos, jnz_offset);
                        }
                        return;
                    }
                }

                // Check for math module functions: math.sqrt, math.sin, math.cos, etc.
                if (call.callee.* == .MemberExpr) {
                    const member = call.callee.MemberExpr;
                    if (member.object.* == .Identifier) {
                        const module_name = member.object.Identifier.name;
                        const func_name = member.member;

                        if (std.mem.eql(u8, module_name, "math")) {
                            // Handle math module functions
                            if (call.args.len >= 1) {
                                try self.generateExpr(call.args[0]);
                            }

                            // Helper pattern for x87 transcendentals: push rax → fld → op → fstp → pop rax.
                            // Input/output travels through rax as a raw 64-bit double bit pattern.
                            if (std.mem.eql(u8, func_name, "sqrt")) {
                                // Single-instruction SSE2 path. xmm0 is caller-save under SysV.
                                try self.assembler.movqXmmReg(.xmm0, .rax);
                                try self.assembler.sqrtsdXmmXmm(.xmm0, .xmm0);
                                try self.assembler.movqRegXmm(.rax, .xmm0);
                                return;
                            } else if (std.mem.eql(u8, func_name, "sin")) {
                                // x87: fld x; fsin; fstp.
                                // fsin is accurate to full double precision for |x| < 2^63.
                                try self.assembler.pushReg(.rax);
                                try self.assembler.fldQwordRsp();
                                try self.assembler.fsin();
                                try self.assembler.fstpQwordRsp();
                                try self.assembler.popReg(.rax);
                                return;
                            } else if (std.mem.eql(u8, func_name, "cos")) {
                                try self.assembler.pushReg(.rax);
                                try self.assembler.fldQwordRsp();
                                try self.assembler.fcos();
                                try self.assembler.fstpQwordRsp();
                                try self.assembler.popReg(.rax);
                                return;
                            } else if (std.mem.eql(u8, func_name, "tan")) {
                                // fptan pushes 1.0 after computing tan, so we must drop it.
                                try self.assembler.pushReg(.rax);
                                try self.assembler.fldQwordRsp();
                                try self.assembler.fptan();
                                try self.assembler.fstpSt0(); // discard the 1.0
                                try self.assembler.fstpQwordRsp();
                                try self.assembler.popReg(.rax);
                                return;
                            } else if (std.mem.eql(u8, func_name, "atan")) {
                                // atan(x) = atan2(x, 1). Load x then 1.0, call fpatan.
                                try self.assembler.pushReg(.rax);
                                try self.assembler.fldQwordRsp();
                                try self.assembler.fld1();
                                try self.assembler.fpatan();
                                try self.assembler.fstpQwordRsp();
                                try self.assembler.popReg(.rax);
                                return;
                            } else if (std.mem.eql(u8, func_name, "asin")) {
                                // asin(x) = atan2(x, sqrt(1 - x*x)).
                                // Use SSE for sqrt of (1 - x*x), then x87 fpatan.
                                // Compute t = sqrt(1 - x*x) into xmm1, keep x in rax.
                                try self.assembler.movqXmmReg(.xmm0, .rax); // xmm0 = x
                                try self.assembler.movqXmmReg(.xmm1, .rax);
                                try self.assembler.mulsdXmmXmm(.xmm1, .xmm1); // xmm1 = x*x
                                // Build 1.0 in xmm2 via rcx = 0x3FF0000000000000
                                try self.assembler.movRegImm64(.rcx, 0x3FF0000000000000);
                                try self.assembler.movqXmmReg(.xmm2, .rcx); // xmm2 = 1.0
                                try self.assembler.subsdXmmXmm(.xmm2, .xmm1); // xmm2 = 1 - x*x
                                try self.assembler.sqrtsdXmmXmm(.xmm2, .xmm2); // xmm2 = sqrt(1 - x*x)
                                // Now push both onto FPU stack: push y first (denominator), then x.
                                // fpatan computes atan2(st(1), st(0)) and pops st(0).
                                // After: st(0)=atan2(x, t). Store from st(0).
                                try self.assembler.movqRegXmm(.rax, .xmm2);
                                try self.assembler.pushReg(.rax);
                                try self.assembler.fldQwordRsp();     // st(0) = t
                                try self.assembler.movqRegXmm(.rax, .xmm0);
                                try self.assembler.movRegMem(.rsp, .rsp, 0); // dead; recompute below
                                // Instead: write x over scratch slot.
                                try self.assembler.movMemReg(.rsp, 0, .rax);
                                try self.assembler.fldQwordRsp();     // st(0) = x, st(1) = t
                                // fpatan: st(1) = atan2(st(1), st(0)); pop st(0).
                                // That gives st(0) = atan2(t, x), which is NOT what we want.
                                // We want atan2(x, t). Swap first.
                                try self.assembler.fxch();            // st(0) = t, st(1) = x
                                try self.assembler.fpatan();          // st(0) = atan2(x, t)
                                try self.assembler.fstpQwordRsp();
                                try self.assembler.popReg(.rax);
                                return;
                            } else if (std.mem.eql(u8, func_name, "acos")) {
                                // acos(x) = atan2(sqrt(1 - x*x), x).
                                try self.assembler.movqXmmReg(.xmm0, .rax);
                                try self.assembler.movqXmmReg(.xmm1, .rax);
                                try self.assembler.mulsdXmmXmm(.xmm1, .xmm1);
                                try self.assembler.movRegImm64(.rcx, 0x3FF0000000000000);
                                try self.assembler.movqXmmReg(.xmm2, .rcx);
                                try self.assembler.subsdXmmXmm(.xmm2, .xmm1);
                                try self.assembler.sqrtsdXmmXmm(.xmm2, .xmm2); // xmm2 = sqrt(1-x*x)
                                // We want atan2(sqrt, x). fpatan computes atan2(st(1), st(0)) then pops.
                                // So load x first (st(0)=x), then sqrt (st(0)=sqrt, st(1)=x).
                                // After fpatan: st(0) = atan2(st(1), st(0)) = atan2(x, sqrt) — wrong.
                                // Swap to get st(0)=x, st(1)=sqrt; fpatan → atan2(sqrt, x).
                                try self.assembler.pushReg(.rax);     // x
                                try self.assembler.fldQwordRsp();     // st(0) = x
                                try self.assembler.movqRegXmm(.rax, .xmm2);
                                try self.assembler.movMemReg(.rsp, 0, .rax);
                                try self.assembler.fldQwordRsp();     // st(0) = sqrt, st(1) = x
                                try self.assembler.fxch();            // st(0) = x, st(1) = sqrt
                                try self.assembler.fpatan();          // st(0) = atan2(sqrt, x)
                                try self.assembler.fstpQwordRsp();
                                try self.assembler.popReg(.rax);
                                return;
                            } else if (std.mem.eql(u8, func_name, "atan2")) {
                                // atan2(y, x): first arg y already loaded in rax; load x separately.
                                // The first arg was evaluated above (into rax); we need to also evaluate args[1].
                                // Save y; evaluate x; stack layout [rsp]=y, [rsp+8] unused → use 16 bytes.
                                try self.assembler.pushReg(.rax);     // [rsp]=y
                                if (call.args.len >= 2) {
                                    try self.generateExpr(call.args[1]);
                                } else {
                                    try self.assembler.movRegImm64(.rax, 0x3FF0000000000000); // default x=1
                                }
                                try self.assembler.pushReg(.rax);     // [rsp]=x, [rsp+8]=y
                                try self.assembler.fldQwordRsp();     // st(0) = x
                                // Load y from [rsp+8]: need fld qword ptr [rsp+8] — use temporary reg.
                                try self.assembler.movRegMem(.rax, .rsp, 8);
                                try self.assembler.movMemReg(.rsp, 0, .rax); // overwrite x slot with y
                                try self.assembler.fldQwordRsp();     // st(0)=y, st(1)=x
                                try self.assembler.fpatan();          // st(0) = atan2(y, x)
                                try self.assembler.fstpQwordRsp();    // result → [rsp]
                                try self.assembler.popReg(.rax);      // rax = result
                                try self.assembler.popReg(.rcx);      // drop extra slot
                                return;
                            } else if (std.mem.eql(u8, func_name, "sinh")) {
                                // sinh(x) = (e^x - e^-x) / 2.
                                // Compute via two exp() calls.
                                // Stash x, compute exp(x), stash, recompute -x, exp, subtract, divide.
                                // Simpler: use (exp(2x) - 1) / (2*exp(x)).
                                // We'll emit: e = exp(x); 1/e = 1.0 / e; (e - 1/e) * 0.5.
                                try self.emitFpuExp(); // rax = exp(x)
                                try self.assembler.pushReg(.rax);     // save exp(x)
                                // Compute 1/exp(x) = exp(-x). We already have exp(x); just divide 1 by it.
                                try self.assembler.movqXmmReg(.xmm0, .rax);
                                try self.assembler.movRegImm64(.rcx, 0x3FF0000000000000);
                                try self.assembler.movqXmmReg(.xmm1, .rcx);
                                try self.assembler.divsdXmmXmm(.xmm1, .xmm0); // xmm1 = 1/exp(x)
                                try self.assembler.popReg(.rax);      // exp(x)
                                try self.assembler.movqXmmReg(.xmm0, .rax);
                                try self.assembler.subsdXmmXmm(.xmm0, .xmm1); // exp(x) - exp(-x)
                                try self.assembler.movRegImm64(.rcx, 0x3FE0000000000000); // 0.5
                                try self.assembler.movqXmmReg(.xmm1, .rcx);
                                try self.assembler.mulsdXmmXmm(.xmm0, .xmm1);
                                try self.assembler.movqRegXmm(.rax, .xmm0);
                                return;
                            } else if (std.mem.eql(u8, func_name, "cosh")) {
                                // cosh(x) = (e^x + e^-x) / 2.
                                try self.emitFpuExp();
                                try self.assembler.pushReg(.rax);
                                try self.assembler.movqXmmReg(.xmm0, .rax);
                                try self.assembler.movRegImm64(.rcx, 0x3FF0000000000000);
                                try self.assembler.movqXmmReg(.xmm1, .rcx);
                                try self.assembler.divsdXmmXmm(.xmm1, .xmm0); // 1/exp(x)
                                try self.assembler.popReg(.rax);
                                try self.assembler.movqXmmReg(.xmm0, .rax);
                                try self.assembler.addsdXmmXmm(.xmm0, .xmm1); // exp(x) + exp(-x)
                                try self.assembler.movRegImm64(.rcx, 0x3FE0000000000000);
                                try self.assembler.movqXmmReg(.xmm1, .rcx);
                                try self.assembler.mulsdXmmXmm(.xmm0, .xmm1);
                                try self.assembler.movqRegXmm(.rax, .xmm0);
                                return;
                            } else if (std.mem.eql(u8, func_name, "tanh")) {
                                // tanh(x) = (e^(2x) - 1) / (e^(2x) + 1).
                                // First double x, then exp, then compute.
                                try self.assembler.movqXmmReg(.xmm0, .rax);
                                try self.assembler.addsdXmmXmm(.xmm0, .xmm0); // 2x
                                try self.assembler.movqRegXmm(.rax, .xmm0);
                                try self.emitFpuExp(); // rax = e^(2x)
                                try self.assembler.movqXmmReg(.xmm0, .rax);
                                try self.assembler.movRegImm64(.rcx, 0x3FF0000000000000);
                                try self.assembler.movqXmmReg(.xmm1, .rcx);
                                try self.assembler.movqXmmReg(.xmm2, .rcx);
                                try self.assembler.subsdXmmXmm(.xmm1, .xmm0); // 1 - e^2x … wait wrong order
                                // Reorder: xmm3 = e^2x - 1, xmm4 = e^2x + 1
                                try self.assembler.movqXmmReg(.xmm3, .rax);
                                try self.assembler.subsdXmmXmm(.xmm3, .xmm2); // e^2x - 1
                                try self.assembler.movqXmmReg(.xmm4, .rax);
                                try self.assembler.addsdXmmXmm(.xmm4, .xmm2); // e^2x + 1
                                try self.assembler.divsdXmmXmm(.xmm3, .xmm4);
                                try self.assembler.movqRegXmm(.rax, .xmm3);
                                return;
                            } else if (std.mem.eql(u8, func_name, "exp")) {
                                try self.emitFpuExp();
                                return;
                            } else if (std.mem.eql(u8, func_name, "ln") or std.mem.eql(u8, func_name, "log")) {
                                // ln(x) = ln(2) * log2(x). fyl2x computes st(1) * log2(st(0)).
                                // Load ln(2) as y, then x, then fyl2x.
                                try self.assembler.pushReg(.rax);
                                try self.assembler.fldln2();           // st(0) = ln(2)
                                try self.assembler.fldQwordRsp();      // st(0) = x, st(1) = ln(2)
                                try self.assembler.fyl2x();            // st(0) = ln(2)*log2(x) = ln(x)
                                try self.assembler.fstpQwordRsp();
                                try self.assembler.popReg(.rax);
                                return;
                            } else if (std.mem.eql(u8, func_name, "log10")) {
                                // log10(x) = log10(2) * log2(x).
                                try self.assembler.pushReg(.rax);
                                try self.assembler.fldlg2();           // st(0) = log10(2)
                                try self.assembler.fldQwordRsp();      // st(0) = x, st(1) = log10(2)
                                try self.assembler.fyl2x();            // st(0) = log10(x)
                                try self.assembler.fstpQwordRsp();
                                try self.assembler.popReg(.rax);
                                return;
                            } else if (std.mem.eql(u8, func_name, "log2")) {
                                // log2(x) = 1 * log2(x).
                                try self.assembler.pushReg(.rax);
                                try self.assembler.fld1();             // st(0) = 1
                                try self.assembler.fldQwordRsp();      // st(0) = x, st(1) = 1
                                try self.assembler.fyl2x();            // st(0) = log2(x)
                                try self.assembler.fstpQwordRsp();
                                try self.assembler.popReg(.rax);
                                return;
                            } else if (std.mem.eql(u8, func_name, "pow")) {
                                // pow(x, y) = 2^(y * log2(x)).
                                // First arg x already in rax; evaluate y, then compute.
                                try self.assembler.pushReg(.rax);      // [rsp] = x
                                if (call.args.len >= 2) {
                                    try self.generateExpr(call.args[1]);
                                } else {
                                    try self.assembler.movRegImm64(.rax, 0x3FF0000000000000); // y=1
                                }
                                try self.assembler.pushReg(.rax);      // [rsp]=y, [rsp+8]=x
                                // Load y as fyl2x's "y" factor, then x.
                                try self.assembler.fldQwordRsp();      // st(0) = y
                                try self.assembler.movRegMem(.rax, .rsp, 8);
                                try self.assembler.movMemReg(.rsp, 0, .rax);
                                try self.assembler.fldQwordRsp();      // st(0) = x, st(1) = y
                                try self.assembler.fyl2x();            // st(0) = y*log2(x)
                                // Now compute 2^st(0). Use frndint + f2xm1 + fscale trick.
                                // st(0) is z = y*log2(x). We want 2^z.
                                //   Split z = i + f where i = round(z), |f| ≤ 0.5.
                                //   2^z = 2^i * 2^f = 2^i * (1 + (2^f - 1)).
                                try self.assembler.fld1();             // st(0)=1, st(1)=z
                                try self.assembler.fstpSt0();          // pop 1 — we used it to duplicate stack
                                // Duplicate approach: fld st(0). But our assembler doesn't have fld st(i).
                                // Alternative: use fscale with a copy of integer part.
                                // Emit: fld st(0) via DD C0 (fld st(0) = D9 C0). Add it now inline.
                                try self.emitRawBytes(&[_]u8{ 0xD9, 0xC0 }); // fld st(0) — duplicates z
                                try self.assembler.frndint();          // st(0) = round(z), st(1) = z
                                // Compute f = z - round(z): fsub st(1), st(0)? Simpler: fxch; fsub st(0), st(1)
                                try self.emitRawBytes(&[_]u8{ 0xDC, 0xE9 }); // fsub st(1), st(0): st(1)-=st(0)
                                // Now st(0)=i, st(1)=f.
                                try self.assembler.fxch();             // st(0)=f, st(1)=i
                                try self.assembler.f2xm1();            // st(0) = 2^f - 1
                                try self.assembler.fld1();             // st(0)=1, st(1)=2^f-1, st(2)=i
                                // Add: st(1) += st(0) → 2^f. Then pop top.
                                try self.emitRawBytes(&[_]u8{ 0xDE, 0xC1 }); // faddp st(1), st(0)
                                // Stack: st(0)=2^f, st(1)=i.
                                try self.assembler.fscale();           // st(0) = 2^f * 2^i = 2^z
                                // Drop i from stack.
                                try self.assembler.fstpSt1();          // stores st(0) to st(1) and pops → st(0)=result
                                try self.assembler.fstpQwordRsp();     // result → [rsp]
                                try self.assembler.popReg(.rax);       // rax = result
                                try self.assembler.popReg(.rcx);       // drop extra slot
                                return;
                            } else if (std.mem.eql(u8, func_name, "floor")) {
                                // SSE4.1 roundsd with mode 1 (toward -inf).
                                try self.assembler.movqXmmReg(.xmm0, .rax);
                                try self.assembler.roundsdXmmXmm(.xmm0, .xmm0, 1);
                                try self.assembler.movqRegXmm(.rax, .xmm0);
                                return;
                            } else if (std.mem.eql(u8, func_name, "ceil")) {
                                try self.assembler.movqXmmReg(.xmm0, .rax);
                                try self.assembler.roundsdXmmXmm(.xmm0, .xmm0, 2);
                                try self.assembler.movqRegXmm(.rax, .xmm0);
                                return;
                            } else if (std.mem.eql(u8, func_name, "round")) {
                                try self.assembler.movqXmmReg(.xmm0, .rax);
                                try self.assembler.roundsdXmmXmm(.xmm0, .xmm0, 0);
                                try self.assembler.movqRegXmm(.rax, .xmm0);
                                return;
                            } else if (std.mem.eql(u8, func_name, "trunc")) {
                                try self.assembler.movqXmmReg(.xmm0, .rax);
                                try self.assembler.roundsdXmmXmm(.xmm0, .xmm0, 3);
                                try self.assembler.movqRegXmm(.rax, .xmm0);
                                return;
                            } else if (std.mem.eql(u8, func_name, "fmod")) {
                                // fmod(x, y) = x - trunc(x/y)*y.
                                // Both args needed; first already in rax (x); evaluate y next.
                                try self.assembler.pushReg(.rax);      // save x
                                if (call.args.len >= 2) {
                                    try self.generateExpr(call.args[1]);
                                }
                                try self.assembler.movqXmmReg(.xmm1, .rax); // xmm1 = y
                                try self.assembler.popReg(.rax);
                                try self.assembler.movqXmmReg(.xmm0, .rax); // xmm0 = x
                                try self.assembler.movqXmmReg(.xmm2, .rax); // xmm2 = x (saved)
                                try self.assembler.divsdXmmXmm(.xmm0, .xmm1); // x/y
                                try self.assembler.roundsdXmmXmm(.xmm0, .xmm0, 3); // trunc
                                try self.assembler.mulsdXmmXmm(.xmm0, .xmm1); // trunc(x/y)*y
                                try self.assembler.subsdXmmXmm(.xmm2, .xmm0); // x - ...
                                try self.assembler.movqRegXmm(.rax, .xmm2);
                                return;
                            } else if (std.mem.eql(u8, func_name, "copysign")) {
                                // copysign(x, y): magnitude of x, sign of y.
                                // Use bit manipulation on rax.
                                // First arg x in rax; evaluate y; combine.
                                try self.assembler.pushReg(.rax);      // save x
                                if (call.args.len >= 2) {
                                    try self.generateExpr(call.args[1]);
                                }
                                // rax = y. Extract sign bit: y & 0x8000000000000000.
                                try self.assembler.movRegImm64(.rcx, @bitCast(@as(u64, 0x8000000000000000)));
                                try self.assembler.andRegReg(.rax, .rcx); // rax = sign(y) bit
                                try self.assembler.popReg(.rdx);       // rdx = x
                                // Clear sign of x: rdx & 0x7FFFFFFFFFFFFFFF.
                                try self.assembler.movRegImm64(.rcx, 0x7FFFFFFFFFFFFFFF);
                                try self.assembler.andRegReg(.rdx, .rcx);
                                // Combine: rax = sign(y) | |x|
                                try self.assembler.orRegReg(.rax, .rdx);
                                return;
                            } else if (std.mem.eql(u8, func_name, "abs")) {
                                // abs: absolute value
                                // test rax, rax; jns .skip; neg rax; .skip:
                                try self.assembler.testRegReg(.rax, .rax);
                                const jns_pos = self.assembler.getPosition();
                                try self.assembler.jnsRel32(0); // Jump if not sign (positive)
                                try self.assembler.negReg(.rax);
                                const skip_pos = self.assembler.getPosition();
                                const jns_offset = @as(i32, @intCast(skip_pos)) - @as(i32, @intCast(jns_pos + 6));
                                try self.assembler.patchJnsRel32(jns_pos, jns_offset);
                                return;
                            } else if (std.mem.eql(u8, func_name, "is_finite")) {
                                // is_finite: For integer values, always return true (finite)
                                // Full implementation would require SSE instructions for float checking
                                // For now, assume all integer values are finite
                                try self.assembler.movRegImm64(.rax, 1);
                                return;
                            } else if (std.mem.eql(u8, func_name, "min")) {
                                // min(a, b): return a if a < b else b
                                if (call.args.len >= 2) {
                                    try self.generateExpr(call.args[1]);
                                    try self.assembler.pushReg(.rax);
                                    try self.generateExpr(call.args[0]);
                                    try self.assembler.popReg(.rcx);
                                    // Compare and select minimum
                                    try self.assembler.cmpRegReg(.rax, .rcx);
                                    const cmov_pos = self.assembler.getPosition();
                                    try self.assembler.jlRel32(0); // Jump if rax < rcx
                                    try self.assembler.movRegReg(.rax, .rcx); // rax = rcx (larger)
                                    const skip_pos = self.assembler.getPosition();
                                    const jl_offset = @as(i32, @intCast(skip_pos)) - @as(i32, @intCast(cmov_pos + 6));
                                    try self.assembler.patchJlRel32(cmov_pos, jl_offset);
                                }
                                return;
                            } else if (std.mem.eql(u8, func_name, "max")) {
                                // max(a, b): return a if a > b else b
                                if (call.args.len >= 2) {
                                    try self.generateExpr(call.args[1]);
                                    try self.assembler.pushReg(.rax);
                                    try self.generateExpr(call.args[0]);
                                    try self.assembler.popReg(.rcx);
                                    // Compare and select maximum
                                    try self.assembler.cmpRegReg(.rax, .rcx);
                                    const cmov_pos = self.assembler.getPosition();
                                    try self.assembler.jgRel32(0); // Jump if rax > rcx
                                    try self.assembler.movRegReg(.rax, .rcx); // rax = rcx (smaller)
                                    const skip_pos = self.assembler.getPosition();
                                    const jg_offset = @as(i32, @intCast(skip_pos)) - @as(i32, @intCast(cmov_pos + 6));
                                    try self.assembler.patchJgRel32(cmov_pos, jg_offset);
                                }
                                return;
                            }
                        }
                    }
                }

                // Unknown function: produce a real diagnostic instead of silently
                // returning 0. Silent fallbacks turn missing-symbol bugs into
                // miscompilations, which is worse than a hard error.
                const callee_name: []const u8 = blk: {
                    if (call.callee.* == .Identifier) {
                        break :blk call.callee.Identifier.name;
                    }
                    if (call.callee.* == .MemberExpr) {
                        break :blk call.callee.MemberExpr.member;
                    }
                    break :blk "<unknown>";
                };
                std.debug.print(
                    "codegen error: call to undefined function '{s}'\n",
                    .{callee_name},
                );
                return error.UnsupportedFeature;
            },
            .TernaryExpr => |ternary| {
                // Ternary: condition ? true_val : false_val
                // Evaluate condition
                try self.generateExpr(ternary.condition);

                // Test rax (condition result)
                try self.assembler.testRegReg(.rax, .rax);

                // Jump if zero (false) to false branch
                const jz_pos = self.assembler.getPosition();
                try self.assembler.jzRel32(0); // Placeholder

                // Generate true branch
                try self.generateExpr(ternary.true_val);

                // Jump over false branch
                const jmp_pos = self.assembler.getPosition();
                try self.assembler.jmpRel32(0); // Placeholder

                // Patch jz to point to false branch
                const false_start = self.assembler.getPosition();
                const jz_offset = @as(i32, @intCast(false_start)) - @as(i32, @intCast(jz_pos + 6));
                try self.assembler.patchJzRel32(jz_pos, jz_offset);

                // Generate false branch
                try self.generateExpr(ternary.false_val);

                // Patch jmp to point after false branch
                const ternary_end = self.assembler.getPosition();
                const jmp_offset = @as(i32, @intCast(ternary_end)) - @as(i32, @intCast(jmp_pos + 5));
                try self.assembler.patchJmpRel32(jmp_pos, jmp_offset);
            },
            .NullCoalesceExpr => |null_coalesce| {
                // Null coalesce: left ?? right (0 == null)
                try self.generateExpr(null_coalesce.left);
                try self.assembler.testRegReg(.rax, .rax);
                const jnz_pos = self.assembler.getPosition();
                try self.assembler.jnzRel32(0);
                try self.generateExpr(null_coalesce.right);
                const coalesce_end = self.assembler.getPosition();
                try self.assembler.patchJnzRel32(jnz_pos, @as(i32, @intCast(coalesce_end)) - @as(i32, @intCast(jnz_pos + 6)));
            },
            .ElvisExpr => |elvis| {
                // Elvis: left ?: right — identical to null-coalesce
                try self.generateExpr(elvis.left);
                try self.assembler.testRegReg(.rax, .rax);
                const jnz_pos = self.assembler.getPosition();
                try self.assembler.jnzRel32(0);
                try self.generateExpr(elvis.right);
                const elvis_end = self.assembler.getPosition();
                try self.assembler.patchJnzRel32(jnz_pos, @as(i32, @intCast(elvis_end)) - @as(i32, @intCast(jnz_pos + 6)));
            },
            .MapLiteral => {
                // Map literals need a runtime hashmap allocation.
                // For now, emit 0 (null map). The interpreter handles
                // maps fully; the native codegen path will be extended
                // when the runtime supports heap-allocated hashmaps.
                std.debug.print("Warning: map literals not yet supported in native codegen — returning null\n", .{});
                try self.assembler.movRegImm64(.rax, 0);
            },
            .PipeExpr => |pipe| {
                // Pipe: value |> function
                // Save the piped value on the stack across the right-side
                // evaluation so it survives register clobbers.
                try self.generateExpr(pipe.left);
                try self.assembler.pushReg(.rax);

                if (pipe.right.* == .CallExpr) {
                    // Resolve the callee function. generateExpr for
                    // CallExpr already handles argument passing; we
                    // need to inject our piped value as the first arg.
                    // For now, pop the value into rdi after resolving.
                    try self.generateExpr(pipe.right);
                } else if (pipe.right.* == .Identifier) {
                    // Bare function name: pop value into rdi and call.
                    try self.assembler.popReg(.rdi);
                    try self.generateExpr(pipe.right);
                    // At this point rax = function result
                    return;
                } else {
                    std.debug.print("Pipe operator requires function on right side\n", .{});
                    try self.assembler.popReg(.rax); // balance stack
                    return error.UnsupportedFeature;
                }
                // Clean the stacked value if CallExpr already consumed args.
                try self.assembler.addRegImm(.rsp, 8);
            },
            .SafeNavExpr => |safe_nav| {
                // Safe navigation: object?.member
                // Evaluate object, check for null, then access via struct layout.
                try self.generateExpr(safe_nav.object);
                try self.assembler.movRegReg(.rbx, .rax);

                try self.assembler.testRegReg(.rbx, .rbx);
                const jz_pos = self.assembler.getPosition();
                try self.assembler.jzRel32(0);

                // Look up the actual field offset from struct layouts
                // instead of the naive char-sum hash that collides.
                const member_name = safe_nav.member;
                var field_offset: i32 = 0;
                if (safe_nav.object.* == .Identifier) {
                    const id = safe_nav.object.Identifier;
                    if (self.locals.get(id.name)) |info| {
                        if (self.struct_layouts.get(info.type_name)) |layout| {
                            for (layout.fields) |f| {
                                if (std.mem.eql(u8, f.name, member_name)) {
                                    field_offset = @intCast(f.offset);
                                    break;
                                }
                            }
                        }
                    }
                }

                try self.assembler.movRegMem(.rax, .rbx, field_offset);

                // Jump over null return
                const jmp_pos = self.assembler.getPosition();
                try self.assembler.jmpRel32(0);

                // Null path: return 0 in rax
                const null_path = self.assembler.getPosition();
                const jz_offset = @as(i32, @intCast(null_path)) - @as(i32, @intCast(jz_pos + 6));
                try self.assembler.patchJzRel32(jz_pos, jz_offset);

                try self.assembler.xorRegReg(.rax, .rax); // rax = 0 (null)

                // End of safe nav
                const safe_nav_end = self.assembler.getPosition();
                const jmp_offset = @as(i32, @intCast(safe_nav_end)) - @as(i32, @intCast(jmp_pos + 5));
                try self.assembler.patchJmpRel32(jmp_pos, jmp_offset);
            },
            .SpreadExpr => |spread| {
                // Spread: ...array — unpack elements onto the stack.
                try self.generateExpr(spread.operand);
                try self.assembler.movRegReg(.rbx, .rax);

                // Save original length in r12 before modifying rbx.
                try self.assembler.movRegMem(.r12, .rbx, 0); // r12 = len
                try self.assembler.movRegReg(.rcx, .r12);

                // Advance rbx past the length header to element[0].
                try self.assembler.addRegImm(.rbx, 8);

                const loop_start = self.assembler.getPosition();
                try self.assembler.testRegReg(.rcx, .rcx);
                const jz_loop_end = self.assembler.getPosition();
                try self.assembler.jzRel32(0);

                try self.assembler.movRegMem(.rax, .rbx, 0);
                try self.assembler.pushReg(.rax);
                try self.assembler.addRegImm(.rbx, 8);
                try self.assembler.subRegImm(.rcx, 1);

                const current_pos = self.assembler.getPosition();
                try self.assembler.jmpRel32(@as(i32, @intCast(loop_start)) - @as(i32, @intCast(current_pos + 5)));

                const loop_end = self.assembler.getPosition();
                try self.assembler.patchJzRel32(jz_loop_end, @as(i32, @intCast(loop_end)) - @as(i32, @intCast(jz_loop_end + 6)));

                // Return the element count in rax (was saved in r12).
                try self.assembler.movRegReg(.rax, .r12);
            },
            .TupleExpr => |tuple| {
                // Tuple: (a, b, c)
                // Full implementation with stack-based allocation
                //
                // Tuple memory layout:
                // [0-7]: element count (usize)
                // [8-15]: element 0 (8 bytes)
                // [16-23]: element 1 (8 bytes)
                // ...

                const element_count = tuple.elements.len;

                // Stack grows downward, so we push in reverse order:
                // 1. Push elements (last to first)
                // 2. Push count
                // 3. Return stack pointer as tuple address

                // Push elements in reverse order
                var i: usize = element_count;
                while (i > 0) {
                    i -= 1;
                    try self.generateExpr(tuple.elements[i]);
                    try self.assembler.pushReg(.rax);
                }

                // Push element count as first field
                try self.assembler.movRegImm64(.rax, @intCast(element_count));
                try self.assembler.pushReg(.rax);

                // Return pointer to tuple start (current rsp)
                try self.assembler.movRegReg(.rax, .rsp);
            },
            .AwaitExpr => |await_expr| {
                // Await expression: await future_expr
                //
                // Two semantics depending on context:
                //
                // 1. INSIDE an async fn body (self.async_ctx != null):
                //    Real cooperative suspension. We evaluate the operand
                //    (which produces a Future*), then call emitAwaitSuspend
                //    to:
                //      - save the inner future on our state
                //      - bump our resume_pt
                //      - return Pending so the executor re-polls us
                //      - on resume, poll the inner future, check ready,
                //        and either re-suspend or load the result.
                //
                // 2. OUTSIDE an async fn (sync context, e.g. main):
                //    Eager block-on. We evaluate the operand and then call
                //    emitBlockOn which spins polling the future until it
                //    reports Ready, then loads the result. This bridges
                //    async results back into sync code without giving up
                //    the strict semantics that `await` returns the value.
                try self.generateExpr(await_expr.expression);
                if (self.async_ctx) |ctx| {
                    try self.emitAwaitSuspend(ctx);
                } else {
                    try self.emitBlockOn();
                }
            },

            .ComptimeExpr => |comptime_expr| {
                // Comptime expression: evaluated at compile time
                // Look up the precomputed value from semantic analysis
                if (self.comptime_store) |store| {
                    if (store.get(comptime_expr.expression)) |value| {
                        // Generate code for the precomputed constant value
                        switch (value) {
                            .int => |int_val| {
                                // Load integer constant
                                try self.assembler.movRegImm64(.rax, @intCast(int_val));
                            },
                            .float => |float_val| {
                                // For float constants, we need to load from memory
                                // Store in data section and load address
                                const int_bits: u64 = @bitCast(float_val);
                                try self.assembler.movRegImm64(.rax, @bitCast(int_bits));
                            },
                            .bool => |bool_val| {
                                // Load boolean constant (0 or 1)
                                try self.assembler.movRegImm64(.rax, if (bool_val) 1 else 0);
                            },
                            .string => |str_val| {
                                // String constants need to be in data section
                                // Register the string literal in the data section
                                const str_offset = try self.registerStringLiteral(str_val);

                                // Load the address of the string using LEA with RIP-relative addressing
                                const lea_pos = try self.assembler.leaRipRel(.rax, 0);

                                // Track this fixup for later patching
                                try self.string_fixups.append(self.allocator, .{
                                    .code_pos = lea_pos,
                                    .data_offset = str_offset,
                                });
                            },
                            .array => |arr_elements| {
                                // Optimized: Generate array literal directly in data section
                                if (arr_elements.len > 0) {
                                    const arr_offset = try self.registerArrayLiteral(arr_elements);

                                    // Load the address of the array using LEA with RIP-relative addressing
                                    const lea_pos = try self.assembler.leaRipRel(.rax, 0);

                                    // Track this fixup for later patching
                                    try self.string_fixups.append(self.allocator, .{
                                        .code_pos = lea_pos,
                                        .data_offset = arr_offset,
                                    });
                                } else {
                                    // Empty array - load null pointer
                                    try self.assembler.movRegImm64(.rax, 0);
                                }
                            },
                            .@"struct" => |struct_val| {
                                // Optimized: Generate struct literal directly in data section
                                if (struct_val.fields.count() > 0) {
                                    const struct_offset = try self.registerStructLiteral(&struct_val.fields);

                                    // Load the address of the struct using LEA with RIP-relative addressing
                                    const lea_pos = try self.assembler.leaRipRel(.rax, 0);

                                    // Track this fixup for later patching
                                    try self.string_fixups.append(self.allocator, .{
                                        .code_pos = lea_pos,
                                        .data_offset = struct_offset,
                                    });
                                } else {
                                    // Empty struct - load null pointer
                                    try self.assembler.movRegImm64(.rax, 0);
                                }
                            },
                            .function => {
                                // Function values in comptime context
                                try self.generateExpr(comptime_expr.expression);
                            },
                            .type_info => {
                                // Type values - these are compile-time only, should not generate runtime code
                                // This is likely an error, but we'll generate 0 as a placeholder
                                try self.assembler.movRegImm64(.rax, 0);
                            },
                            .@"null" => {
                                // Null value
                                try self.assembler.movRegImm64(.rax, 0);
                            },
                            .@"undefined" => {
                                // Undefined value - generate 0 as placeholder
                                try self.assembler.movRegImm64(.rax, 0);
                            },
                        }
                        return;
                    }
                }

                // Fallback: if no precomputed value found, evaluate the expression normally
                try self.generateExpr(comptime_expr.expression);
            },

            .ReflectExpr => |reflect_expr| {
                // Handle builtin functions
                switch (reflect_expr.kind) {
                    .SizeOf => {
                        // @sizeOf(Type) — returns the size in bytes of a
                        // type. We walk a handful of expression shapes the
                        // parser can produce:
                        //   - Identifier: plain type name (`int`, `MyStruct`).
                        //   - MemberExpr: module-qualified (`mod.Type`).
                        //   - Non-type expression (rare): resolve via
                        //     inferExprType, which walks locals and literals.
                        // Unknown types now produce a hard error instead of
                        // silently returning 8, which previously masked
                        // typos and missing imports.
                        const resolved_name: ?[]const u8 = switch (reflect_expr.target.*) {
                            .Identifier => |id| id.name,
                            .MemberExpr => |m| blk: {
                                // For `mod.Type`, use the member name.
                                break :blk m.member;
                            },
                            else => try self.inferExprType(reflect_expr.target),
                        };

                        if (resolved_name) |tn| {
                            const size = self.getTypeSize(tn) catch {
                                std.debug.print(
                                    "codegen error: @sizeOf(): unknown type '{s}'\n",
                                    .{tn},
                                );
                                return error.UnsupportedFeature;
                            };
                            try self.assembler.movRegImm64(.rax, @intCast(size));
                        } else {
                            std.debug.print(
                                "codegen error: @sizeOf() target is not a type name\n",
                                .{},
                            );
                            return error.UnsupportedFeature;
                        }
                    },
                    .AlignOf => {
                        // @alignOf(Type) — returns the natural alignment.
                        // Every type in this codegen is 8-byte aligned
                        // (stack slots, struct fields, and Array elements
                        // all use 8-byte slots), so alignment tracks size
                        // for primitives and defaults to 8 otherwise.
                        const name: ?[]const u8 = if (reflect_expr.target.* == .Identifier)
                            reflect_expr.target.Identifier.name
                        else
                            null;
                        var alignment: usize = 8;
                        if (name) |n| {
                            const sz = self.getTypeSize(n) catch 8;
                            alignment = if (sz >= 8) 8 else sz;
                        }
                        try self.assembler.movRegImm64(.rax, @intCast(alignment));
                    },
                    .OffsetOf => {
                        // @offsetOf(Type, "field") — field offset in bytes.
                        // We look up the struct layout and find the named
                        // field's byte offset. Unknown type or field is a
                        // hard error instead of silently returning 0.
                        if (reflect_expr.target.* != .Identifier) {
                            std.debug.print(
                                "codegen error: @offsetOf first arg must be a struct type name\n",
                                .{},
                            );
                            return error.UnsupportedFeature;
                        }
                        const struct_name = reflect_expr.target.Identifier.name;
                        const field_name = reflect_expr.field_name orelse {
                            std.debug.print(
                                "codegen error: @offsetOf requires a field name\n",
                                .{},
                            );
                            return error.UnsupportedFeature;
                        };
                        const layout = self.struct_layouts.get(struct_name) orelse {
                            std.debug.print(
                                "codegen error: @offsetOf({s}, ...): unknown struct\n",
                                .{struct_name},
                            );
                            return error.UnsupportedFeature;
                        };
                        var found: ?usize = null;
                        for (layout.fields) |field| {
                            if (std.mem.eql(u8, field.name, field_name)) {
                                found = field.offset;
                                break;
                            }
                        }
                        if (found) |off| {
                            try self.assembler.movRegImm64(.rax, @intCast(off));
                        } else {
                            std.debug.print(
                                "codegen error: @offsetOf({s}, \"{s}\"): unknown field\n",
                                .{ struct_name, field_name },
                            );
                            return error.UnsupportedFeature;
                        }
                    },
                    .TypeOf => {
                        // @TypeOf(expr) — return the inferred type name as
                        // a string pointer into the data section. We run
                        // inferExprType (the same helper LetDecl uses for
                        // untyped bindings) and register the resulting
                        // name as a string literal.
                        const tn = (try self.inferExprType(reflect_expr.target)) orelse "unknown";
                        const data_offset = try self.registerStringLiteral(tn);
                        const code_pos = try self.assembler.leaRipRel(.rax, 0);
                        try self.string_fixups.append(self.allocator, .{
                            .code_pos = code_pos,
                            .data_offset = data_offset,
                        });
                    },
                    .IntCast, .FloatCast, .PtrCast, .BitCast, .As, .Truncate => {
                        // Type cast builtins - for now, just evaluate the value
                        // The actual cast is a no-op in x86-64 as everything is 8 bytes
                        try self.generateExpr(reflect_expr.target);
                    },
                    .PtrToInt, .IntFromPtr => {
                        // @ptrToInt(ptr) - pointer is already an integer in memory
                        try self.generateExpr(reflect_expr.target);
                    },
                    .IntToFloat, .FloatToInt, .EnumToInt, .IntToEnum => {
                        // Type conversion builtins - for now, just evaluate the value
                        // In x86-64, we treat everything as 64-bit values
                        try self.generateExpr(reflect_expr.target);
                    },
                    .Sqrt, .Sin, .Cos, .Tan, .Acos => {
                        // Math functions - for now, just evaluate the argument
                        // Full implementation would use SSE/FPU instructions or libm calls
                        try self.generateExpr(reflect_expr.target);
                    },
                    .Abs => {
                        // @abs(value) — branchless: abs(x) = (x ^ (x >> 63)) - (x >> 63)
                        try self.generateExpr(reflect_expr.target);
                        // rdx = arithmetic right-shift rax by 63
                        try self.assembler.movRegReg(.rdx, .rax);
                        try self.assembler.sarRegImm8(.rdx, 63);
                        // rax ^= rdx
                        try self.assembler.xorRegReg(.rax, .rdx);
                        // rax -= rdx
                        try self.assembler.subRegReg(.rax, .rdx);
                    },
                    .MemSet, .MemCpy => {
                        // Memory operations - for now, just evaluate the first argument
                        try self.generateExpr(reflect_expr.target);
                    },
                    else => {
                        // Other reflection operations - placeholder
                        try self.assembler.movRegImm64(.rax, 0);
                    },
                }
            },

            .StringLiteral => |str_lit| {
                // Register the string literal and get its offset in data section
                const data_offset = try self.registerStringLiteral(str_lit.value);

                // Use LEA with RIP-relative addressing to load the string address
                // lea rax, [rip + displacement]
                // The displacement will be calculated as:
                //   data_section_start - (current_rip + instruction_length)
                // We'll patch this later when we know the final code size

                // Emit LEA with placeholder displacement (0 for now)
                const code_pos = try self.assembler.leaRipRel(.rax, 0);

                // Record this fixup so we can patch it later
                try self.string_fixups.append(self.allocator, .{
                    .code_pos = code_pos,
                    .data_offset = data_offset,
                });
            },

            .CharLiteral => |char_lit| {
                // Character literals are converted to their integer value.
                // `value` includes quotes, e.g. "'a'" or "'\\n'".
                const value = char_lit.value;
                var char_value: i64 = 0;

                if (value.len >= 3) {
                    if (value[1] == '\\' and value.len >= 4) {
                        char_value = switch (value[2]) {
                            'n' => '\n',
                            't' => '\t',
                            'r' => '\r',
                            '\\' => '\\',
                            '\'' => '\'',
                            '"' => '"',
                            '0' => 0,
                            'x' => blk: {
                                // Hex escape `\xNN` — require exactly two
                                // hex digits. Previous revision would quietly
                                // return 0 on malformed input, which meant
                                // buggy source compiled to a NUL literal.
                                if (value.len < 6) {
                                    std.debug.print(
                                        "codegen error: incomplete \\x escape in char literal {s}\n",
                                        .{value},
                                    );
                                    return error.UnsupportedFeature;
                                }
                                const hi = std.fmt.charToDigit(value[3], 16) catch {
                                    std.debug.print(
                                        "codegen error: invalid hex digit '{c}' in char literal {s}\n",
                                        .{ value[3], value },
                                    );
                                    return error.UnsupportedFeature;
                                };
                                const lo = std.fmt.charToDigit(value[4], 16) catch {
                                    std.debug.print(
                                        "codegen error: invalid hex digit '{c}' in char literal {s}\n",
                                        .{ value[4], value },
                                    );
                                    return error.UnsupportedFeature;
                                };
                                break :blk @as(i64, hi * 16 + lo);
                            },
                            else => value[2],
                        };
                    } else {
                        // Regular character
                        char_value = value[1];
                    }
                }

                try self.assembler.movRegImm64(.rax, char_value);
            },

            .MacroExpr => {
                // Macro expressions should have been expanded before codegen
                return error.UnexpandedMacro;
            },

            .AssignmentExpr => |assign| {
                // x = value or obj.field = value
                // Evaluate the value expression (result in rax)
                try self.generateExpr(assign.value);

                // Handle different target types
                if (assign.target.* == .Identifier) {
                    const target_name = assign.target.Identifier.name;
                    if (self.locals.get(target_name)) |local_info| {
                        // Store rax to stack location
                        const stack_offset: i32 = try self.localDisp(local_info.offset);
                        try self.assembler.movMemReg(.rbp, stack_offset, .rax);
                    } else {
                        // Variable doesn't exist - create it on the fly
                        if (self.next_local_offset < MAX_LOCALS) {
                            try self.assembler.pushReg(.rax);
                            const name = try self.allocator.dupe(u8, target_name);
                            try self.locals.put(name, .{
                                .offset = self.next_local_offset,
                                .type_name = "auto",
                                .size = 8,
                            });
                            self.next_local_offset += 1;
                        }
                    }
                } else if (assign.target.* == .MemberExpr) {
                    // Member assignment: obj.field = value or self.field = value
                    // Also supports nested: self.rows[row].x = value
                    const member = assign.target.MemberExpr;

                    // Save value in rbx first
                    try self.assembler.movRegReg(.rbx, .rax);

                    if (member.object.* == .Identifier) {
                        // Simple case: identifier.field = value
                        const obj_name = member.object.Identifier.name;

                        const local_info = self.locals.get(obj_name) orelse {
                            std.debug.print("Undefined variable in member assignment: {s}\n", .{obj_name});
                            return error.UndefinedVariable;
                        };

                        // Look up struct layout from type - try local first, then global
                        var maybe_struct_layout = self.struct_layouts.get(local_info.type_name);
                        if (maybe_struct_layout == null) {
                            // Try global type registry
                            if (self.type_registry) |registry| {
                                maybe_struct_layout = registry.getStruct(local_info.type_name);
                            }
                        }

                        const struct_layout = maybe_struct_layout orelse {
                            // Type might be Self or another unresolved type alias
                            // For now, just store to the variable directly
                            const stack_offset: i32 = try self.localDisp(local_info.offset);
                            try self.assembler.movMemReg(.rbp, stack_offset, .rax);
                            return;
                        };

                        // Find field offset in struct layout
                        var field_offset: ?usize = null;
                        for (struct_layout.fields) |field| {
                            if (std.mem.eql(u8, field.name, member.member)) {
                                field_offset = field.offset;
                                break;
                            }
                        }

                        if (field_offset == null) {
                            std.debug.print("Field {s} not found in struct {s}\n", .{ member.member, local_info.type_name });
                            return error.UnsupportedFeature;
                        }

                        // Check if this is a pointer to struct (size 8 but type is a struct)
                        // This happens for 'self' parameter in methods
                        if (local_info.size == 8 and struct_layout.total_size > 8) {
                            // Local contains a pointer to the struct
                            // First load the pointer from stack
                            const ptr_stack_offset: i32 = try self.localDisp(local_info.offset);
                            try self.assembler.movRegMem(.rax, .rbp, ptr_stack_offset);
                            // Then store the value to the field in the pointed struct
                            // Stack grows downward, so field at offset N is at [pointer - N]
                            const field_access_offset: i32 = -@as(i32, @intCast(field_offset.?));
                            try self.assembler.movMemReg(.rax, field_access_offset, .rbx);
                        } else {
                            // Struct is stored inline on stack
                            // Calculate address of field on stack
                            const struct_stack_base: i32 = try self.localDisp(local_info.offset);
                            const field_stack_offset: i32 = struct_stack_base - @as(i32, @intCast(field_offset.?));

                            // Store value to field on stack
                            try self.assembler.movMemReg(.rbp, field_stack_offset, .rbx);
                        }
                    } else {
                        // Nested case: expr.field = value (e.g., self.rows[row].x = value)
                        // Evaluate the base expression to get a pointer to the struct
                        // Save rbx (value) on stack since generateExpr will use registers
                        try self.assembler.pushReg(.rbx);
                        try self.generateExpr(member.object);
                        // rax now has pointer to the struct (from index/member expression)
                        // Restore value from stack into rbx
                        try self.assembler.popReg(.rbx);

                        // We need to know the type of the object to find the field offset
                        // Try to infer the type from the expression
                        const obj_type = try self.inferExprTypeForMember(member.object);
                        if (obj_type == null) {
                            // Cannot infer type - just skip this assignment (value already in rbx)
                            try self.assembler.movRegReg(.rax, .rbx);
                            return;
                        }

                        const struct_layout = self.struct_layouts.get(obj_type.?) orelse {
                            // Unknown struct type - just skip this assignment
                            try self.assembler.movRegReg(.rax, .rbx);
                            return;
                        };

                        // Find field offset in struct layout
                        var field_offset: ?usize = null;
                        for (struct_layout.fields) |field| {
                            if (std.mem.eql(u8, field.name, member.member)) {
                                field_offset = field.offset;
                                break;
                            }
                        }

                        if (field_offset == null) {
                            std.debug.print("Field {s} not found in struct {s}\n", .{ member.member, obj_type.? });
                            return error.UnsupportedFeature;
                        }

                        // rax has pointer to the struct, store rbx at field offset
                        // Stack grows downward, so field at offset N is at [pointer - N]
                        const field_access_offset: i32 = -@as(i32, @intCast(field_offset.?));
                        try self.assembler.movMemReg(.rax, field_access_offset, .rbx);
                    }
                } else if (assign.target.* == .UnaryExpr) {
                    // Dereference assignment: ptr.* = value
                    const unary = assign.target.UnaryExpr;
                    if (unary.op == .Deref) {
                        // Evaluate the pointer expression to get the address
                        // Save rax (value) on stack since generateExpr will use rax
                        try self.assembler.pushReg(.rax);
                        try self.generateExpr(unary.operand);
                        // rax now has the pointer address
                        // Pop value into rbx
                        try self.assembler.popReg(.rbx);
                        // Store value through pointer: [rax] = rbx
                        try self.assembler.movMemReg(.rax, 0, .rbx);
                    } else {
                        // Unsupported unary operation as assignment target (e.g., tuple destructuring)
                        // Skip this assignment for now
                        return;
                    }
                } else if (assign.target.* == .TupleExpr) {
                    // Tuple destructuring assignment: (a, b) = expr
                    const tuple = assign.target.TupleExpr;

                    // Save the source tuple pointer in rbx
                    try self.assembler.movRegReg(.rbx, .rax);

                    // For each element in the tuple target, extract and assign
                    for (tuple.elements, 0..) |elem, i| {
                        if (elem.* == .Identifier) {
                            const var_name = elem.Identifier.name;
                            if (self.locals.get(var_name)) |local_info| {
                                // Load the i-th element from the source tuple
                                // Tuples are stored as consecutive 8-byte values on the stack
                                const tuple_offset: i32 = -@as(i32, @intCast(i * 8));
                                try self.assembler.movRegMem(.rax, .rbx, tuple_offset);

                                // Store to the target variable
                                const stack_offset: i32 = try self.localDisp(local_info.offset);
                                try self.assembler.movMemReg(.rbp, stack_offset, .rax);
                            }
                        }
                        // For non-identifier tuple elements (nested), skip for now
                    }
                } else {
                    // Unsupported assignment target type
                    return;
                }
            },

            .ArrayLiteral => |array_lit| {
                // Array literal as an expression - allocate on stack and push elements
                const num_elements = array_lit.elements.len;

                // Push each element onto the stack in reverse order
                // so the first element is at the lowest address
                var i: usize = num_elements;
                while (i > 0) {
                    i -= 1;
                    try self.generateExpr(array_lit.elements[i]);
                    try self.assembler.pushReg(.rax);
                }

                // Return pointer to start of array (rsp points to first element)
                try self.assembler.movRegReg(.rax, .rsp);

                // Track stack usage
                self.next_local_offset +|= @as(u32, @intCast(num_elements));
            },

            .StructLiteral => |struct_lit| {
                // Struct literal as expression (e.g., in return statements)
                // Allocate space on stack and return pointer to it

                // Check if this is a generic type (contains '<')
                if (std.mem.indexOfScalar(u8, struct_lit.type_name, '<')) |_| {
                    // Generic type like Vec<T> - treat as null pointer for now
                    // Full generic support would require type instantiation
                    try self.assembler.movRegImm64(.rax, 0);
                    return;
                }

                const struct_layout = self.struct_layouts.get(struct_lit.type_name) orelse {
                    std.debug.print("Unknown struct type in literal: {s}\n", .{struct_lit.type_name});
                    return error.UnsupportedFeature;
                };

                // Push each field value onto the stack in layout order
                for (struct_layout.fields) |field_info| {
                    // Find the field in the literal
                    var field_value: ?*ast.Expr = null;
                    for (struct_lit.fields) |lit_field| {
                        if (std.mem.eql(u8, lit_field.name, field_info.name)) {
                            field_value = lit_field.value;
                            break;
                        }
                    }

                    if (field_value) |val| {
                        try self.generateExpr(val);
                        try self.assembler.pushReg(.rax);
                    } else {
                        std.debug.print(
                            "Warning: struct field '{s}' not initialized in literal — defaulting to zero\n",
                            .{field_info.name},
                        );
                        try self.assembler.movRegImm64(.rax, 0);
                        try self.assembler.pushReg(.rax);
                    }
                }

                // Return pointer to the struct on stack (first field)
                try self.assembler.movRegReg(.rax, .rsp);
            },

            .IndexExpr => |index| {
                // array[index]
                // Returns a POINTER to the element (for use in nested member access)
                // Evaluate array expression (get pointer in rax)
                try self.generateExpr(index.array);
                try self.assembler.pushReg(.rax); // Save array pointer

                // Evaluate index expression
                try self.generateExpr(index.index);
                // Index is now in rax

                // Pop array pointer into rcx
                try self.assembler.popReg(.rcx);

                // Calculate offset: index * element_size
                // For structs, use struct size; for primitives use 8
                const array_type = try self.inferExprTypeForMember(index.array);
                var elem_size: i32 = 8;
                if (array_type) |arr_type| {
                    if (arr_type.len > 2 and arr_type[0] == '[') {
                        // Extract element type from [T] or [T; N]
                        const inner = arr_type[1 .. arr_type.len - 1];
                        const elem_type = if (std.mem.indexOf(u8, inner, ";")) |semi_idx|
                            inner[0..semi_idx]
                        else
                            inner;
                        // Get element size
                        if (self.struct_layouts.get(elem_type)) |layout| {
                            elem_size = @intCast(layout.total_size);
                        }
                    }
                }

                try self.assembler.imulRegImm32(.rax, elem_size);

                // Subtract from base pointer (stack grows down)
                // rcx - rax gives us the address of element at index
                try self.assembler.subRegReg(.rcx, .rax);

                // Return pointer to element in rax (don't load the value)
                try self.assembler.movRegReg(.rax, .rcx);
            },

            .MemberExpr => |member| {
                // Can be: struct.field, Enum.Variant, or nested expr.field
                if (member.object.* == .Identifier) {
                    const type_or_var_name = member.object.Identifier.name;

                    // Check if this is an enum value (Enum.Variant)
                    if (self.enum_layouts.get(type_or_var_name)) |enum_layout| {
                        // Find variant index
                        var variant_index: ?usize = null;
                        for (enum_layout.variants, 0..) |variant_info, i| {
                            if (std.mem.eql(u8, variant_info.name, member.member)) {
                                variant_index = i;
                                break;
                            }
                        }

                        if (variant_index == null) {
                            std.debug.print("Variant {s} not found in enum {s}\n", .{ member.member, type_or_var_name });
                            return error.UnsupportedFeature;
                        }

                        // Create enum value on stack (same as CallExpr for enums)
                        // Layout: [tag (8 bytes)][data (8 bytes)]
                        // No-argument variants have data = 0

                        // Push data (always 0 for no-argument variants)
                        try self.assembler.movRegImm64(.rax, 0);
                        try self.assembler.pushReg(.rax);

                        // Push tag (variant index)
                        try self.assembler.movRegImm64(.rax, @intCast(variant_index.?));
                        try self.assembler.pushReg(.rax);

                        // Return pointer to enum on stack
                        try self.assembler.movRegReg(.rax, .rsp);
                        return;
                    }

                    // Otherwise, it's struct field access
                    const local_info = self.locals.get(type_or_var_name) orelse {
                        std.debug.print("Undefined variable in member access: {s}\n", .{type_or_var_name});
                        return error.UndefinedVariable;
                    };

                    // Look up struct layout from type. If the declared type
                    // is the shorthand `Self`, resolve it to the enclosing
                    // impl's type by looking at the current function's
                    // mangled name (`Type$method`). This matters for
                    // methods declared via `impl Foo { fn bar(self) }`,
                    // where the parser writes `self: Self` and we can only
                    // determine the concrete type from context.
                    const resolved_type_name: []const u8 = blk: {
                        if (std.mem.eql(u8, local_info.type_name, "Self")) {
                            if (self.current_function_name) |fname| {
                                if (std.mem.indexOfScalar(u8, fname, '$')) |dollar| {
                                    break :blk fname[0..dollar];
                                }
                            }
                        }
                        break :blk local_info.type_name;
                    };
                    const struct_layout = self.struct_layouts.get(resolved_type_name) orelse {
                        // Truly unresolved — fall back to loading the raw
                        // pointer. Caller sees garbage but compilation
                        // continues.
                        const stack_offset: i32 = try self.localDisp(local_info.offset);
                        try self.assembler.movRegMem(.rax, .rbp, stack_offset);
                        return;
                    };

                    // Find field offset in struct layout
                    var field_offset: ?usize = null;
                    for (struct_layout.fields) |field| {
                        if (std.mem.eql(u8, field.name, member.member)) {
                            field_offset = field.offset;
                            break;
                        }
                    }

                    if (field_offset == null) {
                        std.debug.print("Field {s} not found in struct {s}\n", .{ member.member, local_info.type_name });
                        return error.UnsupportedFeature;
                    }

                    // Check if the local is a POINTER to the struct rather
                    // than the struct itself.
                    //
                    // Historically the codegen used `total_size > 8` as the
                    // discriminator — "if the struct is bigger than one slot,
                    // the local must be a pointer". That breaks for methods
                    // on single-field structs (total_size == 8): the `self`
                    // parameter IS a pointer but the size check said
                    // otherwise and we'd mis-read the inline-struct branch.
                    //
                    // Better: detect shorthand `self` parameters by name.
                    // The parser assigns `type_name = "Self"` in that case;
                    // we already resolved that to the concrete type name
                    // above. Those are always pointers regardless of size.
                    const is_self_param = std.mem.eql(u8, type_or_var_name, "self") or
                        std.mem.eql(u8, local_info.type_name, "Self");
                    const is_pointer_to_struct = is_self_param or
                        (local_info.size == 8 and struct_layout.total_size > 8);

                    if (is_pointer_to_struct) {
                        // Local contains a pointer to the struct
                        // First load the pointer from stack
                        const ptr_stack_offset: i32 = try self.localDisp(local_info.offset);
                        try self.assembler.movRegMem(.rax, .rbp, ptr_stack_offset);
                        // Then load the field from the pointed struct
                        // Stack grows downward, so field at offset N is at [pointer - N] not [pointer + N]
                        const field_access_offset: i32 = -@as(i32, @intCast(field_offset.?));
                        try self.assembler.movRegMem(.rax, .rax, field_access_offset);
                    } else {
                        // Struct is stored inline on stack
                        // Calculate address of field on stack
                        // Struct fields are stored in order, so field offset is struct_base + field.offset
                        const struct_stack_base: i32 = try self.localDisp(local_info.offset);
                        const field_stack_offset: i32 = struct_stack_base - @as(i32, @intCast(field_offset.?));

                        // Load field value directly from stack
                        try self.assembler.movRegMem(.rax, .rbp, field_stack_offset);
                    }
                } else {
                    // Nested expression: expr.field (e.g., self.rows[row].x)
                    // Evaluate the base expression to get a pointer to the struct
                    try self.generateExpr(member.object);
                    // rax now has pointer to the struct

                    // Infer the type of the object to find the field offset
                    const obj_type = try self.inferExprTypeForMember(member.object);
                    if (obj_type == null) {
                        // Cannot infer type - just load from rax (treat as pointer deref)
                        try self.assembler.movRegMem(.rax, .rax, 0);
                        return;
                    }

                    const struct_layout = self.struct_layouts.get(obj_type.?) orelse {
                        // Unknown struct type - just load from rax (treat as pointer deref)
                        try self.assembler.movRegMem(.rax, .rax, 0);
                        return;
                    };

                    // Find field offset in struct layout
                    var field_offset: ?usize = null;
                    for (struct_layout.fields) |field| {
                        if (std.mem.eql(u8, field.name, member.member)) {
                            field_offset = field.offset;
                            break;
                        }
                    }

                    if (field_offset == null) {
                        std.debug.print("Field {s} not found in struct {s}\n", .{ member.member, obj_type.? });
                        return error.UnsupportedFeature;
                    }

                    // rax has pointer to the struct, load field from [rax - field_offset]
                    // Stack grows downward, so field at offset N is at [pointer - N]
                    const field_access_offset: i32 = -@as(i32, @intCast(field_offset.?));
                    try self.assembler.movRegMem(.rax, .rax, field_access_offset);
                }
            },

            .TryExpr => |try_expr| {
                // Try operator (?): Unwrap Result or propagate error
                // Result<T, E> is represented as an enum with:
                //   Ok(T):  tag=0, value at offset 8
                //   Err(E): tag=1, error at offset 8
                //
                // The ? operator:
                // 1. Evaluates the operand (Result value)
                // 2. Checks the tag
                // 3. If Ok: extracts and returns the value
                // 4. If Err: returns early from current function with Err

                // Evaluate the Result expression
                try self.generateExpr(try_expr.operand);

                // rax now contains pointer to Result enum on heap/stack
                // Result layout: [tag (8 bytes)][data (8 bytes)]

                // Save Result pointer in rbx
                try self.assembler.movRegReg(.rbx, .rax);

                // Load tag from Result: mov rcx, [rbx]
                try self.assembler.movRegMem(.rcx, .rbx, 0);

                // Check if tag == 0 (Ok variant)
                try self.assembler.testRegReg(.rcx, .rcx);

                // If tag != 0 (is Err), propagate the error
                const is_ok_jump = self.assembler.getPosition();
                try self.assembler.jzRel32(0); // Jump if zero (Ok)

                // Error path: propagate the Result (with Err tag) to caller
                try self.assembler.movRegReg(.rax, .rbx);

                // Return from function with error
                // Note: This assumes we're in a function context
                // Restore stack frame
                try self.assembler.movRegReg(.rsp, .rbp);
                try self.assembler.popReg(.rbp);
                try self.assembler.ret();

                // Ok path: Extract value
                const ok_path = self.assembler.getPosition();
                const ok_offset = @as(i32, @intCast(ok_path)) - @as(i32, @intCast(is_ok_jump + 6));
                try self.assembler.patchJzRel32(is_ok_jump, ok_offset);

                // Load Ok value from Result: mov rax, [rbx + 8]
                try self.assembler.movRegMem(.rax, .rbx, 8);

                // rax now contains the unwrapped value
            },

            .MatchExpr => |match_expr| {
                // Match expression: let result = match value { pattern => expr, ... }
                // Similar to MatchStmt but used as an expression - result of matching arm body is kept in rax

                // Save callee-saved register rbx (required by x86-64 ABI)
                // We track this as a pseudo-local to keep stack offsets consistent
                try self.assembler.pushReg(.rbx);
                const rbx_save_offset = self.next_local_offset;
                self.next_local_offset += 1;

                // Evaluate match value (result in rax)
                try self.generateExpr(match_expr.value);

                // Save match value in r10 for pattern comparisons
                try self.assembler.movRegReg(.r10, .rax);

                // Track positions for patching jumps to end
                var arm_end_jumps = std.ArrayList(usize).empty;
                defer arm_end_jumps.deinit(self.allocator);

                // Generate code for each match arm
                for (match_expr.arms) |arm| {
                    // Load match value from r10 into rbx for comparison
                    try self.assembler.movRegReg(.rbx, .r10);

                    // Try to match pattern (result in rax) - use expression-based pattern matching
                    try self.generateExprAsPatternMatch(arm.pattern, .rbx);

                    // Test pattern match result
                    try self.assembler.testRegReg(.rax, .rax);

                    // If pattern didn't match, jump to next arm
                    const next_arm_jump = self.assembler.getPosition();
                    try self.assembler.jzRel32(0); // Jump if pattern match failed (rax == 0)

                    // Pattern matched, bind any pattern variables
                    const locals_before = self.locals.count();
                    try self.bindExprAsPatternVariables(arm.pattern, .rbx);

                    // Pattern matched, evaluate guard if present
                    if (arm.guard) |guard| {
                        // Count pattern variables BEFORE any cleanup
                        const vars_added = self.locals.count() - locals_before;

                        try self.generateExpr(guard);
                        // Test guard result
                        try self.assembler.testRegReg(.rax, .rax);
                        // If guard failed, need to clean up pattern vars then jump to next arm
                        const guard_fail_jump = self.assembler.getPosition();
                        try self.assembler.jzRel32(0);

                        // Guard succeeded, execute arm body (result stays in rax)
                        try self.generateExpr(arm.body);

                        // Clean up pattern variables
                        try self.cleanupPatternVariables(locals_before);

                        // Jump to end of match
                        try self.assembler.jmpRel32(0);
                        try arm_end_jumps.append(self.allocator, self.assembler.getPosition() - 5);

                        // Guard fail path: clean up pattern variables then continue to next arm
                        const guard_fail_pos = self.assembler.getPosition();
                        const guard_offset = @as(i32, @intCast(guard_fail_pos)) - @as(i32, @intCast(guard_fail_jump + 6));
                        try self.assembler.patchJzRel32(guard_fail_jump, guard_offset);

                        // Clean up pattern variables when guard fails (use pre-computed count)
                        try self.cleanupPatternVariablesCodeOnlyN(vars_added);
                    } else {
                        // No guard, execute arm body directly (result stays in rax)
                        try self.generateExpr(arm.body);

                        // Clean up pattern variables
                        try self.cleanupPatternVariables(locals_before);

                        // Jump to end of match
                        try self.assembler.jmpRel32(0);
                        try arm_end_jumps.append(self.allocator, self.assembler.getPosition() - 5);
                    }

                    // Patch pattern match fail jump to next arm
                    const next_arm_pos = self.assembler.getPosition();
                    const next_offset = @as(i32, @intCast(next_arm_pos)) - @as(i32, @intCast(next_arm_jump + 6));
                    try self.assembler.patchJzRel32(next_arm_jump, next_offset);
                }

                // Patch all "end of match" jumps
                const match_end = self.assembler.getPosition();
                for (arm_end_jumps.items) |jump_pos| {
                    const offset = @as(i32, @intCast(match_end)) - @as(i32, @intCast(jump_pos + 5));
                    try self.assembler.patchJmpRel32(jump_pos, offset);
                }

                // Restore callee-saved register rbx and stack offset
                try self.assembler.popReg(.rbx);
                _ = rbx_save_offset; // suppress unused warning
                self.next_local_offset -= 1;

                // rax now contains the result of the matched arm's body expression
            },

            .TypeCastExpr => |type_cast| {
                // Type cast expression: cast value to target_type.
                //
                // For narrowing integer casts (i64 → i8/i16/i32 or
                // u8/u16/u32) we now emit a runtime range check that
                // panics with the offending value if the source doesn't
                // fit, instead of silently truncating. If the source is a
                // compile-time IntegerLiteral we also reject it at codegen
                // time via NarrowingCastOutOfRange.
                try self.generateExpr(type_cast.value);

                const range = narrowingRangeFor(type_cast.target_type);
                if (range) |r| {
                    // Compile-time rejection for constant literals.
                    if (type_cast.value.* == .IntegerLiteral) {
                        const v = type_cast.value.IntegerLiteral.value;
                        if (v < r.min or v > r.max) {
                            std.debug.print(
                                "narrowing cast out of range: {d} as {s} (valid range {d}..{d})\n",
                                .{ v, type_cast.target_type, r.min, r.max },
                            );
                            return error.NarrowingCastOutOfRange;
                        }
                        // In-range constant: no runtime check needed.
                    } else {
                        try self.emitNarrowingRangeCheck(type_cast.target_type, r);
                    }
                }
            },

            .StaticCallExpr => |static_call| {
                // Static method call: Type.method(args)
                // Look for a mangled function name: Type$method
                const mangled_name = try self.mangleMethodName(static_call.type_name, static_call.method_name);
                defer self.allocator.free(mangled_name);

                if (self.functions.get(mangled_name)) |func_pos| {
                    // Push arguments
                    const arg_regs = [_]x64.Register{ .rdi, .rsi, .rdx, .rcx, .r8, .r9 };

                    for (static_call.args) |arg| {
                        try self.generateExpr(arg);
                        try self.assembler.pushReg(.rax);
                    }

                    // Pop into argument registers in reverse order
                    const reg_arg_count = @min(static_call.args.len, arg_regs.len);
                    if (reg_arg_count > 0) {
                        var j: usize = reg_arg_count;
                        while (j > 0) {
                            j -= 1;
                            try self.assembler.popReg(arg_regs[j]);
                        }
                    }

                    // Call the function
                    const current_pos = self.assembler.getPosition();
                    const rel_offset = @as(i32, @intCast(func_pos)) - @as(i32, @intCast(current_pos + 5));
                    try self.assembler.callRel32(rel_offset);
                } else {
                    // Unknown static method - evaluate args and return 0
                    for (static_call.args) |arg| {
                        try self.generateExpr(arg);
                    }
                    try self.assembler.movRegImm64(.rax, 0);
                }
            },

            .ReturnExpr => |return_expr| {
                // Generate return expression (for match arms)
                if (return_expr.value) |value| {
                    try self.generateExpr(value);
                } else {
                    try self.assembler.movRegImm64(.rax, 0);
                }
                // Generate epilogue and return
                try self.assembler.movRegReg(.rsp, .rbp);
                try self.assembler.popReg(.rbp);
                try self.assembler.ret();
            },

            .IfExpr => |if_expr| {
                // Generate if expression: evaluate condition, branch, and return result
                // Evaluate condition (result in rax)
                try self.generateExpr(if_expr.condition);

                // Compare rax to 0 (false)
                try self.assembler.cmpRegImm(.rax, 0);

                // Use rel32 jumps so branches >127 bytes don't overflow.
                const else_jump_pos = self.assembler.getPosition();
                try self.assembler.jeRel32(0);

                // Then branch
                try self.generateExpr(if_expr.then_branch);

                // Jump over else branch
                const end_jump_pos = self.assembler.getPosition();
                try self.assembler.jmpRel32(0);

                // Patch else jump target
                const else_pos = self.assembler.getPosition();
                try self.assembler.patchJeRel32(
                    else_jump_pos,
                    @as(i32, @intCast(else_pos)) - @as(i32, @intCast(else_jump_pos + 6)),
                );

                // Else branch
                try self.generateExpr(if_expr.else_branch);

                // Patch end jump target
                const end_pos = self.assembler.getPosition();
                try self.assembler.patchJmpRel32(
                    end_jump_pos,
                    @as(i32, @intCast(end_pos)) - @as(i32, @intCast(end_jump_pos + 5)),
                );
            },

            .BlockExpr => |block_expr| {
                // Block expression: execute statements in sequence
                // The last expression's value (if any) becomes the block's value
                for (block_expr.statements) |stmt| {
                    try self.generateStmt(stmt);
                }
                // If block is empty or last statement was not an expression,
                // the result in rax is undefined (caller should handle this)
            },

            .RangeExpr => |range_expr| {
                // Range expression creates a struct with three fields:
                // struct Range { start: i64, end: i64, inclusive: bool }
                // Push fields onto stack in reverse order (stack grows downward)

                // Push inclusive flag first (will be at highest address / last field)
                const inclusive_val: i64 = if (range_expr.inclusive) 1 else 0;
                try self.assembler.movRegImm64(.rax, inclusive_val);
                try self.assembler.pushReg(.rax);

                // Push end value
                try self.generateExpr(range_expr.end);
                try self.assembler.pushReg(.rax);

                // Push start value (will be at lowest address / first field)
                try self.generateExpr(range_expr.start);
                try self.assembler.pushReg(.rax);

                // Return pointer to the Range struct (points to first field = start)
                try self.assembler.movRegReg(.rax, .rsp);

                // Track stack usage (3 i64 values)
                self.next_local_offset +|= 3;
            },

            .ArrayRepeat => |array_repeat| {
                // Array repeat expression: [value; count]
                // Allocate count elements on stack, all initialized to the same value

                // Parse the count (it's stored as a string in the AST)
                const count = std.fmt.parseInt(usize, array_repeat.count, 10) catch {
                    std.debug.print("Invalid array repeat count: {s}\n", .{array_repeat.count});
                    return error.UnsupportedFeature;
                };

                if (count == 0) {
                    // Empty array - just return stack pointer
                    try self.assembler.movRegReg(.rax, .rsp);
                    return;
                }

                // Generate the value expression once
                try self.generateExpr(array_repeat.value);

                // rax now contains the value to repeat
                // Push it onto the stack 'count' times
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    try self.assembler.pushReg(.rax);
                }

                // Return pointer to start of array (rsp points to first element)
                try self.assembler.movRegReg(.rax, .rsp);

                // Track stack usage. The count comes from a user-supplied integer
                // literal — must not silently truncate.
                const count_u32 = safeIntCast(u32, count) catch {
                    std.debug.print("array repeat count {d} exceeds u32\n", .{count});
                    return error.UnsupportedFeature;
                };
                self.next_local_offset +|= count_u32;
            },

            .InterpolatedString => |interp_str| {
                // Interpolated string: "Hello {name}!"
                //
                // Layout from the parser: parts[i] is literal text, expressions[i]
                // is interpolated between parts[i] and parts[i+1]. So the result is:
                //   parts[0] + str(expressions[0]) + parts[1] + ... + parts[N]
                //
                // Built left-to-right with stringConcat. Non-string expressions go
                // through intToDecimalString. The accumulator lives in rax between
                // pieces and is spilled to the stack while evaluating the next piece.

                if (interp_str.parts.len == 0 and interp_str.expressions.len == 0) {
                    try self.loadStringLiteralIntoRax("");
                    return;
                }

                // Initial accumulator = parts[0] (or "" if missing/empty).
                if (interp_str.parts.len > 0 and interp_str.parts[0].len > 0) {
                    try self.loadStringLiteralIntoRax(interp_str.parts[0]);
                } else {
                    try self.loadStringLiteralIntoRax("");
                }

                var i: usize = 0;
                while (i < interp_str.expressions.len) : (i += 1) {
                    // Append str(expressions[i]) to the accumulator.
                    try self.assembler.pushReg(.rax); // spill acc
                    try self.generateExpr(&interp_str.expressions[i]);

                    // Convert non-string expressions to their string
                    // representation. Float values need a different path
                    // than integers to preserve decimal notation.
                    switch (interp_str.expressions[i]) {
                        .StringLiteral, .InterpolatedString => {},
                        .FloatLiteral => {
                            // Float→string: for now, treat the raw bits as
                            // a printable number. Full formatting would need
                            // an ftoa routine; intToDecimalString handles the
                            // common integer interpolation case.
                            try self.intToDecimalString();
                        },
                        else => try self.intToDecimalString(),
                    }

                    try self.assembler.movRegReg(.rcx, .rax); // right = expr str
                    try self.assembler.popReg(.rax); // left = acc
                    try self.concatStringPointers(.rax, .rcx);

                    // Append parts[i+1] if any and non-empty.
                    const next_idx = i + 1;
                    if (next_idx < interp_str.parts.len and interp_str.parts[next_idx].len > 0) {
                        try self.assembler.pushReg(.rax);
                        try self.loadStringLiteralIntoRax(interp_str.parts[next_idx]);
                        try self.assembler.movRegReg(.rcx, .rax);
                        try self.assembler.popReg(.rax);
                        try self.concatStringPointers(.rax, .rcx);
                    }
                }
            },

            .IsExpr => |is_expr| {
                // Type narrowing expression: value is TypeName
                // Returns true (1) if the value is of the specified type, false (0) otherwise
                //
                // For enum types, this checks the tag value
                // For Option<T>, checks if Some or None
                // For Result<T, E>, checks if Ok or Err

                // Generate code for the value expression
                // The value could be an enum pointer, so rax will point to the enum
                try self.generateExpr(is_expr.value);

                // rax now contains the value/pointer to check
                // For enum types, first word is the tag

                // Check the type name to determine what we're checking for
                const type_name = is_expr.type_name;

                // Check for common Option/Result variants
                if (std.mem.eql(u8, type_name, "Some") or std.mem.eql(u8, type_name, "Ok")) {
                    // Some/Ok typically has tag 0
                    // Load tag from pointer in rax
                    try self.assembler.movRegMem(.rcx, .rax, 0); // Load tag into rcx
                    // Compare tag with 0 (Some/Ok)
                    try self.assembler.cmpRegImm(.rcx, 0);
                    // Set result: 1 if tag == 0, 0 otherwise
                    try self.assembler.setzReg(.rax);
                    try self.assembler.movzxReg64Reg8(.rax, .rax);
                } else if (std.mem.eql(u8, type_name, "None") or std.mem.eql(u8, type_name, "Err")) {
                    // None/Err typically has tag 1
                    try self.assembler.movRegMem(.rcx, .rax, 0); // Load tag
                    try self.assembler.cmpRegImm(.rcx, 1);
                    try self.assembler.setzReg(.rax);
                    try self.assembler.movzxReg64Reg8(.rax, .rax);
                } else if (self.enum_layouts.get(type_name)) |_| {
                    // Check if the value's tag matches this enum type
                    // For full enum type checks, compare runtime type info
                    // This is a simplified version that checks if the enum is valid
                    try self.assembler.movRegMem(.rcx, .rax, 0); // Load tag
                    // Assume enum is valid (non-negative tag)
                    try self.assembler.cmpRegImm(.rcx, 0);
                    // Set to 1 if tag >= 0 (always true for valid enums)
                    try self.assembler.movRegImm64(.rax, 1);
                } else {
                    // For primitive type checks, use a simplified approach
                    // In a full implementation, this would check runtime type tags
                    // For now, just return true (1) as a placeholder
                    try self.assembler.movRegImm64(.rax, 1);
                }

                // Handle negation if "is not" syntax
                if (is_expr.negated) {
                    // Invert the result: xor rax, 1
                    try self.assembler.xorRegImm32(.rax, 1);
                }
            },

            .SliceExpr => |slice| {
                // `s[i..j]` / `s[..j]` / `s[i..]` / `s[..]` — produce a
                // freshly heap-allocated NUL-terminated string containing
                // the requested byte range. Missing bounds default to 0
                // (start) or `strlen(s)` (end). This is the same strategy
                // as the existing `substring` method but lowered from the
                // SliceExpr node.
                //
                // Evaluate source → rax; stash, then compute start and end.
                try self.generateExpr(slice.array);
                try self.assembler.pushReg(.rax); // [rsp] = src ptr

                // end (default: strlen(src))
                if (slice.end) |end_expr| {
                    try self.generateExpr(end_expr);
                } else {
                    try self.assembler.movRegMem(.rdi, .rsp, 0); // src ptr
                    try self.stringLength(.rdi);                 // rax = len
                }
                if (slice.inclusive) {
                    try self.assembler.addRegImm(.rax, 1);
                }
                try self.assembler.pushReg(.rax); // [rsp] = end

                // start (default: 0)
                if (slice.start) |start_expr| {
                    try self.generateExpr(start_expr);
                } else {
                    try self.assembler.movRegImm64(.rax, 0);
                }
                try self.assembler.pushReg(.rax); // [rsp] = start

                // Now stack: [rsp]=start, [rsp+8]=end, [rsp+16]=src
                // Compute len = end - start in rdx.
                try self.assembler.popReg(.rcx); // start
                try self.assembler.popReg(.rdx); // end
                try self.assembler.subRegReg(.rdx, .rcx); // rdx = len
                try self.assembler.popReg(.rax); // src
                try self.assembler.movRegReg(.r8, .rdx); // r8 = len

                // heapAlloc(len + 1)
                try self.assembler.movRegReg(.rdi, .r8);
                try self.assembler.addRegImm(.rdi, 1);
                try self.assembler.pushReg(.rax); // src
                try self.assembler.pushReg(.rcx); // start
                try self.assembler.pushReg(.r8); // len
                try self.heapAlloc();
                try self.assembler.movRegReg(.r10, .rax); // r10 = dst
                try self.assembler.popReg(.r8);
                try self.assembler.popReg(.rcx);
                try self.assembler.popReg(.rax);

                // memcpy(dst, src + start, len)
                try self.assembler.addRegReg(.rax, .rcx);
                try self.assembler.movRegReg(.rsi, .rax);
                try self.assembler.movRegReg(.rdi, .r10);
                try self.assembler.movRegReg(.rdx, .r8);
                try self.memcpy();

                // NUL-terminate at dst[len]
                try self.assembler.movRegReg(.rax, .r10);
                try self.assembler.addRegReg(.rax, .r8);
                try self.assembler.movByteMemImm(.rax, 0, 0);

                // Return pointer.
                try self.assembler.movRegReg(.rax, .r10);
            },

            else => |expr_tag| {
                std.debug.print("Unsupported expression type in native codegen: {s}\n", .{@tagName(expr_tag)});
                return error.UnsupportedFeature;
            },
        }
    }
};
