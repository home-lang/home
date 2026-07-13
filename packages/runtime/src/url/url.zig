// This is close to WHATWG URL, but we don't want the validation errors
pub const URL = struct {
    const log = Output.scoped(.URL, .visible);

    hash: string = "",
    /// hostname, but with a port
    /// `localhost:3000`
    host: string = "",
    /// hostname does not have a port
    /// `localhost`
    hostname: string = "",
    href: string = "",
    origin: string = "",
    password: string = "",
    pathname: string = "/",
    path: string = "/",
    port: string = "",
    protocol: string = "",
    search: string = "",
    searchParams: ?QueryStringMap = null,
    username: string = "",
    port_was_automatically_set: bool = false,

    pub fn isFile(this: *const URL) bool {
        return strings.eqlComptime(this.protocol, "file");
    }
    /// host + path without the ending slash, protocol, searchParams and hash
    pub fn hostWithPath(this: *const URL) []const u8 {
        if (this.host.len > 0) {
            if (this.path.len > 1 and bun.isSliceInBuffer(this.path, this.href) and bun.isSliceInBuffer(this.host, this.href)) {
                const end = @intFromPtr(this.path.ptr) + this.path.len;
                const start = @intFromPtr(this.host.ptr);
                const len: usize = end - start - (if (bun.strings.endsWithComptime(this.path, "/")) @as(usize, 1) else @as(usize, 0));
                const ptr: [*]u8 = @ptrFromInt(start);
                return ptr[0..len];
            }
            return this.host;
        }
        return "";
    }

    /// `"blob:".len + UUID.stringLength` — see `runtime/webcore/ObjectURLRegistry.specifier_len`.
    const blob_specifier_len = "blob:".len + 36;

    pub fn isBlob(this: *const URL) bool {
        return this.href.len == blob_specifier_len and strings.hasPrefixComptime(this.href, "blob:");
    }

    // JSC bridge is intentionally parked for the Home runtime leaf. Bun wires
    // this through `url_jsc/url_jsc.zig`; Home reattaches it with the JSC phase.
    pub const fromJS = unavailableFromJS;

    fn unavailableFromJS() noreturn {
        @compileError("URL.fromJS is JSC-bound and is not available in the pure Home URL leaf yet");
    }

    pub fn fromString(allocator: std.mem.Allocator, input: anytype) !URL {
        const Input = @TypeOf(input);
        if (comptime Input == []const u8 or Input == [:0]const u8) {
            return fromUTF8(allocator, input);
        }
        if (comptime @hasDecl(Input, "slice")) {
            return fromUTF8(allocator, input.slice());
        }

        return fromUTF8(allocator, "");
    }

    pub fn fromUTF8(allocator: std.mem.Allocator, input: []const u8) !URL {
        return URL.parse(try allocator.dupe(u8, input));
    }

    pub fn isLocalhost(this: *const URL) bool {
        return this.hostname.len == 0 or strings.eqlComptime(this.hostname, "localhost") or strings.eqlComptime(this.hostname, "0.0.0.0");
    }

    pub inline fn isUnix(this: *const URL) bool {
        return strings.hasPrefixComptime(this.protocol, "unix");
    }

    pub fn displayProtocol(this: *const URL) string {
        if (this.protocol.len > 0) {
            return this.protocol;
        }

        if (this.getPort()) |port| {
            if (port == 443) {
                return "https";
            }
        }

        return "http";
    }

    pub inline fn isHTTPS(this: *const URL) bool {
        return strings.eqlComptime(this.protocol, "https");
    }

    pub inline fn isS3(this: *const URL) bool {
        return strings.eqlComptime(this.protocol, "s3");
    }

    pub inline fn isHTTP(this: *const URL) bool {
        return strings.eqlComptime(this.protocol, "http");
    }

    pub fn displayHostname(this: *const URL) string {
        if (this.hostname.len > 0) {
            return this.hostname;
        }

        return "localhost";
    }

    pub fn s3Path(this: *const URL) string {
        // Remove the protocol if present; return host + pathname. The previous
        // `href.len - (search.len + hash.len)` trim underflowed (usize) when the
        // parsed search/hash lengths exceeded the protocol-stripped href,
        // slicing out of bounds; upstream drops the trim entirely.
        return if (this.protocol.len > 0 and this.href.len > this.protocol.len + 2) this.href[this.protocol.len + 2 ..] else this.href;
    }

    pub fn displayHost(this: *const URL) bun.fmt.HostFormatter {
        return bun.fmt.HostFormatter{
            .host = if (this.host.len > 0) this.host else this.displayHostname(),
            .port = if (this.port.len > 0) this.getPort() else null,
            .is_https = this.isHTTPS(),
        };
    }

    pub fn hasHTTPLikeProtocol(this: *const URL) bool {
        return strings.eqlComptime(this.protocol, "http") or strings.eqlComptime(this.protocol, "https");
    }

    pub fn getPort(this: *const URL) ?u16 {
        return std.fmt.parseInt(u16, this.port, 10) catch null;
    }

    pub fn getPortAuto(this: *const URL) u16 {
        return this.getPort() orelse this.getDefaultPort();
    }

    pub fn getDefaultPort(this: *const URL) u16 {
        return if (this.isHTTPS()) @as(u16, 443) else @as(u16, 80);
    }

    pub fn isIPAddress(this: *const URL) bool {
        return bun.strings.isIPAddress(this.hostname);
    }

    pub fn hasValidPort(this: *const URL) bool {
        return (this.getPort() orelse 0) > 0;
    }

    pub fn isEmpty(this: *const URL) bool {
        return this.href.len == 0;
    }

    pub fn isAbsolute(this: *const URL) bool {
        return this.hostname.len > 0 and this.pathname.len > 0;
    }

    pub fn joinNormalize(out: []u8, prefix: string, dirname: string, basename: string, extname: string) string {
        var buf: [2048]u8 = undefined;

        var path_parts: [10]string = undefined;
        var path_end: usize = 0;

        path_parts[0] = "/";
        path_end += 1;

        if (prefix.len > 0) {
            path_parts[path_end] = prefix;
            path_end += 1;
        }

        if (dirname.len > 0) {
            path_parts[path_end] = std.mem.trim(u8, dirname, "/\\");
            path_end += 1;
        }

        if (basename.len > 0) {
            if (dirname.len > 0) {
                path_parts[path_end] = "/";
                path_end += 1;
            }

            path_parts[path_end] = std.mem.trim(u8, basename, "/\\");
            path_end += 1;
        }

        if (extname.len > 0) {
            path_parts[path_end] = extname;
            path_end += 1;
        }

        var buf_i: usize = 0;
        for (path_parts[0..path_end]) |part| {
            bun.copy(u8, buf[buf_i..], part);
            buf_i += part.len;
        }
        return normalizeURLPath(buf[0..buf_i], out);
    }

    pub fn joinWrite(
        this: *const URL,
        comptime Writer: type,
        writer: Writer,
        prefix: string,
        dirname: string,
        basename: string,
        extname: string,
    ) !void {
        var out: [2048]u8 = undefined;
        const normalized_path = joinNormalize(&out, prefix, dirname, basename, extname);

        try writer.print("{s}/{s}", .{ this.origin, normalized_path });
    }

    pub fn joinAlloc(this: *const URL, allocator: std.mem.Allocator, prefix: string, dirname: string, basename: string, extname: string, absolute_path: string) !string {
        const has_uplevels = std.mem.indexOf(u8, dirname, "../") != null;

        if (has_uplevels) {
            return try std.fmt.allocPrint(allocator, "{s}/abs:{s}", .{ this.origin, absolute_path });
        } else {
            var out: [2048]u8 = undefined;

            const normalized_path = joinNormalize(&out, prefix, dirname, basename, extname);
            return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ this.origin, normalized_path });
        }
    }

    pub fn parse(base: string) URL {
        if (base.len == 0) return URL{};
        var url = URL{};
        url.href = base;
        var offset: u31 = 0;
        switch (base[0]) {
            '@' => {
                offset += url.parsePassword(base[offset..]) orelse 0;
                offset += url.parseHost(base[offset..]) orelse 0;
            },
            '/', 'a'...'z', 'A'...'Z', '0'...'9', '-', '_', ':' => {
                const is_protocol_relative = base.len > 1 and base[1] == '/';
                if (is_protocol_relative) {
                    offset += 1;
                } else {
                    offset += url.parseProtocol(base[offset..]) orelse 0;
                }

                const is_relative_path = !is_protocol_relative and base[0] == '/';

                if (!is_relative_path) {

                    // if there's no protocol or @, it's ambiguous whether the colon is a port or a username.
                    if (offset > 0) {
                        // see https://github.com/oven-sh/bun/issues/1390
                        const first_at = strings.indexOfChar(base[offset..], '@') orelse 0;
                        const first_colon = strings.indexOfChar(base[offset..], ':') orelse 0;

                        if (first_at > first_colon and first_at < (strings.indexOfChar(base[offset..], '/') orelse std.math.maxInt(u32))) {
                            offset += url.parseUsername(base[offset..]) orelse 0;
                            offset += url.parsePassword(base[offset..]) orelse 0;
                        }
                    }

                    offset += url.parseHost(base[offset..]) orelse 0;
                }
            },
            else => {},
        }

        url.origin = base[0..offset];
        var hash_offset: u32 = std.math.maxInt(u32);

        if (offset > base.len) {
            return url;
        }

        const path_offset = offset;

        var can_update_path = true;
        if (base.len > offset + 1 and base[offset] == '/' and base[offset..].len > 0) {
            url.path = base[offset..];
            url.pathname = url.path;
        }

        if (strings.indexOfChar(base[offset..], '?')) |q| {
            offset += @as(u31, @intCast(q));
            url.path = base[path_offset..][0..q];
            can_update_path = false;
            url.search = base[offset..];
        }

        if (strings.indexOfChar(base[offset..], '#')) |hash| {
            offset += @as(u31, @intCast(hash));
            hash_offset = offset;
            if (can_update_path) {
                url.path = base[path_offset..][0..hash];
            }
            url.hash = base[offset..];

            if (url.search.len > 0) {
                url.search = url.search[0 .. url.search.len - url.hash.len];
            }
        }

        if (base.len > path_offset and base[path_offset] == '/' and offset > 0) {
            if (url.search.len > 0) {
                url.pathname = base[path_offset..@min(
                    @min(offset + url.search.len, base.len),
                    hash_offset,
                )];
            } else if (hash_offset < std.math.maxInt(u32)) {
                url.pathname = base[path_offset..hash_offset];
            }

            url.origin = base[0..path_offset];
        }

        if (url.path.len > 1) {
            const trimmed = std.mem.trim(u8, url.path, "/");
            if (trimmed.len > 1) {
                url.path = url.path[@min(
                    @max(@intFromPtr(trimmed.ptr) - @intFromPtr(url.path.ptr), 1) - 1,
                    hash_offset,
                )..];
            } else {
                url.path = "/";
            }
        } else {
            url.path = "/";
        }

        if (url.pathname.len == 0) {
            url.pathname = "/";
        }

        while (url.pathname.len > 1 and @as(u16, @bitCast(url.pathname[0..2].*)) == comptime std.mem.readInt(u16, "//", .little)) {
            url.pathname = url.pathname[1..];
        }

        url.origin = std.mem.trim(u8, url.origin, "/ ?#");
        return url;
    }

    pub fn parseProtocol(url: *URL, str: string) ?u31 {
        if (str.len < "://".len) return null;
        for (0..str.len) |i| {
            switch (str[i]) {
                '/', '?', '%' => {
                    return null;
                },
                ':' => {
                    if (i + 3 <= str.len and str[i + 1] == '/' and str[i + 2] == '/') {
                        url.protocol = str[0..i];
                        return @intCast(i + 3);
                    }
                },
                else => {},
            }
        }

        return null;
    }

    pub fn parseUsername(url: *URL, str: string) ?u31 {
        // reset it
        url.username = "";

        if (str.len < "@".len) return null;
        for (0..str.len) |i| {
            switch (str[i]) {
                ':', '@' => {
                    // we found a username, everything before this point in the slice is a username
                    url.username = str[0..i];
                    return @intCast(i + 1);
                },
                // if we reach a slash or "?", there's no username
                '?', '/' => {
                    return null;
                },
                else => {},
            }
        }
        return null;
    }

    pub fn parsePassword(url: *URL, str: string) ?u31 {
        // reset it
        url.password = "";

        if (str.len < "@".len) return null;
        for (0..str.len) |i| {
            switch (str[i]) {
                '@' => {
                    // we found a password, everything before this point in the slice is a password
                    url.password = str[0..i];
                    if (Environment.allow_assert) bun.assert(str[i..].len < 2 or std.mem.readInt(u16, str[i..][0..2], .little) != std.mem.readInt(u16, "//", .little));
                    return @intCast(i + 1);
                },
                // if we reach a slash or "?", there's no password
                '?', '/' => {
                    return null;
                },
                else => {},
            }
        }
        return null;
    }

    pub fn parseHost(url: *URL, str: string) ?u31 {
        var i: u31 = 0;

        // reset it
        url.host = "";
        url.hostname = "";
        url.port = "";

        //if starts with "[" so its IPV6
        if (str.len > 0 and str[0] == '[') {
            i = 1;
            var ipv6_i: ?u31 = null;
            var colon_i: ?u31 = null;

            while (i < str.len) : (i += 1) {
                ipv6_i = if (ipv6_i == null and str[i] == ']') i else ipv6_i;
                colon_i = if (ipv6_i != null and colon_i == null and str[i] == ':') i else colon_i;
                switch (str[i]) {
                    // alright, we found the slash or "?"
                    '?', '/' => {
                        break;
                    },
                    else => {},
                }
            }

            url.host = str[0..i];
            if (ipv6_i) |ipv6| {
                //hostname includes "[" and "]"
                url.hostname = str[0 .. ipv6 + 1];
            }

            if (colon_i) |colon| {
                url.port = str[colon + 1 .. i];
            }
        } else {

            // look for the first "/" or "?"
            // if we have a slash or "?", anything before that is the host
            // anything before the colon is the hostname
            // anything after the colon but before the slash is the port
            // the origin is the scheme before the slash

            var colon_i: ?u31 = null;
            while (i < str.len) : (i += 1) {
                colon_i = if (colon_i == null and str[i] == ':') i else colon_i;

                switch (str[i]) {
                    // alright, we found the slash or "?"
                    '?', '/' => {
                        break;
                    },
                    else => {},
                }
            }

            url.host = str[0..i];
            if (colon_i) |colon| {
                url.hostname = str[0..colon];
                url.port = str[colon + 1 .. i];
            } else {
                url.hostname = str[0..i];
            }
        }

        return i;
    }
};

/// QueryString array-backed hash table that does few allocations and preserves the original order
pub const QueryStringMap = struct {
    allocator: std.mem.Allocator,
    slice: string,
    buffer: []u8,
    list: Param.List,
    name_count: ?usize = null,

    threadlocal var _name_count: [8]string = undefined;
    pub fn getNameCount(this: *QueryStringMap) usize {
        return this.list.len;
        // if (this.name_count == null) {
        //     var count: usize = 0;
        //     var iterate = this.iter();
        //     while (iterate.next(&_name_count) != null) {
        //         count += 1;
        //     }
        //     this.name_count = count;
        // }
        // return this.name_count.?;
    }

    pub fn iter(this: *const QueryStringMap) Iterator {
        return Iterator.init(this);
    }

    pub const Iterator = struct {
        // Assume no query string param map will exceed 2048 keys
        // Browsers typically limit URL lengths to around 64k
        const VisitedMap = bun.bit_set.ArrayBitSet(usize, 2048);

        i: usize = 0,
        map: *const QueryStringMap,
        visited: VisitedMap,

        const Result = struct {
            name: string,
            values: []string,
        };

        pub fn init(map: *const QueryStringMap) Iterator {
            return Iterator{ .i = 0, .map = map, .visited = VisitedMap.initEmpty() };
        }

        pub fn next(this: *Iterator, target: []string) ?Result {
            while (this.visited.isSet(this.i)) : (this.i += 1) {}
            if (this.i >= this.map.list.len) return null;

            var slice = this.map.list.slice();
            const hash = slice.items(.name_hash)[this.i];
            const name_slice = slice.items(.name)[this.i];
            bun.assert(name_slice.length > 0);
            var result = Result{ .name = this.map.str(name_slice), .values = target[0..1] };
            target[0] = this.map.str(slice.items(.value)[this.i]);

            this.visited.set(this.i);
            this.i += 1;

            var remainder_hashes = slice.items(.name_hash)[this.i..];
            const remainder_values = slice.items(.value)[this.i..];

            var target_i: usize = 1;
            var current_i: usize = 0;

            while (std.mem.indexOfScalar(u64, remainder_hashes[current_i..], hash)) |next_index| {
                const real_i = current_i + next_index + this.i;
                if (comptime Environment.isDebug) {
                    bun.assert(!this.visited.isSet(real_i));
                }

                this.visited.set(real_i);
                target[target_i] = this.map.str(remainder_values[current_i + next_index]);
                target_i += 1;
                result.values = target[0..target_i];

                current_i += next_index + 1;
                if (target_i >= target.len) return result;
                if (real_i + 1 >= this.map.list.len) return result;
            }

            return result;
        }
    };

    pub fn str(this: *const QueryStringMap, ptr: api.StringPointer) string {
        return this.slice[ptr.offset .. ptr.offset + ptr.length];
    }

    pub fn getIndex(this: *const QueryStringMap, input: string) ?usize {
        const hash = bun.hash(input);
        return std.mem.indexOfScalar(u64, this.list.items(.name_hash), hash);
    }

    pub fn get(this: *const QueryStringMap, input: string) ?string {
        const hash = bun.hash(input);
        const _slice = this.list.slice();
        const i = std.mem.indexOfScalar(u64, _slice.items(.name_hash), hash) orelse return null;
        return this.str(_slice.items(.value)[i]);
    }

    pub fn has(this: *const QueryStringMap, input: string) bool {
        return this.getIndex(input) != null;
    }

    pub fn getAll(this: *const QueryStringMap, input: string, target: []string) usize {
        const hash = bun.hash(input);
        const _slice = this.list.slice();
        return @call(bun.callmod_inline, getAllWithHashFromOffset, .{ this, target, hash, 0, _slice });
    }

    pub fn getAllWithHashFromOffset(this: *const QueryStringMap, target: []string, hash: u64, offset: usize, _slice: Param.List.Slice) usize {
        var remainder_hashes = _slice.items(.name_hash)[offset..];
        var remainder_values = _slice.items(.value)[offset..];
        var target_i: usize = 0;
        while (remainder_hashes.len > 0 and target_i < target.len) {
            const i = std.mem.indexOfScalar(u64, remainder_hashes, hash) orelse break;
            target[target_i] = this.str(remainder_values[i]);
            remainder_values = remainder_values[i + 1 ..];
            remainder_hashes = remainder_hashes[i + 1 ..];
            target_i += 1;
        }
        return target_i;
    }

    pub const Param = struct {
        name: api.StringPointer,
        name_hash: u64,
        value: api.StringPointer,

        pub const List = std.MultiArrayList(Param);
    };

    pub fn initWithScanner(
        allocator: std.mem.Allocator,
        _scanner: CombinedScanner,
    ) bun.OOM!?QueryStringMap {
        var list = Param.List{};
        var scanner = _scanner;

        var estimated_str_len: usize = 0;
        var count: usize = 0;

        var nothing_needs_decoding = true;

        while (scanner.pathname.next()) |result| {
            if (result.name_needs_decoding or result.value_needs_decoding) {
                nothing_needs_decoding = false;
            }
            estimated_str_len += result.name.length + result.value.length;
            count += 1;
        }

        if (Environment.allow_assert)
            bun.assert(count > 0); // We should not call initWithScanner when there are no path params

        while (scanner.query.next()) |result| {
            if (result.name_needs_decoding or result.value_needs_decoding) {
                nothing_needs_decoding = false;
            }
            estimated_str_len += result.name.length + result.value.length;
            count += 1;
        }

        if (count == 0) return null;

        try list.ensureTotalCapacity(allocator, count);
        scanner.reset();

        // this over-allocates
        // TODO: refactor this to support multiple slices instead of copying the whole thing
        var buf = try std.array_list.Managed(u8).initCapacity(allocator, estimated_str_len);
        var writer = ManagedU8Writer{ .list = &buf };
        var buf_writer_pos: u32 = 0;

        const Writer = *ManagedU8Writer;
        while (scanner.pathname.next()) |result| {
            var name = result.name;
            var value = result.value;
            const name_slice = result.rawName(scanner.pathname.routename);

            name.length = @as(u32, @truncate(name_slice.len));
            name.offset = buf_writer_pos;
            try writer.writeAll(name_slice);
            buf_writer_pos += @as(u32, @truncate(name_slice.len));

            const name_hash: u64 = bun.hash(name_slice);

            value.length = PercentEncoding.decode(Writer, &writer, result.rawValue(scanner.pathname.pathname)) catch continue;
            value.offset = buf_writer_pos;
            buf_writer_pos += value.length;

            list.appendAssumeCapacity(Param{ .name = name, .value = value, .name_hash = name_hash });
        }

        const route_parameter_begin = list.len;

        while (scanner.query.next()) |result| {
            var list_slice = list.slice();

            var name = result.name;
            var value = result.value;
            var name_hash: u64 = undefined;
            if (result.name_needs_decoding) {
                name.length = PercentEncoding.decode(Writer, &writer, scanner.query.query_string[name.offset..][0..name.length]) catch continue;
                name.offset = buf_writer_pos;
                buf_writer_pos += name.length;
                name_hash = bun.hash(buf.items[name.offset..][0..name.length]);
            } else {
                name_hash = bun.hash(result.rawName(scanner.query.query_string));
                if (std.mem.indexOfScalar(u64, list_slice.items(.name_hash), name_hash)) |index| {

                    // query string parameters should not override route parameters
                    // see https://nextjs.org/docs/routing/dynamic-routes
                    if (index < route_parameter_begin) {
                        continue;
                    }

                    name = list_slice.items(.name)[index];
                } else {
                    name.length = PercentEncoding.decode(Writer, &writer, scanner.query.query_string[name.offset..][0..name.length]) catch continue;
                    name.offset = buf_writer_pos;
                    buf_writer_pos += name.length;
                }
            }

            value.length = PercentEncoding.decode(Writer, &writer, scanner.query.query_string[value.offset..][0..value.length]) catch continue;
            value.offset = buf_writer_pos;
            buf_writer_pos += value.length;

            list.appendAssumeCapacity(Param{ .name = name, .value = value, .name_hash = name_hash });
        }

        buf.expandToCapacity();
        return QueryStringMap{
            .list = list,
            .buffer = buf.items,
            .slice = buf.items[0..buf_writer_pos],
            .allocator = allocator,
        };
    }

    pub fn init(
        allocator: std.mem.Allocator,
        query_string: string,
    ) bun.OOM!?QueryStringMap {
        var list = Param.List{};

        var scanner = Scanner.init(query_string);
        var count: usize = 0;
        var estimated_str_len: usize = 0;

        var nothing_needs_decoding = true;
        while (scanner.next()) |result| {
            if (result.name_needs_decoding or result.value_needs_decoding) {
                nothing_needs_decoding = false;
            }
            estimated_str_len += result.name.length + result.value.length;
            count += 1;
        }

        if (count == 0) return null;

        scanner = Scanner.init(query_string);
        try list.ensureTotalCapacity(allocator, count);

        if (nothing_needs_decoding) {
            scanner = Scanner.init(query_string);
            while (scanner.next()) |result| {
                if (Environment.allow_assert) bun.assert(!result.name_needs_decoding);
                if (Environment.allow_assert) bun.assert(!result.value_needs_decoding);

                const name = result.name;
                const value = result.value;
                const name_hash: u64 = bun.hash(result.rawName(query_string));
                list.appendAssumeCapacity(Param{ .name = name, .value = value, .name_hash = name_hash });
            }

            return QueryStringMap{
                .list = list,
                .buffer = &[_]u8{},
                .slice = query_string,
                .allocator = allocator,
            };
        }

        var buf = try std.array_list.Managed(u8).initCapacity(allocator, estimated_str_len);
        var writer = ManagedU8Writer{ .list = &buf };
        var buf_writer_pos: u32 = 0;

        var list_slice = list.slice();
        const Writer = *ManagedU8Writer;
        while (scanner.next()) |result| {
            var name = result.name;
            var value = result.value;
            var name_hash: u64 = undefined;
            if (result.name_needs_decoding) {
                name.length = PercentEncoding.decode(Writer, &writer, query_string[name.offset..][0..name.length]) catch continue;
                name.offset = buf_writer_pos;
                buf_writer_pos += name.length;
                name_hash = bun.hash(buf.items[name.offset..][0..name.length]);
            } else {
                name_hash = bun.hash(result.rawName(query_string));
                if (std.mem.indexOfScalar(u64, list_slice.items(.name_hash), name_hash)) |index| {
                    name = list_slice.items(.name)[index];
                } else {
                    name.length = PercentEncoding.decode(Writer, &writer, query_string[name.offset..][0..name.length]) catch continue;
                    name.offset = buf_writer_pos;
                    buf_writer_pos += name.length;
                }
            }

            value.length = PercentEncoding.decode(Writer, &writer, query_string[value.offset..][0..value.length]) catch continue;
            value.offset = buf_writer_pos;
            buf_writer_pos += value.length;

            list.appendAssumeCapacity(Param{ .name = name, .value = value, .name_hash = name_hash });
        }

        buf.expandToCapacity();
        return QueryStringMap{
            .list = list,
            .buffer = buf.items,
            .slice = buf.items[0..buf_writer_pos],
            .allocator = allocator,
        };
    }

    pub fn deinit(this: *QueryStringMap) void {
        if (this.buffer.len > 0) {
            this.allocator.free(this.buffer);
        }

        if (this.list.len > 0) {
            this.list.deinit(this.allocator);
        }
    }
};

pub const PercentEncoding = struct {
    pub fn decode(comptime Writer: type, writer: Writer, input: string) !u32 {
        return @call(bun.callmod_inline, decodeFaultTolerant, .{ Writer, writer, input, null, false });
    }

    /// Decode percent-encoded input into allocated memory.
    /// Caller owns the returned slice and must free it with the same allocator.
    pub fn decodeAlloc(allocator: std.mem.Allocator, input: string) ![]u8 {
        // Allocate enough space - decoded will be at most input.len bytes
        const buf = try allocator.alloc(u8, input.len);
        errdefer allocator.free(buf);

        var writer = FixedBufferWriter{ .buffer = buf };
        const len = try decode(*FixedBufferWriter, &writer, input);

        return buf[0..len];
    }

    pub fn decodeFaultTolerant(
        comptime Writer: type,
        writer: Writer,
        input: string,
        needs_redirect: ?*bool,
        comptime fault_tolerant: bool,
    ) !u32 {
        var i: usize = 0;
        var written: u32 = 0;
        // unlike JavaScript's decodeURIComponent, we are not handling invalid surrogate pairs
        // we are assuming the input is valid ascii
        while (i < input.len) {
            switch (input[i]) {
                '%' => {
                    if (comptime fault_tolerant) {
                        if (!(i + 3 <= input.len and strings.isASCIIHexDigit(input[i + 1]) and strings.isASCIIHexDigit(input[i + 2]))) {
                            // i do not feel good about this
                            // create-react-app's public/index.html uses %PUBLIC_URL% in various tags
                            // This is an invalid %-encoded string, intended to be swapped out at build time by webpack-html-plugin
                            // We don't process HTML, so rewriting this URL path won't happen
                            // But we want to be a little more fault tolerant here than just throwing up an error for something that works in other tools
                            // So we just skip over it and issue a redirect
                            // We issue a redirect because various other tooling client-side may validate URLs
                            // We can't expect other tools to be as fault tolerant
                            if (i + "PUBLIC_URL%".len < input.len and strings.eqlComptime(input[i + 1 ..][0.."PUBLIC_URL%".len], "PUBLIC_URL%")) {
                                i += "PUBLIC_URL%".len + 1;
                                needs_redirect.?.* = true;
                                continue;
                            }
                            return error.DecodingError;
                        }
                    } else {
                        if (!(i + 3 <= input.len and strings.isASCIIHexDigit(input[i + 1]) and strings.isASCIIHexDigit(input[i + 2])))
                            return error.DecodingError;
                    }

                    try writer.writeByte((strings.toASCIIHexValue(input[i + 1]) << 4) | strings.toASCIIHexValue(input[i + 2]));
                    i += 3;
                    written += 1;
                    continue;
                },
                else => {
                    const start = i;
                    i += 1;

                    // scan ahead assuming .writeAll is faster than .writeByte one at a time
                    while (i < input.len and input[i] != '%') : (i += 1) {}
                    try writer.writeAll(input[start..i]);
                    written += @as(u32, @truncate(i - start));
                },
            }
        }

        return written;
    }
};

// FormData moved to `runtime/webcore/FormData.zig` upstream. Keep the name
// present for old imports without pulling the JSC/webcore subtree into this
// pure URL helper leaf.
pub const FormData = struct {};

pub const CombinedScanner = struct {
    query: Scanner,
    pathname: PathnameScanner,
    pub fn init(query_string: string, pathname: string, routename: string, url_params: anytype) CombinedScanner {
        return CombinedScanner{
            .query = Scanner.init(query_string),
            .pathname = PathnameScanner.init(pathname, routename, url_params),
        };
    }

    pub fn reset(this: *CombinedScanner) void {
        this.query.reset();
        this.pathname.reset();
    }

    pub fn next(this: *CombinedScanner) ?Scanner.Result {
        return this.pathname.next() orelse this.query.next();
    }
};

fn stringPointerFromStrings(parent: string, in: string) api.StringPointer {
    if (in.len == 0 or parent.len == 0) return api.StringPointer{};

    if (bun.rangeOfSliceInBuffer(in, parent)) |range| {
        return api.StringPointer{ .offset = range[0], .length = range[1] };
    } else {
        if (strings.indexOf(parent, in)) |i| {
            if (comptime Environment.allow_assert) {
                bun.assert(strings.eqlLong(parent[i..][0..in.len], in, false));
            }

            return api.StringPointer{
                .offset = @as(u32, @truncate(i)),
                .length = @as(u32, @truncate(in.len)),
            };
        }
    }

    return api.StringPointer{};
}

pub const PathnameScanner = struct {
    params: *anyopaque,
    lenFn: *const fn (*anyopaque) usize,
    getFn: *const fn (*anyopaque, usize) RouteParam,
    pathname: string,
    routename: string,
    i: usize = 0,

    pub inline fn isDone(this: *const PathnameScanner) bool {
        return this.lenFn(this.params) <= this.i;
    }

    pub fn reset(this: *PathnameScanner) void {
        this.i = 0;
    }

    pub fn init(pathname: string, routename: string, params: anytype) PathnameScanner {
        const ParamsPtr = @TypeOf(params);
        const Params = @typeInfo(ParamsPtr).pointer.child;
        const VTable = struct {
            fn len(ctx: *anyopaque) usize {
                const typed: ParamsPtr = @ptrCast(@alignCast(ctx));
                return typed.len;
            }

            fn get(ctx: *anyopaque, index: usize) RouteParam {
                const typed: ParamsPtr = @ptrCast(@alignCast(ctx));
                const param = typed.get(index);
                return RouteParam{ .name = param.name, .value = param.value };
            }
        };
        _ = Params;

        return PathnameScanner{
            .pathname = pathname,
            .routename = routename,
            .params = @ptrCast(params),
            .lenFn = VTable.len,
            .getFn = VTable.get,
        };
    }

    pub fn next(this: *PathnameScanner) ?Scanner.Result {
        if (this.isDone()) {
            return null;
        }

        defer this.i += 1;
        const param = this.getFn(this.params, this.i);

        return Scanner.Result{
            // TODO: fix this technical debt
            .name = stringPointerFromStrings(this.routename, param.name),
            .name_needs_decoding = false,
            // TODO: fix this technical debt
            .value = stringPointerFromStrings(this.pathname, param.value),
            .value_needs_decoding = strings.containsChar(param.value, '%'),
        };
    }
};

pub const Scanner = struct {
    query_string: string,
    i: usize,
    start: usize = 0,

    pub fn init(query_string: string) Scanner {
        if (query_string.len > 0 and query_string[0] == '?') {
            return Scanner{ .query_string = query_string, .i = 1, .start = 1 };
        }

        return Scanner{ .query_string = query_string, .i = 0, .start = 0 };
    }

    pub inline fn reset(this: *Scanner) void {
        this.i = this.start;
    }

    pub const Result = struct {
        name_needs_decoding: bool = false,
        value_needs_decoding: bool = false,
        name: api.StringPointer,
        value: api.StringPointer,

        pub inline fn rawName(this: *const Result, query_string: string) string {
            return if (this.name.length > 0) query_string[this.name.offset..][0..this.name.length] else "";
        }

        pub inline fn rawValue(this: *const Result, query_string: string) string {
            return if (this.value.length > 0) query_string[this.value.offset..][0..this.value.length] else "";
        }
    };

    /// Get the next query string parameter without allocating memory.
    pub fn next(this: *Scanner) ?Result {
        var relative_i: usize = 0;
        defer this.i += relative_i;

        // reuse stack space
        // otherwise we'd recursively call the function
        loop: while (true) {
            if (this.i >= this.query_string.len) return null;

            const slice = this.query_string[this.i..];
            relative_i = 0;
            var name = api.StringPointer{ .offset = @as(u32, @truncate(this.i)), .length = 0 };
            var value = api.StringPointer{ .offset = 0, .length = 0 };
            var name_needs_decoding = false;

            while (relative_i < slice.len) {
                const char = slice[relative_i];
                switch (char) {
                    '=' => {
                        name.length = @as(u32, @truncate(relative_i));
                        relative_i += 1;

                        value.offset = @as(u32, @truncate(relative_i + this.i));

                        const offset = relative_i;
                        var value_needs_decoding = false;
                        while (relative_i < slice.len and slice[relative_i] != '&') : (relative_i += 1) {
                            value_needs_decoding = value_needs_decoding or switch (slice[relative_i]) {
                                '%', '+' => true,
                                else => false,
                            };
                        }
                        value.length = @as(u32, @truncate(relative_i - offset));
                        // If the name is empty and it's just a value, skip it.
                        // This is kind of an opinion. But, it's hard to see where that might be intentional.
                        if (name.length == 0) return null;
                        return Result{ .name = name, .value = value, .name_needs_decoding = name_needs_decoding, .value_needs_decoding = value_needs_decoding };
                    },
                    '%', '+' => {
                        name_needs_decoding = true;
                    },
                    '&' => {
                        // key&
                        if (relative_i > 0) {
                            name.length = @as(u32, @truncate(relative_i));
                            return Result{ .name = name, .value = value, .name_needs_decoding = name_needs_decoding, .value_needs_decoding = false };
                        }

                        // &&&&&&&&&&&&&key=value
                        while (relative_i < slice.len and slice[relative_i] == '&') : (relative_i += 1) {}
                        this.i += relative_i;

                        // reuse stack space
                        continue :loop;
                    },
                    else => {},
                }

                relative_i += 1;
            }

            if (relative_i == 0) {
                return null;
            }

            name.length = @as(u32, @truncate(relative_i));
            return Result{ .name = name, .value = value, .name_needs_decoding = name_needs_decoding };
        }
    }
};

const RouteParam = struct {
    name: string,
    value: string,
};

const string = []const u8;

const std = @import("std");
const expect = std.testing.expect;

const builtin = @import("builtin");

const Environment = struct {
    pub const allow_assert = builtin.mode == .Debug;
    pub const isDebug = builtin.mode == .Debug;
};

const Output = struct {
    pub fn scoped(comptime _: anytype, comptime _: anytype) type {
        return struct {};
    }
};

const api = struct {
    pub const StringPointer = extern struct {
        offset: u32 = 0,
        length: u32 = 0,
    };
};

const StringFns = struct {
    pub inline fn eqlComptime(a: []const u8, comptime b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }

    pub inline fn hasPrefixComptime(a: []const u8, comptime b: []const u8) bool {
        return std.mem.startsWith(u8, a, b);
    }

    pub inline fn endsWithComptime(a: []const u8, comptime b: []const u8) bool {
        return std.mem.endsWith(u8, a, b);
    }

    pub inline fn indexOfChar(a: []const u8, c: u8) ?usize {
        return std.mem.indexOfScalar(u8, a, c);
    }

    pub inline fn containsChar(a: []const u8, c: u8) bool {
        return std.mem.indexOfScalar(u8, a, c) != null;
    }

    pub inline fn indexOf(a: []const u8, b: []const u8) ?usize {
        return std.mem.indexOf(u8, a, b);
    }

    pub inline fn eqlLong(a: []const u8, b: []const u8, _: bool) bool {
        return std.mem.eql(u8, a, b);
    }

    pub inline fn isASCIIHexDigit(c: u8) bool {
        return std.ascii.isHex(c);
    }

    pub inline fn toASCIIHexValue(c: u8) u8 {
        return std.fmt.charToDigit(c, 16) catch 0;
    }

    pub fn isIPAddress(input: []const u8) bool {
        if (std.mem.indexOfScalar(u8, input, ':') != null) {
            return true;
        }

        var parts = std.mem.splitScalar(u8, input, '.');
        var count: usize = 0;
        while (parts.next()) |part| {
            if (part.len == 0) return false;
            _ = std.fmt.parseInt(u8, part, 10) catch return false;
            count += 1;
        }
        return count == 4;
    }
};

const strings = StringFns;

const bun = struct {
    pub const OOM = error{OutOfMemory};
    pub const callmod_inline: std.builtin.CallModifier = if (builtin.mode == .Debug) .auto else .always_inline;
    pub const strings = StringFns;
    pub const bit_set = std.bit_set;

    pub const fmt = struct {
        pub const HostFormatter = struct {
            host: []const u8,
            port: ?u16 = null,
            is_https: bool = false,

            pub fn format(self: HostFormatter, writer: *std.Io.Writer) !void {
                if (self.host.len == 0) return;
                const is_ipv6 = std.mem.indexOfScalar(u8, self.host, ':') != null;
                if (is_ipv6) try writer.writeByte('[');
                try writer.writeAll(self.host);
                if (is_ipv6) try writer.writeByte(']');
                if (self.port) |port| {
                    if (!((self.is_https and port == 443) or (!self.is_https and port == 80))) {
                        try writer.print(":{d}", .{port});
                    }
                }
            }
        };
    };

    pub inline fn assert(ok: bool) void {
        std.debug.assert(ok);
    }

    pub inline fn copy(comptime T: type, dest: []T, src: []const T) void {
        @memcpy(dest[0..src.len], src);
    }

    pub inline fn hash(input: []const u8) u64 {
        return std.hash.Wyhash.hash(0, input);
    }

    pub fn isSliceInBuffer(slice: []const u8, buffer: []const u8) bool {
        if (slice.len == 0) return true;
        if (buffer.len == 0) return false;
        const slice_start = @intFromPtr(slice.ptr);
        const slice_end = slice_start + slice.len;
        const buffer_start = @intFromPtr(buffer.ptr);
        const buffer_end = buffer_start + buffer.len;
        return slice_start >= buffer_start and slice_end <= buffer_end;
    }

    pub fn rangeOfSliceInBuffer(slice: []const u8, buffer: []const u8) ?[2]u32 {
        if (!isSliceInBuffer(slice, buffer)) return null;
        const offset = @intFromPtr(slice.ptr) - @intFromPtr(buffer.ptr);
        return .{ @as(u32, @truncate(offset)), @as(u32, @truncate(slice.len)) };
    }
};

const ManagedU8Writer = struct {
    list: *std.array_list.Managed(u8),

    pub fn writeAll(this: *ManagedU8Writer, bytes: []const u8) !void {
        try this.list.appendSlice(bytes);
    }

    pub fn writeByte(this: *ManagedU8Writer, byte: u8) !void {
        try this.list.append(byte);
    }
};

pub const FixedBufferWriter = struct {
    buffer: []u8,
    pos: usize = 0,

    pub fn writeAll(this: *FixedBufferWriter, bytes: []const u8) !void {
        if (this.pos + bytes.len > this.buffer.len) return error.NoSpaceLeft;
        @memcpy(this.buffer[this.pos..][0..bytes.len], bytes);
        this.pos += bytes.len;
    }

    pub fn writeByte(this: *FixedBufferWriter, byte: u8) !void {
        if (this.pos >= this.buffer.len) return error.NoSpaceLeft;
        this.buffer[this.pos] = byte;
        this.pos += 1;
    }
};

fn normalizeURLPath(input: []const u8, out: []u8) []const u8 {
    var segments: [128][]const u8 = undefined;
    var segment_count: usize = 0;

    var it = std.mem.splitScalar(u8, input, '/');
    while (it.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) {
            continue;
        }

        if (std.mem.eql(u8, segment, "..")) {
            if (segment_count > 0) segment_count -= 1;
            continue;
        }

        if (segment_count < segments.len) {
            segments[segment_count] = segment;
            segment_count += 1;
        }
    }

    var i: usize = 0;
    out[i] = '/';
    i += 1;

    for (segments[0..segment_count], 0..) |segment, index| {
        if (index > 0) {
            out[i] = '/';
            i += 1;
        }
        @memcpy(out[i..][0..segment.len], segment);
        i += segment.len;
    }

    return out[0..i];
}

test "URL.parse slices common URL components" {
    const url = URL.parse("https://user:pass@example.com:9443/a/b?x=1#top");
    try std.testing.expectEqualStrings("https", url.protocol);
    try std.testing.expectEqualStrings("user", url.username);
    try std.testing.expectEqualStrings("pass", url.password);
    try std.testing.expectEqualStrings("example.com:9443", url.host);
    try std.testing.expectEqualStrings("example.com", url.hostname);
    try std.testing.expectEqualStrings("9443", url.port);
    try std.testing.expectEqualStrings("/a/b?x=1", url.pathname);
    try std.testing.expectEqualStrings("?x=1", url.search);
    try std.testing.expectEqualStrings("#top", url.hash);
    try std.testing.expectEqual(@as(?u16, 9443), url.getPort());
}

test "URL.hostWithPath returns host plus path without trailing slash" {
    const url = URL.parse("http://localhost:3000/assets/app/");
    try std.testing.expectEqualStrings("localhost:3000/assets/app", url.hostWithPath());
}

test "Scanner skips empty parameters and preserves bare keys" {
    var scanner = Scanner.init("?&&a=1&b&c=three");
    var first = scanner.next().?;
    try std.testing.expectEqualStrings("a", first.rawName(scanner.query_string));
    try std.testing.expectEqualStrings("1", first.rawValue(scanner.query_string));

    var second = scanner.next().?;
    try std.testing.expectEqualStrings("b", second.rawName(scanner.query_string));
    try std.testing.expectEqualStrings("", second.rawValue(scanner.query_string));

    var third = scanner.next().?;
    try std.testing.expectEqualStrings("c", third.rawName(scanner.query_string));
    try std.testing.expectEqualStrings("three", third.rawValue(scanner.query_string));
}

test "QueryStringMap decodes percent encoded names and values" {
    var map = (try QueryStringMap.init(std.testing.allocator, "?na%6De=va%6Cue&name=second")).?;
    defer map.deinit();

    try std.testing.expect(map.has("name"));
    try std.testing.expectEqualStrings("value", map.get("name").?);

    var values: [4]string = undefined;
    try std.testing.expectEqual(@as(usize, 2), map.getAll("name", &values));
    try std.testing.expectEqualStrings("value", values[0]);
    try std.testing.expectEqualStrings("second", values[1]);
}

test "CombinedScanner merges route params before query params" {
    const Param = struct {
        name: string,
        value: string,
    };

    var params = std.MultiArrayList(Param){};
    defer params.deinit(std.testing.allocator);
    try params.append(std.testing.allocator, .{ .name = "slug", .value = "hello%20home" });

    var map = (try QueryStringMap.initWithScanner(
        std.testing.allocator,
        CombinedScanner.init("?slug=query&view=list", "/posts/hello%20home", "/posts/[slug]", &params),
    )).?;
    defer map.deinit();

    try std.testing.expectEqualStrings("hello home", map.get("slug").?);
    try std.testing.expectEqualStrings("list", map.get("view").?);
}

test "PercentEncoding.decode rejects malformed escapes" {
    var buf: [16]u8 = undefined;
    var writer = FixedBufferWriter{ .buffer = &buf };

    try std.testing.expectEqual(@as(u32, 3), try PercentEncoding.decode(*FixedBufferWriter, &writer, "a%2Fb"));
    try std.testing.expectEqualStrings("a/b", buf[0..writer.pos]);
    try std.testing.expectError(error.DecodingError, PercentEncoding.decode(*FixedBufferWriter, &writer, "%zz"));
}

test "URL.joinNormalize collapses dot segments" {
    var out: [256]u8 = undefined;
    const normalized = URL.joinNormalize(&out, "assets/", "pages/../home", "index", ".js");
    try std.testing.expectEqualStrings("/assets/home/index.js", normalized);
}
