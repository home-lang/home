const std = @import("std");
const ast = @import("ast");
const diagnostics = @import("diagnostics");
const traits_mod = @import("traits");
const TraitSystem = traits_mod.TraitSystem;
const trait_checker = @import("trait_checker.zig");
pub const TraitChecker = trait_checker.TraitChecker;

/// Home's static type system with support for advanced features.
///
/// The Type union represents all possible types in the Home language, including:
/// - Primitive types (Int, Float, Bool, String, Void)
/// - Composite types (Array, Tuple, Struct, Enum, Union)
/// - Function types with parameter and return types
/// - Advanced types (Generics, Result/Either, Optional, References)
///
/// Type System Features:
/// - Static type checking with inference
/// - Algebraic data types (enums/tagged unions)
/// - Generic/parametric polymorphism
/// - Result types for error handling (Result<T, E>)
/// - Optional types for null safety (T?)
/// - Reference types for ownership tracking (&T, &mut T)
///
/// The type system integrates with the ownership checker to ensure
/// memory safety without garbage collection.
///
/// Example types:
/// - `[i32]` - Array of integers (ArrayType)
/// - `fn(i32, i32) -> i32` - Function type (FunctionType)
/// - `Result<T, E>` - Result type for error handling
/// - `T?` - Optional type (Optional)
/// - `&T` - Immutable reference (Reference)
/// - `&mut T` - Mutable reference (MutableReference)
pub const Type = union(enum) {
    /// Type variable for type inference (e.g., 'a, 'b)
    TypeVar: TypeVarInfo,
    /// Default integer type (alias for I64)
    Int,
    /// Specific integer types
    I8,
    I16,
    I32,
    I64,
    I128,
    U8,
    U16,
    U32,
    U64,
    U128,
    /// Default float type (alias for F64)
    Float,
    /// Specific float types
    F32,
    F64,
    /// Boolean true/false value
    Bool,
    /// UTF-8 encoded string
    String,
    /// Unit/void type (no value)
    Void,
    /// Homogeneous array type: [T]
    Array: ArrayType,
    /// Function type with parameters and return type
    Function: FunctionType,
    /// Product type with named fields
    Struct: StructType,
    /// Sum type with variants (algebraic data type)
    Enum: EnumType,
    /// Generic/parametric type with bounds
    Generic: GenericType,
    /// Result type for error handling: Result<T, E>
    Result: ResultType,
    /// Product type with positional fields: (T1, T2, ...)
    Tuple: TupleType,
    /// Tagged union with variants
    Union: UnionType,
    /// Optional type for null safety: T?
    Optional: *const Type,
    /// Immutable borrowed reference: &T
    Reference: *const Type,
    /// Mutable borrowed reference: &mut T
    MutableReference: *const Type,

    /// Type variable information for type inference
    pub const TypeVarInfo = struct {
        /// Unique identifier for this type variable
        id: usize,
        /// Optional name for debugging (e.g., "T", "a")
        name: ?[]const u8,
    };

    /// Homogeneous array type.
    ///
    /// Represents an array where all elements have the same type.
    /// Arrays in Home are dynamically sized at runtime.
    ///
    /// Example: `[i32]` is an array of integers
    pub const ArrayType = struct {
        /// Type of elements in the array
        element_type: *const Type,
    };

    /// Function type with parameters and return type.
    ///
    /// Represents first-class function values, including closures
    /// and function pointers. Used for type checking function calls,
    /// higher-order functions, and callbacks.
    ///
    /// Example: `fn(i32, string) -> bool`
    pub const FunctionType = struct {
        /// Parameter types (ordered)
        params: []const Type,
        /// Return type (Void for procedures)
        return_type: *const Type,
    };

    /// Struct type with named fields (product type).
    ///
    /// Represents a nominal record type with named fields. Structs
    /// are nominally typed (name-based) rather than structurally typed.
    ///
    /// Example:
    /// ```home
    /// struct Point {
    ///   x: f64,
    ///   y: f64,
    /// }
    /// ```
    pub const StructType = struct {
        /// Struct type name
        name: []const u8,
        /// Field definitions
        fields: []const Field,

        /// A single field in a struct.
        pub const Field = struct {
            /// Field name
            name: []const u8,
            /// Field type
            type: Type,
        };
    };

    /// Enum type with variants (sum type/algebraic data type).
    ///
    /// Represents a tagged union where each variant can optionally
    /// carry associated data. This is the foundation for algebraic
    /// data types and pattern matching.
    ///
    /// Examples:
    /// ```home
    /// enum Option<T> {
    ///   Some(T),
    ///   None,
    /// }
    ///
    /// enum Result<T, E> {
    ///   Ok(T),
    ///   Err(E),
    /// }
    /// ```
    pub const EnumType = struct {
        /// Enum type name
        name: []const u8,
        /// Variant definitions
        variants: []const Variant,

        /// A single variant in an enum.
        pub const Variant = struct {
            /// Variant name
            name: []const u8,
            /// Optional associated data type (null for unit variants)
            data_type: ?Type,
        };
    };

    /// Generic/parametric type with trait bounds.
    ///
    /// Represents a type parameter that can be instantiated with
    /// concrete types. Bounds specify trait requirements that
    /// the concrete type must satisfy.
    ///
    /// Example: `T: Comparable + Hashable`
    pub const GenericType = struct {
        /// Type parameter name
        name: []const u8,
        /// Trait bounds (constraints on T)
        bounds: []const Type,
    };

    /// Result type for typed error handling.
    ///
    /// Represents a computation that can either succeed with a value
    /// of type T or fail with an error of type E. This provides
    /// type-safe error handling without exceptions.
    ///
    /// Example: `Result<User, DatabaseError>`
    pub const ResultType = struct {
        /// Success value type
        ok_type: *const Type,
        /// Error value type
        err_type: *const Type,
    };

    /// Tuple type with positional fields (anonymous product type).
    ///
    /// Represents a fixed-size heterogeneous collection accessed
    /// by position rather than name. Useful for multiple return
    /// values and temporary groupings.
    ///
    /// Example: `(i32, string, bool)`
    pub const TupleType = struct {
        /// Types of tuple elements (ordered)
        element_types: []const Type,
    };

    /// Union type with variants (discriminated union).
    ///
    /// Similar to Enum but represents a structural union type.
    /// Each variant can optionally carry associated data.
    pub const UnionType = struct {
        /// Union type name
        name: []const u8,
        /// Variant definitions
        variants: []const Variant,

        /// A single variant in a union.
        pub const Variant = struct {
            /// Variant name
            name: []const u8,
            /// Optional associated data type
            data_type: ?Type,
        };
    };

    /// Check if two types are equivalent.
    ///
    /// Performs structural equality for most types, but uses nominal
    /// equality for named types (structs, enums). Generic types are
    /// compared by name and bounds.
    ///
    /// Parameters:
    ///   - self: First type to compare
    ///   - other: Second type to compare
    ///
    /// Returns: true if types are equivalent, false otherwise
    /// Resolve default types to their concrete types.
    ///
    /// Int resolves to I64, Float resolves to F64
    pub fn resolveDefault(self: Type) Type {
        return switch (self) {
            .Int => .I64,
            .Float => .F64,
            else => self,
        };
    }

    /// Check if this is a default/alias type that needs resolution.
    pub fn isDefaultType(self: Type) bool {
        return switch (self) {
            .Int, .Float => true,
            else => false,
        };
    }

    pub fn equals(self: Type, other: Type) bool {
        const self_tag = @as(std.meta.Tag(Type), self);
        const other_tag = @as(std.meta.Tag(Type), other);
        if (self_tag != other_tag) {
            return false;
        }

        return switch (self) {
            .TypeVar => |tv1| {
                const tv2 = other.TypeVar;
                return tv1.id == tv2.id;
            },
            .Int, .I8, .I16, .I32, .I64, .I128, .U8, .U16, .U32, .U64, .U128, .Float, .F32, .F64, .Bool, .String, .Void => true,
            .Array => |a1| {
                const a2 = other.Array;
                return a1.element_type.equals(a2.element_type.*);
            },
            .Function => |f1| {
                const f2 = other.Function;
                if (f1.params.len != f2.params.len) return false;
                for (f1.params, f2.params) |p1, p2| {
                    if (!p1.equals(p2)) return false;
                }
                return f1.return_type.equals(f2.return_type.*);
            },
            .Reference => |r1| r1.equals(other.Reference.*),
            .MutableReference => |r1| r1.equals(other.MutableReference.*),
            .Struct => |s1| {
                const s2 = other.Struct;
                if (!std.mem.eql(u8, s1.name, s2.name)) return false;
                if (s1.fields.len != s2.fields.len) return false;
                for (s1.fields, s2.fields) |f1, f2| {
                    if (!std.mem.eql(u8, f1.name, f2.name)) return false;
                    if (!f1.type.equals(f2.type)) return false;
                }
                return true;
            },
            .Enum => |e1| {
                const e2 = other.Enum;
                return std.mem.eql(u8, e1.name, e2.name);
            },
            .Generic => |g1| {
                const g2 = other.Generic;
                if (!std.mem.eql(u8, g1.name, g2.name)) return false;
                if (g1.bounds.len != g2.bounds.len) return false;
                for (g1.bounds, g2.bounds) |b1, b2| {
                    if (!b1.equals(b2)) return false;
                }
                return true;
            },
            .Result => |r1| {
                const r2 = other.Result;
                return r1.ok_type.equals(r2.ok_type.*) and r1.err_type.equals(r2.err_type.*);
            },
            .Tuple => |t1| {
                const t2 = other.Tuple;
                if (t1.element_types.len != t2.element_types.len) return false;
                for (t1.element_types, t2.element_types) |e1, e2| {
                    if (!e1.equals(e2)) return false;
                }
                return true;
            },
            .Union => |union1| {
                const union2 = other.Union;
                return std.mem.eql(u8, union1.name, union2.name);
            },
            .Optional => |o1| o1.equals(other.Optional.*),
        };
    }

    pub fn format(self: Type, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .Int => try writer.writeAll("int"),
            .I8 => try writer.writeAll("i8"),
            .I16 => try writer.writeAll("i16"),
            .I32 => try writer.writeAll("i32"),
            .I64 => try writer.writeAll("i64"),
            .I128 => try writer.writeAll("i128"),
            .U8 => try writer.writeAll("u8"),
            .U16 => try writer.writeAll("u16"),
            .U32 => try writer.writeAll("u32"),
            .U64 => try writer.writeAll("u64"),
            .U128 => try writer.writeAll("u128"),
            .Float => try writer.writeAll("float"),
            .F32 => try writer.writeAll("f32"),
            .F64 => try writer.writeAll("f64"),
            .Bool => try writer.writeAll("bool"),
            .String => try writer.writeAll("string"),
            .Void => try writer.writeAll("void"),
            .Function => |f| {
                try writer.writeAll("fn(");
                for (f.params, 0..) |param, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{}", .{param});
                }
                try writer.print(") -> {}", .{f.return_type.*});
            },
            .Reference => |r| try writer.print("&{}", .{r.*}),
            .MutableReference => |r| try writer.print("&mut {}", .{r.*}),
            .Result => |r| try writer.print("Result<{}, {}>", .{ r.ok_type.*, r.err_type.* }),
            .Tuple => |t| {
                try writer.writeAll("(");
                for (t.element_types, 0..) |elem, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{}", .{elem});
                }
                try writer.writeAll(")");
            },
            .Union => |u| try writer.print("union {s}", .{u.name}),
            .Optional => |o| try writer.print("{}?", .{o.*}),
            else => try writer.writeAll("<complex-type>"),
        }
    }
};

pub const TypeError = error{
    TypeMismatch,
    UndefinedVariable,
    UndefinedFunction,
    WrongNumberOfArguments,
    InvalidOperation,
    CannotInferType,
    UseAfterMove,
    MultipleMutableBorrows,
    BorrowWhileMutablyBorrowed,
    MutBorrowWhileBorrowed,
    DivisionByZero,
} || std.mem.Allocator.Error;

pub const TypeChecker = struct {
    allocator: std.mem.Allocator,
    program: *const ast.Program,
    env: TypeEnvironment,
    errors: std.ArrayList(TypeErrorInfo),
    allocated_types: std.ArrayList(*Type),
    allocated_slices: std.ArrayList([]Type),
    // ownership_tracker: ownership.OwnershipTracker, // TODO: Implement ownership tracking

    pub const TypeErrorInfo = struct {
        message: []const u8,
        loc: ast.SourceLocation,
    };

    pub fn init(allocator: std.mem.Allocator, program: *const ast.Program) TypeChecker {
        return .{
            .allocator = allocator,
            .program = program,
            .env = TypeEnvironment.init(allocator),
            .errors = std.ArrayList(TypeErrorInfo).init(allocator),
            .allocated_types = std.ArrayList(*Type).init(allocator),
            .allocated_slices = std.ArrayList([]Type).init(allocator),
            // .ownership_tracker = ownership.OwnershipTracker.init(allocator), // TODO: Implement
        };
    }

    pub fn deinit(self: *TypeChecker) void {
        self.env.deinit();
        for (self.errors.items) |err_info| {
            self.allocator.free(err_info.message);
        }
        self.errors.deinit(self.allocator);

        // Free all allocated types
        for (self.allocated_types.items) |typ| {
            self.allocator.destroy(typ);
        }
        self.allocated_types.deinit(self.allocator);

        // Free all allocated slices
        for (self.allocated_slices.items) |slice| {
            self.allocator.free(slice);
        }
        self.allocated_slices.deinit(self.allocator);

        // self.ownership_tracker.deinit();
    }

    pub fn check(self: *TypeChecker) !bool {
        // Register built-in types
        try self.registerBuiltins();

        // First pass: collect function signatures
        for (self.program.statements) |stmt| {
            if (stmt == .FnDecl) {
                try self.collectFunctionSignature(stmt.FnDecl);
            }
        }

        // Second pass: type check all statements
        for (self.program.statements) |stmt| {
            self.checkStatement(stmt) catch |err| {
                if (err != error.TypeMismatch and err != error.DivisionByZero) return err;
                // Continue checking to find more errors
            };
        }

        // Collect ownership errors into main error list
        // TODO: Implement ownership tracking
        // for (self.ownership_tracker.errors.items) |err_info| {
        //     const msg = try self.allocator.dupe(u8, err_info.message);
        //     try self.errors.append(self.allocator, .{ .message = msg, .loc = err_info.loc });
        // }

        return self.errors.items.len == 0;
    }

    fn registerBuiltins(self: *TypeChecker) !void {
        // Create static Void type for return types
        const void_type = try self.allocator.create(Type);
        errdefer self.allocator.destroy(void_type);
        void_type.* = Type.Void;
        try self.allocated_types.append(self.allocator, void_type);

        // print: fn(...) -> void
        const print_type = Type{
            .Function = .{
                .params = &[_]Type{}, // Variadic, we'll handle specially
                .return_type = void_type,
            },
        };
        try self.env.define("print", print_type);

        // assert: fn(bool) -> void
        const assert_params = try self.allocator.alloc(Type, 1);
        errdefer self.allocator.free(assert_params);
        try self.allocated_slices.append(self.allocator, assert_params);
        assert_params[0] = Type.Bool;
        const assert_type = Type{
            .Function = .{
                .params = assert_params,
                .return_type = void_type,
            },
        };
        try self.env.define("assert", assert_type);
    }

    fn collectFunctionSignature(self: *TypeChecker, fn_decl: *const ast.FnDecl) !void {
        var param_types = try self.allocator.alloc(Type, fn_decl.params.len);
        errdefer self.allocator.free(param_types);
        try self.allocated_slices.append(self.allocator, param_types);

        for (fn_decl.params, 0..) |param, i| {
            param_types[i] = try self.parseTypeName(param.type_name);
        }

        const return_type = try self.allocator.create(Type);
        errdefer self.allocator.destroy(return_type);
        try self.allocated_types.append(self.allocator, return_type);
        if (fn_decl.return_type) |rt| {
            return_type.* = try self.parseTypeName(rt);
        } else {
            return_type.* = Type.Void;
        }

        const func_type = Type{
            .Function = .{
                .params = param_types,
                .return_type = return_type,
            },
        };

        try self.env.define(fn_decl.name, func_type);
    }

    fn checkStatement(self: *TypeChecker, stmt: ast.Stmt) TypeError!void {
        switch (stmt) {
            .LetDecl => |decl| {
                if (decl.value) |value| {
                    const value_type = try self.inferExpression(value);

                    if (decl.type_name) |type_name| {
                        const declared_type = try self.parseTypeName(type_name);
                        if (!value_type.equals(declared_type)) {
                            try self.addError("Type mismatch in let declaration", decl.node.loc);
                            return error.TypeMismatch;
                        }
                    }

                    // If the value is an identifier, mark it as moved (if movable)
                    if (value.* == .Identifier) {
                        _ = value.Identifier.name;
                        // TODO: Implement ownership tracking
                        // try self.ownership_tracker.markMoved(id_name);
                    }

                    try self.env.define(decl.name, value_type);
                    // Track ownership of the new variable
                    // TODO: Implement ownership tracking
                    // try self.ownership_tracker.define(decl.name, value_type, decl.node.loc);
                } else if (decl.type_name) |type_name| {
                    const var_type = try self.parseTypeName(type_name);
                    try self.env.define(decl.name, var_type);
                    // TODO: Implement ownership tracking
                    // try self.ownership_tracker.define(decl.name, var_type, decl.node.loc);
                }
            },
            .FnDecl => |fn_decl| {
                // Create new scope for function
                var func_env = TypeEnvironment.init(self.allocator);
                func_env.parent = &self.env;
                defer func_env.deinit();

                // Add parameters to function scope
                for (fn_decl.params) |param| {
                    const param_type = try self.parseTypeName(param.type_name);
                    try func_env.define(param.name, param_type);
                }

                // Type check function body
                const saved_env = self.env;
                self.env = func_env;
                defer self.env = saved_env;

                for (fn_decl.body.statements) |body_stmt| {
                    self.checkStatement(body_stmt) catch |err| {
                        if (err != error.TypeMismatch and err != error.UndefinedVariable) {
                            return err;
                        }
                        // Continue checking to find more errors
                    };
                }
            },
            .IfStmt => |if_stmt| {
                // Check condition is boolean
                const cond_type = try self.inferExpression(if_stmt.condition);
                if (!cond_type.equals(Type.Bool)) {
                    try self.addError("If condition must be boolean", if_stmt.node.loc);
                    return error.TypeMismatch;
                }

                // Check then block
                for (if_stmt.then_block.statements) |then_stmt| {
                    self.checkStatement(then_stmt) catch |err| {
                        if (err != error.TypeMismatch and err != error.UndefinedVariable) {
                            return err;
                        }
                    };
                }

                // Check else block if present
                if (if_stmt.else_block) |else_block| {
                    for (else_block.statements) |else_stmt| {
                        self.checkStatement(else_stmt) catch |err| {
                            if (err != error.TypeMismatch and err != error.UndefinedVariable) {
                                return err;
                            }
                        };
                    }
                }
            },
            .WhileStmt => |while_stmt| {
                // Check condition is boolean
                const cond_type = try self.inferExpression(while_stmt.condition);
                if (!cond_type.equals(Type.Bool)) {
                    try self.addError("While condition must be boolean", while_stmt.node.loc);
                    return error.TypeMismatch;
                }

                // Check body
                for (while_stmt.body.statements) |body_stmt| {
                    self.checkStatement(body_stmt) catch |err| {
                        if (err != error.TypeMismatch and err != error.UndefinedVariable) {
                            return err;
                        }
                    };
                }
            },
            .ForStmt => |for_stmt| {
                // Infer the type of the iterable
                const iterable_type = try self.inferExpression(for_stmt.iterable);

                // For now, we support iterating over integers (simplified)
                // In the future, this should support arrays and other iterables

                // Create new scope for loop variable
                var loop_env = TypeEnvironment.init(self.allocator);
                loop_env.parent = &self.env;
                defer loop_env.deinit();

                // Define iterator variable with appropriate type
                // For integer iterable, iterator is int
                // For array iterable, iterator is the element type
                const iterator_type = if (iterable_type == .Array)
                    iterable_type.Array.element_type.*
                else
                    Type.Int;
                try loop_env.define(for_stmt.iterator, iterator_type);

                // Check body with loop scope
                const saved_env = self.env;
                self.env = loop_env;
                defer self.env = saved_env;

                for (for_stmt.body.statements) |body_stmt| {
                    self.checkStatement(body_stmt) catch |err| {
                        if (err != error.TypeMismatch and err != error.UndefinedVariable) {
                            return err;
                        }
                    };
                }
            },
            .StructDecl => |struct_decl| {
                // Build struct type from fields
                var fields = std.ArrayList(Type.StructType.Field){};
                defer fields.deinit(self.allocator);

                for (struct_decl.fields) |field| {
                    const field_type = try self.parseTypeName(field.type_name);
                    try fields.append(self.allocator, .{
                        .name = field.name,
                        .type = field_type,
                    });
                }

                const struct_type = Type{
                    .Struct = .{
                        .name = struct_decl.name,
                        .fields = try fields.toOwnedSlice(self.allocator),
                    },
                };

                // Register struct type in environment
                try self.env.define(struct_decl.name, struct_type);
            },
            .EnumDecl => |enum_decl| {
                // Build enum type from variants
                var variants = std.ArrayList(Type.EnumType.Variant){};
                defer variants.deinit(self.allocator);

                for (enum_decl.variants) |variant| {
                    var data_type: ?Type = null;
                    if (variant.data_type) |type_name| {
                        data_type = try self.parseTypeName(type_name);
                    }
                    try variants.append(self.allocator, .{
                        .name = variant.name,
                        .data_type = data_type,
                    });
                }

                const enum_type = Type{
                    .Enum = .{
                        .name = enum_decl.name,
                        .variants = try variants.toOwnedSlice(self.allocator),
                    },
                };

                // Register enum type in environment
                try self.env.define(enum_decl.name, enum_type);
            },
            .TypeAliasDecl => |type_alias| {
                // Resolve the target type
                const target_type = try self.parseTypeName(type_alias.target_type);

                // Register type alias in environment
                try self.env.define(type_alias.name, target_type);
            },
            .ExprStmt => |expr| {
                _ = try self.inferExpression(expr);
            },
            .DoWhileStmt => |do_while| {
                // Check body
                for (do_while.body.statements) |body_stmt| {
                    self.checkStatement(body_stmt) catch |err| {
                        if (err != error.TypeMismatch and err != error.UndefinedVariable) {
                            return err;
                        }
                    };
                }

                // Check condition is boolean
                const cond_type = try self.inferExpression(do_while.condition);
                if (!cond_type.equals(Type.Bool)) {
                    try self.addError("Do-while condition must be boolean", do_while.node.loc);
                    return error.TypeMismatch;
                }
            },
            .SwitchStmt => |switch_stmt| {
                // Infer the type of the switch value
                const value_type = try self.inferExpression(switch_stmt.value);

                // Check all case patterns and bodies
                for (switch_stmt.cases) |case_clause| {
                    // Check that patterns match the switch value type
                    if (!case_clause.is_default) {
                        for (case_clause.patterns) |pattern| {
                            const pattern_type = try self.inferExpression(pattern);
                            if (!pattern_type.equals(value_type)) {
                                try self.addError("Case pattern type must match switch value type", case_clause.node.loc);
                                return error.TypeMismatch;
                            }
                        }
                    }

                    // Check case body statements
                    for (case_clause.body) |body_stmt| {
                        self.checkStatement(body_stmt) catch |err| {
                            if (err != error.TypeMismatch and err != error.UndefinedVariable) {
                                return err;
                            }
                        };
                    }
                }
            },
            .TryStmt => |try_stmt| {
                // Check try block
                for (try_stmt.try_block.statements) |try_body_stmt| {
                    self.checkStatement(try_body_stmt) catch |err| {
                        if (err != error.TypeMismatch and err != error.UndefinedVariable) {
                            return err;
                        }
                    };
                }

                // Check catch clauses
                for (try_stmt.catch_clauses) |catch_clause| {
                    // Create new scope for error variable if present
                    if (catch_clause.error_name) |error_name| {
                        var catch_env = TypeEnvironment.init(self.allocator);
                        catch_env.parent = &self.env;
                        defer catch_env.deinit();

                        // Define error variable (type is string for now)
                        try catch_env.define(error_name, Type.String);

                        const saved_env = self.env;
                        self.env = catch_env;
                        defer self.env = saved_env;

                        for (catch_clause.body.statements) |catch_body_stmt| {
                            self.checkStatement(catch_body_stmt) catch |err| {
                                if (err != error.TypeMismatch and err != error.UndefinedVariable) {
                                    return err;
                                }
                            };
                        }
                    } else {
                        // No error variable, just check body
                        for (catch_clause.body.statements) |catch_body_stmt| {
                            self.checkStatement(catch_body_stmt) catch |err| {
                                if (err != error.TypeMismatch and err != error.UndefinedVariable) {
                                    return err;
                                }
                            };
                        }
                    }
                }

                // Check finally block if present
                if (try_stmt.finally_block) |finally_block| {
                    for (finally_block.statements) |finally_stmt| {
                        self.checkStatement(finally_stmt) catch |err| {
                            if (err != error.TypeMismatch and err != error.UndefinedVariable) {
                                return err;
                            }
                        };
                    }
                }
            },
            .DeferStmt => |defer_stmt| {
                // Check the deferred expression
                _ = try self.inferExpression(defer_stmt.body);
            },
            .UnionDecl => |union_decl| {
                // Build union type from variants
                var variants = std.ArrayList(Type.UnionType.Variant){};
                defer variants.deinit(self.allocator);

                for (union_decl.variants) |variant| {
                    var data_type: ?Type = null;
                    if (variant.type_name) |type_name| {
                        data_type = try self.parseTypeName(type_name);
                    }
                    try variants.append(self.allocator, .{
                        .name = variant.name,
                        .data_type = data_type,
                    });
                }

                const union_type = Type{
                    .Union = .{
                        .name = union_decl.name,
                        .variants = try variants.toOwnedSlice(self.allocator),
                    },
                };

                // Register union type in environment
                try self.env.define(union_decl.name, union_type);
            },
            else => {},
        }
    }

    fn inferExpression(self: *TypeChecker, expr: *const ast.Expr) TypeError!Type {
        return switch (expr.*) {
            .IntegerLiteral => Type.Int,
            .FloatLiteral => Type.Float,
            .StringLiteral => Type.String,
            .BooleanLiteral => Type.Bool,
            .ArrayLiteral => |array| try self.inferArrayLiteral(array),
            .Identifier => |id| {
                // Check ownership before use
                // TODO: Implement ownership tracking
                // self.ownership_tracker.checkUse(id.name, id.node.loc) catch |err| {
                //     if (err != error.UseAfterMove) return err;
                //     // Error already added to ownership tracker
                // };

                return self.env.get(id.name) orelse {
                    try self.addError("Undefined variable", id.node.loc);
                    return error.UndefinedVariable;
                };
            },
            .BinaryExpr => |binary| try self.inferBinaryExpression(binary),
            .CallExpr => |call| try self.inferCallExpression(call),
            .IndexExpr => |index| try self.inferIndexExpression(index),
            .SliceExpr => |slice| try self.inferSliceExpression(slice),
            .MemberExpr => |member| try self.inferMemberExpression(member),
            .TryExpr => |try_expr| try self.inferTryExpression(try_expr),
            .TernaryExpr => |ternary| try self.inferTernaryExpression(ternary),
            .NullCoalesceExpr => |null_coalesce| try self.inferNullCoalesceExpression(null_coalesce),
            .PipeExpr => |pipe| try self.inferPipeExpression(pipe),
            .SafeNavExpr => |safe_nav| try self.inferSafeNavExpression(safe_nav),
            .SpreadExpr => |spread| try self.inferSpreadExpression(spread),
            .TupleExpr => |tuple| try self.inferTupleExpression(tuple),
            else => Type.Void,
        };
    }

    fn inferBinaryExpression(self: *TypeChecker, binary: *const ast.BinaryExpr) TypeError!Type {
        const left_type = try self.inferExpression(binary.left);
        const right_type = try self.inferExpression(binary.right);

        return switch (binary.op) {
            .Add, .Sub, .Mul, .Div, .Mod => {
                // Check for division by zero at compile time
                if (binary.op == .Div or binary.op == .Mod) {
                    if (binary.right.* == .IntegerLiteral and binary.right.IntegerLiteral.value == 0) {
                        try self.addError("Division by zero", binary.node.loc);
                        return error.DivisionByZero;
                    } else if (binary.right.* == .FloatLiteral and binary.right.FloatLiteral.value == 0.0) {
                        try self.addError("Division by zero", binary.node.loc);
                        return error.DivisionByZero;
                    }
                }

                if (left_type.equals(Type.Int) and right_type.equals(Type.Int)) {
                    return Type.Int;
                } else if (left_type.equals(Type.Float) or right_type.equals(Type.Float)) {
                    return Type.Float;
                } else {
                    try self.addError("Arithmetic operation requires numeric types", binary.node.loc);
                    return error.TypeMismatch;
                }
            },
            .Equal, .NotEqual, .Less, .LessEq, .Greater, .GreaterEq => Type.Bool,
            .And, .Or => {
                if (!left_type.equals(Type.Bool) or !right_type.equals(Type.Bool)) {
                    try self.addError("Logical operation requires boolean types", binary.node.loc);
                    return error.TypeMismatch;
                }
                return Type.Bool;
            },
            .BitAnd, .BitOr, .BitXor, .LeftShift, .RightShift => {
                if (!left_type.equals(Type.Int) or !right_type.equals(Type.Int)) {
                    try self.addError("Bitwise operation requires integer types", binary.node.loc);
                    return error.TypeMismatch;
                }
                return Type.Int;
            },
            else => Type.Void,
        };
    }

    fn inferCallExpression(self: *TypeChecker, call: *const ast.CallExpr) TypeError!Type {
        if (call.callee.* == .Identifier) {
            const func_name = call.callee.Identifier.name;
            const func_type = self.env.get(func_name) orelse {
                try self.addError("Undefined function", call.node.loc);
                return error.UndefinedFunction;
            };

            if (func_type == .Function) {
                // Check argument types
                const expected_params = func_type.Function.params;

                // Special case for print (variadic)
                if (!std.mem.eql(u8, func_name, "print")) {
                    if (call.args.len != expected_params.len) {
                        try self.addError("Wrong number of arguments", call.node.loc);
                        return error.WrongNumberOfArguments;
                    }

                    for (call.args, 0..) |arg, i| {
                        const arg_type = try self.inferExpression(arg);
                        if (!arg_type.equals(expected_params[i])) {
                            try self.addError("Argument type mismatch", call.node.loc);
                            return error.TypeMismatch;
                        }
                    }
                }

                return func_type.Function.return_type.*;
            }
        }

        return Type.Void;
    }

    fn inferTryExpression(self: *TypeChecker, try_expr: *const ast.TryExpr) TypeError!Type {
        const operand_type = try self.inferExpression(try_expr.operand);

        // The operand must be a Result<T, E> type
        if (operand_type != .Result) {
            try self.addError("Try operator (?) can only be used on Result types", try_expr.node.loc);
            return error.TypeMismatch;
        }

        // The try operator unwraps the Ok value, or propagates the error
        // So the type of `expr?` is T from Result<T, E>
        return operand_type.Result.ok_type.*;
    }

    fn inferArrayLiteral(self: *TypeChecker, array: *const ast.ArrayLiteral) TypeError!Type {
        if (array.elements.len == 0) {
            // Empty array - we'll infer type from context or default to void array
            // For now, return an array of void (not very useful, but valid)
            const elem_type = try self.allocator.create(Type);
            errdefer self.allocator.destroy(elem_type);
            elem_type.* = Type.Void;
            try self.allocated_types.append(self.allocator, elem_type);
            return Type{ .Array = .{ .element_type = elem_type } };
        }

        // Infer type from first element
        const first_type = try self.inferExpression(array.elements[0]);

        // Check all elements have the same type
        for (array.elements[1..]) |elem| {
            const elem_type = try self.inferExpression(elem);
            if (!first_type.equals(elem_type)) {
                try self.addError("Array elements must all have the same type", array.node.loc);
                return error.TypeMismatch;
            }
        }

        // Create array type with element type
        const elem_type = try self.allocator.create(Type);
        errdefer self.allocator.destroy(elem_type);
        elem_type.* = first_type;
        try self.allocated_types.append(self.allocator, elem_type);
        return Type{ .Array = .{ .element_type = elem_type } };
    }

    fn inferIndexExpression(self: *TypeChecker, index: *const ast.IndexExpr) TypeError!Type {
        const array_type = try self.inferExpression(index.array);
        const index_type = try self.inferExpression(index.index);

        // Index must be an integer
        if (!index_type.equals(Type.Int)) {
            try self.addError("Array index must be an integer", index.node.loc);
            return error.TypeMismatch;
        }

        // Array must be an array type
        if (array_type != .Array) {
            try self.addError("Cannot index non-array type", index.node.loc);
            return error.TypeMismatch;
        }

        // Return the element type
        return array_type.Array.element_type.*;
    }

    fn inferSliceExpression(self: *TypeChecker, slice: *const ast.SliceExpr) TypeError!Type {
        const array_type = try self.inferExpression(slice.array);

        // Check start index if present
        if (slice.start) |start| {
            const start_type = try self.inferExpression(start);
            if (!start_type.equals(Type.Int)) {
                try self.addError("Slice start index must be an integer", slice.node.loc);
                return error.TypeMismatch;
            }
        }

        // Check end index if present
        if (slice.end) |end| {
            const end_type = try self.inferExpression(end);
            if (!end_type.equals(Type.Int)) {
                try self.addError("Slice end index must be an integer", slice.node.loc);
                return error.TypeMismatch;
            }
        }

        // Array must be an array type
        if (array_type != .Array) {
            try self.addError("Cannot slice non-array type", slice.node.loc);
            return error.TypeMismatch;
        }

        // Slicing an array returns an array of the same element type
        return array_type;
    }

    fn inferMemberExpression(self: *TypeChecker, member: *const ast.MemberExpr) TypeError!Type {
        const object_type = try self.inferExpression(member.object);

        // Object must be a struct type
        if (object_type != .Struct) {
            try self.addError("Cannot access member of non-struct type", member.node.loc);
            return error.TypeMismatch;
        }

        // Find the field in the struct
        for (object_type.Struct.fields) |field| {
            if (std.mem.eql(u8, field.name, member.member)) {
                return field.type;
            }
        }

        // Field not found
        const err_msg = try std.fmt.allocPrint(
            self.allocator,
            "Struct '{s}' has no field '{s}'",
            .{ object_type.Struct.name, member.member },
        );
        try self.addError(err_msg, member.node.loc);
        self.allocator.free(err_msg);
        return error.TypeMismatch;
    }

    fn inferTernaryExpression(self: *TypeChecker, ternary: *const ast.TernaryExpr) TypeError!Type {
        // Check condition is boolean
        const cond_type = try self.inferExpression(ternary.condition);
        if (!cond_type.equals(Type.Bool)) {
            try self.addError("Ternary condition must be boolean", ternary.node.loc);
            return error.TypeMismatch;
        }

        // Both branches must have the same type
        const true_type = try self.inferExpression(ternary.true_val);
        const false_type = try self.inferExpression(ternary.false_val);

        if (!true_type.equals(false_type)) {
            try self.addError("Ternary branches must have the same type", ternary.node.loc);
            return error.TypeMismatch;
        }

        return true_type;
    }

    fn inferNullCoalesceExpression(self: *TypeChecker, null_coalesce: *const ast.NullCoalesceExpr) TypeError!Type {
        const left_type = try self.inferExpression(null_coalesce.left);
        const right_type = try self.inferExpression(null_coalesce.right);

        // Left side should be Optional type, but we'll be permissive and allow any type
        // Right side must be compatible with the unwrapped left type
        if (left_type == .Optional) {
            const inner_type = left_type.Optional.*;
            if (!inner_type.equals(right_type)) {
                try self.addError("Null coalesce default value must match optional type", null_coalesce.node.loc);
                return error.TypeMismatch;
            }
            return right_type;
        }

        // If left is not optional, just return its type (it will never be null)
        return left_type;
    }

    fn inferPipeExpression(self: *TypeChecker, pipe: *const ast.PipeExpr) TypeError!Type {
        // Infer type of left expression (the value being piped)
        const left_type = try self.inferExpression(pipe.left);

        // Right side should be a function that takes left_type as its first argument
        const right_type = try self.inferExpression(pipe.right);

        if (right_type == .Function) {
            const func_type = right_type.Function;

            // Function should have at least one parameter
            if (func_type.params.len == 0) {
                try self.addError("Pipe target function must have at least one parameter", pipe.node.loc);
                return error.TypeMismatch;
            }

            // First parameter should match left type
            if (!func_type.params[0].equals(left_type)) {
                try self.addError("Pipe type mismatch: function parameter doesn't match piped value", pipe.node.loc);
                return error.TypeMismatch;
            }

            // Return the function's return type
            return func_type.return_type.*;
        }

        try self.addError("Pipe right side must be a function", pipe.node.loc);
        return error.TypeMismatch;
    }

    fn inferSafeNavExpression(self: *TypeChecker, safe_nav: *const ast.SafeNavExpr) TypeError!Type {
        const object_type = try self.inferExpression(safe_nav.object);

        // Object can be Optional<Struct> or just Struct
        var actual_type = object_type;
        if (object_type == .Optional) {
            actual_type = object_type.Optional.*;
        }

        // Actual type must be a struct
        if (actual_type != .Struct) {
            try self.addError("Safe navigation can only be used on struct types", safe_nav.node.loc);
            return error.TypeMismatch;
        }

        // Find the field in the struct
        for (actual_type.Struct.fields) |field| {
            if (std.mem.eql(u8, field.name, safe_nav.member)) {
                // Return the field type wrapped in Optional
                const field_type_ptr = try self.allocator.create(Type);
                errdefer self.allocator.destroy(field_type_ptr);
                field_type_ptr.* = field.type;
                try self.allocated_types.append(self.allocator, field_type_ptr);
                return Type{ .Optional = field_type_ptr };
            }
        }

        // Field not found
        const err_msg = try std.fmt.allocPrint(
            self.allocator,
            "Struct '{s}' has no field '{s}'",
            .{ actual_type.Struct.name, safe_nav.member },
        );
        errdefer self.allocator.free(err_msg);
        try self.addError(err_msg, safe_nav.node.loc);
        self.allocator.free(err_msg);
        return error.TypeMismatch;
    }

    fn inferSpreadExpression(self: *TypeChecker, spread: *const ast.SpreadExpr) TypeError!Type {
        const operand_type = try self.inferExpression(spread.operand);

        // Spread can only be used on array or tuple types
        if (operand_type != .Array and operand_type != .Tuple) {
            try self.addError("Spread operator can only be used on arrays or tuples", spread.node.loc);
            return error.TypeMismatch;
        }

        // Return the same type (spread doesn't change the type, just unpacks it)
        return operand_type;
    }

    fn inferTupleExpression(self: *TypeChecker, tuple: *const ast.TupleExpr) TypeError!Type {
        if (tuple.elements.len == 0) {
            // Empty tuple ()
            return Type{ .Tuple = .{ .element_types = &.{} } };
        }

        // Infer types of all elements
        var element_types = try self.allocator.alloc(Type, tuple.elements.len);
        errdefer self.allocator.free(element_types);
        try self.allocated_slices.append(self.allocator, element_types);

        for (tuple.elements, 0..) |elem, i| {
            element_types[i] = try self.inferExpression(elem);
        }

        return Type{ .Tuple = .{ .element_types = element_types } };
    }

    fn parseTypeName(self: *TypeChecker, name: []const u8) !Type {
        // Built-in primitive types
        if (std.mem.eql(u8, name, "int")) return Type.Int;
        if (std.mem.eql(u8, name, "i8")) return Type.I8;
        if (std.mem.eql(u8, name, "i16")) return Type.I16;
        if (std.mem.eql(u8, name, "i32")) return Type.I32;
        if (std.mem.eql(u8, name, "i64")) return Type.I64;
        if (std.mem.eql(u8, name, "i128")) return Type.I128;
        if (std.mem.eql(u8, name, "u8")) return Type.U8;
        if (std.mem.eql(u8, name, "u16")) return Type.U16;
        if (std.mem.eql(u8, name, "u32")) return Type.U32;
        if (std.mem.eql(u8, name, "u64")) return Type.U64;
        if (std.mem.eql(u8, name, "u128")) return Type.U128;
        if (std.mem.eql(u8, name, "float")) return Type.Float;
        if (std.mem.eql(u8, name, "f32")) return Type.F32;
        if (std.mem.eql(u8, name, "f64")) return Type.F64;
        if (std.mem.eql(u8, name, "bool")) return Type.Bool;
        if (std.mem.eql(u8, name, "string")) return Type.String;
        if (std.mem.eql(u8, name, "str")) return Type.String; // Allow both string and str
        if (std.mem.eql(u8, name, "void")) return Type.Void;

        // Check if it's a reference type
        if (std.mem.startsWith(u8, name, "&mut ")) {
            const inner_type_name = name[5..];
            const inner_type = try self.parseTypeName(inner_type_name);
            const inner_ptr = try self.allocator.create(Type);
            errdefer self.allocator.destroy(inner_ptr);
            inner_ptr.* = inner_type;
            try self.allocated_types.append(self.allocator, inner_ptr);
            return Type{ .MutableReference = inner_ptr };
        }

        if (std.mem.startsWith(u8, name, "&")) {
            const inner_type_name = name[1..];
            const inner_type = try self.parseTypeName(inner_type_name);
            const inner_ptr = try self.allocator.create(Type);
            errdefer self.allocator.destroy(inner_ptr);
            inner_ptr.* = inner_type;
            try self.allocated_types.append(self.allocator, inner_ptr);
            return Type{ .Reference = inner_ptr };
        }

        // Check if it's a generic type (e.g., "Result<T, E>", "Vec<T>")
        if (std.mem.indexOf(u8, name, "<")) |angle_start| {
            const base_name = name[0..angle_start];
            if (std.mem.eql(u8, base_name, "Result")) {
                // Parse Result<T, E>
                // For now, return a generic Result type
                // Full implementation would parse the generic parameters
                const ok_type = try self.allocator.create(Type);
                errdefer self.allocator.destroy(ok_type);
                ok_type.* = Type.Void;
                try self.allocated_types.append(self.allocator, ok_type);

                const err_type = try self.allocator.create(Type);
                errdefer self.allocator.destroy(err_type);
                err_type.* = Type.Void;
                try self.allocated_types.append(self.allocator, err_type);

                return Type{ .Result = .{
                    .ok_type = ok_type,
                    .err_type = err_type,
                } };
            }
        }

        // Try to look up user-defined types from environment (type aliases, structs, enums)
        if (self.env.get(name)) |user_type| {
            return user_type;
        }

        // Unknown type - for now, treat as void
        return Type.Void;
    }

    fn addError(self: *TypeChecker, message: []const u8, loc: ast.SourceLocation) !void {
        const msg = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(msg);
        try self.errors.append(self.allocator, .{ .message = msg, .loc = loc });
    }
};

pub const TypeEnvironment = struct {
    bindings: std.StringHashMap(Type),
    parent: ?*TypeEnvironment,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TypeEnvironment {
        return .{
            .bindings = std.StringHashMap(Type).init(allocator),
            .parent = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TypeEnvironment) void {
        var it = self.bindings.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.bindings.deinit();
    }

    pub fn define(self: *TypeEnvironment, name: []const u8, typ: Type) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        try self.bindings.put(name_copy, typ);
    }

    pub fn get(self: *TypeEnvironment, name: []const u8) ?Type {
        if (self.bindings.get(name)) |typ| {
            return typ;
        }
        if (self.parent) |parent| {
            return parent.get(name);
        }
        return null;
    }
};
