// Shader system for Metal renderer
// Part of Home stdlib - Graphics backend
// Manages shader compilation and pipeline states

const std = @import("std");
const Allocator = std.mem.Allocator;

// Shader types
pub const ShaderType = enum {
    Vertex,
    Fragment,
    Compute,
};

// Shader stage
pub const ShaderStage = struct {
    shader_type: ShaderType,
    source: []const u8,
    entry_point: []const u8,

    pub fn init(shader_type: ShaderType, source: []const u8, entry_point: []const u8) ShaderStage {
        return .{
            .shader_type = shader_type,
            .source = source,
            .entry_point = entry_point,
        };
    }
};

// Vertex attribute description
pub const VertexAttribute = struct {
    location: u32,
    format: VertexFormat,
    offset: u32,

    pub fn init(location: u32, format: VertexFormat, offset: u32) VertexAttribute {
        return .{
            .location = location,
            .format = format,
            .offset = offset,
        };
    }
};

// Vertex format types
pub const VertexFormat = enum {
    Float,
    Float2,
    Float3,
    Float4,
    UChar4Normalized,

    pub fn getSize(self: VertexFormat) u32 {
        return switch (self) {
            .Float => 4,
            .Float2 => 8,
            .Float3 => 12,
            .Float4 => 16,
            .UChar4Normalized => 4,
        };
    }
};

// Blend mode
pub const BlendMode = enum {
    Opaque,
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

// Depth comparison
pub const DepthComparison = enum {
    Never,
    Less,
    Equal,
    LessEqual,
    Greater,
    NotEqual,
    GreaterEqual,
    Always,
};

// Pipeline state configuration
pub const PipelineConfig = struct {
    vertex_attributes: []const VertexAttribute,
    vertex_stride: u32,
    blend_mode: BlendMode,
    cull_mode: CullMode,
    depth_test_enabled: bool,
    depth_write_enabled: bool,
    depth_comparison: DepthComparison,

    pub fn init() PipelineConfig {
        return .{
            .vertex_attributes = &[_]VertexAttribute{},
            .vertex_stride = 0,
            .blend_mode = .Opaque,
            .cull_mode = .Back,
            .depth_test_enabled = true,
            .depth_write_enabled = true,
            .depth_comparison = .Less,
        };
    }
};

// Shader program
pub const ShaderProgram = struct {
    allocator: Allocator,
    vertex_shader: ShaderStage,
    fragment_shader: ShaderStage,
    config: PipelineConfig,
    is_compiled: bool,

    pub fn init(allocator: Allocator, vertex: ShaderStage, fragment: ShaderStage, config: PipelineConfig) ShaderProgram {
        return .{
            .allocator = allocator,
            .vertex_shader = vertex,
            .fragment_shader = fragment,
            .config = config,
            .is_compiled = false,
        };
    }

    pub fn compile(self: *ShaderProgram) !void {
        // In real implementation, this would:
        // 1. Compile Metal shader source
        // 2. Create pipeline state
        // 3. Validate attributes
        self.is_compiled = true;
    }

    pub fn isValid(self: ShaderProgram) bool {
        return self.is_compiled;
    }
};

// Shader library - manages common shaders
pub const ShaderLibrary = struct {
    allocator: Allocator,
    programs: std.StringHashMap(ShaderProgram),

    pub fn init(allocator: Allocator) ShaderLibrary {
        return .{
            .allocator = allocator,
            .programs = std.StringHashMap(ShaderProgram).init(allocator),
        };
    }

    pub fn deinit(self: *ShaderLibrary) void {
        self.programs.deinit();
    }

    pub fn addProgram(self: *ShaderLibrary, name: []const u8, program: ShaderProgram) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        try self.programs.put(owned_name, program);
    }

    pub fn getProgram(self: *ShaderLibrary, name: []const u8) ?*ShaderProgram {
        return self.programs.getPtr(name);
    }

    pub fn hasProgram(self: ShaderLibrary, name: []const u8) bool {
        return self.programs.contains(name);
    }

    pub fn compileAll(self: *ShaderLibrary) !void {
        var iter = self.programs.valueIterator();
        while (iter.next()) |program| {
            try program.compile();
        }
    }
};

// Built-in shader sources

pub const basic_vertex_shader =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct VertexIn {
    \\    float3 position [[attribute(0)]];
    \\    float3 normal [[attribute(1)]];
    \\    float2 texCoord [[attribute(2)]];
    \\};
    \\
    \\struct VertexOut {
    \\    float4 position [[position]];
    \\    float3 worldNormal;
    \\    float2 texCoord;
    \\};
    \\
    \\struct Uniforms {
    \\    float4x4 modelMatrix;
    \\    float4x4 viewMatrix;
    \\    float4x4 projectionMatrix;
    \\};
    \\
    \\vertex VertexOut basic_vertex(
    \\    VertexIn in [[stage_in]],
    \\    constant Uniforms& uniforms [[buffer(1)]]
    \\) {
    \\    VertexOut out;
    \\    float4x4 mvp = uniforms.projectionMatrix * uniforms.viewMatrix * uniforms.modelMatrix;
    \\    out.position = mvp * float4(in.position, 1.0);
    \\    out.worldNormal = (uniforms.modelMatrix * float4(in.normal, 0.0)).xyz;
    \\    out.texCoord = in.texCoord;
    \\    return out;
    \\}
;

pub const basic_fragment_shader =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct VertexOut {
    \\    float4 position [[position]];
    \\    float3 worldNormal;
    \\    float2 texCoord;
    \\};
    \\
    \\struct MaterialUniforms {
    \\    float4 diffuseColor;
    \\    float4 specularColor;
    \\    float shininess;
    \\};
    \\
    \\fragment float4 basic_fragment(
    \\    VertexOut in [[stage_in]],
    \\    constant MaterialUniforms& material [[buffer(0)]],
    \\    texture2d<float> diffuseTexture [[texture(0)]],
    \\    sampler textureSampler [[sampler(0)]]
    \\) {
    \\    float3 normal = normalize(in.worldNormal);
    \\    float3 lightDir = normalize(float3(1.0, 1.0, 1.0));
    \\    float ndotl = max(dot(normal, lightDir), 0.0);
    \\
    \\    float4 texColor = diffuseTexture.sample(textureSampler, in.texCoord);
    \\    float4 diffuse = material.diffuseColor * texColor;
    \\
    \\    float4 finalColor = diffuse * ndotl;
    \\    finalColor.a = diffuse.a;
    \\
    \\    return finalColor;
    \\}
;

pub const particle_vertex_shader =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct ParticleVertexIn {
    \\    float3 position [[attribute(0)]];
    \\    float2 texCoord [[attribute(1)]];
    \\};
    \\
    \\struct ParticleVertexOut {
    \\    float4 position [[position]];
    \\    float2 texCoord;
    \\    float4 color;
    \\};
    \\
    \\struct ParticleUniforms {
    \\    float4x4 viewProjectionMatrix;
    \\    float3 particlePosition;
    \\    float particleSize;
    \\    float4 particleColor;
    \\};
    \\
    \\vertex ParticleVertexOut particle_vertex(
    \\    ParticleVertexIn in [[stage_in]],
    \\    constant ParticleUniforms& uniforms [[buffer(1)]]
    \\) {
    \\    ParticleVertexOut out;
    \\    float3 worldPos = uniforms.particlePosition + in.position * uniforms.particleSize;
    \\    out.position = uniforms.viewProjectionMatrix * float4(worldPos, 1.0);
    \\    out.texCoord = in.texCoord;
    \\    out.color = uniforms.particleColor;
    \\    return out;
    \\}
;

pub const particle_fragment_shader =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct ParticleVertexOut {
    \\    float4 position [[position]];
    \\    float2 texCoord;
    \\    float4 color;
    \\};
    \\
    \\fragment float4 particle_fragment(
    \\    ParticleVertexOut in [[stage_in]],
    \\    texture2d<float> particleTexture [[texture(0)]],
    \\    sampler textureSampler [[sampler(0)]]
    \\) {
    \\    float4 texColor = particleTexture.sample(textureSampler, in.texCoord);
    \\    return texColor * in.color;
    \\}
;

pub const terrain_vertex_shader =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct TerrainVertexIn {
    \\    float3 position [[attribute(0)]];
    \\    float3 normal [[attribute(1)]];
    \\    float2 texCoord [[attribute(2)]];
    \\};
    \\
    \\struct TerrainVertexOut {
    \\    float4 position [[position]];
    \\    float3 worldPos;
    \\    float3 worldNormal;
    \\    float2 texCoord;
    \\};
    \\
    \\struct TerrainUniforms {
    \\    float4x4 modelMatrix;
    \\    float4x4 viewMatrix;
    \\    float4x4 projectionMatrix;
    \\};
    \\
    \\vertex TerrainVertexOut terrain_vertex(
    \\    TerrainVertexIn in [[stage_in]],
    \\    constant TerrainUniforms& uniforms [[buffer(1)]]
    \\) {
    \\    TerrainVertexOut out;
    \\    float4 worldPos = uniforms.modelMatrix * float4(in.position, 1.0);
    \\    out.worldPos = worldPos.xyz;
    \\    out.position = uniforms.projectionMatrix * uniforms.viewMatrix * worldPos;
    \\    out.worldNormal = (uniforms.modelMatrix * float4(in.normal, 0.0)).xyz;
    \\    out.texCoord = in.texCoord;
    \\    return out;
    \\}
;

pub const terrain_fragment_shader =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct TerrainVertexOut {
    \\    float4 position [[position]];
    \\    float3 worldPos;
    \\    float3 worldNormal;
    \\    float2 texCoord;
    \\};
    \\
    \\struct TerrainMaterial {
    \\    float3 lightDir;
    \\    float3 lightColor;
    \\    float ambientStrength;
    \\};
    \\
    \\fragment float4 terrain_fragment(
    \\    TerrainVertexOut in [[stage_in]],
    \\    constant TerrainMaterial& material [[buffer(0)]],
    \\    texture2d<float> terrainTexture [[texture(0)]],
    \\    texture2d<float> splatMap [[texture(1)]],
    \\    sampler textureSampler [[sampler(0)]]
    \\) {
    \\    float3 normal = normalize(in.worldNormal);
    \\    float3 lightDir = normalize(material.lightDir);
    \\    float ndotl = max(dot(normal, lightDir), 0.0);
    \\
    \\    float4 texColor = terrainTexture.sample(textureSampler, in.texCoord);
    \\    float3 ambient = material.ambientStrength * material.lightColor;
    \\    float3 diffuse = ndotl * material.lightColor;
    \\
    \\    float3 finalColor = (ambient + diffuse) * texColor.rgb;
    \\    return float4(finalColor, 1.0);
    \\}
;

// Helper to create standard shader programs
pub fn createBasicShaderProgram(allocator: Allocator) !ShaderProgram {
    const vertex = ShaderStage.init(.Vertex, basic_vertex_shader, "basic_vertex");
    const fragment = ShaderStage.init(.Fragment, basic_fragment_shader, "basic_fragment");

    var config = PipelineConfig.init();
    const attributes = try allocator.alloc(VertexAttribute, 3);
    attributes[0] = VertexAttribute.init(0, .Float3, 0);
    attributes[1] = VertexAttribute.init(1, .Float3, 12);
    attributes[2] = VertexAttribute.init(2, .Float2, 24);
    config.vertex_attributes = attributes;
    config.vertex_stride = 32;

    var program = ShaderProgram.init(allocator, vertex, fragment, config);
    try program.compile();
    return program;
}

pub fn createParticleShaderProgram(allocator: Allocator) !ShaderProgram {
    const vertex = ShaderStage.init(.Vertex, particle_vertex_shader, "particle_vertex");
    const fragment = ShaderStage.init(.Fragment, particle_fragment_shader, "particle_fragment");

    var config = PipelineConfig.init();
    const attributes = try allocator.alloc(VertexAttribute, 2);
    attributes[0] = VertexAttribute.init(0, .Float3, 0);
    attributes[1] = VertexAttribute.init(1, .Float2, 12);
    config.vertex_attributes = attributes;
    config.vertex_stride = 20;
    config.blend_mode = .Additive;
    config.depth_write_enabled = false;

    var program = ShaderProgram.init(allocator, vertex, fragment, config);
    try program.compile();
    return program;
}

pub fn createTerrainShaderProgram(allocator: Allocator) !ShaderProgram {
    const vertex = ShaderStage.init(.Vertex, terrain_vertex_shader, "terrain_vertex");
    const fragment = ShaderStage.init(.Fragment, terrain_fragment_shader, "terrain_fragment");

    var config = PipelineConfig.init();
    const attributes = try allocator.alloc(VertexAttribute, 3);
    attributes[0] = VertexAttribute.init(0, .Float3, 0);
    attributes[1] = VertexAttribute.init(1, .Float3, 12);
    attributes[2] = VertexAttribute.init(2, .Float2, 24);
    config.vertex_attributes = attributes;
    config.vertex_stride = 32;

    var program = ShaderProgram.init(allocator, vertex, fragment, config);
    try program.compile();
    return program;
}

// Tests
test "ShaderStage: init" {
    const stage = ShaderStage.init(.Vertex, "test shader", "main");

    try std.testing.expectEqual(ShaderType.Vertex, stage.shader_type);
    try std.testing.expectEqualStrings("test shader", stage.source);
    try std.testing.expectEqualStrings("main", stage.entry_point);
}

test "VertexFormat: sizes" {
    try std.testing.expectEqual(@as(u32, 4), VertexFormat.Float.getSize());
    try std.testing.expectEqual(@as(u32, 8), VertexFormat.Float2.getSize());
    try std.testing.expectEqual(@as(u32, 12), VertexFormat.Float3.getSize());
    try std.testing.expectEqual(@as(u32, 16), VertexFormat.Float4.getSize());
}

test "VertexAttribute: init" {
    const attr = VertexAttribute.init(0, .Float3, 12);

    try std.testing.expectEqual(@as(u32, 0), attr.location);
    try std.testing.expectEqual(VertexFormat.Float3, attr.format);
    try std.testing.expectEqual(@as(u32, 12), attr.offset);
}

test "PipelineConfig: defaults" {
    const config = PipelineConfig.init();

    try std.testing.expectEqual(BlendMode.Opaque, config.blend_mode);
    try std.testing.expectEqual(CullMode.Back, config.cull_mode);
    try std.testing.expect(config.depth_test_enabled);
    try std.testing.expect(config.depth_write_enabled);
    try std.testing.expectEqual(DepthComparison.Less, config.depth_comparison);
}

test "ShaderProgram: create and compile" {
    const allocator = std.testing.allocator;

    const vertex = ShaderStage.init(.Vertex, basic_vertex_shader, "basic_vertex");
    const fragment = ShaderStage.init(.Fragment, basic_fragment_shader, "basic_fragment");
    const config = PipelineConfig.init();

    var program = ShaderProgram.init(allocator, vertex, fragment, config);
    try std.testing.expect(!program.isValid());

    try program.compile();
    try std.testing.expect(program.isValid());
}

test "ShaderLibrary: add and get programs" {
    const allocator = std.testing.allocator;
    var library = ShaderLibrary.init(allocator);
    defer library.deinit();

    const vertex = ShaderStage.init(.Vertex, basic_vertex_shader, "basic_vertex");
    const fragment = ShaderStage.init(.Fragment, basic_fragment_shader, "basic_fragment");
    const config = PipelineConfig.init();
    const program = ShaderProgram.init(allocator, vertex, fragment, config);

    try library.addProgram("basic", program);
    try std.testing.expect(library.hasProgram("basic"));

    const retrieved = library.getProgram("basic");
    try std.testing.expect(retrieved != null);
}

test "ShaderLibrary: compile all" {
    const allocator = std.testing.allocator;
    var library = ShaderLibrary.init(allocator);
    defer library.deinit();

    const vertex = ShaderStage.init(.Vertex, basic_vertex_shader, "basic_vertex");
    const fragment = ShaderStage.init(.Fragment, basic_fragment_shader, "basic_fragment");
    const config = PipelineConfig.init();
    const program = ShaderProgram.init(allocator, vertex, fragment, config);

    try library.addProgram("test", program);
    try library.compileAll();

    const retrieved = library.getProgram("test");
    try std.testing.expect(retrieved.?.isValid());
}

test "createBasicShaderProgram" {
    const allocator = std.testing.allocator;

    var program = try createBasicShaderProgram(allocator);
    defer allocator.free(program.config.vertex_attributes);

    try std.testing.expect(program.isValid());
    try std.testing.expectEqual(@as(usize, 3), program.config.vertex_attributes.len);
    try std.testing.expectEqual(@as(u32, 32), program.config.vertex_stride);
}

test "createParticleShaderProgram" {
    const allocator = std.testing.allocator;

    var program = try createParticleShaderProgram(allocator);
    defer allocator.free(program.config.vertex_attributes);

    try std.testing.expect(program.isValid());
    try std.testing.expectEqual(BlendMode.Additive, program.config.blend_mode);
    try std.testing.expect(!program.config.depth_write_enabled);
}

test "createTerrainShaderProgram" {
    const allocator = std.testing.allocator;

    var program = try createTerrainShaderProgram(allocator);
    defer allocator.free(program.config.vertex_attributes);

    try std.testing.expect(program.isValid());
    try std.testing.expectEqual(@as(usize, 3), program.config.vertex_attributes.len);
}
