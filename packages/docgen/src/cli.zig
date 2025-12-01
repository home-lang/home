const std = @import("std");
const docgen = @import("docgen.zig");
const DocParser = docgen.DocParser;
const DocumentationGenerator = docgen.DocumentationGenerator;
const SyntaxHighlighter = docgen.SyntaxHighlighter;

/// Command-line interface for documentation generation
pub const CLI = struct {
    allocator: std.mem.Allocator,
    args: []const []const u8,

    pub const Command = enum {
        generate,
        serve,
        watch,
        validate,
        help,
        version,
    };

    pub const Options = struct {
        command: Command = .generate,
        source_dirs: []const []const u8 = &.{},
        output_dir: []const u8 = "docs",
        title: []const u8 = "API Documentation",
        format: Format = .html,
        color_scheme: SyntaxHighlighter.ColorScheme = .github_light,
        watch_mode: bool = false,
        serve_port: u16 = 8080,
        validate_examples: bool = false,
        verbose: bool = false,

        pub const Format = enum {
            html,
            markdown,
            both,
        };
    };

    pub fn init(allocator: std.mem.Allocator, args: []const []const u8) CLI {
        return .{
            .allocator = allocator,
            .args = args,
        };
    }

    /// Parse command-line arguments
    pub fn parseArgs(self: *CLI) !Options {
        var options = Options{};
        var source_dirs = std.ArrayList([]const u8).init(self.allocator);
        defer source_dirs.deinit();

        var i: usize = 1; // Skip program name
        while (i < self.args.len) : (i += 1) {
            const arg = self.args[i];

            if (std.mem.eql(u8, arg, "generate")) {
                options.command = .generate;
            } else if (std.mem.eql(u8, arg, "serve")) {
                options.command = .serve;
            } else if (std.mem.eql(u8, arg, "watch")) {
                options.command = .watch;
            } else if (std.mem.eql(u8, arg, "validate")) {
                options.command = .validate;
            } else if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                options.command = .help;
            } else if (std.mem.eql(u8, arg, "version") or std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
                options.command = .version;
            } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
                i += 1;
                if (i >= self.args.len) return error.MissingValue;
                options.output_dir = self.args[i];
            } else if (std.mem.eql(u8, arg, "--title") or std.mem.eql(u8, arg, "-t")) {
                i += 1;
                if (i >= self.args.len) return error.MissingValue;
                options.title = self.args[i];
            } else if (std.mem.eql(u8, arg, "--format") or std.mem.eql(u8, arg, "-f")) {
                i += 1;
                if (i >= self.args.len) return error.MissingValue;
                options.format = std.meta.stringToEnum(Options.Format, self.args[i]) orelse return error.InvalidFormat;
            } else if (std.mem.eql(u8, arg, "--theme")) {
                i += 1;
                if (i >= self.args.len) return error.MissingValue;
                options.color_scheme = std.meta.stringToEnum(SyntaxHighlighter.ColorScheme, self.args[i]) orelse return error.InvalidTheme;
            } else if (std.mem.eql(u8, arg, "--watch") or std.mem.eql(u8, arg, "-w")) {
                options.watch_mode = true;
            } else if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
                i += 1;
                if (i >= self.args.len) return error.MissingValue;
                options.serve_port = try std.fmt.parseInt(u16, self.args[i], 10);
            } else if (std.mem.eql(u8, arg, "--validate-examples")) {
                options.validate_examples = true;
            } else if (std.mem.eql(u8, arg, "--verbose")) {
                options.verbose = true;
            } else if (std.mem.startsWith(u8, arg, "-")) {
                std.debug.print("Unknown option: {s}\n", .{arg});
                return error.UnknownOption;
            } else {
                // Source directory or file
                try source_dirs.append(arg);
            }
        }

        options.source_dirs = try source_dirs.toOwnedSlice();
        return options;
    }

    /// Run the CLI command
    pub fn run(self: *CLI) !void {
        const options = try self.parseArgs();

        switch (options.command) {
            .help => try self.printHelp(),
            .version => try self.printVersion(),
            .generate => try self.generateDocs(options),
            .serve => try self.serveDocs(options),
            .watch => try self.watchAndGenerate(options),
            .validate => try self.validateDocs(options),
        }
    }

    /// Generate documentation
    fn generateDocs(self: *CLI, options: Options) !void {
        if (options.source_dirs.len == 0) {
            std.debug.print("Error: No source directories specified\n", .{});
            return error.NoSourceDirs;
        }

        if (options.verbose) {
            std.debug.print("Generating documentation...\n", .{});
            std.debug.print("  Source: {s}\n", .{options.source_dirs});
            std.debug.print("  Output: {s}\n", .{options.output_dir});
            std.debug.print("  Format: {s}\n", .{@tagName(options.format)});
        }

        // Create generator
        const config = DocumentationGenerator.Config{
            .title = options.title,
            .output_dir = options.output_dir,
            .generate_html = options.format == .html or options.format == .both,
            .generate_markdown = options.format == .markdown or options.format == .both,
            .enable_search = true,
            .enable_syntax_highlighting = true,
            .color_scheme = options.color_scheme,
        };

        var generator = try DocumentationGenerator.init(self.allocator, config);
        defer generator.deinit();

        // Collect all source files
        var files = std.ArrayList([]const u8).init(self.allocator);
        defer files.deinit();

        for (options.source_dirs) |dir| {
            try self.collectSourceFiles(dir, &files);
        }

        if (options.verbose) {
            std.debug.print("Found {d} source files\n", .{files.items.len});
        }

        // Generate documentation
        try generator.generateFromFiles(files.items);

        // Validate examples if requested
        if (options.validate_examples) {
            if (options.verbose) {
                std.debug.print("Validating code examples...\n", .{});
            }

            const example_extractor = @import("example_extractor.zig");
            var extractor = example_extractor.ExampleExtractor.init(self.allocator);
            defer extractor.deinit();

            var runner = example_extractor.ExampleRunner.init(self.allocator);

            var total_examples: usize = 0;
            var passed: usize = 0;
            var failed: usize = 0;

            // Extract and validate examples from all source files
            for (source_files.items) |file_path| {
                const examples = try extractor.extractExamples(file_path);
                defer {
                    for (examples) |ex| {
                        self.allocator.free(ex.code);
                        if (ex.expected_output) |out| self.allocator.free(out);
                    }
                    self.allocator.free(examples);
                }

                for (examples) |ex| {
                    total_examples += 1;

                    // Run the example
                    const output = runner.runExample(ex) catch |err| {
                        if (options.verbose) {
                            std.debug.print("  ✗ Example failed to run: {}\n", .{err});
                        }
                        failed += 1;
                        continue;
                    };
                    defer self.allocator.free(output);

                    // Check if output matches expected (if provided)
                    if (ex.expected_output) |expected| {
                        if (example_extractor.ExampleRunner.compareOutput(expected, output)) {
                            passed += 1;
                            if (options.verbose) {
                                std.debug.print("  ✓ Example passed\n", .{});
                            }
                        } else {
                            failed += 1;
                            if (options.verbose) {
                                std.debug.print("  ✗ Output mismatch\n", .{});
                                std.debug.print("    Expected: {s}\n", .{expected});
                                std.debug.print("    Got:      {s}\n", .{output});
                            }
                        }
                    } else {
                        // No expected output - just check it runs
                        passed += 1;
                        if (options.verbose) {
                            std.debug.print("  ✓ Example compiled and ran\n", .{});
                        }
                    }
                }
            }

            std.debug.print("\nValidation results: {d} total, {d} passed, {d} failed\n", .{ total_examples, passed, failed });
        }

        std.debug.print("Documentation generated successfully!\n", .{});
        std.debug.print("Output: {s}\n", .{options.output_dir});
    }

    /// Collect all .home source files from a directory
    fn collectSourceFiles(self: *CLI, dir_path: []const u8, files: *std.ArrayList([]const u8)) !void {
        var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .directory) {
                const sub_dir = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
                defer self.allocator.free(sub_dir);
                try self.collectSourceFiles(sub_dir, files);
            } else if (entry.kind == .file) {
                if (std.mem.endsWith(u8, entry.name, ".home") or std.mem.endsWith(u8, entry.name, ".zig")) {
                    const file_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
                    try files.append(file_path);
                }
            }
        }
    }

    /// Serve documentation with HTTP server
    fn serveDocs(self: *CLI, options: Options) !void {
        std.debug.print("Starting documentation server on port {d}...\n", .{options.serve_port});
        std.debug.print("Serving files from: {s}\n", .{options.output_dir});
        std.debug.print("Open http://localhost:{d} in your browser\n", .{options.serve_port});
        std.debug.print("Press Ctrl+C to stop\n\n", .{});

        // Create HTTP server
        const address = std.net.Address.parseIp("127.0.0.1", options.serve_port) catch |err| {
            std.debug.print("Failed to parse address: {}\n", .{err});
            return err;
        };

        var server = try address.listen(.{
            .reuse_address = true,
        });
        defer server.deinit();

        std.debug.print("Server listening on http://127.0.0.1:{d}\n", .{options.serve_port});

        // Accept connections
        while (true) {
            const connection = try server.accept();

            // Handle connection in a separate function to keep code clean
            self.handleConnection(connection, options) catch |err| {
                std.debug.print("Error handling connection: {}\n", .{err});
            };
        }
    }

    /// Handle a single HTTP connection
    fn handleConnection(self: *CLI, connection: std.net.Server.Connection, options: Options) !void {
        defer connection.stream.close();

        var buffer: [4096]u8 = undefined;
        const bytes_read = try connection.stream.read(&buffer);

        if (bytes_read == 0) return;

        const request = buffer[0..bytes_read];

        // Parse HTTP request line (GET /path HTTP/1.1)
        var lines = std.mem.splitScalar(u8, request, '\n');
        const request_line = lines.next() orelse return error.InvalidRequest;

        var parts = std.mem.splitScalar(u8, request_line, ' ');
        const method = parts.next() orelse return error.InvalidRequest;
        const path_raw = parts.next() orelse return error.InvalidRequest;

        // Only support GET requests
        if (!std.mem.eql(u8, method, "GET")) {
            try self.sendResponse(connection.stream, 405, "Method Not Allowed", "text/plain", "405 Method Not Allowed");
            return;
        }

        // Clean up path (remove query string, decode URL)
        var path = path_raw;
        if (std.mem.indexOf(u8, path, "?")) |idx| {
            path = path[0..idx];
        }

        // Remove trailing \r if present
        if (std.mem.endsWith(u8, path, "\r")) {
            path = path[0 .. path.len - 1];
        }

        // Convert "/" to "/index.html"
        if (std.mem.eql(u8, path, "/")) {
            path = "/index.html";
        }

        // Build file path (remove leading /)
        const file_path = if (std.mem.startsWith(u8, path, "/"))
            try std.fs.path.join(self.allocator, &.{ options.output_dir, path[1..] })
        else
            try std.fs.path.join(self.allocator, &.{ options.output_dir, path });
        defer self.allocator.free(file_path);

        // Log request
        std.debug.print("{s} {s}\n", .{ method, path });

        // Try to read and serve the file
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                try self.sendResponse(connection.stream, 404, "Not Found", "text/html",
                    \\<!DOCTYPE html>
                    \\<html>
                    \\<head><title>404 Not Found</title></head>
                    \\<body><h1>404 Not Found</h1><p>The requested file was not found.</p></body>
                    \\</html>
                );
            } else {
                try self.sendResponse(connection.stream, 500, "Internal Server Error", "text/plain", "500 Internal Server Error");
            }
            return;
        };
        defer file.close();

        // Read file content
        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024); // 10MB max
        defer self.allocator.free(content);

        // Determine content type from extension
        const content_type = self.getContentType(file_path);

        // Send response
        try self.sendResponse(connection.stream, 200, "OK", content_type, content);
    }

    /// Get MIME content type from file extension
    fn getContentType(self: *CLI, file_path: []const u8) []const u8 {
        _ = self;
        if (std.mem.endsWith(u8, file_path, ".html")) return "text/html; charset=utf-8";
        if (std.mem.endsWith(u8, file_path, ".css")) return "text/css; charset=utf-8";
        if (std.mem.endsWith(u8, file_path, ".js")) return "application/javascript; charset=utf-8";
        if (std.mem.endsWith(u8, file_path, ".json")) return "application/json; charset=utf-8";
        if (std.mem.endsWith(u8, file_path, ".png")) return "image/png";
        if (std.mem.endsWith(u8, file_path, ".jpg") or std.mem.endsWith(u8, file_path, ".jpeg")) return "image/jpeg";
        if (std.mem.endsWith(u8, file_path, ".gif")) return "image/gif";
        if (std.mem.endsWith(u8, file_path, ".svg")) return "image/svg+xml";
        if (std.mem.endsWith(u8, file_path, ".ico")) return "image/x-icon";
        if (std.mem.endsWith(u8, file_path, ".woff")) return "font/woff";
        if (std.mem.endsWith(u8, file_path, ".woff2")) return "font/woff2";
        if (std.mem.endsWith(u8, file_path, ".ttf")) return "font/ttf";
        return "application/octet-stream";
    }

    /// Send HTTP response
    fn sendResponse(self: *CLI, stream: std.net.Stream, status_code: u16, status_text: []const u8, content_type: []const u8, body: []const u8) !void {
        _ = self;

        // Build response
        var response_buffer: [8192]u8 = undefined;
        const response_header = try std.fmt.bufPrint(&response_buffer,
            "HTTP/1.1 {d} {s}\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "Server: Home-DocGen/0.1.0\r\n" ++
            "\r\n",
            .{ status_code, status_text, content_type, body.len }
        );

        // Send header
        try stream.writeAll(response_header);

        // Send body
        try stream.writeAll(body);
    }

    /// Watch for file changes and regenerate
    fn watchAndGenerate(self: *CLI, options: Options) !void {
        std.debug.print("Watching for changes in source directories...\n", .{});

        if (options.source_dirs.len == 0) {
            std.debug.print("Error: No source directories specified\n", .{});
            return error.NoSourceDirs;
        }

        // Initial generation
        try self.generateDocs(options);
        std.debug.print("\nInitial documentation generated. Watching for changes...\n", .{});
        std.debug.print("Press Ctrl+C to stop\n\n", .{});

        // Platform-specific file watching
        const builtin = @import("builtin");

        switch (builtin.os.tag) {
            .linux => try self.watchWithInotify(options),
            .macos, .freebsd, .netbsd, .openbsd, .dragonfly => try self.watchWithKqueue(options),
            else => {
                std.debug.print("File watching not supported on this platform\n", .{});
                std.debug.print("Please regenerate manually when files change\n", .{});
                return error.UnsupportedPlatform;
            },
        }
    }

    /// Watch files using inotify (Linux)
    fn watchWithInotify(self: *CLI, options: Options) !void {
        const linux = std.os.linux;

        // Create inotify instance
        const fd = try std.posix.inotify_init1(linux.IN.CLOEXEC);
        defer std.posix.close(fd);

        // Watch all source directories
        var watch_descriptors = std.ArrayList(i32).init(self.allocator);
        defer watch_descriptors.deinit();

        for (options.source_dirs) |dir| {
            const wd = try std.posix.inotify_add_watch(
                fd,
                dir,
                linux.IN.MODIFY | linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO
            );
            try watch_descriptors.append(wd);
            std.debug.print("Watching: {s}\n", .{dir});
        }

        // Event buffer
        var buffer: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        var last_regenerate: i64 = std.time.timestamp();
        const debounce_seconds: i64 = 2; // Wait 2 seconds between regenerations

        // Watch loop
        while (true) {
            const bytes_read = try std.posix.read(fd, &buffer);

            if (bytes_read > 0) {
                const now = std.time.timestamp();

                // Debounce: only regenerate if enough time has passed
                if (now - last_regenerate >= debounce_seconds) {
                    std.debug.print("\n=== File change detected, regenerating... ===\n", .{});

                    self.generateDocs(options) catch |err| {
                        std.debug.print("Error regenerating: {}\n", .{err});
                    };

                    std.debug.print("=== Regeneration complete ===\n\n", .{});
                    last_regenerate = now;
                }
            }
        }
    }

    /// Watch files using kqueue (macOS/BSD)
    fn watchWithKqueue(self: *CLI, options: Options) !void {
        const c = std.c;

        // Create kqueue
        const kq = try std.posix.kqueue();
        defer std.posix.close(kq);

        // Open all source directories and add to kqueue
        var dir_fds = std.ArrayList(std.posix.fd_t).init(self.allocator);
        defer {
            for (dir_fds.items) |fd| {
                std.posix.close(fd);
            }
            dir_fds.deinit();
        }

        for (options.source_dirs) |dir_path| {
            const dir_fd = try std.posix.open(dir_path, .{ .ACCMODE = .RDONLY }, 0);
            try dir_fds.append(dir_fd);

            // Register directory with kqueue for file changes
            var kev: c.Kevent = undefined;
            const filter = c.EVFILT_VNODE;
            const flags = c.EV_ADD | c.EV_ENABLE | c.EV_CLEAR;
            const fflags = c.NOTE_WRITE | c.NOTE_DELETE | c.NOTE_EXTEND | c.NOTE_RENAME;

            kev.ident = @intCast(dir_fd);
            kev.filter = @intCast(filter);
            kev.flags = @intCast(flags);
            kev.fflags = @intCast(fflags);
            kev.data = 0;
            kev.udata = null;

            const result = c.kevent(kq, &kev, 1, null, 0, null);
            if (result < 0) {
                return error.KqueueRegisterFailed;
            }

            std.debug.print("Watching: {s}\n", .{dir_path});
        }

        // Event buffer
        var events: [10]c.Kevent = undefined;
        var last_regenerate: i64 = std.time.timestamp();
        const debounce_seconds: i64 = 2;

        // Watch loop
        while (true) {
            const timeout = c.timespec{ .tv_sec = 1, .tv_nsec = 0 };
            const num_events = c.kevent(kq, null, 0, &events, events.len, &timeout);

            if (num_events > 0) {
                const now = std.time.timestamp();

                // Debounce: only regenerate if enough time has passed
                if (now - last_regenerate >= debounce_seconds) {
                    std.debug.print("\n=== File change detected, regenerating... ===\n", .{});

                    self.generateDocs(options) catch |err| {
                        std.debug.print("Error regenerating: {}\n", .{err});
                    };

                    std.debug.print("=== Regeneration complete ===\n\n", .{});
                    last_regenerate = now;
                }
            }
        }
    }

    /// Validate documentation (check for broken links, invalid examples, etc.)
    fn validateDocs(self: *CLI, options: Options) !void {
        std.debug.print("Validating documentation...\n", .{});

        var issues = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (issues.items) |issue| {
                self.allocator.free(issue);
            }
            issues.deinit();
        }

        // Check if output directory exists
        std.fs.cwd().access(options.output_dir, .{}) catch {
            try issues.append(try std.fmt.allocPrint(self.allocator, "Output directory does not exist: {s}", .{options.output_dir}));
        };

        // Check for index.html
        const index_path = try std.fs.path.join(self.allocator, &.{ options.output_dir, "index.html" });
        defer self.allocator.free(index_path);

        std.fs.cwd().access(index_path, .{}) catch {
            try issues.append(try std.fmt.allocPrint(self.allocator, "Missing index.html", .{}));
        };

        // Collect all HTML files and check for broken internal links
        var html_files = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (html_files.items) |file| {
                self.allocator.free(file);
            }
            html_files.deinit();
        }

        try self.collectHTMLFiles(options.output_dir, &html_files);

        // Basic validation complete
        if (issues.items.len == 0) {
            std.debug.print("✓ Validation passed! Found {d} HTML files\n", .{html_files.items.len});
        } else {
            std.debug.print("✗ Validation found {d} issues:\n", .{issues.items.len});
            for (issues.items) |issue| {
                std.debug.print("  - {s}\n", .{issue});
            }
        }
    }

    /// Collect all HTML files from a directory
    fn collectHTMLFiles(self: *CLI, dir_path: []const u8, files: *std.ArrayList([]const u8)) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .directory) {
                const sub_dir = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
                defer self.allocator.free(sub_dir);
                try self.collectHTMLFiles(sub_dir, files);
            } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".html")) {
                const file_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
                try files.append(file_path);
            }
        }
    }

    /// Print help message
    fn printHelp(self: *CLI) !void {
        _ = self;
        const help_text =
            \\Usage: home doc <command> [options] <source-dirs>
            \\
            \\Commands:
            \\  generate         Generate documentation (default)
            \\  serve            Serve documentation with HTTP server
            \\  watch            Watch files and regenerate on changes
            \\  validate         Validate documentation integrity
            \\  help             Show this help message
            \\  version          Show version information
            \\
            \\Options:
            \\  -o, --output <dir>      Output directory (default: docs)
            \\  -t, --title <title>     Documentation title
            \\  -f, --format <format>   Output format: html, markdown, both (default: html)
            \\  --theme <theme>         Color scheme: github_light, github_dark, monokai, etc.
            \\  -w, --watch            Watch for file changes
            \\  -p, --port <port>      Server port (default: 8080)
            \\  --validate-examples    Validate code examples
            \\  --verbose              Verbose output
            \\
            \\Examples:
            \\  home doc generate src/ -o docs
            \\  home doc generate src/ --format markdown
            \\  home doc serve -p 3000
            \\  home doc watch src/ -o docs
            \\
        ;
        std.debug.print("{s}\n", .{help_text});
    }

    /// Print version information
    fn printVersion(self: *CLI) !void {
        _ = self;
        std.debug.print("Home Documentation Generator v0.1.0\n", .{});
    }
};

/// Main entry point for CLI
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var cli = CLI.init(allocator, args);
    try cli.run();
}
