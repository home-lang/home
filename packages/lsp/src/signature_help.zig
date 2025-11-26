const std = @import("std");
const ast = @import("ast");
const Allocator = std.mem.Allocator;

/// Signature help provider for function calls
/// Shows parameter information as the user types
pub const SignatureHelpProvider = struct {
    allocator: Allocator,
    /// Cache of function signatures
    function_signatures: std.StringHashMap(FunctionSignature),

    pub const FunctionSignature = struct {
        label: []const u8,
        documentation: ?[]const u8,
        parameters: []ParameterInformation,
    };

    pub const ParameterInformation = struct {
        label: []const u8,
        documentation: ?[]const u8,
    };

    pub const SignatureHelp = struct {
        signatures: []SignatureInformation,
        active_signature: u32,
        active_parameter: u32,

        pub fn deinit(self: *SignatureHelp, allocator: Allocator) void {
            for (self.signatures) |*sig| {
                allocator.free(sig.label);
                if (sig.documentation) |doc| {
                    allocator.free(doc);
                }
                for (sig.parameters) |*param| {
                    allocator.free(param.label);
                    if (param.documentation) |doc| {
                        allocator.free(doc);
                    }
                }
                allocator.free(sig.parameters);
            }
            allocator.free(self.signatures);
        }
    };

    pub const SignatureInformation = struct {
        label: []const u8,
        documentation: ?[]const u8,
        parameters: []ParameterInformation,
        active_parameter: ?u32,
    };

    pub fn init(allocator: Allocator) SignatureHelpProvider {
        return .{
            .allocator = allocator,
            .function_signatures = std.StringHashMap(FunctionSignature).init(allocator),
        };
    }

    pub fn deinit(self: *SignatureHelpProvider) void {
        var it = self.function_signatures.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.label);
            if (entry.value_ptr.documentation) |doc| {
                self.allocator.free(doc);
            }
            for (entry.value_ptr.parameters) |param| {
                self.allocator.free(param.label);
                if (param.documentation) |doc| {
                    self.allocator.free(doc);
                }
            }
            self.allocator.free(entry.value_ptr.parameters);
        }
        self.function_signatures.deinit();
    }

    /// Index function signatures from AST
    pub fn indexProgram(self: *SignatureHelpProvider, program: *ast.Program) !void {
        for (program.statements) |stmt| {
            try self.indexStatement(&stmt);
        }
    }

    fn indexStatement(self: *SignatureHelpProvider, stmt: *const ast.Stmt) !void {
        switch (stmt.*) {
            .FunctionDecl => |func| {
                try self.addFunctionSignature(func);
            },
            .StructDecl => |struct_decl| {
                // Index struct methods if they exist
                for (struct_decl.methods) |method| {
                    const qualified_name = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}.{s}",
                        .{ struct_decl.name, method.name },
                    );
                    defer self.allocator.free(qualified_name);
                    try self.addFunctionSignatureWithName(method, qualified_name);
                }
            },
            .TraitDecl => |trait_decl| {
                // Index trait methods
                for (trait_decl.methods) |method| {
                    const qualified_name = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}.{s}",
                        .{ trait_decl.name, method.name },
                    );
                    defer self.allocator.free(qualified_name);
                    try self.addFunctionSignatureWithName(method, qualified_name);
                }
            },
            .ImplDecl => |impl_decl| {
                // Index impl methods
                if (impl_decl.trait_name) |trait_name| {
                    for (impl_decl.methods) |method| {
                        const qualified_name = try std.fmt.allocPrint(
                            self.allocator,
                            "{s}::{s}.{s}",
                            .{ impl_decl.type_name, trait_name, method.name },
                        );
                        defer self.allocator.free(qualified_name);
                        try self.addFunctionSignatureWithName(method, qualified_name);
                    }
                } else {
                    for (impl_decl.methods) |method| {
                        const qualified_name = try std.fmt.allocPrint(
                            self.allocator,
                            "{s}.{s}",
                            .{ impl_decl.type_name, method.name },
                        );
                        defer self.allocator.free(qualified_name);
                        try self.addFunctionSignatureWithName(method, qualified_name);
                    }
                }
            },
            else => {},
        }
    }

    fn addFunctionSignature(self: *SignatureHelpProvider, func: ast.FunctionDecl) !void {
        try self.addFunctionSignatureWithName(func, func.name);
    }

    fn addFunctionSignatureWithName(self: *SignatureHelpProvider, func: ast.FunctionDecl, name: []const u8) !void {
        // Build function signature label
        var label = std.ArrayList(u8).init(self.allocator);
        defer label.deinit();

        const writer = label.writer();

        if (func.is_async) try writer.writeAll("async ");
        try writer.writeAll("fn ");
        try writer.writeAll(name);
        try writer.writeByte('(');

        // Build parameters array
        var parameters = std.ArrayList(ParameterInformation).init(self.allocator);

        for (func.params, 0..) |param, i| {
            if (i > 0) try writer.writeAll(", ");

            // Track parameter start position for label ranges
            const param_start = label.items.len;

            if (param.is_mut) try writer.writeAll("mut ");
            try writer.writeAll(param.name);

            if (param.type_annotation) |type_ann| {
                try writer.writeAll(": ");
                try self.formatType(&writer, type_ann);
            }

            const param_end = label.items.len;

            // Create parameter label
            const param_label = try self.allocator.dupe(u8, label.items[param_start..param_end]);

            // Generate parameter documentation
            const param_doc = try self.generateParameterDoc(param);

            try parameters.append(.{
                .label = param_label,
                .documentation = param_doc,
            });
        }

        try writer.writeByte(')');

        // Add return type
        if (func.return_type) |ret_type| {
            try writer.writeAll(" -> ");
            try self.formatType(&writer, ret_type);
        }

        // Generate function documentation
        const func_doc = try self.generateFunctionDoc(func);

        const signature = FunctionSignature{
            .label = try self.allocator.dupe(u8, label.items),
            .documentation = func_doc,
            .parameters = try parameters.toOwnedSlice(),
        };

        const key = try self.allocator.dupe(u8, name);
        try self.function_signatures.put(key, signature);
    }

    /// Format a type for display
    fn formatType(self: *SignatureHelpProvider, writer: anytype, typ: *ast.TypeExpr) !void {
        _ = self;
        switch (typ.*) {
            .Named => |named| try writer.writeAll(named.name),
            .Generic => |generic| {
                try writer.writeAll(generic.base);
                try writer.writeByte('<');
                for (generic.args, 0..) |arg, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try self.formatType(writer, arg);
                }
                try writer.writeByte('>');
            },
            .Optional => |opt| {
                try self.formatType(writer, opt.inner);
                try writer.writeByte('?');
            },
            .Result => |res| {
                try writer.writeAll("Result<");
                try self.formatType(writer, res.ok_type);
                try writer.writeAll(", ");
                try self.formatType(writer, res.err_type);
                try writer.writeByte('>');
            },
            .Array => |arr| {
                try writer.writeByte('[');
                try self.formatType(writer, arr.element_type);
                try writer.writeByte(']');
            },
            .Slice => |slice| {
                try writer.writeAll("[]");
                try self.formatType(writer, slice.element_type);
            },
            .Pointer => |ptr| {
                try writer.writeByte('*');
                if (ptr.is_mut) try writer.writeAll("mut ");
                try self.formatType(writer, ptr.pointee_type);
            },
            .Function => |func| {
                try writer.writeAll("fn(");
                for (func.param_types, 0..) |param_type, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try self.formatType(writer, param_type);
                }
                try writer.writeByte(')');
                if (func.return_type) |ret_type| {
                    try writer.writeAll(" -> ");
                    try self.formatType(writer, ret_type);
                }
            },
            else => try writer.writeByte('_'),
        }
    }

    /// Generate documentation for a parameter
    fn generateParameterDoc(self: *SignatureHelpProvider, param: ast.Parameter) !?[]const u8 {
        if (param.doc_comment) |doc| {
            return try self.allocator.dupe(u8, doc);
        }

        // Generate basic documentation based on type
        if (param.type_annotation) |type_ann| {
            var buf = std.ArrayList(u8).init(self.allocator);
            defer buf.deinit();

            const writer = buf.writer();

            if (param.is_mut) {
                try writer.writeAll("Mutable parameter of type ");
            } else {
                try writer.writeAll("Parameter of type ");
            }

            try self.formatType(&writer, type_ann);

            return try self.allocator.dupe(u8, buf.items);
        }

        return null;
    }

    /// Generate documentation for a function
    fn generateFunctionDoc(self: *SignatureHelpProvider, func: ast.FunctionDecl) !?[]const u8 {
        if (func.doc_comment) |doc| {
            return try self.allocator.dupe(u8, doc);
        }

        // Generate basic documentation
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        const writer = buf.writer();

        if (func.is_pub) {
            try writer.writeAll("Public ");
        }

        if (func.is_async) {
            try writer.writeAll("async function");
        } else {
            try writer.writeAll("function");
        }

        if (func.return_type) |ret_type| {
            try writer.writeAll(" returning ");
            try self.formatType(&writer, ret_type);
        }

        return try self.allocator.dupe(u8, buf.items);
    }

    /// Get signature help at a position in the document
    pub fn getSignatureHelp(
        self: *SignatureHelpProvider,
        doc_text: []const u8,
        line: u32,
        character: u32,
    ) !?SignatureHelp {
        // Find the function call context at the cursor position
        const call_context = try self.findCallContext(doc_text, line, character) orelse return null;
        defer self.allocator.free(call_context.function_name);

        // Look up the function signature
        const signature = self.function_signatures.get(call_context.function_name) orelse return null;

        // Build signature information
        var signatures = try self.allocator.alloc(SignatureInformation, 1);

        signatures[0] = .{
            .label = try self.allocator.dupe(u8, signature.label),
            .documentation = if (signature.documentation) |doc|
                try self.allocator.dupe(u8, doc)
            else
                null,
            .parameters = try self.allocator.alloc(ParameterInformation, signature.parameters.len),
            .active_parameter = call_context.active_parameter,
        };

        // Copy parameters
        for (signature.parameters, 0..) |param, i| {
            signatures[0].parameters[i] = .{
                .label = try self.allocator.dupe(u8, param.label),
                .documentation = if (param.documentation) |doc|
                    try self.allocator.dupe(u8, doc)
                else
                    null,
            };
        }

        return SignatureHelp{
            .signatures = signatures,
            .active_signature = 0,
            .active_parameter = call_context.active_parameter,
        };
    }

    const CallContext = struct {
        function_name: []const u8,
        active_parameter: u32,
    };

    /// Find the function call context at the cursor position
    fn findCallContext(self: *SignatureHelpProvider, doc_text: []const u8, line: u32, character: u32) !?CallContext {
        // Split document into lines
        var lines = std.mem.split(u8, doc_text, "\n");
        var current_line: u32 = 0;

        // Find the target line
        while (lines.next()) |line_text| {
            if (current_line == line) {
                // We're on the right line, now find the function call
                return try self.findCallInLine(line_text, character);
            }
            current_line += 1;
        }

        return null;
    }

    /// Find the function call in a line
    fn findCallInLine(self: *SignatureHelpProvider, line_text: []const u8, character: u32) !?CallContext {
        if (character > line_text.len) return null;

        // Search backwards from cursor position to find the function name and opening paren
        var paren_depth: i32 = 0;
        var i: usize = @min(character, line_text.len);

        // First, find the matching opening parenthesis
        while (i > 0) {
            i -= 1;
            const c = line_text[i];

            if (c == ')') {
                paren_depth += 1;
            } else if (c == '(') {
                if (paren_depth == 0) {
                    // Found the opening paren for our call
                    break;
                }
                paren_depth -= 1;
            }
        }

        if (i == 0 and line_text[0] != '(') {
            return null; // No opening paren found
        }

        // Extract function name before the opening paren
        var func_end = i;
        while (func_end > 0 and std.ascii.isWhitespace(line_text[func_end - 1])) {
            func_end -= 1;
        }

        var func_start = func_end;
        while (func_start > 0) {
            const c = line_text[func_start - 1];
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.')) {
                break;
            }
            func_start -= 1;
        }

        if (func_start == func_end) {
            return null; // No function name found
        }

        const function_name = try self.allocator.dupe(u8, line_text[func_start..func_end]);

        // Count commas to determine active parameter
        var active_parameter: u32 = 0;
        paren_depth = 0;
        i = func_end + 1; // Start after opening paren

        while (i < character) : (i += 1) {
            const c = line_text[i];

            if (c == '(') {
                paren_depth += 1;
            } else if (c == ')') {
                paren_depth -= 1;
            } else if (c == ',' and paren_depth == 0) {
                active_parameter += 1;
            }
        }

        return CallContext{
            .function_name = function_name,
            .active_parameter = active_parameter,
        };
    }

    /// Add built-in function signatures
    pub fn addBuiltins(self: *SignatureHelpProvider) !void {
        // Common built-in functions
        const builtins = [_]struct {
            name: []const u8,
            label: []const u8,
            doc: []const u8,
            params: []const ParameterInformation,
        }{
            .{
                .name = "print",
                .label = "fn print(message: String)",
                .doc = "Prints a message to stdout",
                .params = &[_]ParameterInformation{.{
                    .label = "message: String",
                    .documentation = "The message to print",
                }},
            },
            .{
                .name = "println",
                .label = "fn println(message: String)",
                .doc = "Prints a message to stdout with a newline",
                .params = &[_]ParameterInformation{.{
                    .label = "message: String",
                    .documentation = "The message to print",
                }},
            },
            .{
                .name = "assert",
                .label = "fn assert(condition: bool, message: String)",
                .doc = "Asserts that a condition is true, panics with message if false",
                .params = &[_]ParameterInformation{
                    .{
                        .label = "condition: bool",
                        .documentation = "The condition to check",
                    },
                    .{
                        .label = "message: String",
                        .documentation = "Error message if assertion fails",
                    },
                },
            },
            .{
                .name = "panic",
                .label = "fn panic(message: String) -> !",
                .doc = "Immediately terminates the program with an error message",
                .params = &[_]ParameterInformation{.{
                    .label = "message: String",
                    .documentation = "The panic message",
                }},
            },
        };

        for (builtins) |builtin| {
            const key = try self.allocator.dupe(u8, builtin.name);
            const params = try self.allocator.alloc(ParameterInformation, builtin.params.len);

            for (builtin.params, 0..) |param, i| {
                params[i] = .{
                    .label = try self.allocator.dupe(u8, param.label),
                    .documentation = if (param.documentation) |doc|
                        try self.allocator.dupe(u8, doc)
                    else
                        null,
                };
            }

            try self.function_signatures.put(key, .{
                .label = try self.allocator.dupe(u8, builtin.label),
                .documentation = try self.allocator.dupe(u8, builtin.doc),
                .parameters = params,
            });
        }
    }
};

test "SignatureHelpProvider - basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var provider = SignatureHelpProvider.init(allocator);
    defer provider.deinit();

    try provider.addBuiltins();

    // Test getting signature for print function
    const line = "print(\"Hello\")";
    const help = try provider.getSignatureHelp(line, 0, 7); // Cursor inside the call
    try testing.expect(help != null);

    if (help) |h| {
        defer h.deinit(allocator);
        try testing.expect(h.signatures.len > 0);
        try testing.expectEqualStrings("fn print(message: String)", h.signatures[0].label);
    }
}
