const std = @import("std");
const http = @import("http");
const Allocator = std.mem.Allocator;

/// HTTP client for package registry communication
/// Handles package lookups, downloads, and metadata fetching
pub const RegistryClient = struct {
    allocator: Allocator,
    registry_url: []const u8,
    auth_token: ?[]const u8,
    client: *http.Client,
    cache: MetadataCache,

    pub const DEFAULT_REGISTRY = "https://packages.home-lang.org";
    pub const API_VERSION = "v1";

    pub const MetadataCache = struct {
        entries: std.StringHashMap(CachedMetadata),
        allocator: Allocator,

        pub const CachedMetadata = struct {
            data: PackageMetadata,
            timestamp: i64,
            ttl: i64, // Time to live in seconds
        };

        pub fn init(allocator: Allocator) MetadataCache {
            return .{
                .entries = std.StringHashMap(CachedMetadata).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *MetadataCache) void {
            var it = self.entries.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.data.deinit(self.allocator);
            }
            self.entries.deinit();
        }

        pub fn get(self: *MetadataCache, key: []const u8) ?PackageMetadata {
            const entry = self.entries.get(key) orelse return null;

            // Check if cache is still valid
            const now = std.time.timestamp();
            if (now - entry.timestamp > entry.ttl) {
                // Cache expired
                return null;
            }

            return entry.data;
        }

        pub fn put(self: *MetadataCache, key: []const u8, metadata: PackageMetadata, ttl: i64) !void {
            const cache_key = try self.allocator.dupe(u8, key);
            try self.entries.put(cache_key, .{
                .data = metadata,
                .timestamp = std.time.timestamp(),
                .ttl = ttl,
            });
        }
    };

    pub const PackageMetadata = struct {
        name: []const u8,
        description: ?[]const u8,
        versions: []VersionInfo,
        latest_version: []const u8,
        repository: ?[]const u8,
        homepage: ?[]const u8,
        license: ?[]const u8,
        keywords: [][]const u8,

        pub fn deinit(self: *PackageMetadata, allocator: Allocator) void {
            allocator.free(self.name);
            if (self.description) |desc| allocator.free(desc);
            for (self.versions) |*ver| {
                ver.deinit(allocator);
            }
            allocator.free(self.versions);
            allocator.free(self.latest_version);
            if (self.repository) |repo| allocator.free(repo);
            if (self.homepage) |home| allocator.free(home);
            if (self.license) |lic| allocator.free(lic);
            for (self.keywords) |kw| allocator.free(kw);
            allocator.free(self.keywords);
        }
    };

    pub const VersionInfo = struct {
        version: []const u8,
        published_at: []const u8,
        dependencies: []Dependency,
        checksum: []const u8,
        download_url: []const u8,

        pub fn deinit(self: *VersionInfo, allocator: Allocator) void {
            allocator.free(self.version);
            allocator.free(self.published_at);
            for (self.dependencies) |*dep| {
                allocator.free(dep.name);
                allocator.free(dep.version_constraint);
            }
            allocator.free(self.dependencies);
            allocator.free(self.checksum);
            allocator.free(self.download_url);
        }
    };

    pub const Dependency = struct {
        name: []const u8,
        version_constraint: []const u8,
    };

    pub const SearchResult = struct {
        packages: []PackageSearchHit,

        pub fn deinit(self: *SearchResult, allocator: Allocator) void {
            for (self.packages) |*pkg| {
                allocator.free(pkg.name);
                if (pkg.description) |desc| allocator.free(desc);
                allocator.free(pkg.version);
            }
            allocator.free(self.packages);
        }
    };

    pub const PackageSearchHit = struct {
        name: []const u8,
        description: ?[]const u8,
        version: []const u8,
        downloads: u64,
    };

    pub fn init(allocator: Allocator, registry_url: ?[]const u8, auth_token: ?[]const u8) !*RegistryClient {
        const client = try allocator.create(RegistryClient);

        const http_client = try http.Client.init(allocator);

        client.* = .{
            .allocator = allocator,
            .registry_url = registry_url orelse DEFAULT_REGISTRY,
            .auth_token = if (auth_token) |token| try allocator.dupe(u8, token) else null,
            .client = http_client,
            .cache = MetadataCache.init(allocator),
        };

        return client;
    }

    pub fn deinit(self: *RegistryClient) void {
        if (self.auth_token) |token| {
            self.allocator.free(token);
        }
        self.client.deinit();
        self.cache.deinit();
        self.allocator.destroy(self);
    }

    /// Set authentication token
    pub fn setAuthToken(self: *RegistryClient, token: []const u8) !void {
        if (self.auth_token) |old_token| {
            self.allocator.free(old_token);
        }
        self.auth_token = try self.allocator.dupe(u8, token);
    }

    /// Get package metadata
    pub fn getPackageMetadata(self: *RegistryClient, package_name: []const u8) !PackageMetadata {
        // Check cache first
        if (self.cache.get(package_name)) |cached| {
            return cached;
        }

        // Construct URL: https://registry/v1/packages/{name}
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/packages/{s}",
            .{ self.registry_url, API_VERSION, package_name },
        );
        defer self.allocator.free(url);

        // Make HTTP request
        var headers = std.ArrayList(http.Header).init(self.allocator);
        defer headers.deinit();

        try headers.append(.{
            .name = try self.allocator.dupe(u8, "Accept"),
            .value = try self.allocator.dupe(u8, "application/json"),
        });

        if (self.auth_token) |token| {
            const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token});
            defer self.allocator.free(auth_header);

            try headers.append(.{
                .name = try self.allocator.dupe(u8, "Authorization"),
                .value = try self.allocator.dupe(u8, auth_header),
            });
        }

        const response = try self.client.get(url, headers.items);
        defer response.deinit();

        if (response.status != .Ok) {
            std.debug.print("Registry error: HTTP {d}\n", .{@intFromEnum(response.status)});
            return error.RegistryError;
        }

        // Parse JSON response
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            response.body,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();

        const metadata = try self.parsePackageMetadata(parsed.value);

        // Cache the result (TTL: 5 minutes)
        try self.cache.put(package_name, metadata, 300);

        return metadata;
    }

    /// Parse package metadata from JSON
    fn parsePackageMetadata(self: *RegistryClient, json: std.json.Value) !PackageMetadata {
        const obj = json.object;

        const name = try self.allocator.dupe(u8, obj.get("name").?.string);
        const description = if (obj.get("description")) |desc|
            try self.allocator.dupe(u8, desc.string)
        else
            null;

        const latest_version = try self.allocator.dupe(u8, obj.get("latest_version").?.string);

        const repository = if (obj.get("repository")) |repo|
            try self.allocator.dupe(u8, repo.string)
        else
            null;

        const homepage = if (obj.get("homepage")) |home|
            try self.allocator.dupe(u8, home.string)
        else
            null;

        const license = if (obj.get("license")) |lic|
            try self.allocator.dupe(u8, lic.string)
        else
            null;

        // Parse versions
        var versions = std.ArrayList(VersionInfo).init(self.allocator);
        if (obj.get("versions")) |versions_arr| {
            for (versions_arr.array.items) |version_obj| {
                try versions.append(try self.parseVersionInfo(version_obj));
            }
        }

        // Parse keywords
        var keywords = std.ArrayList([]const u8).init(self.allocator);
        if (obj.get("keywords")) |keywords_arr| {
            for (keywords_arr.array.items) |kw| {
                try keywords.append(try self.allocator.dupe(u8, kw.string));
            }
        }

        return PackageMetadata{
            .name = name,
            .description = description,
            .versions = try versions.toOwnedSlice(),
            .latest_version = latest_version,
            .repository = repository,
            .homepage = homepage,
            .license = license,
            .keywords = try keywords.toOwnedSlice(),
        };
    }

    /// Parse version info from JSON
    fn parseVersionInfo(self: *RegistryClient, json: std.json.Value) !VersionInfo {
        const obj = json.object;

        const version = try self.allocator.dupe(u8, obj.get("version").?.string);
        const published_at = try self.allocator.dupe(u8, obj.get("published_at").?.string);
        const checksum = try self.allocator.dupe(u8, obj.get("checksum").?.string);
        const download_url = try self.allocator.dupe(u8, obj.get("download_url").?.string);

        // Parse dependencies
        var dependencies = std.ArrayList(Dependency).init(self.allocator);
        if (obj.get("dependencies")) |deps_obj| {
            var it = deps_obj.object.iterator();
            while (it.next()) |entry| {
                try dependencies.append(.{
                    .name = try self.allocator.dupe(u8, entry.key_ptr.*),
                    .version_constraint = try self.allocator.dupe(u8, entry.value_ptr.string),
                });
            }
        }

        return VersionInfo{
            .version = version,
            .published_at = published_at,
            .dependencies = try dependencies.toOwnedSlice(),
            .checksum = checksum,
            .download_url = download_url,
        };
    }

    /// Download a package tarball
    pub fn downloadPackage(
        self: *RegistryClient,
        package_name: []const u8,
        version: []const u8,
        dest_path: []const u8,
    ) !void {
        // Get metadata to find download URL
        const metadata = try self.getPackageMetadata(package_name);
        defer metadata.deinit(self.allocator);

        // Find the version
        var download_url: ?[]const u8 = null;
        for (metadata.versions) |ver| {
            if (std.mem.eql(u8, ver.version, version)) {
                download_url = ver.download_url;
                break;
            }
        }

        if (download_url == null) {
            return error.VersionNotFound;
        }

        // Download the tarball
        var headers = std.ArrayList(http.Header).init(self.allocator);
        defer headers.deinit();

        if (self.auth_token) |token| {
            const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token});
            defer self.allocator.free(auth_header);

            try headers.append(.{
                .name = try self.allocator.dupe(u8, "Authorization"),
                .value = try self.allocator.dupe(u8, auth_header),
            });
        }

        const response = try self.client.get(download_url.?, headers.items);
        defer response.deinit();

        if (response.status != .Ok) {
            return error.DownloadFailed;
        }

        // Write to file
        const file = try std.fs.cwd().createFile(dest_path, .{});
        defer file.close();

        try file.writeAll(response.body);

        std.debug.print("Downloaded {s}@{s} to {s}\n", .{ package_name, version, dest_path });
    }

    /// Search for packages
    pub fn searchPackages(self: *RegistryClient, query: []const u8, limit: u32) !SearchResult {
        // Construct search URL
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/search?q={s}&limit={d}",
            .{ self.registry_url, API_VERSION, query, limit },
        );
        defer self.allocator.free(url);

        // Make HTTP request
        var headers = std.ArrayList(http.Header).init(self.allocator);
        defer headers.deinit();

        try headers.append(.{
            .name = try self.allocator.dupe(u8, "Accept"),
            .value = try self.allocator.dupe(u8, "application/json"),
        });

        const response = try self.client.get(url, headers.items);
        defer response.deinit();

        if (response.status != .Ok) {
            return error.SearchFailed;
        }

        // Parse JSON response
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            response.body,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();

        return try self.parseSearchResults(parsed.value);
    }

    /// Parse search results from JSON
    fn parseSearchResults(self: *RegistryClient, json: std.json.Value) !SearchResult {
        const results_arr = json.object.get("results").?.array;

        var packages = std.ArrayList(PackageSearchHit).init(self.allocator);

        for (results_arr.items) |result_obj| {
            const obj = result_obj.object;

            try packages.append(.{
                .name = try self.allocator.dupe(u8, obj.get("name").?.string),
                .description = if (obj.get("description")) |desc|
                    try self.allocator.dupe(u8, desc.string)
                else
                    null,
                .version = try self.allocator.dupe(u8, obj.get("version").?.string),
                .downloads = @intCast(obj.get("downloads").?.integer),
            });
        }

        return SearchResult{
            .packages = try packages.toOwnedSlice(),
        };
    }

    /// Publish a package to the registry
    pub fn publishPackage(
        self: *RegistryClient,
        package_path: []const u8,
        metadata: PackageMetadata,
    ) !void {
        if (self.auth_token == null) {
            return error.NotAuthenticated;
        }

        // Read package tarball
        const tarball = try std.fs.cwd().readFileAlloc(
            self.allocator,
            package_path,
            10 * 1024 * 1024, // 10MB max
        );
        defer self.allocator.free(tarball);

        // Construct publish URL
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/packages",
            .{ self.registry_url, API_VERSION },
        );
        defer self.allocator.free(url);

        // Prepare multipart form data
        const boundary = "----HomePackageUpload";

        var body = std.ArrayList(u8).init(self.allocator);
        defer body.deinit();

        // Add metadata as JSON
        const metadata_json = try std.json.stringifyAlloc(
            self.allocator,
            metadata,
            .{},
        );
        defer self.allocator.free(metadata_json);

        try body.appendSlice(try std.fmt.allocPrint(
            self.allocator,
            "--{s}\r\nContent-Disposition: form-data; name=\"metadata\"\r\n\r\n{s}\r\n",
            .{ boundary, metadata_json },
        ));

        // Add tarball
        try body.appendSlice(try std.fmt.allocPrint(
            self.allocator,
            "--{s}\r\nContent-Disposition: form-data; name=\"tarball\"; filename=\"package.tar.gz\"\r\nContent-Type: application/gzip\r\n\r\n",
            .{boundary},
        ));
        try body.appendSlice(tarball);
        try body.appendSlice(try std.fmt.allocPrint(
            self.allocator,
            "\r\n--{s}--\r\n",
            .{boundary},
        ));

        // Prepare headers
        var headers = std.ArrayList(http.Header).init(self.allocator);
        defer headers.deinit();

        try headers.append(.{
            .name = try self.allocator.dupe(u8, "Authorization"),
            .value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.auth_token.?}),
        });

        try headers.append(.{
            .name = try self.allocator.dupe(u8, "Content-Type"),
            .value = try std.fmt.allocPrint(self.allocator, "multipart/form-data; boundary={s}", .{boundary}),
        });

        // Make HTTP POST request
        const response = try self.client.post(url, headers.items, body.items);
        defer response.deinit();

        if (response.status != .Created) {
            std.debug.print("Publish failed: HTTP {d}\n", .{@intFromEnum(response.status)});
            std.debug.print("Response: {s}\n", .{response.body});
            return error.PublishFailed;
        }

        std.debug.print("Successfully published {s}\n", .{metadata.name});
    }

    /// Get download statistics for a package
    pub fn getPackageStats(self: *RegistryClient, package_name: []const u8) !PackageStats {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/packages/{s}/stats",
            .{ self.registry_url, API_VERSION, package_name },
        );
        defer self.allocator.free(url);

        var headers = std.ArrayList(http.Header).init(self.allocator);
        defer headers.deinit();

        try headers.append(.{
            .name = try self.allocator.dupe(u8, "Accept"),
            .value = try self.allocator.dupe(u8, "application/json"),
        });

        const response = try self.client.get(url, headers.items);
        defer response.deinit();

        if (response.status != .Ok) {
            return error.StatsFailed;
        }

        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            response.body,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();

        const obj = parsed.value.object;

        return PackageStats{
            .total_downloads = @intCast(obj.get("total_downloads").?.integer),
            .weekly_downloads = @intCast(obj.get("weekly_downloads").?.integer),
            .dependents_count = @intCast(obj.get("dependents_count").?.integer),
        };
    }

    pub const PackageStats = struct {
        total_downloads: u64,
        weekly_downloads: u64,
        dependents_count: u64,
    };
};

test "RegistryClient - initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const client = try RegistryClient.init(allocator, null, null);
    defer client.deinit();

    try testing.expectEqualStrings(RegistryClient.DEFAULT_REGISTRY, client.registry_url);
}
