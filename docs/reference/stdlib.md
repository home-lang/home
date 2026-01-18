# Standard Library

Home's standard library provides essential modules for building applications, from collections to networking.

## Overview

The standard library is organized into modules:

| Module | Description |
|--------|-------------|
| `std::collections` | Data structures (Vec, HashMap, etc.) |
| `std::io` | Input/output operations |
| `std::fs` | File system operations |
| `std::net` | Networking |
| `std::http` | HTTP client and server |
| `std::json` | JSON parsing and serialization |
| `std::sync` | Synchronization primitives |
| `std::time` | Time and duration |
| `std::fmt` | String formatting |

## Collections

### Vec (Dynamic Array)

```home
import std::collections::Vec

let mut numbers = Vec<int>.new()
numbers.push(1)
numbers.push(2)
numbers.push(3)

print("Length: {}", numbers.len())     // 3
print("First: {}", numbers[0])          // 1
print("Last: {}", numbers.last())       // Some(3)

// Iteration
for (n in numbers) {
  print(n)
}

// Methods
numbers.pop()           // Remove last
numbers.insert(0, 0)    // Insert at index
numbers.remove(1)       // Remove at index
numbers.clear()         // Remove all
```

### HashMap

```home
import std::collections::HashMap

let mut users = HashMap<string, User>.new()
users.insert("alice", User { name: "Alice", age: 30 })
users.insert("bob", User { name: "Bob", age: 25 })

// Access
let alice = users.get("alice")  // Option<&User>

// Check existence
if (users.contains_key("alice")) {
  print("Found Alice")
}

// Iteration
for ((key, value) in users) {
  print("{}: {}", key, value.name)
}

// Remove
users.remove("bob")
```

### HashSet

```home
import std::collections::HashSet

let mut tags = HashSet<string>.new()
tags.insert("rust")
tags.insert("programming")
tags.insert("rust")  // Duplicate ignored

print("Count: {}", tags.len())  // 2

// Set operations
let other = HashSet.from(["rust", "golang"])
let union = tags.union(&other)
let intersection = tags.intersection(&other)
let difference = tags.difference(&other)
```

### LinkedList

```home
import std::collections::LinkedList

let mut list = LinkedList<int>.new()
list.push_front(1)
list.push_back(2)
list.push_back(3)

print("Front: {}", list.front())  // Some(1)
print("Back: {}", list.back())    // Some(3)

list.pop_front()  // Remove first
list.pop_back()   // Remove last
```

## File System

### Reading Files

```home
import std::fs

// Read entire file as string
let content = fs.read_to_string("config.json")?

// Read as bytes
let bytes = fs.read("image.png")?

// Read lines
for (line in fs.read_lines("data.txt")?) {
  print(line)
}
```

### Writing Files

```home
import std::fs

// Write string
fs.write("output.txt", "Hello, World!")?

// Append
fs.append("log.txt", "New log entry\n")?

// Write bytes
fs.write_bytes("data.bin", bytes)?
```

### File Operations

```home
import std::fs

// Check existence
if (fs.exists("config.json")) {
  // ...
}

// File metadata
let meta = fs.metadata("file.txt")?
print("Size: {} bytes", meta.size)
print("Modified: {}", meta.modified)

// Copy, move, delete
fs.copy("source.txt", "dest.txt")?
fs.rename("old.txt", "new.txt")?
fs.remove("temp.txt")?

// Directories
fs.create_dir("new_folder")?
fs.create_dir_all("path/to/folder")?
fs.remove_dir("empty_folder")?
fs.remove_dir_all("folder_with_contents")?

// List directory
for (entry in fs.read_dir(".")?) {
  print("{}", entry.name)
}
```

## HTTP

### HTTP Client

```home
import std::http

// GET request
let response = await http.get("https://api.example.com/users")?
print("Status: {}", response.status)

let users: []User = await response.json()?

// POST with JSON
let new_user = User { name: "Alice", email: "alice@example.com" }
let response = await http.post("https://api.example.com/users")
  .json(new_user)
  .send()?

// With headers
let response = await http.get("https://api.example.com/data")
  .header("Authorization", "Bearer token123")
  .header("Accept", "application/json")
  .send()?

// Timeout
let response = await http.get("https://api.example.com/slow")
  .timeout(Duration.seconds(10))
  .send()?
```

### HTTP Server

```home
import std::http::{Server, Response}

fn main(): async {
  let server = Server.bind(":3000")

  server.get("/", |req| {
    Response.text("Hello from Home!")
  })

  server.get("/users/:id", async |req| {
    let id = req.param("id").parse::<int>()?
    let user = await database.find_user(id)

    match user {
      Some(u) => Response.json(u),
      None => Response.status(404).text("Not found")
    }
  })

  server.post("/users", async |req| {
    let user: User = await req.json()?
    let created = await database.create_user(user)
    Response.status(201).json(created)
  })

  print("Server running on http://localhost:3000")
  await server.listen()
}
```

## JSON

### Parsing JSON

```home
import std::json

// Parse string to value
let value = json.parse("{\"name\": \"Alice\", \"age\": 30}")?

// Access fields
let name = value["name"].as_string()?
let age = value["age"].as_int()?

// Parse to typed struct
#[derive(Deserialize)]
struct User {
  name: string,
  age: int
}

let user: User = json.from_str("{\"name\": \"Alice\", \"age\": 30}")?
```

### Generating JSON

```home
import std::json

#[derive(Serialize)]
struct User {
  name: string,
  age: int
}

let user = User { name: "Alice", age: 30 }
let json_string = json.to_string(&user)?  // {"name":"Alice","age":30}

// Pretty print
let pretty = json.to_string_pretty(&user)?
```

## Networking

### TCP

```home
import std::net::{TcpListener, TcpStream}

// Server
fn main(): async {
  let listener = TcpListener.bind("127.0.0.1:8080")?

  while (let Ok(stream) = await listener.accept()) {
    spawn(handle_client(stream))
  }
}

async fn handle_client(mut stream: TcpStream) {
  let mut buffer = [0u8; 1024]
  let n = await stream.read(&mut buffer)?
  await stream.write(&buffer[..n])?
}

// Client
async fn connect() {
  let mut stream = await TcpStream.connect("127.0.0.1:8080")?
  await stream.write(b"Hello, server!")?

  let mut buffer = [0u8; 1024]
  let n = await stream.read(&mut buffer)?
  print("Response: {}", String.from_utf8(&buffer[..n])?)
}
```

### UDP

```home
import std::net::UdpSocket

let socket = UdpSocket.bind("127.0.0.1:0")?
socket.send_to(b"Hello", "127.0.0.1:8080")?

let mut buffer = [0u8; 1024]
let (n, addr) = socket.recv_from(&mut buffer)?
print("From {}: {}", addr, String.from_utf8(&buffer[..n])?)
```

## Synchronization

### Mutex

```home
import std::sync::Mutex

let counter = Mutex.new(0)

spawn(|| {
  let mut num = counter.lock()
  *num += 1
})

spawn(|| {
  let mut num = counter.lock()
  *num += 1
})
```

### RwLock

```home
import std::sync::RwLock

let data = RwLock.new(vec![1, 2, 3])

// Multiple readers
spawn(|| {
  let read = data.read()
  print("{:?}", *read)
})

// Single writer
spawn(|| {
  let mut write = data.write()
  write.push(4)
})
```

### Channels

```home
import std::sync::channel

let (tx, rx) = channel<int>()

spawn(|| {
  for (i in 0..10) {
    tx.send(i)
  }
})

while (let Some(n) = rx.recv()) {
  print("Received: {}", n)
}
```

## Time

### Duration

```home
import std::time::Duration

let d1 = Duration.seconds(5)
let d2 = Duration.millis(100)
let d3 = Duration.micros(1000)
let d4 = Duration.nanos(1000000)

let total = d1 + d2
print("Total: {} ms", total.as_millis())
```

### Instant

```home
import std::time::Instant

let start = Instant.now()

// Do work...

let elapsed = start.elapsed()
print("Took {} ms", elapsed.as_millis())
```

### Sleep

```home
import std::time::{sleep, Duration}

async fn delayed_action() {
  await sleep(Duration.seconds(1))
  print("One second later!")
}
```

## String Formatting

```home
import std::fmt

// Basic formatting
let s = fmt.format("Hello, {}!", "World")

// Positional arguments
let s = fmt.format("{0} and {1}, {1} and {0}", "Alice", "Bob")

// Named arguments
let s = fmt.format("{name} is {age} years old", name: "Alice", age: 30)

// Number formatting
let s = fmt.format("{:.2}", 3.14159)      // "3.14"
let s = fmt.format("{:08}", 42)            // "00000042"
let s = fmt.format("{:x}", 255)            // "ff"
let s = fmt.format("{:b}", 10)             // "1010"

// Debug formatting
let s = fmt.format("{:?}", some_struct)
let s = fmt.format("{:#?}", some_struct)   // Pretty print
```

## Database

### SQLite

```home
import std::database::sqlite

let db = sqlite.open("app.db")?

// Create table
db.exec("CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, name TEXT)")?

// Insert
let stmt = db.prepare("INSERT INTO users (name) VALUES (?)")?
stmt.bind(1, "Alice")
stmt.execute()?

// Query
let rows = db.query("SELECT * FROM users WHERE id = ?", [1])?
for (row in rows) {
  print("User: {}", row.get::<string>("name")?)
}
```

## Environment

```home
import std::env

// Get environment variable
let home = env.var("HOME")?

// With default
let port = env.var("PORT").unwrap_or("8080")

// Set environment variable
env.set_var("MY_VAR", "value")

// Command line arguments
let args = env.args()
for (arg in args) {
  print(arg)
}
```

## Random

```home
import std::random

// Random integers
let n = random.int(1, 100)    // 1 to 100 inclusive

// Random float
let f = random.float()         // 0.0 to 1.0

// Random choice
let items = ["apple", "banana", "cherry"]
let choice = random.choice(&items)

// Shuffle
let mut nums = [1, 2, 3, 4, 5]
random.shuffle(&mut nums)

// UUID
let id = random.uuid()
```

## Paths

```home
import std::path::Path

let path = Path.new("/home/user/documents/file.txt")

print("File name: {}", path.file_name())     // "file.txt"
print("Extension: {}", path.extension())      // "txt"
print("Parent: {}", path.parent())            // "/home/user/documents"
print("Is absolute: {}", path.is_absolute()) // true

// Join paths
let new_path = path.parent().join("other.txt")

// Canonicalize
let absolute = Path.new("./relative").canonicalize()?
```

## See Also

- [Getting Started](/guide/getting-started) - Installation and setup
- [Error Handling](/guide/error-handling) - Working with Result types
- [Async Programming](/guide/async) - Async I/O patterns
- [HomeOS Documentation](https://github.com/home-lang/homeos) - OS-level APIs
