const VulnerabilityInfo = struct {
    severity: []const u8,
    title: []const u8,
    url: []const u8,
    vulnerable_versions: []const u8,
    id: []const u8,
    package_name: []const u8,
};

const PackageInfo = struct {
    package_id: u32,
    name: []const u8,
    version: []const u8,
    vulnerabilities: std.array_list.Managed(VulnerabilityInfo),
    dependents: std.array_list.Managed(DependencyPath),

    const DependencyPath = struct {
        path: std.array_list.Managed([]const u8),
        is_direct: bool,
    };
};

const AuditResult = struct {
    vulnerable_packages: bun.StringArrayHashMap(PackageInfo),
    all_vulnerabilities: std.array_list.Managed(VulnerabilityInfo),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AuditResult {
        return AuditResult{
            .vulnerable_packages = bun.StringArrayHashMap(PackageInfo).init(allocator),
            .all_vulnerabilities = std.array_list.Managed(VulnerabilityInfo).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AuditResult) void {
        var iter = self.vulnerable_packages.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.vulnerabilities.deinit();
            for (entry.value_ptr.dependents.items) |*dependent| {
                for (dependent.path.items) |part| self.allocator.free(part);
                dependent.path.deinit();
            }
            entry.value_ptr.dependents.deinit();
        }
        self.vulnerable_packages.deinit();
        self.all_vulnerabilities.deinit();
    }
};

pub const AuditCommand = struct {
    pub fn exec(ctx: Command.Context) !noreturn {
        const cli = try PackageManager.CommandLineArguments.parse(ctx.allocator, .audit);
        const manager, _ = PackageManager.init(ctx, cli, .audit) catch |err| {
            if (err == error.MissingPackageJSON) {
                var cwd_buf: bun.PathBuffer = undefined;
                if (bun.getcwd(&cwd_buf)) |cwd| {
                    Output.errGeneric("No package.json was found for directory \"{s}\"", .{cwd});
                } else |_| {
                    Output.errGeneric("No package.json was found", .{});
                }
                Output.note("Run \"bun init\" to initialize a project", .{});
                Global.exit(1);
            }

            return err;
        };

        const code = try audit(ctx, manager, manager.options.json_output, cli.audit_level, cli.production, cli.audit_ignore_list);
        Global.exit(@intCast(code));
    }

    /// Returns 0 when no vulnerabilities are reported and 1 when there are
    /// vulnerabilities or the response cannot be parsed, including JSON mode.
    pub fn audit(ctx: Command.Context, pm: *PackageManager, json_output: bool, audit_level: ?AuditLevel, audit_prod_only: bool, ignore_list: []const []const u8) bun.OOM!u32 {
        Output.prettyError("<r><b>bun audit <r><d>v" ++ Global.package_json_version_with_sha ++ "<r>\n", .{});
        Output.flush();

        const load_lockfile = pm.lockfile.loadFromCwd(pm, ctx.allocator, ctx.log, true);
        @import("./package_manager_command.zig").PackageManagerCommand.handleLoadLockfileErrors(load_lockfile, pm);

        var dependency_tree = try buildDependencyTree(ctx.allocator, pm, audit_prod_only);
        defer dependency_tree.deinit();

        const packages_result = try collectPackagesForAudit(ctx.allocator, pm, audit_prod_only);
        defer ctx.allocator.free(packages_result.audit_body);
        defer {
            for (packages_result.skipped_packages.items) |package_name| {
                ctx.allocator.free(package_name);
            }
            packages_result.skipped_packages.deinit();
        }

        const response_text = try sendAuditRequest(ctx.allocator, pm, packages_result.audit_body);
        defer ctx.allocator.free(response_text);

        if (json_output) {
            Output.writer().writeAll(response_text) catch {};
            Output.writer().writeByte('\n') catch {};

            if (response_text.len > 0) {
                const source = &logger.Source.initPathString("audit-response.json", response_text);
                var log = logger.Log.init(ctx.allocator);
                defer log.deinit();

                const expr = bun.json.parse(source, &log, ctx.allocator, true) catch {
                    Output.prettyErrorln("<red>error<r>: audit request failed to parse json. Is the registry down?", .{});
                    return 1; // If we can't parse then safe to assume a similar failure
                };

                // If the response is an empty object, no vulnerabilities
                if (expr.data == .e_object and expr.data.e_object.properties.len == 0) {
                    return 0;
                }

                // If there's any content in the response, there are vulnerabilities
                return 1;
            }

            return 0;
        } else if (response_text.len > 0) {
            const exit_code = try printEnhancedAuditReport(ctx.allocator, response_text, pm, &dependency_tree, audit_level, ignore_list);

            printSkippedPackages(packages_result.skipped_packages);

            return exit_code;
        } else {
            Output.prettyln("<green>No vulnerabilities found<r>", .{});

            printSkippedPackages(packages_result.skipped_packages);

            return 0;
        }
    }
};

fn printSkippedPackages(skipped_packages: std.array_list.Managed([]const u8)) void {
    if (skipped_packages.items.len > 0) {
        Output.pretty("<d>Skipped<r> ", .{});
        for (skipped_packages.items, 0..) |package_name, i| {
            if (i > 0) Output.pretty(", ", .{});
            Output.pretty("{s}", .{package_name});
        }

        if (skipped_packages.items.len > 1) {
            Output.prettyln(" <d>because they do not come from the default registry<r>", .{});
        } else {
            Output.prettyln(" <d>because it does not come from the default registry<r>", .{});
        }

        Output.prettyln("", .{});
    }
}

const DependencyTree = struct {
    parents: std.AutoHashMap(u32, std.array_list.Managed(u32)),
    production_packages: ?std.AutoHashMap(u32, void) = null,

    fn deinit(this: *DependencyTree) void {
        var iter = this.parents.valueIterator();
        while (iter.next()) |parents| parents.deinit();
        this.parents.deinit();
        if (this.production_packages) |*packages| packages.deinit();
    }

    fn includes(this: *const DependencyTree, id: u32) bool {
        return if (this.production_packages) |packages| packages.contains(id) else true;
    }
};

fn isDevOnly(dep: bun.install.Dependency) bool {
    return dep.behavior.isDev() and !dep.behavior.isProd() and !dep.behavior.isOptional() and !dep.behavior.isPeer();
}

fn buildDependencyTree(allocator: std.mem.Allocator, pm: *PackageManager, prod_only: bool) bun.OOM!DependencyTree {
    var tree = DependencyTree{ .parents = std.AutoHashMap(u32, std.array_list.Managed(u32)).init(allocator) };
    errdefer tree.deinit();
    if (prod_only) {
        tree.production_packages = std.AutoHashMap(u32, void).init(allocator);
        try buildProductionPackageSet(allocator, pm, &tree.production_packages.?);
    }
    const packages = pm.lockfile.packages.slice();
    const dependencies = pm.lockfile.buffers.dependencies.items;
    const resolutions = pm.lockfile.buffers.resolutions.items;
    const root_id = pm.root_package_id.get(pm.lockfile, pm.workspace_name_hash);
    for (packages.items(.dependencies), packages.items(.resolutions), packages.items(.resolution), 0..) |deps, resolved, resolution, index| {
        const parent_id: u32 = @intCast(index);
        // Root/workspace edges are report boundaries, handled by the path
        // finder. Other local packages can still lead to audited npm children.
        if (parent_id == root_id or resolution.tag == .workspace or !tree.includes(parent_id)) continue;
        for (deps.get(dependencies), resolved.get(resolutions)) |dep, child_id| {
            if (child_id >= packages.len or !tree.includes(child_id) or (prod_only and isDevOnly(dep))) continue;
            const entry = try tree.parents.getOrPut(child_id);
            if (!entry.found_existing) entry.value_ptr.* = std.array_list.Managed(u32).init(allocator);
            try entry.value_ptr.append(parent_id);
        }
    }
    return tree;
}

fn buildProductionPackageSet(allocator: std.mem.Allocator, pm: *PackageManager, prod_set: *std.AutoHashMap(u32, void)) bun.OOM!void {
    const packages = pm.lockfile.packages.slice();
    const pkg_dependencies = packages.items(.dependencies);
    const pkg_resolutions = packages.items(.resolutions);
    const dependencies = pm.lockfile.buffers.dependencies.items;
    const resolutions = pm.lockfile.buffers.resolutions.items;
    const root_id = pm.root_package_id.get(pm.lockfile, pm.workspace_name_hash);

    var queue = bun.LinearFifo(u32, .Dynamic).init(allocator);
    defer queue.deinit();
    try prod_set.put(root_id, {});
    try queue.writeItem(root_id);

    // A package name may resolve to several versions with different children.
    // Follow actual package IDs and exclude dev-only edges at every level,
    // including workspace packages. A name-based visited set both includes
    // unrelated dev versions and can miss a production version's children.
    while (queue.readItem()) |current_pkg_id| {
        const dep_slice = pkg_dependencies[current_pkg_id].get(dependencies);
        const res_slice = pkg_resolutions[current_pkg_id].get(resolutions);
        for (dep_slice, res_slice) |dep, resolved_pkg_id| {
            if (resolved_pkg_id >= packages.len) continue;
            if (isDevOnly(dep)) continue;
            const entry = try prod_set.getOrPut(resolved_pkg_id);
            if (!entry.found_existing) {
                entry.value_ptr.* = {};
                try queue.writeItem(resolved_pkg_id);
            }
        }
    }
}

fn collectPackagesForAudit(allocator: std.mem.Allocator, pm: *PackageManager, prod_only: bool) bun.OOM!struct { audit_body: []u8, skipped_packages: std.array_list.Managed([]const u8) } {
    const packages = pm.lockfile.packages.slice();
    const pkg_names = packages.items(.name);
    const pkg_resolutions = packages.items(.resolution);
    const buf = pm.lockfile.buffers.string_bytes.items;
    const root_id = pm.root_package_id.get(pm.lockfile, pm.workspace_name_hash);

    var packages_list = std.array_list.Managed(struct {
        name: []const u8,
        versions: std.array_list.Managed([]const u8),
    }).init(allocator);
    defer {
        for (packages_list.items) |item| {
            allocator.free(item.name);
            for (item.versions.items) |version| {
                allocator.free(version);
            }
            item.versions.deinit();
        }
        packages_list.deinit();
    }

    var skipped_packages = std.array_list.Managed([]const u8).init(allocator);

    var prod_packages: ?std.AutoHashMap(u32, void) = null;
    defer if (prod_packages) |*map| map.deinit();

    if (prod_only) {
        prod_packages = std.AutoHashMap(u32, void).init(allocator);
        try buildProductionPackageSet(allocator, pm, &prod_packages.?);
    }

    for (pkg_names, pkg_resolutions, 0..) |name, res, idx| {
        if (idx == root_id) continue;
        if (res.tag != .npm) continue;

        const name_slice = name.slice(buf);

        if (prod_only and prod_packages != null) {
            if (!prod_packages.?.contains(@intCast(idx))) {
                continue;
            }
        }

        const package_scope = pm.scopeForPackageName(name_slice);
        if (package_scope.url_hash != pm.options.scope.url_hash) {
            try skipped_packages.append(try allocator.dupe(u8, name_slice));
            continue;
        }

        const ver_str = try std.fmt.allocPrint(allocator, "{f}", .{res.value.npm.version.fmt(buf)});

        var found_package: ?*@TypeOf(packages_list.items[0]) = null;
        for (packages_list.items) |*item| {
            if (std.mem.eql(u8, item.name, name_slice)) {
                found_package = item;
                break;
            }
        }

        if (found_package == null) {
            try packages_list.append(.{
                .name = try allocator.dupe(u8, name_slice),
                .versions = std.array_list.Managed([]const u8).init(allocator),
            });
            found_package = &packages_list.items[packages_list.items.len - 1];
        }

        var version_exists = false;
        for (found_package.?.versions.items) |existing_ver| {
            if (std.mem.eql(u8, existing_ver, ver_str)) {
                version_exists = true;
                break;
            }
        }

        if (!version_exists) {
            try found_package.?.versions.append(ver_str);
        } else {
            allocator.free(ver_str);
        }
    }

    var body = try MutableString.init(allocator, 1024);
    body.appendChar('{') catch {};

    for (packages_list.items, 0..) |package, pkg_idx| {
        if (pkg_idx > 0) body.appendChar(',') catch {};
        body.appendChar('"') catch {};
        body.appendSlice(package.name) catch {};
        body.appendChar('"') catch {};
        body.appendChar(':') catch {};
        body.appendChar('[') catch {};
        for (package.versions.items, 0..) |version, ver_idx| {
            if (ver_idx > 0) body.appendChar(',') catch {};
            body.appendChar('"') catch {};
            body.appendSlice(version) catch {};
            body.appendChar('"') catch {};
        }
        body.appendChar(']') catch {};
    }
    body.appendChar('}') catch {};

    return .{
        .audit_body = try allocator.dupe(u8, body.slice()),
        .skipped_packages = skipped_packages,
    };
}

fn sendAuditRequest(allocator: std.mem.Allocator, pm: *PackageManager, body: []const u8) bun.OOM![]u8 {
    libdeflate.load();
    var compressor = libdeflate.Compressor.alloc(6) orelse return error.OutOfMemory;
    defer compressor.deinit();

    const max_compressed_size = compressor.maxBytesNeeded(body, .gzip);
    const compressed_body = try allocator.alloc(u8, max_compressed_size);
    defer allocator.free(compressed_body);

    const compression_result = compressor.gzip(body, compressed_body);
    const final_compressed_body = compressed_body[0..compression_result.written];

    var headers: HeaderBuilder = .{};
    headers.count("accept", "application/json");
    headers.count("content-type", "application/json");
    headers.count("content-encoding", "gzip");
    if (pm.options.scope.token.len > 0) {
        headers.count("authorization", "");
        headers.content.cap += "Bearer ".len + pm.options.scope.token.len;
    } else if (pm.options.scope.auth.len > 0) {
        headers.count("authorization", "");
        headers.content.cap += "Basic ".len + pm.options.scope.auth.len;
    }
    try headers.allocate(allocator);
    headers.append("accept", "application/json");
    headers.append("content-type", "application/json");
    headers.append("content-encoding", "gzip");
    if (pm.options.scope.token.len > 0) {
        headers.appendFmt("authorization", "Bearer {s}", .{pm.options.scope.token});
    } else if (pm.options.scope.auth.len > 0) {
        headers.appendFmt("authorization", "Basic {s}", .{pm.options.scope.auth});
    }

    const url_str = try std.fmt.allocPrint(allocator, "{s}/-/npm/v1/security/advisories/bulk", .{strings.withoutTrailingSlash(pm.options.scope.url.href)});
    defer allocator.free(url_str);
    const url = URL.parse(url_str);

    const http_proxy = pm.env.getHttpProxyFor(url);

    var response_buf = try MutableString.init(allocator, 1024);
    var req = http.AsyncHTTP.initSync(
        allocator,
        .POST,
        url,
        headers.entries,
        headers.content.ptr.?[0..headers.content.len],
        &response_buf,
        final_compressed_body,
        http_proxy,
        null,
        .follow,
    );
    const res = req.sendSync() catch |err| {
        Output.err(err, "audit request failed", .{});
        Global.crash();
    };

    if (res.status_code >= 400) {
        Output.prettyErrorln("<red>error<r>: audit request failed (status {d})", .{res.status_code});
        Global.crash();
    }

    return try allocator.dupe(u8, response_buf.slice());
}

fn parseVulnerability(allocator: std.mem.Allocator, package_name: []const u8, vuln: bun.ast.Expr) bun.OOM!VulnerabilityInfo {
    var vulnerability = VulnerabilityInfo{
        .severity = "moderate",
        .title = "Vulnerability found",
        .url = "",
        .vulnerable_versions = "",
        .id = "",
        .package_name = try allocator.dupe(u8, package_name),
    };

    if (vuln.data == .e_object) {
        const props = vuln.data.e_object.properties.slice();
        for (props) |prop| {
            if (prop.key) |key| {
                if (key.data == .e_string) {
                    const field_name = key.data.e_string.data;
                    if (prop.value) |value| {
                        if (value.data == .e_string) {
                            const field_value = value.data.e_string.data;
                            if (std.mem.eql(u8, field_name, "severity")) {
                                vulnerability.severity = field_value;
                            } else if (std.mem.eql(u8, field_name, "title")) {
                                vulnerability.title = field_value;
                            } else if (std.mem.eql(u8, field_name, "url")) {
                                vulnerability.url = field_value;
                            } else if (std.mem.eql(u8, field_name, "vulnerable_versions")) {
                                vulnerability.vulnerable_versions = field_value;
                            } else if (std.mem.eql(u8, field_name, "id")) {
                                vulnerability.id = field_value;
                            }
                        } else if (value.data == .e_number) {
                            if (std.mem.eql(u8, field_name, "id")) {
                                vulnerability.id = try std.fmt.allocPrint(allocator, "{d}", .{@as(u64, @intFromFloat(value.data.e_number.value))});
                            }
                        }
                    }
                }
            }
        }
    }

    return vulnerability;
}

fn findDependencyPaths(
    allocator: std.mem.Allocator,
    target_package: []const u8,
    vulnerable_versions: []const u8,
    dependency_tree: *const DependencyTree,
    pm: *PackageManager,
) bun.OOM!std.array_list.Managed(PackageInfo.DependencyPath) {
    var paths = std.array_list.Managed(PackageInfo.DependencyPath).init(allocator);
    const packages = pm.lockfile.packages.slice();
    const root_id = pm.root_package_id.get(pm.lockfile, pm.workspace_name_hash);
    const dependencies = pm.lockfile.buffers.dependencies.items;
    const resolutions = pm.lockfile.buffers.resolutions.items;
    const buf = pm.lockfile.buffers.string_bytes.items;
    const names = packages.items(.name);
    const package_resolutions = packages.items(.resolution);
    const deps = packages.items(.dependencies);
    const resolved = packages.items(.resolutions);
    const prod_only = dependency_tree.production_packages != null;
    const query = try bun.Semver.Query.parse(allocator, vulnerable_versions, bun.Semver.SlicedString.init(vulnerable_versions, vulnerable_versions));
    defer query.deinit();
    var queue = bun.LinearFifo(u32, .Dynamic).init(allocator);
    defer queue.deinit();
    // Each node records a descendant on a path to an affected installed
    // version. IDs keep distinct versions separate; finalized nodes keep
    // the descendant chain acyclic.
    var next = std.AutoHashMap(u32, u32).init(allocator);
    defer next.deinit();
    for (names, package_resolutions, 0..) |name, resolution, index| {
        const id: u32 = @intCast(index);
        if (resolution.tag != .npm or !strings.eql(name.slice(buf), target_package) or !dependency_tree.includes(id)) continue;
        if (vulnerable_versions.len > 0 and !query.satisfies(resolution.value.npm.version, vulnerable_versions, buf)) continue;
        try next.put(id, id);
        try queue.writeItem(id);
    }

    var visited = std.AutoHashMap(u32, void).init(allocator);
    defer visited.deinit();
    while (queue.readItem()) |current| {
        const visit = try visited.getOrPut(current);
        if (visit.found_existing) continue;
        visit.value_ptr.* = {};
        var boundary_found = false;
        for (deps, resolved, package_resolutions, names, 0..) |boundary_deps, boundary_resolved, resolution, name, boundary_index| {
            const boundary: u32 = @intCast(boundary_index);
            if (boundary != root_id and resolution.tag != .workspace) continue;
            if (!dependency_tree.includes(boundary)) continue;
            for (boundary_deps.get(dependencies), boundary_resolved.get(resolutions)) |dep, id| {
                if (id != current or (prod_only and isDevOnly(dep))) continue;
                var dependency_path = PackageInfo.DependencyPath{
                    .path = std.array_list.Managed([]const u8).init(allocator),
                    .is_direct = boundary == root_id and next.get(current).? == current,
                };
                var trace = current;
                while (true) {
                    try dependency_path.path.insert(0, try allocator.dupe(u8, names[trace].slice(buf)));
                    const descendant = next.get(trace).?;
                    if (descendant == trace) break;
                    trace = descendant;
                }
                if (boundary != root_id) {
                    const prefix = try std.fmt.allocPrint(allocator, "workspace:{s}", .{name.slice(buf)});
                    try dependency_path.path.insert(0, prefix);
                }
                try paths.append(dependency_path);
                boundary_found = true;
                break;
            }
        }
        // Upstream replaces a pending node's representative path when it
        // encounters another parent edge before dequeuing that node. Preserve
        // this deterministic selection order, but never rewrite finalized
        // nodes or affected-version terminals into a cycle.
        if (!boundary_found or next.get(current).? == current) {
            if (dependency_tree.parents.get(current)) |parents| {
                for (parents.items) |parent| {
                    if (visited.contains(parent)) continue;
                    if (next.get(parent)) |descendant| {
                        if (descendant == parent) continue;
                    }
                    try next.put(parent, current);
                    try queue.writeItem(parent);
                }
            }
        }
    }
    return paths;
}

fn printEnhancedAuditReport(
    allocator: std.mem.Allocator,
    response_text: []const u8,
    pm: *PackageManager,
    dependency_tree: *const DependencyTree,
    audit_level: ?AuditLevel,
    ignore_list: []const []const u8,
) bun.OOM!u32 {
    const source = &logger.Source.initPathString("audit-response.json", response_text);
    var log = logger.Log.init(allocator);
    defer log.deinit();

    const expr = bun.json.parse(source, &log, allocator, true) catch {
        Output.writer().writeAll(response_text) catch {};
        Output.writer().writeByte('\n') catch {};
        return 1;
    };

    if (expr.data == .e_object and expr.data.e_object.properties.len == 0) {
        Output.prettyln("<green>No vulnerabilities found<r>", .{});
        return 0;
    }

    var audit_result = AuditResult.init(allocator);
    defer audit_result.deinit();

    var vuln_counts = struct {
        low: u32 = 0,
        moderate: u32 = 0,
        high: u32 = 0,
        critical: u32 = 0,
    }{};

    if (expr.data == .e_object) {
        const properties = expr.data.e_object.properties.slice();

        for (properties) |prop| {
            if (prop.key) |key| {
                if (key.data == .e_string) {
                    const package_name = key.data.e_string.data;

                    if (prop.value) |value| {
                        if (value.data == .e_array) {
                            const vulns = value.data.e_array.items.slice();
                            for (vulns) |vuln| {
                                if (vuln.data == .e_object) {
                                    const vulnerability = try parseVulnerability(allocator, package_name, vuln);

                                    if (audit_level) |level| {
                                        if (!level.shouldIncludeSeverity(vulnerability.severity)) {
                                            continue;
                                        }
                                    }

                                    if (ignore_list.len > 0) {
                                        var should_ignore = false;
                                        for (ignore_list) |ignored_cve| {
                                            if (strings.eql(vulnerability.id, ignored_cve) or
                                                strings.indexOf(vulnerability.url, ignored_cve) != null)
                                            {
                                                should_ignore = true;
                                                break;
                                            }
                                        }
                                        if (should_ignore) {
                                            continue;
                                        }
                                    }

                                    if (std.mem.eql(u8, vulnerability.severity, "low")) {
                                        vuln_counts.low += 1;
                                    } else if (std.mem.eql(u8, vulnerability.severity, "moderate")) {
                                        vuln_counts.moderate += 1;
                                    } else if (std.mem.eql(u8, vulnerability.severity, "high")) {
                                        vuln_counts.high += 1;
                                    } else if (std.mem.eql(u8, vulnerability.severity, "critical")) {
                                        vuln_counts.critical += 1;
                                    } else {
                                        vuln_counts.moderate += 1;
                                    }

                                    try audit_result.all_vulnerabilities.append(vulnerability);
                                }
                            }
                        }
                    }
                }
            }
        }

        for (audit_result.all_vulnerabilities.items) |vulnerability| {
            const paths = try findDependencyPaths(allocator, vulnerability.package_name, vulnerability.vulnerable_versions, dependency_tree, pm);

            const result = try audit_result.vulnerable_packages.getOrPut(vulnerability.package_name);
            if (!result.found_existing) {
                result.value_ptr.* = PackageInfo{
                    .package_id = 0,
                    .name = vulnerability.package_name,
                    .version = vulnerability.vulnerable_versions,
                    .vulnerabilities = std.array_list.Managed(VulnerabilityInfo).init(allocator),
                    .dependents = paths,
                };
            } else {
                for (paths.items) |candidate| {
                    var duplicate = false;
                    for (result.value_ptr.dependents.items) |existing| {
                        if (existing.path.items.len != candidate.path.items.len) continue;
                        var same = true;
                        for (existing.path.items, candidate.path.items) |a, b| {
                            if (!strings.eql(a, b)) {
                                same = false;
                                break;
                            }
                        }
                        if (same) {
                            duplicate = true;
                            break;
                        }
                    }
                    if (duplicate) {
                        for (candidate.path.items) |part| allocator.free(part);
                        candidate.path.deinit();
                    } else try result.value_ptr.dependents.append(candidate);
                }
                paths.deinit();
            }
            try result.value_ptr.vulnerabilities.append(vulnerability);
        }

        var package_iter = audit_result.vulnerable_packages.iterator();
        while (package_iter.next()) |entry| {
            const package_info = entry.value_ptr;

            if (package_info.vulnerabilities.items.len > 0) {
                const main_vuln = package_info.vulnerabilities.items[0];

                // const is_direct_dependency: bool = brk: {
                //     for (package_info.dependents.items) |path| {
                //         if (path.is_direct) {
                //             break :brk true;
                //         }
                //     }

                //     break :brk false;
                // };

                if (main_vuln.vulnerable_versions.len > 0) {
                    Output.prettyln("<red>{s}<r>  {s}", .{ main_vuln.package_name, main_vuln.vulnerable_versions });
                } else {
                    Output.prettyln("<red>{s}<r>", .{main_vuln.package_name});
                }

                for (package_info.dependents.items) |path| {
                    if (path.path.items.len > 1) {
                        if (std.mem.startsWith(u8, path.path.items[0], "workspace:")) {
                            const vulnerable_pkg = path.path.items[1];
                            Output.pretty("  <d>{s}", .{path.path.items[0]});
                            var i = path.path.items.len;
                            while (i > 2) {
                                i -= 1;
                                Output.pretty(" › {s}", .{path.path.items[i]});
                            }
                            Output.prettyln(" › <red>{s}<r>", .{vulnerable_pkg});
                        } else {
                            const vulnerable_pkg = path.path.items[0];

                            var reversed_items = std.array_list.Managed([]const u8).init(allocator);
                            for (path.path.items[1..]) |item| try reversed_items.append(item);
                            std.mem.reverse([]const u8, reversed_items.items);
                            defer reversed_items.deinit();

                            const vuln_pkg_path = try std.mem.join(allocator, " › ", reversed_items.items);
                            defer allocator.free(vuln_pkg_path);

                            Output.prettyln("  <d>{s} › <red>{s}<r>", .{ vuln_pkg_path, vulnerable_pkg });
                        }
                    } else {
                        Output.prettyln("  <d>(direct dependency)<r>", .{});
                    }
                }

                for (package_info.vulnerabilities.items) |vuln| {
                    if (vuln.title.len > 0) {
                        if (std.mem.eql(u8, vuln.severity, "critical")) {
                            Output.prettyln("  <red>critical<d>:<r> {s} - <d>{s}<r>", .{ vuln.title, vuln.url });
                        } else if (std.mem.eql(u8, vuln.severity, "high")) {
                            Output.prettyln("  <red>high<d>:<r> {s} - <d>{s}<r>", .{ vuln.title, vuln.url });
                        } else if (std.mem.eql(u8, vuln.severity, "moderate")) {
                            Output.prettyln("  <yellow>moderate<d>:<r> {s} - <d>{s}<r>", .{ vuln.title, vuln.url });
                        } else {
                            Output.prettyln("  <cyan>low<d>:<r> {s} - <d>{s}<r>", .{ vuln.title, vuln.url });
                        }
                    }
                }

                // if (is_direct_dependency) {
                //     Output.prettyln("  To fix: <green>`bun update {s}`<r>", .{package_info.name});
                // } else {
                //     Output.prettyln("  To fix: <green>`bun update --latest`<r><d> (may be a breaking change)<r>", .{});
                // }

                Output.prettyln("", .{});
            }
        }

        const total = vuln_counts.low + vuln_counts.moderate + vuln_counts.high + vuln_counts.critical;
        if (total > 0) {
            Output.pretty("<b>{d} vulnerabilities<r> (", .{total});

            var has_previous = false;
            if (vuln_counts.critical > 0) {
                Output.pretty("<red><b>{d} critical<r>", .{vuln_counts.critical});
                has_previous = true;
            }
            if (vuln_counts.high > 0) {
                if (has_previous) Output.pretty(", ", .{});
                Output.pretty("<red>{d} high<r>", .{vuln_counts.high});
                has_previous = true;
            }
            if (vuln_counts.moderate > 0) {
                if (has_previous) Output.pretty(", ", .{});
                Output.pretty("<yellow>{d} moderate<r>", .{vuln_counts.moderate});
                has_previous = true;
            }
            if (vuln_counts.low > 0) {
                if (has_previous) Output.pretty(", ", .{});
                Output.pretty("<cyan>{d} low<r>", .{vuln_counts.low});
            }
            Output.prettyln(")", .{});

            Output.prettyln("", .{});
            Output.prettyln("To update all dependencies to the latest compatible versions:", .{});
            Output.prettyln("  <green>bun update<r>", .{});
            Output.prettyln("", .{});
            Output.prettyln("To update all dependencies to the latest versions (including breaking changes):", .{});
            Output.prettyln("  <green>bun update --latest<r>", .{});
            Output.prettyln("", .{});
        }

        if (total > 0) {
            return 1;
        }
    } else {
        Output.writer().writeAll(response_text) catch {};
        Output.writer().writeByte('\n') catch {};
    }

    return 0;
}

const libdeflate = @import("../../libdeflate_sys/libdeflate.zig");
const std = @import("std");
const AuditLevel = @import("../../install/PackageManager/CommandLineArguments.zig").AuditLevel;
const Command = @import("./cli.zig").Command;
const PackageManager = @import("../../install/install.zig").PackageManager;
const URL = @import("../../url/url.zig").URL;

const bun = @import("bun");
const Global = bun.Global;
const MutableString = bun.MutableString;
const Output = bun.Output;
const logger = bun.logger;
const strings = bun.strings;

const http = bun.http;
const HeaderBuilder = http.HeaderBuilder;
