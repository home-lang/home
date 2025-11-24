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
        // Serialize timeline project to JSON
        var output = std.ArrayList(u8).init(allocator);
        errdefer output.deinit();

        const writer = output.writer();

        try writer.writeAll("{");

        // Project metadata
        try writer.print("\"project_name\":\"{s}\",", .{self.project_name});
        try writer.print("\"created_date\":{d},", .{self.created_date});

        // Timeline properties
        try writer.writeAll("\"timeline\":{");
        try writer.print("\"frame_rate\":{{\"num\":{d},\"den\":{d}}},", .{ self.timeline.frame_rate.num, self.timeline.frame_rate.den });
        try writer.print("\"duration_us\":{d},", .{self.timeline.duration_us});
        try writer.print("\"width\":{d},", .{self.timeline.width});
        try writer.print("\"height\":{d},", .{self.timeline.height});

        // Video tracks
        try writer.writeAll("\"video_tracks\":[");
        for (self.timeline.video_tracks.items, 0..) |*track, i| {
            if (i > 0) try writer.writeAll(",");
            try serializeTrack(writer, track);
        }
        try writer.writeAll("],");

        // Audio tracks
        try writer.writeAll("\"audio_tracks\":[");
        for (self.timeline.audio_tracks.items, 0..) |*track, i| {
            if (i > 0) try writer.writeAll(",");
            try serializeTrack(writer, track);
        }
        try writer.writeAll("],");

        // Subtitle tracks
        try writer.writeAll("\"subtitle_tracks\":[");
        for (self.timeline.subtitle_tracks.items, 0..) |*track, i| {
            if (i > 0) try writer.writeAll(",");
            try serializeTrack(writer, track);
        }
        try writer.writeAll("]");

        try writer.writeAll("}"); // End timeline
        try writer.writeAll("}"); // End project

        return output.toOwnedSlice();
    }

    fn serializeTrack(writer: anytype, track: *const Track) !void {
        try writer.writeAll("{");
        try writer.print("\"name\":\"{s}\",", .{track.name});
        try writer.print("\"track_type\":\"{s}\",", .{@tagName(track.track_type)});
        try writer.print("\"enabled\":{},", .{track.enabled});
        try writer.print("\"muted\":{},", .{track.muted});
        try writer.print("\"opacity\":{d},", .{track.opacity});
        try writer.print("\"blend_mode\":\"{s}\",", .{@tagName(track.blend_mode)});

        try writer.writeAll("\"clips\":[");
        for (track.clips.items, 0..) |*clip, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{");
            try writer.print("\"source_path\":\"{s}\",", .{clip.source_path});
            try writer.print("\"source_in\":{d},", .{clip.source_in});
            try writer.print("\"source_out\":{d},", .{clip.source_out});
            try writer.print("\"timeline_in\":{d},", .{clip.timeline_in});
            try writer.print("\"timeline_out\":{d},", .{clip.timeline_out});
            try writer.print("\"speed\":{d},", .{clip.speed});
            try writer.print("\"volume\":{d}", .{clip.volume});
            try writer.writeAll("}");
        }
        try writer.writeAll("]");

        try writer.writeAll("}");
    }

    pub fn load(data: []const u8, allocator: std.mem.Allocator) !TimelineProject {
        // Parse JSON timeline project
        // Using std.json for parsing
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
        defer parsed.deinit();

        const root = parsed.value.object;

        // Extract project metadata
        const project_name_val = root.get("project_name") orelse return error.InvalidJson;
        const project_name = try allocator.dupe(u8, project_name_val.string);

        const created_date = root.get("created_date") orelse return error.InvalidJson;

        // Extract timeline
        const timeline_obj = (root.get("timeline") orelse return error.InvalidJson).object;

        // Parse frame rate
        const frame_rate_obj = (timeline_obj.get("frame_rate") orelse return error.InvalidJson).object;
        const frame_rate = types.Rational{
            .num = @intCast((frame_rate_obj.get("num") orelse return error.InvalidJson).integer),
            .den = @intCast((frame_rate_obj.get("den") orelse return error.InvalidJson).integer),
        };

        const width: u32 = @intCast((timeline_obj.get("width") orelse return error.InvalidJson).integer);
        const height: u32 = @intCast((timeline_obj.get("height") orelse return error.InvalidJson).integer);

        var timeline = Timeline.init(allocator, width, height, frame_rate);
        errdefer timeline.deinit();

        timeline.duration_us = @intCast((timeline_obj.get("duration_us") orelse return error.InvalidJson).integer);

        // Load video tracks
        const video_tracks_arr = (timeline_obj.get("video_tracks") orelse return error.InvalidJson).array;
        for (video_tracks_arr.items) |track_val| {
            const track = try deserializeTrack(allocator, track_val.object);
            try timeline.video_tracks.append(track);
        }

        // Load audio tracks
        const audio_tracks_arr = (timeline_obj.get("audio_tracks") orelse return error.InvalidJson).array;
        for (audio_tracks_arr.items) |track_val| {
            const track = try deserializeTrack(allocator, track_val.object);
            try timeline.audio_tracks.append(track);
        }

        // Load subtitle tracks
        const subtitle_tracks_arr = (timeline_obj.get("subtitle_tracks") orelse return error.InvalidJson).array;
        for (subtitle_tracks_arr.items) |track_val| {
            const track = try deserializeTrack(allocator, track_val.object);
            try timeline.subtitle_tracks.append(track);
        }

        return TimelineProject{
            .timeline = timeline,
            .project_name = project_name,
            .created_date = created_date.integer,
        };
    }

    fn deserializeTrack(allocator: std.mem.Allocator, track_obj: std.json.ObjectMap) !Track {
        const name = try allocator.dupe(u8, (track_obj.get("name") orelse return error.InvalidJson).string);

        const track_type_str = (track_obj.get("track_type") orelse return error.InvalidJson).string;
        const track_type: Track.TrackType = if (std.mem.eql(u8, track_type_str, "video"))
            .video
        else if (std.mem.eql(u8, track_type_str, "audio"))
            .audio
        else
            .subtitle;

        var track = Track.init(allocator, track_type, name);

        track.enabled = (track_obj.get("enabled") orelse return error.InvalidJson).bool;
        track.muted = (track_obj.get("muted") orelse return error.InvalidJson).bool;

        const opacity_val = track_obj.get("opacity") orelse return error.InvalidJson;
        track.opacity = @floatCast(opacity_val.float);

        const blend_mode_str = (track_obj.get("blend_mode") orelse return error.InvalidJson).string;
        track.blend_mode = std.meta.stringToEnum(Track.BlendMode, blend_mode_str) orelse .normal;

        // Load clips
        const clips_arr = (track_obj.get("clips") orelse return error.InvalidJson).array;
        for (clips_arr.items) |clip_val| {
            const clip_obj = clip_val.object;

            const source_path = try allocator.dupe(u8, (clip_obj.get("source_path") orelse return error.InvalidJson).string);

            const speed_val = clip_obj.get("speed") orelse return error.InvalidJson;
            const volume_val = clip_obj.get("volume") orelse return error.InvalidJson;

            const clip = Clip{
                .allocator = allocator,
                .source_path = source_path,
                .source_in = @intCast((clip_obj.get("source_in") orelse return error.InvalidJson).integer),
                .source_out = @intCast((clip_obj.get("source_out") orelse return error.InvalidJson).integer),
                .timeline_in = @intCast((clip_obj.get("timeline_in") orelse return error.InvalidJson).integer),
                .timeline_out = @intCast((clip_obj.get("timeline_out") orelse return error.InvalidJson).integer),
                .speed = @floatCast(speed_val.float),
                .volume = @floatCast(volume_val.float),
                .transition_in = null,
                .transition_out = null,
            };

            try track.clips.append(clip);
        }

        return track;
    }
};
