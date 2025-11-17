// Home Language - Window Module
// Cross-platform window creation

const std = @import("std");

pub const WindowConfig = struct {
    title: []const u8,
    width: u32,
    height: u32,
    resizable: bool = true,
    fullscreen: bool = false,
};

pub const Window = struct {
    handle: *anyopaque,
    width: u32,
    height: u32,
    is_open: bool,

    pub fn create(config: WindowConfig) !Window {
        // Stub - would use platform-specific APIs
        _ = config;
        return Window{
            .handle = undefined,
            .width = config.width,
            .height = config.height,
            .is_open = true,
        };
    }

    pub fn destroy(self: *Window) void {
        self.is_open = false;
    }

    pub fn pollEvents(self: *Window) bool {
        return self.is_open;
    }

    pub fn setTitle(self: *Window, title: []const u8) void {
        _ = self;
        _ = title;
    }

    pub fn resize(self: *Window, width: u32, height: u32) void {
        self.width = width;
        self.height = height;
    }

    pub fn setFullscreen(self: *Window, fullscreen: bool) void {
        _ = self;
        _ = fullscreen;
    }
};
