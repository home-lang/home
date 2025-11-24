const std = @import("std");
const types = @import("../core/types.zig");
const frame = @import("../core/frame.zig");
const packet = @import("../core/packet.zig");

/// Video sink interface
pub const VideoSink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        writeFrame: *const fn (ptr: *anyopaque, video_frame: frame.VideoFrame) anyerror!void,
        flush: *const fn (ptr: *anyopaque) anyerror!void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn writeFrame(self: VideoSink, video_frame: frame.VideoFrame) !void {
        return self.vtable.writeFrame(self.ptr, video_frame);
    }

    pub fn flush(self: VideoSink) !void {
        return self.vtable.flush(self.ptr);
    }

    pub fn deinit(self: VideoSink) void {
        self.vtable.deinit(self.ptr);
    }
};

/// Audio sink interface
pub const AudioSink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        writeSamples: *const fn (ptr: *anyopaque, audio_frame: frame.AudioFrame) anyerror!void,
        flush: *const fn (ptr: *anyopaque) anyerror!void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn writeSamples(self: AudioSink, audio_frame: frame.AudioFrame) !void {
        return self.vtable.writeSamples(self.ptr, audio_frame);
    }

    pub fn flush(self: AudioSink) !void {
        return self.vtable.flush(self.ptr);
    }

    pub fn deinit(self: AudioSink) void {
        self.vtable.deinit(self.ptr);
    }
};

/// Video frame sink (collect decoded frames)
pub const VideoFrameSink = struct {
    allocator: std.mem.Allocator,
    frames: std.ArrayList(frame.VideoFrame),

    pub fn init(allocator: std.mem.Allocator) VideoFrameSink {
        return .{
            .allocator = allocator,
            .frames = std.ArrayList(frame.VideoFrame).init(allocator),
        };
    }

    pub fn deinit(self: *VideoFrameSink) void {
        self.frames.deinit();
    }

    pub fn asVideoSink(self: *VideoFrameSink) VideoSink {
        return VideoSink{
            .ptr = self,
            .vtable = &.{
                .writeFrame = writeFrameImpl,
                .flush = flushImpl,
                .deinit = deinitImpl,
            },
        };
    }

    pub fn getFrames(self: *const VideoFrameSink) []const frame.VideoFrame {
        return self.frames.items;
    }

    pub fn getFrame(self: *const VideoFrameSink, index: usize) ?frame.VideoFrame {
        if (index < self.frames.items.len) {
            return self.frames.items[index];
        }
        return null;
    }

    fn writeFrameImpl(ptr: *anyopaque, video_frame: frame.VideoFrame) !void {
        const self: *VideoFrameSink = @ptrCast(@alignCast(ptr));
        try self.frames.append(video_frame);
    }

    fn flushImpl(ptr: *anyopaque) !void {
        _ = ptr;
        // Nothing to flush
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *VideoFrameSink = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

/// Image sequence sink (export frames as image files)
pub const ImageSequenceSink = struct {
    allocator: std.mem.Allocator,
    output_pattern: []const u8, // e.g., "frame_%04d.png"
    image_format: []const u8, // "png", "jpg", "webp"
    frame_count: u32,
    quality: u8, // 0-100 for JPEG

    pub fn init(allocator: std.mem.Allocator, output_pattern: []const u8, image_format: []const u8) ImageSequenceSink {
        return .{
            .allocator = allocator,
            .output_pattern = output_pattern,
            .image_format = image_format,
            .frame_count = 0,
            .quality = 90,
        };
    }

    pub fn deinit(self: *ImageSequenceSink) void {
        _ = self;
    }

    pub fn asVideoSink(self: *ImageSequenceSink) VideoSink {
        return VideoSink{
            .ptr = self,
            .vtable = &.{
                .writeFrame = writeFrameImpl,
                .flush = flushImpl,
                .deinit = deinitImpl,
            },
        };
    }

    fn writeFrameImpl(ptr: *anyopaque, video_frame: frame.VideoFrame) !void {
        const self: *ImageSequenceSink = @ptrCast(@alignCast(ptr));

        // Generate filename
        var filename_buf: [256]u8 = undefined;
        const filename = try std.fmt.bufPrint(&filename_buf, self.output_pattern, .{self.frame_count});

        _ = filename;
        _ = video_frame;

        // Would convert frame to image and save
        // Integration with packages/image would happen here

        self.frame_count += 1;
    }

    fn flushImpl(ptr: *anyopaque) !void {
        _ = ptr;
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *ImageSequenceSink = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

/// Encoded packet sink (get raw encoded packets)
pub const EncodedPacketSink = struct {
    allocator: std.mem.Allocator,
    packets: std.ArrayList(packet.Packet),

    pub fn init(allocator: std.mem.Allocator) EncodedPacketSink {
        return .{
            .allocator = allocator,
            .packets = std.ArrayList(packet.Packet).init(allocator),
        };
    }

    pub fn deinit(self: *EncodedPacketSink) void {
        self.packets.deinit();
    }

    pub fn writePacket(self: *EncodedPacketSink, pkt: packet.Packet) !void {
        try self.packets.append(pkt);
    }

    pub fn getPackets(self: *const EncodedPacketSink) []const packet.Packet {
        return self.packets.items;
    }

    pub fn getPacket(self: *const EncodedPacketSink, index: usize) ?packet.Packet {
        if (index < self.packets.items.len) {
            return self.packets.items[index];
        }
        return null;
    }
};

/// Audio sample sink (collect decoded samples)
pub const AudioSampleSink = struct {
    allocator: std.mem.Allocator,
    samples: std.ArrayList(f32),
    sample_rate: u32,
    channels: u8,

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32, channels: u8) AudioSampleSink {
        return .{
            .allocator = allocator,
            .samples = std.ArrayList(f32).init(allocator),
            .sample_rate = sample_rate,
            .channels = channels,
        };
    }

    pub fn deinit(self: *AudioSampleSink) void {
        self.samples.deinit();
    }

    pub fn asAudioSink(self: *AudioSampleSink) AudioSink {
        return AudioSink{
            .ptr = self,
            .vtable = &.{
                .writeSamples = writeSamplesImpl,
                .flush = flushImpl,
                .deinit = deinitImpl,
            },
        };
    }

    pub fn getSamples(self: *const AudioSampleSink) []const f32 {
        return self.samples.items;
    }

    pub fn getFrameCount(self: *const AudioSampleSink) usize {
        return self.samples.items.len / self.channels;
    }

    pub fn getDuration(self: *const AudioSampleSink) u64 {
        const frame_count = self.getFrameCount();
        return @intFromFloat(@as(f64, @floatFromInt(frame_count)) / @as(f64, @floatFromInt(self.sample_rate)) * 1_000_000.0);
    }

    fn writeSamplesImpl(ptr: *anyopaque, audio_frame: frame.AudioFrame) !void {
        const self: *AudioSampleSink = @ptrCast(@alignCast(ptr));

        // Extract all samples from audio frame as f32
        const num_samples = audio_frame.num_samples;
        const channels = audio_frame.channels;

        // Reserve space for new samples
        const total_new_samples = @as(usize, num_samples) * @as(usize, channels);
        try self.samples.ensureTotalCapacity(self.samples.items.len + total_new_samples);

        // Extract samples and append to buffer (interleaved format)
        for (0..num_samples) |sample_idx| {
            for (0..channels) |ch| {
                const sample = audio_frame.getSampleF32(@intCast(ch), @intCast(sample_idx)) orelse 0.0;
                try self.samples.append(sample);
            }
        }
    }

    fn flushImpl(ptr: *anyopaque) !void {
        _ = ptr;
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *AudioSampleSink = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

/// Waveform sink (generate waveform visualization data)
pub const WaveformSink = struct {
    allocator: std.mem.Allocator,
    sample_rate: u32,
    channels: u8,
    window_size: usize, // Samples per waveform point
    peaks: std.ArrayList(WaveformPoint),

    pub const WaveformPoint = struct {
        min: f32,
        max: f32,
        rms: f32,
    };

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32, channels: u8, window_size: usize) WaveformSink {
        return .{
            .allocator = allocator,
            .sample_rate = sample_rate,
            .channels = channels,
            .window_size = window_size,
            .peaks = std.ArrayList(WaveformPoint).init(allocator),
        };
    }

    pub fn deinit(self: *WaveformSink) void {
        self.peaks.deinit();
    }

    pub fn asAudioSink(self: *WaveformSink) AudioSink {
        return AudioSink{
            .ptr = self,
            .vtable = &.{
                .writeSamples = writeSamplesImpl,
                .flush = flushImpl,
                .deinit = deinitImpl,
            },
        };
    }

    pub fn getPeaks(self: *const WaveformSink) []const WaveformPoint {
        return self.peaks.items;
    }

    fn writeSamplesImpl(ptr: *anyopaque, audio_frame: frame.AudioFrame) !void {
        const self: *WaveformSink = @ptrCast(@alignCast(ptr));

        const num_samples = audio_frame.num_samples;
        const channels = audio_frame.channels;

        // Process samples in windows to generate waveform points
        var sample_idx: usize = 0;
        while (sample_idx < num_samples) {
            const window_end = @min(sample_idx + self.window_size, num_samples);
            const window_samples = window_end - sample_idx;

            if (window_samples == 0) break;

            var min_val: f32 = 1.0;
            var max_val: f32 = -1.0;
            var sum_squares: f32 = 0.0;
            var count: usize = 0;

            // Calculate min, max, and RMS for this window across all channels
            for (sample_idx..window_end) |i| {
                for (0..channels) |ch| {
                    const sample = audio_frame.getSampleF32(@intCast(ch), @intCast(i)) orelse 0.0;

                    min_val = @min(min_val, sample);
                    max_val = @max(max_val, sample);
                    sum_squares += sample * sample;
                    count += 1;
                }
            }

            // Calculate RMS
            const rms = if (count > 0)
                @sqrt(sum_squares / @as(f32, @floatFromInt(count)))
            else
                0.0;

            // Add waveform point
            try self.peaks.append(.{
                .min = min_val,
                .max = max_val,
                .rms = rms,
            });

            sample_idx = window_end;
        }
    }

    fn flushImpl(ptr: *anyopaque) !void {
        _ = ptr;
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *WaveformSink = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

/// Null sink (discard all data, for analysis/benchmarking)
pub const NullSink = struct {
    frame_count: u64,
    sample_count: u64,

    pub fn init() NullSink {
        return .{
            .frame_count = 0,
            .sample_count = 0,
        };
    }

    pub fn deinit(self: *NullSink) void {
        _ = self;
    }

    pub fn asVideoSink(self: *NullSink) VideoSink {
        return VideoSink{
            .ptr = self,
            .vtable = &.{
                .writeFrame = writeFrameImpl,
                .flush = flushImpl,
                .deinit = deinitImpl,
            },
        };
    }

    pub fn asAudioSink(self: *NullSink) AudioSink {
        return AudioSink{
            .ptr = self,
            .vtable = &.{
                .writeSamples = writeSamplesImpl,
                .flush = flushAudioImpl,
                .deinit = deinitAudioImpl,
            },
        };
    }

    pub fn getFrameCount(self: *const NullSink) u64 {
        return self.frame_count;
    }

    pub fn getSampleCount(self: *const NullSink) u64 {
        return self.sample_count;
    }

    fn writeFrameImpl(ptr: *anyopaque, video_frame: frame.VideoFrame) !void {
        const self: *NullSink = @ptrCast(@alignCast(ptr));
        _ = video_frame;
        self.frame_count += 1;
    }

    fn writeSamplesImpl(ptr: *anyopaque, audio_frame: frame.AudioFrame) !void {
        const self: *NullSink = @ptrCast(@alignCast(ptr));
        _ = audio_frame;
        self.sample_count += 1;
    }

    fn flushImpl(ptr: *anyopaque) !void {
        _ = ptr;
    }

    fn flushAudioImpl(ptr: *anyopaque) !void {
        _ = ptr;
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *NullSink = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn deinitAudioImpl(ptr: *anyopaque) void {
        const self: *NullSink = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

/// File sink (write to file)
pub const FileSink = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    bytes_written: u64,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !FileSink {
        const file = try std.fs.cwd().createFile(path, .{});
        return .{
            .allocator = allocator,
            .file = file,
            .bytes_written = 0,
        };
    }

    pub fn deinit(self: *FileSink) void {
        self.file.close();
    }

    pub fn write(self: *FileSink, data: []const u8) !void {
        try self.file.writeAll(data);
        self.bytes_written += data.len;
    }

    pub fn getBytesWritten(self: *const FileSink) u64 {
        return self.bytes_written;
    }
};

/// Memory buffer sink (write to growable buffer)
pub const BufferSink = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) BufferSink {
        return .{
            .allocator = allocator,
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *BufferSink) void {
        self.buffer.deinit();
    }

    pub fn write(self: *BufferSink, data: []const u8) !void {
        try self.buffer.appendSlice(data);
    }

    pub fn getBuffer(self: *const BufferSink) []const u8 {
        return self.buffer.items;
    }

    pub fn getSize(self: *const BufferSink) usize {
        return self.buffer.items.len;
    }

    pub fn clear(self: *BufferSink) void {
        self.buffer.clearRetainingCapacity();
    }
};
