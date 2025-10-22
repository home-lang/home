# Ion Standard Library Modules

Complete reference for Ion's standard library.

---

## 📦 Available Modules

### Core Utilities

#### `datetime.zig` - Date and Time
```ion
import std.datetime;

let now = DateTime.now();
let iso = now.formatISO(allocator);
let tomorrow = now.addDays(1);
let timer = Timer.start();
```

**Exports**:
- `DateTime` - Date/time manipulation
- `Duration` - Time duration
- `Timer` - Elapsed time measurement
- `parseISO()` - Parse ISO 8601
- `sleep()` - Sleep for duration

---

#### `crypto.zig` - Cryptography
```ion
import std.crypto;

let hash = SHA256.hash("data");
let uuid = UUID.v4();
let token = JWT.create(allocator, claims, secret);
let salt = Password.generateSalt(allocator);
```

**Exports**:
- `SHA256`, `SHA512`, `MD5`, `BLAKE3` - Hashing
- `HMAC` - Message authentication
- `Base64`, `Hex` - Encoding
- `Random`, `SecureRandom` - Random generation
- `Password` - Password hashing
- `UUID` - UUID generation
- `JWT` - JSON Web Tokens

---

#### `process.zig` - Process Management
```ion
import std.process;

let result = exec(allocator, &[_][]const u8{"ls", "-la"});
let builder = ProcessBuilder.init(allocator)
    .command("git").arg("status").run();
```

**Exports**:
- `exec()`, `execWithInput()`, `shell()` - Execute commands
- `SpawnedProcess` - Async process
- `ProcessBuilder` - Fluent process builder
- `Pipe` - Process pipes
- `Signal` - Unix signals
- Environment & directory management functions

---

#### `cli.zig` - Command-Line Arguments
```ion
import std.cli;

let parser = ArgParser.init(allocator, "myapp", "Description");
parser.addString("input", 'i', "input", true, null, "Input file");
parser.parse(argv);
let input = parser.getString("input");
```

**Exports**:
- `ArgParser` - Full-featured argument parser
- `SimpleArgs` - Quick argument parsing
- `Env` - Environment variable helpers

---

#### `regex.zig` - Regular Expressions
```ion
import std.regex;

let regex = Regex.compile(allocator, "[0-9]+");
let matches = regex.findAll("abc 123 def 456");
let replaced = regex.replaceAll("text", "replacement");
```

**Exports**:
- `Regex` - Pattern matching engine
- `Match` - Match result
- `Patterns` - Common patterns (EMAIL, URL, IPV4, etc.)

---

### Networking

#### `http.zig` - HTTP Client
```ion
import std.http;

let client = HttpClient.init(allocator);
let response = client.get("https://api.example.com/users");
let json_response = client.post("https://api.example.com/users", 
    .{ .body = "{\"name\":\"John\"}", .content_type = "application/json" });
```

**Exports**:
- `HttpClient` - HTTP/HTTPS client
- `Request`, `Response` - HTTP messages
- GET, POST, PUT, DELETE, PATCH methods

---

#### `tcp.zig` - TCP Sockets
```ion
import std.tcp;

let server = TcpServer.init(allocator, "127.0.0.1", 8080);
server.listen(handle_client);

let client = TcpClient.connect(allocator, "127.0.0.1", 8080);
client.write("Hello");
```

**Exports**:
- `TcpServer` - TCP server
- `TcpClient` - TCP client

---

#### `udp.zig` - UDP Sockets
```ion
import std.udp;

let socket = UdpSocket.bind(allocator, "127.0.0.1", 8080);
socket.sendTo("data", "127.0.0.1", 9000);
```

**Exports**:
- `UdpSocket` - UDP socket

---

### Data Formats

#### `json.zig` - JSON Parsing/Serialization
```ion
import std.json;

let parsed = JSON.parse(allocator, "{\"name\":\"John\"}");
let serialized = JSON.stringify(allocator, value);

let builder = JSON.object()
    .put("name", "John")
    .put("age", 30);
```

**Exports**:
- `JSON` - Parser and serializer
- `Value` - JSON value types
- Builder pattern for construction

---

### File System

#### `file.zig` - File I/O
```ion
import std.file;

let content = File.read(allocator, "path/to/file.txt");
File.write("path/to/file.txt", "content");
File.append("path/to/file.txt", "more content");
```

**Exports**:
- `File` - File operations
- `Directory` - Directory operations
- `Path` - Path utilities

---

## 📊 Module Statistics

| Module | Lines | Exports | Status |
|--------|-------|---------|--------|
| datetime.zig | 430 | 5 | ✅ Complete |
| crypto.zig | 440 | 9 | ✅ Complete |
| process.zig | 380 | 15+ | ✅ Complete |
| cli.zig | 370 | 3 | ✅ Complete |
| regex.zig | 390 | 3 | ✅ Complete |
| http.zig | 280 | 3 | ✅ Complete |
| tcp.zig | 180 | 2 | ✅ Complete |
| udp.zig | 120 | 1 | ✅ Complete |
| json.zig | 350 | 3 | ✅ Complete |
| file.zig | 240 | 3 | ✅ Complete |

**Total**: ~3,180 lines of standard library code

---

## 🎯 Usage Patterns

### Web API Example
```ion
import std.http;
import std.json;
import std.crypto;

fn main() async {
    let server = HttpServer.new();
    
    server.get("/users/:id", async |req, res| {
        let id = req.params.get("id");
        let user = await db.users.find(id);
        res.json(user);
    });
    
    server.post("/auth/login", async |req, res| {
        let body = JSON.parse(allocator, req.body());
        let token = JWT.create(allocator, body, secret);
        res.json(.{ .token = token });
    });
    
    server.listen(8080);
}
```

### CLI Tool Example
```ion
import std.cli;
import std.file;
import std.process;

fn main() !void {
    let parser = ArgParser.init(allocator, "mytool", "My CLI tool");
    parser.addString("input", 'i', "input", true, null, "Input file");
    parser.addString("output", 'o', "output", false, "out.txt", "Output file");
    parser.addBool("verbose", 'v', "verbose", "Verbose output");
    
    parser.parse(std.process.getArgs(allocator));
    
    let input = parser.getString("input").?;
    let output = parser.getString("output").?;
    
    let content = File.read(allocator, input);
    // ... process content ...
    File.write(output, processed);
}
```

### Background Job Example
```ion
import std.process;
import std.datetime;
import std.crypto;

fn process_video(path: []const u8) !void {
    let timer = Timer.start();
    
    // Spawn ffmpeg process
    let result = ProcessBuilder.init(allocator)
        .command("ffmpeg")
        .args(&[_][]const u8{"-i", path, "-codec:v", "libx264", "output.mp4"})
        .run();
    
    if (result.exit_code != 0) {
        log.error("Video processing failed: {s}", .{result.stderr});
        return error.ProcessingFailed;
    }
    
    let elapsed = timer.elapsedMillis();
    log.info("Video processed in {d}ms", .{elapsed});
}
```

---

## 🚀 Future Additions

The following modules are planned:

### Web Framework (Phase 1)
- `router.zig` - HTTP routing
- `middleware.zig` - Middleware system
- `template.zig` - Template engine

### Database (Phase 1)
- `postgres.zig` - PostgreSQL driver
- `mysql.zig` - MySQL driver
- `sqlite.zig` - SQLite driver
- `orm.zig` - Object-relational mapping

### Testing (Phase 3)
- `test.zig` - BDD testing framework
- `mock.zig` - Mocking utilities
- `assert.zig` - Enhanced assertions

### Advanced (Phase 5+)
- `cache.zig` - Caching (Redis, in-memory)
- `queue.zig` - Job queues
- `email.zig` - Email sending
- `graphql.zig` - GraphQL server
- `websocket.zig` - WebSocket server

---

**Last Updated**: 2025-10-22
**Status**: ✅ Core standard library complete
**Total Modules**: 10 complete, 15+ planned
