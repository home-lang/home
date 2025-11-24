// Home Audio Library - MIDI File Parser
// Standard MIDI File (SMF) format reader

const std = @import("std");
const Allocator = std.mem.Allocator;

/// MIDI file format
pub const MidiFormat = enum(u16) {
    single_track = 0, // Single track
    multi_track = 1, // Multiple tracks, synchronous
    multi_sequence = 2, // Multiple tracks, asynchronous
};

/// MIDI event types
pub const MidiEventType = enum(u4) {
    note_off = 0x8,
    note_on = 0x9,
    poly_aftertouch = 0xA,
    control_change = 0xB,
    program_change = 0xC,
    channel_aftertouch = 0xD,
    pitch_bend = 0xE,
    system = 0xF,
};

/// Meta event types
pub const MetaEventType = enum(u8) {
    sequence_number = 0x00,
    text = 0x01,
    copyright = 0x02,
    track_name = 0x03,
    instrument_name = 0x04,
    lyric = 0x05,
    marker = 0x06,
    cue_point = 0x07,
    channel_prefix = 0x20,
    end_of_track = 0x2F,
    tempo = 0x51,
    smpte_offset = 0x54,
    time_signature = 0x58,
    key_signature = 0x59,
    sequencer_specific = 0x7F,
    _,
};

/// MIDI event
pub const MidiEvent = struct {
    /// Delta time in ticks
    delta_time: u32,
    /// Absolute time in ticks
    absolute_time: u64,
    /// Event data
    data: EventData,

    pub const EventData = union(enum) {
        note_off: NoteEvent,
        note_on: NoteEvent,
        poly_aftertouch: AftertouchEvent,
        control_change: ControlEvent,
        program_change: ProgramEvent,
        channel_aftertouch: ChannelAftertouchEvent,
        pitch_bend: PitchBendEvent,
        meta: MetaEvent,
        sysex: []const u8,
    };

    pub const NoteEvent = struct {
        channel: u4,
        note: u7,
        velocity: u7,
    };

    pub const AftertouchEvent = struct {
        channel: u4,
        note: u7,
        pressure: u7,
    };

    pub const ControlEvent = struct {
        channel: u4,
        controller: u7,
        value: u7,
    };

    pub const ProgramEvent = struct {
        channel: u4,
        program: u7,
    };

    pub const ChannelAftertouchEvent = struct {
        channel: u4,
        pressure: u7,
    };

    pub const PitchBendEvent = struct {
        channel: u4,
        value: i14, // -8192 to 8191
    };

    pub const MetaEvent = struct {
        event_type: MetaEventType,
        data: []const u8,
    };
};

/// MIDI track
pub const MidiTrack = struct {
    events: []MidiEvent,
    name: ?[]const u8,
    instrument: ?[]const u8,

    pub fn deinit(self: *MidiTrack, allocator: Allocator) void {
        allocator.free(self.events);
        if (self.name) |n| allocator.free(n);
        if (self.instrument) |i| allocator.free(i);
    }
};

/// Tempo event
pub const TempoEvent = struct {
    tick: u64,
    microseconds_per_beat: u32,

    pub fn bpm(self: TempoEvent) f64 {
        return 60_000_000.0 / @as(f64, @floatFromInt(self.microseconds_per_beat));
    }
};

/// Time signature
pub const TimeSignature = struct {
    tick: u64,
    numerator: u8,
    denominator: u8, // Power of 2
    clocks_per_metronome: u8,
    thirty_seconds_per_quarter: u8,

    pub fn denominatorValue(self: TimeSignature) u32 {
        return @as(u32, 1) << self.denominator;
    }
};

/// MIDI file reader
pub const MidiReader = struct {
    allocator: Allocator,
    data: []const u8,
    pos: usize,

    // Header info
    format: MidiFormat,
    num_tracks: u16,
    ticks_per_quarter: u16, // Division

    // Tracks
    tracks: []MidiTrack,

    // Tempo map
    tempo_events: []TempoEvent,
    time_signatures: []TimeSignature,

    const Self = @This();

    /// MIDI file magic
    const HEADER_MAGIC = "MThd".*;
    const TRACK_MAGIC = "MTrk".*;

    /// Create reader from memory
    pub fn fromMemory(allocator: Allocator, data: []const u8) !Self {
        var self = Self{
            .allocator = allocator,
            .data = data,
            .pos = 0,
            .format = .single_track,
            .num_tracks = 0,
            .ticks_per_quarter = 480,
            .tracks = &[_]MidiTrack{},
            .tempo_events = &[_]TempoEvent{},
            .time_signatures = &[_]TimeSignature{},
        };

        try self.parseHeader();
        try self.parseTracks();

        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.tracks) |*t| {
            t.deinit(self.allocator);
        }
        self.allocator.free(self.tracks);
        self.allocator.free(self.tempo_events);
        self.allocator.free(self.time_signatures);
    }

    fn readBytes(self: *Self, comptime N: usize) ?*const [N]u8 {
        if (self.pos + N > self.data.len) return null;
        const result = self.data[self.pos..][0..N];
        self.pos += N;
        return result;
    }

    fn readU8(self: *Self) ?u8 {
        if (self.pos >= self.data.len) return null;
        const result = self.data[self.pos];
        self.pos += 1;
        return result;
    }

    fn readU16Be(self: *Self) ?u16 {
        const bytes = self.readBytes(2) orelse return null;
        return std.mem.readInt(u16, bytes, .big);
    }

    fn readU32Be(self: *Self) ?u32 {
        const bytes = self.readBytes(4) orelse return null;
        return std.mem.readInt(u32, bytes, .big);
    }

    fn readVariableLength(self: *Self) ?u32 {
        var value: u32 = 0;
        var i: u32 = 0;
        while (i < 4) : (i += 1) {
            const byte = self.readU8() orelse return null;
            value = (value << 7) | (byte & 0x7F);
            if (byte & 0x80 == 0) break;
        }
        return value;
    }

    fn parseHeader(self: *Self) !void {
        const magic = self.readBytes(4) orelse return error.TruncatedData;
        if (!std.mem.eql(u8, magic, &HEADER_MAGIC)) return error.InvalidFormat;

        const chunk_size = self.readU32Be() orelse return error.TruncatedData;
        if (chunk_size < 6) return error.InvalidFormat;

        const format_raw = self.readU16Be() orelse return error.TruncatedData;
        self.format = @enumFromInt(format_raw);

        self.num_tracks = self.readU16Be() orelse return error.TruncatedData;

        const division = self.readU16Be() orelse return error.TruncatedData;
        if (division & 0x8000 != 0) {
            // SMPTE format - not commonly used
            return error.UnsupportedFormat;
        }
        self.ticks_per_quarter = division;

        // Skip any extra header bytes
        if (chunk_size > 6) {
            self.pos += chunk_size - 6;
        }
    }

    fn parseTracks(self: *Self) !void {
        var tracks_list = std.ArrayList(MidiTrack).init(self.allocator);
        defer tracks_list.deinit(self.allocator);

        var tempo_list = std.ArrayList(TempoEvent).init(self.allocator);
        defer tempo_list.deinit(self.allocator);

        var time_sig_list = std.ArrayList(TimeSignature).init(self.allocator);
        defer time_sig_list.deinit(self.allocator);

        for (0..self.num_tracks) |_| {
            const track = try self.parseTrack(&tempo_list, &time_sig_list);
            try tracks_list.append(self.allocator, track);
        }

        self.tracks = try tracks_list.toOwnedSlice(self.allocator);
        self.tempo_events = try tempo_list.toOwnedSlice(self.allocator);
        self.time_signatures = try time_sig_list.toOwnedSlice(self.allocator);
    }

    fn parseTrack(
        self: *Self,
        tempo_list: *std.ArrayList(TempoEvent),
        time_sig_list: *std.ArrayList(TimeSignature),
    ) !MidiTrack {
        const magic = self.readBytes(4) orelse return error.TruncatedData;
        if (!std.mem.eql(u8, magic, &TRACK_MAGIC)) return error.InvalidFormat;

        const chunk_size = self.readU32Be() orelse return error.TruncatedData;
        const track_end = self.pos + chunk_size;

        var events = std.ArrayList(MidiEvent).init(self.allocator);
        defer events.deinit(self.allocator);

        var track_name: ?[]const u8 = null;
        var instrument_name: ?[]const u8 = null;

        var running_status: u8 = 0;
        var absolute_time: u64 = 0;

        while (self.pos < track_end) {
            const delta = self.readVariableLength() orelse break;
            absolute_time += delta;

            var status = self.readU8() orelse break;

            // Running status
            if (status < 0x80) {
                self.pos -= 1;
                status = running_status;
            } else if (status < 0xF0) {
                running_status = status;
            }

            const event_type: u4 = @truncate(status >> 4);
            const channel: u4 = @truncate(status);

            const event_data: MidiEvent.EventData = switch (event_type) {
                0x8 => blk: {
                    const note: u7 = @truncate(self.readU8() orelse break);
                    const velocity: u7 = @truncate(self.readU8() orelse break);
                    break :blk .{ .note_off = .{ .channel = channel, .note = note, .velocity = velocity } };
                },
                0x9 => blk: {
                    const note: u7 = @truncate(self.readU8() orelse break);
                    const velocity: u7 = @truncate(self.readU8() orelse break);
                    // Note on with velocity 0 is note off
                    if (velocity == 0) {
                        break :blk .{ .note_off = .{ .channel = channel, .note = note, .velocity = 0 } };
                    }
                    break :blk .{ .note_on = .{ .channel = channel, .note = note, .velocity = velocity } };
                },
                0xA => blk: {
                    const note: u7 = @truncate(self.readU8() orelse break);
                    const pressure: u7 = @truncate(self.readU8() orelse break);
                    break :blk .{ .poly_aftertouch = .{ .channel = channel, .note = note, .pressure = pressure } };
                },
                0xB => blk: {
                    const controller: u7 = @truncate(self.readU8() orelse break);
                    const value: u7 = @truncate(self.readU8() orelse break);
                    break :blk .{ .control_change = .{ .channel = channel, .controller = controller, .value = value } };
                },
                0xC => blk: {
                    const program: u7 = @truncate(self.readU8() orelse break);
                    break :blk .{ .program_change = .{ .channel = channel, .program = program } };
                },
                0xD => blk: {
                    const pressure: u7 = @truncate(self.readU8() orelse break);
                    break :blk .{ .channel_aftertouch = .{ .channel = channel, .pressure = pressure } };
                },
                0xE => blk: {
                    const lsb = self.readU8() orelse break;
                    const msb = self.readU8() orelse break;
                    const value: i14 = @as(i14, @intCast((@as(u14, msb) << 7) | lsb)) - 8192;
                    break :blk .{ .pitch_bend = .{ .channel = channel, .value = value } };
                },
                0xF => blk: {
                    if (status == 0xFF) {
                        // Meta event
                        const meta_type: MetaEventType = @enumFromInt(self.readU8() orelse break);
                        const length = self.readVariableLength() orelse break;
                        const meta_data = if (length > 0 and self.pos + length <= self.data.len)
                            self.data[self.pos..][0..length]
                        else
                            &[_]u8{};
                        self.pos += length;

                        // Extract tempo and time signature
                        switch (meta_type) {
                            .tempo => {
                                if (meta_data.len >= 3) {
                                    const uspb = (@as(u32, meta_data[0]) << 16) |
                                        (@as(u32, meta_data[1]) << 8) |
                                        @as(u32, meta_data[2]);
                                    try tempo_list.append(self.allocator, .{
                                        .tick = absolute_time,
                                        .microseconds_per_beat = uspb,
                                    });
                                }
                            },
                            .time_signature => {
                                if (meta_data.len >= 4) {
                                    try time_sig_list.append(self.allocator, .{
                                        .tick = absolute_time,
                                        .numerator = meta_data[0],
                                        .denominator = meta_data[1],
                                        .clocks_per_metronome = meta_data[2],
                                        .thirty_seconds_per_quarter = meta_data[3],
                                    });
                                }
                            },
                            .track_name => {
                                track_name = try self.allocator.dupe(u8, meta_data);
                            },
                            .instrument_name => {
                                instrument_name = try self.allocator.dupe(u8, meta_data);
                            },
                            else => {},
                        }

                        break :blk .{ .meta = .{ .event_type = meta_type, .data = meta_data } };
                    } else if (status == 0xF0 or status == 0xF7) {
                        // SysEx
                        const length = self.readVariableLength() orelse break;
                        const sysex_data = if (length > 0 and self.pos + length <= self.data.len)
                            self.data[self.pos..][0..length]
                        else
                            &[_]u8{};
                        self.pos += length;
                        break :blk .{ .sysex = sysex_data };
                    } else {
                        continue;
                    }
                },
                else => continue,
            };

            try events.append(self.allocator, .{
                .delta_time = delta,
                .absolute_time = absolute_time,
                .data = event_data,
            });
        }

        self.pos = track_end;

        return MidiTrack{
            .events = try events.toOwnedSlice(self.allocator),
            .name = track_name,
            .instrument = instrument_name,
        };
    }

    /// Get duration in seconds
    pub fn getDuration(self: *const Self) f64 {
        if (self.tracks.len == 0) return 0;

        var max_ticks: u64 = 0;
        for (self.tracks) |track| {
            if (track.events.len > 0) {
                const last_tick = track.events[track.events.len - 1].absolute_time;
                if (last_tick > max_ticks) {
                    max_ticks = last_tick;
                }
            }
        }

        return self.ticksToSeconds(max_ticks);
    }

    /// Convert ticks to seconds
    pub fn ticksToSeconds(self: *const Self, ticks: u64) f64 {
        // Simple conversion assuming constant tempo
        const default_tempo: u32 = 500000; // 120 BPM
        const tempo = if (self.tempo_events.len > 0) self.tempo_events[0].microseconds_per_beat else default_tempo;

        const seconds_per_tick = @as(f64, @floatFromInt(tempo)) / 1_000_000.0 / @as(f64, @floatFromInt(self.ticks_per_quarter));
        return @as(f64, @floatFromInt(ticks)) * seconds_per_tick;
    }

    /// Get BPM (from first tempo event or default)
    pub fn getBpm(self: *const Self) f64 {
        if (self.tempo_events.len > 0) {
            return self.tempo_events[0].bpm();
        }
        return 120.0;
    }
};

/// Detect if data is MIDI format
pub fn isMidi(data: []const u8) bool {
    if (data.len < 4) return false;
    return std.mem.eql(u8, data[0..4], "MThd");
}

/// Note number to name
pub fn noteToName(note: u7) [3]u8 {
    const names = [_][]const u8{ "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" };
    const octave = note / 12 - 1;
    const name_idx = note % 12;

    var result: [3]u8 = .{ ' ', ' ', ' ' };
    const name = names[name_idx];
    @memcpy(result[0..name.len], name);
    result[name.len] = '0' + @as(u8, @intCast(octave));
    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "MIDI detection" {
    const midi_data = "MThd" ++ [_]u8{0} ** 10;
    try std.testing.expect(isMidi(midi_data));

    const not_midi = "RIFF" ++ [_]u8{0} ** 10;
    try std.testing.expect(!isMidi(not_midi));
}

test "Note to name" {
    const c4 = noteToName(60);
    try std.testing.expectEqualStrings("C4 ", &c4);

    const a4 = noteToName(69);
    try std.testing.expectEqualStrings("A4 ", &a4);
}

test "TempoEvent bpm" {
    const tempo = TempoEvent{
        .tick = 0,
        .microseconds_per_beat = 500000, // 120 BPM
    };
    try std.testing.expectApproxEqAbs(@as(f64, 120.0), tempo.bpm(), 0.01);
}
