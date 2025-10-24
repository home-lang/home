// Home Programming Language - Compile-Time JSON Import Example
// TypeScript-style narrow literal types with JSON imports

const Basics = @import("basics");
const json_import = @import("comptime").json_import;

// Example 1: Import package.json with narrow types
const pkg = comptime json_import.PackageJson.import("package.json");

pub fn main() !void {
    // Hover over 'name' shows: "my-package" (literal type)
    // Type is narrowed to the exact string value!
    const package_name = pkg.name;
    Basics.println("Package name: {s}", .{package_name});

    // Hover over 'version' shows: "1.0.0"
    const version = pkg.version;
    Basics.println("Version: {s}", .{version});

    // Access nested properties with full type safety
    if (pkg.scripts) |scripts| {
        if (scripts.get("build")) |build_script| {
            Basics.print("Build script: {s}\n", .{build_script});
        }
    }
}

// Example 2: Import custom JSON config with narrow types
const config = comptime blk: {
    const Config = struct {
        app_name: []const u8,
        port: i32,
        debug: bool,
        features: struct {
            auth: bool,
            database: bool,
            cache: bool,
        },
    };

    // This gets parsed at compile time with exact literal types!
    break :blk json_import.JsonSchema(Config).parseFile("config.json");
};

pub fn startServer() !void {
    // Hover over config.app_name shows the ACTUAL value: "MyApp"
    // VSCode shows: "MyApp" (not just []const u8)
    Basics.print("Starting {s} on port {d}\n", .{ config.app_name, config.port });

    // Hover over config.debug shows: true or false
    if (config.debug) {
        Basics.print("Debug mode enabled\n", .{});
    }

    // Hover over config.features.auth shows: true
    if (config.features.auth) {
        Basics.print("Auth enabled\n", .{});
    }
}

// Example 3: Using JSON imports in compile-time code generation
const api_endpoints = comptime json_import.importJson("api-endpoints.json");

pub fn generateRoutes() !void {
    // The JSON structure is available at compile time!
    // VSCode autocomplete shows all properties from the JSON file

    inline for (api_endpoints.parsed.array_value) |endpoint| {
        const path = endpoint.object_value.get("path").?.string_value;
        const method = endpoint.object_value.get("method").?.string_value;

        Basics.print("Route: {s} {s}\n", .{ method, path });
    }
}

// Example 4: Type-safe database configuration
const db_config = comptime blk: {
    const DatabaseConfig = struct {
        host: []const u8,
        port: i32,
        database: []const u8,
        username: []const u8,
        password: []const u8,
        pool: struct {
            min: i32,
            max: i32,
        },
    };

    break :blk json_import.JsonSchema(DatabaseConfig).parseFile("database.json");
};

pub fn connectDatabase() !void {
    // Hover over db_config.host shows: "localhost"
    // Hover over db_config.port shows: 5432
    // All values are narrowly typed with their literal values!

    Basics.print("Connecting to {s}:{d}\n", .{ db_config.host, db_config.port });
    Basics.print("Database: {s}\n", .{db_config.database});
    Basics.print("Pool size: {d}-{d}\n", .{ db_config.pool.min, db_config.pool.max });
}

// Example 5: Feature flags from JSON
const features = comptime json_import.importJson("features.json");

pub fn checkFeature(comptime feature_name: []const u8) bool {
    const feature_value = features.get(feature_name);

    return switch (feature_value) {
        .bool_value => |b| b,
        else => false,
    };
}

pub fn useFeatureFlags() !void {
    // Compile-time feature flag checking
    if (comptime checkFeature("use_new_ui")) {
        Basics.print("Using new UI\n", .{});
    } else {
        Basics.print("Using old UI\n", .{});
    }

    if (comptime checkFeature("enable_analytics")) {
        Basics.print("Analytics enabled\n", .{});
    }
}

// Example 6: Internationalization strings
const i18n = comptime json_import.importJson("locales/en.json");

pub fn translate(comptime key: []const u8) []const u8 {
    const value = i18n.get(key);
    return value.string_value;
}

pub fn showLocalizedText() !void {
    // Hover over translate("welcome") shows: "Welcome to our app!"
    const welcome_text = comptime translate("welcome");
    Basics.print("{s}\n", .{welcome_text});

    const goodbye_text = comptime translate("goodbye");
    Basics.print("{s}\n", .{goodbye_text});
}

// Example 7: Environment-specific configuration
const env = comptime blk: {
    // Select configuration based on build mode
    const build_mode = @import("builtin").mode;

    const env_file = switch (build_mode) {
        .Debug => "config.development.json",
        .ReleaseSafe => "config.staging.json",
        .ReleaseFast => "config.production.json",
        else => "config.development.json",
    };

    break :blk json_import.importJson(env_file);
};

pub fn getEnvironmentConfig() !void {
    // Different JSON file loaded based on build mode
    // Hover shows the actual value from the selected environment file
    const api_url = env.get("api_url").string_value;
    const timeout = env.get("timeout").int_value;

    Basics.print("API URL: {s}\n", .{api_url});
    Basics.print("Timeout: {d}ms\n", .{timeout});
}

// Example 8: Compile-time validation of JSON structure
const schema = comptime blk: {
    // This validates the JSON structure at compile time
    const json_str =
        \\{
        \\  "name": "my-app",
        \\  "version": "1.0.0",
        \\  "config": {
        \\    "port": 3000
        \\  }
        \\}
    ;

    json_import.assertJson(json_str); // Compile error if invalid JSON
    json_import.assertPath(json_str, "config.port"); // Compile error if path doesn't exist

    break :blk json_import.importJson(json_str);
};

// Example 9: Type-safe API responses
const ApiResponse = struct {
    status: i32,
    message: []const u8,
    data: ?struct {
        id: i64,
        name: []const u8,
        email: []const u8,
    } = null,
};

pub fn parseApiResponse(json_str: []const u8) !ApiResponse {
    var arena = Basics.heap.ArenaAllocator.init(Basics.heap.page_allocator);
    defer arena.deinit();

    return try json_import.JsonSchema(ApiResponse).parse(arena.allocator(), json_str);
}

// Example 10: Using with string literals
pub fn demonstrateLiteralTypes() !void {
    // Each of these gets the EXACT literal type
    const name_literal = json_import.stringLiteral("my-package");
    const version_literal = json_import.stringLiteral("1.0.0");
    const port_literal = json_import.intLiteral(3000);
    const enabled_literal = json_import.boolLiteral(true);

    // Hover over name_literal.literal shows: "my-package"
    // Type is: stringLiteral("my-package"), not just []const u8!
    Basics.print("Name: {s}\n", .{name_literal.literal});

    // Hover over port_literal.literal shows: 3000
    Basics.print("Port: {d}\n", .{port_literal.literal});

    // Compile-time equality checking with literal types
    if (comptime name_literal.equals("my-package")) {
        Basics.print("Name matches!\n", .{});
    }
}

// Example JSON files referenced in this example:

// package.json:
// {
//   "name": "my-package",
//   "version": "1.0.0",
//   "description": "A test package",
//   "scripts": {
//     "build": "zig build",
//     "test": "zig build test"
//   },
//   "dependencies": {
//     "some-lib": "^1.0.0"
//   }
// }

// config.json:
// {
//   "app_name": "MyApp",
//   "port": 3000,
//   "debug": true,
//   "features": {
//     "auth": true,
//     "database": true,
//     "cache": false
//   }
// }

// api-endpoints.json:
// [
//   {
//     "path": "/api/users",
//     "method": "GET"
//   },
//   {
//     "path": "/api/users/:id",
//     "method": "GET"
//   },
//   {
//     "path": "/api/users",
//     "method": "POST"
//   }
// ]

// database.json:
// {
//   "host": "localhost",
//   "port": 5432,
//   "database": "myapp",
//   "username": "admin",
//   "password": "secret",
//   "pool": {
//     "min": 2,
//     "max": 10
//   }
// }

// features.json:
// {
//   "use_new_ui": true,
//   "enable_analytics": false,
//   "beta_features": true
// }

// locales/en.json:
// {
//   "welcome": "Welcome to our app!",
//   "goodbye": "See you later!",
//   "error": "An error occurred"
// }
