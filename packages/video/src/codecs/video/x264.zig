// Home Video Library - x264 FFI Integration
// Production H.264 encoding via libx264
// https://www.videolan.org/developers/x264.html

const std = @import("std");
const core = @import("../../core/frame.zig");
const types = @import("../../core/types.zig");

pub const VideoFrame = core.VideoFrame;

// ============================================================================
// x264 C FFI Bindings
// ============================================================================

// Opaque types
pub const x264_t = opaque {};
pub const x264_param_t = extern struct {
    // CPU flags
    cpu: c_uint,
    i_threads: c_int,
    i_lookahead_threads: c_int,
    b_sliced_threads: c_int,
    b_deterministic: c_int,
    b_cpu_independent: c_int,
    i_sync_lookahead: c_int,

    // Video properties
    i_width: c_int,
    i_height: c_int,
    i_csp: c_int, // Color space
    i_level_idc: c_int,
    i_frame_total: c_int,

    // VUI parameters
    vui: extern struct {
        i_sar_width: c_int,
        i_sar_height: c_int,
        i_overscan: c_int,
        i_vidformat: c_int,
        b_fullrange: c_int,
        i_colorprim: c_int,
        i_transfer: c_int,
        i_colmatrix: c_int,
        i_chroma_loc: c_int,
    },

    // Bitstream parameters
    i_frame_reference: c_int, // Max number of reference frames
    i_dpb_size: c_int,
    i_keyint_max: c_int, // Max GOP size
    i_keyint_min: c_int, // Min GOP size
    i_scenecut_threshold: c_int,
    b_intra_refresh: c_int,

    // Bframes
    i_bframe: c_int,
    i_bframe_adaptive: c_int,
    i_bframe_bias: c_int,
    i_bframe_pyramid: c_int,
    b_open_gop: c_int,
    b_bluray_compat: c_int,
    i_avcintra_class: c_int,
    i_avcintra_flavor: c_int,

    b_deblocking_filter: c_int,
    i_deblocking_filter_alphac0: c_int,
    i_deblocking_filter_beta: c_int,

    b_cabac: c_int,
    i_cabac_init_idc: c_int,

    b_interlaced: c_int,
    b_constrained_intra: c_int,

    i_cqm_preset: c_int,
    psz_cqm_file: ?[*:0]const u8,
    cqm_4iy: [16]u8,
    cqm_4py: [16]u8,
    cqm_4ic: [16]u8,
    cqm_4pc: [16]u8,
    cqm_8iy: [64]u8,
    cqm_8py: [64]u8,
    cqm_8ic: [64]u8,
    cqm_8pc: [64]u8,

    // Log
    pf_log: ?*const fn (
        ?*anyopaque,
        c_int,
        [*:0]const u8,
        [*c]std.builtin.VaList,
    ) callconv(.C) void,
    p_log_private: ?*anyopaque,
    i_log_level: c_int,

    // Analysis
    analyse: extern struct {
        intra: c_uint,
        inter: c_uint,
        b_transform_8x8: c_int,
        i_weighted_pred: c_int,
        b_weighted_bipred: c_int,
        i_direct_mv_pred: c_int,
        i_chroma_qp_offset: c_int,

        i_me_method: c_int,
        i_me_range: c_int,
        i_mv_range: c_int,
        i_mv_range_thread: c_int,
        i_subpel_refine: c_int,
        b_chroma_me: c_int,
        b_mixed_references: c_int,
        i_trellis: c_int,
        b_fast_pskip: c_int,
        b_dct_decimate: c_int,
        i_noise_reduction: c_int,
        f_psy_rd: f32,
        f_psy_trellis: f32,
        b_psy: c_int,
        b_mb_info: c_int,
        b_mb_info_update: c_int,

        i_luma_deadzone: [2]c_int,

        b_psnr: c_int,
        b_ssim: c_int,
    },

    // Rate control
    rc: extern struct {
        i_rc_method: c_int,
        i_qp_constant: c_int,
        i_qp_min: c_int,
        i_qp_max: c_int,
        i_qp_step: c_int,

        i_bitrate: c_int,
        f_rf_constant: f32,
        f_rf_constant_max: f32,
        f_rate_tolerance: f32,
        i_vbv_max_bitrate: c_int,
        i_vbv_buffer_size: c_int,
        f_vbv_buffer_init: f32,
        f_ip_factor: f32,
        f_pb_factor: f32,

        i_aq_mode: c_int,
        f_aq_strength: f32,
        b_mb_tree: c_int,
        i_lookahead: c_int,

        b_stat_write: c_int,
        psz_stat_out: ?[*:0]const u8,
        b_stat_read: c_int,
        psz_stat_in: ?[*:0]const u8,

        f_qcompress: f32,
        f_qblur: f32,
        f_complexity_blur: f32,
        zones: ?*anyopaque,
        i_zones: c_int,
        zone_free: ?*const fn (?*anyopaque) callconv(.C) void,

        b_mb_tree_readwrite: c_int,
        psz_zones: ?[*:0]const u8,
    },

    // Cropping
    crop_rect: extern struct {
        i_left: c_int,
        i_top: c_int,
        i_right: c_int,
        i_bottom: c_int,
    },

    // Frame packing
    i_frame_packing: c_int,

    // Alternative transfer characteristics
    i_alternative_transfer: c_int,

    b_aud: c_int,
    b_repeat_headers: c_int,
    b_annexb: c_int,
    i_sps_id: c_int,
    b_vfr_input: c_int,
    b_pulldown: c_int,
    i_fps_num: c_uint,
    i_fps_den: c_uint,
    i_timebase_num: c_uint,
    i_timebase_den: c_uint,

    b_tff: c_int,

    b_pic_struct: c_int,

    b_fake_interlaced: c_int,

    b_stitchable: c_int,
    b_opencl: c_int,
    i_opencl_device: c_int,
    opencl_device_id: ?*anyopaque,
    psz_clbin_file: ?[*:0]const u8,

    i_slice_max_size: c_int,
    i_slice_max_mbs: c_int,
    i_slice_min_mbs: c_int,
    i_slice_count: c_int,
    i_slice_count_max: c_int,

    param_free: ?*const fn (?*anyopaque) callconv(.C) void,

    nalu_process: ?*const fn (
        ?*x264_t,
        ?*x264_nal_t,
        ?*anyopaque,
    ) callconv(.C) c_int,
    opaque: ?*anyopaque,
};

pub const x264_picture_t = extern struct {
    i_type: c_int,
    i_qpplus1: c_int,
    i_pic_struct: c_int,
    b_keyframe: c_int,
    i_pts: i64,
    i_dts: i64,

    param: ?*anyopaque,
    img: extern struct {
        i_csp: c_int,
        i_plane: c_int,
        i_stride: [4]c_int,
        plane: [4]?[*]u8,
    },

    prop: extern struct {
        quant_offsets: ?[*]f32,
        quant_offsets_free: ?*const fn (?*anyopaque) callconv(.C) void,

        mb_info: ?*anyopaque,
        mb_info_free: ?*const fn (?*anyopaque) callconv(.C) void,

        sei_rpu: ?*anyopaque,
        sei_rpu_size: c_int,
        sei_rpu_free: ?*const fn (?*anyopaque) callconv(.C) void,
    },

    hrd_timing: extern struct {
        cpb_initial_arrival_time: i64,
        cpb_final_arrival_time: i64,
        cpb_removal_time: i64,
        dpb_output_time: i64,
    },

    extra_sei: extern struct {
        payloads: ?*anyopaque,
        num_payloads: c_int,
        sei_free: ?*const fn (?*anyopaque) callconv(.C) void,
    },

    opaque: ?*anyopaque,
};

pub const x264_nal_t = extern struct {
    i_ref_idc: c_int,
    i_type: c_int,
    b_long_startcode: c_int,
    i_first_mb: c_int,
    i_last_mb: c_int,

    i_payload: c_int,
    p_payload: ?[*]u8,
};

pub const x264_image_t = extern struct {
    i_csp: c_int,
    i_plane: c_int,
    i_stride: [4]c_int,
    plane: [4]?[*]u8,
};

// Rate control methods
pub const X264_RC_CQP: c_int = 0;
pub const X264_RC_CRF: c_int = 1;
pub const X264_RC_ABR: c_int = 2;

// Log levels
pub const X264_LOG_ERROR: c_int = 0;
pub const X264_LOG_WARNING: c_int = 1;
pub const X264_LOG_INFO: c_int = 2;
pub const X264_LOG_DEBUG: c_int = 3;

// Color spaces
pub const X264_CSP_I420: c_int = 0x0001;
pub const X264_CSP_YV12: c_int = 0x0002;
pub const X264_CSP_NV12: c_int = 0x0003;
pub const X264_CSP_NV21: c_int = 0x0004;
pub const X264_CSP_I422: c_int = 0x0005;
pub const X264_CSP_YV16: c_int = 0x0006;
pub const X264_CSP_NV16: c_int = 0x0007;
pub const X264_CSP_YUYV: c_int = 0x0008;
pub const X264_CSP_UYVY: c_int = 0x0009;
pub const X264_CSP_V210: c_int = 0x000a;
pub const X264_CSP_I444: c_int = 0x000b;
pub const X264_CSP_YV24: c_int = 0x000c;
pub const X264_CSP_BGR: c_int = 0x000d;
pub const X264_CSP_BGRA: c_int = 0x000e;
pub const X264_CSP_RGB: c_int = 0x000f;

// Picture types
pub const X264_TYPE_AUTO: c_int = 0x0000;
pub const X264_TYPE_IDR: c_int = 0x0001;
pub const X264_TYPE_I: c_int = 0x0002;
pub const X264_TYPE_P: c_int = 0x0003;
pub const X264_TYPE_BREF: c_int = 0x0004;
pub const X264_TYPE_B: c_int = 0x0005;
pub const X264_TYPE_KEYFRAME: c_int = 0x0006;

// NAL unit types
pub const NAL_UNKNOWN: c_int = 0;
pub const NAL_SLICE: c_int = 1;
pub const NAL_SLICE_DPA: c_int = 2;
pub const NAL_SLICE_DPB: c_int = 3;
pub const NAL_SLICE_DPC: c_int = 4;
pub const NAL_SLICE_IDR: c_int = 5;
pub const NAL_SEI: c_int = 6;
pub const NAL_SPS: c_int = 7;
pub const NAL_PPS: c_int = 8;
pub const NAL_AUD: c_int = 9;
pub const NAL_FILLER: c_int = 12;

// x264 API functions
extern "c" fn x264_param_default(param: *x264_param_t) void;
extern "c" fn x264_param_default_preset(
    param: *x264_param_t,
    preset: [*:0]const u8,
    tune: [*:0]const u8,
) c_int;
extern "c" fn x264_param_apply_profile(
    param: *x264_param_t,
    profile: [*:0]const u8,
) c_int;
extern "c" fn x264_encoder_open(param: *x264_param_t) ?*x264_t;
extern "c" fn x264_encoder_reconfig(enc: *x264_t, param: *x264_param_t) c_int;
extern "c" fn x264_encoder_headers(
    enc: *x264_t,
    pp_nal: *?[*]x264_nal_t,
    pi_nal: *c_int,
) c_int;
extern "c" fn x264_encoder_encode(
    enc: *x264_t,
    pp_nal: *?[*]x264_nal_t,
    pi_nal: *c_int,
    pic_in: ?*x264_picture_t,
    pic_out: *x264_picture_t,
) c_int;
extern "c" fn x264_encoder_close(enc: *x264_t) void;
extern "c" fn x264_encoder_delayed_frames(enc: *x264_t) c_int;
extern "c" fn x264_encoder_maximum_delayed_frames(enc: *x264_t) c_int;
extern "c" fn x264_encoder_intra_refresh(enc: *x264_t) void;
extern "c" fn x264_encoder_invalidate_reference(enc: *x264_t, pts: i64) c_int;

extern "c" fn x264_picture_init(pic: *x264_picture_t) void;
extern "c" fn x264_picture_alloc(
    pic: *x264_picture_t,
    i_csp: c_int,
    i_width: c_int,
    i_height: c_int,
) c_int;
extern "c" fn x264_picture_clean(pic: *x264_picture_t) void;

// ============================================================================
// Zig Wrapper
// ============================================================================

/// x264 Encoder Configuration
pub const X264Config = struct {
    width: u32,
    height: u32,
    frame_rate: types.Rational,

    // Preset: ultrafast, superfast, veryfast, faster, fast, medium, slow, slower, veryslow, placebo
    preset: []const u8 = "medium",
    // Tune: film, animation, grain, stillimage, psnr, ssim, fastdecode, zerolatency
    tune: []const u8 = "",
    // Profile: baseline, main, high, high10, high422, high444
    profile: []const u8 = "main",

    // Rate control
    rc_method: RateControlMethod = .crf,
    bitrate: u32 = 2000, // kbps (for ABR)
    crf: u8 = 23, // 0-51, lower = better quality
    qp: u8 = 23, // for CQP

    // GOP structure
    keyframe_interval: u32 = 250,
    min_keyframe_interval: u32 = 25,
    b_frames: u8 = 3,
    ref_frames: u8 = 3,

    // Quality
    me_range: u16 = 16, // Motion estimation search range
    subpel_refine: u8 = 7, // 1-11, higher = slower but better

    // Threading
    threads: u8 = 0, // 0 = auto

    // Logging
    log_level: LogLevel = .warning,
};

pub const RateControlMethod = enum {
    cqp, // Constant QP
    crf, // Constant rate factor
    abr, // Average bitrate
};

pub const LogLevel = enum(c_int) {
    none = -1,
    err = X264_LOG_ERROR,
    warning = X264_LOG_WARNING,
    info = X264_LOG_INFO,
    debug = X264_LOG_DEBUG,
};

/// Encoded packet from x264
pub const EncodedPacket = struct {
    data: []const u8,
    pts: types.Timestamp,
    dts: types.Timestamp,
    is_keyframe: bool,
    nal_type: c_int,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *EncodedPacket) void {
        self.allocator.free(self.data);
    }
};

/// x264 Encoder
pub const X264Encoder = struct {
    encoder: *x264_t,
    config: X264Config,
    allocator: std.mem.Allocator,
    frame_count: u64 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: X264Config) !Self {
        // Allocate param struct
        var param: x264_param_t = undefined;

        // Set defaults with preset and tune
        const preset_z = try allocator.dupeZ(u8, config.preset);
        defer allocator.free(preset_z);
        const tune_z = if (config.tune.len > 0)
            try allocator.dupeZ(u8, config.tune)
        else
            try allocator.dupeZ(u8, "");
        defer allocator.free(tune_z);

        const ret = x264_param_default_preset(&param, preset_z.ptr, tune_z.ptr);
        if (ret < 0) {
            return error.InvalidPreset;
        }

        // Set video properties
        param.i_width = @intCast(config.width);
        param.i_height = @intCast(config.height);
        param.i_fps_num = @intCast(config.frame_rate.num);
        param.i_fps_den = @intCast(config.frame_rate.denom);
        param.i_timebase_num = @intCast(config.frame_rate.denom);
        param.i_timebase_den = @intCast(config.frame_rate.num);

        // Set color space to I420 (YUV 4:2:0 planar)
        param.i_csp = X264_CSP_I420;

        // GOP structure
        param.i_keyint_max = @intCast(config.keyframe_interval);
        param.i_keyint_min = @intCast(config.min_keyframe_interval);
        param.i_bframe = @intCast(config.b_frames);
        param.i_frame_reference = @intCast(config.ref_frames);

        // Rate control
        param.rc.i_rc_method = switch (config.rc_method) {
            .cqp => X264_RC_CQP,
            .crf => X264_RC_CRF,
            .abr => X264_RC_ABR,
        };

        switch (config.rc_method) {
            .cqp => {
                param.rc.i_qp_constant = @intCast(config.qp);
            },
            .crf => {
                param.rc.f_rf_constant = @floatFromInt(config.crf);
            },
            .abr => {
                param.rc.i_bitrate = @intCast(config.bitrate);
            },
        }

        // Analysis
        param.analyse.i_me_range = @intCast(config.me_range);
        param.analyse.i_subpel_refine = @intCast(config.subpel_refine);

        // Threading
        param.i_threads = @intCast(config.threads);

        // Logging
        param.i_log_level = @intFromEnum(config.log_level);

        // Repeat headers for every keyframe (important for streaming)
        param.b_repeat_headers = 1;
        param.b_annexb = 1; // Annex B format (start codes)

        // Apply profile
        const profile_z = try allocator.dupeZ(u8, config.profile);
        defer allocator.free(profile_z);

        const profile_ret = x264_param_apply_profile(&param, profile_z.ptr);
        if (profile_ret < 0) {
            return error.InvalidProfile;
        }

        // Open encoder
        const encoder = x264_encoder_open(&param) orelse {
            return error.EncoderOpenFailed;
        };

        return .{
            .encoder = encoder,
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        x264_encoder_close(self.encoder);
    }

    /// Get encoder headers (SPS, PPS, etc.)
    pub fn getHeaders(self: *Self) ![]u8 {
        var pp_nal: ?[*]x264_nal_t = null;
        var pi_nal: c_int = 0;

        const ret = x264_encoder_headers(self.encoder, &pp_nal, &pi_nal);
        if (ret < 0) {
            return error.GetHeadersFailed;
        }

        // Concatenate all NAL units
        var total_size: usize = 0;
        const nals = pp_nal.?[0..@intCast(pi_nal)];
        for (nals) |nal| {
            total_size += @intCast(nal.i_payload);
        }

        const headers = try self.allocator.alloc(u8, total_size);
        var offset: usize = 0;
        for (nals) |nal| {
            const payload_size: usize = @intCast(nal.i_payload);
            @memcpy(headers[offset .. offset + payload_size], nal.p_payload.?[0..payload_size]);
            offset += payload_size;
        }

        return headers;
    }

    /// Encode a single frame
    pub fn encode(self: *Self, frame: *const VideoFrame) !?EncodedPacket {
        // Prepare input picture
        var pic_in: x264_picture_t = undefined;
        x264_picture_init(&pic_in);

        // Set picture type (let x264 decide)
        pic_in.i_type = X264_TYPE_AUTO;

        // Set PTS
        pic_in.i_pts = frame.pts.toMicroseconds();

        // Set image data
        pic_in.img.i_csp = X264_CSP_I420;
        pic_in.img.i_plane = 3;

        // YUV 4:2:0 planar
        pic_in.img.plane[0] = frame.data[0].ptr;
        pic_in.img.plane[1] = frame.data[1].ptr;
        pic_in.img.plane[2] = frame.data[2].ptr;
        pic_in.img.plane[3] = null;

        pic_in.img.i_stride[0] = @intCast(frame.stride[0]);
        pic_in.img.i_stride[1] = @intCast(frame.stride[1]);
        pic_in.img.i_stride[2] = @intCast(frame.stride[2]);
        pic_in.img.i_stride[3] = 0;

        // Encode
        var pic_out: x264_picture_t = undefined;
        var pp_nal: ?[*]x264_nal_t = null;
        var pi_nal: c_int = 0;

        const ret = x264_encoder_encode(
            self.encoder,
            &pp_nal,
            &pi_nal,
            &pic_in,
            &pic_out,
        );

        if (ret < 0) {
            return error.EncodeFailed;
        }

        // No output yet (encoder buffering)
        if (ret == 0) {
            return null;
        }

        // Concatenate all NAL units
        var total_size: usize = 0;
        const nals = pp_nal.?[0..@intCast(pi_nal)];
        for (nals) |nal| {
            total_size += @intCast(nal.i_payload);
        }

        const data = try self.allocator.alloc(u8, total_size);
        errdefer self.allocator.free(data);

        var offset: usize = 0;
        var is_keyframe = false;
        var nal_type: c_int = 0;

        for (nals) |nal| {
            const payload_size: usize = @intCast(nal.i_payload);
            @memcpy(data[offset .. offset + payload_size], nal.p_payload.?[0..payload_size]);
            offset += payload_size;

            // Check if this is a keyframe
            if (nal.i_type == NAL_SLICE_IDR) {
                is_keyframe = true;
            }

            // Use first slice NAL type
            if (nal_type == 0 and (nal.i_type == NAL_SLICE or nal.i_type == NAL_SLICE_IDR)) {
                nal_type = nal.i_type;
            }
        }

        self.frame_count += 1;

        return EncodedPacket{
            .data = data,
            .pts = types.Timestamp.fromMicroseconds(pic_out.i_pts),
            .dts = types.Timestamp.fromMicroseconds(pic_out.i_dts),
            .is_keyframe = is_keyframe,
            .nal_type = nal_type,
            .allocator = self.allocator,
        };
    }

    /// Flush delayed frames
    pub fn flush(self: *Self) !?EncodedPacket {
        var pic_out: x264_picture_t = undefined;
        var pp_nal: ?[*]x264_nal_t = null;
        var pi_nal: c_int = 0;

        const ret = x264_encoder_encode(
            self.encoder,
            &pp_nal,
            &pi_nal,
            null, // NULL to flush
            &pic_out,
        );

        if (ret < 0) {
            return error.FlushFailed;
        }

        if (ret == 0) {
            return null; // No more frames
        }

        // Concatenate all NAL units
        var total_size: usize = 0;
        const nals = pp_nal.?[0..@intCast(pi_nal)];
        for (nals) |nal| {
            total_size += @intCast(nal.i_payload);
        }

        const data = try self.allocator.alloc(u8, total_size);
        errdefer self.allocator.free(data);

        var offset: usize = 0;
        var is_keyframe = false;
        var nal_type: c_int = 0;

        for (nals) |nal| {
            const payload_size: usize = @intCast(nal.i_payload);
            @memcpy(data[offset .. offset + payload_size], nal.p_payload.?[0..payload_size]);
            offset += payload_size;

            if (nal.i_type == NAL_SLICE_IDR) {
                is_keyframe = true;
            }

            if (nal_type == 0 and (nal.i_type == NAL_SLICE or nal.i_type == NAL_SLICE_IDR)) {
                nal_type = nal.i_type;
            }
        }

        return EncodedPacket{
            .data = data,
            .pts = types.Timestamp.fromMicroseconds(pic_out.i_pts),
            .dts = types.Timestamp.fromMicroseconds(pic_out.i_dts),
            .is_keyframe = is_keyframe,
            .nal_type = nal_type,
            .allocator = self.allocator,
        };
    }

    /// Get number of delayed frames still in encoder
    pub fn delayedFrames(self: *Self) u32 {
        return @intCast(x264_encoder_delayed_frames(self.encoder));
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Convert Home VideoFrame to x264 picture format
pub fn convertFrameToX264(
    allocator: std.mem.Allocator,
    frame: *const VideoFrame,
    pic: *x264_picture_t,
) !void {
    // Initialize picture
    x264_picture_init(pic);

    // Allocate x264 internal picture buffer
    const ret = x264_picture_alloc(
        pic,
        X264_CSP_I420,
        @intCast(frame.width),
        @intCast(frame.height),
    );

    if (ret < 0) {
        return error.PictureAllocFailed;
    }

    // Copy frame data to x264 picture
    // Y plane
    const y_height = frame.height;
    for (0..y_height) |y| {
        const src_offset = y * frame.stride[0];
        const dst_offset = y * @as(usize, @intCast(pic.img.i_stride[0]));
        @memcpy(
            pic.img.plane[0].?[dst_offset .. dst_offset + frame.width],
            frame.data[0][src_offset .. src_offset + frame.width],
        );
    }

    // U and V planes (half resolution for 4:2:0)
    const uv_width = frame.width / 2;
    const uv_height = frame.height / 2;

    for (0..uv_height) |y| {
        // U plane
        const u_src_offset = y * frame.stride[1];
        const u_dst_offset = y * @as(usize, @intCast(pic.img.i_stride[1]));
        @memcpy(
            pic.img.plane[1].?[u_dst_offset .. u_dst_offset + uv_width],
            frame.data[1][u_src_offset .. u_src_offset + uv_width],
        );

        // V plane
        const v_src_offset = y * frame.stride[2];
        const v_dst_offset = y * @as(usize, @intCast(pic.img.i_stride[2]));
        @memcpy(
            pic.img.plane[2].?[v_dst_offset .. v_dst_offset + uv_width],
            frame.data[2][v_src_offset .. v_src_offset + uv_width],
        );
    }

    pic.i_pts = frame.pts.toMicroseconds();

    _ = allocator;
}

/// Clean up x264 picture
pub fn cleanupX264Picture(pic: *x264_picture_t) void {
    x264_picture_clean(pic);
}
