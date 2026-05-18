// Copied from bun/src/runtime/node/fs_events.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// **Partial port (constants + Core Foundation FFI types only).**
//
// Upstream `fs_events.zig` (659 lines) is the macOS-only FSEvents
// watcher backing for `chokidar`/`node:fs.watch`. It bundles three
// concerns:
//
//   1. Core Foundation + Carbon (`FSEventStream*`) C ABI type aliases
//      and the `kFSEventStream*` event-flag constants.
//   2. The dlsym-loaded `CoreFoundation` / `CoreServices` helper
//      namespaces.
//   3. The `FSEventsLoop` / `FSEventsWatcher` runtime, which depends on
//      `bun.threading.UnboundedQueue`, `bun.Mutex`,
//      `bun.jsc.Node.fs.Watcher.Event`, and the sibling
//      `path_watcher.zig` — all unported substrate.
//
// Only (1) is ported here. The rest re-lands when the Watcher event
// substrate and `path_watcher.zig` are ready.
//
// No imports rewritten — this slice of upstream pulls only `std`.

const std = @import("std");

// ---- Core Foundation primitive types ---------------------------------------

pub const CFAbsoluteTime = f64;
pub const CFTimeInterval = f64;
pub const CFArrayCallBacks = anyopaque;

pub const FSEventStreamEventFlags = c_int;
pub const OSStatus = c_int;
pub const CFIndex = c_long;

pub const FSEventStreamCreateFlags = u32;
pub const FSEventStreamEventId = u64;

pub const CFStringEncoding = c_uint;

pub const CFArrayRef = ?*anyopaque;
pub const CFAllocatorRef = ?*anyopaque;
pub const CFBundleRef = ?*anyopaque;
pub const CFDictionaryRef = ?*anyopaque;
pub const CFRunLoopRef = ?*anyopaque;
pub const CFRunLoopSourceRef = ?*anyopaque;
pub const CFStringRef = ?*anyopaque;
pub const CFTypeRef = ?*anyopaque;
pub const FSEventStreamRef = ?*anyopaque;
pub const FSEventStreamCallback = *const fn (
    FSEventStreamRef,
    ?*anyopaque,
    usize,
    ?*anyopaque,
    *FSEventStreamEventFlags,
    *FSEventStreamEventId,
) callconv(.c) void;

/// We only care about `info` and `perform`; the rest of the slots stay
/// null because Bun never registers retain/release/equal/hash callbacks
/// for its CF run-loop source.
pub const CFRunLoopSourceContext = extern struct {
    version: CFIndex = 0,
    info: *anyopaque,
    retain: ?*anyopaque = null,
    release: ?*anyopaque = null,
    copyDescription: ?*anyopaque = null,
    equal: ?*anyopaque = null,
    hash: ?*anyopaque = null,
    schedule: ?*anyopaque = null,
    cancel: ?*anyopaque = null,
    perform: *const fn (?*anyopaque) callconv(.c) void,
};

pub const FSEventStreamContext = extern struct {
    version: CFIndex = 0,
    info: ?*anyopaque = null,
    pad: [3]?*anyopaque = .{ null, null, null },
};

// ---- Encoding + status constants -------------------------------------------

pub const kCFStringEncodingUTF8: CFStringEncoding = 0x8000100;
pub const noErr: OSStatus = 0;

// ---- FSEventStream create flags --------------------------------------------

pub const kFSEventStreamCreateFlagNoDefer: c_int = 2;
pub const kFSEventStreamCreateFlagFileEvents: c_int = 16;

// ---- FSEventStream event flags ---------------------------------------------

pub const kFSEventStreamEventFlagEventIdsWrapped: c_int = 8;
pub const kFSEventStreamEventFlagHistoryDone: c_int = 16;
pub const kFSEventStreamEventFlagItemChangeOwner: c_int = 0x4000;
pub const kFSEventStreamEventFlagItemCreated: c_int = 0x100;
pub const kFSEventStreamEventFlagItemFinderInfoMod: c_int = 0x2000;
pub const kFSEventStreamEventFlagItemInodeMetaMod: c_int = 0x400;
pub const kFSEventStreamEventFlagItemIsDir: c_int = 0x20000;
pub const kFSEventStreamEventFlagItemModified: c_int = 0x1000;
pub const kFSEventStreamEventFlagItemRemoved: c_int = 0x200;
pub const kFSEventStreamEventFlagItemRenamed: c_int = 0x800;
pub const kFSEventStreamEventFlagItemXattrMod: c_int = 0x8000;
pub const kFSEventStreamEventFlagKernelDropped: c_int = 4;
pub const kFSEventStreamEventFlagMount: c_int = 64;
pub const kFSEventStreamEventFlagUnmount: c_int = 128;
pub const kFSEventStreamEventFlagUserDropped: c_int = 2;
pub const kFSEventStreamEventFlagRootChanged: c_int = 32;

// ---- Composed event-class masks --------------------------------------------
// Upstream groups the individual flags into three logical event classes —
// `Modified`, `Renamed`, and `System` — that the path_watcher uses for
// per-event dispatch. The bit-OR order is preserved verbatim so it's
// 1:1 with upstream `path_watcher.zig`'s mask checks.

pub const kFSEventsModified: c_int =
    kFSEventStreamEventFlagItemChangeOwner |
    kFSEventStreamEventFlagItemFinderInfoMod |
    kFSEventStreamEventFlagItemInodeMetaMod |
    kFSEventStreamEventFlagItemModified |
    kFSEventStreamEventFlagItemXattrMod;

pub const kFSEventsRenamed: c_int =
    kFSEventStreamEventFlagItemCreated |
    kFSEventStreamEventFlagItemRemoved |
    kFSEventStreamEventFlagItemRenamed;

pub const kFSEventsSystem: c_int =
    kFSEventStreamEventFlagUserDropped |
    kFSEventStreamEventFlagKernelDropped |
    kFSEventStreamEventFlagEventIdsWrapped |
    kFSEventStreamEventFlagHistoryDone |
    kFSEventStreamEventFlagMount |
    kFSEventStreamEventFlagUnmount |
    kFSEventStreamEventFlagRootChanged;

// ---- Tests ----------------------------------------------------------------

test "fs_events: kFSEventsModified bit mask matches upstream composition" {
    // Upstream `path_watcher.zig` ANDs incoming event flags against this
    // mask to decide whether to emit a `change` event. If the bit
    // composition drifts, that classification silently breaks.
    const expected: c_int = 0x4000 | 0x2000 | 0x400 | 0x1000 | 0x8000;
    try std.testing.expectEqual(expected, kFSEventsModified);
}

test "fs_events: kFSEventsRenamed bit mask matches upstream composition" {
    const expected: c_int = 0x100 | 0x200 | 0x800;
    try std.testing.expectEqual(expected, kFSEventsRenamed);
}

test "fs_events: kFSEventsSystem bit mask matches upstream composition" {
    const expected: c_int = 2 | 4 | 8 | 16 | 64 | 128 | 32;
    try std.testing.expectEqual(expected, kFSEventsSystem);
}

test "fs_events: kCFStringEncodingUTF8 matches Apple's published constant" {
    // From `<CoreFoundation/CFString.h>`. Hard-coded because including
    // the system header pulls in the whole CF surface.
    try std.testing.expectEqual(@as(CFStringEncoding, 0x0800_0100), kCFStringEncodingUTF8);
}

test "fs_events: CFRunLoopSourceContext layout is C-ABI" {
    try std.testing.expectEqual(@as(usize, @alignOf(*anyopaque)), @alignOf(CFRunLoopSourceContext));
    // 1 CFIndex + 9 pointer-sized slots = 10 * pointer-size bytes on
    // every Apple platform Bun supports (all 64-bit).
    try std.testing.expectEqual(@as(usize, 10 * @sizeOf(*anyopaque)), @sizeOf(CFRunLoopSourceContext));
}

test "fs_events: FSEventStreamContext layout is C-ABI" {
    // `version` (CFIndex) + `info` + 3-element pad = 5 pointer-sized slots.
    try std.testing.expectEqual(@as(usize, 5 * @sizeOf(*anyopaque)), @sizeOf(FSEventStreamContext));
}
