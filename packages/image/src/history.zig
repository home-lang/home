const std = @import("std");
const Image = @import("image.zig").Image;
const Color = @import("color.zig").Color;

// ============================================================================
// History State
// ============================================================================

pub const HistoryState = struct {
    name: []const u8,
    timestamp: i64,
    // Store as compressed delta or full snapshot
    data: HistoryData,
    allocator: std.mem.Allocator,

    pub const HistoryData = union(enum) {
        full_snapshot: []u8,
        delta: DeltaData,
    };

    pub const DeltaData = struct {
        changed_regions: []ChangedRegion,
        base_state_idx: usize,
    };

    pub const ChangedRegion = struct {
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        old_data: []u8,
        new_data: []u8,
    };

    pub fn deinit(self: *HistoryState) void {
        self.allocator.free(self.name);

        switch (self.data) {
            .full_snapshot => |snapshot| {
                self.allocator.free(snapshot);
            },
            .delta => |delta| {
                for (delta.changed_regions) |*region| {
                    self.allocator.free(region.old_data);
                    self.allocator.free(region.new_data);
                }
                self.allocator.free(delta.changed_regions);
            },
        }
    }
};

// ============================================================================
// History Manager
// ============================================================================

pub const HistoryManager = struct {
    states: std.ArrayList(HistoryState),
    current_idx: usize,
    max_states: usize,
    allocator: std.mem.Allocator,

    // Settings
    use_delta_compression: bool,
    delta_threshold: usize, // Max changed pixels before full snapshot

    pub fn init(allocator: std.mem.Allocator) HistoryManager {
        return HistoryManager{
            .states = std.ArrayList(HistoryState).init(allocator),
            .current_idx = 0,
            .max_states = 50,
            .allocator = allocator,
            .use_delta_compression = true,
            .delta_threshold = 1000000, // ~1 million pixels
        };
    }

    pub fn deinit(self: *HistoryManager) void {
        for (self.states.items) |*state| {
            state.deinit();
        }
        self.states.deinit();
    }

    pub fn setMaxStates(self: *HistoryManager, max: usize) void {
        self.max_states = max;
        self.trimHistory();
    }

    pub fn pushState(self: *HistoryManager, img: *const Image, name: []const u8) !void {
        // Remove any redo states
        while (self.states.items.len > self.current_idx + 1) {
            var state = self.states.pop();
            state.deinit();
        }

        // Create new state
        const name_copy = try self.allocator.dupe(u8, name);

        var state = HistoryState{
            .name = name_copy,
            .timestamp = std.time.timestamp(),
            .data = undefined,
            .allocator = self.allocator,
        };

        // Decide between full snapshot and delta
        if (self.use_delta_compression and self.states.items.len > 0) {
            const delta = try self.computeDelta(img);
            if (delta) |d| {
                state.data = .{ .delta = d };
            } else {
                state.data = .{ .full_snapshot = try self.createSnapshot(img) };
            }
        } else {
            state.data = .{ .full_snapshot = try self.createSnapshot(img) };
        }

        try self.states.append(state);
        self.current_idx = self.states.items.len - 1;

        self.trimHistory();
    }

    fn createSnapshot(self: *HistoryManager, img: *const Image) ![]u8 {
        const size = img.width * img.height * 4;
        const snapshot = try self.allocator.alloc(u8, size + 8);

        // Store dimensions
        @memcpy(snapshot[0..4], std.mem.asBytes(&img.width));
        @memcpy(snapshot[4..8], std.mem.asBytes(&img.height));

        // Store pixel data
        for (0..img.height) |y| {
            for (0..img.width) |x| {
                const color = img.getPixel(@intCast(x), @intCast(y));
                const idx = 8 + (y * img.width + x) * 4;
                snapshot[idx] = color.r;
                snapshot[idx + 1] = color.g;
                snapshot[idx + 2] = color.b;
                snapshot[idx + 3] = color.a;
            }
        }

        return snapshot;
    }

    fn computeDelta(self: *HistoryManager, img: *const Image) !?HistoryState.DeltaData {
        // Get base state
        if (self.states.items.len == 0) return null;

        const base_idx = self.current_idx;
        const base_state = &self.states.items[base_idx];

        // Can only compute delta from full snapshot
        const base_data = switch (base_state.data) {
            .full_snapshot => |s| s,
            .delta => return null, // Need to chain deltas - skip for simplicity
        };

        const base_width = std.mem.bytesToValue(u32, base_data[0..4]);
        const base_height = std.mem.bytesToValue(u32, base_data[4..8]);

        if (base_width != img.width or base_height != img.height) {
            return null; // Size changed, need full snapshot
        }

        // Find changed regions
        var changed_regions = std.ArrayList(HistoryState.ChangedRegion).init(self.allocator);
        errdefer {
            for (changed_regions.items) |*r| {
                self.allocator.free(r.old_data);
                self.allocator.free(r.new_data);
            }
            changed_regions.deinit();
        }

        // Simple approach: scan for changed 32x32 blocks
        const block_size: u32 = 32;
        var total_changed: usize = 0;

        var by: u32 = 0;
        while (by < img.height) : (by += block_size) {
            var bx: u32 = 0;
            while (bx < img.width) : (bx += block_size) {
                const bw = @min(block_size, img.width - bx);
                const bh = @min(block_size, img.height - by);

                // Check if block changed
                var changed = false;
                outer: for (0..bh) |dy| {
                    for (0..bw) |dx| {
                        const x = bx + @as(u32, @intCast(dx));
                        const y = by + @as(u32, @intCast(dy));
                        const idx = 8 + (y * img.width + x) * 4;

                        const old_color = Color{
                            .r = base_data[idx],
                            .g = base_data[idx + 1],
                            .b = base_data[idx + 2],
                            .a = base_data[idx + 3],
                        };
                        const new_color = img.getPixel(x, y);

                        if (old_color.r != new_color.r or old_color.g != new_color.g or
                            old_color.b != new_color.b or old_color.a != new_color.a)
                        {
                            changed = true;
                            break :outer;
                        }
                    }
                }

                if (changed) {
                    total_changed += bw * bh;

                    // Exceeded threshold, use full snapshot
                    if (total_changed > self.delta_threshold) {
                        for (changed_regions.items) |*r| {
                            self.allocator.free(r.old_data);
                            self.allocator.free(r.new_data);
                        }
                        changed_regions.deinit();
                        return null;
                    }

                    // Store region data
                    const region_size = bw * bh * 4;
                    const old_data = try self.allocator.alloc(u8, region_size);
                    const new_data = try self.allocator.alloc(u8, region_size);

                    for (0..bh) |dy| {
                        for (0..bw) |dx| {
                            const x = bx + @as(u32, @intCast(dx));
                            const y = by + @as(u32, @intCast(dy));
                            const src_idx = 8 + (y * img.width + x) * 4;
                            const dst_idx = (dy * bw + dx) * 4;

                            old_data[dst_idx] = base_data[src_idx];
                            old_data[dst_idx + 1] = base_data[src_idx + 1];
                            old_data[dst_idx + 2] = base_data[src_idx + 2];
                            old_data[dst_idx + 3] = base_data[src_idx + 3];

                            const new_color = img.getPixel(x, y);
                            new_data[dst_idx] = new_color.r;
                            new_data[dst_idx + 1] = new_color.g;
                            new_data[dst_idx + 2] = new_color.b;
                            new_data[dst_idx + 3] = new_color.a;
                        }
                    }

                    try changed_regions.append(HistoryState.ChangedRegion{
                        .x = bx,
                        .y = by,
                        .width = bw,
                        .height = bh,
                        .old_data = old_data,
                        .new_data = new_data,
                    });
                }
            }
        }

        if (changed_regions.items.len == 0) {
            changed_regions.deinit();
            return null; // No changes
        }

        return HistoryState.DeltaData{
            .changed_regions = try changed_regions.toOwnedSlice(),
            .base_state_idx = base_idx,
        };
    }

    fn trimHistory(self: *HistoryManager) void {
        while (self.states.items.len > self.max_states) {
            var state = self.states.orderedRemove(0);
            state.deinit();
            if (self.current_idx > 0) self.current_idx -= 1;
        }
    }

    pub fn canUndo(self: *const HistoryManager) bool {
        return self.current_idx > 0;
    }

    pub fn canRedo(self: *const HistoryManager) bool {
        return self.current_idx < self.states.items.len - 1;
    }

    pub fn undo(self: *HistoryManager, img: *Image) !bool {
        if (!self.canUndo()) return false;

        self.current_idx -= 1;
        try self.applyState(img, self.current_idx);
        return true;
    }

    pub fn redo(self: *HistoryManager, img: *Image) !bool {
        if (!self.canRedo()) return false;

        self.current_idx += 1;
        try self.applyState(img, self.current_idx);
        return true;
    }

    pub fn goToState(self: *HistoryManager, img: *Image, idx: usize) !bool {
        if (idx >= self.states.items.len) return false;

        self.current_idx = idx;
        try self.applyState(img, idx);
        return true;
    }

    fn applyState(self: *HistoryManager, img: *Image, idx: usize) !void {
        const state = &self.states.items[idx];

        switch (state.data) {
            .full_snapshot => |snapshot| {
                const width = std.mem.bytesToValue(u32, snapshot[0..4]);
                const height = std.mem.bytesToValue(u32, snapshot[4..8]);

                // Resize if needed
                if (img.width != width or img.height != height) {
                    img.deinit();
                    img.* = try Image.create(self.allocator, width, height, .rgba);
                }

                // Apply snapshot
                for (0..height) |y| {
                    for (0..width) |x| {
                        const src_idx = 8 + (y * width + x) * 4;
                        img.setPixel(@intCast(x), @intCast(y), Color{
                            .r = snapshot[src_idx],
                            .g = snapshot[src_idx + 1],
                            .b = snapshot[src_idx + 2],
                            .a = snapshot[src_idx + 3],
                        });
                    }
                }
            },
            .delta => |delta| {
                // First apply base state
                try self.applyState(img, delta.base_state_idx);

                // Then apply regions
                for (delta.changed_regions) |region| {
                    for (0..region.height) |dy| {
                        for (0..region.width) |dx| {
                            const x = region.x + @as(u32, @intCast(dx));
                            const y = region.y + @as(u32, @intCast(dy));
                            const src_idx = (dy * region.width + dx) * 4;

                            img.setPixel(x, y, Color{
                                .r = region.new_data[src_idx],
                                .g = region.new_data[src_idx + 1],
                                .b = region.new_data[src_idx + 2],
                                .a = region.new_data[src_idx + 3],
                            });
                        }
                    }
                }
            },
        }
    }

    pub fn getStateCount(self: *const HistoryManager) usize {
        return self.states.items.len;
    }

    pub fn getCurrentIndex(self: *const HistoryManager) usize {
        return self.current_idx;
    }

    pub fn getStateName(self: *const HistoryManager, idx: usize) ?[]const u8 {
        if (idx >= self.states.items.len) return null;
        return self.states.items[idx].name;
    }

    pub fn getStateTimestamp(self: *const HistoryManager, idx: usize) ?i64 {
        if (idx >= self.states.items.len) return null;
        return self.states.items[idx].timestamp;
    }

    pub fn clear(self: *HistoryManager) void {
        for (self.states.items) |*state| {
            state.deinit();
        }
        self.states.clearRetainingCapacity();
        self.current_idx = 0;
    }
};

// ============================================================================
// Snapshot System (Named States)
// ============================================================================

pub const Snapshot = struct {
    name: []const u8,
    thumbnail: ?Image,
    data: []u8,
    width: u32,
    height: u32,
    timestamp: i64,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, img: *const Image, name: []const u8, create_thumbnail: bool) !Snapshot {
        const name_copy = try allocator.dupe(u8, name);

        // Create full data copy
        const size = img.width * img.height * 4;
        const data = try allocator.alloc(u8, size);

        for (0..img.height) |y| {
            for (0..img.width) |x| {
                const color = img.getPixel(@intCast(x), @intCast(y));
                const idx = (y * img.width + x) * 4;
                data[idx] = color.r;
                data[idx + 1] = color.g;
                data[idx + 2] = color.b;
                data[idx + 3] = color.a;
            }
        }

        // Create thumbnail
        var thumbnail: ?Image = null;
        if (create_thumbnail) {
            const thumb_size: u32 = 128;
            const scale = @as(f32, @floatFromInt(thumb_size)) / @as(f32, @floatFromInt(@max(img.width, img.height)));
            const thumb_w = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(img.width)) * scale)));
            const thumb_h = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(img.height)) * scale)));

            thumbnail = try Image.create(allocator, thumb_w, thumb_h, .rgba);

            // Simple nearest-neighbor downscale
            for (0..thumb_h) |y| {
                for (0..thumb_w) |x| {
                    const src_x = @as(u32, @intFromFloat(@as(f32, @floatFromInt(x)) / scale));
                    const src_y = @as(u32, @intFromFloat(@as(f32, @floatFromInt(y)) / scale));
                    thumbnail.?.setPixel(@intCast(x), @intCast(y), img.getPixel(src_x, src_y));
                }
            }
        }

        return Snapshot{
            .name = name_copy,
            .thumbnail = thumbnail,
            .data = data,
            .width = img.width,
            .height = img.height,
            .timestamp = std.time.timestamp(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Snapshot) void {
        self.allocator.free(self.name);
        self.allocator.free(self.data);
        if (self.thumbnail) |*thumb| {
            thumb.deinit();
        }
    }

    pub fn restore(self: *const Snapshot, allocator: std.mem.Allocator) !Image {
        var img = try Image.create(allocator, self.width, self.height, .rgba);

        for (0..self.height) |y| {
            for (0..self.width) |x| {
                const idx = (y * self.width + x) * 4;
                img.setPixel(@intCast(x), @intCast(y), Color{
                    .r = self.data[idx],
                    .g = self.data[idx + 1],
                    .b = self.data[idx + 2],
                    .a = self.data[idx + 3],
                });
            }
        }

        return img;
    }
};

pub const SnapshotManager = struct {
    snapshots: std.ArrayList(Snapshot),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SnapshotManager {
        return SnapshotManager{
            .snapshots = std.ArrayList(Snapshot).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SnapshotManager) void {
        for (self.snapshots.items) |*snap| {
            snap.deinit();
        }
        self.snapshots.deinit();
    }

    pub fn createSnapshot(self: *SnapshotManager, img: *const Image, name: []const u8) !usize {
        const snapshot = try Snapshot.create(self.allocator, img, name, true);
        try self.snapshots.append(snapshot);
        return self.snapshots.items.len - 1;
    }

    pub fn deleteSnapshot(self: *SnapshotManager, idx: usize) void {
        if (idx >= self.snapshots.items.len) return;
        var snapshot = self.snapshots.orderedRemove(idx);
        snapshot.deinit();
    }

    pub fn restoreSnapshot(self: *const SnapshotManager, idx: usize) !?Image {
        if (idx >= self.snapshots.items.len) return null;
        return try self.snapshots.items[idx].restore(self.allocator);
    }

    pub fn getSnapshotCount(self: *const SnapshotManager) usize {
        return self.snapshots.items.len;
    }

    pub fn getSnapshot(self: *const SnapshotManager, idx: usize) ?*const Snapshot {
        if (idx >= self.snapshots.items.len) return null;
        return &self.snapshots.items[idx];
    }

    pub fn renameSnapshot(self: *SnapshotManager, idx: usize, new_name: []const u8) !void {
        if (idx >= self.snapshots.items.len) return;

        self.allocator.free(self.snapshots.items[idx].name);
        self.snapshots.items[idx].name = try self.allocator.dupe(u8, new_name);
    }
};

// ============================================================================
// Non-Destructive Edit Stack
// ============================================================================

pub const EditOperation = struct {
    op_type: EditType,
    params: Parameters,
    enabled: bool,
    blend_mode: BlendMode,
    opacity: f32,

    pub const EditType = enum {
        brightness_contrast,
        hue_saturation,
        color_balance,
        levels,
        curves,
        exposure,
        vibrance,
        channel_mixer,
        gradient_map,
        photo_filter,
        invert,
        posterize,
        threshold,
        blur,
        sharpen,
        custom,
    };

    pub const Parameters = union(EditType) {
        brightness_contrast: struct { brightness: f32, contrast: f32 },
        hue_saturation: struct { hue: f32, saturation: f32, lightness: f32 },
        color_balance: struct { shadows: [3]f32, midtones: [3]f32, highlights: [3]f32 },
        levels: struct { input_black: u8, input_white: u8, gamma: f32, output_black: u8, output_white: u8 },
        curves: struct { points: []const [2]f32 },
        exposure: struct { exposure: f32, offset: f32, gamma: f32 },
        vibrance: struct { vibrance: f32, saturation: f32 },
        channel_mixer: struct { matrix: [9]f32 },
        gradient_map: struct { colors: []const Color },
        photo_filter: struct { color: Color, density: f32, preserve_luminosity: bool },
        invert: void,
        posterize: struct { levels: u8 },
        threshold: struct { level: u8 },
        blur: struct { radius: u32, blur_type: enum { gaussian, box, motion } },
        sharpen: struct { amount: f32, radius: u32 },
        custom: struct { apply_fn: *const fn (*Image) void },
    };

    pub const BlendMode = enum {
        normal,
        multiply,
        screen,
        overlay,
        soft_light,
        hard_light,
        color_dodge,
        color_burn,
        darken,
        lighten,
        difference,
        exclusion,
        hue,
        saturation,
        color,
        luminosity,
    };
};

pub const EditStack = struct {
    operations: std.ArrayList(EditOperation),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) EditStack {
        return EditStack{
            .operations = std.ArrayList(EditOperation).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EditStack) void {
        self.operations.deinit();
    }

    pub fn addOperation(self: *EditStack, op: EditOperation) !void {
        try self.operations.append(op);
    }

    pub fn removeOperation(self: *EditStack, idx: usize) void {
        if (idx >= self.operations.items.len) return;
        _ = self.operations.orderedRemove(idx);
    }

    pub fn moveOperation(self: *EditStack, from_idx: usize, to_idx: usize) void {
        if (from_idx >= self.operations.items.len or to_idx >= self.operations.items.len) return;

        const op = self.operations.items[from_idx];
        _ = self.operations.orderedRemove(from_idx);
        self.operations.insert(to_idx, op) catch {};
    }

    pub fn toggleOperation(self: *EditStack, idx: usize) void {
        if (idx >= self.operations.items.len) return;
        self.operations.items[idx].enabled = !self.operations.items[idx].enabled;
    }

    pub fn setOpacity(self: *EditStack, idx: usize, opacity: f32) void {
        if (idx >= self.operations.items.len) return;
        self.operations.items[idx].opacity = std.math.clamp(opacity, 0, 1);
    }

    pub fn apply(self: *const EditStack, source: *const Image, allocator: std.mem.Allocator) !Image {
        var result = try source.clone(allocator);

        for (self.operations.items) |op| {
            if (!op.enabled) continue;

            // Apply operation to temporary image
            var temp = try result.clone(allocator);
            defer temp.deinit();

            applyOperation(&temp, op);

            // Blend with opacity
            if (op.opacity < 1.0) {
                for (0..result.height) |y| {
                    for (0..result.width) |x| {
                        const src = result.getPixel(@intCast(x), @intCast(y));
                        const dst = temp.getPixel(@intCast(x), @intCast(y));
                        result.setPixel(@intCast(x), @intCast(y), blendColors(src, dst, op.blend_mode, op.opacity));
                    }
                }
            } else {
                // Full opacity, just copy
                for (0..result.height) |y| {
                    for (0..result.width) |x| {
                        result.setPixel(@intCast(x), @intCast(y), temp.getPixel(@intCast(x), @intCast(y)));
                    }
                }
            }
        }

        return result;
    }

    fn applyOperation(img: *Image, op: EditOperation) void {
        switch (op.params) {
            .brightness_contrast => |params| {
                for (0..img.height) |y| {
                    for (0..img.width) |x| {
                        var color = img.getPixel(@intCast(x), @intCast(y));

                        // Brightness
                        var r = @as(f32, @floatFromInt(color.r)) + params.brightness * 255;
                        var g = @as(f32, @floatFromInt(color.g)) + params.brightness * 255;
                        var b = @as(f32, @floatFromInt(color.b)) + params.brightness * 255;

                        // Contrast
                        const factor = (259 * (params.contrast * 255 + 255)) / (255 * (259 - params.contrast * 255));
                        r = factor * (r - 128) + 128;
                        g = factor * (g - 128) + 128;
                        b = factor * (b - 128) + 128;

                        color.r = @intFromFloat(std.math.clamp(r, 0, 255));
                        color.g = @intFromFloat(std.math.clamp(g, 0, 255));
                        color.b = @intFromFloat(std.math.clamp(b, 0, 255));

                        img.setPixel(@intCast(x), @intCast(y), color);
                    }
                }
            },
            .invert => {
                for (0..img.height) |y| {
                    for (0..img.width) |x| {
                        var color = img.getPixel(@intCast(x), @intCast(y));
                        color.r = 255 - color.r;
                        color.g = 255 - color.g;
                        color.b = 255 - color.b;
                        img.setPixel(@intCast(x), @intCast(y), color);
                    }
                }
            },
            .posterize => |params| {
                const levels = @max(2, params.levels);
                const step = 255.0 / @as(f32, @floatFromInt(levels - 1));

                for (0..img.height) |y| {
                    for (0..img.width) |x| {
                        var color = img.getPixel(@intCast(x), @intCast(y));

                        color.r = @intFromFloat(@round(@as(f32, @floatFromInt(color.r)) / step) * step);
                        color.g = @intFromFloat(@round(@as(f32, @floatFromInt(color.g)) / step) * step);
                        color.b = @intFromFloat(@round(@as(f32, @floatFromInt(color.b)) / step) * step);

                        img.setPixel(@intCast(x), @intCast(y), color);
                    }
                }
            },
            .threshold => |params| {
                for (0..img.height) |y| {
                    for (0..img.width) |x| {
                        var color = img.getPixel(@intCast(x), @intCast(y));
                        const lum = @as(u8, @intFromFloat(@as(f32, @floatFromInt(color.r)) * 0.299 + @as(f32, @floatFromInt(color.g)) * 0.587 + @as(f32, @floatFromInt(color.b)) * 0.114));

                        const val: u8 = if (lum > params.level) 255 else 0;
                        color.r = val;
                        color.g = val;
                        color.b = val;

                        img.setPixel(@intCast(x), @intCast(y), color);
                    }
                }
            },
            else => {}, // Other operations need more complex implementations
        }
    }

    fn blendColors(src: Color, dst: Color, mode: EditOperation.BlendMode, opacity: f32) Color {
        const sr = @as(f32, @floatFromInt(src.r)) / 255.0;
        const sg = @as(f32, @floatFromInt(src.g)) / 255.0;
        const sb = @as(f32, @floatFromInt(src.b)) / 255.0;
        const dr = @as(f32, @floatFromInt(dst.r)) / 255.0;
        const dg = @as(f32, @floatFromInt(dst.g)) / 255.0;
        const db = @as(f32, @floatFromInt(dst.b)) / 255.0;

        var r: f32 = 0;
        var g: f32 = 0;
        var b: f32 = 0;

        switch (mode) {
            .normal => {
                r = dr;
                g = dg;
                b = db;
            },
            .multiply => {
                r = sr * dr;
                g = sg * dg;
                b = sb * db;
            },
            .screen => {
                r = 1 - (1 - sr) * (1 - dr);
                g = 1 - (1 - sg) * (1 - dg);
                b = 1 - (1 - sb) * (1 - db);
            },
            .overlay => {
                r = if (sr < 0.5) 2 * sr * dr else 1 - 2 * (1 - sr) * (1 - dr);
                g = if (sg < 0.5) 2 * sg * dg else 1 - 2 * (1 - sg) * (1 - dg);
                b = if (sb < 0.5) 2 * sb * db else 1 - 2 * (1 - sb) * (1 - db);
            },
            .soft_light => {
                r = if (dr < 0.5) sr - (1 - 2 * dr) * sr * (1 - sr) else sr + (2 * dr - 1) * (softLightD(sr) - sr);
                g = if (dg < 0.5) sg - (1 - 2 * dg) * sg * (1 - sg) else sg + (2 * dg - 1) * (softLightD(sg) - sg);
                b = if (db < 0.5) sb - (1 - 2 * db) * sb * (1 - sb) else sb + (2 * db - 1) * (softLightD(sb) - sb);
            },
            .hard_light => {
                r = if (dr < 0.5) 2 * sr * dr else 1 - 2 * (1 - sr) * (1 - dr);
                g = if (dg < 0.5) 2 * sg * dg else 1 - 2 * (1 - sg) * (1 - dg);
                b = if (db < 0.5) 2 * sb * db else 1 - 2 * (1 - sb) * (1 - db);
            },
            .color_dodge => {
                r = if (dr >= 1) 1 else @min(1, sr / (1 - dr));
                g = if (dg >= 1) 1 else @min(1, sg / (1 - dg));
                b = if (db >= 1) 1 else @min(1, sb / (1 - db));
            },
            .color_burn => {
                r = if (dr <= 0) 0 else @max(0, 1 - (1 - sr) / dr);
                g = if (dg <= 0) 0 else @max(0, 1 - (1 - sg) / dg);
                b = if (db <= 0) 0 else @max(0, 1 - (1 - sb) / db);
            },
            .darken => {
                r = @min(sr, dr);
                g = @min(sg, dg);
                b = @min(sb, db);
            },
            .lighten => {
                r = @max(sr, dr);
                g = @max(sg, dg);
                b = @max(sb, db);
            },
            .difference => {
                r = @abs(sr - dr);
                g = @abs(sg - dg);
                b = @abs(sb - db);
            },
            .exclusion => {
                r = sr + dr - 2 * sr * dr;
                g = sg + dg - 2 * sg * dg;
                b = sb + db - 2 * sb * db;
            },
            else => {
                r = dr;
                g = dg;
                b = db;
            },
        }

        // Apply opacity
        r = sr * (1 - opacity) + r * opacity;
        g = sg * (1 - opacity) + g * opacity;
        b = sb * (1 - opacity) + b * opacity;

        return Color{
            .r = @intFromFloat(std.math.clamp(r * 255, 0, 255)),
            .g = @intFromFloat(std.math.clamp(g * 255, 0, 255)),
            .b = @intFromFloat(std.math.clamp(b * 255, 0, 255)),
            .a = src.a,
        };
    }

    fn softLightD(x: f32) f32 {
        return if (x <= 0.25) ((16 * x - 12) * x + 4) * x else @sqrt(x);
    }
};
