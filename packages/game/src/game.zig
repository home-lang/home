// Home Programming Language - Game Development Framework
// Comprehensive game development utilities
//
// This module provides:
// - Craft integration (native cross-platform windowing, GPU, input)
// - Game loop utilities
// - Asset loading
// - A* Pathfinding
// - Entity-Component system basics
// - Replay system
// - Multiplayer networking foundation
// - Mod support infrastructure
// - Animation system

const std = @import("std");

// Re-export submodules
pub const loop = @import("game_loop.zig");
pub const assets = @import("assets.zig");
pub const pathfinding = @import("pathfinding.zig");
pub const ai = @import("ai.zig");
pub const replay = @import("replay.zig");
pub const network = @import("network.zig");
pub const mods = @import("mods.zig");
pub const ecs = @import("ecs.zig");

// ============================================================================
// Craft Integration Types
// These mirror Craft's API for seamless integration
// ============================================================================

/// Window configuration options (mirrors Craft's WindowOptions)
pub const WindowOptions = struct {
    title: []const u8 = "Home Game",
    width: u32 = 1200,
    height: u32 = 800,
    x: ?i32 = null,
    y: ?i32 = null,
    resizable: bool = true,
    frameless: bool = false,
    transparent: bool = false,
    always_on_top: bool = false,
    fullscreen: bool = false,
    dark_mode: ?bool = null,
    dev_tools: bool = false,
    titlebar_hidden: bool = false,
};

/// GPU backend options (mirrors Craft's GPUBackend)
pub const GPUBackend = enum {
    auto,
    metal, // macOS
    vulkan, // Linux/Windows
    opengl, // Fallback
    software, // No acceleration
};

/// GPU configuration (mirrors Craft's GPUConfig)
pub const GPUConfig = struct {
    backend: GPUBackend = .auto,
    vsync: bool = true,
    max_fps: ?u32 = null,
    hardware_decode: bool = true,
    canvas_acceleration: bool = true,
    power_preference: PowerPreference = .default,
};

pub const PowerPreference = enum {
    default,
    low_power, // Integrated GPU
    high_performance, // Discrete GPU
};

// ============================================================================
// Event Types (mirrors Craft's event system)
// ============================================================================

pub const EventType = enum {
    // Window events
    window_created,
    window_closed,
    window_resized,
    window_moved,
    window_focused,
    window_blurred,
    window_minimized,
    window_maximized,
    window_restored,

    // Input events
    key_down,
    key_up,
    mouse_down,
    mouse_up,
    mouse_move,
    mouse_wheel,

    // Application events
    app_started,
    app_stopped,
    app_paused,
    app_resumed,

    // Custom events
    custom,
};

pub const KeyEvent = struct {
    code: []const u8,
    key: []const u8,
    alt: bool = false,
    ctrl: bool = false,
    shift: bool = false,
    meta: bool = false,
};

pub const MouseEvent = struct {
    x: i32,
    y: i32,
    button: u8 = 0,
    alt: bool = false,
    ctrl: bool = false,
    shift: bool = false,
    meta: bool = false,
};

pub const ScrollEvent = struct {
    delta_x: f32,
    delta_y: f32,
};

pub const ResizeEvent = struct {
    width: u32,
    height: u32,
};

pub const Event = struct {
    event_type: EventType,
    timestamp: i64,
    key: ?KeyEvent = null,
    mouse: ?MouseEvent = null,
    scroll: ?ScrollEvent = null,
    resize: ?ResizeEvent = null,
    custom_name: ?[]const u8 = null,
    custom_data: ?[]const u8 = null,
};

pub const EventCallback = *const fn (event: Event) void;

// ============================================================================
// Input State (for polling-based input)
// ============================================================================

pub const InputState = struct {
    keys: std.AutoHashMap(u32, bool),
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    mouse_buttons: [5]bool = [_]bool{false} ** 5,
    mouse_wheel_x: f32 = 0,
    mouse_wheel_y: f32 = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) InputState {
        return .{
            .keys = std.AutoHashMap(u32, bool).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *InputState) void {
        self.keys.deinit();
    }

    pub fn isKeyDown(self: *const InputState, key_code: u32) bool {
        return self.keys.get(key_code) orelse false;
    }

    pub fn isMouseButtonDown(self: *const InputState, button: u8) bool {
        if (button < 5) {
            return self.mouse_buttons[button];
        }
        return false;
    }

    pub fn getMousePosition(self: *const InputState) struct { x: i32, y: i32 } {
        return .{ .x = self.mouse_x, .y = self.mouse_y };
    }

    pub fn getMouseWheel(self: *const InputState) struct { x: f32, y: f32 } {
        return .{ .x = self.mouse_wheel_x, .y = self.mouse_wheel_y };
    }

    pub fn handleEvent(self: *InputState, event: Event) void {
        switch (event.event_type) {
            .key_down => {
                if (event.key) |key| {
                    if (key.code.len > 0) {
                        self.keys.put(hashKeyCode(key.code), true) catch {};
                    }
                }
            },
            .key_up => {
                if (event.key) |key| {
                    if (key.code.len > 0) {
                        self.keys.put(hashKeyCode(key.code), false) catch {};
                    }
                }
            },
            .mouse_move => {
                if (event.mouse) |mouse| {
                    self.mouse_x = mouse.x;
                    self.mouse_y = mouse.y;
                }
            },
            .mouse_down => {
                if (event.mouse) |mouse| {
                    if (mouse.button < 5) {
                        self.mouse_buttons[mouse.button] = true;
                    }
                    self.mouse_x = mouse.x;
                    self.mouse_y = mouse.y;
                }
            },
            .mouse_up => {
                if (event.mouse) |mouse| {
                    if (mouse.button < 5) {
                        self.mouse_buttons[mouse.button] = false;
                    }
                    self.mouse_x = mouse.x;
                    self.mouse_y = mouse.y;
                }
            },
            .mouse_wheel => {
                if (event.scroll) |scroll| {
                    self.mouse_wheel_x = scroll.delta_x;
                    self.mouse_wheel_y = scroll.delta_y;
                }
            },
            else => {},
        }
    }

    fn hashKeyCode(code: []const u8) u32 {
        var hash: u32 = 0;
        for (code) |c| {
            hash = hash *% 31 +% @as(u32, c);
        }
        return hash;
    }
};

// Common key codes
pub const KeyCode = struct {
    pub const SPACE: u32 = hashStr("Space");
    pub const ENTER: u32 = hashStr("Enter");
    pub const ESCAPE: u32 = hashStr("Escape");
    pub const TAB: u32 = hashStr("Tab");
    pub const BACKSPACE: u32 = hashStr("Backspace");

    pub const ARROW_UP: u32 = hashStr("ArrowUp");
    pub const ARROW_DOWN: u32 = hashStr("ArrowDown");
    pub const ARROW_LEFT: u32 = hashStr("ArrowLeft");
    pub const ARROW_RIGHT: u32 = hashStr("ArrowRight");

    pub const KEY_A: u32 = hashStr("KeyA");
    pub const KEY_B: u32 = hashStr("KeyB");
    pub const KEY_C: u32 = hashStr("KeyC");
    pub const KEY_D: u32 = hashStr("KeyD");
    pub const KEY_E: u32 = hashStr("KeyE");
    pub const KEY_F: u32 = hashStr("KeyF");
    pub const KEY_G: u32 = hashStr("KeyG");
    pub const KEY_H: u32 = hashStr("KeyH");
    pub const KEY_I: u32 = hashStr("KeyI");
    pub const KEY_J: u32 = hashStr("KeyJ");
    pub const KEY_K: u32 = hashStr("KeyK");
    pub const KEY_L: u32 = hashStr("KeyL");
    pub const KEY_M: u32 = hashStr("KeyM");
    pub const KEY_N: u32 = hashStr("KeyN");
    pub const KEY_O: u32 = hashStr("KeyO");
    pub const KEY_P: u32 = hashStr("KeyP");
    pub const KEY_Q: u32 = hashStr("KeyQ");
    pub const KEY_R: u32 = hashStr("KeyR");
    pub const KEY_S: u32 = hashStr("KeyS");
    pub const KEY_T: u32 = hashStr("KeyT");
    pub const KEY_U: u32 = hashStr("KeyU");
    pub const KEY_V: u32 = hashStr("KeyV");
    pub const KEY_W: u32 = hashStr("KeyW");
    pub const KEY_X: u32 = hashStr("KeyX");
    pub const KEY_Y: u32 = hashStr("KeyY");
    pub const KEY_Z: u32 = hashStr("KeyZ");

    fn hashStr(comptime s: []const u8) u32 {
        var hash: u32 = 0;
        for (s) |c| {
            hash = hash *% 31 +% @as(u32, c);
        }
        return hash;
    }
};

// ============================================================================
// Rendering Types (mirrors Craft's renderer)
// ============================================================================

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const Size = struct {
    width: u32,
    height: u32,
};

/// Canvas for software rendering
pub const Canvas = struct {
    width: u32,
    height: u32,
    pixels: []u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Canvas {
        const pixels = try allocator.alloc(u32, width * height);
        @memset(pixels, 0xFFFFFFFF); // White background

        return Canvas{
            .width = width,
            .height = height,
            .pixels = pixels,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Canvas) void {
        self.allocator.free(self.pixels);
    }

    pub fn clear(self: *Canvas, color: Color) void {
        const pixel = color.toPixel();
        @memset(self.pixels, pixel);
    }

    pub fn drawRect(self: *Canvas, x: i32, y: i32, w: u32, h: u32, color: Color) void {
        const pixel = color.toPixel();

        var py: i32 = y;
        while (py < y + @as(i32, @intCast(h))) : (py += 1) {
            if (py < 0 or py >= @as(i32, @intCast(self.height))) continue;

            var px: i32 = x;
            while (px < x + @as(i32, @intCast(w))) : (px += 1) {
                if (px < 0 or px >= @as(i32, @intCast(self.width))) continue;

                const index = @as(usize, @intCast(py)) * self.width + @as(usize, @intCast(px));
                self.pixels[index] = pixel;
            }
        }
    }

    pub fn drawCircle(self: *Canvas, center_x: i32, center_y: i32, radius: u32, color: Color) void {
        const pixel = color.toPixel();
        const r_sq = @as(i32, @intCast(radius * radius));

        var py: i32 = center_y - @as(i32, @intCast(radius));
        while (py <= center_y + @as(i32, @intCast(radius))) : (py += 1) {
            if (py < 0 or py >= @as(i32, @intCast(self.height))) continue;

            var px: i32 = center_x - @as(i32, @intCast(radius));
            while (px <= center_x + @as(i32, @intCast(radius))) : (px += 1) {
                if (px < 0 or px >= @as(i32, @intCast(self.width))) continue;

                const dx = px - center_x;
                const dy = py - center_y;
                if (dx * dx + dy * dy <= r_sq) {
                    const index = @as(usize, @intCast(py)) * self.width + @as(usize, @intCast(px));
                    self.pixels[index] = pixel;
                }
            }
        }
    }

    pub fn drawLine(self: *Canvas, x0_in: i32, y0_in: i32, x1: i32, y1: i32, color: Color) void {
        const pixel = color.toPixel();

        var x0 = x0_in;
        var y0 = y0_in;

        const dx: i32 = @intCast(@abs(x1 - x0));
        const dy: i32 = @intCast(@abs(y1 - y0));
        const sx: i32 = if (x0 < x1) 1 else -1;
        const sy: i32 = if (y0 < y1) 1 else -1;
        var err = dx - dy;

        while (true) {
            if (x0 >= 0 and x0 < @as(i32, @intCast(self.width)) and y0 >= 0 and y0 < @as(i32, @intCast(self.height))) {
                const index = @as(usize, @intCast(y0)) * self.width + @as(usize, @intCast(x0));
                self.pixels[index] = pixel;
            }

            if (x0 == x1 and y0 == y1) break;

            const e2 = 2 * err;
            if (e2 > -dy) {
                err -= dy;
                x0 += sx;
            }
            if (e2 < dx) {
                err += dx;
                y0 += sy;
            }
        }
    }

    pub fn getPixel(self: Canvas, x: u32, y: u32) ?Color {
        if (x >= self.width or y >= self.height) return null;

        const pixel = self.pixels[y * self.width + x];
        return Color.fromPixel(pixel);
    }

    pub fn setPixel(self: *Canvas, x: u32, y: u32, color: Color) void {
        if (x >= self.width or y >= self.height) return;

        self.pixels[y * self.width + x] = color.toPixel();
    }
};

// ============================================================================
// Animation System (mirrors Craft's animation module)
// ============================================================================

pub const EasingFunction = enum {
    linear,
    ease_in_quad,
    ease_out_quad,
    ease_in_out_quad,
    ease_in_cubic,
    ease_out_cubic,
    ease_in_out_cubic,
    ease_in_sine,
    ease_out_sine,
    ease_in_out_sine,
    ease_out_bounce,
    ease_in_bounce,
    ease_in_out_bounce,
    ease_out_elastic,
    ease_in_elastic,
    ease_out_back,
    ease_in_back,

    pub fn apply(self: EasingFunction, t: f32) f32 {
        const clamped = @max(0.0, @min(1.0, t));
        return switch (self) {
            .linear => clamped,
            .ease_in_quad => clamped * clamped,
            .ease_out_quad => clamped * (2.0 - clamped),
            .ease_in_out_quad => if (clamped < 0.5) 2.0 * clamped * clamped else -1.0 + (4.0 - 2.0 * clamped) * clamped,
            .ease_in_cubic => clamped * clamped * clamped,
            .ease_out_cubic => blk: {
                const x = clamped - 1.0;
                break :blk x * x * x + 1.0;
            },
            .ease_in_out_cubic => if (clamped < 0.5) 4.0 * clamped * clamped * clamped else blk: {
                const x = (2.0 * clamped - 2.0);
                break :blk (x * x * x + 2.0) / 2.0;
            },
            .ease_in_sine => 1.0 - @cos((clamped * std.math.pi) / 2.0),
            .ease_out_sine => @sin((clamped * std.math.pi) / 2.0),
            .ease_in_out_sine => -(@cos(std.math.pi * clamped) - 1.0) / 2.0,
            .ease_out_bounce => easeOutBounce(clamped),
            .ease_in_bounce => 1.0 - easeOutBounce(1.0 - clamped),
            .ease_in_out_bounce => if (clamped < 0.5) (1.0 - easeOutBounce(1.0 - 2.0 * clamped)) / 2.0 else (1.0 + easeOutBounce(2.0 * clamped - 1.0)) / 2.0,
            else => clamped,
        };
    }

    fn easeOutBounce(t: f32) f32 {
        const n1: f32 = 7.5625;
        const d1: f32 = 2.75;

        if (t < 1.0 / d1) {
            return n1 * t * t;
        } else if (t < 2.0 / d1) {
            const t2 = t - 1.5 / d1;
            return n1 * t2 * t2 + 0.75;
        } else if (t < 2.5 / d1) {
            const t2 = t - 2.25 / d1;
            return n1 * t2 * t2 + 0.9375;
        } else {
            const t2 = t - 2.625 / d1;
            return n1 * t2 * t2 + 0.984375;
        }
    }
};

pub const AnimationState = enum {
    idle,
    running,
    paused,
    completed,
    canceled,
};

pub const Animation = struct {
    start_value: f32,
    end_value: f32,
    duration_ms: u64,
    easing: EasingFunction,
    state: AnimationState,
    elapsed_ms: u64,
    start_time: i64,
    on_update: ?*const fn (f32) void,
    on_complete: ?*const fn () void,

    pub fn init(start_val: f32, end_val: f32, duration_ms: u64, easing_fn: EasingFunction) Animation {
        return Animation{
            .start_value = start_val,
            .end_value = end_val,
            .duration_ms = duration_ms,
            .easing = easing_fn,
            .state = .idle,
            .elapsed_ms = 0,
            .start_time = 0,
            .on_update = null,
            .on_complete = null,
        };
    }

    pub fn start(self: *Animation) void {
        self.state = .running;
        self.start_time = std.time.milliTimestamp();
        self.elapsed_ms = 0;
    }

    pub fn pause(self: *Animation) void {
        if (self.state == .running) {
            self.state = .paused;
        }
    }

    pub fn @"resume"(self: *Animation) void {
        if (self.state == .paused) {
            self.state = .running;
        }
    }

    pub fn cancel(self: *Animation) void {
        self.state = .canceled;
    }

    pub fn reset(self: *Animation) void {
        self.state = .idle;
        self.elapsed_ms = 0;
        self.start_time = 0;
    }

    pub fn update(self: *Animation) f32 {
        if (self.state != .running) {
            return if (self.state == .completed) self.end_value else self.start_value;
        }

        const now = std.time.milliTimestamp();
        self.elapsed_ms = @intCast(now - self.start_time);

        if (self.elapsed_ms >= self.duration_ms) {
            self.state = .completed;
            if (self.on_complete) |callback| {
                callback();
            }
            return self.end_value;
        }

        const progress = @as(f32, @floatFromInt(self.elapsed_ms)) / @as(f32, @floatFromInt(self.duration_ms));
        const eased = self.easing.apply(progress);
        const current = self.start_value + (self.end_value - self.start_value) * eased;

        if (self.on_update) |callback| {
            callback(current);
        }

        return current;
    }

    pub fn isComplete(self: Animation) bool {
        return self.state == .completed;
    }

    pub fn isRunning(self: Animation) bool {
        return self.state == .running;
    }
};

/// Spring physics animation
pub const SpringAnimation = struct {
    position: f32,
    velocity: f32,
    target: f32,
    stiffness: f32,
    damping: f32,
    mass: f32,
    state: AnimationState,
    threshold: f32,

    pub fn init(initial: f32, target: f32) SpringAnimation {
        return SpringAnimation{
            .position = initial,
            .velocity = 0.0,
            .target = target,
            .stiffness = 200.0,
            .damping = 10.0,
            .mass = 1.0,
            .state = .idle,
            .threshold = 0.01,
        };
    }

    pub fn start(self: *SpringAnimation) void {
        self.state = .running;
    }

    pub fn update(self: *SpringAnimation, dt: f32) f32 {
        if (self.state != .running) return self.position;

        const spring_force = -self.stiffness * (self.position - self.target);
        const damping_force = -self.damping * self.velocity;
        const acceleration = (spring_force + damping_force) / self.mass;

        self.velocity += acceleration * dt;
        self.position += self.velocity * dt;

        // Check if spring has settled
        if (@abs(self.position - self.target) < self.threshold and @abs(self.velocity) < self.threshold) {
            self.position = self.target;
            self.velocity = 0.0;
            self.state = .completed;
        }

        return self.position;
    }

    pub fn setTarget(self: *SpringAnimation, target: f32) void {
        self.target = target;
        self.state = .running;
    }
};

// ============================================================================
// Game Application Framework
// ============================================================================

pub const GameConfig = struct {
    title: []const u8 = "Home Game",
    width: u32 = 800,
    height: u32 = 600,
    target_fps: u32 = 60,
    vsync: bool = true,
    fullscreen: bool = false,
    resizable: bool = true,
    gpu_backend: GPUBackend = .auto,
    power_preference: PowerPreference = .default,
};

pub const Game = struct {
    allocator: std.mem.Allocator,
    config: GameConfig,
    running: bool = false,

    // Timing
    delta_time: f64 = 0,
    total_time: f64 = 0,
    frame_count: u64 = 0,

    // Input
    input: InputState,

    // Rendering
    canvas: ?*Canvas = null,

    // Subsystems
    asset_manager: ?*assets.AssetManager = null,
    replay_manager: ?*replay.ReplayManager = null,
    mod_manager: ?*mods.ModManager = null,

    // Event handlers
    event_handlers: std.ArrayList(EventCallback),

    pub fn init(allocator: std.mem.Allocator, config: GameConfig) !*Game {
        const game = try allocator.create(Game);
        game.* = .{
            .allocator = allocator,
            .config = config,
            .input = InputState.init(allocator),
            .event_handlers = std.ArrayList(EventCallback).init(allocator),
        };

        // Initialize subsystems
        game.asset_manager = try assets.AssetManager.init(allocator);
        game.replay_manager = try replay.ReplayManager.init(allocator);
        game.mod_manager = try mods.ModManager.init(allocator);

        // Create canvas for rendering
        game.canvas = try allocator.create(Canvas);
        game.canvas.?.* = try Canvas.init(allocator, config.width, config.height);

        return game;
    }

    pub fn deinit(self: *Game) void {
        if (self.canvas) |canvas| {
            canvas.deinit();
            self.allocator.destroy(canvas);
        }
        if (self.asset_manager) |am| am.deinit();
        if (self.replay_manager) |rm| rm.deinit();
        if (self.mod_manager) |mm| mm.deinit();
        self.input.deinit();
        self.event_handlers.deinit();
        self.allocator.destroy(self);
    }

    pub fn addEventListener(self: *Game, callback: EventCallback) !void {
        try self.event_handlers.append(callback);
    }

    pub fn dispatchEvent(self: *Game, event: Event) void {
        // Update input state
        self.input.handleEvent(event);

        // Call event handlers
        for (self.event_handlers.items) |handler| {
            handler(event);
        }
    }

    pub fn run(self: *Game, comptime callbacks: type) !void {
        self.running = true;

        // Initialize
        if (@hasDecl(callbacks, "init")) {
            try callbacks.init(self);
        }

        var last_time = std.time.nanoTimestamp();
        const target_frame_time: i128 = @divFloor(1_000_000_000, self.config.target_fps);

        while (self.running) {
            const current_time = std.time.nanoTimestamp();
            const elapsed = current_time - last_time;
            self.delta_time = @as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0;
            self.total_time += self.delta_time;
            last_time = current_time;

            // Process events (would integrate with Craft's event loop)
            if (@hasDecl(callbacks, "processEvents")) {
                try callbacks.processEvents(self);
            }

            // Update
            if (@hasDecl(callbacks, "update")) {
                try callbacks.update(self, self.delta_time);
            }

            // Render
            if (@hasDecl(callbacks, "render")) {
                try callbacks.render(self);
            }

            self.frame_count += 1;

            // Frame timing
            const frame_elapsed = std.time.nanoTimestamp() - current_time;
            if (frame_elapsed < target_frame_time) {
                const sleep_ns: u64 = @intCast(target_frame_time - frame_elapsed);
                std.time.sleep(sleep_ns);
            }
        }

        // Cleanup
        if (@hasDecl(callbacks, "cleanup")) {
            callbacks.cleanup(self);
        }
    }

    pub fn quit(self: *Game) void {
        self.running = false;
    }

    pub fn getFPS(self: *Game) f64 {
        if (self.total_time > 0) {
            return @as(f64, @floatFromInt(self.frame_count)) / self.total_time;
        }
        return 0;
    }

    pub fn getCanvas(self: *Game) ?*Canvas {
        return self.canvas;
    }

    pub fn resizeCanvas(self: *Game, width: u32, height: u32) !void {
        if (self.canvas) |old_canvas| {
            old_canvas.deinit();
            self.allocator.destroy(old_canvas);
        }

        self.canvas = try self.allocator.create(Canvas);
        self.canvas.?.* = try Canvas.init(self.allocator, width, height);
    }
};

// ============================================================================
// Common Game Types
// ============================================================================

pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub fn add(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }

    pub fn sub(self: Vec2, other: Vec2) Vec2 {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }

    pub fn scale(self: Vec2, s: f32) Vec2 {
        return .{ .x = self.x * s, .y = self.y * s };
    }

    pub fn length(self: Vec2) f32 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }

    pub fn normalize(self: Vec2) Vec2 {
        const len = self.length();
        if (len == 0) return self;
        return .{ .x = self.x / len, .y = self.y / len };
    }

    pub fn dot(self: Vec2, other: Vec2) f32 {
        return self.x * other.x + self.y * other.y;
    }

    pub fn distance(self: Vec2, other: Vec2) f32 {
        return self.sub(other).length();
    }

    pub fn lerp(self: Vec2, other: Vec2, t: f32) Vec2 {
        return .{
            .x = self.x + (other.x - self.x) * t,
            .y = self.y + (other.y - self.y) * t,
        };
    }

    pub fn rotate(self: Vec2, rot_angle: f32) Vec2 {
        const c = @cos(rot_angle);
        const s = @sin(rot_angle);
        return .{
            .x = self.x * c - self.y * s,
            .y = self.x * s + self.y * c,
        };
    }

    pub fn perpendicular(self: Vec2) Vec2 {
        return .{ .x = -self.y, .y = self.x };
    }

    pub fn angle(self: Vec2) f32 {
        return std.math.atan2(self.y, self.x);
    }

    pub fn angleTo(self: Vec2, other: Vec2) f32 {
        return std.math.atan2(other.y - self.y, other.x - self.x);
    }
};

pub const Vec3 = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,

    pub fn add(self: Vec3, other: Vec3) Vec3 {
        return .{ .x = self.x + other.x, .y = self.y + other.y, .z = self.z + other.z };
    }

    pub fn sub(self: Vec3, other: Vec3) Vec3 {
        return .{ .x = self.x - other.x, .y = self.y - other.y, .z = self.z - other.z };
    }

    pub fn scale(self: Vec3, s: f32) Vec3 {
        return .{ .x = self.x * s, .y = self.y * s, .z = self.z * s };
    }

    pub fn length(self: Vec3) f32 {
        return @sqrt(self.x * self.x + self.y * self.y + self.z * self.z);
    }

    pub fn normalize(self: Vec3) Vec3 {
        const len = self.length();
        if (len == 0) return self;
        return .{ .x = self.x / len, .y = self.y / len, .z = self.z / len };
    }

    pub fn dot(self: Vec3, other: Vec3) f32 {
        return self.x * other.x + self.y * other.y + self.z * other.z;
    }

    pub fn cross(self: Vec3, other: Vec3) Vec3 {
        return .{
            .x = self.y * other.z - self.z * other.y,
            .y = self.z * other.x - self.x * other.z,
            .z = self.x * other.y - self.y * other.x,
        };
    }

    pub fn lerp(self: Vec3, other: Vec3, t: f32) Vec3 {
        return .{
            .x = self.x + (other.x - self.x) * t,
            .y = self.y + (other.y - self.y) * t,
            .z = self.z + (other.z - self.z) * t,
        };
    }
};

pub const Vec4 = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    w: f32 = 0,

    pub fn add(self: Vec4, other: Vec4) Vec4 {
        return .{ .x = self.x + other.x, .y = self.y + other.y, .z = self.z + other.z, .w = self.w + other.w };
    }

    pub fn sub(self: Vec4, other: Vec4) Vec4 {
        return .{ .x = self.x - other.x, .y = self.y - other.y, .z = self.z - other.z, .w = self.w - other.w };
    }

    pub fn scale(self: Vec4, s: f32) Vec4 {
        return .{ .x = self.x * s, .y = self.y * s, .z = self.z * s, .w = self.w * s };
    }

    pub fn dot(self: Vec4, other: Vec4) f32 {
        return self.x * other.x + self.y * other.y + self.z * other.z + self.w * other.w;
    }
};

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn contains(self: Rect, point: Vec2) bool {
        return point.x >= self.x and point.x <= self.x + self.width and
            point.y >= self.y and point.y <= self.y + self.height;
    }

    pub fn intersects(self: Rect, other: Rect) bool {
        return self.x < other.x + other.width and
            self.x + self.width > other.x and
            self.y < other.y + other.height and
            self.y + self.height > other.y;
    }

    pub fn center(self: Rect) Vec2 {
        return .{
            .x = self.x + self.width / 2,
            .y = self.y + self.height / 2,
        };
    }

    pub fn expand(self: Rect, amount: f32) Rect {
        return .{
            .x = self.x - amount,
            .y = self.y - amount,
            .width = self.width + amount * 2,
            .height = self.height + amount * 2,
        };
    }
};

pub const Color = struct {
    r: u8 = 255,
    g: u8 = 255,
    b: u8 = 255,
    a: u8 = 255,

    pub const white = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const red = Color{ .r = 255, .g = 0, .b = 0, .a = 255 };
    pub const green = Color{ .r = 0, .g = 255, .b = 0, .a = 255 };
    pub const blue = Color{ .r = 0, .g = 0, .b = 255, .a = 255 };
    pub const yellow = Color{ .r = 255, .g = 255, .b = 0, .a = 255 };
    pub const cyan = Color{ .r = 0, .g = 255, .b = 255, .a = 255 };
    pub const magenta = Color{ .r = 255, .g = 0, .b = 255, .a = 255 };
    pub const orange = Color{ .r = 255, .g = 165, .b = 0, .a = 255 };
    pub const purple = Color{ .r = 128, .g = 0, .b = 128, .a = 255 };
    pub const gray = Color{ .r = 128, .g = 128, .b = 128, .a = 255 };
    pub const dark_gray = Color{ .r = 64, .g = 64, .b = 64, .a = 255 };
    pub const light_gray = Color{ .r = 192, .g = 192, .b = 192, .a = 255 };
    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn fromHex(hex: u32) Color {
        return .{
            .r = @truncate((hex >> 24) & 0xFF),
            .g = @truncate((hex >> 16) & 0xFF),
            .b = @truncate((hex >> 8) & 0xFF),
            .a = @truncate(hex & 0xFF),
        };
    }

    pub fn fromHexRGB(hex: u32) Color {
        return .{
            .r = @truncate((hex >> 16) & 0xFF),
            .g = @truncate((hex >> 8) & 0xFF),
            .b = @truncate(hex & 0xFF),
            .a = 255,
        };
    }

    pub fn toHex(self: Color) u32 {
        return (@as(u32, self.r) << 24) | (@as(u32, self.g) << 16) | (@as(u32, self.b) << 8) | @as(u32, self.a);
    }

    pub fn toPixel(self: Color) u32 {
        return (@as(u32, self.a) << 24) | (@as(u32, self.r) << 16) | (@as(u32, self.g) << 8) | @as(u32, self.b);
    }

    pub fn fromPixel(pixel: u32) Color {
        return .{
            .a = @truncate((pixel >> 24) & 0xFF),
            .r = @truncate((pixel >> 16) & 0xFF),
            .g = @truncate((pixel >> 8) & 0xFF),
            .b = @truncate(pixel & 0xFF),
        };
    }

    pub fn lerp(self: Color, other: Color, t: f32) Color {
        const t_clamped = @max(0.0, @min(1.0, t));
        return .{
            .r = @intFromFloat(@as(f32, @floatFromInt(self.r)) + (@as(f32, @floatFromInt(other.r)) - @as(f32, @floatFromInt(self.r))) * t_clamped),
            .g = @intFromFloat(@as(f32, @floatFromInt(self.g)) + (@as(f32, @floatFromInt(other.g)) - @as(f32, @floatFromInt(self.g))) * t_clamped),
            .b = @intFromFloat(@as(f32, @floatFromInt(self.b)) + (@as(f32, @floatFromInt(other.b)) - @as(f32, @floatFromInt(self.b))) * t_clamped),
            .a = @intFromFloat(@as(f32, @floatFromInt(self.a)) + (@as(f32, @floatFromInt(other.a)) - @as(f32, @floatFromInt(self.a))) * t_clamped),
        };
    }

    pub fn withAlpha(self: Color, a: u8) Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = a };
    }
};

// ============================================================================
// Transform Component
// ============================================================================

pub const Transform = struct {
    position: Vec3 = .{},
    rotation: Vec3 = .{}, // Euler angles in radians
    scale: Vec3 = .{ .x = 1, .y = 1, .z = 1 },

    pub fn translate(self: *Transform, offset: Vec3) void {
        self.position = self.position.add(offset);
    }

    pub fn rotateX(self: *Transform, angle: f32) void {
        self.rotation.x += angle;
    }

    pub fn rotateY(self: *Transform, angle: f32) void {
        self.rotation.y += angle;
    }

    pub fn rotateZ(self: *Transform, angle: f32) void {
        self.rotation.z += angle;
    }

    pub fn scaleUniform(self: *Transform, factor: f32) void {
        self.scale = self.scale.scale(factor);
    }
};

// ============================================================================
// Frame Rate Limiter (matches Craft's FrameLimiter)
// ============================================================================

pub const FrameLimiter = struct {
    target_fps: u32,
    frame_time_ns: i64,
    last_frame: i64,

    pub fn init(target_fps: u32) FrameLimiter {
        const frame_time = @as(i64, @intCast(1_000_000_000 / target_fps));
        return FrameLimiter{
            .target_fps = target_fps,
            .frame_time_ns = frame_time,
            .last_frame = std.time.nanoTimestamp(),
        };
    }

    pub fn limit(self: *FrameLimiter) void {
        const now = std.time.nanoTimestamp();
        const elapsed = now - self.last_frame;

        if (elapsed < self.frame_time_ns) {
            const sleep_ns = self.frame_time_ns - elapsed;
            std.time.sleep(@intCast(sleep_ns));
        }

        self.last_frame = std.time.nanoTimestamp();
    }

    pub fn setTargetFPS(self: *FrameLimiter, fps: u32) void {
        self.target_fps = fps;
        self.frame_time_ns = @intCast(1_000_000_000 / fps);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Vec2 operations" {
    const v1 = Vec2{ .x = 3, .y = 4 };
    const v2 = Vec2{ .x = 1, .y = 2 };

    const sum = v1.add(v2);
    try std.testing.expectEqual(@as(f32, 4), sum.x);
    try std.testing.expectEqual(@as(f32, 6), sum.y);

    try std.testing.expectEqual(@as(f32, 5), v1.length());

    const normalized = v1.normalize();
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), normalized.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), normalized.y, 0.001);
}

test "Vec2 lerp" {
    const v1 = Vec2{ .x = 0, .y = 0 };
    const v2 = Vec2{ .x = 10, .y = 20 };

    const mid = v1.lerp(v2, 0.5);
    try std.testing.expectEqual(@as(f32, 5), mid.x);
    try std.testing.expectEqual(@as(f32, 10), mid.y);
}

test "Vec3 operations" {
    const v1 = Vec3{ .x = 1, .y = 0, .z = 0 };
    const v2 = Vec3{ .x = 0, .y = 1, .z = 0 };

    const cross_result = v1.cross(v2);
    try std.testing.expectEqual(@as(f32, 0), cross_result.x);
    try std.testing.expectEqual(@as(f32, 0), cross_result.y);
    try std.testing.expectEqual(@as(f32, 1), cross_result.z);
}

test "Rect intersection" {
    const r1 = Rect{ .x = 0, .y = 0, .width = 10, .height = 10 };
    const r2 = Rect{ .x = 5, .y = 5, .width = 10, .height = 10 };
    const r3 = Rect{ .x = 20, .y = 20, .width = 5, .height = 5 };

    try std.testing.expect(r1.intersects(r2));
    try std.testing.expect(!r1.intersects(r3));
}

test "Rect contains" {
    const r = Rect{ .x = 0, .y = 0, .width = 10, .height = 10 };

    try std.testing.expect(r.contains(.{ .x = 5, .y = 5 }));
    try std.testing.expect(!r.contains(.{ .x = 15, .y = 5 }));
}

test "Color operations" {
    const c1 = Color.red;
    const c2 = Color.blue;

    const lerped = c1.lerp(c2, 0.5);
    try std.testing.expectEqual(@as(u8, 127), lerped.r);
    try std.testing.expectEqual(@as(u8, 0), lerped.g);
    try std.testing.expectEqual(@as(u8, 127), lerped.b);
}

test "Color fromHex" {
    const c = Color.fromHexRGB(0xFF5500);
    try std.testing.expectEqual(@as(u8, 255), c.r);
    try std.testing.expectEqual(@as(u8, 85), c.g);
    try std.testing.expectEqual(@as(u8, 0), c.b);
}

test "Animation easing" {
    const easing = EasingFunction.ease_out_quad;

    // At t=0, should be 0
    try std.testing.expectApproxEqAbs(@as(f32, 0), easing.apply(0), 0.001);

    // At t=1, should be 1
    try std.testing.expectApproxEqAbs(@as(f32, 1), easing.apply(1), 0.001);

    // At t=0.5, ease_out_quad should be 0.75
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), easing.apply(0.5), 0.001);
}

test "InputState" {
    var input = InputState.init(std.testing.allocator);
    defer input.deinit();

    // Test key handling
    try input.keys.put(KeyCode.KEY_A, true);
    try std.testing.expect(input.isKeyDown(KeyCode.KEY_A));
    try std.testing.expect(!input.isKeyDown(KeyCode.KEY_B));

    // Test mouse handling
    input.mouse_buttons[0] = true;
    try std.testing.expect(input.isMouseButtonDown(0));
    try std.testing.expect(!input.isMouseButtonDown(1));
}

test "Canvas drawing" {
    var canvas = try Canvas.init(std.testing.allocator, 100, 100);
    defer canvas.deinit();

    canvas.clear(Color.white);
    canvas.drawRect(10, 10, 20, 20, Color.red);

    const pixel = canvas.getPixel(15, 15);
    try std.testing.expect(pixel != null);
    try std.testing.expectEqual(@as(u8, 255), pixel.?.r);
    try std.testing.expectEqual(@as(u8, 0), pixel.?.g);
    try std.testing.expectEqual(@as(u8, 0), pixel.?.b);
}
