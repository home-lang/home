// W3D Model Loader for C&C Generals
// Parses Westwood 3D binary format and prepares for GPU rendering
//
// This loader reads actual .W3D files from disk and creates
// GPU-ready mesh data for OpenGL/Metal rendering.

const std = @import("std");
const Io = std.Io;

// W3D Chunk Types (from Westwood/EA W3D format specification)
// Top-level container chunks
const W3D_CHUNK_MESH: u32 = 0x00000000; // Mesh container
const W3D_CHUNK_HIERARCHY: u32 = 0x00000100; // Hierarchy container
const W3D_CHUNK_ANIMATION: u32 = 0x00000200; // Animation container
const W3D_CHUNK_COMPRESSED_ANIMATION: u32 = 0x00000280;
const W3D_CHUNK_MORPH_ANIMATION: u32 = 0x000002C0;
const W3D_CHUNK_HMODEL: u32 = 0x00000300; // Skinned model container
const W3D_CHUNK_LODMODEL: u32 = 0x00000400;
const W3D_CHUNK_COLLECTION: u32 = 0x00000420;
const W3D_CHUNK_POINTS: u32 = 0x00000440;
const W3D_CHUNK_LIGHT: u32 = 0x00000460;
const W3D_CHUNK_EMITTER: u32 = 0x00000500;
const W3D_CHUNK_AGGREGATE: u32 = 0x00000600;
const W3D_CHUNK_HLOD: u32 = 0x00000700; // Hierarchical LOD
const W3D_CHUNK_BOX: u32 = 0x00000740;

// Mesh sub-chunks
const W3D_CHUNK_MESH_HEADER3: u32 = 0x0000001F; // Mesh header (version 3)
const W3D_CHUNK_VERTICES: u32 = 0x00000002;
const W3D_CHUNK_VERTEX_NORMALS: u32 = 0x00000003;
const W3D_CHUNK_MESH_USER_TEXT: u32 = 0x0000000C;
const W3D_CHUNK_VERTEX_INFLUENCES: u32 = 0x0000000E;
const W3D_CHUNK_TRIANGLES: u32 = 0x00000020;
const W3D_CHUNK_VERTEX_SHADE_INDICES: u32 = 0x00000022;
const W3D_CHUNK_PRELIT_UNLIT: u32 = 0x00000023;
const W3D_CHUNK_PRELIT_VERTEX: u32 = 0x00000024;
const W3D_CHUNK_PRELIT_LIGHTMAP_MULTI_PASS: u32 = 0x00000025;
const W3D_CHUNK_PRELIT_LIGHTMAP_MULTI_TEXTURE: u32 = 0x00000026;
const W3D_CHUNK_MATERIAL_INFO: u32 = 0x00000028;
const W3D_CHUNK_SHADERS: u32 = 0x00000029;
const W3D_CHUNK_VERTEX_MATERIALS: u32 = 0x0000002A;
const W3D_CHUNK_VERTEX_MATERIAL: u32 = 0x0000002B;
const W3D_CHUNK_TEXTURES: u32 = 0x00000030;
const W3D_CHUNK_TEXTURE: u32 = 0x00000031;
const W3D_CHUNK_TEXTURE_NAME: u32 = 0x00000032;
const W3D_CHUNK_MATERIAL_PASS: u32 = 0x00000038;
const W3D_CHUNK_STAGE_TEXCOORDS: u32 = 0x00000048;
const W3D_CHUNK_PER_FACE_TEXCOORD_IDS: u32 = 0x00000049;
const W3D_CHUNK_SHADER_IDS: u32 = 0x0000004A;

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn init() Vec3 {
        return .{ .x = 0, .y = 0, .z = 0 };
    }
};

pub const Vec2 = struct {
    u: f32,
    v: f32,

    pub fn init() Vec2 {
        return .{ .u = 0, .v = 0 };
    }
};

pub const W3DVertex = struct {
    position: Vec3,
    normal: Vec3,
    texcoord: Vec2,
};

pub const W3DTriangle = struct {
    indices: [3]u32,
    normal: Vec3,
};

pub const W3DMesh = struct {
    name: [16]u8,
    vertices: []W3DVertex,
    triangles: []W3DTriangle,
    texture_name: [64]u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *W3DMesh) void {
        self.allocator.free(self.vertices);
        self.allocator.free(self.triangles);
    }
};

pub const W3DModel = struct {
    name: [64]u8,
    meshes: []W3DMesh,
    allocator: std.mem.Allocator,
    loaded: bool,

    pub fn init(allocator: std.mem.Allocator) W3DModel {
        return .{
            .name = std.mem.zeroes([64]u8),
            .meshes = &.{},
            .allocator = allocator,
            .loaded = false,
        };
    }

    pub fn deinit(self: *W3DModel) void {
        for (self.meshes) |*mesh| {
            mesh.deinit();
        }
        self.allocator.free(self.meshes);
    }
};

pub const W3DLoader = struct {
    allocator: std.mem.Allocator,
    models: std.ArrayList(W3DModel),
    model_paths: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) W3DLoader {
        var loader = W3DLoader{
            .allocator = allocator,
            .models = .{},
            .model_paths = .{},
        };
        // Pre-allocate space to prevent reallocation invalidating pointers
        loader.models.ensureTotalCapacity(allocator, 32) catch {};
        loader.model_paths.ensureTotalCapacity(allocator, 32) catch {};
        return loader;
    }

    pub fn deinit(self: *W3DLoader) void {
        for (self.models.items) |*model| {
            model.deinit();
        }
        self.models.deinit(self.allocator);
        for (self.model_paths.items) |path| {
            self.allocator.free(path);
        }
        self.model_paths.deinit(self.allocator);
    }

    pub fn load(self: *W3DLoader, io: Io, file_path: []const u8) !?*W3DModel {
        // Check if already loaded
        for (self.model_paths.items, 0..) |path, i| {
            if (std.mem.eql(u8, path, file_path)) {
                return &self.models.items[i];
            }
        }

        // Read file
        std.debug.print("  Opening: {s}...", .{file_path});
        const file = Io.Dir.openFileAbsolute(io, file_path, .{}) catch |err| {
            std.debug.print(" FAILED ({any})\n", .{err});
            return null;
        };
        defer file.close(io);

        const file_size = try file.length(io);
        std.debug.print(" ({d} bytes)...", .{file_size});
        if (file_size == 0) {
            std.debug.print(" empty file\n", .{});
            return null;
        }

        const data = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(data);

        // Read entire file into buffer
        const bytes_read = try file.readPositionalAll(io, data, 0);
        if (bytes_read != file_size) {
            std.debug.print(" read error\n", .{});
            return null;
        }

        std.debug.print(" parsing...", .{});
        // Parse
        var model = try self.parseW3D(data);
        model.loaded = true;
        std.debug.print(" done\n", .{});

        // Store
        try self.models.append(self.allocator, model);
        const path_copy = try self.allocator.dupe(u8, file_path);
        try self.model_paths.append(self.allocator, path_copy);

        return &self.models.items[self.models.items.len - 1];
    }

    fn parseW3D(self: *W3DLoader, data: []const u8) !W3DModel {
        var model = W3DModel.init(self.allocator);
        var meshes: std.ArrayList(W3DMesh) = .{};

        // Recursively parse all chunks looking for mesh data
        try self.parseChunks(data, &meshes, 0);

        model.meshes = try meshes.toOwnedSlice(self.allocator);
        return model;
    }

    fn parseChunks(self: *W3DLoader, data: []const u8, meshes: *std.ArrayList(W3DMesh), depth: u32) !void {
        if (depth > 10) return; // Prevent infinite recursion

        var pos: usize = 0;

        while (pos + 8 <= data.len) {
            const chunk_type = std.mem.readInt(u32, data[pos..][0..4], .little);
            const chunk_size_raw = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
            const is_container = (chunk_size_raw & 0x80000000) != 0;
            const chunk_size = chunk_size_raw & 0x7FFFFFFF;
            pos += 8;

            // Sanity check - chunk size should be reasonable
            if (chunk_size > data.len or pos + chunk_size > data.len) break;
            if (chunk_size == 0 and chunk_type != W3D_CHUNK_MESH) {
                // Zero-size non-mesh chunks are likely padding or end markers
                continue;
            }

            const chunk_end = pos + chunk_size;
            const chunk_data = data[pos..chunk_end];

            switch (chunk_type) {
                W3D_CHUNK_MESH => {
                    // Mesh container (type 0x00000000) - only if it's marked as a container
                    // and has a reasonable size for mesh data
                    if (is_container and chunk_size >= 8) {
                        if (try self.parseMesh(chunk_data)) |mesh| {
                            try meshes.append(self.allocator, mesh);
                        }
                    }
                },
                W3D_CHUNK_HLOD, W3D_CHUNK_HMODEL, W3D_CHUNK_LODMODEL, W3D_CHUNK_AGGREGATE, W3D_CHUNK_COLLECTION => {
                    // Known container chunks that may contain meshes - recurse into them
                    if (is_container and chunk_size >= 8) {
                        try self.parseChunks(chunk_data, meshes, depth + 1);
                    }
                },
                // Skip these containers - they don't contain mesh data
                W3D_CHUNK_HIERARCHY, W3D_CHUNK_ANIMATION, W3D_CHUNK_COMPRESSED_ANIMATION, W3D_CHUNK_MORPH_ANIMATION => {},
                else => {
                    // For unknown containers, don't recurse - just skip
                    // The top-level iteration will find all mesh chunks
                },
            }

            pos = chunk_end;
        }
    }

    fn parseMesh(self: *W3DLoader, data: []const u8) !?W3DMesh {
        var mesh = W3DMesh{
            .name = std.mem.zeroes([16]u8),
            .vertices = &.{},
            .triangles = &.{},
            .texture_name = std.mem.zeroes([64]u8),
            .allocator = self.allocator,
        };

        var vertices: std.ArrayList(W3DVertex) = .{};
        var triangles: std.ArrayList(W3DTriangle) = .{};

        var pos: usize = 0;
        var vertex_count: u32 = 0;

        while (pos + 8 <= data.len) {
            const chunk_type = std.mem.readInt(u32, data[pos..][0..4], .little);
            const chunk_size_raw = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
            const chunk_size = chunk_size_raw & 0x7FFFFFFF;
            pos += 8;

            const chunk_end = pos + chunk_size;
            if (chunk_end > data.len) break;

            switch (chunk_type) {
                W3D_CHUNK_MESH_HEADER3 => {
                    // W3D Mesh Header v3 structure:
                    // Offset 0: Version (1 byte)
                    // Offset 1: Attributes (4 bytes)
                    // Offset 5-7: padding
                    // Offset 8: MeshName (16 bytes)
                    // Offset 24: ContainerName (16 bytes)
                    // Offset 40: NumTris (4 bytes)
                    // Offset 44: NumVertices (4 bytes)
                    if (chunk_size >= 48) {
                        // Read mesh name at offset 8
                        @memcpy(&mesh.name, data[pos + 8 ..][0..16]);

                        // Vertex count at offset 44
                        vertex_count = std.mem.readInt(u32, data[pos + 44 ..][0..4], .little);

                        // Sanity check - don't allocate absurd amounts
                        if (vertex_count > 100000) {
                            vertex_count = 0;
                        }

                        // Pre-allocate vertices
                        if (vertex_count > 0) {
                            try vertices.ensureTotalCapacity(self.allocator, vertex_count);
                            var i: u32 = 0;
                            while (i < vertex_count) : (i += 1) {
                                try vertices.append(self.allocator, .{
                                    .position = Vec3.init(),
                                    .normal = Vec3.init(),
                                    .texcoord = Vec2.init(),
                                });
                            }
                        }
                    }
                },
                W3D_CHUNK_VERTICES => {
                    const count = chunk_size / 12;
                    var i: usize = 0;
                    var offset = pos;
                    while (i < count and i < vertices.items.len) : (i += 1) {
                        vertices.items[i].position = .{
                            .x = @bitCast(std.mem.readInt(u32, data[offset..][0..4], .little)),
                            .y = @bitCast(std.mem.readInt(u32, data[offset + 4 ..][0..4], .little)),
                            .z = @bitCast(std.mem.readInt(u32, data[offset + 8 ..][0..4], .little)),
                        };
                        offset += 12;
                    }
                },
                W3D_CHUNK_VERTEX_NORMALS => {
                    const count = chunk_size / 12;
                    var i: usize = 0;
                    var offset = pos;
                    while (i < count and i < vertices.items.len) : (i += 1) {
                        vertices.items[i].normal = .{
                            .x = @bitCast(std.mem.readInt(u32, data[offset..][0..4], .little)),
                            .y = @bitCast(std.mem.readInt(u32, data[offset + 4 ..][0..4], .little)),
                            .z = @bitCast(std.mem.readInt(u32, data[offset + 8 ..][0..4], .little)),
                        };
                        offset += 12;
                    }
                },
                W3D_CHUNK_TRIANGLES => {
                    const count = chunk_size / 32;
                    var i: usize = 0;
                    var offset = pos;
                    while (i < count) : (i += 1) {
                        const tri = W3DTriangle{
                            .indices = .{
                                std.mem.readInt(u32, data[offset..][0..4], .little),
                                std.mem.readInt(u32, data[offset + 4 ..][0..4], .little),
                                std.mem.readInt(u32, data[offset + 8 ..][0..4], .little),
                            },
                            .normal = .{
                                .x = @bitCast(std.mem.readInt(u32, data[offset + 16 ..][0..4], .little)),
                                .y = @bitCast(std.mem.readInt(u32, data[offset + 20 ..][0..4], .little)),
                                .z = @bitCast(std.mem.readInt(u32, data[offset + 24 ..][0..4], .little)),
                            },
                        };
                        try triangles.append(self.allocator, tri);
                        offset += 32;
                    }
                },
                W3D_CHUNK_STAGE_TEXCOORDS => {
                    const count = chunk_size / 8;
                    var i: usize = 0;
                    var offset = pos;
                    while (i < count and i < vertices.items.len) : (i += 1) {
                        vertices.items[i].texcoord = .{
                            .u = @bitCast(std.mem.readInt(u32, data[offset..][0..4], .little)),
                            .v = @bitCast(std.mem.readInt(u32, data[offset + 4 ..][0..4], .little)),
                        };
                        offset += 8;
                    }
                },
                W3D_CHUNK_TEXTURE_NAME => {
                    const name_len = @min(chunk_size, 64);
                    @memcpy(mesh.texture_name[0..name_len], data[pos..][0..name_len]);
                },
                else => {},
            }

            pos = chunk_end;
        }

        mesh.vertices = try vertices.toOwnedSlice(self.allocator);
        mesh.triangles = try triangles.toOwnedSlice(self.allocator);

        if (mesh.vertices.len == 0) {
            return null;
        }

        return mesh;
    }
};

// GPU Mesh for rendering
pub const GPUMesh = struct {
    vao: u32,
    vbo: u32,
    ebo: u32,
    index_count: u32,

    pub fn init() GPUMesh {
        return .{
            .vao = 0,
            .vbo = 0,
            .ebo = 0,
            .index_count = 0,
        };
    }
};

// Create GPU mesh from W3D mesh
pub fn uploadMeshToGPU(mesh: *const W3DMesh, gl: anytype) GPUMesh {
    var gpu_mesh = GPUMesh.init();

    if (mesh.vertices.len == 0 or mesh.triangles.len == 0) {
        return gpu_mesh;
    }

    // Create vertex array
    var vao: u32 = 0;
    gl.glGenVertexArrays(1, &vao);
    gl.glBindVertexArray(vao);

    // Create vertex buffer
    var vbo: u32 = 0;
    gl.glGenBuffers(1, &vbo);
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vbo);

    // Pack vertex data: position (3) + normal (3) + texcoord (2) = 8 floats per vertex
    const vertex_size = 8;
    const vertex_data = std.heap.page_allocator.alloc(f32, mesh.vertices.len * vertex_size) catch return gpu_mesh;
    defer std.heap.page_allocator.free(vertex_data);

    for (mesh.vertices, 0..) |v, i| {
        const offset = i * vertex_size;
        vertex_data[offset + 0] = v.position.x;
        vertex_data[offset + 1] = v.position.y;
        vertex_data[offset + 2] = v.position.z;
        vertex_data[offset + 3] = v.normal.x;
        vertex_data[offset + 4] = v.normal.y;
        vertex_data[offset + 5] = v.normal.z;
        vertex_data[offset + 6] = v.texcoord.u;
        vertex_data[offset + 7] = v.texcoord.v;
    }

    gl.glBufferData(
        gl.GL_ARRAY_BUFFER,
        @intCast(mesh.vertices.len * vertex_size * @sizeOf(f32)),
        vertex_data.ptr,
        gl.GL_STATIC_DRAW,
    );

    // Create index buffer
    var ebo: u32 = 0;
    gl.glGenBuffers(1, &ebo);
    gl.glBindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, ebo);

    const index_data = std.heap.page_allocator.alloc(u32, mesh.triangles.len * 3) catch return gpu_mesh;
    defer std.heap.page_allocator.free(index_data);

    for (mesh.triangles, 0..) |t, i| {
        const offset = i * 3;
        index_data[offset + 0] = t.indices[0];
        index_data[offset + 1] = t.indices[1];
        index_data[offset + 2] = t.indices[2];
    }

    gl.glBufferData(
        gl.GL_ELEMENT_ARRAY_BUFFER,
        @intCast(mesh.triangles.len * 3 * @sizeOf(u32)),
        index_data.ptr,
        gl.GL_STATIC_DRAW,
    );

    // Set up vertex attributes
    // Position
    gl.glVertexAttribPointer(0, 3, gl.GL_FLOAT, gl.GL_FALSE, vertex_size * @sizeOf(f32), @ptrFromInt(0));
    gl.glEnableVertexAttribArray(0);

    // Normal
    gl.glVertexAttribPointer(1, 3, gl.GL_FLOAT, gl.GL_FALSE, vertex_size * @sizeOf(f32), @ptrFromInt(3 * @sizeOf(f32)));
    gl.glEnableVertexAttribArray(1);

    // Texcoord
    gl.glVertexAttribPointer(2, 2, gl.GL_FLOAT, gl.GL_FALSE, vertex_size * @sizeOf(f32), @ptrFromInt(6 * @sizeOf(f32)));
    gl.glEnableVertexAttribArray(2);

    gl.glBindVertexArray(0);

    gpu_mesh.vao = vao;
    gpu_mesh.vbo = vbo;
    gpu_mesh.ebo = ebo;
    gpu_mesh.index_count = @intCast(mesh.triangles.len * 3);

    return gpu_mesh;
}

// Draw a GPU mesh
pub fn drawGPUMesh(gpu_mesh: *const GPUMesh, gl: anytype) void {
    if (gpu_mesh.vao == 0 or gpu_mesh.index_count == 0) {
        return;
    }

    gl.glBindVertexArray(gpu_mesh.vao);
    gl.glDrawElements(gl.GL_TRIANGLES, @intCast(gpu_mesh.index_count), gl.GL_UNSIGNED_INT, null);
    gl.glBindVertexArray(0);
}
