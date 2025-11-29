const std = @import("std");
const ast = @import("ast");
const parser_mod = @import("parser");
const Parser = parser_mod.Parser;
const ModuleResolver = parser_mod.module_resolver.ModuleResolver;
const Lexer = @import("lexer").Lexer;
const diagnostics = @import("diagnostics");
const traits_mod = @import("traits");
const TraitSystem = traits_mod.TraitSystem;
const trait_checker = @import("trait_checker.zig");
pub const TraitChecker = trait_checker.TraitChecker;
const comptime_mod = @import("comptime");
const ComptimeIntegration = comptime_mod.integration.ComptimeIntegration;
const ComptimeValueStore = comptime_mod.integration.ComptimeValueStore;
const ownership = @import("ownership.zig");
pub const OwnershipTracker = ownership.OwnershipTracker;
pub const OwnershipState = ownership.OwnershipState;
const pattern_checker = @import("pattern_checker.zig");
pub const PatternChecker = pattern_checker.PatternChecker;
pub const PatternMatcher = pattern_checker.PatternMatcher;
const error_handling = @import("error_handling.zig");
pub const ErrorHandler = error_handling.ErrorHandler;
pub const ErrorConversion = error_handling.ErrorConversion;
pub const ResultUtils = error_handling.ResultUtils;
const generics_mod = @import("generics.zig");
pub const GenericHandler = generics_mod.GenericHandler;
pub const TypeParameter = generics_mod.TypeParameter;
pub const GenericUtils = generics_mod.GenericUtils;

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
        /// Number of required parameters (without default values)
        /// If null, all parameters are required (for backwards compatibility)
        required_params: ?usize = null,
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

    pub fn format(self: Type, comptime fmt: []const u8, options: anytype, writer: anytype) !void {
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
                    try writer.print("{any}", .{param});
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
                    try writer.print("{any}", .{elem});
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
    comptime_store: ?*ComptimeValueStore,
    ownership_tracker: OwnershipTracker,
    pattern_checker: PatternChecker,
    error_handler: ErrorHandler,
    /// Source file path for resolving imports
    source_path: ?[]const u8,
    /// Loaded module cache to avoid re-parsing
    loaded_modules: std.StringHashMap(bool),

    pub const TypeErrorInfo = struct {
        message: []const u8,
        loc: ast.SourceLocation,
        // Enhanced error information
        expected: ?[]const u8 = null,
        actual: ?[]const u8 = null,
        suggestion: ?[]const u8 = null,
        context: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator, program: *const ast.Program) TypeChecker {
        return .{
            .allocator = allocator,
            .program = program,
            .env = TypeEnvironment.init(allocator),
            .errors = std.ArrayList(TypeErrorInfo){},
            .allocated_types = std.ArrayList(*Type){},
            .allocated_slices = std.ArrayList([]Type){},
            .comptime_store = null,
            .ownership_tracker = OwnershipTracker.init(allocator),
            .pattern_checker = PatternChecker.init(allocator),
            .error_handler = ErrorHandler.init(allocator),
            .source_path = null,
            .loaded_modules = std.StringHashMap(bool).init(allocator),
        };
    }

    /// Initialize with source path for import resolution
    pub fn initWithSourcePath(allocator: std.mem.Allocator, program: *const ast.Program, source_path: []const u8) TypeChecker {
        var checker = init(allocator, program);
        checker.source_path = source_path;
        return checker;
    }

    /// Initialize with comptime support
    pub fn initWithComptime(allocator: std.mem.Allocator, program: *const ast.Program, comptime_store: *ComptimeValueStore) TypeChecker {
        var checker = init(allocator, program);
        checker.comptime_store = comptime_store;
        return checker;
    }

    pub fn deinit(self: *TypeChecker) void {
        self.env.deinit();
        for (self.errors.items) |err_info| {
            self.allocator.free(err_info.message);
            if (err_info.expected) |expected| self.allocator.free(expected);
            if (err_info.actual) |actual| self.allocator.free(actual);
            if (err_info.suggestion) |suggestion| self.allocator.free(suggestion);
            if (err_info.context) |context| self.allocator.free(context);
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

        self.ownership_tracker.deinit();
        self.pattern_checker.deinit();
        self.error_handler.deinit();
        self.loaded_modules.deinit();
    }

    pub fn check(self: *TypeChecker) !bool {
        // Register built-in types
        try self.registerBuiltins();

        // Evaluate comptime expressions if store provided
        if (self.comptime_store) |store| {
            if (ComptimeIntegration.init(self.allocator, store)) |integration_value| {
                var integration = integration_value;
                defer integration.deinit();
                // Process all comptime expressions in the program
                integration.processProgram(@constCast(self.program)) catch |err| {
                    std.debug.print("Warning: comptime evaluation failed: {}\n", .{err});
                };
            } else |err| {
                // If comptime init fails, continue without comptime support
                std.debug.print("Warning: comptime initialization failed: {}\n", .{err});
                self.comptime_store = null;
            }
        }

        // First pass: process imports and collect module-level declarations
        for (self.program.statements) |stmt| {
            switch (stmt) {
                .ImportDecl => |import_decl| {
                    // Process import to register imported types
                    self.processImport(import_decl) catch |err| {
                        // Log import error but continue checking
                        if (err == error.OutOfMemory) return err;
                        // Other errors are logged as warnings
                    };
                },
                .FnDecl => |fn_decl| {
                    try self.collectFunctionSignature(fn_decl);
                },
                .LetDecl => |decl| {
                    // Module-level let declaration - register in environment
                    if (decl.value) |value| {
                        const value_type = if (decl.type_name) |type_name|
                            try self.parseTypeName(type_name)
                        else
                            try self.inferExpression(value);
                        try self.env.define(decl.name, value_type);
                    } else if (decl.type_name) |type_name| {
                        const var_type = try self.parseTypeName(type_name);
                        try self.env.define(decl.name, var_type);
                    }
                },
                .StructDecl => |struct_decl| {
                    // Pre-register struct type
                    var fields = std.ArrayList(Type.StructType.Field){};
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
                    try self.env.define(struct_decl.name, struct_type);
                },
                .EnumDecl => |enum_decl| {
                    // Pre-register enum type
                    var variants = std.ArrayList(Type.EnumType.Variant){};
                    for (enum_decl.variants) |variant| {
                        var data_type_val: ?Type = null;
                        if (variant.data_type) |type_name| {
                            data_type_val = try self.parseTypeName(type_name);
                        }
                        try variants.append(self.allocator, .{
                            .name = variant.name,
                            .data_type = data_type_val,
                        });
                    }
                    const enum_type = Type{
                        .Enum = .{
                            .name = enum_decl.name,
                            .variants = try variants.toOwnedSlice(self.allocator),
                        },
                    };
                    try self.env.define(enum_decl.name, enum_type);
                },
                else => {},
            }
        }

        // Second pass: type check all statements
        for (self.program.statements) |stmt| {
            self.checkStatement(stmt) catch |err| {
                // Only fail on allocation errors, not type errors
                // Continue checking to find more errors for type-related errors
                switch (err) {
                    error.OutOfMemory => return err,
                    else => {}, // Continue checking to find more errors
                }
            };
        }

        // Collect ownership errors into main error list
        for (self.ownership_tracker.errors.items) |err_info| {
            const msg = try self.allocator.dupe(u8, err_info.message);
            try self.errors.append(self.allocator, .{ .message = msg, .loc = err_info.loc });
        }

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

        // Count required parameters (those without default values)
        var required_params: usize = 0;
        for (fn_decl.params, 0..) |param, i| {
            param_types[i] = try self.parseTypeName(param.type_name);
            if (param.default_value == null) {
                required_params += 1;
            }
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
                .required_params = required_params,
            },
        };

        try self.env.define(fn_decl.name, func_type);
    }

    /// Process an import declaration by loading and parsing the imported module
    /// and registering the imported types/functions in the current environment
    fn processImport(self: *TypeChecker, import_decl: *const ast.ImportDecl) !void {
        // Build module path key for caching
        var path_key = std.ArrayList(u8){};
        defer path_key.deinit(self.allocator);
        for (import_decl.path, 0..) |segment, i| {
            if (i > 0) try path_key.append(self.allocator, '/');
            try path_key.appendSlice(self.allocator, segment);
        }

        // Check if already loaded
        if (self.loaded_modules.contains(path_key.items)) {
            return;
        }

        // Resolve module file path
        const file_path = self.resolveModulePath(import_decl.path) catch |err| {
            // Module not found - register imported names as unknown types to allow checking to continue
            if (import_decl.imports) |imports| {
                for (imports) |import_name| {
                    // Register as a placeholder struct type so type checking can continue
                    const struct_type = Type{
                        .Struct = .{
                            .name = import_name,
                            .fields = &[_]Type.StructType.Field{},
                        },
                    };
                    self.env.define(import_name, struct_type) catch {};
                }
            }
            return err;
        };
        defer self.allocator.free(file_path);

        // Mark as loaded to prevent circular imports
        const key_copy = try self.allocator.dupe(u8, path_key.items);
        try self.loaded_modules.put(key_copy, true);

        // Read the module source file
        const source = std.fs.cwd().readFileAlloc(file_path, self.allocator, std.Io.Limit.unlimited) catch |err| {
            // File read error - register imported names as placeholder types
            if (import_decl.imports) |imports| {
                for (imports) |import_name| {
                    const struct_type = Type{
                        .Struct = .{
                            .name = import_name,
                            .fields = &[_]Type.StructType.Field{},
                        },
                    };
                    self.env.define(import_name, struct_type) catch {};
                }
            }
            return err;
        };
        defer self.allocator.free(source);

        // Tokenize
        var lexer = Lexer.init(self.allocator, source);
        var tokens = lexer.tokenize() catch |err| {
            if (import_decl.imports) |imports| {
                for (imports) |import_name| {
                    const struct_type = Type{
                        .Struct = .{
                            .name = import_name,
                            .fields = &[_]Type.StructType.Field{},
                        },
                    };
                    self.env.define(import_name, struct_type) catch {};
                }
            }
            return err;
        };
        defer tokens.deinit(self.allocator);

        // Parse
        var parser = Parser.init(self.allocator, tokens.items) catch |err| {
            if (import_decl.imports) |imports| {
                for (imports) |import_name| {
                    const struct_type = Type{
                        .Struct = .{
                            .name = import_name,
                            .fields = &[_]Type.StructType.Field{},
                        },
                    };
                    self.env.define(import_name, struct_type) catch {};
                }
            }
            return err;
        };

        const program = parser.parse() catch |err| {
            if (import_decl.imports) |imports| {
                for (imports) |import_name| {
                    const struct_type = Type{
                        .Struct = .{
                            .name = import_name,
                            .fields = &[_]Type.StructType.Field{},
                        },
                    };
                    self.env.define(import_name, struct_type) catch {};
                }
            }
            return err;
        };

        // Extract imported types from the module
        const imported_names: ?[]const []const u8 = import_decl.imports;

        // Collect all exported types from the module
        for (program.statements) |stmt| {
            switch (stmt) {
                .StructDecl => |struct_decl| {
                    // Check if this struct is in the import list (or if no specific imports, import all)
                    const should_import = if (imported_names) |names| blk: {
                        for (names) |name| {
                            if (std.mem.eql(u8, name, struct_decl.name)) {
                                break :blk true;
                            }
                        }
                        break :blk false;
                    } else true;

                    if (should_import) {
                        // Build struct type and register it
                        var fields = std.ArrayList(Type.StructType.Field){};
                        for (struct_decl.fields) |field| {
                            const field_type = self.parseTypeName(field.type_name) catch Type.Void;
                            // Duplicate field name to outlive parser memory
                            const field_name_copy = self.allocator.dupe(u8, field.name) catch continue;
                            fields.append(self.allocator, .{
                                .name = field_name_copy,
                                .type = field_type,
                            }) catch {};
                        }
                        // Duplicate struct name to outlive parser memory
                        const struct_name_copy = self.allocator.dupe(u8, struct_decl.name) catch continue;
                        const struct_type = Type{
                            .Struct = .{
                                .name = struct_name_copy,
                                .fields = fields.toOwnedSlice(self.allocator) catch &[_]Type.StructType.Field{},
                            },
                        };
                        self.env.define(struct_name_copy, struct_type) catch {};
                    }
                },
                .EnumDecl => |enum_decl| {
                    const should_import = if (imported_names) |names| blk: {
                        for (names) |name| {
                            if (std.mem.eql(u8, name, enum_decl.name)) {
                                break :blk true;
                            }
                        }
                        break :blk false;
                    } else true;

                    if (should_import) {
                        var variants = std.ArrayList(Type.EnumType.Variant){};
                        for (enum_decl.variants) |variant| {
                            var data_type_val: ?Type = null;
                            if (variant.data_type) |type_name| {
                                data_type_val = self.parseTypeName(type_name) catch null;
                            }
                            // Duplicate variant name to outlive parser memory
                            const variant_name_copy = self.allocator.dupe(u8, variant.name) catch continue;
                            variants.append(self.allocator, .{
                                .name = variant_name_copy,
                                .data_type = data_type_val,
                            }) catch {};
                        }
                        // Duplicate enum name to outlive parser memory
                        const enum_name_copy = self.allocator.dupe(u8, enum_decl.name) catch continue;
                        const enum_type = Type{
                            .Enum = .{
                                .name = enum_name_copy,
                                .variants = variants.toOwnedSlice(self.allocator) catch &[_]Type.EnumType.Variant{},
                            },
                        };
                        self.env.define(enum_name_copy, enum_type) catch {};
                    }
                },
                .FnDecl => |fn_decl| {
                    const should_import = if (imported_names) |names| blk: {
                        for (names) |name| {
                            if (std.mem.eql(u8, name, fn_decl.name)) {
                                break :blk true;
                            }
                        }
                        break :blk false;
                    } else true;

                    if (should_import) {
                        // Build function type and register it
                        self.collectFunctionSignature(fn_decl) catch {};
                    }
                },
                else => {},
            }
        }
    }

    /// Resolve module path to file path
    fn resolveModulePath(self: *TypeChecker, path_segments: []const []const u8) ![]const u8 {
        // Build path from segments
        var path_buf = std.ArrayList(u8){};
        defer path_buf.deinit(self.allocator);

        // Get source root directory from source_path
        var source_root: []const u8 = ".";
        if (self.source_path) |sp| {
            if (std.mem.lastIndexOf(u8, sp, "/")) |last_slash| {
                const dir = sp[0..last_slash];
                // Check if we're in src/ - handle both "src/..." and ".../src/..."
                if (std.mem.indexOf(u8, dir, "/src")) |src_pos| {
                    source_root = dir[0..src_pos];
                } else if (std.mem.startsWith(u8, dir, "src")) {
                    // Relative path like "src/engine" - source_root is "."
                    source_root = ".";
                } else {
                    source_root = dir;
                }
            }
        }

        // Try src/ directory first
        try path_buf.appendSlice(self.allocator, source_root);
        try path_buf.appendSlice(self.allocator, "/src/");
        for (path_segments, 0..) |segment, i| {
            if (i > 0) try path_buf.append(self.allocator, '/');
            try path_buf.appendSlice(self.allocator, segment);
        }
        try path_buf.appendSlice(self.allocator, ".home");

        // Check if file exists
        if (std.fs.cwd().access(path_buf.items, .{})) |_| {
            return try self.allocator.dupe(u8, path_buf.items);
        } else |_| {}

        // Try without src/ prefix
        path_buf.clearRetainingCapacity();
        try path_buf.appendSlice(self.allocator, source_root);
        try path_buf.append(self.allocator, '/');
        for (path_segments, 0..) |segment, i| {
            if (i > 0) try path_buf.append(self.allocator, '/');
            try path_buf.appendSlice(self.allocator, segment);
        }
        try path_buf.appendSlice(self.allocator, ".home");

        if (std.fs.cwd().access(path_buf.items, .{})) |_| {
            return try self.allocator.dupe(u8, path_buf.items);
        } else |_| {}

        return error.FileNotFound;
    }

    fn checkStatement(self: *TypeChecker, stmt: ast.Stmt) TypeError!void {
        switch (stmt) {
            .LetDecl => |decl| {
                if (decl.value) |value| {
                    // BIDIRECTIONAL CHECKING: If type annotation exists, CHECK the value
                    // Otherwise, SYNTHESIZE the type from the value
                    const value_type = if (decl.type_name) |type_name| blk: {
                        const declared_type = try self.parseTypeName(type_name);
                        // CHECK mode: value must have declared_type
                        try self.checkExpression(value, declared_type);
                        break :blk declared_type;
                    } else blk: {
                        // SYNTHESIS mode: infer type from value
                        break :blk try self.synthesizeExpression(value);
                    };

                    // If the value is an identifier, mark it as moved (if movable)
                    if (value.* == .Identifier) {
                        const id_name = value.Identifier.name;
                        try self.ownership_tracker.markMoved(id_name);
                    }

                    try self.env.define(decl.name, value_type);
                    // Track ownership of the new variable
                    try self.ownership_tracker.define(decl.name, value_type, decl.node.loc);
                } else if (decl.type_name) |type_name| {
                    const var_type = try self.parseTypeName(type_name);
                    try self.env.define(decl.name, var_type);
                    try self.ownership_tracker.define(decl.name, var_type, decl.node.loc);
                }
            },
            .FnDecl => |fn_decl| {
                // Save the module environment pointer for parent scope lookup
                const saved_env_ptr = try self.allocator.create(TypeEnvironment);
                saved_env_ptr.* = self.env;

                // Create new scope for function with parent link to module scope
                var func_env = TypeEnvironment.init(self.allocator);
                func_env.parent = saved_env_ptr; // Enable module-level variable lookup

                // Add parameters to function scope
                for (fn_decl.params) |param| {
                    const param_type = try self.parseTypeName(param.type_name);
                    try func_env.define(param.name, param_type);
                }

                // Type check function body with the function environment
                self.env = func_env;

                for (fn_decl.body.statements) |body_stmt| {
                    self.checkStatement(body_stmt) catch |err| {
                        if (err != error.TypeMismatch and err != error.UndefinedVariable) {
                            // Restore env before returning error
                            self.env = saved_env_ptr.*;
                            self.allocator.destroy(saved_env_ptr);
                            return err;
                        }
                        // Continue checking to find more errors
                    };
                }

                // Restore the original environment
                self.env = saved_env_ptr.*;
                self.allocator.destroy(saved_env_ptr);

                // End function scope - release all borrows
                self.ownership_tracker.exitScope();
            },
            .IfStmt => |if_stmt| {
                // Check condition is boolean or optional (optionals are truthy if Some, falsy if None)
                const cond_type = try self.inferExpression(if_stmt.condition);
                if (!cond_type.equals(Type.Bool) and cond_type != .Optional) {
                    try self.addError("If condition must be boolean or optional", if_stmt.node.loc);
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
                // Release borrows at end of then block
                self.ownership_tracker.exitScope();

                // Check else block if present
                if (if_stmt.else_block) |else_block| {
                    for (else_block.statements) |else_stmt| {
                        self.checkStatement(else_stmt) catch |err| {
                            if (err != error.TypeMismatch and err != error.UndefinedVariable) {
                                return err;
                            }
                        };
                    }
                    // Release borrows at end of else block
                    self.ownership_tracker.exitScope();
                }
            },
            .IfLetStmt => |if_let_stmt| {
                // Check the value expression
                _ = try self.inferExpression(if_let_stmt.value);

                // Save current env pointer for parent scope lookup
                const saved_env_ptr = try self.allocator.create(TypeEnvironment);
                saved_env_ptr.* = self.env;

                // Create new scope for the binding variable with parent link
                var let_env = TypeEnvironment.init(self.allocator);
                let_env.parent = saved_env_ptr;

                // Define the binding variable if present (assume Int for now)
                if (if_let_stmt.binding) |binding| {
                    try let_env.define(binding, Type.Int);
                }

                // Check then block with binding scope
                self.env = let_env;

                for (if_let_stmt.then_block.statements) |then_stmt| {
                    self.checkStatement(then_stmt) catch |err| {
                        if (err != error.TypeMismatch and err != error.UndefinedVariable) {
                            self.env = saved_env_ptr.*;
                            self.allocator.destroy(saved_env_ptr);
                            return err;
                        }
                    };
                }

                self.env = saved_env_ptr.*;
                self.allocator.destroy(saved_env_ptr);

                // Check else block if present
                if (if_let_stmt.else_block) |else_block| {
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
                // Check condition is boolean or optional (optionals are truthy if Some, falsy if None)
                const cond_type = try self.inferExpression(while_stmt.condition);
                if (!cond_type.equals(Type.Bool) and cond_type != .Optional) {
                    try self.addError("While condition must be boolean or optional", while_stmt.node.loc);
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

                // Save current env pointer for parent scope lookup
                const saved_env_ptr = try self.allocator.create(TypeEnvironment);
                saved_env_ptr.* = self.env;

                // Create new scope for loop variable with parent link
                var loop_env = TypeEnvironment.init(self.allocator);
                loop_env.parent = saved_env_ptr;

                // Define iterator variable with appropriate type
                // For integer iterable, iterator is int
                // For array iterable, iterator is the element type
                const iterator_type = if (iterable_type == .Array)
                    iterable_type.Array.element_type.*
                else
                    Type.Int;
                try loop_env.define(for_stmt.iterator, iterator_type);

                // Check body with loop scope
                self.env = loop_env;

                for (for_stmt.body.statements) |body_stmt| {
                    self.checkStatement(body_stmt) catch |err| {
                        if (err != error.TypeMismatch and err != error.UndefinedVariable) {
                            self.env = saved_env_ptr.*;
                            self.allocator.destroy(saved_env_ptr);
                            return err;
                        }
                    };
                }

                self.env = saved_env_ptr.*;
                self.allocator.destroy(saved_env_ptr);
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

                const fields_slice = try fields.toOwnedSlice(self.allocator);
                // Track the allocated slice for proper cleanup
                try self.env.trackAllocation(fields_slice);

                const struct_type = Type{
                    .Struct = .{
                        .name = struct_decl.name,
                        .fields = fields_slice,
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

                const variants_slice = try variants.toOwnedSlice(self.allocator);
                // Track the allocated slice for proper cleanup
                try self.env.trackAllocation(variants_slice);

                const enum_type = Type{
                    .Enum = .{
                        .name = enum_decl.name,
                        .variants = variants_slice,
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

    // ============================================================================
    // BIDIRECTIONAL TYPE CHECKING
    // ============================================================================

    /// Check mode: Verify that an expression has the expected type
    fn checkExpression(self: *TypeChecker, expr: *const ast.Expr, expected: Type) TypeError!void {
        // Special case: null literals can be assigned to optional types
        if (expr.* == .NullLiteral) {
            if (expected == .Optional) {
                return; // Valid null assignment to optional type
            }
        }

        // Special case: integer literals can be coerced to any integer type
        if (expr.* == .IntegerLiteral) {
            if (isIntegerType(expected)) {
                return; // Valid integer literal coercion
            }
        }

        // Special case: float literals can be coerced to any float type
        if (expr.* == .FloatLiteral) {
            if (isFloatType(expected)) {
                return; // Valid float literal coercion
            }
        }

        // Special case: empty array literals can be coerced to any array type
        if (expr.* == .ArrayLiteral) {
            if (expr.ArrayLiteral.elements.len == 0 and expected == .Array) {
                return; // Valid empty array coercion to expected array type
            }
        }

        const actual = try self.synthesizeExpression(expr);
        if (!actual.equals(expected) and !canCoerce(actual, expected)) {
            try self.addTypeMismatchError(expected, actual, expr.getLocation());
            return error.TypeMismatch;
        }
    }

    /// Check if a type is an integer type (any size)
    fn isIntegerType(t: Type) bool {
        return switch (t) {
            .Int, .I8, .I16, .I32, .I64, .I128, .U8, .U16, .U32, .U64, .U128 => true,
            else => false,
        };
    }

    /// Check if a type is a float type
    fn isFloatType(t: Type) bool {
        return switch (t) {
            .Float, .F32, .F64 => true,
            else => false,
        };
    }

    /// Check if a type can be coerced to another type
    fn canCoerce(from: Type, to: Type) bool {
        // Value can be coerced to Optional of that type (T -> ?T)
        // This must be checked first to handle Int -> ?i32 coercion
        if (to == .Optional) {
            const inner_type = to.Optional.*;
            // Check if from type matches or can coerce to the inner type
            if (from.equals(inner_type)) {
                return true;
            }
            // Also check if from can coerce to inner type
            return canCoerce(from, inner_type);
        }
        // Integer type coercion: generic Int can coerce to specific integer types
        if (from == .Int) {
            return isIntegerType(to);
        }
        // Float type coercion: generic Float can coerce to specific float types
        if (from == .Float) {
            return isFloatType(to);
        }
        return false;
    }

    /// Synthesis mode: Infer the type of an expression
    fn synthesizeExpression(self: *TypeChecker, expr: *const ast.Expr) TypeError!Type {
        return try self.inferExpression(expr);
    }

    /// Legacy inference method (will gradually migrate to synthesizeExpression)
    fn inferExpression(self: *TypeChecker, expr: *const ast.Expr) TypeError!Type {
        return switch (expr.*) {
            .IntegerLiteral => Type.Int,
            .FloatLiteral => Type.Float,
            .StringLiteral => Type.String,
            .BooleanLiteral => Type.Bool,
            .ArrayLiteral => |array| try self.inferArrayLiteral(array),
            .Identifier => |id| {
                // Check ownership before use
                self.ownership_tracker.checkUse(id.name, id.node.loc) catch |err| {
                    if (err != error.UseAfterMove) return err;
                    // Error already added to ownership tracker, continue type checking
                };

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
            .StructLiteral => |struct_lit| try self.inferStructLiteral(struct_lit),
            .UnaryExpr => |unary| try self.inferUnaryExpression(unary),
            else => Type.Void,
        };
    }

    fn inferBinaryExpression(self: *TypeChecker, binary: *const ast.BinaryExpr) TypeError!Type {
        const left_type = try self.inferExpression(binary.left);
        const right_type = try self.inferExpression(binary.right);

        return switch (binary.op) {
            .Add => {
                // String concatenation with + operator
                if (left_type.equals(Type.String) or right_type.equals(Type.String)) {
                    return Type.String;
                }
                // Numeric addition
                if (isIntegerType(left_type) and isIntegerType(right_type)) {
                    return Type.Int;
                } else if (isFloatType(left_type) or isFloatType(right_type)) {
                    return Type.Float;
                } else {
                    try self.addError("Addition requires numeric or string types", binary.node.loc);
                    return error.TypeMismatch;
                }
            },
            .Sub, .Mul, .Div, .Mod => {
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

                if (isIntegerType(left_type) and isIntegerType(right_type)) {
                    return Type.Int;
                } else if (isFloatType(left_type) or isFloatType(right_type)) {
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
                // Function might be from an imported module, return unknown type
                // to allow type checking to continue
                return Type.Void;
            };

            if (func_type == .Function) {
                // Check argument types
                const expected_params = func_type.Function.params;

                // Special case for print (variadic)
                if (!std.mem.eql(u8, func_name, "print")) {
                    // Get required params count (if not set, all params are required)
                    const required_params = func_type.Function.required_params orelse expected_params.len;

                    // Total provided arguments = positional + named
                    const total_provided = call.args.len + call.named_args.len;

                    // Check: args >= required_params AND args <= total_params
                    if (total_provided < required_params or total_provided > expected_params.len) {
                        try self.addError("Wrong number of arguments", call.node.loc);
                        return error.WrongNumberOfArguments;
                    }

                    // Type check positional arguments
                    for (call.args, 0..) |arg, i| {
                        const arg_type = try self.inferExpression(arg);
                        if (!arg_type.equals(expected_params[i]) and !canCoerce(arg_type, expected_params[i])) {
                            try self.addError("Argument type mismatch", call.node.loc);
                            return error.TypeMismatch;
                        }
                    }

                    // Type check named arguments (we'd need parameter names to do full validation)
                    // For now, just type check the expressions
                    for (call.named_args) |named_arg| {
                        _ = try self.inferExpression(named_arg.value);
                    }
                }

                return func_type.Function.return_type.*;
            }
        }

        // Handle enum variant constructor calls like Result::Ok(value)
        if (call.callee.* == .MemberExpr) {
            const member = call.callee.MemberExpr;
            if (member.object.* == .Identifier) {
                const enum_name = member.object.Identifier.name;
                const enum_type = self.env.get(enum_name) orelse {
                    // Unknown type, allow to continue
                    return Type.Void;
                };

                if (enum_type == .Enum) {
                    // This is an enum variant constructor like Result::Ok(value)
                    // The type of the expression is the enum type itself
                    // Verify the variant exists and type-check the argument
                    const variant_name = member.member;
                    for (enum_type.Enum.variants) |variant| {
                        if (std.mem.eql(u8, variant.name, variant_name)) {
                            // Type check the argument if the variant has data
                            if (variant.data_type) |expected_data_type| {
                                if (call.args.len == 1) {
                                    const arg_type = try self.inferExpression(call.args[0]);
                                    if (!arg_type.equals(expected_data_type) and !canCoerce(arg_type, expected_data_type)) {
                                        try self.addError("Enum variant data type mismatch", call.node.loc);
                                        return error.TypeMismatch;
                                    }
                                }
                            }
                            return enum_type;
                        }
                    }
                }
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
        const object_type = self.inferExpression(member.object) catch {
            // If we can't infer the object type, return a generic type
            return Type.Void;
        };

        const member_name = member.member;
        if (member_name.len == 0) {
            try self.addError("Empty member name in member access", member.node.loc);
            return error.TypeMismatch;
        }

        // Handle enum variant access (e.g., Platform::MACOS)
        if (object_type == .Enum) {
            // Check if the member is a valid variant
            for (object_type.Enum.variants) |variant| {
                if (std.mem.eql(u8, variant.name, member_name)) {
                    // Return the enum type itself for variant access
                    return object_type;
                }
            }
            const err_msg = try std.fmt.allocPrint(
                self.allocator,
                "Enum '{s}' has no variant '{s}'",
                .{ object_type.Enum.name, member_name },
            );
            try self.addError(err_msg, member.node.loc);
            self.allocator.free(err_msg);
            return error.TypeMismatch;
        }

        // Object must be a struct type for field access
        if (object_type != .Struct) {
            try self.addError("Cannot access member of non-struct type", member.node.loc);
            return error.TypeMismatch;
        }

        // Placeholder struct check - must come BEFORE field iteration
        // Placeholder structs have no fields and are created when imports fail
        if (object_type.Struct.fields.len == 0) {
            // Placeholder struct - return Void to allow type checking to continue
            return Type.Void;
        }

        // Safety check: if fields slice has invalid length, return Void
        if (object_type.Struct.fields.len > 1000) {
            return Type.Void;
        }

        for (object_type.Struct.fields) |field| {
            // Safety check for field names - check length first
            if (field.name.len == 0 or field.name.len > 1000) {
                continue;
            }
            if (std.mem.eql(u8, field.name, member_name)) {
                return field.type;
            }
        }

        const err_msg = try std.fmt.allocPrint(
            self.allocator,
            "Struct '{s}' has no field '{s}'",
            .{ object_type.Struct.name, member_name },
        );
        try self.addError(err_msg, member.node.loc);
        self.allocator.free(err_msg);
        return error.TypeMismatch;
    }

    fn inferStructLiteral(self: *TypeChecker, struct_lit: *const ast.StructLiteralExpr) TypeError!Type {
        // Look up the struct type in the environment
        const type_name = struct_lit.type_name;

        // First try direct lookup in environment
        if (self.env.get(type_name)) |struct_type| {
            if (struct_type != .Struct) {
                const err_msg = try std.fmt.allocPrint(
                    self.allocator,
                    "'{s}' is not a struct type",
                    .{type_name},
                );
                try self.addError(err_msg, struct_lit.node.loc);
                self.allocator.free(err_msg);
                return error.TypeMismatch;
            }

            // Validate field types (optional: check each field against struct definition)
            for (struct_lit.fields) |field| {
                _ = try self.inferExpression(field.value);
            }

            return struct_type;
        }

        // If not found, try parsing as a type name (handles generic types like Vec<i32>)
        const parsed_type = self.parseTypeName(type_name) catch {
            const err_msg = try std.fmt.allocPrint(
                self.allocator,
                "Unknown struct type '{s}'",
                .{type_name},
            );
            try self.addError(err_msg, struct_lit.node.loc);
            self.allocator.free(err_msg);
            return error.UndefinedVariable;
        };

        // For generic collection types (Vec<T>, Array<T>, List<T>), return the parsed type
        // These are valid as constructor expressions like Vec<i32> {}
        if (parsed_type == .Array) {
            // Validate field types if any
            for (struct_lit.fields) |field| {
                _ = try self.inferExpression(field.value);
            }
            return parsed_type;
        }

        // For other parsed types that resolved to Struct, use that
        if (parsed_type == .Struct) {
            for (struct_lit.fields) |field| {
                _ = try self.inferExpression(field.value);
            }
            return parsed_type;
        }

        // Otherwise, report unknown type
        const err_msg = try std.fmt.allocPrint(
            self.allocator,
            "Unknown struct type '{s}'",
            .{type_name},
        );
        try self.addError(err_msg, struct_lit.node.loc);
        self.allocator.free(err_msg);
        return error.UndefinedVariable;
    }

    fn inferUnaryExpression(self: *TypeChecker, unary: *const ast.UnaryExpr) TypeError!Type {
        const operand_type = try self.inferExpression(unary.operand);

        return switch (unary.op) {
            .Not => {
                // Allow logical not on boolean or optional types
                // For optional types, !opt is true if opt is null (None)
                if (!operand_type.equals(Type.Bool) and operand_type != .Optional) {
                    try self.addError("Logical not requires boolean or optional operand", unary.node.loc);
                    return error.TypeMismatch;
                }
                return Type.Bool;
            },
            .Neg => {
                if (!operand_type.equals(Type.Int) and !operand_type.equals(Type.Float)) {
                    try self.addError("Negation requires numeric operand", unary.node.loc);
                    return error.TypeMismatch;
                }
                return operand_type;
            },
            .BitNot => {
                if (!operand_type.equals(Type.Int)) {
                    try self.addError("Bitwise not requires integer operand", unary.node.loc);
                    return error.TypeMismatch;
                }
                return Type.Int;
            },
            .Deref => {
                // Dereference returns the pointed-to type
                // For now, just return the operand type (pointer semantics not fully implemented)
                return operand_type;
            },
            .AddressOf => {
                // Address-of returns a pointer to the operand type
                // For now, just return the operand type (pointer semantics not fully implemented)
                return operand_type;
            },
            .Borrow => {
                // Immutable borrow: &x
                // Check if operand is an identifier (can only borrow variables)
                if (unary.operand.* != .Identifier) {
                    try self.addError("Can only borrow variables", unary.node.loc);
                    return error.TypeMismatch;
                }

                const var_name = unary.operand.Identifier.name;

                // Track the borrow in ownership system
                try self.ownership_tracker.borrow(var_name, false, unary.node.loc);

                // Return Reference type
                const inner_type = try self.allocator.create(Type);
                inner_type.* = operand_type;
                try self.allocated_types.append(self.allocator, inner_type);

                return Type{ .Reference = inner_type };
            },
            .BorrowMut => {
                // Mutable borrow: &mut x
                // Check if operand is an identifier
                if (unary.operand.* != .Identifier) {
                    try self.addError("Can only borrow variables", unary.node.loc);
                    return error.TypeMismatch;
                }

                const var_name = unary.operand.Identifier.name;

                // Track the mutable borrow in ownership system
                try self.ownership_tracker.borrowMut(var_name, unary.node.loc);

                // Return MutableReference type
                const inner_type = try self.allocator.create(Type);
                inner_type.* = operand_type;
                try self.allocated_types.append(self.allocator, inner_type);

                return Type{ .MutableReference = inner_type };
            },
        };
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
            // Use canCoerce to allow integer literal coercion (e.g., Int -> i32)
            if (!inner_type.equals(right_type) and !canCoerce(right_type, inner_type)) {
                try self.addError("Null coalesce default value must match optional type", null_coalesce.node.loc);
                return error.TypeMismatch;
            }
            // Return the inner type (unwrapped optional type)
            return inner_type;
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

        // Check if it's a mutable type (mut T) - for by-value mutable parameters
        // This is different from &mut T which is a mutable reference
        if (std.mem.startsWith(u8, name, "mut ")) {
            const inner_type_name = name[4..];
            // For type checking, mut T is treated as T (mutability is a binding property)
            return try self.parseTypeName(inner_type_name);
        }

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

        // Check if it's an optional type (?T)
        if (name.len > 1 and name[0] == '?') {
            const inner_type_name = name[1..];
            const inner_type = try self.parseTypeName(inner_type_name);
            const inner_ptr = try self.allocator.create(Type);
            errdefer self.allocator.destroy(inner_ptr);
            inner_ptr.* = inner_type;
            try self.allocated_types.append(self.allocator, inner_ptr);
            return Type{ .Optional = inner_ptr };
        }

        // Check if it's a generic type (e.g., "Result<T, E>", "Vec<T>", "Option<T>")
        if (std.mem.indexOf(u8, name, "<")) |angle_start| {
            const base_name = name[0..angle_start];

            // Find the closing angle bracket
            const angle_end = std.mem.lastIndexOf(u8, name, ">") orelse name.len;
            const type_params = name[angle_start + 1 .. angle_end];

            if (std.mem.eql(u8, base_name, "Result")) {
                // Parse Result<T, E>
                // Find comma to split ok_type and err_type
                var ok_type_name: []const u8 = "void";
                var err_type_name: []const u8 = "void";

                if (std.mem.indexOf(u8, type_params, ",")) |comma_pos| {
                    ok_type_name = std.mem.trim(u8, type_params[0..comma_pos], " ");
                    err_type_name = std.mem.trim(u8, type_params[comma_pos + 1 ..], " ");
                } else {
                    ok_type_name = std.mem.trim(u8, type_params, " ");
                }

                const ok_type = try self.allocator.create(Type);
                errdefer self.allocator.destroy(ok_type);
                ok_type.* = try self.parseTypeName(ok_type_name);
                try self.allocated_types.append(self.allocator, ok_type);

                const err_type = try self.allocator.create(Type);
                errdefer self.allocator.destroy(err_type);
                err_type.* = try self.parseTypeName(err_type_name);
                try self.allocated_types.append(self.allocator, err_type);

                return Type{ .Result = .{
                    .ok_type = ok_type,
                    .err_type = err_type,
                } };
            }

            if (std.mem.eql(u8, base_name, "Option")) {
                // Parse Option<T> - treat as nullable/optional type
                const inner_type_name = std.mem.trim(u8, type_params, " ");
                const inner_type = try self.allocator.create(Type);
                errdefer self.allocator.destroy(inner_type);
                inner_type.* = try self.parseTypeName(inner_type_name);
                try self.allocated_types.append(self.allocator, inner_type);

                return Type{ .Optional = inner_type };
            }

            if (std.mem.eql(u8, base_name, "Vec") or std.mem.eql(u8, base_name, "Array") or std.mem.eql(u8, base_name, "List")) {
                // Parse Vec<T>, Array<T>, List<T> - all treated as array types
                const elem_type_name = std.mem.trim(u8, type_params, " ");
                const elem_type = try self.allocator.create(Type);
                errdefer self.allocator.destroy(elem_type);
                elem_type.* = try self.parseTypeName(elem_type_name);
                try self.allocated_types.append(self.allocator, elem_type);

                return Type{ .Array = .{
                    .element_type = elem_type,
                } };
            }

            if (std.mem.eql(u8, base_name, "HashMap") or std.mem.eql(u8, base_name, "Map") or std.mem.eql(u8, base_name, "Dict")) {
                // Parse HashMap<K, V> - for now treat as generic type
                // TODO: Add proper Map type
                return Type.Void;
            }

            // Unknown generic type - treat as void for now
            return Type.Void;
        }

        // Check if it's an array type [T] or [T; N]
        if (name.len > 2 and name[0] == '[') {
            // Find the element type (skip ; and size if present)
            var end_pos = name.len - 1;
            if (name[end_pos] == ']') {
                // Check for [T; N] syntax
                if (std.mem.indexOf(u8, name, ";")) |semi_pos| {
                    end_pos = semi_pos;
                }

                const elem_type_name = std.mem.trim(u8, name[1..end_pos], " ");
                const elem_type = try self.allocator.create(Type);
                errdefer self.allocator.destroy(elem_type);
                elem_type.* = try self.parseTypeName(elem_type_name);
                try self.allocated_types.append(self.allocator, elem_type);

                return Type{ .Array = .{
                    .element_type = elem_type,
                } };
            }
        }

        // Handle module::Type paths (e.g., "thing::Thing", "player::Player")
        if (std.mem.indexOf(u8, name, "::")) |sep_pos| {
            // Extract the type name after the module path
            const type_name = name[sep_pos + 2 ..];
            // Try to look up just the type name in environment
            if (self.env.get(type_name)) |user_type| {
                return user_type;
            }
            // Also try the full path as-is
            if (self.env.get(name)) |user_type| {
                return user_type;
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

    /// Add a type mismatch error with expected and actual types
    fn addTypeMismatchError(
        self: *TypeChecker,
        expected: Type,
        actual: Type,
        loc: ast.SourceLocation,
    ) !void {
        const expected_str = try self.typeToString(expected);
        const actual_str = try self.typeToString(actual);

        const msg = try std.fmt.allocPrint(
            self.allocator,
            "Type mismatch",
            .{},
        );
        errdefer self.allocator.free(msg);

        try self.errors.append(self.allocator, .{
            .message = msg,
            .loc = loc,
            .expected = expected_str,
            .actual = actual_str,
            .suggestion = try self.suggestTypeFix(expected, actual),
        });
    }

    /// Convert a type to a readable string
    fn typeToString(self: *TypeChecker, typ: Type) ![]const u8 {
        return switch (typ) {
            .Int => try self.allocator.dupe(u8, "int"),
            .Float => try self.allocator.dupe(u8, "float"),
            .Bool => try self.allocator.dupe(u8, "bool"),
            .String => try self.allocator.dupe(u8, "string"),
            .Void => try self.allocator.dupe(u8, "void"),
            .Array => |arr| {
                const elem_str = try self.typeToString(arr.element_type.*);
                defer self.allocator.free(elem_str);
                return try std.fmt.allocPrint(self.allocator, "[{s}]", .{elem_str});
            },
            .Function => |func| {
                // Build parameter list
                var params_str = std.ArrayList(u8){};
                defer params_str.deinit(self.allocator);

                try params_str.appendSlice(self.allocator,"fn(");
                for (func.params, 0..) |param, i| {
                    if (i > 0) try params_str.appendSlice(self.allocator, ", ");
                    const param_str = try self.typeToString(param);
                    defer self.allocator.free(param_str);
                    try params_str.appendSlice(self.allocator,param_str);
                }
                try params_str.appendSlice(self.allocator,") -> ");

                const ret_str = try self.typeToString(func.return_type.*);
                defer self.allocator.free(ret_str);
                try params_str.appendSlice(self.allocator,ret_str);

                return try self.allocator.dupe(u8, params_str.items);
            },
            .Reference => |ref| {
                const inner_str = try self.typeToString(ref.*);
                defer self.allocator.free(inner_str);
                return try std.fmt.allocPrint(self.allocator, "&{s}", .{inner_str});
            },
            .MutableReference => |ref| {
                const inner_str = try self.typeToString(ref.*);
                defer self.allocator.free(inner_str);
                return try std.fmt.allocPrint(self.allocator, "&mut {s}", .{inner_str});
            },
            else => try std.fmt.allocPrint(self.allocator, "{any}", .{typ}),
        };
    }

    /// Suggest a fix for a type mismatch
    fn suggestTypeFix(self: *TypeChecker, expected: Type, actual: Type) !?[]const u8 {
        // Int <-> Float conversion
        if (expected == .Int and actual == .Float) {
            return try self.allocator.dupe(u8, "use .int() to convert float to int");
        }
        if (expected == .Float and actual == .Int) {
            return try self.allocator.dupe(u8, "use .float() to convert int to float");
        }

        // Bool <-> Int
        if (expected == .Bool and actual == .Int) {
            return try self.allocator.dupe(u8, "use comparison operators (==, !=, <, >) instead of int");
        }

        // String suggestions
        if (expected == .String and actual == .Int) {
            return try self.allocator.dupe(u8, "use .toString() to convert int to string");
        }

        return null;
    }
};

/// Tracked allocation info for proper cleanup
const TrackedAlloc = struct {
    ptr: *anyopaque,
    len: usize,
    alignment: u8,
    elem_size: usize,
};

pub const TypeEnvironment = struct {
    bindings: std.StringHashMap(Type),
    parent: ?*TypeEnvironment,
    allocator: std.mem.Allocator,
    /// Track allocated slices for proper cleanup (avoids double-free)
    allocated_slices: std.ArrayList(TrackedAlloc),

    pub fn init(allocator: std.mem.Allocator) TypeEnvironment {
        return .{
            .bindings = std.StringHashMap(Type).init(allocator),
            .parent = null,
            .allocator = allocator,
            .allocated_slices = std.ArrayList(TrackedAlloc){},
        };
    }

    pub fn deinit(self: *TypeEnvironment) void {
        // Free tracked slices (struct fields, enum variants)
        for (self.allocated_slices.items) |alloc| {
            // Skip zero-length allocations to avoid integer overflow in rawFree
            if (alloc.len == 0) continue;
            const byte_ptr: [*]u8 = @ptrCast(alloc.ptr);
            const byte_slice = byte_ptr[0 .. alloc.len * alloc.elem_size];
            self.allocator.rawFree(byte_slice, @enumFromInt(alloc.alignment), @returnAddress());
        }
        self.allocated_slices.deinit(self.allocator);

        // Free the keys
        var it = self.bindings.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.bindings.deinit();
    }

    /// Track an allocated slice for cleanup in deinit
    pub fn trackAllocation(self: *TypeEnvironment, slice: anytype) !void {
        const T = @TypeOf(slice[0]);
        try self.allocated_slices.append(self.allocator, .{
            .ptr = @ptrCast(@constCast(slice.ptr)),
            .len = slice.len,
            .alignment = std.math.log2(@as(u8, @alignOf(T))),
            .elem_size = @sizeOf(T),
        });
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

/// Stub for lifetime tracking (to be implemented)
pub const LifetimeTracker = struct {
    pub fn init(allocator: std.mem.Allocator) LifetimeTracker {
        _ = allocator;
        return .{};
    }
    pub fn deinit(self: *LifetimeTracker) void {
        _ = self;
    }
};

/// Stub for move tracking (to be implemented)
pub const MoveTracker = struct {
    pub fn init(allocator: std.mem.Allocator) MoveTracker {
        _ = allocator;
        return .{};
    }
    pub fn deinit(self: *MoveTracker) void {
        _ = self;
    }
};

/// Stub for type inference (to be implemented)
pub const TypeInferencer = struct {
    pub fn init(allocator: std.mem.Allocator) TypeInferencer {
        _ = allocator;
        return .{};
    }
    pub fn deinit(self: *TypeInferencer) void {
        _ = self;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "type: primitive type equality" {
    const testing = std.testing;

    const int_type: Type = .Int;
    const bool_type: Type = .Bool;
    const string_type: Type = .String;
    const void_type: Type = .Void;
    const f32_type: Type = .F32;
    const f64_type: Type = .F64;
    const i32_type: Type = .I32;
    const i64_type: Type = .I64;
    const u8_type: Type = .U8;
    const u16_type: Type = .U16;
    const u32_type: Type = .U32;
    const u64_type: Type = .U64;

    try testing.expect(int_type.equals(.Int));
    try testing.expect(bool_type.equals(.Bool));
    try testing.expect(string_type.equals(.String));
    try testing.expect(void_type.equals(.Void));
    try testing.expect(f32_type.equals(.F32));
    try testing.expect(f64_type.equals(.F64));
    try testing.expect(i32_type.equals(.I32));
    try testing.expect(i64_type.equals(.I64));
    try testing.expect(u8_type.equals(.U8));
    try testing.expect(u16_type.equals(.U16));
    try testing.expect(u32_type.equals(.U32));
    try testing.expect(u64_type.equals(.U64));
}

test "type: primitive type inequality" {
    const testing = std.testing;

    const int_type: Type = .Int;
    const float_type: Type = .Float;
    const bool_type: Type = .Bool;
    const string_type: Type = .String;
    const i32_type: Type = .I32;
    const i64_type: Type = .I64;
    const f32_type: Type = .F32;
    const f64_type: Type = .F64;
    const u8_type: Type = .U8;
    const i8_type: Type = .I8;

    try testing.expect(!int_type.equals(float_type));
    try testing.expect(!bool_type.equals(string_type));
    try testing.expect(!i32_type.equals(i64_type));
    try testing.expect(!f32_type.equals(f64_type));
    try testing.expect(!u8_type.equals(i8_type));
}

test "type: resolveDefault" {
    const testing = std.testing;

    const int_type: Type = .Int;
    const float_type: Type = .Float;
    const bool_type: Type = .Bool;
    const string_type: Type = .String;
    const i32_type: Type = .I32;

    // Int resolves to I64
    try testing.expect(int_type.resolveDefault().equals(.I64));
    // Float resolves to F64
    try testing.expect(float_type.resolveDefault().equals(.F64));
    // Other types stay the same
    try testing.expect(bool_type.resolveDefault().equals(.Bool));
    try testing.expect(string_type.resolveDefault().equals(.String));
    try testing.expect(i32_type.resolveDefault().equals(.I32));
}

test "type: isDefaultType" {
    const testing = std.testing;

    const int_type: Type = .Int;
    const float_type: Type = .Float;
    const i32_type: Type = .I32;
    const f64_type: Type = .F64;
    const bool_type: Type = .Bool;
    const string_type: Type = .String;

    try testing.expect(int_type.isDefaultType());
    try testing.expect(float_type.isDefaultType());
    try testing.expect(!i32_type.isDefaultType());
    try testing.expect(!f64_type.isDefaultType());
    try testing.expect(!bool_type.isDefaultType());
    try testing.expect(!string_type.isDefaultType());
}

test "type: TypeVar equality" {
    const testing = std.testing;

    const tv1 = Type{ .TypeVar = .{ .id = 1, .name = "T" } };
    const tv2 = Type{ .TypeVar = .{ .id = 1, .name = "T" } };
    const tv3 = Type{ .TypeVar = .{ .id = 2, .name = "U" } };

    try testing.expect(tv1.equals(tv2));
    try testing.expect(!tv1.equals(tv3));
}

test "type: TypeEnvironment define and get" {
    const testing = std.testing;

    var env = TypeEnvironment.init(testing.allocator);
    defer env.deinit();

    // Define a variable
    try env.define("x", .Int);
    try env.define("name", .String);

    // Get defined variables
    const x_type = env.get("x");
    try testing.expect(x_type != null);
    try testing.expect(x_type.?.equals(.Int));

    const name_type = env.get("name");
    try testing.expect(name_type != null);
    try testing.expect(name_type.?.equals(.String));

    // Undefined variable returns null
    try testing.expect(env.get("undefined") == null);
}

test "type: TypeInferencer init/deinit" {
    const testing = std.testing;

    var inferencer = TypeInferencer.init(testing.allocator);
    defer inferencer.deinit();
    // Just verify no crash - stub implementation
}

test "type: LifetimeTracker init/deinit" {
    const testing = std.testing;

    var tracker = LifetimeTracker.init(testing.allocator);
    defer tracker.deinit();
    // Just verify no crash - stub implementation
}

test "type: MoveTracker init/deinit" {
    const testing = std.testing;

    var tracker = MoveTracker.init(testing.allocator);
    defer tracker.deinit();
    // Just verify no crash - stub implementation
}
