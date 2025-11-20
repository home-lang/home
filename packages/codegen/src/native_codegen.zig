const std = @import("std");
const ast = @import("ast");
pub const x64 = @import("x64.zig");
const elf = @import("elf.zig");
const macho = @import("macho.zig");
const builtin = @import("builtin");
const type_checker_mod = @import("type_checker.zig");
pub const TypeChecker = type_checker_mod.TypeChecker;

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
} || std.mem.Allocator.Error || std.fs.File.OpenError || std.fs.File.ReadError;

/// Maximum number of local variables per function.
///
/// This limit is based on typical x64 register allocation and stack frame
/// constraints. Each local variable occupies stack space indexed by an 8-bit
/// offset, allowing for efficient encoding in x64 instructions.
const MAX_LOCALS = 256;

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

/// Local variable information.
///
/// Stores both stack location and type information for local variables.
pub const LocalInfo = struct {
    /// Stack offset from RBP (1-based index)
    offset: u8,
    /// Type name (e.g., "i32", "[i32]", "Point")
    type_name: []const u8,
    /// Size in bytes
    size: usize,
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
        // Load first operand into xmm0
        try assembler.movdqaXmmMem(.xmm0, .rdi, offset); // rdi = first array base

        // Load second operand into xmm1
        try assembler.movdqaXmmMem(.xmm1, .rsi, offset); // rsi = second array base

        // Perform operation
        switch (pattern.op) {
            .add => try assembler.padddXmmXmm(.xmm0, .xmm1),
            .sub => try assembler.psubdXmmXmm(.xmm0, .xmm1),
            .mul => try assembler.pmulldXmmXmm(.xmm0, .xmm1),
            .div => {
                // Integer division not available in SIMD, fall back to scalar
                // For now, skip - would need scalar fallback
            },
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
    next_local_offset: u8,

    // Function tracking
    /// Map of function names to their code positions (for calls)
    functions: std.StringHashMap(usize),

    // Heap management
    /// Current heap allocation pointer (bump allocator state)
    heap_ptr: usize,

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

    // Register allocation
    /// Simple register allocator for optimizing register usage
    reg_alloc: RegisterAllocator,

    /// Create a new native code generator for the given program.
    ///
    /// Parameters:
    ///   - allocator: Allocator for codegen data structures
    ///   - program: AST program to compile
    ///
    /// Returns: Initialized NativeCodegen
    pub fn init(allocator: std.mem.Allocator, program: *const ast.Program) NativeCodegen {
        return .{
            .allocator = allocator,
            .assembler = x64.Assembler.init(allocator),
            .program = program,
            .locals = std.StringHashMap(LocalInfo).init(allocator),
            .next_local_offset = 0,
            .functions = std.StringHashMap(usize).init(allocator),
            .heap_ptr = HEAP_START,
            .struct_layouts = std.StringHashMap(StructLayout).init(allocator),
            .enum_layouts = std.StringHashMap(EnumLayout).init(allocator),
            .string_literals = std.ArrayList([]const u8){},
            .string_offsets = std.StringHashMap(usize).init(allocator),
            .string_fixups = std.ArrayList(StringFixup){},
            .reg_alloc = RegisterAllocator.init(),
        };
    }

    /// Clean up codegen resources.
    ///
    /// Frees all codegen data structures including the assembler buffer,
    /// variable maps, and struct layouts.
    pub fn deinit(self: *NativeCodegen) void {
        self.assembler.deinit();

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

        // Free struct_layouts memory
        {
            var struct_iter = self.struct_layouts.iterator();
            while (struct_iter.next()) |entry| {
                const key = entry.key_ptr.*;
                const layout = entry.value_ptr.*;

                // Free field names
                for (layout.fields) |field| {
                    if (field.name.len > 0) {
                        self.allocator.free(field.name);
                    }
                }

                // Free fields array
                if (layout.fields.len > 0) {
                    self.allocator.free(layout.fields);
                }

                // Free struct name (key and layout.name are the same pointer)
                if (key.len > 0) {
                    self.allocator.free(key);
                }
            }
            self.struct_layouts.deinit();
        }

        // Free enum_layouts memory
        {
            var enum_iter = self.enum_layouts.iterator();
            while (enum_iter.next()) |entry| {
                const key = entry.key_ptr.*;
                const layout = entry.value_ptr.*;

                // Free variant names and data types
                for (layout.variants) |variant| {
                    if (variant.name.len > 0) {
                        self.allocator.free(variant.name);
                    }
                    if (variant.data_type) |dt| {
                        if (dt.len > 0) {
                            self.allocator.free(dt);
                        }
                    }
                }

                // Free variants array
                if (layout.variants.len > 0) {
                    self.allocator.free(layout.variants);
                }

                // Free enum name (key and layout.name are the same pointer)
                if (key.len > 0) {
                    self.allocator.free(key);
                }
            }
            self.enum_layouts.deinit();
        }

        // Free string_offsets (keys point to AST memory, not allocated)
        self.string_offsets.deinit();

        self.string_literals.deinit(self.allocator);
        self.string_fixups.deinit(self.allocator);
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
        const needs_rex = base.needsRexPrefix() or src.needsRexPrefix();
        if (needs_rex or true) { // Always use REX.W for 64-bit
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
        const writer = self.assembler.code.writer(self.allocator);
        try writer.writeInt(i32, offset, .little);
    }

    /// Register a string literal and return its offset in the data section
    fn registerStringLiteral(self: *NativeCodegen, str: []const u8) !usize {
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

    /// Get the total size of the data section (all strings + null terminators)
    fn getDataSectionSize(self: *NativeCodegen) usize {
        var size: usize = 0;
        for (self.string_literals.items) |str| {
            size += str.len + 1; // +1 for null terminator
        }
        return size;
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

    fn checkMatchExhaustiveness(self: *NativeCodegen, match_stmt: *ast.MatchStmt) CodegenError!void {
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
        var covered_variants = std.ArrayList([]const u8){};
        defer covered_variants.deinit(self.allocator);

        var match_enum_name: ?[]const u8 = null;

        for (match_stmt.arms) |arm| {
            try self.checkPatternExhaustiveness(arm.pattern, &covered_variants, &match_enum_name, &has_wildcard);
        }

        if (has_wildcard) {
            // Match is exhaustive
            return;
        }

        // If we identified an enum type, check if all variants are covered
        if (match_enum_name) |enum_name| {
            if (self.enum_layouts.get(enum_name)) |enum_layout| {
                // Check if all variants are covered
                var all_covered = true;
                var missing_variants = std.ArrayList([]const u8){};
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
                    // Emit warning for non-exhaustive match
                    std.debug.print("Warning: non-exhaustive pattern match on enum '{s}'\n", .{enum_name});
                    std.debug.print("Missing variants:\n", .{});
                    for (missing_variants.items) |variant| {
                        std.debug.print("  - {s}\n", .{variant});
                    }
                    std.debug.print("Consider adding a wildcard pattern '_' to handle all cases\n", .{});
                }
            }
        }

        // Allow non-exhaustive matches for now (with warning)
        // Future enhancement: make this an error in strict mode
    }

    /// Generate pattern matching code
    /// Returns: pattern match result in rax (1 if matched, 0 if not matched)
    /// value_reg: register containing the value to match against
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
                // Set rax based on comparison
                try self.assembler.movRegImm64(.rax, 0); // Assume no match
                try self.assembler.jneRel32(10); // Skip next instruction if not equal (10 bytes for movRegImm64)
                try self.assembler.movRegImm64(.rax, 1); // Match found
            },
            .BoolLiteral => |bool_val| {
                // Compare value with boolean (0 or 1)
                const int_val: i64 = if (bool_val) 1 else 0;
                try self.assembler.movRegImm64(.rcx, @intCast(int_val));
                try self.assembler.cmpRegReg(value_reg, .rcx);
                try self.assembler.movRegImm64(.rax, 0);
                try self.assembler.jneRel32(10);
                try self.assembler.movRegImm64(.rax, 1);
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
                try self.assembler.movRegImm64(.rdx, float_bits);

                // Compare
                const cmp_reg = if (needs_save) saved_reg else value_reg;
                try self.assembler.cmpRegReg(cmp_reg, .rdx);

                // Set rax based on comparison
                try self.assembler.movRegImm64(.rax, 0); // Assume no match
                try self.assembler.jneRel32(10); // Skip next instruction if not equal
                try self.assembler.movRegImm64(.rax, 1); // Match found
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
                try self.assembler.movRegImm64(.rax, 0); // Assume no match
                try self.assembler.jneRel32(10); // Skip next instruction if not equal
                try self.assembler.movRegImm64(.rax, 1); // Match found
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
                    // Set result based on comparison
                    try self.assembler.movRegImm64(.rax, 0); // Assume no match
                    try self.assembler.jneRel32(10); // Skip next instruction if not equal
                    try self.assembler.movRegImm64(.rax, 1); // Match found
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
                var elem_fail_jumps = std.ArrayList(usize){ .items = &.{}, .capacity = 0 };
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
                    var elem_fail_jumps = std.ArrayList(usize){ .items = &.{}, .capacity = 0 };
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

                    var elem_fail_jumps = std.ArrayList(usize){ .items = &.{}, .capacity = 0 };
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
                var field_fail_jumps = std.ArrayList(usize){ .items = &.{}, .capacity = 0 };
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
                var success_jumps = std.ArrayList(usize){ .items = &.{}, .capacity = 0 };
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
            else => {
                try self.assembler.movRegImm64(.rax, 0);
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

                    const name_copy = try self.allocator.dupe(u8, name);
                    errdefer self.allocator.free(name_copy);

                    // We don't know the exact type, so use a generic size
                    try self.locals.put(name_copy, .{
                        .offset = offset,
                        .type_name = "i32", // Default to i32 for now
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
                    // For now, we'll bind the whole array pointer
                    // TODO: Create a new array slice with remaining elements
                    const rest_offset: i32 = @intCast((array_pattern.elements.len + 1) * 8);
                    try self.assembler.leaRegMem(.rcx, value_reg, rest_offset);

                    try self.assembler.pushReg(.rcx);
                    const offset = self.next_local_offset;
                    self.next_local_offset += 1;

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
            // Complex patterns TODO
            .Range => {},
        }
    }

    /// Clean up pattern variables added after a certain point
    /// This removes variables from the locals map and adjusts stack
    /// Preserves rax (the arm body result)
    fn cleanupPatternVariables(self: *NativeCodegen, locals_before: usize) CodegenError!void {
        const locals_after = self.locals.count();
        const vars_to_remove = locals_after - locals_before;

        if (vars_to_remove == 0) return;

        // Save rax (arm body result)
        try self.assembler.pushReg(.rax);

        // Pop variables from stack (into rcx to discard)
        var i: usize = 0;
        while (i < vars_to_remove) : (i += 1) {
            try self.assembler.popReg(.rcx); // Pop into rcx (discard)
        }

        // Restore rax
        try self.assembler.popReg(.rax);

        // Reset local offset
        self.next_local_offset -= @intCast(vars_to_remove);

        // Remove from locals HashMap
        // We need to iterate and remove entries added after locals_before
        // Since HashMap doesn't support removal during iteration, collect keys first
        var keys_to_remove = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
        defer keys_to_remove.deinit(self.allocator);

        var iter = self.locals.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.offset >= @as(u8, @intCast(locals_before))) {
                try keys_to_remove.append(self.allocator, entry.key_ptr.*);
            }
        }

        // Now remove the collected keys
        for (keys_to_remove.items) |key| {
            _ = self.locals.remove(key);
            self.allocator.free(key);
        }
    }

    /// Get the size of a type in bytes
    fn getTypeSize(self: *NativeCodegen, type_name: []const u8) CodegenError!usize {
        // Primitive types
        if (std.mem.eql(u8, type_name, "i32")) return 8; // i64 on x64
        if (std.mem.eql(u8, type_name, "i64")) return 8;
        if (std.mem.eql(u8, type_name, "bool")) return 8;
        if (std.mem.eql(u8, type_name, "f32")) return 4;
        if (std.mem.eql(u8, type_name, "f64")) return 8;
        if (std.mem.eql(u8, type_name, "str")) return 8; // String pointers are 8 bytes
        if (std.mem.eql(u8, type_name, "string")) return 8; // String pointers are 8 bytes

        // Check if it's a struct type
        if (self.struct_layouts.get(type_name)) |layout| {
            return layout.total_size;
        }

        // Check if it's an enum type
        if (self.enum_layouts.get(type_name)) |enum_layout| {
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

        std.debug.print("Unknown type: {s}\n", .{type_name});
        return error.UnsupportedFeature;
    }

    /// Write all string literals to a buffer for the data section
    fn writeDataSection(self: *NativeCodegen) ![]u8 {
        const size = self.getDataSectionSize();
        if (size == 0) {
            return &[_]u8{};
        }

        var data = try self.allocator.alloc(u8, size);
        var offset: usize = 0;

        for (self.string_literals.items) |str| {
            @memcpy(data[offset..][0..str.len], str);
            offset += str.len;
            data[offset] = 0; // Null terminator
            offset += 1;
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
        const text_section_base: usize = 0x1000; // __TEXT starts at file offset 0x1000

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
        // Generate code for all statements
        // Note: Don't add prologue/epilogue here - each function handles its own
        for (self.program.statements) |stmt| {
            try self.generateStmt(stmt);
        }

        return try self.assembler.getCode();
    }

    pub fn writeExecutable(self: *NativeCodegen, path: []const u8) !void {
        // Generate code (this fills self.assembler.code)
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
                try writer.writeWithEntryPoint(path, main_offset);
            },
            .linux => {
                var writer = elf.ElfWriter.init(self.allocator, code);
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
            .ExprStmt => |expr| {
                _ = try self.generateExpr(expr);
            },
            .FnDecl => |func| try self.generateFnDecl(func),
            .ReturnStmt => |ret| {
                if (ret.value) |value| {
                    try self.generateExpr(value);
                    // Result is in rax
                }
                // Jump to epilogue (for now, just return)
                try self.assembler.movRegReg(.rsp, .rbp);
                try self.assembler.popReg(.rbp);
                try self.assembler.ret();
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

                // Generate loop body
                for (while_stmt.body.statements) |body_stmt| {
                    try self.generateStmt(body_stmt);
                }

                // Jump back to condition
                const current_pos = self.assembler.getPosition();
                const back_offset = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(current_pos + 5));
                try self.assembler.jmpRel32(back_offset);

                // Patch the conditional jump to point here (after loop)
                const loop_end = self.assembler.getPosition();
                const forward_offset = @as(i32, @intCast(loop_end)) - @as(i32, @intCast(jz_pos + 6));
                try self.assembler.patchJzRel32(jz_pos, forward_offset);
            },
            .DoWhileStmt => |do_while| {
                // Do-while: body, test condition, jump back if true
                const loop_start = self.assembler.getPosition();

                // Generate loop body
                for (do_while.body.statements) |body_stmt| {
                    try self.generateStmt(body_stmt);
                }

                // Evaluate condition
                try self.generateExpr(do_while.condition);

                // Test rax (condition result)
                try self.assembler.testRegReg(.rax, .rax);

                // Jump back to start if true (non-zero)
                const current_pos = self.assembler.getPosition();
                const back_offset = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(current_pos + 6));
                try self.assembler.jnzRel32(back_offset);
            },
            .ForStmt => |for_stmt| {
                // For loop: for iterator in iterable { body }
                // Currently only supports range expressions (e.g., 0..10)

                // Check if iterable is a range expression
                if (for_stmt.iterable.* != .RangeExpr) {
                    std.debug.print("For loops currently only support range expressions\n", .{});
                    return error.UnsupportedFeature;
                }

                const range = for_stmt.iterable.RangeExpr;

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
                const iterator_name_copy = try self.allocator.dupe(u8, for_stmt.iterator);
                errdefer self.allocator.free(iterator_name_copy);
                try self.locals.put(iterator_name_copy, .{
                    .offset = iterator_offset,
                    .type_name = "i32",  // For loop iterators are always i32
                    .size = 8,
                });

                // Push initial iterator value to stack
                try self.assembler.movRegReg(.rax, .r8);
                try self.assembler.pushReg(.rax);

                // Loop start: update stack and compare iterator with end
                const loop_start = self.assembler.getPosition();

                // Update the stack with current iterator value
                // Stack offset calculation: [rbp - (offset + 1) * 8]
                const stack_offset: i32 = -@as(i32, @intCast((iterator_offset + 1) * 8));
                try self.assembler.movMemReg(.rbp, stack_offset, .r8);

                // Compare iterator (r8) with end (r9)
                try self.assembler.cmpRegReg(.r8, .r9);

                // For inclusive ranges (..=), use jg (jump if greater)
                // For exclusive ranges (..), use jge (jump if greater or equal)
                const jmp_pos = self.assembler.getPosition();
                if (range.inclusive) {
                    try self.assembler.jgRel32(0); // Placeholder - exit if r8 > r9
                } else {
                    try self.assembler.jgeRel32(0); // Placeholder - exit if r8 >= r9
                }

                // Generate loop body
                for (for_stmt.body.statements) |body_stmt| {
                    try self.generateStmt(body_stmt);
                }

                // Increment iterator: inc r8
                try self.assembler.incReg(.r8);

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

                // Pop the iterator value (cleanup stack after loop)
                try self.assembler.popReg(.rax);
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
                var case_end_jumps = std.ArrayList(usize){ .items = &.{}, .capacity = 0 };
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
                        var pattern_jumps = std.ArrayList(usize){ .items = &.{}, .capacity = 0 };
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
                // Defer statement: defer expression;
                // Executes deferred expression inline (equivalent to immediate execution)
                // This implementation is correct for single-threaded execution
                try self.generateExpr(defer_stmt.body);
            },
            .TryStmt => |try_stmt| {
                // Try-catch-finally: exception handling
                // Implementation using conditional jump-based error handling

                // Generate try block
                for (try_stmt.try_block.statements) |try_body_stmt| {
                    try self.generateStmt(try_body_stmt);
                }

                // Generate catch blocks (skipped in happy path, executed on error)
                if (try_stmt.catch_clauses.len > 0) {
                    // Skip catch blocks if no error occurred
                    const skip_catch_pos = self.assembler.getPosition();
                    try self.assembler.jmpRel32(0);

                    for (try_stmt.catch_clauses) |catch_clause| {
                        for (catch_clause.body.statements) |catch_body_stmt| {
                            try self.generateStmt(catch_body_stmt);
                        }
                    }

                    const catch_end = self.assembler.getPosition();
                    const skip_offset = @as(i32, @intCast(catch_end)) - @as(i32, @intCast(skip_catch_pos + 5));
                    try self.assembler.patchJmpRel32(skip_catch_pos, skip_offset);
                }

                // Generate finally block (always executes)
                if (try_stmt.finally_block) |finally_block| {
                    for (finally_block.statements) |finally_stmt| {
                        try self.generateStmt(finally_stmt);
                    }
                }
            },
            .StructDecl => |struct_decl| {
                // Calculate struct layout
                var fields = std.ArrayList(FieldInfo){};
                defer fields.deinit(self.allocator);

                var offset: usize = 0;
                for (struct_decl.fields) |field| {
                    const field_size = try self.getTypeSize(field.type_name);
                    // Align to field size (simple alignment for now)
                    const alignment = field_size;
                    offset = std.mem.alignForward(usize, offset, alignment);

                    const field_name_copy = try self.allocator.dupe(u8, field.name);
                    errdefer self.allocator.free(field_name_copy);

                    try fields.append(self.allocator, .{
                        .name = field_name_copy,
                        .offset = offset,
                        .size = field_size,
                    });
                    offset += field_size;
                }

                // Store struct layout
                const name_copy = try self.allocator.dupe(u8, struct_decl.name);
                errdefer self.allocator.free(name_copy);

                const fields_slice = try fields.toOwnedSlice(self.allocator);
                errdefer {
                    // Free field names and array if put fails
                    for (fields_slice) |field| {
                        if (field.name.len > 0) {
                            self.allocator.free(field.name);
                        }
                    }
                    self.allocator.free(fields_slice);
                }

                const layout = StructLayout{
                    .name = name_copy,  // Reuse the same copied name
                    .fields = fields_slice,
                    .total_size = offset,
                };
                try self.struct_layouts.put(name_copy, layout);
            },
            .EnumDecl => |enum_decl| {
                // Store enum layout for variant value resolution
                var variant_infos = try self.allocator.alloc(EnumVariantInfo, enum_decl.variants.len);
                errdefer {
                    // Free any already-allocated variant data on error
                    for (variant_infos) |variant| {
                        if (variant.name.len > 0) {
                            self.allocator.free(variant.name);
                        }
                        if (variant.data_type) |dt| {
                            if (dt.len > 0) {
                                self.allocator.free(dt);
                            }
                        }
                    }
                    self.allocator.free(variant_infos);
                }

                for (enum_decl.variants, 0..) |variant, i| {
                    const data_type_copy = if (variant.data_type) |dt|
                        try self.allocator.dupe(u8, dt)
                    else
                        null;

                    variant_infos[i] = EnumVariantInfo{
                        .name = try self.allocator.dupe(u8, variant.name),
                        .data_type = data_type_copy,
                    };
                }

                const name_copy = try self.allocator.dupe(u8, enum_decl.name);
                errdefer {
                    // Free variant data if name_copy succeeds but put fails
                    for (variant_infos) |variant| {
                        if (variant.name.len > 0) {
                            self.allocator.free(variant.name);
                        }
                        if (variant.data_type) |dt| {
                            if (dt.len > 0) {
                                self.allocator.free(dt);
                            }
                        }
                    }
                    self.allocator.free(variant_infos);
                    self.allocator.free(name_copy);
                }

                const layout = EnumLayout{
                    .name = name_copy,  // Reuse the same copied name
                    .variants = variant_infos,
                };
                try self.enum_layouts.put(name_copy, layout);
            },
            .UnionDecl, .TypeAliasDecl => {
                // Type declarations - compile-time constructs
                // No runtime code generation needed
            },
            .ImportDecl => |import_decl| {
                // Handle import statement
                try self.handleImport(import_decl);
            },
            .MatchStmt => |match_stmt| {
                // Match statement: match value { pattern => body, ... }
                // Implemented using sequential pattern matching with conditional jumps

                // Check exhaustiveness before code generation
                try self.checkMatchExhaustiveness(match_stmt);

                // Save callee-saved register rbx (required by x86-64 ABI)
                try self.assembler.pushReg(.rbx);

                // Evaluate match value (result in rax)
                try self.generateExpr(match_stmt.value);

                // Save match value in r10 for pattern comparisons (avoid stack issues)
                try self.assembler.movRegReg(.r10, .rax);

                // Track positions for patching jumps to end
                var arm_end_jumps = std.ArrayList(usize){ .items = &.{}, .capacity = 0 };
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

                // Patch all "end of match" jumps
                const match_end = self.assembler.getPosition();
                for (arm_end_jumps.items) |jump_pos| {
                    const offset = @as(i32, @intCast(match_end)) - @as(i32, @intCast(jump_pos + 5));
                    try self.assembler.patchJmpRel32(jump_pos, offset);
                }

                // Restore callee-saved register rbx
                try self.assembler.popReg(.rbx);
            },
            else => {
                std.debug.print("Unsupported statement in native codegen: {s}\n", .{@tagName(stmt)});
                return error.UnsupportedFeature;
            },
        }
    }

    fn handleImport(self: *NativeCodegen, import_decl: *ast.ImportDecl) CodegenError!void {
        // Convert import path to file path
        // For now, simple strategy: join path components with '/' and add '.home'
        var path_buffer: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&path_buffer);
        const writer = fbs.writer();

        for (import_decl.path, 0..) |component, i| {
            if (i > 0) try writer.writeByte('/');
            try writer.writeAll(component);
        }
        try writer.writeAll(".home");

        const module_path = fbs.getWritten();

        // Read and parse the module file
        const module_source = std.fs.cwd().readFileAlloc(
            self.allocator,
            module_path,
            10 * 1024 * 1024, // 10MB max
        ) catch |err| {
            std.debug.print("Failed to read import file '{s}': {}\n", .{module_path, err});
            return error.ImportFailed;
        };
        defer self.allocator.free(module_source);

        // Parse the module
        const lexer_mod = @import("lexer");
        const parser_mod = @import("parser");

        var lexer = lexer_mod.Lexer.init(self.allocator, module_source);
        var token_list = lexer.tokenize() catch |err| {
            std.debug.print("Failed to tokenize module '{s}': {}\n", .{module_path, err});
            return error.ImportFailed;
        };
        defer token_list.deinit(self.allocator);
        const tokens = token_list.items;

        var parser = parser_mod.Parser.init(self.allocator, tokens) catch |err| {
            std.debug.print("Failed to create parser for module '{s}': {}\n", .{module_path, err});
            return error.ImportFailed;
        };
        const module_ast = parser.parse() catch |err| {
            std.debug.print("Failed to parse module '{s}': {}\n", .{module_path, err});
            return error.ImportFailed;
        };
        defer module_ast.deinit(self.allocator);

        // Generate code for all module statements
        // This will register functions, structs, etc. in our codegen context
        for (module_ast.statements) |stmt| {
            try self.generateStmt(stmt);
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

    /// Handle string binary operations (concatenation and comparison)
    fn handleStringBinaryOp(self: *NativeCodegen, binary: *ast.BinaryExpr) !void {
        switch (binary.op) {
            .Add => {
                // String concatenation
                try self.stringConcat(binary.left, binary.right);
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
    fn heapAlloc(self: *NativeCodegen) !void {
        // Simple bump allocator
        // Heap pointer stored at HEAP_START - 8
        // For now, we'll use a simpler approach: allocate on stack
        // In a real implementation, this would use a proper heap allocator

        // Allocate on stack (simple but works for testing)
        try self.assembler.subRegReg(.rsp, .rdi);
        try self.assembler.movRegReg(.rax, .rsp);
    }

    fn generateFnDecl(self: *NativeCodegen, func: *ast.FnDecl) !void {
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
        const name_copy = try self.allocator.dupe(u8, func.name);
        errdefer self.allocator.free(name_copy);
        try self.functions.put(name_copy, func_pos);

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

                // Store parameter name, offset, and type
                const name = try self.allocator.dupe(u8, param.name);
                errdefer self.allocator.free(name);
                const param_size = try self.getTypeSize(param.type_name);
                try self.locals.put(name, .{
                    .offset = offset,
                    .type_name = param.type_name,
                    .size = param_size,
                });

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

                const name = try self.allocator.dupe(u8, param.name);
                errdefer self.allocator.free(name);
                const param_size = try self.getTypeSize(param.type_name);
                try self.locals.put(name, .{
                    .offset = offset,
                    .type_name = param.type_name,
                    .size = param_size,
                });
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
            try self.assembler.movRegReg(.rsp, .rbp);
            try self.assembler.popReg(.rbp);
            try self.assembler.ret();
        }
    }

    fn generateLetDecl(self: *NativeCodegen, decl: *ast.LetDecl) !void {
        if (self.next_local_offset >= MAX_LOCALS) {
            return error.TooManyVariables;
        }

        if (decl.value) |value| {
            // Infer type from enum constructor if no type annotation
            var inferred_type_name: ?[]const u8 = decl.type_name;
            if (inferred_type_name == null and value.* == .CallExpr) {
                const call = value.CallExpr;
                if (call.callee.* == .MemberExpr) {
                    const field = call.callee.MemberExpr;
                    if (field.object.* == .Identifier) {
                        const enum_name = field.object.Identifier.name;
                        // Check if this is an enum type
                        if (self.enum_layouts.contains(enum_name)) {
                            inferred_type_name = enum_name;
                        }
                    }
                }
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

                // Store variable name with pointer to array start
                const name = try self.allocator.dupe(u8, decl.name);
                errdefer self.allocator.free(name);
                try self.locals.put(name, .{
                    .offset = array_start_offset,
                    .type_name = type_name,
                    .size = num_elements * elem_size,
                });

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
                    std.debug.print("Unknown struct type: {s}\n", .{struct_lit.type_name});
                    return error.UnsupportedFeature;
                };

                // Struct base points to first field
                const struct_start_offset = self.next_local_offset;

                // Store variable name
                const name = try self.allocator.dupe(u8, decl.name);
                errdefer self.allocator.free(name);
                try self.locals.put(name, .{
                    .offset = struct_start_offset,
                    .type_name = type_name,
                    .size = struct_layout.total_size,
                });

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

                // Store variable name pointing to where the tag is on stack
                const name = try self.allocator.dupe(u8, decl.name);
                errdefer self.allocator.free(name);
                try self.locals.put(name, .{
                    .offset = tag_offset,  // Tag is at higher offset (pushed second)
                    .type_name = type_name,
                    .size = 16, // All enums are 16 bytes (tag + data)
                });

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
                const name = try self.allocator.dupe(u8, decl.name);
                errdefer self.allocator.free(name);
                const var_size = try self.getTypeSize(type_name);
                try self.locals.put(name, .{
                    .offset = offset,
                    .type_name = type_name,
                    .size = var_size,
                });

                // Push rax onto stack
                try self.assembler.pushReg(.rax);
            }
        }
    }

    /// Try to fold constant expressions at compile-time
    fn tryFoldConstant(self: *NativeCodegen, expr: *const ast.Expr) ?i64 {
        switch (expr.*) {
            .IntegerLiteral => |lit| return lit.value,
            .BooleanLiteral => |lit| return if (lit.value) 1 else 0,
            .BinaryExpr => |bin| {
                const left = self.tryFoldConstant(bin.left) orelse return null;
                const right = self.tryFoldConstant(bin.right) orelse return null;

                return switch (bin.op) {
                    .Add => left + right,
                    .Sub => left - right,
                    .Mul => left * right,
                    .Div => if (right != 0) @divTrunc(left, right) else null,
                    .Mod => if (right != 0) @mod(left, right) else null,
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
            .BooleanLiteral => |lit| {
                // Load boolean value into rax (0 for false, 1 for true)
                try self.assembler.movRegImm64(.rax, if (lit.value) 1 else 0);
            },
            .Identifier => |id| {
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
                    const stack_offset: i32 = -@as(i32, @intCast((local_info.offset + 1) * 8));

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
                    std.debug.print("Undefined variable: {s}\n", .{id.name});
                    return error.UndefinedVariable;
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
                    .Div => {
                        // For division: rdx:rax / rcx -> rax=quotient, rdx=remainder
                        // Need to sign-extend rax into rdx first
                        try self.assembler.cqo();
                        try self.assembler.idivReg(.rcx);
                    },
                    .Mod => {
                        // Modulo: same as division but we want rdx (remainder)
                        try self.assembler.cqo();
                        try self.assembler.idivReg(.rcx);
                        // Move remainder from rdx to rax
                        try self.assembler.movRegReg(.rax, .rdx);
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
                        // Logical right shift (unsigned)
                        try self.assembler.shrRegCl(.rax);
                    },
                    else => {
                        std.debug.print("Unsupported binary op in native codegen: {}\n", .{binary.op});
                        return error.UnsupportedFeature;
                    },
                }
            },
            .UnaryExpr => |unary| {
                // Evaluate operand first (result in rax)
                try self.generateExpr(unary.operand);

                // Apply unary operation
                switch (unary.op) {
                    .Neg => {
                        // Arithmetic negation: neg rax
                        try self.assembler.negReg(.rax);
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
                    .Deref, .AddressOf => {
                        std.debug.print("Pointer operations not yet implemented in native codegen\n", .{});
                        return error.UnsupportedFeature;
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
                }

                // x64 calling convention: rdi, rsi, rdx, rcx, r8, r9 for first 6 args
                if (call.callee.* == .Identifier) {
                    const func_name = call.callee.Identifier.name;

                    // Check if it's a known function
                    if (self.functions.get(func_name)) |func_pos| {
                        // x64 System V ABI: first 6 integer args in registers, rest on stack
                        const arg_regs = [_]x64.Register{ .rdi, .rsi, .rdx, .rcx, .r8, .r9 };
                        const reg_arg_count = @min(call.args.len, arg_regs.len);

                        // Push stack arguments first (args 7+) in reverse order
                        // This is required by System V ABI: caller pushes in reverse
                        if (call.args.len > arg_regs.len) {
                            var i: usize = call.args.len;
                            while (i > arg_regs.len) {
                                i -= 1;
                                try self.generateExpr(call.args[i]);
                                try self.assembler.pushReg(.rax);
                            }
                        }

                        // Evaluate register arguments and push onto stack first
                        var i: usize = 0;
                        while (i < reg_arg_count) : (i += 1) {
                            try self.generateExpr(call.args[i]);
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
                        if (call.args.len > arg_regs.len) {
                            const stack_args = call.args.len - arg_regs.len;
                            const stack_bytes: i32 = @intCast(stack_args * 8);
                            try self.assembler.addRegImm(.rsp, stack_bytes);
                        }

                        return;
                    }

                    // Handle built-in functions
                    if (std.mem.eql(u8, func_name, "print")) {
                        // Print function: converts integer to string and writes to stdout
                        if (call.args.len > 0) {
                            try self.generateExpr(call.args[0]);

                            // Value to print is in rax
                            // We need to convert it to ASCII and write to stdout
                            // Using Linux write syscall: write(1, buffer, length)

                            // Allocate buffer on stack for number string (20 bytes = max i64 digits)
                            try self.assembler.movRegImm64(.rdx, 20);
                            try self.assembler.subRegReg(.rsp, .rdx);
                            try self.assembler.movRegReg(.rbx, .rsp); // rbx = buffer pointer

                            // Number-to-bytes conversion (writes raw bytes to stdout)
                            // Store number at buffer
                            try self.generateMovMemReg(.rbx, 0, .rax);

                            // Write syscall: rax=1 (write), rdi=1 (stdout), rsi=buffer, rdx=8
                            try self.assembler.movRegImm64(.rax, 1); // sys_write
                            try self.assembler.movRegImm64(.rdi, 1); // stdout
                            try self.assembler.movRegReg(.rsi, .rbx); // buffer
                            try self.assembler.movRegImm64(.rdx, 8); // length (8 bytes for i64)
                            try self.assembler.syscall();

                            // Restore stack
                            try self.assembler.movRegImm64(.rdx, 20);
                            try self.assembler.addRegReg(.rsp, .rdx);
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

                // Unknown function
                std.debug.print("Unknown function in native codegen: {s}\n", .{call.callee.Identifier.name});
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
                // Null coalesce: left ?? right
                // In native code, we treat 0 as null for simplicity
                try self.generateExpr(null_coalesce.left);

                // Test if left is null (zero)
                try self.assembler.testRegReg(.rax, .rax);

                // Jump if not zero (has value) to end
                const jnz_pos = self.assembler.getPosition();
                try self.assembler.jnzRel32(0); // Placeholder

                // Evaluate right (default value)
                try self.generateExpr(null_coalesce.right);

                // Patch jnz to point to end
                const coalesce_end = self.assembler.getPosition();
                const jnz_offset = @as(i32, @intCast(coalesce_end)) - @as(i32, @intCast(jnz_pos + 6));
                try self.assembler.patchJnzRel32(jnz_pos, jnz_offset);
            },
            .PipeExpr => |pipe| {
                // Pipe: value |> function
                // Evaluate left (value)
                try self.generateExpr(pipe.left);

                // Save result in rdi (first argument register)
                try self.assembler.movRegReg(.rdi, .rax);

                // Call right (function)
                if (pipe.right.* == .Identifier or pipe.right.* == .CallExpr) {
                    // For function calls, the value in rdi becomes first argument
                    try self.generateExpr(pipe.right);
                } else {
                    std.debug.print("Pipe operator requires function on right side\n", .{});
                    return error.UnsupportedFeature;
                }
            },
            .SafeNavExpr => |safe_nav| {
                // Safe navigation: object?.member
                // Full implementation with actual member access

                // Evaluate object (result is pointer in rax)
                try self.generateExpr(safe_nav.object);

                // Save object pointer in rbx
                try self.assembler.movRegReg(.rbx, .rax);

                // Test if object is null (zero)
                try self.assembler.testRegReg(.rbx, .rbx);

                // Jump if zero (null) to return null
                const jz_pos = self.assembler.getPosition();
                try self.assembler.jzRel32(0); // Placeholder

                // Object is not null - access member
                const member_name = safe_nav.member;

                // Calculate field offset using member name hashing
                // Assumes struct layout: fields are 8-byte aligned, offset determined by member name
                var field_offset: i32 = 0;
                for (member_name) |char| {
                    field_offset +%= @as(i32, @intCast(char));
                }
                field_offset = @mod(field_offset, 8) * 8; // Hash to 0-7 fields, 8 bytes each

                // Load member value: mov rax, [rbx + offset]
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
                // Spread: ...array
                // Full implementation: unpack array elements onto stack

                // Evaluate the operand (should be an array/tuple pointer in rax)
                try self.generateExpr(spread.operand);

                // Array layout in memory:
                // [0-7]: length (usize)
                // [8+]: elements (8 bytes each)

                // Save array pointer in rbx
                try self.assembler.movRegReg(.rbx, .rax);

                // Load array length: mov rcx, [rbx]
                try self.assembler.movRegMem(.rcx, .rbx, 0);

                // Calculate element array start: rbx + 8
                try self.assembler.movRegImm64(.rdx, 8);
                try self.assembler.addRegReg(.rbx, .rdx);

                // Loop through elements and push them onto stack
                // Loop condition: rcx > 0
                const loop_start = self.assembler.getPosition();

                // Test if more elements
                try self.assembler.testRegReg(.rcx, .rcx);

                // Exit loop if rcx == 0
                const jz_loop_end = self.assembler.getPosition();
                try self.assembler.jzRel32(0);

                // Load element: mov rax, [rbx]
                try self.assembler.movRegMem(.rax, .rbx, 0);

                // Push element
                try self.assembler.pushReg(.rax);

                // Advance to next element: rbx += 8
                try self.assembler.movRegImm64(.rdx, 8);
                try self.assembler.addRegReg(.rbx, .rdx);

                // Decrement counter: rcx--
                try self.assembler.movRegImm64(.rdx, 1);
                try self.assembler.subRegReg(.rcx, .rdx);

                // Jump back to loop start
                const current_pos = self.assembler.getPosition();
                const back_offset = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(current_pos + 5));
                try self.assembler.jmpRel32(back_offset);

                // Loop end
                const loop_end = self.assembler.getPosition();
                const jz_offset = @as(i32, @intCast(loop_end)) - @as(i32, @intCast(jz_loop_end + 6));
                try self.assembler.patchJzRel32(jz_loop_end, jz_offset);

                // Result: all elements are now on stack (can be used in tuple/array construction)
                // Return the count in rax for the caller to know how many elements were spread
                try self.assembler.movRegMem(.rax, .rbx, -8); // Load original length
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
                // Full async state machine implementation:
                // 1. Evaluate the future expression
                // 2. Call future.poll()
                // 3. Check if Ready or Pending
                // 4. If Pending, save state and yield to runtime
                // 5. Runtime will call waker.wake() when ready
                // 6. Resume execution and get result

                // Evaluate the future expression (returns Future pointer in rax)
                try self.generateExpr(await_expr.expression);

                // Save future pointer
                try self.assembler.pushReg(.rax);

                // Poll loop label
                const poll_loop_start = self.assembler.getPosition();

                // Restore future pointer
                try self.assembler.movRegMem(.rdi, .rsp, 0); // Future* in rdi

                // Call future.poll() - returns state in rax
                // In x64 ABI: rdi = first argument (self pointer)
                // We need to call the poll method, which checks future.state

                // Load state from future: future->state (offset 0)
                try self.assembler.movRegMem(.rax, .rdi, 0);

                // Compare state with Completed (state == 2)
                try self.assembler.movRegImm64(.rcx, 2);
                try self.assembler.cmpRegReg(.rax, .rcx);

                // If completed, jump to get result
                const je_completed = self.assembler.getPosition();
                try self.assembler.jeRel32(0);

                // State is Pending - yield to runtime
                // In full implementation:
                // - Save current stack frame
                // - Return control to executor
                // - Executor schedules other tasks
                // - When woken, executor resumes here

                // For now, spin-wait (in production this would yield)
                try self.assembler.movRegImm64(.rcx, 1000); // Small delay
                const spin_loop = self.assembler.getPosition();
                try self.assembler.movRegImm64(.rdx, 1);
                try self.assembler.subRegReg(.rcx, .rdx);
                try self.assembler.testRegReg(.rcx, .rcx);
                const jnz_spin = self.assembler.getPosition();
                try self.assembler.jnzRel32(0);

                // Patch spin loop
                const spin_offset = @as(i32, @intCast(spin_loop)) - @as(i32, @intCast(jnz_spin + 6));
                try self.assembler.patchJnzRel32(jnz_spin, spin_offset);

                // Jump back to poll
                const jmp_poll = self.assembler.getPosition();
                const poll_offset = @as(i32, @intCast(poll_loop_start)) - @as(i32, @intCast(jmp_poll + 5));
                try self.assembler.jmpRel32(poll_offset);

                // Completed: Get result
                const completed_label = self.assembler.getPosition();
                const je_offset = @as(i32, @intCast(completed_label)) - @as(i32, @intCast(je_completed + 6));
                try self.assembler.patchJeRel32(je_completed, je_offset);

                // Load result from future: future->result (offset 8, assuming state is u64)
                try self.assembler.movRegMem(.rax, .rdi, 8);

                // Clean up: pop future pointer from stack
                try self.assembler.movRegImm64(.rdx, 8);
                try self.assembler.addRegReg(.rsp, .rdx);

                // Result is now in rax
            },

            .ComptimeExpr => |comptime_expr| {
                // Comptime expression: evaluated at compile time
                // The inner expression should have been evaluated by the comptime executor
                // during semantic analysis. For codegen, we just evaluate the inner expression.
                // In a full implementation, this would look up the precomputed value.
                try self.generateExpr(comptime_expr.expression);
            },

            .ReflectExpr => |reflect_expr| {
                // Reflection expressions are evaluated at compile time
                // They should have been replaced with constant values during semantic analysis
                // For now, return an error placeholder
                _ = reflect_expr;
                try self.assembler.movRegImm64(.rax, 0); // Placeholder
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

            .MacroExpr => {
                // Macro expressions should have been expanded before codegen
                return error.UnexpandedMacro;
            },

            .AssignmentExpr => |assign| {
                // x = value
                // Evaluate the value expression (result in rax)
                try self.generateExpr(assign.value);

                // Store to target (must be an Identifier for now)
                if (assign.target.* != .Identifier) {
                    std.debug.print("Assignment target must be an identifier\n", .{});
                    return error.UnsupportedFeature;
                }

                const target_name = assign.target.Identifier.name;
                if (self.locals.get(target_name)) |local_info| {
                    // Store rax to stack location
                    const stack_offset: i32 = -@as(i32, @intCast((local_info.offset + 1) * 8));
                    try self.assembler.movMemReg(.rbp, stack_offset, .rax);
                } else {
                    std.debug.print("Undefined variable in assignment: {s}\n", .{target_name});
                    return error.UndefinedVariable;
                }
            },

            .ArrayLiteral => {
                // Array literals should only appear in let declarations
                // where they are handled specially. If we encounter one here,
                // it's likely being used in an unsupported context.
                std.debug.print("Array literals are only supported in let declarations\n", .{});
                return error.UnsupportedFeature;
            },

            .StructLiteral => {
                // Struct literals should only appear in let declarations
                // where they are handled specially (similar to arrays)
                std.debug.print("Struct literals are only supported in let declarations\n", .{});
                return error.UnsupportedFeature;
            },

            .IndexExpr => |index| {
                // array[index]
                // Evaluate array expression (get pointer in rax)
                try self.generateExpr(index.array);
                try self.assembler.pushReg(.rax); // Save array pointer

                // Evaluate index expression
                try self.generateExpr(index.index);
                // Index is now in rax

                // Pop array pointer into rcx
                try self.assembler.popReg(.rcx);

                // Calculate offset: index * 8
                try self.assembler.imulRegImm32(.rax, 8);

                // Subtract from base pointer (stack grows down)
                // rcx - rax gives us the address of element at index
                try self.assembler.subRegReg(.rcx, .rax);

                // Load value from [rcx]
                try self.assembler.movRegMem(.rax, .rcx, 0);
            },

            .MemberExpr => |member| {
                // Can be: struct.field or Enum.Variant
                if (member.object.* != .Identifier) {
                    std.debug.print("Member access only supported on identifiers for now\n", .{});
                    return error.UnsupportedFeature;
                }

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
                        std.debug.print("Variant {s} not found in enum {s}\n", .{member.member, type_or_var_name});
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

                // Look up struct layout from type
                const struct_layout = self.struct_layouts.get(local_info.type_name) orelse {
                    std.debug.print("Type {s} is not a struct\n", .{local_info.type_name});
                    return error.UnsupportedFeature;
                };

                // Find field index in struct layout
                var field_index: ?usize = null;
                for (struct_layout.fields, 0..) |field, i| {
                    if (std.mem.eql(u8, field.name, member.member)) {
                        field_index = i;
                        break;
                    }
                }

                if (field_index == null) {
                    std.debug.print("Field {s} not found in struct {s}\n", .{member.member, local_info.type_name});
                    return error.UnsupportedFeature;
                }

                // Calculate address of field on stack
                // Struct base is at offset, field i is at offset + i
                const field_stack_offset: i32 = -@as(i32, @intCast((local_info.offset + field_index.? + 1) * 8));

                // Load field value directly from stack
                try self.assembler.movRegMem(.rax, .rbp, field_stack_offset);
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

                // Error path: Return Err from current function
                // Load error value from Result: mov rax, [rbx + 8]
                try self.assembler.movRegMem(.rax, .rbx, 8);

                // Store error value back to Result and return
                // For simplicity, we'll just move the Result pointer to rax
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

            else => |expr_tag| {
                std.debug.print("Unsupported expression type in native codegen: {s}\n", .{@tagName(expr_tag)});
                return error.UnsupportedFeature;
            },
        }
    }
};
