const std = @import("std");

/// JavaScript interop for WebAssembly
///
/// Provides bindings for JavaScript APIs when running in a browser or Node.js
/// Features:
/// - JS function imports
/// - JS object manipulation
/// - DOM access
/// - Async/await support
/// - TypedArray conversion
pub const JSInterop = struct {
    allocator: std.mem.Allocator,
    imports: std.StringHashMap(JSValue),
    exports: std.StringHashMap(JSValue),

    /// JavaScript value representation
    pub const JSValue = union(enum) {
        undefined: void,
        null: void,
        boolean: bool,
        number: f64,
        string: []const u8,
        object: *JSObject,
        function: *JSFunction,
        array: *JSArray,

        pub fn isUndefined(self: JSValue) bool {
            return self == .undefined;
        }

        pub fn isNull(self: JSValue) bool {
            return self == .null;
        }

        pub fn toBool(self: JSValue) !bool {
            return switch (self) {
                .boolean => |b| b,
                .number => |n| n != 0,
                .string => |s| s.len > 0,
                .null, .undefined => false,
                else => true,
            };
        }

        pub fn toNumber(self: JSValue) !f64 {
            return switch (self) {
                .number => |n| n,
                .boolean => |b| if (b) 1.0 else 0.0,
                .string => |s| try std.fmt.parseFloat(f64, s),
                else => error.CannotConvertToNumber,
            };
        }

        pub fn toString(self: JSValue, allocator: std.mem.Allocator) ![]const u8 {
            return switch (self) {
                .string => |s| try allocator.dupe(u8, s),
                .number => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
                .boolean => |b| try allocator.dupe(u8, if (b) "true" else "false"),
                .undefined => try allocator.dupe(u8, "undefined"),
                .null => try allocator.dupe(u8, "null"),
                else => try allocator.dupe(u8, "[object]"),
            };
        }
    };

    pub const JSObject = struct {
        allocator: std.mem.Allocator,
        properties: std.StringHashMap(JSValue),

        pub fn init(allocator: std.mem.Allocator) JSObject {
            return .{
                .allocator = allocator,
                .properties = std.StringHashMap(JSValue).init(allocator),
            };
        }

        pub fn deinit(self: *JSObject) void {
            self.properties.deinit();
        }

        pub fn get(self: *JSObject, key: []const u8) ?JSValue {
            return self.properties.get(key);
        }

        pub fn set(self: *JSObject, key: []const u8, value: JSValue) !void {
            try self.properties.put(key, value);
        }

        pub fn has(self: *JSObject, key: []const u8) bool {
            return self.properties.contains(key);
        }

        pub fn delete(self: *JSObject, key: []const u8) bool {
            return self.properties.remove(key);
        }

        pub fn keys(self: *JSObject) ![][]const u8 {
            var key_list = std.ArrayList([]const u8).init(self.allocator);
            var it = self.properties.keyIterator();
            while (it.next()) |key| {
                try key_list.append(key.*);
            }
            return try key_list.toOwnedSlice();
        }
    };

    pub const JSArray = struct {
        allocator: std.mem.Allocator,
        elements: std.ArrayList(JSValue),

        pub fn init(allocator: std.mem.Allocator) JSArray {
            return .{
                .allocator = allocator,
                .elements = std.ArrayList(JSValue).init(allocator),
            };
        }

        pub fn deinit(self: *JSArray) void {
            self.elements.deinit();
        }

        pub fn get(self: *JSArray, index: usize) ?JSValue {
            if (index >= self.elements.items.len) return null;
            return self.elements.items[index];
        }

        pub fn set(self: *JSArray, index: usize, value: JSValue) !void {
            if (index >= self.elements.items.len) {
                try self.elements.resize(index + 1);
            }
            self.elements.items[index] = value;
        }

        pub fn push(self: *JSArray, value: JSValue) !void {
            try self.elements.append(value);
        }

        pub fn pop(self: *JSArray) ?JSValue {
            if (self.elements.items.len == 0) return null;
            return self.elements.pop();
        }

        pub fn length(self: *JSArray) usize {
            return self.elements.items.len;
        }
    };

    pub const JSFunction = struct {
        allocator: std.mem.Allocator,
        name: []const u8,
        callback: *const fn ([]const JSValue) anyerror!JSValue,

        pub fn init(
            allocator: std.mem.Allocator,
            name: []const u8,
            callback: *const fn ([]const JSValue) anyerror!JSValue,
        ) !JSFunction {
            return .{
                .allocator = allocator,
                .name = try allocator.dupe(u8, name),
                .callback = callback,
            };
        }

        pub fn deinit(self: *JSFunction) void {
            self.allocator.free(self.name);
        }

        pub fn call(self: *JSFunction, args: []const JSValue) !JSValue {
            return try self.callback(args);
        }
    };

    pub fn init(allocator: std.mem.Allocator) JSInterop {
        return .{
            .allocator = allocator,
            .imports = std.StringHashMap(JSValue).init(allocator),
            .exports = std.StringHashMap(JSValue).init(allocator),
        };
    }

    pub fn deinit(self: *JSInterop) void {
        self.imports.deinit();
        self.exports.deinit();
    }

    /// Import a JavaScript function
    pub fn importFunction(
        self: *JSInterop,
        name: []const u8,
        callback: *const fn ([]const JSValue) anyerror!JSValue,
    ) !void {
        const func = try self.allocator.create(JSFunction);
        func.* = try JSFunction.init(self.allocator, name, callback);
        try self.imports.put(name, .{ .function = func });
    }

    /// Export a value to JavaScript
    pub fn exportValue(self: *JSInterop, name: []const u8, value: JSValue) !void {
        try self.exports.put(name, value);
    }

    /// Get an imported value
    pub fn getImport(self: *JSInterop, name: []const u8) ?JSValue {
        return self.imports.get(name);
    }

    /// Get an exported value
    pub fn getExport(self: *JSInterop, name: []const u8) ?JSValue {
        return self.exports.get(name);
    }

    /// Call an imported JavaScript function
    pub fn callImport(self: *JSInterop, name: []const u8, args: []const JSValue) !JSValue {
        const value = self.getImport(name) orelse return error.ImportNotFound;
        if (value != .function) return error.NotAFunction;
        return try value.function.call(args);
    }
};

/// Bindings generator for JavaScript
pub const JSBindingsGenerator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) JSBindingsGenerator {
        return .{ .allocator = allocator };
    }

    /// Generate JavaScript bindings for a WASM module
    pub fn generate(self: *JSBindingsGenerator, module_name: []const u8, exports: []const Export) ![]const u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        const writer = buffer.writer();

        try writer.print(
            \\// Auto-generated JavaScript bindings for {s}
            \\
            \\export class {s} {{
            \\  constructor(wasmModule) {{
            \\    this.instance = wasmModule.instance;
            \\    this.memory = this.instance.exports.memory;
            \\  }}
            \\
            \\
        , .{ module_name, module_name });

        // Generate wrapper functions for exports
        for (exports) |exp| {
            if (exp.kind == .function) {
                try writer.print(
                    \\  {s}(...args) {{
                    \\    return this.instance.exports.{s}(...args);
                    \\  }}
                    \\
                    \\
                , .{ exp.name, exp.name });
            }
        }

        // Generate memory helpers
        try writer.writeAll(
            \\  readString(ptr, len) {
            \\    const bytes = new Uint8Array(this.memory.buffer, ptr, len);
            \\    return new TextDecoder().decode(bytes);
            \\  }
            \\
            \\  writeString(str) {
            \\    const encoder = new TextEncoder();
            \\    const bytes = encoder.encode(str);
            \\    const ptr = this.instance.exports.alloc(bytes.length);
            \\    const mem = new Uint8Array(this.memory.buffer, ptr, bytes.length);
            \\    mem.set(bytes);
            \\    return ptr;
            \\  }
            \\
            \\  readArray(ptr, len, type = 'i32') {
            \\    const TypedArray = {
            \\      'i32': Int32Array,
            \\      'i64': BigInt64Array,
            \\      'f32': Float32Array,
            \\      'f64': Float64Array,
            \\    }[type];
            \\    return new TypedArray(this.memory.buffer, ptr, len);
            \\  }
            \\}
            \\
            \\export async function load(wasmPath) {
            \\  const response = await fetch(wasmPath);
            \\  const bytes = await response.arrayBuffer();
            \\  const wasmModule = await WebAssembly.instantiate(bytes, {
            \\    env: {
            \\      // Import functions here
            \\    }
            \\  });
            \\  return new
        );

        try writer.print(" {s}(wasmModule);\n}}\n", .{module_name});

        return try buffer.toOwnedSlice();
    }

    pub const Export = struct {
        name: []const u8,
        kind: ExportKind,
    };

    pub const ExportKind = enum {
        function,
        memory,
        table,
        global,
    };
};

/// DOM API bindings for browser environment
pub const DOM = struct {
    /// Console API
    pub const console = struct {
        pub fn log(msg: []const u8) void {
            _ = msg;
            // In real implementation, this would call JS console.log
        }

        pub fn error(msg: []const u8) void {
            _ = msg;
            // In real implementation, this would call JS console.error
        }

        pub fn warn(msg: []const u8) void {
            _ = msg;
            // In real implementation, this would call JS console.warn
        }
    };

    /// Document API
    pub const document = struct {
        pub fn getElementById(id: []const u8) ?*Element {
            _ = id;
            // In real implementation, this would call JS document.getElementById
            return null;
        }

        pub fn querySelector(selector: []const u8) ?*Element {
            _ = selector;
            // In real implementation, this would call JS document.querySelector
            return null;
        }

        pub fn createElement(tag: []const u8) !*Element {
            _ = tag;
            // In real implementation, this would call JS document.createElement
            return error.NotImplemented;
        }
    };

    pub const Element = struct {
        id: []const u8,

        pub fn setAttribute(self: *Element, name: []const u8, value: []const u8) void {
            _ = self;
            _ = name;
            _ = value;
        }

        pub fn getAttribute(self: *Element, name: []const u8) ?[]const u8 {
            _ = self;
            _ = name;
            return null;
        }

        pub fn addEventListener(self: *Element, event: []const u8, handler: *const fn () void) void {
            _ = self;
            _ = event;
            _ = handler;
        }
    };
};
