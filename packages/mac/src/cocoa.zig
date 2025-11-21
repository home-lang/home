// Home Programming Language - Cocoa/AppKit FFI Bindings
// Provides macOS window management and event handling via Cocoa
//
// This module uses the Objective-C runtime to interface with macOS frameworks

const std = @import("std");
const ffi = @import("ffi");

// ============================================================================
// Objective-C Runtime Types
// ============================================================================

pub const id = ?*anyopaque;
pub const Class = ?*opaque {};
pub const SEL = ?*opaque {};
pub const IMP = ?*const fn () callconv(.C) void;
pub const Method = ?*opaque {};
pub const Ivar = ?*opaque {};
pub const Protocol = ?*opaque {};

pub const BOOL = u8;
pub const YES: BOOL = 1;
pub const NO: BOOL = 0;

pub const NSInteger = c_long;
pub const NSUInteger = c_ulong;
pub const CGFloat = f64;

// ============================================================================
// CoreGraphics Types
// ============================================================================

pub const CGPoint = extern struct {
    x: CGFloat,
    y: CGFloat,
};

pub const CGSize = extern struct {
    width: CGFloat,
    height: CGFloat,
};

pub const CGRect = extern struct {
    origin: CGPoint,
    size: CGSize,
};

pub fn CGRectMake(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) CGRect {
    return CGRect{
        .origin = CGPoint{ .x = x, .y = y },
        .size = CGSize{ .width = width, .height = height },
    };
}

pub const CGContextRef = ?*opaque {};

// ============================================================================
// NSRange
// ============================================================================

pub const NSRange = extern struct {
    location: NSUInteger,
    length: NSUInteger,
};

pub fn NSMakeRange(location: NSUInteger, length: NSUInteger) NSRange {
    return NSRange{ .location = location, .length = length };
}

// ============================================================================
// Objective-C Runtime Functions
// ============================================================================

pub extern "c" fn objc_getClass(name: [*:0]const u8) Class;
pub extern "c" fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extraBytes: usize) Class;
pub extern "c" fn objc_registerClassPair(cls: Class) void;
pub extern "c" fn objc_disposeClassPair(cls: Class) void;

pub extern "c" fn sel_registerName(str: [*:0]const u8) SEL;
pub extern "c" fn sel_getName(sel: SEL) [*:0]const u8;

pub extern "c" fn class_addMethod(cls: Class, name: SEL, imp: IMP, types: [*:0]const u8) BOOL;
pub extern "c" fn class_addIvar(cls: Class, name: [*:0]const u8, size: usize, alignment: u8, types: [*:0]const u8) BOOL;
pub extern "c" fn class_addProtocol(cls: Class, protocol: Protocol) BOOL;

pub extern "c" fn objc_getProtocol(name: [*:0]const u8) Protocol;

pub extern "c" fn object_getIvar(obj: id, ivar: Ivar) id;
pub extern "c" fn object_setIvar(obj: id, ivar: Ivar, value: id) void;
pub extern "c" fn object_getInstanceVariable(obj: id, name: [*:0]const u8, outValue: ?*?*anyopaque) Ivar;

// Message sending (variadic - requires wrapper functions)
pub extern "c" fn objc_msgSend() void;
pub extern "c" fn objc_msgSend_stret() void;
pub extern "c" fn objc_msgSend_fpret() void;

// Type-safe message send wrappers
pub fn msgSend(obj: id, selector: SEL, comptime ReturnType: type) ReturnType {
    const func = @as(*const fn (id, SEL) callconv(.c) ReturnType, @ptrCast(&objc_msgSend));
    return func(obj, selector);
}

pub fn msgSend1(obj: id, selector: SEL, comptime ReturnType: type, arg1: anytype) ReturnType {
    const func = @as(*const fn (id, SEL, @TypeOf(arg1)) callconv(.c) ReturnType, @ptrCast(&objc_msgSend));
    return func(obj, selector, arg1);
}

pub fn msgSend2(obj: id, selector: SEL, comptime ReturnType: type, arg1: anytype, arg2: anytype) ReturnType {
    const func = @as(*const fn (id, SEL, @TypeOf(arg1), @TypeOf(arg2)) callconv(.c) ReturnType, @ptrCast(&objc_msgSend));
    return func(obj, selector, arg1, arg2);
}

pub fn msgSend3(obj: id, selector: SEL, comptime ReturnType: type, arg1: anytype, arg2: anytype, arg3: anytype) ReturnType {
    const func = @as(*const fn (id, SEL, @TypeOf(arg1), @TypeOf(arg2), @TypeOf(arg3)) callconv(.c) ReturnType, @ptrCast(&objc_msgSend));
    return func(obj, selector, arg1, arg2, arg3);
}

pub fn msgSend4(obj: id, selector: SEL, comptime ReturnType: type, arg1: anytype, arg2: anytype, arg3: anytype, arg4: anytype) ReturnType {
    const func = @as(*const fn (id, SEL, @TypeOf(arg1), @TypeOf(arg2), @TypeOf(arg3), @TypeOf(arg4)) callconv(.c) ReturnType, @ptrCast(&objc_msgSend));
    return func(obj, selector, arg1, arg2, arg3, arg4);
}

// ============================================================================
// NSAutoreleasePool
// ============================================================================

pub extern "c" fn NSAutoreleasePoolPush() id;
pub extern "c" fn NSAutoreleasePoolPop(pool: id) void;

// ============================================================================
// NSApplication Constants
// ============================================================================

pub const NSApplicationActivationPolicy = enum(NSInteger) {
    Regular = 0,
    Accessory = 1,
    Prohibited = 2,
};

pub const NSWindowStyleMask = packed struct(NSUInteger) {
    borderless: bool = false,
    titled: bool = false,
    closable: bool = false,
    miniaturizable: bool = false,
    resizable: bool = false,
    _padding1: u3 = 0,
    textured_background: bool = false,
    unified_title_and_toolbar: bool = false,
    fullscreen: bool = false,
    fullsize_content_view: bool = false,
    utility_window: bool = false,
    doc_modal_window: bool = false,
    nonactivating_panel: bool = false,
    _padding2: u49 = 0,

    pub const Default = NSWindowStyleMask{
        .titled = true,
        .closable = true,
        .miniaturizable = true,
        .resizable = true,
    };
};

pub const NSBackingStoreType = enum(NSUInteger) {
    Retained = 0,
    Nonretained = 1,
    Buffered = 2,
};

pub const NSEventType = enum(NSUInteger) {
    LeftMouseDown = 1,
    LeftMouseUp = 2,
    RightMouseDown = 3,
    RightMouseUp = 4,
    MouseMoved = 5,
    LeftMouseDragged = 6,
    RightMouseDragged = 7,
    MouseEntered = 8,
    MouseExited = 9,
    KeyDown = 10,
    KeyUp = 11,
    FlagsChanged = 12,
    AppKitDefined = 13,
    SystemDefined = 14,
    ApplicationDefined = 15,
    Periodic = 16,
    CursorUpdate = 17,
    ScrollWheel = 22,
    TabletPoint = 23,
    TabletProximity = 24,
    OtherMouseDown = 25,
    OtherMouseUp = 26,
    OtherMouseDragged = 27,
};

pub const NSEventModifierFlags = packed struct(NSUInteger) {
    _padding1: u16 = 0,
    caps_lock: bool = false,
    shift: bool = false,
    control: bool = false,
    option: bool = false,
    command: bool = false,
    numeric_pad: bool = false,
    help: bool = false,
    function_: bool = false,
    _padding2: u40 = 0,
};

// ============================================================================
// OpenGL Context Constants
// ============================================================================

pub const NSOpenGLPixelFormatAttribute = enum(u32) {
    AllRenderers = 1,
    DoubleBuffer = 5,
    Stereo = 6,
    AuxBuffers = 7,
    ColorSize = 8,
    AlphaSize = 11,
    DepthSize = 12,
    StencilSize = 13,
    AccumSize = 14,
    MinimumPolicy = 51,
    MaximumPolicy = 52,
    OffScreen = 53,
    FullScreen = 54,
    SampleBuffers = 55,
    Samples = 56,
    AuxDepthStencil = 57,
    ColorFloat = 58,
    Multisample = 59,
    Supersample = 60,
    SampleAlpha = 61,
    RendererID = 70,
    SingleRenderer = 71,
    NoRecovery = 72,
    Accelerated = 73,
    ClosestPolicy = 74,
    Robust = 75,
    BackingStore = 76,
    MPSafe = 78,
    Window = 80,
    MultiScreen = 81,
    Compliant = 83,
    ScreenMask = 84,
    PixelBuffer = 90,
    RemotePixelBuffer = 91,
    AllowOfflineRenderers = 96,
    AcceleratedCompute = 97,
    OpenGLProfile = 99,
    VirtualScreenCount = 128,

    // Terminate attribute list
    Zero = 0,
};

pub const NSOpenGLProfileVersion = enum(u32) {
    Legacy = 0x1000,
    Core3_2 = 0x3200,
    Core4_1 = 0x4100,
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Get a selector by name
pub fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

/// Get a class by name
pub fn getClass(name: [*:0]const u8) Class {
    return objc_getClass(name);
}

/// Allocate an instance of a class
pub fn alloc(class: Class) id {
    return msgSend(class, sel("alloc"), id);
}

/// Initialize an instance
pub fn init(object: id) id {
    return msgSend(object, sel("init"), id);
}

/// Release an object
pub fn release(object: id) void {
    _ = msgSend(object, sel("release"), void);
}

/// Retain an object
pub fn retain(object: id) id {
    return msgSend(object, sel("retain"), id);
}

/// Autorelease an object
pub fn autorelease(object: id) id {
    return msgSend(object, sel("autorelease"), id);
}

/// Create NSString from C string
pub fn createNSString(str: [*:0]const u8) id {
    const NSString = getClass("NSString");
    const alloc_obj = alloc(NSString);
    return msgSend1(alloc_obj, sel("initWithUTF8String:"), id, str);
}

/// Create NSNumber from integer
pub fn createNSNumber(value: i64) id {
    const NSNumber = getClass("NSNumber");
    return msgSend1(NSNumber, sel("numberWithLongLong:"), id, value);
}

/// Create NSNumber from float
pub fn createNSNumberFloat(value: f64) id {
    const NSNumber = getClass("NSNumber");
    return msgSend1(NSNumber, sel("numberWithDouble:"), id, value);
}

// ============================================================================
// NSApplication Helpers
// ============================================================================

pub fn NSApp() id {
    const NSApplication = getClass("NSApplication");
    return msgSend(NSApplication, sel("sharedApplication"), id);
}

pub fn setActivationPolicy(policy: NSApplicationActivationPolicy) void {
    const app = NSApp();
    _ = msgSend1(app, sel("setActivationPolicy:"), BOOL, @intFromEnum(policy));
}

pub fn activateIgnoringOtherApps(app: id, flag: bool) void {
    _ = msgSend1(app, sel("activateIgnoringOtherApps:"), void, if (flag) YES else NO);
}

pub fn finishLaunching(app: id) void {
    _ = msgSend(app, sel("finishLaunching"), void);
}

pub fn run(app: id) void {
    _ = msgSend(app, sel("run"), void);
}

pub fn terminate(app: id) void {
    _ = msgSend1(app, sel("terminate:"), void, @as(id, null));
}

// ============================================================================
// NSWindow Helpers
// ============================================================================

pub fn createWindow(rect: CGRect, style: NSWindowStyleMask, backing: NSBackingStoreType, defer_display: bool) id {
    const NSWindow = getClass("NSWindow");
    const window = alloc(NSWindow);
    return msgSend4(
        window,
        sel("initWithContentRect:styleMask:backing:defer:"),
        id,
        rect,
        @as(NSUInteger, @bitCast(style)),
        @intFromEnum(backing),
        if (defer_display) YES else NO,
    );
}

pub fn setWindowTitle(window: id, title: [*:0]const u8) void {
    const title_str = createNSString(title);
    _ = msgSend1(window, sel("setTitle:"), void, title_str);
    release(title_str);
}

pub fn makeKeyAndOrderFront(window: id) void {
    _ = msgSend1(window, sel("makeKeyAndOrderFront:"), void, @as(id, null));
}

pub fn center(window: id) void {
    _ = msgSend(window, sel("center"), void);
}

pub fn setDelegate(window: id, delegate: id) void {
    _ = msgSend1(window, sel("setDelegate:"), void, delegate);
}

pub fn contentView(window: id) id {
    return msgSend(window, sel("contentView"), id);
}

// ============================================================================
// NSEvent Helpers
// ============================================================================

pub fn nextEventMatchingMask(app: id, mask: NSUInteger, untilDate: id, inMode: id, dequeue: bool) id {
    return msgSend4(
        app,
        sel("nextEventMatchingMask:untilDate:inMode:dequeue:"),
        id,
        mask,
        untilDate,
        inMode,
        if (dequeue) YES else NO,
    );
}

pub fn sendEvent(app: id, event: id) void {
    _ = msgSend1(app, sel("sendEvent:"), void, event);
}

pub fn eventType(event: id) NSEventType {
    const type_val = msgSend(event, sel("type"), NSUInteger);
    return @enumFromInt(type_val);
}

pub fn keyCode(event: id) u16 {
    return @intCast(msgSend(event, sel("keyCode"), c_ushort));
}

pub fn modifierFlags(event: id) NSEventModifierFlags {
    const flags = msgSend(event, sel("modifierFlags"), NSUInteger);
    return @bitCast(flags);
}

pub fn characters(event: id) id {
    return msgSend(event, sel("characters"), id);
}

pub fn mouseLocation(event: id) CGPoint {
    return msgSend(event, sel("locationInWindow"), CGPoint);
}

// ============================================================================
// NSOpenGLView Helpers
// ============================================================================

/// Create OpenGL pixel format from raw u32 attribute array
/// The array should be terminated with 0
pub fn createOpenGLPixelFormat(attributes: []const u32) id {
    const NSOpenGLPixelFormat = getClass("NSOpenGLPixelFormat");
    const pixel_format = alloc(NSOpenGLPixelFormat);
    return msgSend1(pixel_format, sel("initWithAttributes:"), id, attributes.ptr);
}

/// Create OpenGL pixel format from enum attributes
pub fn createOpenGLPixelFormatEnum(attributes: []const NSOpenGLPixelFormatAttribute) id {
    const NSOpenGLPixelFormat = getClass("NSOpenGLPixelFormat");
    const pixel_format = alloc(NSOpenGLPixelFormat);

    // Convert attributes to u32 array
    var attrs: std.ArrayList(u32) = .{};
    defer attrs.deinit(std.heap.page_allocator);

    for (attributes) |attr| {
        attrs.append(std.heap.page_allocator, @intFromEnum(attr)) catch unreachable;
    }
    attrs.append(std.heap.page_allocator, 0) catch unreachable; // Null-terminate

    return msgSend1(pixel_format, sel("initWithAttributes:"), id, attrs.items.ptr);
}

pub fn createOpenGLContext(pixel_format: id, share_context: ?id) id {
    const NSOpenGLContext = getClass("NSOpenGLContext");
    const context = alloc(NSOpenGLContext);
    return msgSend2(context, sel("initWithFormat:shareContext:"), id, pixel_format, share_context orelse @as(id, null));
}

pub fn makeCurrentContext(context: id) void {
    _ = msgSend(context, sel("makeCurrentContext"), void);
}

pub fn flushBuffer(context: id) void {
    _ = msgSend(context, sel("flushBuffer"), void);
}

pub fn setView(context: id, view: id) void {
    _ = msgSend1(context, sel("setView:"), void, view);
}

// ============================================================================
// Utility Functions
// ============================================================================

/// Get NSString as C string
pub fn getNSStringCString(ns_string: id, buffer: []u8) bool {
    const result = msgSend2(
        ns_string,
        sel("getCString:maxLength:encoding:"),
        BOOL,
        buffer.ptr,
        buffer.len,
        @as(NSUInteger, 4), // NSUTF8StringEncoding
    );
    return result == YES;
}

/// Create date for distant past (useful for non-blocking event polling)
pub fn distantPast() id {
    const NSDate = getClass("NSDate");
    return msgSend(NSDate, sel("distantPast"), id);
}

/// Create date for distant future
pub fn distantFuture() id {
    const NSDate = getClass("NSDate");
    return msgSend(NSDate, sel("distantFuture"), id);
}

/// Get default run loop mode
pub fn defaultRunLoopMode() id {
    const NSRunLoopCommonModes_ptr = @extern(*id, .{ .name = "NSDefaultRunLoopMode" });
    return NSRunLoopCommonModes_ptr.*;
}

// ============================================================================
// Virtual Key Codes (macOS)
// ============================================================================

pub const kVK_ANSI_A: u16 = 0x00;
pub const kVK_ANSI_S: u16 = 0x01;
pub const kVK_ANSI_D: u16 = 0x02;
pub const kVK_ANSI_F: u16 = 0x03;
pub const kVK_ANSI_H: u16 = 0x04;
pub const kVK_ANSI_G: u16 = 0x05;
pub const kVK_ANSI_Z: u16 = 0x06;
pub const kVK_ANSI_X: u16 = 0x07;
pub const kVK_ANSI_C: u16 = 0x08;
pub const kVK_ANSI_V: u16 = 0x09;
pub const kVK_ANSI_B: u16 = 0x0B;
pub const kVK_ANSI_Q: u16 = 0x0C;
pub const kVK_ANSI_W: u16 = 0x0D;
pub const kVK_ANSI_E: u16 = 0x0E;
pub const kVK_ANSI_R: u16 = 0x0F;
pub const kVK_ANSI_Y: u16 = 0x10;
pub const kVK_ANSI_T: u16 = 0x11;
pub const kVK_ANSI_1: u16 = 0x12;
pub const kVK_ANSI_2: u16 = 0x13;
pub const kVK_ANSI_3: u16 = 0x14;
pub const kVK_ANSI_4: u16 = 0x15;
pub const kVK_ANSI_6: u16 = 0x16;
pub const kVK_ANSI_5: u16 = 0x17;
pub const kVK_ANSI_Equal: u16 = 0x18;
pub const kVK_ANSI_9: u16 = 0x19;
pub const kVK_ANSI_7: u16 = 0x1A;
pub const kVK_ANSI_Minus: u16 = 0x1B;
pub const kVK_ANSI_8: u16 = 0x1C;
pub const kVK_ANSI_0: u16 = 0x1D;
pub const kVK_Return: u16 = 0x24;
pub const kVK_Tab: u16 = 0x30;
pub const kVK_Space: u16 = 0x31;
pub const kVK_Delete: u16 = 0x33;
pub const kVK_Escape: u16 = 0x35;
pub const kVK_LeftArrow: u16 = 0x7B;
pub const kVK_RightArrow: u16 = 0x7C;
pub const kVK_DownArrow: u16 = 0x7D;
pub const kVK_UpArrow: u16 = 0x7E;

// ============================================================================
// Tests
// ============================================================================

test "Cocoa types" {
    const testing = std.testing;

    // Verify sizes
    try testing.expectEqual(@as(usize, 16), @sizeOf(CGPoint));
    try testing.expectEqual(@as(usize, 16), @sizeOf(CGSize));
    try testing.expectEqual(@as(usize, 32), @sizeOf(CGRect));
}

test "CGRect creation" {
    const testing = std.testing;

    const rect = CGRectMake(0, 0, 800, 600);
    try testing.expectEqual(@as(CGFloat, 0), rect.origin.x);
    try testing.expectEqual(@as(CGFloat, 0), rect.origin.y);
    try testing.expectEqual(@as(CGFloat, 800), rect.size.width);
    try testing.expectEqual(@as(CGFloat, 600), rect.size.height);
}
