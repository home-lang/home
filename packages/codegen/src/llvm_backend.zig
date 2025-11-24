const std = @import("std");
const ast = @import("ast");
const types = @import("types");
const Type = types.Type;

/// LLVM IR code generation backend
///
/// This module generates LLVM IR from the Home AST, enabling:
/// - Native code generation for multiple platforms
/// - LLVM optimization passes
/// - High-performance compiled code
/// - Interoperability with C/C++
pub const LLVMBackend = struct {
    allocator: std.mem.Allocator,
    /// Generated LLVM IR code
    ir_code: std.ArrayList(u8),
    /// Current indentation level
    indent_level: usize,
    /// Symbol table for variables
    variables: std.StringHashMap(LLVMValue),
    /// Function declarations
    functions: std.StringHashMap(LLVMFunction),
    /// Type definitions
    type_defs: std.StringHashMap([]const u8),
    /// Temporary counter for SSA form
    temp_counter: usize,
    /// Label counter for basic blocks
    label_counter: usize,

    pub const LLVMValue = struct {
        /// LLVM register/value name (e.g., %0, %result)
        name: []const u8,
        /// Type of the value
        typ: Type,
    };

    pub const LLVMFunction = struct {
        name: []const u8,
        return_type: Type,
        param_types: []const Type,
        /// LLVM function signature
        signature: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) LLVMBackend {
        return .{
            .allocator = allocator,
            .ir_code = std.ArrayList(u8).init(allocator),
            .indent_level = 0,
            .variables = std.StringHashMap(LLVMValue).init(allocator),
            .functions = std.StringHashMap(LLVMFunction).init(allocator),
            .type_defs = std.StringHashMap([]const u8).init(allocator),
            .temp_counter = 0,
            .label_counter = 0,
        };
    }

    pub fn deinit(self: *LLVMBackend) void {
        self.ir_code.deinit();
        self.variables.deinit();
        self.functions.deinit();
        self.type_defs.deinit();
    }

    /// Generate LLVM IR from an AST program
    pub fn generate(self: *LLVMBackend, program: *const ast.Program) ![]const u8 {
        // Write module header
        try self.emitLine("; ModuleID = 'home_module'");
        try self.emitLine("target datalayout = \"e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128\"");
        try self.emitLine("target triple = \"x86_64-apple-macosx13.0.0\"");
        try self.emitLine("");

        // Declare external functions (runtime/stdlib)
        try self.declareRuntimeFunctions();

        // Generate code for each statement
        for (program.statements) |stmt| {
            try self.generateStmt(stmt);
        }

        return try self.allocator.dupe(u8, self.ir_code.items);
    }

    fn declareRuntimeFunctions(self: *LLVMBackend) !void {
        // Declare printf for print statements
        try self.emitLine("declare i32 @printf(i8*, ...)");
        try self.emitLine("declare i8* @malloc(i64)");
        try self.emitLine("declare void @free(i8*)");
        try self.emitLine("");
    }

    fn generateStmt(self: *LLVMBackend, stmt: *const ast.Stmt) !void {
        switch (stmt.*) {
            .FunctionDecl => |func_decl| try self.generateFunction(func_decl),
            .StructDecl => |struct_decl| try self.generateStruct(struct_decl),
            .EnumDecl => |enum_decl| try self.generateEnum(enum_decl),
            .LetDecl => |let_decl| try self.generateLetDecl(let_decl),
            .ConstDecl => |const_decl| try self.generateConstDecl(const_decl),
            .ReturnStmt => |ret_stmt| try self.generateReturn(ret_stmt),
            .IfStmt => |if_stmt| try self.generateIf(if_stmt),
            .WhileStmt => |while_stmt| try self.generateWhile(while_stmt),
            .ForStmt => |for_stmt| try self.generateFor(for_stmt),
            .ExprStmt => |expr_stmt| try self.generateExprStmt(expr_stmt),
            .TypeAliasDecl, .TraitDecl, .ImplDecl => {}, // Type-level declarations, no codegen needed
            .ImportDecl => {}, // Handled during module resolution
            else => {}, // Other statements not yet implemented
        }
    }

    fn generateFunction(self: *LLVMBackend, func: *const ast.FunctionDecl) !void {
        // Generate function signature
        const return_llvm_type = try self.toLLVMType(func.return_type);

        try self.emit("define ");
        try self.emit(return_llvm_type);
        try self.emit(" @");
        try self.emit(func.name);
        try self.emit("(");

        // Parameters
        for (func.params, 0..) |param, i| {
            if (i > 0) try self.emit(", ");
            const param_type = try self.toLLVMType(param.type_annotation.?);
            try self.emit(param_type);
            try self.emit(" %");
            try self.emit(param.name);
        }

        try self.emitLine(") {");
        self.indent_level += 1;

        // Function body
        try self.emitLine("entry:");
        self.indent_level += 1;

        // Generate body statements
        for (func.body.statements) |stmt| {
            try self.generateStmt(stmt);
        }

        // Default return if function doesn't explicitly return
        if (func.return_type == .Void) {
            try self.emitLine("ret void");
        }

        self.indent_level -= 1;
        try self.emitLine("}");
        try self.emitLine("");
        self.indent_level -= 1;
    }

    fn generateStruct(self: *LLVMBackend, struct_decl: *const ast.StructDecl) !void {
        // Generate LLVM struct type
        try self.emit("%struct.");
        try self.emit(struct_decl.name);
        try self.emit(" = type { ");

        for (struct_decl.fields, 0..) |field, i| {
            if (i > 0) try self.emit(", ");
            const field_type = try self.toLLVMType(field.type_annotation);
            try self.emit(field_type);
        }

        try self.emitLine(" }");
        try self.emitLine("");
    }

    fn generateEnum(self: *LLVMBackend, enum_decl: *const ast.EnumDecl) !void {
        // Enums are represented as tagged unions in LLVM
        // Structure: { i32 tag, [N x i8] payload }
        // Where N is the size of the largest variant

        // First, find the largest variant payload size
        var max_size: usize = 1; // Minimum 1 byte for unit variants
        for (enum_decl.variants) |variant| {
            if (variant.value_type) |value_type| {
                const size = try self.getTypeSize(value_type);
                if (size > max_size) max_size = size;
            }
        }

        // Generate the enum type: { i32 tag, [N x i8] payload }
        try self.emit("%");
        try self.emit(enum_decl.name);
        try self.emit(" = type { i32, [");
        const size_str = try std.fmt.allocPrint(self.allocator, "{d}", .{max_size});
        defer self.allocator.free(size_str);
        try self.emit(size_str);
        try self.emitLine(" x i8] }");
        try self.emitLine("");

        // Generate constructor functions for each variant
        for (enum_decl.variants, 0..) |variant, tag| {
            try self.generateEnumConstructor(enum_decl.name, variant.name, @intCast(tag), variant.value_type, max_size);
        }
    }

    fn generateEnumConstructor(
        self: *LLVMBackend,
        enum_name: []const u8,
        variant_name: []const u8,
        tag: i32,
        value_type: ?Type,
        payload_size: usize,
    ) !void {
        // Generate a constructor function: @EnumName_VariantName(value) -> %EnumName
        try self.emit("define %");
        try self.emit(enum_name);
        try self.emit(" @");
        try self.emit(enum_name);
        try self.emit("_");
        try self.emit(variant_name);
        try self.emit("(");

        if (value_type) |val_type| {
            const llvm_type = try self.toLLVMType(val_type);
            try self.emit(llvm_type);
            try self.emit(" %value");
        }

        try self.emitLine(") {");
        try self.emitLine("entry:");

        // Allocate enum on stack
        try self.emit("  %result = alloca %");
        try self.emit(enum_name);
        try self.emitLine("");

        // Set the tag
        try self.emit("  %tag_ptr = getelementptr %");
        try self.emit(enum_name);
        try self.emit(", %");
        try self.emit(enum_name);
        try self.emitLine("* %result, i32 0, i32 0");

        const tag_str = try std.fmt.allocPrint(self.allocator, "{d}", .{tag});
        defer self.allocator.free(tag_str);
        try self.emit("  store i32 ");
        try self.emit(tag_str);
        try self.emitLine(", i32* %tag_ptr");

        // If there's a value, store it in the payload
        if (value_type) |val_type| {
            try self.emit("  %payload_ptr = getelementptr %");
            try self.emit(enum_name);
            try self.emit(", %");
            try self.emit(enum_name);
            try self.emitLine("* %result, i32 0, i32 1");

            const llvm_type = try self.toLLVMType(val_type);
            try self.emit("  %payload_cast = bitcast [");
            const size_str = try std.fmt.allocPrint(self.allocator, "{d}", .{payload_size});
            defer self.allocator.free(size_str);
            try self.emit(size_str);
            try self.emit(" x i8]* %payload_ptr to ");
            try self.emit(llvm_type);
            try self.emitLine("*");

            try self.emit("  store ");
            try self.emit(llvm_type);
            try self.emit(" %value, ");
            try self.emit(llvm_type);
            try self.emitLine("* %payload_cast");
        }

        // Load and return the enum value
        try self.emit("  %enum_val = load %");
        try self.emit(enum_name);
        try self.emit(", %");
        try self.emit(enum_name);
        try self.emitLine("* %result");
        try self.emit("  ret %");
        try self.emit(enum_name);
        try self.emitLine(" %enum_val");

        try self.emitLine("}");
        try self.emitLine("");
    }

    fn getTypeSize(self: *LLVMBackend, typ: Type) !usize {
        _ = self;
        return switch (typ) {
            .Void => 0,
            .Bool, .I8, .U8 => 1,
            .I16, .U16 => 2,
            .I32, .U32, .Int, .F32, .Float => 4,
            .I64, .U64, .F64, .Double => 8,
            .I128, .U128 => 16,
            .String, .Array, .Tuple, .Function, .Pointer, .Reference, .MutableReference => 8, // Pointers
            .Struct => |s| blk: {
                // Sum of field sizes (simplified, doesn't account for alignment)
                var total: usize = 0;
                for (s.fields) |field| {
                    total += try self.getTypeSize(field.typ);
                }
                break :blk total;
            },
            .Option => 9, // 1 byte tag + 8 bytes max payload
            .Result => 9, // 1 byte tag + 8 bytes max payload
            else => 8, // Default to pointer size
        };
    }

    /// Convert Home type to LLVM type string
    fn toLLVMType(self: *LLVMBackend, typ: Type) ![]const u8 {
        _ = self;
        return switch (typ) {
            .Void => "void",
            .Bool => "i1",
            .I8, .U8 => "i8",
            .I16, .U16 => "i16",
            .I32, .U32, .Int => "i32",
            .I64, .U64 => "i64",
            .I128, .U128 => "i128",
            .F32, .Float => "float",
            .F64 => "double",
            .String => "i8*", // Pointer to char array
            .Reference, .MutableReference => "i8*", // Generic pointer
            else => "i8*", // Default to pointer for complex types
        };
    }

    /// Generate a new temporary SSA register name
    fn newTemp(self: *LLVMBackend) ![]const u8 {
        const temp = try std.fmt.allocPrint(self.allocator, "%{d}", .{self.temp_counter});
        self.temp_counter += 1;
        return temp;
    }

    /// Generate a new basic block label
    fn newLabel(self: *LLVMBackend) ![]const u8 {
        const label = try std.fmt.allocPrint(self.allocator, "label{d}", .{self.label_counter});
        self.label_counter += 1;
        return label;
    }

    fn emit(self: *LLVMBackend, text: []const u8) !void {
        try self.ir_code.appendSlice(text);
    }

    fn emitLine(self: *LLVMBackend, text: []const u8) !void {
        // Add indentation
        for (0..self.indent_level) |_| {
            try self.ir_code.appendSlice("  ");
        }
        try self.ir_code.appendSlice(text);
        try self.ir_code.append('\n');
    }
};

/// LLVM optimization pass manager
pub const OptimizationPass = enum {
    /// Basic optimizations (mem2reg, etc.)
    O0,
    /// Moderate optimizations
    O1,
    /// Aggressive optimizations
    O2,
    /// Maximum optimizations (may increase compile time)
    O3,

    pub fn toFlags(self: OptimizationPass) []const []const u8 {
        return switch (self) {
            .O0 => &[_][]const u8{},
            .O1 => &[_][]const u8{ "-mem2reg", "-instcombine" },
            .O2 => &[_][]const u8{ "-mem2reg", "-instcombine", "-reassociate", "-gvn", "-simplifycfg" },
            .O3 => &[_][]const u8{ "-mem2reg", "-instcombine", "-reassociate", "-gvn", "-simplifycfg", "-inline", "-tailcallelim" },
        };
    }
};

/// Compile LLVM IR to native code
pub const Compiler = struct {
    allocator: std.mem.Allocator,
    optimization_level: OptimizationPass,

    pub fn init(allocator: std.mem.Allocator, optimization_level: OptimizationPass) Compiler {
        return .{
            .allocator = allocator,
            .optimization_level = optimization_level,
        };
    }

    /// Compile LLVM IR to an object file
    pub fn compileToObject(self: *Compiler, ir_code: []const u8, output_path: []const u8) !void {
        // Write IR to temporary file
        const ir_file = try std.fmt.allocPrint(self.allocator, "{s}.ll", .{output_path});
        defer self.allocator.free(ir_file);

        var file = try std.fs.cwd().createFile(ir_file, .{});
        defer file.close();
        try file.writeAll(ir_code);

        // Run LLVM tools (llc for compilation)
        // In a real implementation, we would:
        // 1. Run opt with optimization passes
        // 2. Run llc to generate object code
        // 3. Link with runtime library
        _ = self;
    }

    /// Compile and link to executable
    pub fn compileToExecutable(
        self: *Compiler,
        ir_code: []const u8,
        output_path: []const u8,
    ) !void {
        // Compile to object
        const obj_file = try std.fmt.allocPrint(self.allocator, "{s}.o", .{output_path});
        defer self.allocator.free(obj_file);

        try self.compileToObject(ir_code, obj_file);

        // Link (would use ld or lld)
        // link object file + runtime library -> executable
    }

    // Statement generation functions (placeholder implementations)

    fn generateLetDecl(self: *LLVMBackend, decl: *const ast.LetDecl) !void {
        // Allocate local variable on stack
        // For now, just emit a comment
        try self.emit("; let ");
        try self.emit(decl.name);
        try self.emitLine("");
    }

    fn generateConstDecl(self: *LLVMBackend, decl: *const ast.ConstDecl) !void {
        // Constants are typically inlined or made global
        try self.emit("; const ");
        try self.emit(decl.name);
        try self.emitLine("");
    }

    fn generateReturn(self: *LLVMBackend, ret: *const ast.ReturnStmt) !void {
        if (ret.value) |_| {
            // TODO: Generate return value expression
            try self.emitLine("; ret <value>");
        } else {
            try self.emitLine("ret void");
        }
    }

    fn generateIf(self: *LLVMBackend, if_stmt: *const ast.IfStmt) !void {
        // TODO: Generate condition, branches, labels
        try self.emitLine("; if statement");
    }

    fn generateWhile(self: *LLVMBackend, while_stmt: *const ast.WhileStmt) !void {
        // TODO: Generate loop labels and condition
        try self.emitLine("; while loop");
    }

    fn generateFor(self: *LLVMBackend, for_stmt: *const ast.ForStmt) !void {
        // TODO: Generate for loop
        try self.emitLine("; for loop");
    }

    fn generateExprStmt(self: *LLVMBackend, expr: *const ast.Expr) !void {
        // TODO: Generate expression and discard result
        try self.emitLine("; expression statement");
    }
};
