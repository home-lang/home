const std = @import("std");
const types = @import("../core/types.zig");
const VideoFrame = @import("../core/frame.zig").VideoFrame;
const AudioFrame = @import("../core/frame.zig").AudioFrame;

/// Timeline - Non-linear editing container
pub const Timeline = struct {
    allocator: std.mem.Allocator,
    video_tracks: std.ArrayList(Track),
    audio_tracks: std.ArrayList(Track),
    subtitle_tracks: std.ArrayList(Track),
    frame_rate: types.Rational,
    duration_us: u64,
    width: u32,
    height: u32,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, frame_rate: types.Rational) Timeline {
        return .{
            .allocator = allocator,
            .video_tracks = std.ArrayList(Track).init(allocator),
            .audio_tracks = std.ArrayList(Track).init(allocator),
            .subtitle_tracks = std.ArrayList(Track).init(allocator),
            .frame_rate = frame_rate,
            .duration_us = 0,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *Timeline) void {
        for (self.video_tracks.items) |*track| track.deinit();
        for (self.audio_tracks.items) |*track| track.deinit();
        for (self.subtitle_tracks.items) |*track| track.deinit();
        self.video_tracks.deinit();
        self.audio_tracks.deinit();
        self.subtitle_tracks.deinit();
    }

    pub fn addVideoTrack(self: *Timeline, name: []const u8) !*Track {
        var track = Track.init(self.allocator, .video, name);
        try self.video_tracks.append(track);
        return &self.video_tracks.items[self.video_tracks.items.len - 1];
    }

    pub fn addAudioTrack(self: *Timeline, name: []const u8) !*Track {
        var track = Track.init(self.allocator, .audio, name);
        try self.audio_tracks.append(track);
        return &self.audio_tracks.items[self.audio_tracks.items.len - 1];
    }

    pub fn getDuration(self: *const Timeline) u64 {
        var max_duration: u64 = 0;
        for (self.video_tracks.items) |*track| {
            max_duration = @max(max_duration, track.getDuration());
        }
        for (self.audio_tracks.items) |*track| {
            max_duration = @max(max_duration, track.getDuration());
        }
        return max_duration;
    }
};

/// Track - Single lane in timeline
pub const Track = struct {
    allocator: std.mem.Allocator,
    track_type: TrackType,
    name: []const u8,
    clips: std.ArrayList(Clip),
    enabled: bool,
    muted: bool,
    opacity: f32,
    blend_mode: BlendMode,

    pub const TrackType = enum {
        video,
        audio,
        subtitle,
    };

    pub const BlendMode = enum {
        normal,
        multiply,
        screen,
        overlay,
        add,
        subtract,
    };

    pub fn init(allocator: std.mem.Allocator, track_type: TrackType, name: []const u8) Track {
        return .{
            .allocator = allocator,
            .track_type = track_type,
            .name = name,
            .clips = std.ArrayList(Clip).init(allocator),
            .enabled = true,
            .muted = false,
            .opacity = 1.0,
            .blend_mode = .normal,
        };
    }

    pub fn deinit(self: *Track) void {
        for (self.clips.items) |*clip| clip.deinit();
        self.clips.deinit();
    }

    pub fn insertClip(self: *Track, clip: Clip, position_us: u64) !void {
        var new_clip = clip;
        new_clip.timeline_in = position_us;
        new_clip.timeline_out = position_us + (clip.source_out - clip.source_in);

        // Find insertion point
        var insert_idx: usize = 0;
        for (self.clips.items, 0..) |*existing, i| {
            if (existing.timeline_in > position_us) break;
            insert_idx = i + 1;
        }

        try self.clips.insert(insert_idx, new_clip);
    }

    pub fn overwriteClip(self: *Track, clip: Clip, position_us: u64) !void {
        const clip_duration = clip.source_out - clip.source_in;
        const clip_end = position_us + clip_duration;

        // Remove overlapping clips
        var i: usize = 0;
        while (i < self.clips.items.len) {
            const existing = &self.clips.items[i];
            if (existing.timeline_out > position_us and existing.timeline_in < clip_end) {
                var removed = self.clips.orderedRemove(i);
                removed.deinit();
            } else {
                i += 1;
            }
        }

        var new_clip = clip;
        new_clip.timeline_in = position_us;
        new_clip.timeline_out = clip_end;
        try self.clips.append(new_clip);
    }

    pub fn rippleDelete(self: *Track, clip_index: usize) !void {
        if (clip_index >= self.clips.items.len) return error.InvalidIndex;

        const removed_clip = self.clips.items[clip_index];
        const clip_duration = removed_clip.timeline_out - removed_clip.timeline_in;

        var removed = self.clips.orderedRemove(clip_index);
        removed.deinit();

        // Shift all subsequent clips
        for (self.clips.items[clip_index..]) |*clip| {
            clip.timeline_in -= clip_duration;
            clip.timeline_out -= clip_duration;
        }
    }

    pub fn splitClip(self: *Track, clip_index: usize, split_time_us: u64) !void {
        if (clip_index >= self.clips.items.len) return error.InvalidIndex;

        const clip = &self.clips.items[clip_index];
        if (split_time_us <= clip.timeline_in or split_time_us >= clip.timeline_out) {
            return error.InvalidSplitTime;
        }

        const offset_in_clip = split_time_us - clip.timeline_in;
        const new_source_in = clip.source_in + offset_in_clip;

        // Create second half
        var second_half = Clip{
            .allocator = self.allocator,
            .source_path = clip.source_path,
            .source_in = new_source_in,
            .source_out = clip.source_out,
            .timeline_in = split_time_us,
            .timeline_out = clip.timeline_out,
            .speed = clip.speed,
            .volume = clip.volume,
            .transition_in = null,
            .transition_out = null,
        };

        // Modify first half
        clip.source_out = new_source_in;
        clip.timeline_out = split_time_us;

        try self.clips.insert(clip_index + 1, second_half);
    }

    pub fn getDuration(self: *const Track) u64 {
        var max: u64 = 0;
        for (self.clips.items) |*clip| {
            max = @max(max, clip.timeline_out);
        }
        return max;
    }
};

/// Clip - Media segment on a track
pub const Clip = struct {
    allocator: std.mem.Allocator,
    source_path: []const u8,
    source_in: u64, // microseconds
    source_out: u64,
    timeline_in: u64,
    timeline_out: u64,
    speed: f32,
    volume: f32,
    transition_in: ?Transition,
    transition_out: ?Transition,

    pub fn deinit(self: *Clip) void {
        _ = self;
    }

    pub fn getDuration(self: *const Clip) u64 {
        return self.timeline_out - self.timeline_in;
    }

    pub fn getSourceDuration(self: *const Clip) u64 {
        return self.source_out - self.source_in;
    }
};

/// Transition - Effect between clips
pub const Transition = struct {
    transition_type: TransitionType,
    duration_us: u64,
    easing: EasingFunction,

    pub const TransitionType = enum {
        cut,
        fade,
        crossfade,
        dissolve,
        wipe_left,
        wipe_right,
        wipe_up,
        wipe_down,
        slide,
        push,
    };

    pub const EasingFunction = enum {
        linear,
        ease_in,
        ease_out,
        ease_in_out,
        cubic_bezier,
    };

    pub fn apply(self: *const Transition, progress: f32) f32 {
        return switch (self.easing) {
            .linear => progress,
            .ease_in => progress * progress,
            .ease_out => 1.0 - (1.0 - progress) * (1.0 - progress),
            .ease_in_out => if (progress < 0.5)
                2.0 * progress * progress
            else
                1.0 - std.math.pow(f32, -2.0 * progress + 2.0, 2.0) / 2.0,
            .cubic_bezier => progress, // Simplified
        };
    }
};

/// Timeline renderer
pub const TimelineRenderer = struct {
    allocator: std.mem.Allocator,
    timeline: *Timeline,

    pub fn init(allocator: std.mem.Allocator, timeline: *Timeline) TimelineRenderer {
        return .{
            .allocator = allocator,
            .timeline = timeline,
        };
    }

    pub fn renderFrame(self: *TimelineRenderer, timestamp_us: u64) !?VideoFrame {
        _ = self;
        _ = timestamp_us;
        // Would composite all video tracks at this timestamp
        return null;
    }

    pub fn renderAudio(self: *TimelineRenderer, start_us: u64, duration_us: u64) !?AudioFrame {
        _ = self;
        _ = start_us;
        _ = duration_us;
        // Would mix all audio tracks in this range
        return null;
    }
};

/// EDL (Edit Decision List) export
pub const EdlExporter = struct {
    pub fn exportEdl(timeline: *const Timeline, allocator: std.mem.Allocator) ![]u8 {
        var output = std.ArrayList(u8).init(allocator);
        const writer = output.writer();

        try writer.writeAll("TITLE: Timeline Export\n");
        try writer.writeAll("FCM: NON-DROP FRAME\n\n");

        var event_num: u32 = 1;
        for (timeline.video_tracks.items) |*track| {
            for (track.clips.items) |*clip| {
                try writer.print("{d:0>6}  001      V     C        ", .{event_num});
                try writeTimecode(writer, clip.source_in);
                try writer.writeAll(" ");
                try writeTimecode(writer, clip.source_out);
                try writer.writeAll(" ");
                try writeTimecode(writer, clip.timeline_in);
                try writer.writeAll(" ");
                try writeTimecode(writer, clip.timeline_out);
                try writer.writeAll("\n");
                event_num += 1;
            }
        }

        return output.toOwnedSlice();
    }

    fn writeTimecode(writer: anytype, time_us: u64) !void {
        const hours = time_us / 3600000000;
        const minutes = (time_us / 60000000) % 60;
        const seconds = (time_us / 1000000) % 60;
        const frames = ((time_us % 1000000) * 30) / 1000000; // Assuming 30fps
        try writer.print("{d:0>2}:{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds, frames });
    }
};

/// Project serialization
pub const TimelineProject = struct {
    timeline: Timeline,
    project_name: []const u8,
    created_date: i64,

    pub fn save(self: *const TimelineProject, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        _ = allocator;
        // Would serialize to JSON
        return error.NotImplemented;
    }

    pub fn load(data: []const u8, allocator: std.mem.Allocator) !TimelineProject {
        _ = data;
        _ = allocator;
        // Would deserialize from JSON
        return error.NotImplemented;
    }
};
