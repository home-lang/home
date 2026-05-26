// Copied from bun/src/jsc/JSType.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// JSC-bridge methods omitted: `toTypedArrayType` returns
// `bun.jsc.ArrayBuffer.TypedArrayType` which depends on the as-yet-unported
// `ArrayBuffer` opaque. Re-lands in Phase 12.2.

const jsc = @import("home_rt").jsc;

/// JSType is a critical performance optimization in JavaScriptCore that enables O(1) type
/// identification for JavaScript values without virtual function calls or expensive RTTI.
///
/// THE FUNDAMENTAL ARCHITECTURE:
///
/// JSValue (64-bit on modern platforms):
/// ┌─────────────────────────────────────────────────────────────────┐
/// │ Either: Immediate value (int32, bool, null, undefined, double)   │
/// │    Or:  Pointer to JSCell + type bits                           │
/// └─────────────────────────────────────────────────────────────────┘
///
/// JSCell (base class for all heap objects):
/// ┌─────────────────────────────────────────────────────────────────┐
/// │ m_structureID │ m_indexingTypeAndMisc │ m_type │ m_flags │ ...   │
/// │               │                       │ (u8)   │         │       │
/// └─────────────────────────────────────────────────────────────────┘
///                                           ↑
///                                      JSType enum
///
/// PERFORMANCE CRITICAL DESIGN:
///
/// Instead of virtual function calls like:
///   if (cell->isString()) // virtual call overhead
///
/// JavaScriptCore uses direct memory access:
///   if (cell->type() == StringType) // single memory load + compare
///
/// This JSType enum provides the complete taxonomy of JavaScript runtime types,
/// enabling the engine to make blazing-fast type decisions that are essential
/// for JavaScript's dynamic nature.
///
/// TYPE HIERARCHY MAPPING:
///
/// JavaScript Primitives → JSType:
/// • string → String (heap-allocated) or immediate (small strings)
/// • number → immediate double/int32 or HeapBigInt
/// • boolean → immediate true/false
/// • symbol → Symbol
/// • bigint → HeapBigInt or BigInt32 (immediate)
/// • null/undefined → immediate values
///
/// JavaScript Objects → JSType:
/// • {} → Object, FinalObject
/// • [] → Array, DerivedArray
/// • function → JSFunction, InternalFunction
/// • new Int8Array() → Int8Array
/// • new Error() → ErrorInstance
/// • arguments → DirectArguments, ScopedArguments
///
/// Engine Internals → JSType:
/// • Structure → metadata for object layout optimization
/// • CodeBlock → compiled JavaScript bytecode
/// • Executable → function compilation units
///
/// FAST PATH OPTIMIZATIONS:
///
/// The JSType enables JavaScriptCore's legendary performance through:
///
/// 1. Inline Caching: "This property access was on a String last time,
///    check if it's still a String with one comparison"
///
/// 2. Speculative Compilation: "This function usually gets Arrays,
///    generate optimized code for Arrays and deoptimize if wrong"
///
/// 3. Polymorphic Inline Caches: "This call site sees Objects and Arrays,
///    generate a fast switch on JSType"
///
/// 4. Type Guards: "Assume this is a String, insert a type check,
///    and generate optimal string operations"
///
/// MEMORY LAYOUT OPTIMIZATION:
///
/// JSType is strategically placed in JSCell's header for cache efficiency.
/// A typical property access like obj.prop becomes:
///
/// 1. Load JSCell* from JSValue (1 instruction)
/// 2. Load JSType from JSCell header (1 instruction, same cache line)
/// 3. Compare JSType against expected type (1 instruction)
/// 4. Branch to optimized or generic path
///
/// This 3-instruction type check is what makes JavaScript competitive
/// with statically typed languages in hot code paths.
///
/// The enum values are carefully ordered to enable range checks:
/// • All typed arrays are consecutive (Int8Array..Float64Array)
/// • All function types are grouped together
/// • All array types are adjacent
///
/// This allows optimizations like:
///   if (type >= Int8Array && type <= Float64Array) // single range check
///   if (type >= JSFunction && type <= InternalFunction) // function check
pub const JSType = enum(u8) {
    /// Base type for all JavaScript values that are heap-allocated.
    /// Every object, function, string, etc. in JavaScript inherits from JSCell.
    Cell = 0,

    /// Metadata object that describes the layout and properties of JavaScript objects.
    /// Critical for property access optimization and inline caching.
    Structure = 1,

    /// JavaScript string primitive.
    String = 2,

    /// Arbitrary precision integer type for JavaScript BigInt values.
    HeapBigInt = 3,

    /// Heap-allocated double values (new in recent WebKit).
    HeapDouble = 4,

    /// Heap-allocated int32 values (new in recent WebKit).
    HeapInt32 = 5,

    /// JavaScript Symbol primitive - unique identifiers.
    Symbol = 6,

    /// Accessor property descriptor containing getter and/or setter functions.
    GetterSetter = 7,

    /// Custom native getter/setter implementation for built-in properties.
    CustomGetterSetter = 8,

    /// Wrapper for native API values exposed to JavaScript.
    APIValueWrapper = 9,

    /// Compiled native code executable for built-in functions.
    NativeExecutable = 10,

    /// Compiled executable for top-level program code.
    ProgramExecutable = 11,

    /// Compiled executable for ES6 module code.
    ModuleProgramExecutable = 12,

    /// Compiled executable for eval() expressions.
    EvalExecutable = 13,

    /// Compiled executable for function bodies.
    FunctionExecutable = 14,

    UnlinkedFunctionExecutable = 15,
    UnlinkedProgramCodeBlock = 16,
    UnlinkedModuleProgramCodeBlock = 17,
    UnlinkedEvalCodeBlock = 18,
    UnlinkedFunctionCodeBlock = 19,

    /// Compiled bytecode block ready for execution.
    CodeBlock = 20,

    JSCellButterfly = 21,
    JSSourceCode = 22,

    /// Slim promise reaction (no rejection handler / context payload).
    SlimPromiseReaction = 23,

    /// Full promise reaction (carries onFulfilled/onRejected and async context).
    FullPromiseReaction = 24,

    /// Context object for Promise.all() operations.
    PromiseAllContext = 25,

    /// Global context for Promise.all() (new in recent WebKit).
    PromiseAllGlobalContext = 26,

    /// Microtask dispatcher for promise/microtask queue management.
    JSMicrotaskDispatcher = 27,

    /// Module loader registry entry (new C++ module loader).
    ModuleRegistryEntry = 28,

    /// Module loading context (new C++ module loader).
    ModuleLoadingContext = 29,

    /// Module loader payload (new C++ module loader).
    ModuleLoaderPayload = 30,

    /// Module graph loading state (new C++ module loader).
    ModuleGraphLoadingState = 31,

    /// JSModuleLoader cell type (new C++ module loader).
    JSModuleLoader = 32,

    /// Base JavaScript object type.
    Object = 33,

    /// Optimized object type for object literals with fixed properties.
    FinalObject = 34,

    JSCallee = 35,

    /// JavaScript function object created from JavaScript source code.
    JSFunction = 36,

    /// Built-in function implemented in native code.
    InternalFunction = 37,

    NullSetterFunction = 38,

    /// Boxed Boolean object.
    BooleanObject = 39,

    /// Boxed Number object.
    NumberObject = 40,

    /// JavaScript Error object and its subclasses.
    ErrorInstance = 41,

    GlobalProxy = 42,

    /// Arguments object for function parameters.
    DirectArguments = 43,

    ScopedArguments = 44,
    ClonedArguments = 45,

    /// JavaScript Array object.
    Array = 46,

    /// Array subclass created through class extension.
    DerivedArray = 47,

    /// ArrayBuffer for binary data storage.
    ArrayBuffer = 48,

    /// Typed array for 8-bit signed integers.
    Int8Array = 49,

    /// Typed array for 8-bit unsigned integers.
    Uint8Array = 50,

    /// Typed array for 8-bit unsigned integers with clamping.
    Uint8ClampedArray = 51,

    /// Typed array for 16-bit signed integers.
    Int16Array = 52,

    /// Typed array for 16-bit unsigned integers.
    Uint16Array = 53,

    /// Typed array for 32-bit signed integers.
    Int32Array = 54,

    /// Typed array for 32-bit unsigned integers.
    Uint32Array = 55,

    /// Typed array for 16-bit floating point numbers.
    Float16Array = 56,

    /// Typed array for 32-bit floating point numbers.
    Float32Array = 57,

    /// Typed array for 64-bit floating point numbers.
    Float64Array = 58,

    /// Typed array for 64-bit signed BigInt values.
    BigInt64Array = 59,

    /// Typed array for 64-bit unsigned BigInt values.
    BigUint64Array = 60,

    /// DataView for flexible binary data access.
    DataView = 61,

    /// Global object containing all global variables and functions.
    GlobalObject = 62,

    GlobalLexicalEnvironment = 63,
    LexicalEnvironment = 64,
    ModuleEnvironment = 65,
    StrictEvalActivation = 66,

    /// Scope object for with statements.
    WithScope = 67,

    AsyncDisposableStack = 68,
    DisposableStack = 69,

    /// Namespace object for ES6 modules.
    ModuleNamespaceObject = 70,

    ShadowRealm = 71,

    /// Regular expression object.
    RegExpObject = 72,

    /// JavaScript Date object for date/time operations.
    JSDate = 73,

    /// Proxy object that intercepts operations on another object.
    ProxyObject = 74,

    /// Generator object created by generator functions.
    Generator = 75,

    /// Async generator object for asynchronous iteration.
    AsyncGenerator = 76,

    /// Iterator for Array objects.
    JSArrayIterator = 77,

    Iterator = 78,
    IteratorHelper = 79,

    /// Iterator for Map objects.
    MapIterator = 80,

    /// Iterator for Set objects.
    SetIterator = 81,

    /// Iterator for String objects.
    StringIterator = 82,

    WrapForValidIterator = 83,

    /// Iterator for RegExp string matching.
    RegExpStringIterator = 84,

    AsyncFromSyncIterator = 85,

    /// JavaScript Promise object for asynchronous operations.
    JSPromise = 86,

    /// JavaScript Map object for key-value storage.
    Map = 87,

    /// JavaScript Set object for unique value storage.
    Set = 88,

    /// WeakMap for weak key-value references.
    WeakMap = 89,

    /// WeakSet for weak value references.
    WeakSet = 90,

    WebAssemblyModule = 91,
    WebAssemblyInstance = 92,
    WebAssemblyGCObject = 93,

    /// Boxed String object.
    StringObject = 94,

    DerivedStringObject = 95,
    InternalFieldTuple = 96,

    MaxJS = 0b11111111,
    Event = 0b11101111,
    DOMWrapper = 0b11101110,
    EmbedderArrayLike = 0b11101101,

    /// This means that we don't have Zig bindings for the type yet, but it
    /// implements .toJSON()
    JSAsJSONType = 0b11110000 | 1,
    _,

    pub const min_typed_array: JSType = .Int8Array;
    pub const max_typed_array: JSType = .DataView;

    pub fn canGet(this: JSType) bool {
        return switch (this) {
            .Array,
            .ArrayBuffer,
            .BigInt64Array,
            .BigUint64Array,
            .BooleanObject,
            .DOMWrapper,
            .DataView,
            .DerivedArray,
            .DerivedStringObject,
            .ErrorInstance,
            .Event,
            .FinalObject,
            .Float32Array,
            .Float16Array,
            .Float64Array,
            .GlobalObject,
            .Int16Array,
            .Int32Array,
            .Int8Array,
            .InternalFunction,
            .JSArrayIterator,
            .AsyncGenerator,
            .JSDate,
            .JSFunction,
            .Generator,
            .Map,
            .MapIterator,
            .JSPromise,
            .Set,
            .SetIterator,
            .IteratorHelper,
            .Iterator,
            .StringIterator,
            .WeakMap,
            .WeakSet,
            .ModuleNamespaceObject,
            .NumberObject,
            .Object,
            .ProxyObject,
            .RegExpObject,
            .ShadowRealm,
            .StringObject,
            .Uint16Array,
            .Uint32Array,
            .Uint8Array,
            .Uint8ClampedArray,
            .WebAssemblyModule,
            .WebAssemblyInstance,
            .WebAssemblyGCObject,
            => true,
            else => false,
        };
    }

    pub inline fn isObject(this: JSType) bool {
        // inline constexpr bool isObjectType(JSType type) { return type >= ObjectType; }
        return @intFromEnum(this) >= @intFromEnum(JSType.Object);
    }

    pub fn isFunction(this: JSType) bool {
        return switch (this) {
            .JSFunction, .FunctionExecutable, .InternalFunction => true,
            else => false,
        };
    }

    pub fn isTypedArrayOrArrayBuffer(this: JSType) bool {
        return switch (this) {
            .ArrayBuffer,
            .BigInt64Array,
            .BigUint64Array,
            .Float32Array,
            .Float16Array,
            .Float64Array,
            .Int16Array,
            .Int32Array,
            .Int8Array,
            .Uint16Array,
            .Uint32Array,
            .Uint8Array,
            .Uint8ClampedArray,
            => true,
            else => false,
        };
    }

    pub fn isArrayBufferLike(this: JSType) bool {
        return switch (this) {
            .DataView,
            .ArrayBuffer,
            .BigInt64Array,
            .BigUint64Array,
            .Float32Array,
            .Float16Array,
            .Float64Array,
            .Int16Array,
            .Int32Array,
            .Int8Array,
            .Uint16Array,
            .Uint32Array,
            .Uint8Array,
            .Uint8ClampedArray,
            => true,
            else => false,
        };
    }

    pub fn isTypedArray(this: JSType) bool {
        return switch (this) {
            .BigInt64Array,
            .BigUint64Array,
            .Float32Array,
            .Float16Array,
            .Float64Array,
            .Int16Array,
            .Int32Array,
            .Int8Array,
            .Uint16Array,
            .Uint32Array,
            .Uint8Array,
            .Uint8ClampedArray,
            => true,
            else => false,
        };
    }

    pub fn toTypedArrayType(this: JSType) jsc.ArrayBuffer.TypedArrayType {
        return switch (this) {
            .Int8Array => .TypeInt8,
            .Int16Array => .TypeInt16,
            .Int32Array => .TypeInt32,
            .Uint8Array => .TypeUint8,
            .Uint8ClampedArray => .TypeUint8Clamped,
            .Uint16Array => .TypeUint16,
            .Uint32Array => .TypeUint32,
            .Float16Array => .TypeFloat16,
            .Float32Array => .TypeFloat32,
            .Float64Array => .TypeFloat64,
            .BigInt64Array => .TypeBigInt64,
            .BigUint64Array => .TypeBigUint64,
            .DataView => .TypeDataView,
            else => .TypeNone,
        };
    }

    pub fn isHidden(this: JSType) bool {
        return switch (this) {
            .APIValueWrapper,
            .NativeExecutable,
            .ProgramExecutable,
            .ModuleProgramExecutable,
            .EvalExecutable,
            .FunctionExecutable,
            .UnlinkedFunctionExecutable,
            .UnlinkedProgramCodeBlock,
            .UnlinkedModuleProgramCodeBlock,
            .UnlinkedEvalCodeBlock,
            .UnlinkedFunctionCodeBlock,
            .CodeBlock,
            .JSCellButterfly,
            .JSSourceCode,
            .SlimPromiseReaction,
            .FullPromiseReaction,
            .PromiseAllContext,
            .PromiseAllGlobalContext,
            => true,
            else => false,
        };
    }

    pub const LastMaybeFalsyCellPrimitive = JSType.HeapBigInt;
    pub const LastJSCObject = JSType.InternalFieldTuple; // This is the last "JSC" Object type. After this, we have embedder's (e.g., WebCore) extended object types.

    pub inline fn isString(this: JSType) bool {
        return this == .String;
    }

    pub inline fn isStringObject(this: JSType) bool {
        return this == .StringObject;
    }

    pub inline fn isDerivedStringObject(this: JSType) bool {
        return this == .DerivedStringObject;
    }

    pub inline fn isStringObjectLike(this: JSType) bool {
        return this == .StringObject or this == .DerivedStringObject;
    }

    pub inline fn isStringLike(this: JSType) bool {
        return switch (this) {
            .String, .StringObject, .DerivedStringObject => true,
            else => false,
        };
    }

    pub inline fn isArray(this: JSType) bool {
        return switch (this) {
            .Array, .DerivedArray => true,
            else => false,
        };
    }

    pub inline fn isArrayLike(this: JSType) bool {
        return switch (this) {
            .Array,
            .DerivedArray,

            .ArrayBuffer,
            .BigInt64Array,
            .BigUint64Array,
            .Float32Array,
            .Float16Array,
            .Float64Array,
            .Int16Array,
            .Int32Array,
            .Int8Array,
            .Uint16Array,
            .Uint32Array,
            .Uint8Array,
            .Uint8ClampedArray,
            => true,
            else => false,
        };
    }

    pub inline fn isSet(this: JSType) bool {
        return switch (this) {
            .Set, .WeakSet => true,
            else => false,
        };
    }

    pub inline fn isMap(this: JSType) bool {
        return switch (this) {
            .Map, .WeakMap => true,
            else => false,
        };
    }

    pub inline fn isIndexable(this: JSType) bool {
        return switch (this) {
            .Object,
            .FinalObject,
            .Array,
            .DerivedArray,
            .ErrorInstance,
            .JSFunction,
            .InternalFunction,

            .ArrayBuffer,
            .BigInt64Array,
            .BigUint64Array,
            .Float32Array,
            .Float16Array,
            .Float64Array,
            .Int16Array,
            .Int32Array,
            .Int8Array,
            .Uint16Array,
            .Uint32Array,
            .Uint8Array,
            .Uint8ClampedArray,
            => true,
            else => false,
        };
    }

    pub inline fn isArguments(this: JSType) bool {
        return switch (this) {
            .DirectArguments, .ClonedArguments, .ScopedArguments => true,
            else => false,
        };
    }
};

test "JSType classifies primitive tags" {
    const std = @import("std");
    try std.testing.expect(JSType.String.isString());
    try std.testing.expect(JSType.StringObject.isStringLike());
    try std.testing.expect(JSType.DerivedStringObject.isStringLike());
    try std.testing.expect(!JSType.Object.isString());
}

test "JSType.isObject uses range check" {
    const std = @import("std");
    try std.testing.expect(JSType.Object.isObject());
    try std.testing.expect(JSType.Array.isObject());
    try std.testing.expect(!JSType.String.isObject());
    try std.testing.expect(!JSType.Cell.isObject());
}

test "JSType.isFunction is restrictive" {
    const std = @import("std");
    try std.testing.expect(JSType.JSFunction.isFunction());
    try std.testing.expect(JSType.InternalFunction.isFunction());
    try std.testing.expect(!JSType.Array.isFunction());
}

test "JSType.isTypedArray excludes DataView and ArrayBuffer" {
    const std = @import("std");
    try std.testing.expect(JSType.Uint8Array.isTypedArray());
    try std.testing.expect(JSType.Float64Array.isTypedArray());
    try std.testing.expect(!JSType.DataView.isTypedArray());
    try std.testing.expect(!JSType.ArrayBuffer.isTypedArray());
    try std.testing.expect(JSType.DataView.isArrayBufferLike());
}

test "JSType.isArguments covers direct/scoped/cloned variants" {
    const std = @import("std");
    try std.testing.expect(JSType.DirectArguments.isArguments());
    try std.testing.expect(JSType.ScopedArguments.isArguments());
    try std.testing.expect(JSType.ClonedArguments.isArguments());
    try std.testing.expect(!JSType.Array.isArguments());
}
