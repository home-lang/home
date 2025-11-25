// Home Video Library - GPU Shader Kernels
// Shader source code for various GPU operations

const std = @import("std");

// ============================================================================
// Shader Source (GLSL/SPIR-V compatible)
// ============================================================================

pub const yuv_to_rgb_shader =
    \\#version 450
    \\
    \\layout(local_size_x = 16, local_size_y = 16) in;
    \\
    \\layout(binding = 0) readonly buffer YPlane { uint8_t y[]; };
    \\layout(binding = 1) readonly buffer UPlane { uint8_t u[]; };
    \\layout(binding = 2) readonly buffer VPlane { uint8_t v[]; };
    \\layout(binding = 3) writeonly buffer Output { uint8_t rgb[]; };
    \\
    \\layout(push_constant) uniform Params {
    \\    uint width;
    \\    uint height;
    \\};
    \\
    \\void main() {
    \\    uvec2 pos = gl_GlobalInvocationID.xy;
    \\    if (pos.x >= width || pos.y >= height) return;
    \\
    \\    uint y_idx = pos.y * width + pos.x;
    \\    uint uv_idx = (pos.y / 2) * (width / 2) + (pos.x / 2);
    \\
    \\    float Y = float(y[y_idx]) / 255.0;
    \\    float U = float(u[uv_idx]) / 255.0 - 0.5;
    \\    float V = float(v[uv_idx]) / 255.0 - 0.5;
    \\
    \\    float R = Y + 1.402 * V;
    \\    float G = Y - 0.344136 * U - 0.714136 * V;
    \\    float B = Y + 1.772 * U;
    \\
    \\    uint rgb_idx = y_idx * 3;
    \\    rgb[rgb_idx + 0] = uint8_t(clamp(R, 0.0, 1.0) * 255.0);
    \\    rgb[rgb_idx + 1] = uint8_t(clamp(G, 0.0, 1.0) * 255.0);
    \\    rgb[rgb_idx + 2] = uint8_t(clamp(B, 0.0, 1.0) * 255.0);
    \\}
;

pub const bilinear_scale_shader =
    \\#version 450
    \\
    \\layout(local_size_x = 16, local_size_y = 16) in;
    \\
    \\layout(binding = 0) readonly buffer Input { uint8_t src[]; };
    \\layout(binding = 1) writeonly buffer Output { uint8_t dst[]; };
    \\
    \\layout(push_constant) uniform Params {
    \\    uint src_width;
    \\    uint src_height;
    \\    uint dst_width;
    \\    uint dst_height;
    \\};
    \\
    \\void main() {
    \\    uvec2 pos = gl_GlobalInvocationID.xy;
    \\    if (pos.x >= dst_width || pos.y >= dst_height) return;
    \\
    \\    float x_ratio = float(src_width) / float(dst_width);
    \\    float y_ratio = float(src_height) / float(dst_height);
    \\
    \\    float src_x = float(pos.x) * x_ratio;
    \\    float src_y = float(pos.y) * y_ratio;
    \\
    \\    uint x1 = uint(floor(src_x));
    \\    uint y1 = uint(floor(src_y));
    \\    uint x2 = min(x1 + 1, src_width - 1);
    \\    uint y2 = min(y1 + 1, src_height - 1);
    \\
    \\    float fx = fract(src_x);
    \\    float fy = fract(src_y);
    \\
    \\    for (uint c = 0; c < 3; c++) {
    \\        float p1 = float(src[(y1 * src_width + x1) * 3 + c]);
    \\        float p2 = float(src[(y1 * src_width + x2) * 3 + c]);
    \\        float p3 = float(src[(y2 * src_width + x1) * 3 + c]);
    \\        float p4 = float(src[(y2 * src_width + x2) * 3 + c]);
    \\
    \\        float val = mix(mix(p1, p2, fx), mix(p3, p4, fx), fy);
    \\        dst[(pos.y * dst_width + pos.x) * 3 + c] = uint8_t(val);
    \\    }
    \\}
;

pub const gaussian_blur_shader =
    \\#version 450
    \\
    \\layout(local_size_x = 16, local_size_y = 16) in;
    \\
    \\layout(binding = 0) readonly buffer Input { uint8_t src[]; };
    \\layout(binding = 1) writeonly buffer Output { uint8_t dst[]; };
    \\
    \\layout(push_constant) uniform Params {
    \\    uint width;
    \\    uint height;
    \\    float sigma;
    \\};
    \\
    \\void main() {
    \\    uvec2 pos = gl_GlobalInvocationID.xy;
    \\    if (pos.x >= width || pos.y >= height) return;
    \\
    \\    const int radius = 3;
    \\    float kernel[7] = float[](0.00598, 0.060626, 0.241843, 0.383103, 0.241843, 0.060626, 0.00598);
    \\
    \\    for (uint c = 0; c < 3; c++) {
    \\        float sum = 0.0;
    \\        for (int dy = -radius; dy <= radius; dy++) {
    \\            for (int dx = -radius; dx <= radius; dx++) {
    \\                int x = clamp(int(pos.x) + dx, 0, int(width) - 1);
    \\                int y = clamp(int(pos.y) + dy, 0, int(height) - 1);
    \\                float weight = kernel[dx + radius] * kernel[dy + radius];
    \\                sum += float(src[(y * int(width) + x) * 3 + c]) * weight;
    \\            }
    \\        }
    \\        dst[(pos.y * width + pos.x) * 3 + c] = uint8_t(sum);
    \\    }
    \\}
;

// ============================================================================
// Metal Shaders (MSL)
// ============================================================================

pub const metal_yuv_to_rgb =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\kernel void yuv_to_rgb(
    \\    const device uint8_t* y [[buffer(0)]],
    \\    const device uint8_t* u [[buffer(1)]],
    \\    const device uint8_t* v [[buffer(2)]],
    \\    device uint8_t* rgb [[buffer(3)]],
    \\    constant uint& width [[buffer(4)]],
    \\    constant uint& height [[buffer(5)]],
    \\    uint2 gid [[thread_position_in_grid]])
    \\{
    \\    if (gid.x >= width || gid.y >= height) return;
    \\
    \\    uint y_idx = gid.y * width + gid.x;
    \\    uint uv_idx = (gid.y / 2) * (width / 2) + (gid.x / 2);
    \\
    \\    float Y = float(y[y_idx]) / 255.0;
    \\    float U = float(u[uv_idx]) / 255.0 - 0.5;
    \\    float V = float(v[uv_idx]) / 255.0 - 0.5;
    \\
    \\    float R = Y + 1.402 * V;
    \\    float G = Y - 0.344136 * U - 0.714136 * V;
    \\    float B = Y + 1.772 * U;
    \\
    \\    uint rgb_idx = y_idx * 3;
    \\    rgb[rgb_idx + 0] = uint8_t(clamp(R, 0.0f, 1.0f) * 255.0);
    \\    rgb[rgb_idx + 1] = uint8_t(clamp(G, 0.0f, 1.0f) * 255.0);
    \\    rgb[rgb_idx + 2] = uint8_t(clamp(B, 0.0f, 1.0f) * 255.0);
    \\}
;

// ============================================================================
// CUDA Kernels
// ============================================================================

pub const cuda_yuv_to_rgb =
    \\__global__ void yuv_to_rgb_kernel(
    \\    const uint8_t* __restrict__ y,
    \\    const uint8_t* __restrict__ u,
    \\    const uint8_t* __restrict__ v,
    \\    uint8_t* __restrict__ rgb,
    \\    unsigned int width,
    \\    unsigned int height)
    \\{
    \\    unsigned int x = blockIdx.x * blockDim.x + threadIdx.x;
    \\    unsigned int y_pos = blockIdx.y * blockDim.y + threadIdx.y;
    \\
    \\    if (x >= width || y_pos >= height) return;
    \\
    \\    unsigned int y_idx = y_pos * width + x;
    \\    unsigned int uv_idx = (y_pos / 2) * (width / 2) + (x / 2);
    \\
    \\    float Y = (float)y[y_idx] / 255.0f;
    \\    float U = (float)u[uv_idx] / 255.0f - 0.5f;
    \\    float V = (float)v[uv_idx] / 255.0f - 0.5f;
    \\
    \\    float R = Y + 1.402f * V;
    \\    float G = Y - 0.344136f * U - 0.714136f * V;
    \\    float B = Y + 1.772f * U;
    \\
    \\    unsigned int rgb_idx = y_idx * 3;
    \\    rgb[rgb_idx + 0] = (uint8_t)fminf(fmaxf(R, 0.0f), 1.0f) * 255.0f;
    \\    rgb[rgb_idx + 1] = (uint8_t)fminf(fmaxf(G, 0.0f), 1.0f) * 255.0f;
    \\    rgb[rgb_idx + 2] = (uint8_t)fminf(fmaxf(B, 0.0f), 1.0f) * 255.0f;
    \\}
;
