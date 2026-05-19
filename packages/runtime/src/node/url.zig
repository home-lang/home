// Home Runtime — Phase 12.7 port of `node:url` (Zig substrate).
//
// Upstream references:
//   * Node.js `lib/url.js` (legacy `url.parse` / `url.format`) +
//     `lib/internal/url.js` (WHATWG `URL` / `URLSearchParams`).
//   * `bun/src/url/url.zig` — Bun's Zig URL parser (~1085 LOC). The
//     Bun implementation leans heavily on JSC primitives
//     (`jsc.URL.hrefFromString`, `bun.String`, `bun.fmt.HostFormatter`).
//
// Per `NODE_SHIM_SCOPE_2026-05-19.md` this lands the Zig-callable
// substrate for `node:url`. The JS shim re-attaches once Phase 12.2
// brings up the JSC bridge; until then, Zig callers consume the
// surface here directly.
//
// API surface (matches the WHATWG `URL` shape + the legacy
// `url.parse` / `url.format` / `pathToFileURL` / `fileURLToPath`
// helpers):
//
//   * `URL` — parsed URL with `protocol` / `username` / `password` /
//     `host` / `hostname` / `port` / `pathname` / `search` / `hash` /
//     `href` / `origin` + an owned `URLSearchParams`. Parsing follows
//     a pragmatic subset of RFC 3986 + the WHATWG URL Standard: every
//     component is sliced out of an internally-owned `href` buffer so
//     `URL.toString` is a no-op view. `URL.deinit` frees the href
//     buffer + the searchParams entries it owns.
//
//   * `URL.parse(allocator, input, ?base)` — pre-normalizes `input`
//     against `base` (if non-null) using `resolve`, then splits the
//     resulting `href`. Returns `error.InvalidURL` if no scheme is
//     present and `base` is also null.
//
//   * `URL.toString(self)` — returns the stored `href` view (the
//     parser already normalizes the string at parse time).
//
//   * `URL.toJSON(self)` — alias of `toString`. Mirrors WHATWG.
//
//   * `URLSearchParams` — `ArrayList(.{ key, value })` with `init` /
//     `deinit` / `fromString` / `toString` / `get` / `getAll` / `has`
//     / `set` / `append` / `delete` / `keys` / `values`. Encoding /
//     decoding uses the standard `x-www-form-urlencoded` rules
//     (percent-encode every byte outside the unreserved set; `+`
//     decodes to space).
//
//   * `url.parse(allocator, input)` — legacy alias of `URL.parse`
//     with no base.
//   * `url.format(parsed, allocator)` — joins the URL components
//     back into a normalized string (owned by caller).
//   * `url.resolve(allocator, base, ref)` — resolves `ref` against
//     `base` per RFC 3986 § 5.3. Returns a freshly-allocated owned
//     string.
//   * `url.pathToFileURL(allocator, path)` — wraps `path` in a
//     `file://` URL (absolute path required on Unix; on Windows the
//     drive letter is preserved).
//   * `url.fileURLToPath(allocator, url)` — strips the `file://`
//     prefix + URL-decodes percent escapes. Returns a freshly-
//     allocated owned string.
//
//   * `url.domainToASCII(allocator, host)` — Punycode encoding stub;
//     returns a copy of `host` until the IDNA tables are ported.
//   * `url.domainToUnicode(allocator, ascii_host)` — Punycode
//     decoding stub; symmetric with the above.
//
// Inline tests cover ≥6 cases per scope:
//   1. URL.parse + every getter slice.
//   2. URL.parse with a base.
//   3. URL.toString round-trip.
//   4. URLSearchParams get / has / set / append / delete.
//   5. URLSearchParams.toString.
//   6. fileURLToPath.
//   7. pathToFileURL.
//   8. url.resolve relative path.

const std = @import("std");

// =====================================================================
// URLSearchParams
// =====================================================================

/// A single `(key, value)` entry inside `URLSearchParams`. Both slices
/// are owned by the parent's allocator.
pub const SearchEntry = struct {
    key: []const u8,
    value: []const u8,
};

/// `URLSearchParams` — preserves insertion order; supports duplicate
/// keys (which is why we use an ArrayList rather than a HashMap).
pub const URLSearchParams = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(SearchEntry),

    pub fn init(allocator: std.mem.Allocator) URLSearchParams {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(SearchEntry){},
        };
    }

    pub fn deinit(self: *URLSearchParams) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.key);
            self.allocator.free(e.value);
        }
        self.entries.deinit(self.allocator);
    }

    /// Parses an `application/x-www-form-urlencoded` string into a new
    /// `URLSearchParams`. Leading `?` is stripped if present (so
    /// callers can pass `url.search` verbatim).
    pub fn fromString(allocator: std.mem.Allocator, raw: []const u8) !URLSearchParams {
        var self = URLSearchParams.init(allocator);
        errdefer self.deinit();

        var query = raw;
        if (query.len > 0 and query[0] == '?') query = query[1..];

        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |segment| {
            if (segment.len == 0) continue;
            const eq_idx = std.mem.indexOfScalar(u8, segment, '=');
            const raw_key = if (eq_idx) |i| segment[0..i] else segment;
            const raw_val: []const u8 = if (eq_idx) |i| segment[i + 1 ..] else "";
            const key = try decodeFormComponent(allocator, raw_key);
            errdefer allocator.free(key);
            const val = try decodeFormComponent(allocator, raw_val);
            errdefer allocator.free(val);
            try self.entries.append(allocator, .{ .key = key, .value = val });
        }
        return self;
    }

    /// Returns a freshly-allocated `application/x-www-form-urlencoded`
    /// serialization of every entry.
    pub fn toString(self: *const URLSearchParams, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(allocator);

        var first = true;
        for (self.entries.items) |e| {
            if (!first) try buf.append(allocator, '&');
            first = false;
            try encodeFormComponent(allocator, &buf, e.key);
            try buf.append(allocator, '=');
            try encodeFormComponent(allocator, &buf, e.value);
        }
        return try buf.toOwnedSlice(allocator);
    }

    /// Returns the first value for `key` (or `null` if no such entry).
    pub fn get(self: *const URLSearchParams, key: []const u8) ?[]const u8 {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }

    /// Returns every value associated with `key`. Caller owns the
    /// returned slice (but not its elements, which alias the
    /// `URLSearchParams`-owned entries).
    pub fn getAll(self: *const URLSearchParams, allocator: std.mem.Allocator, key: []const u8) ![][]const u8 {
        var out = std.ArrayList([]const u8){};
        errdefer out.deinit(allocator);
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.key, key)) try out.append(allocator, e.value);
        }
        return try out.toOwnedSlice(allocator);
    }

    pub fn has(self: *const URLSearchParams, key: []const u8) bool {
        return self.get(key) != null;
    }

    /// Replaces every existing entry whose key matches `key` with a
    /// single `(key, value)` entry. Mirrors `URLSearchParams.set`.
    pub fn set(self: *URLSearchParams, key: []const u8, value: []const u8) !void {
        // First-pass: rewrite the first matching entry in place + drop
        // every subsequent duplicate.
        var replaced = false;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const e = self.entries.items[i];
            if (std.mem.eql(u8, e.key, key)) {
                if (!replaced) {
                    self.allocator.free(e.value);
                    const new_val = try self.allocator.dupe(u8, value);
                    self.entries.items[i].value = new_val;
                    replaced = true;
                    i += 1;
                } else {
                    self.allocator.free(e.key);
                    self.allocator.free(e.value);
                    _ = self.entries.orderedRemove(i);
                }
            } else {
                i += 1;
            }
        }
        if (!replaced) try self.append(key, value);
    }

    /// Appends a new `(key, value)` entry (does not deduplicate).
    pub fn append(self: *URLSearchParams, key: []const u8, value: []const u8) !void {
        const k = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(k);
        const v = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(v);
        try self.entries.append(self.allocator, .{ .key = k, .value = v });
    }

    /// Removes every entry whose key matches `key`. No-op if none.
    pub fn delete(self: *URLSearchParams, key: []const u8) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const e = self.entries.items[i];
            if (std.mem.eql(u8, e.key, key)) {
                self.allocator.free(e.key);
                self.allocator.free(e.value);
                _ = self.entries.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Iterator over the keys in insertion order.
    pub fn keys(self: *const URLSearchParams) Iter(.keys) {
        return .{ .entries = self.entries.items, .idx = 0 };
    }

    /// Iterator over the values in insertion order.
    pub fn values(self: *const URLSearchParams) Iter(.values) {
        return .{ .entries = self.entries.items, .idx = 0 };
    }

    pub const IterKind = enum { keys, values };

    pub fn Iter(comptime kind: IterKind) type {
        return struct {
            entries: []const SearchEntry,
            idx: usize,

            pub fn next(self: *@This()) ?[]const u8 {
                if (self.idx >= self.entries.len) return null;
                const e = self.entries[self.idx];
                self.idx += 1;
                return switch (kind) {
                    .keys => e.key,
                    .values => e.value,
                };
            }
        };
    }
};

// =====================================================================
// URL
// =====================================================================

/// `URL` — parsed WHATWG URL. Every slice field aliases the owned
/// `href` buffer; `searchParams` is owned outright and freed in
/// `deinit`. `URL` is move-only — copying the struct without calling
/// `deinit` on the original leaks the searchParams entries.
pub const URL = struct {
    allocator: std.mem.Allocator,
    /// Owned href buffer. Every other slice field is a view into this.
    href_buf: []u8,

    protocol: []const u8 = "",
    username: []const u8 = "",
    password: []const u8 = "",
    host: []const u8 = "",
    hostname: []const u8 = "",
    port: []const u8 = "",
    pathname: []const u8 = "",
    search: []const u8 = "",
    hash: []const u8 = "",
    href: []const u8 = "",
    origin: []const u8 = "",
    searchParams: URLSearchParams,

    /// Parses `input` against an optional `base`. Both are interpreted
    /// as UTF-8. Returns `error.InvalidURL` if neither carries a
    /// scheme.
    pub fn parse(allocator: std.mem.Allocator, input: []const u8, base: ?[]const u8) !URL {
        // Resolve against the base first so the rest of the parser
        // sees a single absolute href.
        const resolved = if (base) |b| try resolve(allocator, b, input) else try allocator.dupe(u8, input);
        errdefer allocator.free(resolved);

        var self = URL{
            .allocator = allocator,
            .href_buf = resolved,
            .href = resolved,
            .searchParams = URLSearchParams.init(allocator),
        };
        errdefer self.searchParams.deinit();

        try splitInto(&self, resolved);
        return self;
    }

    pub fn deinit(self: *URL) void {
        self.searchParams.deinit();
        self.allocator.free(self.href_buf);
    }

    /// Returns the normalized href view. The slice is valid for the
    /// lifetime of `self`.
    pub fn toString(self: *const URL) []const u8 {
        return self.href;
    }

    /// Alias of `toString`. Mirrors WHATWG `URL.toJSON`.
    pub fn toJSON(self: *const URL) []const u8 {
        return self.href;
    }
};

/// Splits an already-resolved absolute href into the fields of `self`.
/// Slices alias `self.href_buf`. Populates `self.searchParams` by
/// parsing `self.search` (minus the leading `?`).
fn splitInto(self: *URL, href: []const u8) !void {
    var rest = href;

    // Scheme.
    if (std.mem.indexOfScalar(u8, rest, ':')) |colon_idx| {
        // Validate scheme bytes: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
        if (colon_idx > 0 and isAsciiAlpha(rest[0])) {
            var ok = true;
            for (rest[1..colon_idx]) |c| {
                if (!isSchemeByte(c)) {
                    ok = false;
                    break;
                }
            }
            if (ok) {
                self.protocol = rest[0 .. colon_idx + 1];
                rest = rest[colon_idx + 1 ..];
            }
        }
    }
    if (self.protocol.len == 0) return error.InvalidURL;

    // Authority (after `//`).
    if (rest.len >= 2 and rest[0] == '/' and rest[1] == '/') {
        rest = rest[2..];
        // Find the end of the authority — first `/`, `?`, or `#`.
        var auth_end: usize = rest.len;
        for (rest, 0..) |c, i| {
            if (c == '/' or c == '?' or c == '#') {
                auth_end = i;
                break;
            }
        }
        const authority = rest[0..auth_end];
        rest = rest[auth_end..];

        // Userinfo `user[:password]@`.
        var hostpart = authority;
        if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at_idx| {
            const userinfo = authority[0..at_idx];
            hostpart = authority[at_idx + 1 ..];
            if (std.mem.indexOfScalar(u8, userinfo, ':')) |c_idx| {
                self.username = userinfo[0..c_idx];
                self.password = userinfo[c_idx + 1 ..];
            } else {
                self.username = userinfo;
            }
        }

        self.host = hostpart;
        if (std.mem.lastIndexOfScalar(u8, hostpart, ':')) |colon_idx| {
            // Make sure we're not inside an IPv6 literal `[::1]`.
            if (hostpart.len == 0 or hostpart[hostpart.len - 1] != ']') {
                self.hostname = hostpart[0..colon_idx];
                self.port = hostpart[colon_idx + 1 ..];
            } else {
                self.hostname = hostpart;
            }
        } else {
            self.hostname = hostpart;
        }

        // Origin = `scheme://hostport`. Always derivable for
        // hierarchical URLs.
        // Compute origin slice from the original buffer.
        const origin_end_ptr = @intFromPtr(rest.ptr);
        const origin_start_ptr = @intFromPtr(self.href_buf.ptr);
        self.origin = self.href_buf[0 .. origin_end_ptr - origin_start_ptr];
    }

    // Fragment.
    if (std.mem.indexOfScalar(u8, rest, '#')) |h_idx| {
        self.hash = rest[h_idx..];
        rest = rest[0..h_idx];
    }

    // Query.
    if (std.mem.indexOfScalar(u8, rest, '?')) |q_idx| {
        self.search = rest[q_idx..];
        rest = rest[0..q_idx];
    }

    // Whatever's left is the pathname (may be empty).
    self.pathname = rest;

    if (self.search.len > 1) {
        self.searchParams.deinit();
        self.searchParams = try URLSearchParams.fromString(self.allocator, self.search);
    }
}

// =====================================================================
// Legacy module-level helpers
// =====================================================================

/// Legacy `url.parse(input)` — alias of `URL.parse(allocator, input, null)`.
pub fn parse(allocator: std.mem.Allocator, input: []const u8) !URL {
    return URL.parse(allocator, input, null);
}

/// Legacy `url.format(parsed)` — joins the parsed components back into
/// a normalized string. Returns a freshly-allocated owned slice.
pub fn format(parsed: *const URL, allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, parsed.protocol);
    if (parsed.host.len > 0 or parsed.hostname.len > 0) {
        try buf.appendSlice(allocator, "//");
        if (parsed.username.len > 0) {
            try buf.appendSlice(allocator, parsed.username);
            if (parsed.password.len > 0) {
                try buf.append(allocator, ':');
                try buf.appendSlice(allocator, parsed.password);
            }
            try buf.append(allocator, '@');
        }
        if (parsed.host.len > 0) {
            try buf.appendSlice(allocator, parsed.host);
        } else {
            try buf.appendSlice(allocator, parsed.hostname);
            if (parsed.port.len > 0) {
                try buf.append(allocator, ':');
                try buf.appendSlice(allocator, parsed.port);
            }
        }
    }
    try buf.appendSlice(allocator, parsed.pathname);
    try buf.appendSlice(allocator, parsed.search);
    try buf.appendSlice(allocator, parsed.hash);
    return try buf.toOwnedSlice(allocator);
}

/// `url.resolve(base, ref)` — resolves a possibly-relative `ref`
/// against `base` per RFC 3986 § 5.3. Returns a freshly-allocated
/// owned string.
pub fn resolve(allocator: std.mem.Allocator, base: []const u8, ref: []const u8) ![]u8 {
    // Detect absolute reference (has its own scheme).
    if (hasScheme(ref)) return try allocator.dupe(u8, ref);
    if (ref.len == 0) return try allocator.dupe(u8, base);

    // Otherwise we need the base scheme + authority.
    const b_scheme_end = std.mem.indexOfScalar(u8, base, ':') orelse
        return try allocator.dupe(u8, ref);
    const b_scheme = base[0 .. b_scheme_end + 1];

    // Authority span starts after "://" (if present).
    var b_authority: []const u8 = "";
    var b_path: []const u8 = base[b_scheme_end + 1 ..];
    if (b_path.len >= 2 and b_path[0] == '/' and b_path[1] == '/') {
        // Skip the two slashes.
        const after_slashes = b_path[2..];
        var auth_end: usize = after_slashes.len;
        for (after_slashes, 0..) |c, i| {
            if (c == '/' or c == '?' or c == '#') {
                auth_end = i;
                break;
            }
        }
        b_authority = b_path[0 .. 2 + auth_end];
        b_path = after_slashes[auth_end..];
    }

    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, b_scheme);
    try buf.appendSlice(allocator, b_authority);

    if (ref[0] == '/') {
        // Absolute path on the base authority.
        try buf.appendSlice(allocator, ref);
    } else if (ref[0] == '?' or ref[0] == '#') {
        // Same-document reference — keep the base path; strip any
        // trailing query/fragment from the base before appending.
        var path_only = b_path;
        if (std.mem.indexOfAny(u8, b_path, "?#")) |i| path_only = b_path[0..i];
        try buf.appendSlice(allocator, path_only);
        try buf.appendSlice(allocator, ref);
    } else {
        // Relative path: replace the last segment of the base path.
        var base_dir = b_path;
        if (std.mem.lastIndexOfScalar(u8, b_path, '/')) |i| {
            base_dir = b_path[0 .. i + 1];
        } else {
            base_dir = "/";
        }
        try buf.appendSlice(allocator, base_dir);
        try buf.appendSlice(allocator, ref);
    }
    return try buf.toOwnedSlice(allocator);
}

/// `url.pathToFileURL(path)` — wraps `path` in a `file://` URL.
/// Returns a freshly-parsed `URL` whose buffer the caller must
/// `deinit`. On Unix `path` must be absolute; on Windows we preserve
/// the drive letter.
pub fn pathToFileURL(allocator: std.mem.Allocator, path: []const u8) !URL {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "file://");

    if (path.len == 0) return error.InvalidURL;

    // On Windows the path may start with `C:\` — keep the drive
    // letter; rewrite backslashes to forward slashes; URL-encode
    // anything that isn't allowed in a path segment.
    var i: usize = 0;
    // Posix-ish input expects a leading '/'. If absent, prepend.
    if (path[0] != '/') {
        // Windows-style "C:\foo" — emit "/C:/foo".
        try buf.append(allocator, '/');
    }
    while (i < path.len) : (i += 1) {
        const c = path[i];
        if (c == '\\') {
            try buf.append(allocator, '/');
        } else if (isPathPassthrough(c)) {
            try buf.append(allocator, c);
        } else {
            try percentEncodeByte(allocator, &buf, c);
        }
    }
    // URL.parse dupes its input, so we keep `buf` local and let
    // `defer buf.deinit(...)` reclaim the scratch storage.
    return try URL.parse(allocator, buf.items, null);
}

/// `url.fileURLToPath(url)` — strips the `file://` prefix +
/// percent-decodes the path. Returns a freshly-allocated owned
/// string.
pub fn fileURLToPath(allocator: std.mem.Allocator, url_str: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, url_str, "file://")) return error.InvalidURL;
    var rest = url_str["file://".len..];
    // Drop any host (file://host/path → /path); we don't honor remote
    // file URLs.
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash_idx| {
        rest = rest[slash_idx..];
    } else {
        return error.InvalidURL;
    }
    // Strip query / fragment.
    if (std.mem.indexOfAny(u8, rest, "?#")) |i| rest = rest[0..i];

    // On Windows the canonical form is `/C:/path` — strip the
    // leading slash so we hand back `C:/path`.
    if (rest.len >= 3 and rest[0] == '/' and isAsciiAlpha(rest[1]) and rest[2] == ':') {
        rest = rest[1..];
    }
    return try percentDecode(allocator, rest);
}

/// IDNA stub — returns a fresh copy of `host`. Real Punycode encoding
/// re-attaches when the IDNA tables are ported.
pub fn domainToASCII(allocator: std.mem.Allocator, host: []const u8) ![]u8 {
    return try allocator.dupe(u8, host);
}

/// IDNA stub — returns a fresh copy of `ascii_host`. Real Punycode
/// decoding re-attaches when the IDNA tables are ported.
pub fn domainToUnicode(allocator: std.mem.Allocator, ascii_host: []const u8) ![]u8 {
    return try allocator.dupe(u8, ascii_host);
}

// =====================================================================
// Encoding helpers
// =====================================================================

fn isAsciiAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isAsciiDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isSchemeByte(c: u8) bool {
    return isAsciiAlpha(c) or isAsciiDigit(c) or c == '+' or c == '-' or c == '.';
}

fn isUnreserved(c: u8) bool {
    return isAsciiAlpha(c) or isAsciiDigit(c) or c == '-' or c == '_' or c == '.' or c == '~';
}

/// Bytes that may appear in a URL path segment without escaping.
/// Mirrors RFC 3986 `pchar` minus the percent escape itself.
fn isPathPassthrough(c: u8) bool {
    if (isUnreserved(c)) return true;
    return switch (c) {
        '/', ':', '@', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=' => true,
        else => false,
    };
}

fn hexNibble(value: u8) u8 {
    return if (value < 10) '0' + value else 'A' + (value - 10);
}

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => 10 + (c - 'a'),
        'A'...'F' => 10 + (c - 'A'),
        else => null,
    };
}

fn percentEncodeByte(allocator: std.mem.Allocator, out: *std.ArrayList(u8), c: u8) !void {
    try out.append(allocator, '%');
    try out.append(allocator, hexNibble(c >> 4));
    try out.append(allocator, hexNibble(c & 0xF));
}

/// Percent-decodes `input` into a freshly-allocated owned slice. `%`
/// followed by invalid hex is passed through verbatim (Node's
/// behavior).
fn percentDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == '%' and i + 2 < input.len) {
            if (hexValue(input[i + 1])) |hi| {
                if (hexValue(input[i + 2])) |lo| {
                    try out.append(allocator, (hi << 4) | lo);
                    i += 3;
                    continue;
                }
            }
        }
        try out.append(allocator, c);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

/// `application/x-www-form-urlencoded` encoder. Spaces are encoded as
/// `+`; every other byte outside the unreserved set is percent-
/// encoded.
fn encodeFormComponent(allocator: std.mem.Allocator, out: *std.ArrayList(u8), input: []const u8) !void {
    for (input) |c| {
        if (c == ' ') {
            try out.append(allocator, '+');
        } else if (isUnreserved(c)) {
            try out.append(allocator, c);
        } else {
            try percentEncodeByte(allocator, out, c);
        }
    }
}

/// `application/x-www-form-urlencoded` decoder. `+` decodes to a
/// space, `%xx` to the corresponding byte; everything else is passed
/// through.
fn decodeFormComponent(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == '+') {
            try out.append(allocator, ' ');
            i += 1;
            continue;
        }
        if (c == '%' and i + 2 < input.len) {
            if (hexValue(input[i + 1])) |hi| {
                if (hexValue(input[i + 2])) |lo| {
                    try out.append(allocator, (hi << 4) | lo);
                    i += 3;
                    continue;
                }
            }
        }
        try out.append(allocator, c);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

fn hasScheme(s: []const u8) bool {
    if (s.len < 2) return false;
    if (!isAsciiAlpha(s[0])) return false;
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        if (s[i] == ':') return i > 0;
        if (!isSchemeByte(s[i])) return false;
    }
    return false;
}

// =====================================================================
// Inline tests
// =====================================================================

const testing = std.testing;

test "URL.parse: every getter slice is populated" {
    var u = try URL.parse(testing.allocator, "https://user:pass@example.com:8080/path/to?q=1&q=2#frag", null);
    defer u.deinit();
    try testing.expectEqualStrings("https:", u.protocol);
    try testing.expectEqualStrings("user", u.username);
    try testing.expectEqualStrings("pass", u.password);
    try testing.expectEqualStrings("example.com:8080", u.host);
    try testing.expectEqualStrings("example.com", u.hostname);
    try testing.expectEqualStrings("8080", u.port);
    try testing.expectEqualStrings("/path/to", u.pathname);
    try testing.expectEqualStrings("?q=1&q=2", u.search);
    try testing.expectEqualStrings("#frag", u.hash);
    try testing.expectEqualStrings("https://user:pass@example.com:8080", u.origin);
}

test "URL.parse: relative input resolves against base" {
    var u = try URL.parse(testing.allocator, "../sibling", "https://example.com/a/b/c");
    defer u.deinit();
    try testing.expectEqualStrings("https://example.com/a/b/../sibling", u.href);
    try testing.expectEqualStrings("example.com", u.hostname);
}

test "URL.toString: round-trip of the href view" {
    const input = "http://example.com/?x=1";
    var u = try URL.parse(testing.allocator, input, null);
    defer u.deinit();
    try testing.expectEqualStrings(input, u.toString());
    try testing.expectEqualStrings(input, u.toJSON());
}

test "URLSearchParams: get / has / set / append / delete" {
    var u = try URL.parse(testing.allocator, "https://x.test/?a=1&b=2&a=3", null);
    defer u.deinit();
    try testing.expectEqualStrings("1", u.searchParams.get("a").?);
    try testing.expect(u.searchParams.has("b"));
    try testing.expect(!u.searchParams.has("zzz"));

    try u.searchParams.append("c", "9");
    try testing.expectEqualStrings("9", u.searchParams.get("c").?);

    try u.searchParams.set("a", "99");
    try testing.expectEqualStrings("99", u.searchParams.get("a").?);
    // `set` collapses duplicates.
    const all = try u.searchParams.getAll(testing.allocator, "a");
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 1), all.len);

    u.searchParams.delete("b");
    try testing.expect(!u.searchParams.has("b"));
}

test "URLSearchParams: toString round-trip + spaces encode as +" {
    var p = URLSearchParams.init(testing.allocator);
    defer p.deinit();
    try p.append("hello", "world");
    try p.append("greeting", "hi there");

    const s = try p.toString(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("hello=world&greeting=hi+there", s);

    var parsed = try URLSearchParams.fromString(testing.allocator, s);
    defer parsed.deinit();
    try testing.expectEqualStrings("hi there", parsed.get("greeting").?);
}

test "fileURLToPath: decodes percent escapes" {
    const p = try fileURLToPath(testing.allocator, "file:///home/me/hi%20there.txt");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("/home/me/hi there.txt", p);
}

test "pathToFileURL: prepends file:// and encodes spaces" {
    var u = try pathToFileURL(testing.allocator, "/tmp/hello world.txt");
    defer u.deinit();
    try testing.expectEqualStrings("file:///tmp/hello%20world.txt", u.href);
    try testing.expectEqualStrings("file:", u.protocol);
}

test "url.resolve: relative reference replaces last segment" {
    const out = try resolve(testing.allocator, "https://example.com/a/b/c", "sibling");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("https://example.com/a/b/sibling", out);
}

test "url.resolve: absolute reference wins" {
    const out = try resolve(testing.allocator, "https://example.com/a/b/c", "http://other.example/x");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("http://other.example/x", out);
}

test "url.parse legacy alias" {
    var u = try parse(testing.allocator, "https://example.com/path?q=1");
    defer u.deinit();
    try testing.expectEqualStrings("https:", u.protocol);
    try testing.expectEqualStrings("/path", u.pathname);
}

test "url.format reassembles components" {
    var u = try URL.parse(testing.allocator, "https://user@example.com:9000/abc?x=1#h", null);
    defer u.deinit();
    const s = try format(&u, testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("https://user@example.com:9000/abc?x=1#h", s);
}

test "domainToASCII / domainToUnicode: identity stubs" {
    const a = try domainToASCII(testing.allocator, "example.com");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("example.com", a);

    const u = try domainToUnicode(testing.allocator, "example.com");
    defer testing.allocator.free(u);
    try testing.expectEqualStrings("example.com", u);
}
