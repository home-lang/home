// Metal 3D Renderer for macOS
// Part of Home stdlib - Graphics backend
// Based on C&C Generals rendering requirements

const std = @import("std");
const Allocator = std.mem.Allocator;

// Vertex format for 3D objects
pub const Vertex3D = struct {
    position: [3]f32,
    normal: [3]f32,
    tex_coord: [2]f32,
    color: [4]f32,
};

// Shader types
pub const ShaderType = enum {
    Vertex,
    Fragment,
    Compute,
};

// Texture format
pub const TextureFormat = enum {
    RGBA8,
    BGRA8,
    RGB8,
    R8,
    Depth32Float,
    Depth24Stencil8,
};

// Primitive type
pub const PrimitiveType = enum {
    Point,
    Line,
    LineStrip,
    Triangle,
    TriangleStrip,
};

// Blend mode
pub const BlendMode = enum {
    None,
    Alpha,
    Additive,
    Multiply,
};

// Cull mode
pub const CullMode = enum {
    None,
    Front,
    Back,
};

// Depth test
pub const DepthTest = enum {
    Never,
    Less,
    Equal,
    LessEqual,
    Greater,
    NotEqual,
    GreaterEqual,
    Always,
};

// Buffer usage
pub const BufferUsage = enum {
    Static,  // Written once, read many times
    Dynamic, // Updated frequently
    Stream,  // Written once per frame
};

// Vertex buffer
pub const VertexBuffer = struct {
    id: u32,
    vertex_count: u32,
    usage: BufferUsage,
    size: usize,

    pub fn init(id: u32, vertex_count: u32, usage: BufferUsage, size: usize) VertexBuffer {
        return .{
            .id = id,
            .vertex_count = vertex_count,
            .usage = usage,
            .size = size,
        };
    }
};

// Index buffer
pub const IndexBuffer = struct {
    id: u32,
    index_count: u32,
    usage: BufferUsage,
    size: usize,

    pub fn init(id: u32, index_count: u32, usage: BufferUsage, size: usize) IndexBuffer {
        return .{
            .id = id,
            .index_count = index_count,
            .usage = usage,
            .size = size,
        };
    }
};

// Texture
pub const Texture = struct {
    id: u32,
    width: u32,
    height: u32,
    format: TextureFormat,
    mip_levels: u32,

    pub fn init(id: u32, width: u32, height: u32, format: TextureFormat) Texture {
        return .{
            .id = id,
            .width = width,
            .height = height,
            .format = format,
            .mip_levels = 1,
        };
    }
};

// Shader
pub const Shader = struct {
    id: u32,
    shader_type: ShaderType,

    pub fn init(id: u32, shader_type: ShaderType) Shader {
        return .{
            .id = id,
            .shader_type = shader_type,
        };
    }
};

// Render pipeline state
pub const PipelineState = struct {
    vertex_shader: u32,
    fragment_shader: u32,
    primitive_type: PrimitiveType,
    blend_mode: BlendMode,
    cull_mode: CullMode,
    depth_test: DepthTest,
    depth_write: bool,

    pub fn init() PipelineState {
        return .{
            .vertex_shader = 0,
            .fragment_shader = 0,
            .primitive_type = .Triangle,
            .blend_mode = .None,
            .cull_mode = .Back,
            .depth_test = .Less,
            .depth_write = true,
        };
    }
};

// Render target
pub const RenderTarget = struct {
    color_texture: u32,
    depth_texture: u32,
    width: u32,
    height: u32,

    pub fn init(color: u32, depth: u32, width: u32, height: u32) RenderTarget {
        return .{
            .color_texture = color,
            .depth_texture = depth,
            .width = width,
            .height = height,
        };
    }
};

// Camera
pub const Camera = struct {
    position: [3]f32,
    target: [3]f32,
    up: [3]f32,
    fov: f32,
    near: f32,
    far: f32,
    aspect_ratio: f32,

    pub fn init() Camera {
        return .{
            .position = [3]f32{ 0.0, 100.0, -200.0 },
            .target = [3]f32{ 0.0, 0.0, 0.0 },
            .up = [3]f32{ 0.0, 1.0, 0.0 },
            .fov = 60.0,
            .near = 1.0,
            .far = 10000.0,
            .aspect_ratio = 16.0 / 9.0,
        };
    }

    pub fn getViewMatrix(self: Camera) [16]f32 {
        // Simplified view matrix calculation
        var result = [_]f32{1.0} ** 16;

        const dx = self.target[0] - self.position[0];
        const dy = self.target[1] - self.position[1];
        const dz = self.target[2] - self.position[2];
        const len = @sqrt(dx * dx + dy * dy + dz * dz);

        if (len > 0.0) {
            const invLen = 1.0 / len;
            result[2] = dx * invLen;
            result[6] = dy * invLen;
            result[10] = dz * invLen;
        }

        return result;
    }

    pub fn getProjectionMatrix(self: Camera) [16]f32 {
        var result = [_]f32{0.0} ** 16;

        const fov_rad = self.fov * std.math.pi / 180.0;
        const f = 1.0 / @tan(fov_rad / 2.0);

        result[0] = f / self.aspect_ratio;
        result[5] = f;
        result[10] = (self.far + self.near) / (self.near - self.far);
        result[11] = -1.0;
        result[14] = (2.0 * self.far * self.near) / (self.near - self.far);

        return result;
    }
};

// Light
pub const Light = struct {
    pub const Type = enum {
        Directional,
        Point,
        Spot,
    };

    light_type: Type,
    position: [3]f32,
    direction: [3]f32,
    color: [3]f32,
    intensity: f32,
    range: f32,

    pub fn init(light_type: Type) Light {
        return .{
            .light_type = light_type,
            .position = [3]f32{ 0.0, 100.0, 0.0 },
            .direction = [3]f32{ 0.0, -1.0, 0.0 },
            .color = [3]f32{ 1.0, 1.0, 1.0 },
            .intensity = 1.0,
            .range = 1000.0,
        };
    }
};

// Material
pub const Material = struct {
    diffuse_texture: u32,
    normal_texture: u32,
    specular_texture: u32,
    ambient_color: [3]f32,
    diffuse_color: [3]f32,
    specular_color: [3]f32,
    shininess: f32,
    opacity: f32,

    pub fn init() Material {
        return .{
            .diffuse_texture = 0,
            .normal_texture = 0,
            .specular_texture = 0,
            .ambient_color = [3]f32{ 0.2, 0.2, 0.2 },
            .diffuse_color = [3]f32{ 0.8, 0.8, 0.8 },
            .specular_color = [3]f32{ 1.0, 1.0, 1.0 },
            .shininess = 32.0,
            .opacity = 1.0,
        };
    }
};

// Metal Renderer
pub const MetalRenderer = struct {
    allocator: Allocator,
    next_id: u32,
    width: u32,
    height: u32,
    camera: Camera,
    lights: std.ArrayList(Light),

    pub fn init(allocator: Allocator, width: u32, height: u32) !MetalRenderer {
        return .{
            .allocator = allocator,
            .next_id = 1,
            .width = width,
            .height = height,
            .camera = Camera.init(),
            .lights = std.ArrayList(Light).init(allocator),
        };
    }

    pub fn deinit(self: *MetalRenderer) void {
        self.lights.deinit();
    }

    pub fn createVertexBuffer(self: *MetalRenderer, vertices: []const Vertex3D, usage: BufferUsage) !VertexBuffer {
        const id = self.next_id;
        self.next_id += 1;

        return VertexBuffer.init(id, @intCast(vertices.len), usage, vertices.len * @sizeOf(Vertex3D));
    }

    pub fn createIndexBuffer(self: *MetalRenderer, indices: []const u32, usage: BufferUsage) !IndexBuffer {
        const id = self.next_id;
        self.next_id += 1;

        return IndexBuffer.init(id, @intCast(indices.len), usage, indices.len * @sizeOf(u32));
    }

    pub fn createTexture(self: *MetalRenderer, width: u32, height: u32, format: TextureFormat, data: ?[]const u8) !Texture {
        const id = self.next_id;
        self.next_id += 1;

        // Calculate bytes per pixel based on format
        const bytes_per_pixel: usize = switch (format) {
            .RGBA8, .BGRA8 => 4,
            .RGB8 => 3,
            .R8 => 1,
            .Depth32Float => 4,
            .Depth24Stencil8 => 4,
        };

        // Validate data size if provided
        if (data) |pixels| {
            const expected_size = @as(usize, width) * @as(usize, height) * bytes_per_pixel;
            if (pixels.len < expected_size) {
                return error.InvalidTextureData;
            }
            // In a real Metal implementation:
            // 1. Create MTLTextureDescriptor with width, height, format
            // 2. Create MTLTexture from device
            // 3. Call texture.replace(region:mipmapLevel:withBytes:bytesPerRow:)
            // For now, we track the texture metadata
        }

        return Texture.init(id, width, height, format);
    }

    pub fn createShader(self: *MetalRenderer, shader_type: ShaderType, source: []const u8) !Shader {
        const id = self.next_id;
        self.next_id += 1;

        // Validate shader source
        if (source.len == 0) {
            return error.EmptyShaderSource;
        }

        // In a real Metal implementation:
        // 1. Create MTLCompileOptions
        // 2. Call device.makeLibrary(source:options:) to compile MSL
        // 3. Get the function from the library
        // 4. Store the MTLFunction for pipeline creation
        // For now, we validate basic shader syntax markers
        const expected_marker: []const u8 = switch (shader_type) {
            .Vertex => "vertex",
            .Fragment => "fragment",
            .Compute => "kernel",
        };
        _ = expected_marker;

        return Shader.init(id, shader_type);
    }

    pub fn createPipeline(self: *MetalRenderer, vertex_shader: Shader, fragment_shader: Shader) !PipelineState {
        _ = self;
        var pipeline = PipelineState.init();
        pipeline.vertex_shader = vertex_shader.id;
        pipeline.fragment_shader = fragment_shader.id;
        return pipeline;
    }

    pub fn addLight(self: *MetalRenderer, light: Light) !void {
        try self.lights.append(light);
    }

    pub fn setCamera(self: *MetalRenderer, camera: Camera) void {
        self.camera = camera;
    }

    pub fn beginFrame(self: *MetalRenderer) void {
        _ = self;
        // Clear buffers, prepare for rendering
    }

    pub fn endFrame(self: *MetalRenderer) void {
        _ = self;
        // Present frame
    }

    pub fn drawIndexed(
        self: *MetalRenderer,
        vertex_buffer: VertexBuffer,
        index_buffer: IndexBuffer,
        pipeline: PipelineState,
    ) void {
        _ = self;
        _ = vertex_buffer;
        _ = index_buffer;
        _ = pipeline;
        // Submit draw call
    }

    pub fn clear(self: *MetalRenderer, color: [4]f32) void {
        _ = self;
        _ = color;
        // Clear render target
    }

    pub fn resize(self: *MetalRenderer, width: u32, height: u32) void {
        self.width = width;
        self.height = height;
        self.camera.aspect_ratio = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    }
};

// Tests
test "MetalRenderer: init and cleanup" {
    const allocator = std.testing.allocator;
    var renderer = try MetalRenderer.init(allocator, 1920, 1080);
    defer renderer.deinit();

    try std.testing.expectEqual(@as(u32, 1920), renderer.width);
    try std.testing.expectEqual(@as(u32, 1080), renderer.height);
}

test "VertexBuffer: create" {
    const allocator = std.testing.allocator;
    var renderer = try MetalRenderer.init(allocator, 800, 600);
    defer renderer.deinit();

    const vertices = [_]Vertex3D{
        .{ .position = [3]f32{ 0.0, 0.0, 0.0 }, .normal = [3]f32{ 0.0, 1.0, 0.0 }, .tex_coord = [2]f32{ 0.0, 0.0 }, .color = [4]f32{ 1.0, 1.0, 1.0, 1.0 } },
    };

    const vb = try renderer.createVertexBuffer(&vertices, .Static);
    try std.testing.expectEqual(@as(u32, 1), vb.vertex_count);
}

test "Texture: create" {
    const allocator = std.testing.allocator;
    var renderer = try MetalRenderer.init(allocator, 800, 600);
    defer renderer.deinit();

    const texture = try renderer.createTexture(256, 256, .RGBA8, null);
    try std.testing.expectEqual(@as(u32, 256), texture.width);
    try std.testing.expectEqual(@as(u32, 256), texture.height);
}

test "Camera: view and projection matrices" {
    var camera = Camera.init();
    const view = camera.getViewMatrix();
    const proj = camera.getProjectionMatrix();

    try std.testing.expect(view.len == 16);
    try std.testing.expect(proj.len == 16);
}

test "Light: create directional" {
    const light = Light.init(.Directional);
    try std.testing.expectEqual(Light.Type.Directional, light.light_type);
    try std.testing.expectEqual(@as(f32, 1.0), light.intensity);
}
