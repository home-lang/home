// Home Game Development Framework - Replay System
// Record and playback game states and inputs

const std = @import("std");

// ============================================================================
// Zig 0.16 Compatibility - Time Helper
// ============================================================================

/// Get current time in milliseconds (Zig 0.16 compatible)
fn getMilliTimestamp() i64 {
    const instant = std.time.Instant.now() catch return 0;
    return @intCast(@as(i128, instant.timestamp.sec) * 1000 + @divFloor(instant.timestamp.nsec, 1_000_000));
}

// ============================================================================
// Input Recording
// ============================================================================

pub const InputType = enum(u8) {
    key_down,
    key_up,
    mouse_move,
    mouse_down,
    mouse_up,
    mouse_wheel,
    gamepad_button,
    gamepad_axis,
    custom,
};

pub const RecordedInput = struct {
    frame: u64,
    timestamp_ms: u64,
    input_type: InputType,
    data: InputData,

    pub const InputData = union {
        key: struct {
            code: u32,
            modifiers: u8,
        },
        mouse_move: struct {
            x: i32,
            y: i32,
        },
        mouse_button: struct {
            button: u8,
            x: i32,
            y: i32,
        },
        mouse_wheel: struct {
            delta_x: f32,
            delta_y: f32,
        },
        gamepad_button: struct {
            button: u8,
            pressed: bool,
        },
        gamepad_axis: struct {
            axis: u8,
            value: f32,
        },
        custom: struct {
            id: u32,
            value: i64,
        },
    };
};

// ============================================================================
// State Snapshot
// ============================================================================

pub const StateSnapshot = struct {
    frame: u64,
    timestamp_ms: u64,
    data: []u8,
    checksum: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, frame: u64, timestamp_ms: u64, data: []const u8) !StateSnapshot {
        const data_copy = try allocator.dupe(u8, data);
        return StateSnapshot{
            .frame = frame,
            .timestamp_ms = timestamp_ms,
            .data = data_copy,
            .checksum = calculateChecksum(data),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StateSnapshot) void {
        self.allocator.free(self.data);
    }

    fn calculateChecksum(data: []const u8) u32 {
        var hash: u32 = 0;
        for (data) |byte| {
            hash = hash *% 31 +% @as(u32, byte);
        }
        return hash;
    }

    pub fn verify(self: *const StateSnapshot) bool {
        return calculateChecksum(self.data) == self.checksum;
    }
};

// ============================================================================
// Replay Recording
// ============================================================================

pub const ReplayHeader = struct {
    magic: [4]u8 = [_]u8{ 'H', 'R', 'P', 'L' },
    version: u16 = 1,
    flags: u16 = 0,
    game_seed: u64 = 0,
    start_timestamp: i64 = 0,
    duration_ms: u64 = 0,
    frame_count: u64 = 0,
    input_count: u64 = 0,
    snapshot_count: u32 = 0,
    metadata_size: u32 = 0,
};

pub const ReplayRecording = struct {
    header: ReplayHeader,
    inputs: std.ArrayList(RecordedInput),
    snapshots: std.ArrayList(StateSnapshot),
    metadata: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    current_frame: u64,
    start_time: i64,

    pub fn init(allocator: std.mem.Allocator) !*ReplayRecording {
        const self = try allocator.create(ReplayRecording);
        self.* = ReplayRecording{
            .header = ReplayHeader{},
            .inputs = .{},
            .snapshots = .{},
            .metadata = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
            .current_frame = 0,
            .start_time = getMilliTimestamp(),
        };
        self.header.start_timestamp = self.start_time;
        return self;
    }

    pub fn deinit(self: *ReplayRecording) void {
        self.inputs.deinit(self.allocator);

        for (self.snapshots.items) |*snapshot| {
            snapshot.deinit();
        }
        self.snapshots.deinit(self.allocator);

        self.metadata.deinit();
        self.allocator.destroy(self);
    }

    pub fn recordInput(self: *ReplayRecording, input: RecordedInput) !void {
        var recorded = input;
        recorded.frame = self.current_frame;
        recorded.timestamp_ms = @intCast(getMilliTimestamp() - self.start_time);
        try self.inputs.append(self.allocator, recorded);
        self.header.input_count += 1;
    }

    pub fn recordSnapshot(self: *ReplayRecording, state_data: []const u8) !void {
        const timestamp_ms: u64 = @intCast(getMilliTimestamp() - self.start_time);
        const snapshot = try StateSnapshot.init(self.allocator, self.current_frame, timestamp_ms, state_data);
        try self.snapshots.append(self.allocator, snapshot);
        self.header.snapshot_count += 1;
    }

    pub fn advanceFrame(self: *ReplayRecording) void {
        self.current_frame += 1;
        self.header.frame_count = self.current_frame;
        self.header.duration_ms = @intCast(getMilliTimestamp() - self.start_time);
    }

    pub fn setMetadata(self: *ReplayRecording, key: []const u8, value: []const u8) !void {
        try self.metadata.put(key, value);
    }

    pub fn setSeed(self: *ReplayRecording, seed: u64) void {
        self.header.game_seed = seed;
    }
};

// ============================================================================
// Replay Playback
// ============================================================================

pub const PlaybackState = enum {
    stopped,
    playing,
    paused,
    finished,
};

pub const ReplayPlayback = struct {
    recording: *ReplayRecording,
    state: PlaybackState,
    current_frame: u64,
    current_input_index: usize,
    playback_speed: f32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, recording: *ReplayRecording) !*ReplayPlayback {
        const self = try allocator.create(ReplayPlayback);
        self.* = ReplayPlayback{
            .recording = recording,
            .state = .stopped,
            .current_frame = 0,
            .current_input_index = 0,
            .playback_speed = 1.0,
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *ReplayPlayback) void {
        self.allocator.destroy(self);
    }

    pub fn play(self: *ReplayPlayback) void {
        self.state = .playing;
    }

    pub fn pause(self: *ReplayPlayback) void {
        self.state = .paused;
    }

    pub fn stop(self: *ReplayPlayback) void {
        self.state = .stopped;
        self.current_frame = 0;
        self.current_input_index = 0;
    }

    pub fn setSpeed(self: *ReplayPlayback, speed: f32) void {
        self.playback_speed = @max(0.1, @min(speed, 10.0));
    }

    pub fn seekToFrame(self: *ReplayPlayback, frame: u64) void {
        self.current_frame = @min(frame, self.recording.header.frame_count);

        // Find the input index for this frame
        self.current_input_index = 0;
        for (self.recording.inputs.items, 0..) |input, i| {
            if (input.frame > self.current_frame) break;
            self.current_input_index = i;
        }
    }

    pub fn seekToTime(self: *ReplayPlayback, time_ms: u64) void {
        // Estimate frame from time (assuming 60 FPS)
        const estimated_frame = (time_ms * 60) / 1000;
        self.seekToFrame(estimated_frame);
    }

    pub fn getInputsForFrame(self: *ReplayPlayback, frame: u64) []const RecordedInput {
        // Find inputs for this frame
        const inputs = self.recording.inputs.items;

        var start: usize = self.current_input_index;
        while (start < inputs.len and inputs[start].frame < frame) {
            start += 1;
        }

        var end = start;
        while (end < inputs.len and inputs[end].frame == frame) {
            end += 1;
        }

        return inputs[start..end];
    }

    pub fn advanceFrame(self: *ReplayPlayback) bool {
        if (self.state != .playing) return false;

        self.current_frame += 1;
        if (self.current_frame >= self.recording.header.frame_count) {
            self.state = .finished;
            return false;
        }

        return true;
    }

    pub fn getProgress(self: *const ReplayPlayback) f32 {
        if (self.recording.header.frame_count == 0) return 0;
        return @as(f32, @floatFromInt(self.current_frame)) / @as(f32, @floatFromInt(self.recording.header.frame_count));
    }

    pub fn findNearestSnapshot(self: *const ReplayPlayback, frame: u64) ?*const StateSnapshot {
        var best: ?*const StateSnapshot = null;
        var best_distance: u64 = std.math.maxInt(u64);

        for (self.recording.snapshots.items) |*snapshot| {
            if (snapshot.frame <= frame) {
                const distance = frame - snapshot.frame;
                if (distance < best_distance) {
                    best_distance = distance;
                    best = snapshot;
                }
            }
        }

        return best;
    }
};

// ============================================================================
// Replay Manager
// ============================================================================

pub const ReplayManager = struct {
    allocator: std.mem.Allocator,
    current_recording: ?*ReplayRecording,
    current_playback: ?*ReplayPlayback,
    is_recording: bool,
    is_playing: bool,
    snapshot_interval: u32, // Frames between automatic snapshots

    pub fn init(allocator: std.mem.Allocator) !*ReplayManager {
        const self = try allocator.create(ReplayManager);
        self.* = ReplayManager{
            .allocator = allocator,
            .current_recording = null,
            .current_playback = null,
            .is_recording = false,
            .is_playing = false,
            .snapshot_interval = 600, // Every 10 seconds at 60 FPS
        };
        return self;
    }

    pub fn deinit(self: *ReplayManager) void {
        if (self.current_recording) |recording| {
            recording.deinit();
        }
        if (self.current_playback) |playback| {
            playback.deinit();
        }
        self.allocator.destroy(self);
    }

    pub fn startRecording(self: *ReplayManager) !void {
        if (self.current_recording) |recording| {
            recording.deinit();
        }

        self.current_recording = try ReplayRecording.init(self.allocator);
        self.is_recording = true;
    }

    pub fn stopRecording(self: *ReplayManager) ?*ReplayRecording {
        self.is_recording = false;
        const recording = self.current_recording;
        self.current_recording = null;
        return recording;
    }

    pub fn recordInput(self: *ReplayManager, input: RecordedInput) !void {
        if (self.is_recording) {
            if (self.current_recording) |recording| {
                try recording.recordInput(input);
            }
        }
    }

    pub fn advanceFrame(self: *ReplayManager) void {
        if (self.is_recording) {
            if (self.current_recording) |recording| {
                recording.advanceFrame();
            }
        }
        if (self.is_playing) {
            if (self.current_playback) |playback| {
                _ = playback.advanceFrame();
            }
        }
    }

    pub fn startPlayback(self: *ReplayManager, recording: *ReplayRecording) !void {
        if (self.current_playback) |playback| {
            playback.deinit();
        }

        self.current_playback = try ReplayPlayback.init(self.allocator, recording);
        self.current_playback.?.play();
        self.is_playing = true;
    }

    pub fn stopPlayback(self: *ReplayManager) void {
        if (self.current_playback) |playback| {
            playback.stop();
        }
        self.is_playing = false;
    }

    pub fn setSnapshotInterval(self: *ReplayManager, frames: u32) void {
        self.snapshot_interval = frames;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ReplayRecording" {
    var recording = try ReplayRecording.init(std.testing.allocator);
    defer recording.deinit();

    try recording.recordInput(.{
        .frame = 0,
        .timestamp_ms = 0,
        .input_type = .key_down,
        .data = .{ .key = .{ .code = 65, .modifiers = 0 } },
    });

    try std.testing.expectEqual(@as(u64, 1), recording.header.input_count);
}

test "StateSnapshot" {
    const data = [_]u8{ 1, 2, 3, 4, 5 };
    var snapshot = try StateSnapshot.init(std.testing.allocator, 0, 0, &data);
    defer snapshot.deinit();

    try std.testing.expect(snapshot.verify());
}

test "ReplayPlayback" {
    var recording = try ReplayRecording.init(std.testing.allocator);
    defer recording.deinit();

    recording.header.frame_count = 100;

    var playback = try ReplayPlayback.init(std.testing.allocator, recording);
    defer playback.deinit();

    playback.play();
    try std.testing.expectEqual(PlaybackState.playing, playback.state);

    playback.seekToFrame(50);
    try std.testing.expectEqual(@as(u64, 50), playback.current_frame);
}

test "ReplayManager" {
    var manager = try ReplayManager.init(std.testing.allocator);
    defer manager.deinit();

    try manager.startRecording();
    try std.testing.expect(manager.is_recording);

    const recording = manager.stopRecording();
    try std.testing.expect(!manager.is_recording);
    if (recording) |r| r.deinit();
}
