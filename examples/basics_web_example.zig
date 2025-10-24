// Home Programming Language - Basics Web Framework Example
// Complete example using Home's Basics module for web development

const Basics = @import("basics");

// Example 1: Simple HTTP server with routing
pub fn example1_simple_server() !void {
    Basics.println("=== Example 1: Simple HTTP Server ===", .{});

    var gpa = Basics.createAllocator();
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create router
    var router = Basics.http_router.Router.init(allocator);
    defer router.deinit();

    // Add routes
    try router.get("/", handleHome);
    try router.get("/about", handleAbout);
    try router.post("/api/users", handleCreateUser);

    Basics.println("Server configured with 3 routes", .{});
}

fn handleHome(req: *Basics.http_router.Request, res: *Basics.http_router.Response) !void {
    _ = req;
    try res.json(.{ .message = "Welcome to Home!" });
}

fn handleAbout(req: *Basics.http_router.Request, res: *Basics.http_router.Response) !void {
    _ = req;
    try res.json(.{ .page = "about", .version = "1.0.0" });
}

fn handleCreateUser(req: *Basics.http_router.Request, res: *Basics.http_router.Response) !void {
    _ = req;
    try res.json(.{ .id = 123, .created = true });
}

// Example 2: Middleware usage
pub fn example2_middleware() !void {
    Basics.println("\n=== Example 2: Middleware ===", .{});

    var gpa = Basics.createAllocator();
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var router = Basics.http_router.Router.init(allocator);
    defer router.deinit();

    // CORS middleware
    const cors_config = Basics.middleware.CorsOptions{
        .allow_origin = "*",
        .allow_methods = "GET, POST, PUT, DELETE",
        .allow_headers = "Content-Type, Authorization",
        .max_age = 3600,
    };
    router.use(Basics.middleware.cors(cors_config));

    // Rate limiting
    var rate_limiter = try Basics.middleware.RateLimiter.init(
        allocator,
        .{
            .max_requests = 100,
            .window_seconds = 60,
        },
    );
    defer rate_limiter.deinit();
    router.use(rate_limiter.middleware());

    Basics.println("Middleware configured: CORS + Rate Limiting", .{});
}

// Example 3: Session management
pub fn example3_sessions() !void {
    Basics.println("\n=== Example 3: Session Management ===", .{});

    var gpa = Basics.createAllocator();
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create session manager
    var session_mgr = try Basics.session.SessionManager.init(allocator, .{
        .secret_key = "your-secret-key-here",
        .session_lifetime = 3600,
        .cookie_name = "home_session",
        .secure = true,
        .http_only = true,
    });
    defer session_mgr.deinit();

    // Create a new session
    const session_id = try session_mgr.createSession();
    var session = session_mgr.getSession(session_id).?;

    // Set session data
    try session.set("user_id", "123");
    try session.set("username", "alice");
    try session.set("role", "admin");

    Basics.println("Session created: {s}", .{session_id});
    Basics.println("  user_id: {s}", .{session.get("user_id") orelse "none"});
    Basics.println("  username: {s}", .{session.get("username") orelse "none"});
    Basics.println("  role: {s}", .{session.get("role") orelse "none"});
}

// Example 4: Validation
pub fn example4_validation() !void {
    Basics.println("\n=== Example 4: Validation ===", .{});

    var gpa = Basics.createAllocator();
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create validator
    var validator = Basics.validation.Validator.init(allocator);
    defer validator.deinit();

    // Define validation rules
    var email_field = try validator.field("email");
    try email_field.addRule(Basics.validation.Required.rule());
    try email_field.addRule(Basics.validation.Email.rule());

    var age_field = try validator.field("age");
    try age_field.addRule(Basics.validation.Required.rule());
    var min_rule = Basics.validation.Min{ .min = 18 };
    try age_field.addRule(min_rule.toRule());

    // Test validation
    const test_data = .{
        .email = "alice@example.com",
        .age = 25,
    };

    Basics.println("Validating data:", .{});
    Basics.println("  email: {s}", .{test_data.email});
    Basics.println("  age: {d}", .{test_data.age});
    Basics.println("Validation would pass!", .{});
}

// Example 5: JSON handling with narrow types
pub fn example5_json_config() !void {
    Basics.println("\n=== Example 5: JSON Configuration ===", .{});

    // Import config at compile time
    const config = comptime blk: {
        const Config = struct {
            app_name: []const u8,
            port: i32,
            debug: bool,
            database: struct {
                host: []const u8,
                port: i32,
            },
        };

        // This would load from actual file
        break :blk Config{
            .app_name = "MyApp",
            .port = 3000,
            .debug = true,
            .database = .{
                .host = "localhost",
                .port = 5432,
            },
        };
    };

    // Hover over config.app_name shows: "MyApp"
    // Hover over config.port shows: 3000
    Basics.println("App: {s}", .{config.app_name});
    Basics.println("Port: {d}", .{config.port});
    Basics.println("Debug: {}", .{config.debug});
    Basics.println("Database: {s}:{d}", .{ config.database.host, config.database.port });
}

// Example 6: Complete web application
pub fn example6_complete_app() !void {
    Basics.println("\n=== Example 6: Complete Web App ===", .{});

    var gpa = Basics.createAllocator();
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create router
    var router = Basics.http_router.Router.init(allocator);
    defer router.deinit();

    // Add middleware
    const cors = Basics.middleware.CorsOptions{
        .allow_origin = "*",
        .allow_methods = "GET, POST, PUT, DELETE",
        .allow_headers = "Content-Type",
        .max_age = 3600,
    };
    router.use(Basics.middleware.cors(cors));

    // Add routes
    try router.get("/", indexHandler);
    try router.get("/api/health", healthHandler);
    try router.post("/api/login", loginHandler);
    try router.get("/api/users/:id", getUserHandler);

    Basics.println("Complete app configured!", .{});
    Basics.println("  Routes: 4", .{});
    Basics.println("  Middleware: CORS", .{});
}

fn indexHandler(req: *Basics.http_router.Request, res: *Basics.http_router.Response) !void {
    _ = req;
    try res.html("<h1>Welcome to Home!</h1>");
}

fn healthHandler(req: *Basics.http_router.Request, res: *Basics.http_router.Response) !void {
    _ = req;
    try res.json(.{
        .status = "healthy",
        .timestamp = Basics.now(),
        .uptime = 12345,
    });
}

fn loginHandler(req: *Basics.http_router.Request, res: *Basics.http_router.Response) !void {
    _ = req;
    // In real app, validate credentials
    try res.json(.{
        .success = true,
        .token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
        .expires_in = 3600,
    });
}

fn getUserHandler(req: *Basics.http_router.Request, res: *Basics.http_router.Response) !void {
    const user_id = req.params.get("id") orelse "unknown";

    try res.json(.{
        .id = user_id,
        .name = "Alice",
        .email = "alice@example.com",
        .role = "admin",
    });
}

// Example 7: Using friendly Basics helpers
pub fn example7_basics_helpers() !void {
    Basics.println("\n=== Example 7: Basics Helpers ===", .{});

    // String comparison
    const name = "Alice";
    if (Basics.strEql(name, "Alice")) {
        Basics.println("Name matches: {s}", .{name});
    }

    // Time helpers
    const timestamp = Basics.now();
    const millis = Basics.nowMillis();
    Basics.println("Current time:", .{});
    Basics.println("  Seconds: {d}", .{timestamp});
    Basics.println("  Milliseconds: {d}", .{millis});

    // Type aliases
    const message: Basics.String = "Hello, Home!";
    const count: Basics.Integer = 42;
    const price: Basics.Float = 19.99;
    const active: Basics.Boolean = true;

    Basics.println("Type aliases:", .{});
    Basics.println("  message (String): {s}", .{message});
    Basics.println("  count (Integer): {d}", .{count});
    Basics.println("  price (Float): {d:.2}", .{price});
    Basics.println("  active (Boolean): {}", .{active});
}

// Example 8: Result and Option types
pub fn example8_result_option() !void {
    Basics.println("\n=== Example 8: Result & Option Types ===", .{});

    // Result type
    const result = divide(10, 2);
    if (result.isOk()) {
        Basics.println("Division result: {d}", .{result.unwrap()});
    } else {
        Basics.println("Division failed", .{});
    }

    // Option type
    const user = findUser(123);
    if (user.isSome()) {
        const u = user.unwrap();
        Basics.println("Found user: {s} (id: {d})", .{ u.name, u.id });
    } else {
        Basics.println("User not found", .{});
    }
}

fn divide(a: i32, b: i32) Basics.Result(i32) {
    if (b == 0) {
        return .{ .err = Basics.Error.InvalidInput };
    }
    return .{ .ok = @divTrunc(a, b) };
}

const User = struct {
    id: i64,
    name: []const u8,
    email: []const u8,
};

fn findUser(id: i64) Basics.Option(User) {
    if (id == 123) {
        return .{
            .some = User{
                .id = 123,
                .name = "Alice",
                .email = "alice@example.com",
            },
        };
    }
    return .{ .none = {} };
}

// Main function - run all examples
pub fn main() !void {
    Basics.println("╔══════════════════════════════════════╗", .{});
    Basics.println("║  Home Basics Web Framework Examples ║", .{});
    Basics.println("╚══════════════════════════════════════╝\n", .{});

    try example1_simple_server();
    try example2_middleware();
    try example3_sessions();
    try example4_validation();
    try example5_json_config();
    try example6_complete_app();
    try example7_basics_helpers();
    try example8_result_option();

    Basics.println("\n✓ All examples completed successfully!", .{});
}
