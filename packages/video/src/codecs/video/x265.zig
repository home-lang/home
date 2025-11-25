// Home Video Library - x265 FFI Integration
// Production H.265/HEVC encoding via libx265
// https://x265.readthedocs.io/

const std = @import("std");
const core = @import("../../core/frame.zig");
const types = @import("../../core/types.zig");

pub const VideoFrame = core.VideoFrame;

// ============================================================================
// x265 C FFI Bindings
// ============================================================================

// Opaque type
pub const x265_encoder = opaque {};

pub const x265_param = extern struct {
    // frameRate: numerator
    fpsNum: u32,
    // frameRate: denominator
    fpsDenom: u32,

    // source width in pixels
    sourceWidth: c_int,
    // source height in pixels
    sourceHeight: c_int,

    // Interlace mode
    interlaceMode: c_int,

    // total of bipred search points
    totalFrames: c_int,

    // Level Limits
    levelIdc: c_int,

    // Enable/Disable High Tier
    bHighTier: c_int,

    // max CU size
    maxCUSize: u32,
    // min CU size
    minCUSize: u32,

    // CTU size
    ctuSize: u32,

    // max TU size
    tuQTMaxInterDepth: u32,
    tuQTMaxIntraDepth: u32,

    // Max Transform Depth
    maxTUSize: u32,

    // Quad split enable/disable
    bEnableRectInter: c_int,

    // AMP enable/disable
    bEnableAMP: c_int,

    // max P/B slices per full frame
    maxNumReferences: c_int,

    // max number of merge candidates
    maxNumMergeCand: u32,

    // Enable early skip detection
    bEnableEarlySkip: c_int,

    // Enable B frames
    bframes: c_int,
    // Number of B frames
    bBPyramid: c_int,
    // Use B frames as references
    bOpenGOP: c_int,

    // radl frames for cra
    radl: c_int,

    // Enable weighted prediction in P slices
    bEnableWeightedPred: c_int,
    // Enable weighted prediction in B slices
    bEnableWeightedBiPred: c_int,

    // reference picture set: 0=off, 1=on
    bEnableRdo: c_int,

    // Enable RDOQ
    bEnableRDOQ: c_int,

    // Enable RDOQ Level
    rdoqLevel: c_int,

    // Enable RDOQ TS
    bEnableRDOQTS: c_int,

    // Enable sign hiding
    bEnableSignHiding: c_int,

    // Enable TSkip
    bEnableTransformSkip: c_int,

    // Enable TSkip Fast
    bEnableTSkipFast: c_int,

    // Enable strong intra smoothing
    bEnableStrongIntraSmoothing: c_int,

    // Enable constrained intra pred
    bEnableConstrainedIntra: c_int,

    // Loop filter across slices
    bLFCrossSliceBoundary: c_int,

    // deblocking filter control
    bEnableLoopFilter: c_int,
    deblockingFilterTCOffset: c_int,
    deblockingFilterBetaOffset: c_int,

    // sample adaptive offset
    bEnableSAO: c_int,
    bSaoNonDeblocked: c_int,

    // slice mode
    bEnableSlices: c_int,

    // slice mode parameters
    maxSliceSegments: c_int,

    // dependent slices
    bEnableSliceSegments: c_int,

    // use access unit delimiters
    bEnableAccessUnitDelimiters: c_int,

    // QP
    rc: extern struct {
        // rate control mode: CQP, CRF, ABR
        rateControlMode: c_int,

        // target QP for CQP mode
        qp: c_int,

        // rate factor for CRF mode
        rfConstant: f64,

        // target bitrate for ABR mode in kbps
        bitrate: c_int,

        // 1 = default, 2 = more aggressive
        qgSize: c_int,

        // max bitrate for VBV in kbps
        vbvMaxBitrate: c_int,
        // VBV buffer size in kbits
        vbvBufferSize: c_int,
        // VBV buffer initial occupancy
        vbvBufferInit: f64,

        // crf-max for ABR mode
        rfConstantMax: f64,
        // crf-min for ABR mode
        rfConstantMin: f64,

        // qpmin
        qpMin: c_int,
        // qpmax
        qpMax: c_int,
        // qpstep
        qpStep: c_int,

        // aq-mode
        aqMode: c_int,
        // aq-strength
        aqStrength: f64,

        // strict VBV
        bStrictCbr: c_int,

        // enable/disable slow first pass
        bEnableSlowFirstPass: c_int,

        // 2pass stats filename
        statFileName: [*:0]const u8,
        // 2pass stats write
        bStatWrite: c_int,
        // 2pass stats read
        bStatRead: c_int,

        // QP factor between I and P
        ipFactor: f64,
        // QP factor between P and B
        pbFactor: f64,

        // cutree for 2pass
        bEnableCutree: c_int,

        // lookahead
        lookaheadDepth: c_int,

        // Enable grain optimized ratecontrol
        bEnableGrain: c_int,

        // scenecut sensitivity
        scenecutThreshold: c_int,

        // histbased scenecut
        bHistBasedSceneCut: c_int,

        // number of scenecut windows
        scenecutWindow: c_int,

        // max AU size in bits
        maxAUSizeFactor: f64,

        // min VBV fullness
        minVbvFullness: f64,
        // max VBV fullness
        maxVbvFullness: f64,

        // Pass-through zone info
        zonefileCount: c_int,
        zonefileName: [*:0]const u8,

        // qpfile name
        qpfile: [*:0]const u8,

        // force QP
        bEnableConstVbv: c_int,

        // Adaptive Quantization offsets
        chromaQpOffset: c_int,
        cbQpOffset: c_int,
        crQpOffset: c_int,

        // frame-aq
        bEnableFrameDuplication: c_int,

        // fades
        bEnableFades: c_int,

        // hevc-aq
        hevcAq: c_int,

        // qp-adaptation-range
        qpAdaptationRange: f64,
    },

    // vui parameters
    vui: extern struct {
        // aspect ratio
        aspectRatioIdc: c_int,
        sarWidth: c_int,
        sarHeight: c_int,

        // overscan info
        bEnableOverscanInfoPresent: c_int,
        bEnableOverscanAppropriate: c_int,

        // video signal type
        bEnableVideoSignalTypePresentFlag: c_int,
        videoFormat: c_int,
        bEnableVideoFullRangeFlag: c_int,
        bEnableColorDescriptionPresentFlag: c_int,
        colorPrimaries: c_int,
        transferCharacteristics: c_int,
        matrixCoeffs: c_int,

        // chroma location
        bEnableChromaLocInfoPresent: c_int,
        chromaSampleLocTypeTopField: c_int,
        chromaSampleLocTypeBottomField: c_int,

        // neutral chroma indication
        bEnableNeutralChromaIndicationFlag: c_int,

        // field coding
        bEnableFieldSeqFlag: c_int,

        // timing info
        bEnableTimingInfo: c_int,
        numUnitsInTick: u32,
        timeScale: u32,

        // buffering period
        bEnableHrdTimingInfo: c_int,

        // bitstream restriction
        bEnableBitstreamRestriction: c_int,
        bEnableTilesFixedStructure: c_int,
        bEnableMotionVectorsOverPicBoundaries: c_int,
        bEnableRestrictedRefPicLists: c_int,
        minSpatialSegmentationIdc: c_int,
        maxBytesPerPicDenom: c_int,
        maxBitsPerMinCuDenom: c_int,
        log2MaxMvLengthHorizontal: c_int,
        log2MaxMvLengthVertical: c_int,
    },

    // coding tools
    bEnableWavefront: c_int,

    // motion search
    searchMethod: c_int,
    // search range
    searchRange: c_int,
    // subpel refinement
    subpelRefine: c_int,

    // RDLevel
    rdLevel: c_int,

    // psy-rd
    bEnablePsyRd: c_int,
    psyRd: f64,
    psyRdoq: f64,

    // analysis
    bEnableCbfFastMode: c_int,
    bEnableEarlySkip: c_int,

    // limit modes evaluated
    limitModes: c_int,

    // cu-lossless
    bCULossless: c_int,

    // fast intra
    bEnableFastIntra: c_int,

    // input CSP
    internalCsp: c_int,

    // internal bit depth
    internalBitDepth: c_int,

    // log level
    logLevel: c_int,

    // csv log filename
    csvfn: [*:0]const u8,

    // csv log level
    csvLogLevel: c_int,

    // number of parallel frame encoders
    frameNumThreads: c_int,

    // number of parallel wavefront threads
    numaPools: [*:0]const u8,

    // wpp threads
    wppThreads: c_int,

    // job queue
    lookaheadThreads: c_int,

    // Target usage: fast, medium, slow
    bEnableSplitRdSkip: c_int,
    rdPenalty: c_int,
    bEnableRdRefine: c_int,

    // analysis save/load
    analysisReuseMode: c_int,
    analysisReuseFileName: [*:0]const u8,

    // enable multipass refinement
    bEnableMultiPassRefinement: c_int,

    // limit number of SAO types per frame
    bLimitSAO: c_int,

    // scalingList
    scalingLists: [*:0]const u8,

    // maxCLL
    maxCLL: u16,
    // maxFALL
    maxFALL: u16,

    // min luma coding block size
    minLumaCodingBlockSize: c_int,

    // HRD model
    bEmitHRDSEI: c_int,
    bEmitInfoSEI: c_int,
    bEmitHDRSEI: c_int,
    bEmitIDRRecoverySEI: c_int,

    // hash SEI
    bEnableDecodedPictureHashSEI: c_int,
    decodedPictureHashSEI: c_int,

    // Film grain
    filmGrain: [*:0]const u8,

    // Master display
    masterDisplay: [*:0]const u8,

    // MaxCLL/MaxFALL
    maxLuma: [*:0]const u8,

    // HLG
    bEmitCLL: c_int,

    // VUI HRD info
    bEmitVUIHRDInfo: c_int,

    // VUI timing info
    bEmitVUITimingInfo: c_int,

    // Dolby Vision
    dolbyProfile: c_int,

    // Reserved for future use
    reserved: [128]u8,
};

pub const x265_picture = extern struct {
    // presentation time stamp in timebase units
    pts: i64,
    // decoding time stamp in timebase units
    dts: i64,

    // user data
    userData: ?*anyopaque,

    // planes: 0=Y, 1=Cb, 2=Cr
    planes: [3]?[*]u8,
    // stride for each plane
    stride: [3]c_int,

    // input bit depth
    bitDepth: c_int,

    // picture type
    sliceType: c_int,

    // quantizer for this frame
    quantOffsets: ?*f32,

    // force picture type
    forceqp: c_int,

    // color space
    colorSpace: c_int,

    // field number for field coding
    fieldNum: c_int,

    // picture structure
    picStruct: c_int,

    // width of picture
    width: c_int,
    // height of picture
    height: c_int,

    // frame reordering
    frameNum: c_int,

    // poc
    poc: c_int,

    // RPL modification
    bRPLModification: c_int,

    // window parameters
    windowLeftOffset: c_int,
    windowRightOffset: c_int,
    windowTopOffset: c_int,
    windowBottomOffset: c_int,

    // scene change
    bSceneChange: c_int,

    // referenced
    bKeyframe: c_int,

    // Dolby Vision RPU data
    rpu: extern struct {
        payload: ?[*]u8,
        payloadSize: c_int,
    },

    // Reserved
    reserved: [64]u8,
};

pub const x265_nal = extern struct {
    // payload type
    @"type": u32,

    // payload size in bytes
    sizeBytes: u32,

    // payload data
    payload: ?[*]u8,
};

pub const x265_picture_init = extern struct {
    // Reserved for internal use
    reserved: [128]u8,
};

// Picture types
pub const X265_TYPE_AUTO: c_int = 0;
pub const X265_TYPE_IDR: c_int = 1;
pub const X265_TYPE_I: c_int = 2;
pub const X265_TYPE_P: c_int = 3;
pub const X265_TYPE_BREF: c_int = 4;
pub const X265_TYPE_B: c_int = 5;

// Rate control modes
pub const X265_RC_CQP: c_int = 0;
pub const X265_RC_CRF: c_int = 1;
pub const X265_RC_ABR: c_int = 2;

// Log levels
pub const X265_LOG_NONE: c_int = -1;
pub const X265_LOG_ERROR: c_int = 0;
pub const X265_LOG_WARNING: c_int = 1;
pub const X265_LOG_INFO: c_int = 2;
pub const X265_LOG_DEBUG: c_int = 3;
pub const X265_LOG_FULL: c_int = 4;

// Color spaces
pub const X265_CSP_I400: c_int = 0; // Monochrome
pub const X265_CSP_I420: c_int = 1; // YUV 4:2:0 planar
pub const X265_CSP_I422: c_int = 2; // YUV 4:2:2 planar
pub const X265_CSP_I444: c_int = 3; // YUV 4:4:4 planar
pub const X265_CSP_NV12: c_int = 4; // YUV 4:2:0 semi-planar (NV12)
pub const X265_CSP_NV16: c_int = 5; // YUV 4:2:2 semi-planar (NV16)

// NAL unit types
pub const NAL_UNIT_CODED_SLICE_TRAIL_N: u32 = 0;
pub const NAL_UNIT_CODED_SLICE_TRAIL_R: u32 = 1;
pub const NAL_UNIT_CODED_SLICE_TSA_N: u32 = 2;
pub const NAL_UNIT_CODED_SLICE_TSA_R: u32 = 3;
pub const NAL_UNIT_CODED_SLICE_STSA_N: u32 = 4;
pub const NAL_UNIT_CODED_SLICE_STSA_R: u32 = 5;
pub const NAL_UNIT_CODED_SLICE_RADL_N: u32 = 6;
pub const NAL_UNIT_CODED_SLICE_RADL_R: u32 = 7;
pub const NAL_UNIT_CODED_SLICE_RASL_N: u32 = 8;
pub const NAL_UNIT_CODED_SLICE_RASL_R: u32 = 9;
pub const NAL_UNIT_CODED_SLICE_BLA_W_LP: u32 = 16;
pub const NAL_UNIT_CODED_SLICE_BLA_W_RADL: u32 = 17;
pub const NAL_UNIT_CODED_SLICE_BLA_N_LP: u32 = 18;
pub const NAL_UNIT_CODED_SLICE_IDR_W_RADL: u32 = 19;
pub const NAL_UNIT_CODED_SLICE_IDR_N_LP: u32 = 20;
pub const NAL_UNIT_CODED_SLICE_CRA: u32 = 21;
pub const NAL_UNIT_VPS: u32 = 32;
pub const NAL_UNIT_SPS: u32 = 33;
pub const NAL_UNIT_PPS: u32 = 34;
pub const NAL_UNIT_ACCESS_UNIT_DELIMITER: u32 = 35;
pub const NAL_UNIT_EOS: u32 = 36;
pub const NAL_UNIT_EOB: u32 = 37;
pub const NAL_UNIT_FILLER_DATA: u32 = 38;
pub const NAL_UNIT_PREFIX_SEI: u32 = 39;
pub const NAL_UNIT_SUFFIX_SEI: u32 = 40;

// x265 API functions
extern "c" fn x265_param_alloc() ?*x265_param;
extern "c" fn x265_param_free(param: *x265_param) void;
extern "c" fn x265_param_default(param: *x265_param) void;
extern "c" fn x265_param_default_preset(
    param: *x265_param,
    preset: [*:0]const u8,
    tune: [*:0]const u8,
) c_int;
extern "c" fn x265_param_apply_profile(
    param: *x265_param,
    profile: [*:0]const u8,
) c_int;
extern "c" fn x265_param_parse(
    param: *x265_param,
    name: [*:0]const u8,
    value: [*:0]const u8,
) c_int;

extern "c" fn x265_encoder_open(param: *x265_param) ?*x265_encoder;
extern "c" fn x265_encoder_close(enc: *x265_encoder) void;
extern "c" fn x265_encoder_reconfig(enc: *x265_encoder, param: *x265_param) c_int;
extern "c" fn x265_encoder_parameters(enc: *x265_encoder, param: *x265_param) c_int;
extern "c" fn x265_encoder_headers(
    enc: *x265_encoder,
    pp_nal: *?[*]x265_nal,
    pi_nal: *u32,
) c_int;
extern "c" fn x265_encoder_encode(
    enc: *x265_encoder,
    pp_nal: *?[*]x265_nal,
    pi_nal: *u32,
    pic_in: ?*x265_picture,
    pic_out: *x265_picture,
) c_int;
extern "c" fn x265_encoder_get_stats(
    enc: *x265_encoder,
    outputBitrate: *f64,
    frameNum: *u32,
) void;

extern "c" fn x265_picture_alloc() ?*x265_picture;
extern "c" fn x265_picture_free(pic: *x265_picture) void;
extern "c" fn x265_picture_init(param: *x265_param, pic: *x265_picture) void;

extern "c" fn x265_cleanup() void;
extern "c" fn x265_version_str() [*:0]const u8;
extern "c" fn x265_build_info_str() [*:0]const u8;

// ============================================================================
// Zig Wrapper
// ============================================================================

/// x265 Encoder Configuration
pub const X265Config = struct {
    width: u32,
    height: u32,
    frame_rate: types.Rational,

    // Preset: ultrafast, superfast, veryfast, faster, fast, medium, slow, slower, veryslow, placebo
    preset: []const u8 = "medium",
    // Tune: psnr, ssim, grain, zerolatency, fastdecode, animation
    tune: []const u8 = "",
    // Profile: main, main10, main12, main422-10, main422-12, main444-8, main444-10, main444-12
    profile: []const u8 = "main",

    // Rate control
    rc_method: RateControlMethod = .crf,
    bitrate: u32 = 2000, // kbps (for ABR)
    crf: u8 = 28, // 0-51, lower = better quality (28 = default)
    qp: u8 = 28, // for CQP

    // GOP structure
    keyframe_interval: u32 = 250,
    b_frames: u8 = 4,
    ref_frames: u8 = 3,

    // Quality
    me_range: u16 = 57, // Motion estimation search range
    subpel_refine: u8 = 2, // 0-7, higher = slower but better
    rd_level: u8 = 3, // 0-6, RD refinement level

    // Threading
    frame_threads: u8 = 0, // 0 = auto
    wpp_threads: u8 = 0, // 0 = auto (wavefront parallel processing)

    // Logging
    log_level: LogLevel = .warning,
};

pub const RateControlMethod = enum {
    cqp, // Constant QP
    crf, // Constant rate factor
    abr, // Average bitrate
};

pub const LogLevel = enum(c_int) {
    none = X265_LOG_NONE,
    err = X265_LOG_ERROR,
    warning = X265_LOG_WARNING,
    info = X265_LOG_INFO,
    debug = X265_LOG_DEBUG,
    full = X265_LOG_FULL,
};

/// Encoded packet from x265
pub const EncodedPacket = struct {
    data: []const u8,
    pts: types.Timestamp,
    dts: types.Timestamp,
    is_keyframe: bool,
    nal_type: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *EncodedPacket) void {
        self.allocator.free(self.data);
    }
};

/// x265 Encoder Statistics
pub const EncoderStats = struct {
    output_bitrate: f64,
    frame_num: u32,
};

/// x265 Encoder
pub const X265Encoder = struct {
    encoder: *x265_encoder,
    param: *x265_param,
    config: X265Config,
    allocator: std.mem.Allocator,
    frame_count: u64 = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: X265Config) !Self {
        // Allocate param struct
        const param = x265_param_alloc() orelse {
            return error.ParamAllocFailed;
        };
        errdefer x265_param_free(param);

        // Set defaults with preset and tune
        const preset_z = try allocator.dupeZ(u8, config.preset);
        defer allocator.free(preset_z);
        const tune_z = if (config.tune.len > 0)
            try allocator.dupeZ(u8, config.tune)
        else
            try allocator.dupeZ(u8, "");
        defer allocator.free(tune_z);

        const ret = x265_param_default_preset(param, preset_z.ptr, tune_z.ptr);
        if (ret < 0) {
            return error.InvalidPreset;
        }

        // Set video properties
        param.sourceWidth = @intCast(config.width);
        param.sourceHeight = @intCast(config.height);
        param.fpsNum = @intCast(config.frame_rate.num);
        param.fpsDenom = @intCast(config.frame_rate.denom);

        // Set internal color space to I420 (YUV 4:2:0 planar)
        param.internalCsp = X265_CSP_I420;

        // GOP structure
        param.rc.lookaheadDepth = @intCast(config.keyframe_interval);
        param.bframes = @intCast(config.b_frames);
        param.maxNumReferences = @intCast(config.ref_frames);

        // Rate control
        param.rc.rateControlMode = switch (config.rc_method) {
            .cqp => X265_RC_CQP,
            .crf => X265_RC_CRF,
            .abr => X265_RC_ABR,
        };

        switch (config.rc_method) {
            .cqp => {
                param.rc.qp = @intCast(config.qp);
            },
            .crf => {
                param.rc.rfConstant = @floatFromInt(config.crf);
            },
            .abr => {
                param.rc.bitrate = @intCast(config.bitrate);
            },
        }

        // Analysis
        param.searchRange = @intCast(config.me_range);
        param.subpelRefine = @intCast(config.subpel_refine);
        param.rdLevel = @intCast(config.rd_level);

        // Threading
        param.frameNumThreads = @intCast(config.frame_threads);
        param.wppThreads = @intCast(config.wpp_threads);

        // Logging
        param.logLevel = @intFromEnum(config.log_level);

        // Enable repeated headers (important for streaming)
        param.bEnableAccessUnitDelimiters = 1;

        // VUI timing info
        param.vui.bEnableTimingInfo = 1;
        param.vui.numUnitsInTick = @intCast(config.frame_rate.denom);
        param.vui.timeScale = @intCast(config.frame_rate.num);

        // Apply profile
        const profile_z = try allocator.dupeZ(u8, config.profile);
        defer allocator.free(profile_z);

        const profile_ret = x265_param_apply_profile(param, profile_z.ptr);
        if (profile_ret < 0) {
            return error.InvalidProfile;
        }

        // Open encoder
        const encoder = x265_encoder_open(param) orelse {
            return error.EncoderOpenFailed;
        };

        return .{
            .encoder = encoder,
            .param = param,
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        x265_encoder_close(self.encoder);
        x265_param_free(self.param);
    }

    /// Get encoder headers (VPS, SPS, PPS)
    pub fn getHeaders(self: *Self) ![]u8 {
        var pp_nal: ?[*]x265_nal = null;
        var pi_nal: u32 = 0;

        const ret = x265_encoder_headers(self.encoder, &pp_nal, &pi_nal);
        if (ret < 0) {
            return error.GetHeadersFailed;
        }

        // Concatenate all NAL units
        var total_size: usize = 0;
        const nals = pp_nal.?[0..pi_nal];
        for (nals) |nal| {
            total_size += nal.sizeBytes;
        }

        const headers = try self.allocator.alloc(u8, total_size);
        var offset: usize = 0;
        for (nals) |nal| {
            @memcpy(headers[offset .. offset + nal.sizeBytes], nal.payload.?[0..nal.sizeBytes]);
            offset += nal.sizeBytes;
        }

        return headers;
    }

    /// Encode a single frame
    pub fn encode(self: *Self, frame: *const VideoFrame) !?EncodedPacket {
        // Prepare input picture
        const pic_in = x265_picture_alloc() orelse {
            return error.PictureAllocFailed;
        };
        defer x265_picture_free(pic_in);

        x265_picture_init(self.param, pic_in);

        // Set picture type (let x265 decide)
        pic_in.sliceType = X265_TYPE_AUTO;

        // Set PTS
        pic_in.pts = frame.pts.toMicroseconds();

        // Set image dimensions
        pic_in.width = @intCast(frame.width);
        pic_in.height = @intCast(frame.height);

        // Set color space
        pic_in.colorSpace = X265_CSP_I420;
        pic_in.bitDepth = 8;

        // YUV 4:2:0 planar
        pic_in.planes[0] = frame.data[0].ptr;
        pic_in.planes[1] = frame.data[1].ptr;
        pic_in.planes[2] = frame.data[2].ptr;

        pic_in.stride[0] = @intCast(frame.stride[0]);
        pic_in.stride[1] = @intCast(frame.stride[1]);
        pic_in.stride[2] = @intCast(frame.stride[2]);

        // Encode
        const pic_out = x265_picture_alloc() orelse {
            return error.PictureAllocFailed;
        };
        defer x265_picture_free(pic_out);

        var pp_nal: ?[*]x265_nal = null;
        var pi_nal: u32 = 0;

        const ret = x265_encoder_encode(
            self.encoder,
            &pp_nal,
            &pi_nal,
            pic_in,
            pic_out,
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
        const nals = pp_nal.?[0..pi_nal];
        for (nals) |nal| {
            total_size += nal.sizeBytes;
        }

        const data = try self.allocator.alloc(u8, total_size);
        errdefer self.allocator.free(data);

        var offset: usize = 0;
        var is_keyframe = false;
        var nal_type: u32 = 0;

        for (nals) |nal| {
            @memcpy(data[offset .. offset + nal.sizeBytes], nal.payload.?[0..nal.sizeBytes]);
            offset += nal.sizeBytes;

            // Check if this is a keyframe (IDR or CRA)
            if (nal.@"type" == NAL_UNIT_CODED_SLICE_IDR_W_RADL or
                nal.@"type" == NAL_UNIT_CODED_SLICE_IDR_N_LP or
                nal.@"type" == NAL_UNIT_CODED_SLICE_CRA)
            {
                is_keyframe = true;
            }

            // Use first slice NAL type
            if (nal_type == 0 and nal.@"type" < NAL_UNIT_VPS) {
                nal_type = nal.@"type";
            }
        }

        self.frame_count += 1;

        return EncodedPacket{
            .data = data,
            .pts = types.Timestamp.fromMicroseconds(pic_out.pts),
            .dts = types.Timestamp.fromMicroseconds(pic_out.dts),
            .is_keyframe = is_keyframe,
            .nal_type = nal_type,
            .allocator = self.allocator,
        };
    }

    /// Flush delayed frames
    pub fn flush(self: *Self) !?EncodedPacket {
        const pic_out = x265_picture_alloc() orelse {
            return error.PictureAllocFailed;
        };
        defer x265_picture_free(pic_out);

        var pp_nal: ?[*]x265_nal = null;
        var pi_nal: u32 = 0;

        const ret = x265_encoder_encode(
            self.encoder,
            &pp_nal,
            &pi_nal,
            null, // NULL to flush
            pic_out,
        );

        if (ret < 0) {
            return error.FlushFailed;
        }

        if (ret == 0) {
            return null; // No more frames
        }

        // Concatenate all NAL units
        var total_size: usize = 0;
        const nals = pp_nal.?[0..pi_nal];
        for (nals) |nal| {
            total_size += nal.sizeBytes;
        }

        const data = try self.allocator.alloc(u8, total_size);
        errdefer self.allocator.free(data);

        var offset: usize = 0;
        var is_keyframe = false;
        var nal_type: u32 = 0;

        for (nals) |nal| {
            @memcpy(data[offset .. offset + nal.sizeBytes], nal.payload.?[0..nal.sizeBytes]);
            offset += nal.sizeBytes;

            if (nal.@"type" == NAL_UNIT_CODED_SLICE_IDR_W_RADL or
                nal.@"type" == NAL_UNIT_CODED_SLICE_IDR_N_LP or
                nal.@"type" == NAL_UNIT_CODED_SLICE_CRA)
            {
                is_keyframe = true;
            }

            if (nal_type == 0 and nal.@"type" < NAL_UNIT_VPS) {
                nal_type = nal.@"type";
            }
        }

        return EncodedPacket{
            .data = data,
            .pts = types.Timestamp.fromMicroseconds(pic_out.pts),
            .dts = types.Timestamp.fromMicroseconds(pic_out.dts),
            .is_keyframe = is_keyframe,
            .nal_type = nal_type,
            .allocator = self.allocator,
        };
    }

    /// Get encoder statistics
    pub fn getStats(self: *Self) EncoderStats {
        var output_bitrate: f64 = 0;
        var frame_num: u32 = 0;
        x265_encoder_get_stats(self.encoder, &output_bitrate, &frame_num);
        return .{
            .output_bitrate = output_bitrate,
            .frame_num = frame_num,
        };
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Get x265 version string
pub fn getVersion() [:0]const u8 {
    return std.mem.span(x265_version_str());
}

/// Get x265 build info
pub fn getBuildInfo() [:0]const u8 {
    return std.mem.span(x265_build_info_str());
}

/// Cleanup global x265 resources (call at program exit)
pub fn cleanup() void {
    x265_cleanup();
}
