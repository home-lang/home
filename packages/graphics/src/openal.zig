// Home Programming Language - OpenAL FFI Bindings
// Provides 3D positional audio via OpenAL
//
// OpenAL is a cross-platform 3D audio API similar to OpenGL

const std = @import("std");
const ffi = @import("../../ffi/src/ffi.zig");

// ============================================================================
// OpenAL Types
// ============================================================================

pub const ALboolean = u8;
pub const ALchar = u8;
pub const ALbyte = i8;
pub const ALubyte = u8;
pub const ALshort = c_short;
pub const ALushort = c_ushort;
pub const ALint = c_int;
pub const ALuint = c_uint;
pub const ALsizei = c_int;
pub const ALenum = c_int;
pub const ALfloat = f32;
pub const ALdouble = f64;
pub const ALvoid = anyopaque;

// Opaque device and context handles
pub const ALCdevice = opaque {};
pub const ALCcontext = opaque {};

pub const ALCboolean = u8;
pub const ALCchar = u8;
pub const ALCbyte = i8;
pub const ALCubyte = u8;
pub const ALCshort = c_short;
pub const ALCushort = c_ushort;
pub const ALCint = c_int;
pub const ALCuint = c_uint;
pub const ALCsizei = c_int;
pub const ALCenum = c_int;
pub const ALCfloat = f32;
pub const ALCdouble = f64;
pub const ALCvoid = anyopaque;

// ============================================================================
// OpenAL Constants
// ============================================================================

// Boolean values
pub const AL_FALSE: ALboolean = 0;
pub const AL_TRUE: ALboolean = 1;

// Errors
pub const AL_NO_ERROR: ALenum = 0;
pub const AL_INVALID_NAME: ALenum = 0xA001;
pub const AL_INVALID_ENUM: ALenum = 0xA002;
pub const AL_INVALID_VALUE: ALenum = 0xA003;
pub const AL_INVALID_OPERATION: ALenum = 0xA004;
pub const AL_OUT_OF_MEMORY: ALenum = 0xA005;

// Source parameters
pub const AL_SOURCE_RELATIVE: ALenum = 0x202;
pub const AL_CONE_INNER_ANGLE: ALenum = 0x1001;
pub const AL_CONE_OUTER_ANGLE: ALenum = 0x1002;
pub const AL_PITCH: ALenum = 0x1003;
pub const AL_POSITION: ALenum = 0x1004;
pub const AL_DIRECTION: ALenum = 0x1005;
pub const AL_VELOCITY: ALenum = 0x1006;
pub const AL_LOOPING: ALenum = 0x1007;
pub const AL_BUFFER: ALenum = 0x1009;
pub const AL_GAIN: ALenum = 0x100A;
pub const AL_MIN_GAIN: ALenum = 0x100D;
pub const AL_MAX_GAIN: ALenum = 0x100E;
pub const AL_ORIENTATION: ALenum = 0x100F;
pub const AL_REFERENCE_DISTANCE: ALenum = 0x1020;
pub const AL_ROLLOFF_FACTOR: ALenum = 0x1021;
pub const AL_CONE_OUTER_GAIN: ALenum = 0x1022;
pub const AL_MAX_DISTANCE: ALenum = 0x1023;

// Source state
pub const AL_SOURCE_STATE: ALenum = 0x1010;
pub const AL_INITIAL: ALenum = 0x1011;
pub const AL_PLAYING: ALenum = 0x1012;
pub const AL_PAUSED: ALenum = 0x1013;
pub const AL_STOPPED: ALenum = 0x1014;

// Buffer parameters
pub const AL_FREQUENCY: ALenum = 0x2001;
pub const AL_BITS: ALenum = 0x2002;
pub const AL_CHANNELS: ALenum = 0x2003;
pub const AL_SIZE: ALenum = 0x2004;

// Buffer formats
pub const AL_FORMAT_MONO8: ALenum = 0x1100;
pub const AL_FORMAT_MONO16: ALenum = 0x1101;
pub const AL_FORMAT_STEREO8: ALenum = 0x1102;
pub const AL_FORMAT_STEREO16: ALenum = 0x1103;

// Listener parameters
pub const AL_UNUSED: ALenum = 0x2010;

// Distance models
pub const AL_DISTANCE_MODEL: ALenum = 0xD000;
pub const AL_INVERSE_DISTANCE: ALenum = 0xD001;
pub const AL_INVERSE_DISTANCE_CLAMPED: ALenum = 0xD002;
pub const AL_LINEAR_DISTANCE: ALenum = 0xD003;
pub const AL_LINEAR_DISTANCE_CLAMPED: ALenum = 0xD004;
pub const AL_EXPONENT_DISTANCE: ALenum = 0xD005;
pub const AL_EXPONENT_DISTANCE_CLAMPED: ALenum = 0xD006;

// ALC (OpenAL Context) constants
pub const ALC_FALSE: ALCboolean = 0;
pub const ALC_TRUE: ALCboolean = 1;

pub const ALC_FREQUENCY: ALCenum = 0x1007;
pub const ALC_REFRESH: ALCenum = 0x1008;
pub const ALC_SYNC: ALCenum = 0x1009;
pub const ALC_MONO_SOURCES: ALCenum = 0x1010;
pub const ALC_STEREO_SOURCES: ALCenum = 0x1011;

pub const ALC_NO_ERROR: ALCenum = 0;
pub const ALC_INVALID_DEVICE: ALCenum = 0xA001;
pub const ALC_INVALID_CONTEXT: ALCenum = 0xA002;
pub const ALC_INVALID_ENUM: ALCenum = 0xA003;
pub const ALC_INVALID_VALUE: ALCenum = 0xA004;
pub const ALC_OUT_OF_MEMORY: ALCenum = 0xA005;

pub const ALC_DEFAULT_DEVICE_SPECIFIER: ALCenum = 0x1004;
pub const ALC_DEVICE_SPECIFIER: ALCenum = 0x1005;
pub const ALC_EXTENSIONS: ALCenum = 0x1006;

// ============================================================================
// OpenAL Core Functions
// ============================================================================

// Renderer State management
pub extern "c" fn alEnable(capability: ALenum) void;
pub extern "c" fn alDisable(capability: ALenum) void;
pub extern "c" fn alIsEnabled(capability: ALenum) ALboolean;

// State retrieval
pub extern "c" fn alGetString(param: ALenum) ?[*:0]const u8;
pub extern "c" fn alGetBooleanv(param: ALenum, values: [*]ALboolean) void;
pub extern "c" fn alGetIntegerv(param: ALenum, values: [*]ALint) void;
pub extern "c" fn alGetFloatv(param: ALenum, values: [*]ALfloat) void;
pub extern "c" fn alGetDoublev(param: ALenum, values: [*]ALdouble) void;
pub extern "c" fn alGetBoolean(param: ALenum) ALboolean;
pub extern "c" fn alGetInteger(param: ALenum) ALint;
pub extern "c" fn alGetFloat(param: ALenum) ALfloat;
pub extern "c" fn alGetDouble(param: ALenum) ALdouble;

// Error support
pub extern "c" fn alGetError() ALenum;

// Extension support
pub extern "c" fn alIsExtensionPresent(extname: [*:0]const u8) ALboolean;
pub extern "c" fn alGetProcAddress(fname: [*:0]const u8) ?*const anyopaque;
pub extern "c" fn alGetEnumValue(ename: [*:0]const u8) ALenum;

// Listener
pub extern "c" fn alListenerf(param: ALenum, value: ALfloat) void;
pub extern "c" fn alListener3f(param: ALenum, value1: ALfloat, value2: ALfloat, value3: ALfloat) void;
pub extern "c" fn alListenerfv(param: ALenum, values: [*]const ALfloat) void;
pub extern "c" fn alListeneri(param: ALenum, value: ALint) void;
pub extern "c" fn alListener3i(param: ALenum, value1: ALint, value2: ALint, value3: ALint) void;
pub extern "c" fn alListeneriv(param: ALenum, values: [*]const ALint) void;
pub extern "c" fn alGetListenerf(param: ALenum, value: *ALfloat) void;
pub extern "c" fn alGetListener3f(param: ALenum, value1: *ALfloat, value2: *ALfloat, value3: *ALfloat) void;
pub extern "c" fn alGetListenerfv(param: ALenum, values: [*]ALfloat) void;
pub extern "c" fn alGetListeneri(param: ALenum, value: *ALint) void;
pub extern "c" fn alGetListener3i(param: ALenum, value1: *ALint, value2: *ALint, value3: *ALint) void;
pub extern "c" fn alGetListeneriv(param: ALenum, values: [*]ALint) void;

// Sources
pub extern "c" fn alGenSources(n: ALsizei, sources: [*]ALuint) void;
pub extern "c" fn alDeleteSources(n: ALsizei, sources: [*]const ALuint) void;
pub extern "c" fn alIsSource(source: ALuint) ALboolean;

pub extern "c" fn alSourcef(source: ALuint, param: ALenum, value: ALfloat) void;
pub extern "c" fn alSource3f(source: ALuint, param: ALenum, value1: ALfloat, value2: ALfloat, value3: ALfloat) void;
pub extern "c" fn alSourcefv(source: ALuint, param: ALenum, values: [*]const ALfloat) void;
pub extern "c" fn alSourcei(source: ALuint, param: ALenum, value: ALint) void;
pub extern "c" fn alSource3i(source: ALuint, param: ALenum, value1: ALint, value2: ALint, value3: ALint) void;
pub extern "c" fn alSourceiv(source: ALuint, param: ALenum, values: [*]const ALint) void;

pub extern "c" fn alGetSourcef(source: ALuint, param: ALenum, value: *ALfloat) void;
pub extern "c" fn alGetSource3f(source: ALuint, param: ALenum, value1: *ALfloat, value2: *ALfloat, value3: *ALfloat) void;
pub extern "c" fn alGetSourcefv(source: ALuint, param: ALenum, values: [*]ALfloat) void;
pub extern "c" fn alGetSourcei(source: ALuint, param: ALenum, value: *ALint) void;
pub extern "c" fn alGetSource3i(source: ALuint, param: ALenum, value1: *ALint, value2: *ALint, value3: *ALint) void;
pub extern "c" fn alGetSourceiv(source: ALuint, param: ALenum, values: [*]ALint) void;

// Source playback
pub extern "c" fn alSourcePlayv(n: ALsizei, sources: [*]const ALuint) void;
pub extern "c" fn alSourceStopv(n: ALsizei, sources: [*]const ALuint) void;
pub extern "c" fn alSourceRewindv(n: ALsizei, sources: [*]const ALuint) void;
pub extern "c" fn alSourcePausev(n: ALsizei, sources: [*]const ALuint) void;

pub extern "c" fn alSourcePlay(source: ALuint) void;
pub extern "c" fn alSourceStop(source: ALuint) void;
pub extern "c" fn alSourceRewind(source: ALuint) void;
pub extern "c" fn alSourcePause(source: ALuint) void;

// Source queuing
pub extern "c" fn alSourceQueueBuffers(source: ALuint, nb: ALsizei, buffers: [*]const ALuint) void;
pub extern "c" fn alSourceUnqueueBuffers(source: ALuint, nb: ALsizei, buffers: [*]ALuint) void;

// Buffers
pub extern "c" fn alGenBuffers(n: ALsizei, buffers: [*]ALuint) void;
pub extern "c" fn alDeleteBuffers(n: ALsizei, buffers: [*]const ALuint) void;
pub extern "c" fn alIsBuffer(buffer: ALuint) ALboolean;
pub extern "c" fn alBufferData(buffer: ALuint, format: ALenum, data: ?*const anyopaque, size: ALsizei, freq: ALsizei) void;

pub extern "c" fn alBufferf(buffer: ALuint, param: ALenum, value: ALfloat) void;
pub extern "c" fn alBuffer3f(buffer: ALuint, param: ALenum, value1: ALfloat, value2: ALfloat, value3: ALfloat) void;
pub extern "c" fn alBufferfv(buffer: ALuint, param: ALenum, values: [*]const ALfloat) void;
pub extern "c" fn alBufferi(buffer: ALuint, param: ALenum, value: ALint) void;
pub extern "c" fn alBuffer3i(buffer: ALuint, param: ALenum, value1: ALint, value2: ALint, value3: ALint) void;
pub extern "c" fn alBufferiv(buffer: ALuint, param: ALenum, values: [*]const ALint) void;

pub extern "c" fn alGetBufferf(buffer: ALuint, param: ALenum, value: *ALfloat) void;
pub extern "c" fn alGetBuffer3f(buffer: ALuint, param: ALenum, value1: *ALfloat, value2: *ALfloat, value3: *ALfloat) void;
pub extern "c" fn alGetBufferfv(buffer: ALuint, param: ALenum, values: [*]ALfloat) void;
pub extern "c" fn alGetBufferi(buffer: ALuint, param: ALenum, value: *ALint) void;
pub extern "c" fn alGetBuffer3i(buffer: ALuint, param: ALenum, value1: *ALint, value2: *ALint, value3: *ALint) void;
pub extern "c" fn alGetBufferiv(buffer: ALuint, param: ALenum, values: [*]ALint) void;

// Distance model
pub extern "c" fn alDistanceModel(distanceModel: ALenum) void;
pub extern "c" fn alDopplerFactor(value: ALfloat) void;
pub extern "c" fn alDopplerVelocity(value: ALfloat) void;
pub extern "c" fn alSpeedOfSound(value: ALfloat) void;

// ============================================================================
// OpenAL Context Functions (ALC)
// ============================================================================

// Context management
pub extern "c" fn alcCreateContext(device: ?*ALCdevice, attrlist: ?[*]const ALCint) ?*ALCcontext;
pub extern "c" fn alcMakeContextCurrent(context: ?*ALCcontext) ALCboolean;
pub extern "c" fn alcProcessContext(context: ?*ALCcontext) void;
pub extern "c" fn alcSuspendContext(context: ?*ALCcontext) void;
pub extern "c" fn alcDestroyContext(context: ?*ALCcontext) void;
pub extern "c" fn alcGetCurrentContext() ?*ALCcontext;
pub extern "c" fn alcGetContextsDevice(context: ?*ALCcontext) ?*ALCdevice;

// Device management
pub extern "c" fn alcOpenDevice(devicename: ?[*:0]const u8) ?*ALCdevice;
pub extern "c" fn alcCloseDevice(device: ?*ALCdevice) ALCboolean;

// Error support
pub extern "c" fn alcGetError(device: ?*ALCdevice) ALCenum;

// Extension support
pub extern "c" fn alcIsExtensionPresent(device: ?*ALCdevice, extname: [*:0]const u8) ALCboolean;
pub extern "c" fn alcGetProcAddress(device: ?*ALCdevice, funcname: [*:0]const u8) ?*const anyopaque;
pub extern "c" fn alcGetEnumValue(device: ?*ALCdevice, enumname: [*:0]const u8) ALCenum;

// Query functions
pub extern "c" fn alcGetString(device: ?*ALCdevice, param: ALCenum) ?[*:0]const u8;
pub extern "c" fn alcGetIntegerv(device: ?*ALCdevice, param: ALCenum, size: ALCsizei, values: [*]ALCint) void;

// Capture functions (ALC_EXT_CAPTURE)
pub extern "c" fn alcCaptureOpenDevice(devicename: ?[*:0]const u8, frequency: ALCuint, format: ALCenum, buffersize: ALCsizei) ?*ALCdevice;
pub extern "c" fn alcCaptureCloseDevice(device: ?*ALCdevice) ALCboolean;
pub extern "c" fn alcCaptureStart(device: ?*ALCdevice) void;
pub extern "c" fn alcCaptureStop(device: ?*ALCdevice) void;
pub extern "c" fn alcCaptureSamples(device: ?*ALCdevice, buffer: ?*anyopaque, samples: ALCsizei) void;

// ============================================================================
// Helper Functions
// ============================================================================

/// Check for OpenAL errors and return error string
pub fn checkError() ?[]const u8 {
    const err = alGetError();
    return switch (err) {
        AL_NO_ERROR => null,
        AL_INVALID_NAME => "AL_INVALID_NAME",
        AL_INVALID_ENUM => "AL_INVALID_ENUM",
        AL_INVALID_VALUE => "AL_INVALID_VALUE",
        AL_INVALID_OPERATION => "AL_INVALID_OPERATION",
        AL_OUT_OF_MEMORY => "AL_OUT_OF_MEMORY",
        else => "UNKNOWN_ERROR",
    };
}

/// Check for ALC errors and return error string
pub fn checkContextError(device: ?*ALCdevice) ?[]const u8 {
    const err = alcGetError(device);
    return switch (err) {
        ALC_NO_ERROR => null,
        ALC_INVALID_DEVICE => "ALC_INVALID_DEVICE",
        ALC_INVALID_CONTEXT => "ALC_INVALID_CONTEXT",
        ALC_INVALID_ENUM => "ALC_INVALID_ENUM",
        ALC_INVALID_VALUE => "ALC_INVALID_VALUE",
        ALC_OUT_OF_MEMORY => "ALC_OUT_OF_MEMORY",
        else => "UNKNOWN_ERROR",
    };
}

/// Generate a single source
pub fn genSource() ALuint {
    var source: ALuint = undefined;
    alGenSources(1, &source);
    return source;
}

/// Delete a single source
pub fn deleteSource(source: ALuint) void {
    alDeleteSources(1, &source);
}

/// Generate a single buffer
pub fn genBuffer() ALuint {
    var buffer: ALuint = undefined;
    alGenBuffers(1, &buffer);
    return buffer;
}

/// Delete a single buffer
pub fn deleteBuffer(buffer: ALuint) void {
    alDeleteBuffers(1, &buffer);
}

/// Set listener position (x, y, z)
pub fn setListenerPosition(x: f32, y: f32, z: f32) void {
    alListener3f(AL_POSITION, x, y, z);
}

/// Set listener velocity (x, y, z)
pub fn setListenerVelocity(x: f32, y: f32, z: f32) void {
    alListener3f(AL_VELOCITY, x, y, z);
}

/// Set listener orientation (at_x, at_y, at_z, up_x, up_y, up_z)
pub fn setListenerOrientation(at_x: f32, at_y: f32, at_z: f32, up_x: f32, up_y: f32, up_z: f32) void {
    const orientation = [_]f32{ at_x, at_y, at_z, up_x, up_y, up_z };
    alListenerfv(AL_ORIENTATION, &orientation);
}

/// Set source position (x, y, z)
pub fn setSourcePosition(source: ALuint, x: f32, y: f32, z: f32) void {
    alSource3f(source, AL_POSITION, x, y, z);
}

/// Set source velocity (x, y, z)
pub fn setSourceVelocity(source: ALuint, x: f32, y: f32, z: f32) void {
    alSource3f(source, AL_VELOCITY, x, y, z);
}

/// Set source gain (volume)
pub fn setSourceGain(source: ALuint, gain: f32) void {
    alSourcef(source, AL_GAIN, gain);
}

/// Set source pitch
pub fn setSourcePitch(source: ALuint, pitch: f32) void {
    alSourcef(source, AL_PITCH, pitch);
}

/// Set source looping
pub fn setSourceLooping(source: ALuint, looping: bool) void {
    alSourcei(source, AL_LOOPING, if (looping) AL_TRUE else AL_FALSE);
}

/// Get source state
pub fn getSourceState(source: ALuint) ALint {
    var state: ALint = undefined;
    alGetSourcei(source, AL_SOURCE_STATE, &state);
    return state;
}

/// Check if source is playing
pub fn isSourcePlaying(source: ALuint) bool {
    return getSourceState(source) == AL_PLAYING;
}

// ============================================================================
// Tests
// ============================================================================

test "OpenAL constants" {
    const testing = std.testing;

    // Verify some key constants
    try testing.expectEqual(@as(ALenum, 0x1100), AL_FORMAT_MONO8);
    try testing.expectEqual(@as(ALenum, 0x1101), AL_FORMAT_MONO16);
    try testing.expectEqual(@as(ALenum, 0x1012), AL_PLAYING);
}

test "OpenAL type sizes" {
    const testing = std.testing;

    // Verify type sizes
    try testing.expectEqual(@as(usize, 4), @sizeOf(ALuint));
    try testing.expectEqual(@as(usize, 4), @sizeOf(ALint));
    try testing.expectEqual(@as(usize, 4), @sizeOf(ALfloat));
    try testing.expectEqual(@as(usize, 1), @sizeOf(ALboolean));
}
