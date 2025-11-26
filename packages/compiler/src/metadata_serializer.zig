const std = @import("std");
const ast = @import("ast");
const types = @import("types");

/// Serializes and deserializes compilation metadata for incremental compilation
/// Stores type information, symbol tables, and other compilation artifacts
pub const MetadataSerializer = struct {
    allocator: std.mem.Allocator,

    pub const Metadata = struct {
        version: u32 = 1,
        module_name: []const u8,
        exports: []ExportedSymbol,
        imports: []ImportedSymbol,
        type_definitions: []TypeDefinition,
        function_signatures: []FunctionSignature,

        pub const ExportedSymbol = struct {
            name: []const u8,
            kind: SymbolKind,
            type_info: []const u8, // Serialized type information

            pub const SymbolKind = enum {
                Function,
                Type,
                Constant,
                Variable,
            };
        };

        pub const ImportedSymbol = struct {
            name: []const u8,
            module: []const u8,
            alias: ?[]const u8 = null,
        };

        pub const TypeDefinition = struct {
            name: []const u8,
            kind: TypeKind,
            fields: []Field,

            pub const TypeKind = enum {
                Struct,
                Enum,
                Trait,
                TypeAlias,
            };

            pub const Field = struct {
                name: []const u8,
                type_name: []const u8,
                offset: usize,
            };
        };

        pub const FunctionSignature = struct {
            name: []const u8,
            params: []Param,
            return_type: []const u8,
            is_generic: bool,

            pub const Param = struct {
                name: []const u8,
                type_name: []const u8,
            };
        };
    };

    pub fn init(allocator: std.mem.Allocator) MetadataSerializer {
        return .{ .allocator = allocator };
    }

    /// Serialize metadata to binary format
    pub fn serialize(self: *MetadataSerializer, metadata: Metadata) ![]const u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        errdefer buffer.deinit();

        const writer = buffer.writer();

        // Write version
        try writer.writeInt(u32, metadata.version, .little);

        // Write module name
        try self.writeString(writer, metadata.module_name);

        // Write exports
        try writer.writeInt(u32, @intCast(metadata.exports.len), .little);
        for (metadata.exports) |export_sym| {
            try self.writeExportedSymbol(writer, export_sym);
        }

        // Write imports
        try writer.writeInt(u32, @intCast(metadata.imports.len), .little);
        for (metadata.imports) |import_sym| {
            try self.writeImportedSymbol(writer, import_sym);
        }

        // Write type definitions
        try writer.writeInt(u32, @intCast(metadata.type_definitions.len), .little);
        for (metadata.type_definitions) |type_def| {
            try self.writeTypeDefinition(writer, type_def);
        }

        // Write function signatures
        try writer.writeInt(u32, @intCast(metadata.function_signatures.len), .little);
        for (metadata.function_signatures) |func_sig| {
            try self.writeFunctionSignature(writer, func_sig);
        }

        return buffer.toOwnedSlice();
    }

    /// Deserialize metadata from binary format
    pub fn deserialize(self: *MetadataSerializer, data: []const u8) !Metadata {
        var stream = std.io.fixedBufferStream(data);
        const reader = stream.reader();

        // Read version
        const version = try reader.readInt(u32, .little);
        if (version != 1) {
            return error.UnsupportedMetadataVersion;
        }

        // Read module name
        const module_name = try self.readString(reader);

        // Read exports
        const export_count = try reader.readInt(u32, .little);
        var exports = try self.allocator.alloc(Metadata.ExportedSymbol, export_count);
        for (exports) |*export_sym| {
            export_sym.* = try self.readExportedSymbol(reader);
        }

        // Read imports
        const import_count = try reader.readInt(u32, .little);
        var imports = try self.allocator.alloc(Metadata.ImportedSymbol, import_count);
        for (imports) |*import_sym| {
            import_sym.* = try self.readImportedSymbol(reader);
        }

        // Read type definitions
        const type_def_count = try reader.readInt(u32, .little);
        var type_definitions = try self.allocator.alloc(Metadata.TypeDefinition, type_def_count);
        for (type_definitions) |*type_def| {
            type_def.* = try self.readTypeDefinition(reader);
        }

        // Read function signatures
        const func_sig_count = try reader.readInt(u32, .little);
        var function_signatures = try self.allocator.alloc(Metadata.FunctionSignature, func_sig_count);
        for (function_signatures) |*func_sig| {
            func_sig.* = try self.readFunctionSignature(reader);
        }

        return .{
            .version = version,
            .module_name = module_name,
            .exports = exports,
            .imports = imports,
            .type_definitions = type_definitions,
            .function_signatures = function_signatures,
        };
    }

    /// Extract metadata from AST
    pub fn extractFromAST(self: *MetadataSerializer, program: *ast.Program, module_name: []const u8) !Metadata {
        var exports = std.ArrayList(Metadata.ExportedSymbol).init(self.allocator);
        var type_definitions = std.ArrayList(Metadata.TypeDefinition).init(self.allocator);
        var function_signatures = std.ArrayList(Metadata.FunctionSignature).init(self.allocator);

        // Walk AST and extract symbol information
        for (program.statements) |stmt| {
            switch (stmt) {
                .FunctionDecl => |func_decl| {
                    if (func_decl.is_public) {
                        try exports.append(.{
                            .name = try self.allocator.dupe(u8, func_decl.name),
                            .kind = .Function,
                            .type_info = try self.allocator.dupe(u8, "function"),
                        });
                    }

                    var params = try self.allocator.alloc(Metadata.FunctionSignature.Param, func_decl.params.len);
                    for (func_decl.params, 0..) |param, i| {
                        params[i] = .{
                            .name = try self.allocator.dupe(u8, param.name),
                            .type_name = try self.allocator.dupe(u8, "unknown"), // TODO: Get actual type
                        };
                    }

                    try function_signatures.append(.{
                        .name = try self.allocator.dupe(u8, func_decl.name),
                        .params = params,
                        .return_type = try self.allocator.dupe(u8, "unknown"), // TODO: Get actual return type
                        .is_generic = func_decl.generic_params.len > 0,
                    });
                },
                .StructDecl => |struct_decl| {
                    if (struct_decl.is_public) {
                        try exports.append(.{
                            .name = try self.allocator.dupe(u8, struct_decl.name),
                            .kind = .Type,
                            .type_info = try self.allocator.dupe(u8, "struct"),
                        });
                    }

                    var fields = try self.allocator.alloc(Metadata.TypeDefinition.Field, struct_decl.fields.len);
                    for (struct_decl.fields, 0..) |field, i| {
                        fields[i] = .{
                            .name = try self.allocator.dupe(u8, field.name),
                            .type_name = try self.allocator.dupe(u8, "unknown"), // TODO: Get actual type
                            .offset = i,
                        };
                    }

                    try type_definitions.append(.{
                        .name = try self.allocator.dupe(u8, struct_decl.name),
                        .kind = .Struct,
                        .fields = fields,
                    });
                },
                else => {},
            }
        }

        return .{
            .module_name = try self.allocator.dupe(u8, module_name),
            .exports = try exports.toOwnedSlice(),
            .imports = &.{}, // TODO: Extract imports
            .type_definitions = try type_definitions.toOwnedSlice(),
            .function_signatures = try function_signatures.toOwnedSlice(),
        };
    }

    // Helper methods for writing

    fn writeString(self: *MetadataSerializer, writer: anytype, str: []const u8) !void {
        _ = self;
        try writer.writeInt(u32, @intCast(str.len), .little);
        try writer.writeAll(str);
    }

    fn writeExportedSymbol(self: *MetadataSerializer, writer: anytype, symbol: Metadata.ExportedSymbol) !void {
        try self.writeString(writer, symbol.name);
        try writer.writeInt(u8, @intFromEnum(symbol.kind), .little);
        try self.writeString(writer, symbol.type_info);
    }

    fn writeImportedSymbol(self: *MetadataSerializer, writer: anytype, symbol: Metadata.ImportedSymbol) !void {
        try self.writeString(writer, symbol.name);
        try self.writeString(writer, symbol.module);
        if (symbol.alias) |alias| {
            try writer.writeInt(u8, 1, .little);
            try self.writeString(writer, alias);
        } else {
            try writer.writeInt(u8, 0, .little);
        }
    }

    fn writeTypeDefinition(self: *MetadataSerializer, writer: anytype, type_def: Metadata.TypeDefinition) !void {
        try self.writeString(writer, type_def.name);
        try writer.writeInt(u8, @intFromEnum(type_def.kind), .little);
        try writer.writeInt(u32, @intCast(type_def.fields.len), .little);
        for (type_def.fields) |field| {
            try self.writeString(writer, field.name);
            try self.writeString(writer, field.type_name);
            try writer.writeInt(u64, @intCast(field.offset), .little);
        }
    }

    fn writeFunctionSignature(self: *MetadataSerializer, writer: anytype, func_sig: Metadata.FunctionSignature) !void {
        try self.writeString(writer, func_sig.name);
        try writer.writeInt(u32, @intCast(func_sig.params.len), .little);
        for (func_sig.params) |param| {
            try self.writeString(writer, param.name);
            try self.writeString(writer, param.type_name);
        }
        try self.writeString(writer, func_sig.return_type);
        try writer.writeInt(u8, if (func_sig.is_generic) 1 else 0, .little);
    }

    // Helper methods for reading

    fn readString(self: *MetadataSerializer, reader: anytype) ![]const u8 {
        const len = try reader.readInt(u32, .little);
        const str = try self.allocator.alloc(u8, len);
        try reader.readNoEof(str);
        return str;
    }

    fn readExportedSymbol(self: *MetadataSerializer, reader: anytype) !Metadata.ExportedSymbol {
        const name = try self.readString(reader);
        const kind_int = try reader.readInt(u8, .little);
        const kind = @as(Metadata.ExportedSymbol.SymbolKind, @enumFromInt(kind_int));
        const type_info = try self.readString(reader);

        return .{
            .name = name,
            .kind = kind,
            .type_info = type_info,
        };
    }

    fn readImportedSymbol(self: *MetadataSerializer, reader: anytype) !Metadata.ImportedSymbol {
        const name = try self.readString(reader);
        const module = try self.readString(reader);
        const has_alias = try reader.readInt(u8, .little);
        const alias = if (has_alias == 1) try self.readString(reader) else null;

        return .{
            .name = name,
            .module = module,
            .alias = alias,
        };
    }

    fn readTypeDefinition(self: *MetadataSerializer, reader: anytype) !Metadata.TypeDefinition {
        const name = try self.readString(reader);
        const kind_int = try reader.readInt(u8, .little);
        const kind = @as(Metadata.TypeDefinition.TypeKind, @enumFromInt(kind_int));
        const field_count = try reader.readInt(u32, .little);

        var fields = try self.allocator.alloc(Metadata.TypeDefinition.Field, field_count);
        for (fields) |*field| {
            field.name = try self.readString(reader);
            field.type_name = try self.readString(reader);
            field.offset = @intCast(try reader.readInt(u64, .little));
        }

        return .{
            .name = name,
            .kind = kind,
            .fields = fields,
        };
    }

    fn readFunctionSignature(self: *MetadataSerializer, reader: anytype) !Metadata.FunctionSignature {
        const name = try self.readString(reader);
        const param_count = try reader.readInt(u32, .little);

        var params = try self.allocator.alloc(Metadata.FunctionSignature.Param, param_count);
        for (params) |*param| {
            param.name = try self.readString(reader);
            param.type_name = try self.readString(reader);
        }

        const return_type = try self.readString(reader);
        const is_generic = (try reader.readInt(u8, .little)) == 1;

        return .{
            .name = name,
            .params = params,
            .return_type = return_type,
            .is_generic = is_generic,
        };
    }
};
