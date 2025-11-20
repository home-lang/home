// Home Programming Language - OpenGL FFI Bindings
// Provides complete OpenGL 4.1 Core Profile bindings for macOS
//
// This module exposes OpenGL functions to Home language programs
// OpenGL 4.1 is the maximum version supported on macOS

const std = @import("std");
const ffi = @import("../../ffi/src/ffi.zig");

// ============================================================================
// OpenGL Types
// ============================================================================

pub const GLenum = c_uint;
pub const GLboolean = u8;
pub const GLbitfield = c_uint;
pub const GLvoid = anyopaque;
pub const GLbyte = i8;
pub const GLshort = c_short;
pub const GLint = c_int;
pub const GLubyte = u8;
pub const GLushort = c_ushort;
pub const GLuint = c_uint;
pub const GLsizei = c_int;
pub const GLfloat = f32;
pub const GLclampf = f32;
pub const GLdouble = f64;
pub const GLclampd = f64;
pub const GLchar = u8;
pub const GLsizeiptr = isize;
pub const GLintptr = isize;
pub const GLint64 = i64;
pub const GLuint64 = u64;

// ============================================================================
// OpenGL Constants
// ============================================================================

// Boolean values
pub const GL_FALSE: GLboolean = 0;
pub const GL_TRUE: GLboolean = 1;

// Data types
pub const GL_BYTE: GLenum = 0x1400;
pub const GL_UNSIGNED_BYTE: GLenum = 0x1401;
pub const GL_SHORT: GLenum = 0x1402;
pub const GL_UNSIGNED_SHORT: GLenum = 0x1403;
pub const GL_INT: GLenum = 0x1404;
pub const GL_UNSIGNED_INT: GLenum = 0x1405;
pub const GL_FLOAT: GLenum = 0x1406;
pub const GL_DOUBLE: GLenum = 0x140A;

// Primitives
pub const GL_POINTS: GLenum = 0x0000;
pub const GL_LINES: GLenum = 0x0001;
pub const GL_LINE_LOOP: GLenum = 0x0002;
pub const GL_LINE_STRIP: GLenum = 0x0003;
pub const GL_TRIANGLES: GLenum = 0x0004;
pub const GL_TRIANGLE_STRIP: GLenum = 0x0005;
pub const GL_TRIANGLE_FAN: GLenum = 0x0006;

// Buffer objects
pub const GL_ARRAY_BUFFER: GLenum = 0x8892;
pub const GL_ELEMENT_ARRAY_BUFFER: GLenum = 0x8893;
pub const GL_UNIFORM_BUFFER: GLenum = 0x8A11;

// Buffer usage
pub const GL_STREAM_DRAW: GLenum = 0x88E0;
pub const GL_STREAM_READ: GLenum = 0x88E1;
pub const GL_STREAM_COPY: GLenum = 0x88E2;
pub const GL_STATIC_DRAW: GLenum = 0x88E4;
pub const GL_STATIC_READ: GLenum = 0x88E5;
pub const GL_STATIC_COPY: GLenum = 0x88E6;
pub const GL_DYNAMIC_DRAW: GLenum = 0x88E8;
pub const GL_DYNAMIC_READ: GLenum = 0x88E9;
pub const GL_DYNAMIC_COPY: GLenum = 0x88EA;

// Shaders
pub const GL_VERTEX_SHADER: GLenum = 0x8B31;
pub const GL_FRAGMENT_SHADER: GLenum = 0x8B30;
pub const GL_GEOMETRY_SHADER: GLenum = 0x8DD9;
pub const GL_COMPILE_STATUS: GLenum = 0x8B81;
pub const GL_LINK_STATUS: GLenum = 0x8B82;
pub const GL_INFO_LOG_LENGTH: GLenum = 0x8B84;

// Textures
pub const GL_TEXTURE_1D: GLenum = 0x0DE0;
pub const GL_TEXTURE_2D: GLenum = 0x0DE1;
pub const GL_TEXTURE_3D: GLenum = 0x806F;
pub const GL_TEXTURE_CUBE_MAP: GLenum = 0x8513;
pub const GL_TEXTURE_2D_ARRAY: GLenum = 0x8C1A;

pub const GL_TEXTURE_MAG_FILTER: GLenum = 0x2800;
pub const GL_TEXTURE_MIN_FILTER: GLenum = 0x2801;
pub const GL_TEXTURE_WRAP_S: GLenum = 0x2802;
pub const GL_TEXTURE_WRAP_T: GLenum = 0x2803;
pub const GL_TEXTURE_WRAP_R: GLenum = 0x8072;

pub const GL_NEAREST: GLenum = 0x2600;
pub const GL_LINEAR: GLenum = 0x2601;
pub const GL_NEAREST_MIPMAP_NEAREST: GLenum = 0x2700;
pub const GL_LINEAR_MIPMAP_NEAREST: GLenum = 0x2701;
pub const GL_NEAREST_MIPMAP_LINEAR: GLenum = 0x2702;
pub const GL_LINEAR_MIPMAP_LINEAR: GLenum = 0x2703;

pub const GL_REPEAT: GLenum = 0x2901;
pub const GL_CLAMP_TO_EDGE: GLenum = 0x812F;
pub const GL_CLAMP_TO_BORDER: GLenum = 0x812D;
pub const GL_MIRRORED_REPEAT: GLenum = 0x8370;

// Texture formats
pub const GL_RED: GLenum = 0x1903;
pub const GL_RGB: GLenum = 0x1907;
pub const GL_RGBA: GLenum = 0x1908;
pub const GL_DEPTH_COMPONENT: GLenum = 0x1902;
pub const GL_DEPTH_STENCIL: GLenum = 0x84F9;

pub const GL_RGB8: GLenum = 0x8051;
pub const GL_RGBA8: GLenum = 0x8058;
pub const GL_DEPTH_COMPONENT24: GLenum = 0x81A6;
pub const GL_DEPTH24_STENCIL8: GLenum = 0x88F0;

// Framebuffers
pub const GL_FRAMEBUFFER: GLenum = 0x8D40;
pub const GL_READ_FRAMEBUFFER: GLenum = 0x8CA8;
pub const GL_DRAW_FRAMEBUFFER: GLenum = 0x8CA9;
pub const GL_COLOR_ATTACHMENT0: GLenum = 0x8CE0;
pub const GL_DEPTH_ATTACHMENT: GLenum = 0x8D00;
pub const GL_STENCIL_ATTACHMENT: GLenum = 0x8D20;
pub const GL_FRAMEBUFFER_COMPLETE: GLenum = 0x8CD5;

// Blending
pub const GL_BLEND: GLenum = 0x0BE2;
pub const GL_SRC_ALPHA: GLenum = 0x0302;
pub const GL_ONE_MINUS_SRC_ALPHA: GLenum = 0x0303;
pub const GL_ONE: GLenum = 1;
pub const GL_ZERO: GLenum = 0;

// Depth testing
pub const GL_DEPTH_TEST: GLenum = 0x0B71;
pub const GL_LESS: GLenum = 0x0201;
pub const GL_LEQUAL: GLenum = 0x0203;
pub const GL_GREATER: GLenum = 0x0204;
pub const GL_GEQUAL: GLenum = 0x0206;
pub const GL_EQUAL: GLenum = 0x0202;
pub const GL_NOTEQUAL: GLenum = 0x0205;
pub const GL_ALWAYS: GLenum = 0x0207;
pub const GL_NEVER: GLenum = 0x0200;

// Face culling
pub const GL_CULL_FACE: GLenum = 0x0B44;
pub const GL_FRONT: GLenum = 0x0404;
pub const GL_BACK: GLenum = 0x0405;
pub const GL_FRONT_AND_BACK: GLenum = 0x0408;
pub const GL_CW: GLenum = 0x0900;
pub const GL_CCW: GLenum = 0x0901;

// Clearing
pub const GL_COLOR_BUFFER_BIT: GLbitfield = 0x00004000;
pub const GL_DEPTH_BUFFER_BIT: GLbitfield = 0x00000100;
pub const GL_STENCIL_BUFFER_BIT: GLbitfield = 0x00000400;

// Errors
pub const GL_NO_ERROR: GLenum = 0;
pub const GL_INVALID_ENUM: GLenum = 0x0500;
pub const GL_INVALID_VALUE: GLenum = 0x0501;
pub const GL_INVALID_OPERATION: GLenum = 0x0502;
pub const GL_OUT_OF_MEMORY: GLenum = 0x0505;

// Vertex arrays
pub const GL_VERTEX_ARRAY: GLenum = 0x8074;

// ============================================================================
// OpenGL Functions - Core Profile
// ============================================================================

// Basic operations
pub extern "c" fn glEnable(cap: GLenum) void;
pub extern "c" fn glDisable(cap: GLenum) void;
pub extern "c" fn glClear(mask: GLbitfield) void;
pub extern "c" fn glClearColor(red: GLfloat, green: GLfloat, blue: GLfloat, alpha: GLfloat) void;
pub extern "c" fn glClearDepth(depth: GLdouble) void;
pub extern "c" fn glViewport(x: GLint, y: GLint, width: GLsizei, height: GLsizei) void;
pub extern "c" fn glScissor(x: GLint, y: GLint, width: GLsizei, height: GLsizei) void;
pub extern "c" fn glFlush() void;
pub extern "c" fn glFinish() void;
pub extern "c" fn glGetError() GLenum;

// Depth testing
pub extern "c" fn glDepthFunc(func: GLenum) void;
pub extern "c" fn glDepthMask(flag: GLboolean) void;

// Blending
pub extern "c" fn glBlendFunc(sfactor: GLenum, dfactor: GLenum) void;
pub extern "c" fn glBlendEquation(mode: GLenum) void;

// Face culling
pub extern "c" fn glCullFace(mode: GLenum) void;
pub extern "c" fn glFrontFace(mode: GLenum) void;

// Buffer objects
pub extern "c" fn glGenBuffers(n: GLsizei, buffers: [*]GLuint) void;
pub extern "c" fn glDeleteBuffers(n: GLsizei, buffers: [*]const GLuint) void;
pub extern "c" fn glBindBuffer(target: GLenum, buffer: GLuint) void;
pub extern "c" fn glBufferData(target: GLenum, size: GLsizeiptr, data: ?*const anyopaque, usage: GLenum) void;
pub extern "c" fn glBufferSubData(target: GLenum, offset: GLintptr, size: GLsizeiptr, data: ?*const anyopaque) void;
pub extern "c" fn glMapBuffer(target: GLenum, access: GLenum) ?*anyopaque;
pub extern "c" fn glUnmapBuffer(target: GLenum) GLboolean;

// Vertex arrays
pub extern "c" fn glGenVertexArrays(n: GLsizei, arrays: [*]GLuint) void;
pub extern "c" fn glDeleteVertexArrays(n: GLsizei, arrays: [*]const GLuint) void;
pub extern "c" fn glBindVertexArray(array: GLuint) void;
pub extern "c" fn glEnableVertexAttribArray(index: GLuint) void;
pub extern "c" fn glDisableVertexAttribArray(index: GLuint) void;
pub extern "c" fn glVertexAttribPointer(
    index: GLuint,
    size: GLint,
    type_: GLenum,
    normalized: GLboolean,
    stride: GLsizei,
    pointer: ?*const anyopaque,
) void;
pub extern "c" fn glVertexAttribDivisor(index: GLuint, divisor: GLuint) void;

// Drawing
pub extern "c" fn glDrawArrays(mode: GLenum, first: GLint, count: GLsizei) void;
pub extern "c" fn glDrawElements(mode: GLenum, count: GLsizei, type_: GLenum, indices: ?*const anyopaque) void;
pub extern "c" fn glDrawArraysInstanced(mode: GLenum, first: GLint, count: GLsizei, instancecount: GLsizei) void;
pub extern "c" fn glDrawElementsInstanced(mode: GLenum, count: GLsizei, type_: GLenum, indices: ?*const anyopaque, instancecount: GLsizei) void;

// Shaders
pub extern "c" fn glCreateShader(type_: GLenum) GLuint;
pub extern "c" fn glDeleteShader(shader: GLuint) void;
pub extern "c" fn glShaderSource(shader: GLuint, count: GLsizei, string: [*]const [*:0]const u8, length: ?[*]const GLint) void;
pub extern "c" fn glCompileShader(shader: GLuint) void;
pub extern "c" fn glGetShaderiv(shader: GLuint, pname: GLenum, params: *GLint) void;
pub extern "c" fn glGetShaderInfoLog(shader: GLuint, bufSize: GLsizei, length: ?*GLsizei, infoLog: [*]GLchar) void;

// Programs
pub extern "c" fn glCreateProgram() GLuint;
pub extern "c" fn glDeleteProgram(program: GLuint) void;
pub extern "c" fn glAttachShader(program: GLuint, shader: GLuint) void;
pub extern "c" fn glDetachShader(program: GLuint, shader: GLuint) void;
pub extern "c" fn glLinkProgram(program: GLuint) void;
pub extern "c" fn glUseProgram(program: GLuint) void;
pub extern "c" fn glGetProgramiv(program: GLuint, pname: GLenum, params: *GLint) void;
pub extern "c" fn glGetProgramInfoLog(program: GLuint, bufSize: GLsizei, length: ?*GLsizei, infoLog: [*]GLchar) void;

// Uniforms
pub extern "c" fn glGetUniformLocation(program: GLuint, name: [*:0]const u8) GLint;
pub extern "c" fn glUniform1f(location: GLint, v0: GLfloat) void;
pub extern "c" fn glUniform2f(location: GLint, v0: GLfloat, v1: GLfloat) void;
pub extern "c" fn glUniform3f(location: GLint, v0: GLfloat, v1: GLfloat, v2: GLfloat) void;
pub extern "c" fn glUniform4f(location: GLint, v0: GLfloat, v1: GLfloat, v2: GLfloat, v3: GLfloat) void;
pub extern "c" fn glUniform1i(location: GLint, v0: GLint) void;
pub extern "c" fn glUniform2i(location: GLint, v0: GLint, v1: GLint) void;
pub extern "c" fn glUniform3i(location: GLint, v0: GLint, v1: GLint, v2: GLint) void;
pub extern "c" fn glUniform4i(location: GLint, v0: GLint, v1: GLint, v2: GLint, v3: GLint) void;
pub extern "c" fn glUniform1fv(location: GLint, count: GLsizei, value: [*]const GLfloat) void;
pub extern "c" fn glUniform2fv(location: GLint, count: GLsizei, value: [*]const GLfloat) void;
pub extern "c" fn glUniform3fv(location: GLint, count: GLsizei, value: [*]const GLfloat) void;
pub extern "c" fn glUniform4fv(location: GLint, count: GLsizei, value: [*]const GLfloat) void;
pub extern "c" fn glUniformMatrix2fv(location: GLint, count: GLsizei, transpose: GLboolean, value: [*]const GLfloat) void;
pub extern "c" fn glUniformMatrix3fv(location: GLint, count: GLsizei, transpose: GLboolean, value: [*]const GLfloat) void;
pub extern "c" fn glUniformMatrix4fv(location: GLint, count: GLsizei, transpose: GLboolean, value: [*]const GLfloat) void;

// Textures
pub extern "c" fn glGenTextures(n: GLsizei, textures: [*]GLuint) void;
pub extern "c" fn glDeleteTextures(n: GLsizei, textures: [*]const GLuint) void;
pub extern "c" fn glBindTexture(target: GLenum, texture: GLuint) void;
pub extern "c" fn glTexImage2D(
    target: GLenum,
    level: GLint,
    internalformat: GLint,
    width: GLsizei,
    height: GLsizei,
    border: GLint,
    format: GLenum,
    type_: GLenum,
    pixels: ?*const anyopaque,
) void;
pub extern "c" fn glTexSubImage2D(
    target: GLenum,
    level: GLint,
    xoffset: GLint,
    yoffset: GLint,
    width: GLsizei,
    height: GLsizei,
    format: GLenum,
    type_: GLenum,
    pixels: ?*const anyopaque,
) void;
pub extern "c" fn glTexParameteri(target: GLenum, pname: GLenum, param: GLint) void;
pub extern "c" fn glTexParameterf(target: GLenum, pname: GLenum, param: GLfloat) void;
pub extern "c" fn glGenerateMipmap(target: GLenum) void;
pub extern "c" fn glActiveTexture(texture: GLenum) void;

// Framebuffers
pub extern "c" fn glGenFramebuffers(n: GLsizei, framebuffers: [*]GLuint) void;
pub extern "c" fn glDeleteFramebuffers(n: GLsizei, framebuffers: [*]const GLuint) void;
pub extern "c" fn glBindFramebuffer(target: GLenum, framebuffer: GLuint) void;
pub extern "c" fn glFramebufferTexture2D(
    target: GLenum,
    attachment: GLenum,
    textarget: GLenum,
    texture: GLuint,
    level: GLint,
) void;
pub extern "c" fn glCheckFramebufferStatus(target: GLenum) GLenum;

// Renderbuffers
pub extern "c" fn glGenRenderbuffers(n: GLsizei, renderbuffers: [*]GLuint) void;
pub extern "c" fn glDeleteRenderbuffers(n: GLsizei, renderbuffers: [*]const GLuint) void;
pub extern "c" fn glBindRenderbuffer(target: GLenum, renderbuffer: GLuint) void;
pub extern "c" fn glRenderbufferStorage(target: GLenum, internalformat: GLenum, width: GLsizei, height: GLsizei) void;
pub extern "c" fn glFramebufferRenderbuffer(target: GLenum, attachment: GLenum, renderbuffertarget: GLenum, renderbuffer: GLuint) void;

// ============================================================================
// Additional constants for texture slots
// ============================================================================

pub const GL_TEXTURE0: GLenum = 0x84C0;
pub const GL_TEXTURE1: GLenum = 0x84C1;
pub const GL_TEXTURE2: GLenum = 0x84C2;
pub const GL_TEXTURE3: GLenum = 0x84C3;
pub const GL_TEXTURE4: GLenum = 0x84C4;
pub const GL_TEXTURE5: GLenum = 0x84C5;
pub const GL_TEXTURE6: GLenum = 0x84C6;
pub const GL_TEXTURE7: GLenum = 0x84C7;
pub const GL_TEXTURE8: GLenum = 0x84C8;
pub const GL_TEXTURE9: GLenum = 0x84C9;
pub const GL_TEXTURE10: GLenum = 0x84CA;
pub const GL_TEXTURE11: GLenum = 0x84CB;
pub const GL_TEXTURE12: GLenum = 0x84CC;
pub const GL_TEXTURE13: GLenum = 0x84CD;
pub const GL_TEXTURE14: GLenum = 0x84CE;
pub const GL_TEXTURE15: GLenum = 0x84CF;

// ============================================================================
// Helper Functions
// ============================================================================

/// Check for OpenGL errors and return error string
pub fn checkError() ?[]const u8 {
    const err = glGetError();
    return switch (err) {
        GL_NO_ERROR => null,
        GL_INVALID_ENUM => "GL_INVALID_ENUM",
        GL_INVALID_VALUE => "GL_INVALID_VALUE",
        GL_INVALID_OPERATION => "GL_INVALID_OPERATION",
        GL_OUT_OF_MEMORY => "GL_OUT_OF_MEMORY",
        else => "UNKNOWN_ERROR",
    };
}

/// Generate a single buffer
pub fn genBuffer() GLuint {
    var buffer: GLuint = undefined;
    glGenBuffers(1, &buffer);
    return buffer;
}

/// Delete a single buffer
pub fn deleteBuffer(buffer: GLuint) void {
    glDeleteBuffers(1, &buffer);
}

/// Generate a single vertex array
pub fn genVertexArray() GLuint {
    var vao: GLuint = undefined;
    glGenVertexArrays(1, &vao);
    return vao;
}

/// Delete a single vertex array
pub fn deleteVertexArray(vao: GLuint) void {
    glDeleteVertexArrays(1, &vao);
}

/// Generate a single texture
pub fn genTexture() GLuint {
    var texture: GLuint = undefined;
    glGenTextures(1, &texture);
    return texture;
}

/// Delete a single texture
pub fn deleteTexture(texture: GLuint) void {
    glDeleteTextures(1, &texture);
}

/// Generate a single framebuffer
pub fn genFramebuffer() GLuint {
    var fbo: GLuint = undefined;
    glGenFramebuffers(1, &fbo);
    return fbo;
}

/// Delete a single framebuffer
pub fn deleteFramebuffer(fbo: GLuint) void {
    glDeleteFramebuffers(1, &fbo);
}

/// Compile shader and return handle, or error
pub fn compileShader(source: [:0]const u8, shader_type: GLenum) !GLuint {
    const shader = glCreateShader(shader_type);
    if (shader == 0) return error.ShaderCreationFailed;

    const sources = [_][*:0]const u8{source.ptr};
    glShaderSource(shader, 1, &sources, null);
    glCompileShader(shader);

    var success: GLint = undefined;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &success);
    if (success == 0) {
        var info_log: [512]u8 = undefined;
        glGetShaderInfoLog(shader, 512, null, &info_log);
        glDeleteShader(shader);
        return error.ShaderCompilationFailed;
    }

    return shader;
}

/// Link program from vertex and fragment shaders
pub fn linkProgram(vertex_shader: GLuint, fragment_shader: GLuint) !GLuint {
    const program = glCreateProgram();
    if (program == 0) return error.ProgramCreationFailed;

    glAttachShader(program, vertex_shader);
    glAttachShader(program, fragment_shader);
    glLinkProgram(program);

    var success: GLint = undefined;
    glGetProgramiv(program, GL_LINK_STATUS, &success);
    if (success == 0) {
        var info_log: [512]u8 = undefined;
        glGetProgramInfoLog(program, 512, null, &info_log);
        glDeleteProgram(program);
        return error.ProgramLinkFailed;
    }

    return program;
}

// ============================================================================
// Tests
// ============================================================================

test "OpenGL constants" {
    const testing = std.testing;

    // Verify some key constants
    try testing.expectEqual(@as(GLenum, 0x0004), GL_TRIANGLES);
    try testing.expectEqual(@as(GLenum, 0x8892), GL_ARRAY_BUFFER);
    try testing.expectEqual(@as(GLenum, 0x88E4), GL_STATIC_DRAW);
}

test "OpenGL type sizes" {
    const testing = std.testing;

    // Verify type sizes match OpenGL spec
    try testing.expectEqual(@as(usize, 4), @sizeOf(GLuint));
    try testing.expectEqual(@as(usize, 4), @sizeOf(GLint));
    try testing.expectEqual(@as(usize, 4), @sizeOf(GLfloat));
    try testing.expectEqual(@as(usize, 1), @sizeOf(GLboolean));
}
