/// ** Update the version number when any breaking changes are made to the cache format or to the JS parser **
/// Version 3: "Infinity" becomes "1/0".
/// Version 4: TypeScript enums are properly handled + more constant folding
/// Version 5: `require.main === module` no longer marks a module as CJS
/// Version 6: `use strict` is preserved in CommonJS modules when at the top of the file
/// Version 7: Several bundler changes that are likely to impact the runtime as well.
/// Version 8: Fix for generated symbols
/// Version 9: String printing changes
/// Version 10: Constant folding for ''.charCodeAt(n)
/// Version 11: Fix \uFFFF printing regression
/// Version 12: "use strict"; makes it CommonJS if we otherwise don't know which one to pick.
/// Version 13: Hoist `import.meta.require` definition, see #15738
/// Version 14: Updated global defines table list.
/// Version 15: Updated global defines table list.
/// Version 16: Added typeof undefined minification optimization.
/// Version 17: Removed transpiler import rewrite for bun:test. Not bumping it causes test/js/bun/http/req-url-leak.test.ts to fail with SyntaxError: Export named 'expect' not found in module 'bun:test'.
/// Version 18: Include ESM record (module info) with an ES Module, see #15758
/// Version 19: Sourcemap blob is InternalSourceMap (varint stream + sync points), not VLQ.
/// Version 20: InternalSourceMap stream is bit-packed windows.
const expected_version = 20;

const debug = Output.scoped(.cache, .visible);
// Source files smaller than this are not written to / read from the on-disk
// transpiler cache. Originally 50 KiB, which excluded almost every file in a
// typical node_modules tree (eslint pulls in ~1500 small CommonJS files, all
// well under that floor), forcing a full lex -> parse -> visit -> print ->
// sourcemap pass on every invocation. A statx + open + read of a tiny cache
// file is far cheaper than re-transpiling, so the floor is low. The cache key
// still incorporates the source byte length (input_byte_length / isStale), so
// shrinking this does not weaken staleness detection.
const MINIMUM_CACHE_SIZE = 4 * 1024;

// When making parser changes, it gets extremely confusing.
var bun_debug_restore_from_cache = false;

pub const RuntimeTranspilerCache = struct {
    input_hash: ?u64 = null,
    input_byte_length: ?u64 = null,
    features_hash: ?u64 = null,
    exports_kind: bun.ast.ExportsKind = .none,
    output_code: ?bun.String = null,
    entry: ?Entry = null,

    sourcemap_allocator: std.mem.Allocator,
    output_code_allocator: std.mem.Allocator,
    esm_record_allocator: std.mem.Allocator,

    const seed = 42;
    pub const Metadata = struct {
        cache_version: u32 = expected_version,
        output_encoding: Encoding = Encoding.none,
        module_type: ModuleType = ModuleType.none,

        features_hash: u64 = 0,

        input_byte_length: u64 = 0,
        input_hash: u64 = 0,

        output_byte_offset: u64 = 0,
        output_byte_length: u64 = 0,
        output_hash: u64 = 0,

        sourcemap_byte_offset: u64 = 0,
        sourcemap_byte_length: u64 = 0,
        sourcemap_hash: u64 = 0,

        esm_record_byte_offset: u64 = 0,
        esm_record_byte_length: u64 = 0,
        esm_record_hash: u64 = 0,

        pub const size = brk: {
            var count: usize = 0;
            const meta: Metadata = .{};
            for (std.meta.fieldNames(Metadata)) |name| {
                count += @sizeOf(@TypeOf(@field(meta, name)));
            }
            break :brk count;
        };

        pub fn encode(this: *const Metadata, writer: anytype) !void {
            try writer.writeInt(u32, this.cache_version, .little);
            try writer.writeInt(u8, @intFromEnum(this.module_type), .little);
            try writer.writeInt(u8, @intFromEnum(this.output_encoding), .little);

            try writer.writeInt(u64, this.features_hash, .little);

            try writer.writeInt(u64, this.input_byte_length, .little);
            try writer.writeInt(u64, this.input_hash, .little);

            try writer.writeInt(u64, this.output_byte_offset, .little);
            try writer.writeInt(u64, this.output_byte_length, .little);
            try writer.writeInt(u64, this.output_hash, .little);

            try writer.writeInt(u64, this.sourcemap_byte_offset, .little);
            try writer.writeInt(u64, this.sourcemap_byte_length, .little);
            try writer.writeInt(u64, this.sourcemap_hash, .little);

            try writer.writeInt(u64, this.esm_record_byte_offset, .little);
            try writer.writeInt(u64, this.esm_record_byte_length, .little);
            try writer.writeInt(u64, this.esm_record_hash, .little);
        }

        pub fn decode(this: *Metadata, reader: anytype) !void {
            this.cache_version = try reader.takeInt(u32, .little);
            if (this.cache_version != expected_version) {
                return error.StaleCache;
            }

            this.module_type = @enumFromInt(try reader.takeInt(u8, .little));
            this.output_encoding = @enumFromInt(try reader.takeInt(u8, .little));

            this.features_hash = try reader.takeInt(u64, .little);

            this.input_byte_length = try reader.takeInt(u64, .little);
            this.input_hash = try reader.takeInt(u64, .little);

            this.output_byte_offset = try reader.takeInt(u64, .little);
            this.output_byte_length = try reader.takeInt(u64, .little);
            this.output_hash = try reader.takeInt(u64, .little);

            this.sourcemap_byte_offset = try reader.takeInt(u64, .little);
            this.sourcemap_byte_length = try reader.takeInt(u64, .little);
            this.sourcemap_hash = try reader.takeInt(u64, .little);

            this.esm_record_byte_offset = try reader.takeInt(u64, .little);
            this.esm_record_byte_length = try reader.takeInt(u64, .little);
            this.esm_record_hash = try reader.takeInt(u64, .little);

            switch (this.module_type) {
                .esm, .cjs => {},
                // Invalid module type
                else => return error.InvalidModuleType,
            }

            switch (this.output_encoding) {
                .utf8, .utf16, .latin1 => {},
                // Invalid encoding
                else => return error.UnknownEncoding,
            }
        }
    };

    pub const Entry = struct {
        metadata: Metadata,
        output_code: OutputCode = .{ .utf8 = "" },
        sourcemap: []const u8 = "",
        esm_record: []const u8 = "",

        pub const OutputCode = union(enum) {
            utf8: []const u8,
            string: bun.String,

            pub fn deinit(this: *OutputCode, allocator: std.mem.Allocator) void {
                switch (this.*) {
                    .utf8 => {
                        allocator.free(this.utf8);
                    },
                    .string => this.string.deref(),
                }
            }

            pub fn byteSlice(this: *const OutputCode) []const u8 {
                switch (this.*) {
                    .utf8 => return this.utf8,
                    .string => return this.string.byteSlice(),
                }
            }
        };

        pub fn deinit(this: *Entry, sourcemap_allocator: std.mem.Allocator, output_code_allocator: std.mem.Allocator, esm_record_allocator: std.mem.Allocator) void {
            this.output_code.deinit(output_code_allocator);
            if (this.sourcemap.len > 0) {
                sourcemap_allocator.free(this.sourcemap);
            }
            if (this.esm_record.len > 0) {
                esm_record_allocator.free(this.esm_record);
            }
        }

        pub fn save(
            destination_dir: bun.FD,
            destination_path: bun.PathString,
            input_byte_length: u64,
            input_hash: u64,
            features_hash: u64,
            sourcemap: []const u8,
            esm_record: []const u8,
            output_code: OutputCode,
            exports_kind: bun.ast.ExportsKind,
        ) !void {
            var tracer = bun.perf.trace("RuntimeTranspilerCache.save");
            defer tracer.end();

            // atomically write to a tmpfile and then move it to the final destination
            var tmpname_buf: bun.PathBuffer = undefined;
            const tmpfilename = try bun.fs.FileSystem.tmpname(std.fs.path.extension(destination_path.slice()), &tmpname_buf, input_hash);

            const output_bytes = output_code.byteSlice();

            // First we open the tmpfile, to avoid any other work in the event of failure.
            var tmpfile = try bun.Tmpfile.create(destination_dir, tmpfilename).unwrap();
            defer {
                tmpfile.fd.close();
            }
            {
                errdefer {
                    if (!tmpfile.using_tmpfile) {
                        _ = bun.sys.unlinkat(destination_dir, tmpfilename);
                    }
                }
                var metadata_buf: [Metadata.size * 2]u8 = undefined;
                @memset(&metadata_buf, 0);
                const metadata_bytes = brk: {
                    var metadata = Metadata{
                        .input_byte_length = input_byte_length,
                        .input_hash = input_hash,
                        .features_hash = features_hash,
                        .module_type = switch (exports_kind) {
                            .cjs => ModuleType.cjs,
                            else => ModuleType.esm,
                        },
                        .output_encoding = switch (output_code) {
                            .utf8 => Encoding.utf8,
                            .string => |str| switch (str.encoding()) {
                                .utf8 => Encoding.utf8,
                                .utf16 => Encoding.utf16,
                                .latin1 => Encoding.latin1,
                            },
                        },
                        .sourcemap_byte_length = sourcemap.len,
                        .output_byte_offset = Metadata.size,
                        .output_byte_length = output_bytes.len,
                        .sourcemap_byte_offset = Metadata.size + output_bytes.len,
                        .esm_record_byte_offset = Metadata.size + output_bytes.len + sourcemap.len,
                        .esm_record_byte_length = esm_record.len,
                    };

                    metadata.output_hash = hash(output_bytes);
                    metadata.sourcemap_hash = hash(sourcemap);
                    if (esm_record.len > 0) {
                        metadata.esm_record_hash = hash(esm_record);
                    }

                    var metadata_stream = std.Io.Writer.fixed(&metadata_buf);

                    try metadata.encode(&metadata_stream);

                    if (comptime bun.Environment.isDebug) {
                        var metadata_stream2 = std.Io.Reader.fixed(metadata_buf[0..Metadata.size]);
                        var metadata2 = Metadata{};
                        metadata2.decode(&metadata_stream2) catch |err| bun.Output.panic("Metadata did not roundtrip encode -> decode  successfully: {s}", .{@errorName(err)});
                        bun.assert(std.meta.eql(metadata, metadata2));
                    }

                    break :brk metadata_stream.buffered();
                };

                var vecs_buf: [4]bun.PlatformIOVecConst = undefined;
                var vecs_i: usize = 0;
                vecs_buf[vecs_i] = bun.platformIOVecConstCreate(metadata_bytes);
                vecs_i += 1;
                if (output_bytes.len > 0) {
                    vecs_buf[vecs_i] = bun.platformIOVecConstCreate(output_bytes);
                    vecs_i += 1;
                }
                if (sourcemap.len > 0) {
                    vecs_buf[vecs_i] = bun.platformIOVecConstCreate(sourcemap);
                    vecs_i += 1;
                }
                if (esm_record.len > 0) {
                    vecs_buf[vecs_i] = bun.platformIOVecConstCreate(esm_record);
                    vecs_i += 1;
                }
                const vecs: []const bun.PlatformIOVecConst = vecs_buf[0..vecs_i];

                var position: isize = 0;
                const end_position = Metadata.size + output_bytes.len + sourcemap.len + esm_record.len;

                if (bun.Environment.allow_assert) {
                    var total: usize = 0;
                    for (vecs) |v| {
                        bun.assert(v.len > 0);
                        total += v.len;
                    }
                    bun.assert(end_position == total);
                }
                bun.assert(end_position == @as(i64, @intCast(sourcemap.len + output_bytes.len + Metadata.size + esm_record.len)));

                bun.sys.preallocate_file(tmpfile.fd.cast(), 0, @intCast(end_position)) catch {};
                while (position < end_position) {
                    const written = try bun.sys.pwritev(tmpfile.fd, vecs, position).unwrap();
                    if (written <= 0) {
                        return error.WriteFailed;
                    }

                    position += @intCast(written);
                }
            }

            try tmpfile.finish(@ptrCast(std.fs.path.basename(destination_path.slice())));
        }

        pub fn load(
            this: *Entry,
            file: std.Io.File,
            sourcemap_allocator: std.mem.Allocator,
            output_code_allocator: std.mem.Allocator,
            esm_record_allocator: std.mem.Allocator,
        ) !void {
            const io = std.Io.Threaded.global_single_threaded.io();
            const stat_size = (try file.stat(io)).size;
            if (stat_size < Metadata.size + this.metadata.output_byte_length + this.metadata.sourcemap_byte_length) {
                return error.MissingData;
            }

            bun.assert(this.output_code == .utf8 and this.output_code.utf8.len == 0); // this should be the default value

            this.output_code = if (this.metadata.output_byte_length == 0)
                .{ .string = bun.String.empty }
            else switch (this.metadata.output_encoding) {
                .utf8 => brk: {
                    const utf8 = try output_code_allocator.alloc(u8, this.metadata.output_byte_length);
                    errdefer output_code_allocator.free(utf8);
                    const read_bytes = try file.readPositionalAll(io, utf8, this.metadata.output_byte_offset);
                    if (read_bytes != this.metadata.output_byte_length) {
                        return error.MissingData;
                    }
                    break :brk .{ .utf8 = utf8 };
                },
                .latin1 => brk: {
                    var latin1, const bytes = bun.String.createUninitialized(.latin1, this.metadata.output_byte_length);
                    errdefer latin1.deref();
                    const read_bytes = try file.readPositionalAll(io, bytes, this.metadata.output_byte_offset);

                    if (this.metadata.output_hash != 0) {
                        if (hash(latin1.latin1()) != this.metadata.output_hash) {
                            return error.InvalidHash;
                        }
                    }

                    if (read_bytes != this.metadata.output_byte_length) {
                        return error.MissingData;
                    }

                    break :brk .{ .string = latin1 };
                },
                .utf16 => brk: {
                    var string, const chars = bun.String.createUninitialized(.utf16, this.metadata.output_byte_length / 2);
                    errdefer string.deref();

                    const read_bytes = try file.readPositionalAll(io, std.mem.sliceAsBytes(chars), this.metadata.output_byte_offset);
                    if (read_bytes != this.metadata.output_byte_length) {
                        return error.MissingData;
                    }

                    if (this.metadata.output_hash != 0) {
                        if (hash(std.mem.sliceAsBytes(string.utf16())) != this.metadata.output_hash) {
                            return error.InvalidHash;
                        }
                    }

                    break :brk .{ .string = string };
                },

                else => @panic("Unexpected output encoding"),
            };

            errdefer {
                switch (this.output_code) {
                    .utf8 => output_code_allocator.free(this.output_code.utf8),
                    .string => this.output_code.string.deref(),
                }
            }

            if (this.metadata.sourcemap_byte_length > 0) {
                const sourcemap = try sourcemap_allocator.alloc(u8, this.metadata.sourcemap_byte_length);
                errdefer sourcemap_allocator.free(sourcemap);
                const read_bytes = try file.readPositionalAll(io, sourcemap, this.metadata.sourcemap_byte_offset);
                if (read_bytes != this.metadata.sourcemap_byte_length) {
                    return error.MissingData;
                }

                this.sourcemap = sourcemap;
            }

            if (this.metadata.esm_record_byte_length > 0) {
                const esm_record = try esm_record_allocator.alloc(u8, this.metadata.esm_record_byte_length);
                errdefer esm_record_allocator.free(esm_record);
                const read_bytes = try file.readPositionalAll(io, esm_record, this.metadata.esm_record_byte_offset);
                if (read_bytes != this.metadata.esm_record_byte_length) {
                    return error.MissingData;
                }

                if (this.metadata.esm_record_hash != 0) {
                    if (hash(esm_record) != this.metadata.esm_record_hash) {
                        return error.InvalidHash;
                    }
                }

                this.esm_record = esm_record;
            }
        }
    };

    pub fn hash(bytes: []const u8) u64 {
        return std.hash.Wyhash.hash(seed, bytes);
    }

    pub const ModuleType = enum(u8) {
        none = 0,
        esm = 1,
        cjs = 2,
    };

    pub const Encoding = enum(u8) {
        none = 0,
        utf8 = 1,
        utf16 = 2,
        latin1 = 3,
        _,
    };

    pub fn writeCacheFilename(
        buf: []u8,
        input_hash: u64,
    ) !usize {
        const fmt_name = if (comptime bun.Environment.allow_assert) "{x}.debug.pile" else "{x}.pile";

        const printed = try std.fmt.bufPrint(buf, fmt_name, .{std.mem.asBytes(&input_hash)});
        return printed.len;
    }

    pub fn getCacheFilePath(
        buf: *bun.PathBuffer,
        input_hash: u64,
    ) ![:0]const u8 {
        const cache_dir = try getCacheDir(buf);
        buf[cache_dir.len] = std.fs.path.sep;
        const cache_filename_len = try writeCacheFilename(buf[cache_dir.len + 1 ..], input_hash);
        buf[cache_dir.len + 1 + cache_filename_len] = 0;

        return buf[0 .. cache_dir.len + 1 + cache_filename_len :0];
    }

    fn reallyGetCacheDir(buf: *bun.PathBuffer) [:0]const u8 {
        if (comptime bun.Environment.isDebug) {
            bun_debug_restore_from_cache = bun.env_var.BUN_DEBUG_ENABLE_RESTORE_FROM_TRANSPILER_CACHE.get();
        }

        if (bun.env_var.BUN_RUNTIME_TRANSPILER_CACHE_PATH.get()) |dir| {
            if (dir.len == 0 or (dir.len == 1 and dir[0] == '0')) {
                return "";
            }

            const len = @min(dir.len, bun.MAX_PATH_BYTES - 1);
            @memcpy(buf[0..len], dir[0..len]);
            buf[len] = 0;
            return buf[0..len :0];
        }

        if (bun.env_var.XDG_CACHE_HOME.get()) |dir| {
            const parts = &[_][]const u8{ dir, "bun", "@t@" };
            return bun.fs.FileSystem.instance.absBufZ(parts, buf);
        }

        if (comptime bun.Environment.isMac) {
            // On a mac, default to ~/Library/Caches/bun/*
            // This is different than ~/.bun/install/cache, and not configurable by the user.
            if (bun.env_var.HOME.get()) |home| {
                const parts = &[_][]const u8{
                    home,
                    "Library/",
                    "Caches/",
                    "bun",
                    "@t@",
                };
                return bun.fs.FileSystem.instance.absBufZ(parts, buf);
            }
        }

        if (bun.env_var.HOME.get()) |dir| {
            const parts = &[_][]const u8{ dir, ".bun", "install", "cache", "@t@" };
            return bun.fs.FileSystem.instance.absBufZ(parts, buf);
        }

        // With neither XDG_CACHE_HOME nor HOME set, the old fallback was a
        // predictable, world-writable `<tmpdir>/bun/@t@` directory. Another user
        // could pre-create it and poison cached transpiler output (code
        // execution). Disable the cache instead of using an unsafe location.
        return "";
    }

    // Only do this at most once per-thread.
    const cache_dir_bufs = bun.ThreadlocalBuffers(struct { buf: bun.PathBuffer = undefined });
    threadlocal var runtime_transpiler_cache: ?[:0]const u8 = null;
    pub var is_disabled = false;

    fn getCacheDir(buf: *bun.PathBuffer) ![:0]const u8 {
        if (is_disabled) return error.CacheDisabled;
        const path = runtime_transpiler_cache orelse path: {
            const path = reallyGetCacheDir(&cache_dir_bufs.get().buf);
            if (path.len == 0) {
                is_disabled = true;
                return error.CacheDisabled;
            }
            runtime_transpiler_cache = path;
            break :path path;
        };
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        return path;
    }

    pub fn fromFile(
        input_hash: u64,
        feature_hash: u64,
        input_stat_size: u64,
        sourcemap_allocator: std.mem.Allocator,
        output_code_allocator: std.mem.Allocator,
        esm_record_allocator: std.mem.Allocator,
    ) !Entry {
        var tracer = bun.perf.trace("RuntimeTranspilerCache.fromFile");
        defer tracer.end();

        var cache_file_path_buf: bun.PathBuffer = undefined;
        const cache_file_path = try getCacheFilePath(&cache_file_path_buf, input_hash);
        bun.assert(cache_file_path.len > 0);
        return fromFileWithCacheFilePath(
            bun.PathString.init(cache_file_path),
            input_hash,
            feature_hash,
            input_stat_size,
            sourcemap_allocator,
            output_code_allocator,
            esm_record_allocator,
        );
    }

    pub fn fromFileWithCacheFilePath(
        cache_file_path: bun.PathString,
        input_hash: u64,
        feature_hash: u64,
        input_stat_size: u64,
        sourcemap_allocator: std.mem.Allocator,
        output_code_allocator: std.mem.Allocator,
        esm_record_allocator: std.mem.Allocator,
    ) !Entry {
        var metadata_bytes_buf: [Metadata.size * 2]u8 = undefined;
        const io = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.openFileAbsolute(io, cache_file_path.slice(), .{ .mode = .read_only });
        defer file.close(io);
        errdefer {
            // On any error, we delete the cache file
            std.Io.Dir.deleteFileAbsolute(io, cache_file_path.slice()) catch {};
        }

        const metadata_bytes = try file.readPositionalAll(io, &metadata_bytes_buf, 0);
        var metadata_stream = std.Io.Reader.fixed(metadata_bytes_buf[0..metadata_bytes]);

        var entry = Entry{
            .metadata = Metadata{},
            .output_code = .{ .utf8 = "" },
            .sourcemap = "",
        };
        try entry.metadata.decode(&metadata_stream);
        if (entry.metadata.input_hash != input_hash or entry.metadata.input_byte_length != input_stat_size) {
            // delete the cache in this case
            return error.InvalidInputHash;
        }

        if (entry.metadata.features_hash != feature_hash) {
            // delete the cache in this case
            return error.MismatchedFeatureHash;
        }

        try entry.load(file, sourcemap_allocator, output_code_allocator, esm_record_allocator);

        return entry;
    }

    pub fn isEligible(
        _: *const @This(),
        path: *const bun.fs.Path,
    ) bool {
        return path.isFile();
    }

    pub fn toFile(
        input_byte_length: u64,
        input_hash: u64,
        features_hash: u64,
        sourcemap: []const u8,
        esm_record: []const u8,
        source_code: bun.String,
        exports_kind: bun.ast.ExportsKind,
    ) !void {
        var tracer = bun.perf.trace("RuntimeTranspilerCache.toFile");
        defer tracer.end();

        var cache_file_path_buf: bun.PathBuffer = undefined;
        const output_code: Entry.OutputCode = switch (source_code.encoding()) {
            .utf8 => .{ .utf8 = source_code.byteSlice() },
            else => .{ .string = source_code },
        };

        const cache_file_path = try getCacheFilePath(&cache_file_path_buf, input_hash);
        debug("filename to put into: '{s}'", .{cache_file_path});

        if (cache_file_path.len == 0) {
            return;
        }

        const cache_dir_fd = brk: {
            if (std.fs.path.dirname(cache_file_path)) |dirname| {
                break :brk try makeOpenPathCompat(dirname);
            }

            break :brk bun.FD.cwd();
        };
        defer {
            if (cache_dir_fd != bun.FD.cwd()) cache_dir_fd.close();
        }

        try Entry.save(
            cache_dir_fd,
            bun.PathString.init(cache_file_path),
            input_byte_length,
            input_hash,
            features_hash,
            sourcemap,
            esm_record,
            output_code,
            exports_kind,
        );
    }

    pub fn get(
        this: *RuntimeTranspilerCache,
        source: *const bun.logger.Source,
        parser_options: *const bun.js_parser.Parser.Options,
        used_jsx: bool,
    ) bool {
        if (comptime !bun.FeatureFlags.runtime_transpiler_cache)
            return false;

        if (this.entry != null) return true;

        if (source.contents.len < MINIMUM_CACHE_SIZE)
            return false;

        if (is_disabled)
            return false;

        if (!source.path.isFile())
            return false;

        const input_hash = this.input_hash orelse hash(source.contents);
        this.input_hash = input_hash;
        this.input_byte_length = source.contents.len;

        var features_hasher = std.hash.Wyhash.init(seed);
        parser_options.hashForRuntimeTranspiler(&features_hasher, used_jsx);
        this.features_hash = features_hasher.final();

        this.entry = fromFile(input_hash, this.features_hash.?, source.contents.len, this.sourcemap_allocator, this.output_code_allocator, this.esm_record_allocator) catch |err| {
            debug("get(\"{s}\") = {s}", .{ source.path.text, @errorName(err) });
            return false;
        };
        if (comptime bun.Environment.isDebug) {
            if (bun_debug_restore_from_cache) {
                debug("get(\"{s}\") = {d} bytes, restored", .{ source.path.text, this.entry.?.output_code.byteSlice().len });
            } else {
                debug("get(\"{s}\") = {d} bytes, ignored for debug build", .{ source.path.text, this.entry.?.output_code.byteSlice().len });
            }
        }
        bun.analytics.Features.transpiler_cache += 1;

        if (comptime bun.Environment.isDebug) {
            if (!bun_debug_restore_from_cache) {
                if (this.entry) |*entry| {
                    entry.deinit(this.sourcemap_allocator, this.output_code_allocator, this.esm_record_allocator);
                    this.entry = null;
                }
            }
        }

        return this.entry != null;
    }

    pub fn put(this: *RuntimeTranspilerCache, output_code_bytes: []const u8, sourcemap: []const u8, esm_record: []const u8) void {
        if (comptime !bun.FeatureFlags.runtime_transpiler_cache)
            @compileError("RuntimeTranspilerCache is disabled");

        if (this.input_hash == null or is_disabled) {
            return;
        }
        bun.assert(this.entry == null);
        const output_code = bun.String.cloneLatin1(output_code_bytes);
        this.output_code = output_code;

        toFile(this.input_byte_length.?, this.input_hash.?, this.features_hash.?, sourcemap, esm_record, output_code, this.exports_kind) catch |err| {
            debug("put() = {s}", .{@errorName(err)});
            return;
        };
        if (comptime bun.Environment.allow_assert)
            debug("put() = {d} bytes", .{output_code.latin1().len});
    }
};

const std = @import("std");

const bun = @import("bun");
const Output = bun.Output;

fn makeOpenPathCompat(dirname: []const u8) !bun.FD {
    if (comptime bun.Environment.isWindows) {
        @panic("TODO(phase-12.2-M3): port RuntimeTranspilerCache makeOpenPathCompat for Windows");
    }

    try makeDirPathAbsoluteCompat(dirname);
    const flags: std.posix.O = .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
    };
    return try bun.FD.fromNative(try std.posix.openat(std.Io.Dir.cwd().handle, dirname, flags, 0)).makeLibUVOwned();
}

fn makeDirPathAbsoluteCompat(dirname: []const u8) !void {
    if (dirname.len == 0) return;
    if (dirname.len >= bun.MAX_PATH_BYTES) return error.NameTooLong;

    var buf: bun.PathBuffer = undefined;
    @memcpy(buf[0..dirname.len], dirname);
    buf[dirname.len] = 0;

    var index: usize = if (dirname[0] == std.fs.path.sep) 1 else 0;
    while (index <= dirname.len) : (index += 1) {
        if (index < dirname.len and dirname[index] != std.fs.path.sep) continue;
        if (index == 0) continue;

        const prev = buf[index];
        buf[index] = 0;
        const rc = std.c.mkdir(buf[0..index :0].ptr, 0o755);
        buf[index] = prev;

        if (rc == 0) continue;
        switch (std.c.errno(rc)) {
            .EXIST => continue,
            .ACCES => return error.AccessDenied,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .PERM => return error.PermissionDenied,
            .ROFS => return error.AccessDenied,
            .LOOP => return error.SymLinkLoop,
            .NOSPC => return error.NoSpaceLeft,
            else => return error.Unexpected,
        }
    }
}
