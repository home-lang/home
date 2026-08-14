# Home Typed ORM - Complete Guide

> **Fully Type-Safe ORM with Compile-Time Validation**
> Zero runtime overhead • Type errors caught at compile time • Elegant API

---

## 🎯 Key Features

### ✅ Compile-Time Type Safety

- **Field validation** - Wrong field names = compile error
- **Type checking** - Wrong types = compile error
- **Relationship validation** - Invalid relationships = compile error
- **SQL generation** - All validated at compile time

### ✅ Zero Runtime Overhead

- No reflection at runtime
- No dynamic dispatch
- Direct struct field access
- Optimized queries

### ✅ Elegant API

- Chainable query builder
- Type-safe relationships
- Clean model definitions
- Intuitive syntax

---

## 📚 Quick Start

### 1. Define Your Model

```zig
const User = struct {
    id: i64 = 0,
    email: []const u8,
    name: []const u8,
    age: ?i32 = null,
    is_active: bool = true,

    pub const table = "users";
};
```

### 2. Create the Model Type

```zig
const typed_orm = @import("typed_orm");
const UserModel = typed_orm.Model(User);
```

### 3. Use It

```zig
// Create
var user = UserModel.new(allocator, &connection);
user.set("email", "alice@example.com"); // Type-checked!
user.set("age", @as(i32, 28)); // Must be i32
try user.save();

// Query with type safety
var query = typed_orm.Query(User).init(allocator, &connection);
_ = try query.where("email", "=", "alice@example.com"); // Field validated!
const found = try query.first();

// Update
user.set("age", @as(i32, 29));
try user.save();

// Delete
try user.delete();
```

---

## 🏗️ Model Definitions

### Basic Model

```zig
const User = struct {
    // Primary key (auto-detected by name "id")
    id: i64 = 0,

    // Required fields
    email: []const u8,
    name: []const u8,

    // Optional fields (nullable)
    age: ?i32 = null,
    bio: ?[]const u8 = null,

    // Boolean with default
    is_active: bool = true,

    // Timestamps
    created_at: i64 = 0,
    updated_at: i64 = 0,

    // Specify table name (optional, defaults to struct name)
    pub const table = "users";
};
```

### Supported Types

| Zig Type | SQL Type | Example |
|----------|----------|---------|
| `i32`, `i64` | INTEGER/BIGINT | `user_id: i64` |
| `f32`, `f64` | REAL | `price: f64` |
| `bool` | BOOLEAN | `is_active: bool` |
| `[]const u8` | TEXT | `name: []const u8` |
| `?T` | T NULL | `age: ?i32` |

### With Custom Primary Key

```zig
const Post = struct {
    // Custom primary key name
    post_id: i64 = 0,
    title: []const u8,
    content: []const u8,

    pub const table = "posts";

    // Specify primary key (if not "id")
    pub const post_id_options = struct {
        pub const is_primary = true;
        pub const auto_increment = true;
    };
};
```

---

## 💾 CRUD Operations

### Create

```zig
const UserModel = typed_orm.Model(User);

// Method 1: Create and set fields
var user = UserModel.new(allocator, &connection);
user.set("email", "alice@example.com");
user.set("name", "Alice Smith");
user.set("age", @as(i32, 28));
try user.save();

// Method 2: Initialize with data
var user = UserModel.init(allocator, &connection, .{
    .id = 0,
    .email = "bob@example.com",
    .name = "Bob Johnson",
    .age = 35,
    .is_active = true,
    .created_at = std.time.timestamp(),
    .updated_at = std.time.timestamp(),
});
try user.save();
```

### Read

```zig
const UserQuery = typed_orm.Query(User);

// Find by ID
const user = try UserQuery.find(allocator, &connection, 1);
if (user) |u| {
    std.debug.print("Found: {s}\n", .{u.get("name")});
}

// Find first matching
var query = UserQuery.init(allocator, &connection);
defer query.deinit();

_ = try query.where("email", "=", "alice@example.com");
const found = try query.first();

// Get all matching
var query2 = UserQuery.init(allocator, &connection);
defer query2.deinit();

_ = try query2.where("is_active", "=", true);
const users = try query2.get();
defer allocator.free(users);

for (users) |user| {
    std.debug.print("{s}\n", .{user.get("name")});
}
```

### Update

```zig
// Load user
var user = (try UserQuery.find(allocator, &connection, 1)).?;

// Modify fields (type-safe!)
user.set("name", "Alice Cooper");
user.set("age", @as(i32, 29));
user.set("updated_at", std.time.timestamp());

// Save changes
try user.save();
```

### Delete

```zig
var user = (try UserQuery.find(allocator, &connection, 1)).?;
try user.delete();
```

---

## 🔍 Type-Safe Queries

### Basic Queries

```zig
var query = typed_orm.Query(User).init(allocator, &connection);
defer query.deinit();

// Where clause (field validated at compile time!)
_ = try query.where("email", "=", "alice@example.com");
_ = try query.where("age", ">", 18);
_ = try query.where("is_active", "=", true);

// Order by (field validated!)
_ = query.orderBy("created_at", .desc);
_ = query.orderBy("name", .asc);

// Limit and offset
_ = query.limit(10);
_ = query.offset(20);

// Execute
const users = try query.get();
defer allocator.free(users);
```

### Select Specific Fields

```zig
var query = typed_orm.Query(User).init(allocator, &connection);
defer query.deinit();

// Only select specific fields (validated at compile time!)
_ = query.select(&.{ "id", "name", "email" });

const users = try query.get();
defer allocator.free(users);
```

### Chaining

```zig
var query = typed_orm.Query(User).init(allocator, &connection);
defer query.deinit();

const active_users = try query
    .where("is_active", "=", true)
    .where("age", ">=", 18)
    .orderBy("created_at", .desc)
    .limit(10)
    .get();

defer allocator.free(active_users);
```

### Aggregates

```zig
// Count
var count_query = typed_orm.Query(User).init(allocator, &connection);
defer count_query.deinit();

_ = try count_query.where("is_active", "=", true);
const total = try count_query.count();

std.debug.print("Active users: {d}\n", .{total});

// Exists
var exists_query = typed_orm.Query(User).init(allocator, &connection);
defer exists_query.deinit();

_ = try exists_query.where("email", "=", "test@example.com");
const exists = try exists_query.exists();

if (exists) {
    std.debug.print("Email already registered\n", .{});
}
```

---

## 🔗 Type-Safe Relationships

### One-to-One (Has-One)

```zig
const User = struct {
    id: i64 = 0,
    email: []const u8,
    name: []const u8,
    pub const table = "users";
};

const Profile = struct {
    id: i64 = 0,
    user_id: i64,  // Foreign key
    avatar_url: ?[]const u8 = null,
    website: ?[]const u8 = null,
    pub const table = "profiles";
};

// Define relationship
const UserProfile = typed_orm.HasOne(User, Profile, "user_id");

// Use it
const user = (try typed_orm.Query(User).find(allocator, &connection, 1)).?;
const profile = try UserProfile.get(allocator, &connection, &user);

if (profile) |p| {
    std.debug.print("Website: {s}\n", .{p.get("website") orelse "N/A"});
}
```

### One-to-Many (Has-Many)

```zig
const User = struct {
    id: i64 = 0,
    name: []const u8,
    pub const table = "users";
};

const Post = struct {
    id: i64 = 0,
    user_id: i64,  // Foreign key
    title: []const u8,
    content: []const u8,
    pub const table = "posts";
};

// Define relationship
const UserPosts = typed_orm.HasMany(User, Post, "user_id");

// Use it
const user = (try typed_orm.Query(User).find(allocator, &connection, 1)).?;
const posts = try UserPosts.get(allocator, &connection, &user);
defer allocator.free(posts);

std.debug.print("User has {d} posts:\n", .{posts.len});
for (posts) |post| {
    std.debug.print("  - {s}\n", .{post.get("title")});
}
```

### Belongs-To (Inverse)

```zig
const Post = struct {
    id: i64 = 0,
    user_id: i64,
    title: []const u8,
    pub const table = "posts";
};

const User = struct {
    id: i64 = 0,
    name: []const u8,
    pub const table = "users";
};

// Define relationship
const PostAuthor = typed_orm.BelongsTo(Post, User, "user_id");

// Use it
const post = (try typed_orm.Query(Post).find(allocator, &connection, 1)).?;
const author = try PostAuthor.get(allocator, &connection, &post);

if (author) |user| {
    std.debug.print("Written by: {s}\n", .{user.get("name")});
}
```

### Complete Example

```zig
// Models
const User = struct {
    id: i64 = 0,
    name: []const u8,
    pub const table = "users";
};

const Post = struct {
    id: i64 = 0,
    user_id: i64,
    title: []const u8,
    pub const table = "posts";
};

const Comment = struct {
    id: i64 = 0,
    post_id: i64,
    user_id: i64,
    content: []const u8,
    pub const table = "comments";
};

// Relationships
const UserPosts = typed_orm.HasMany(User, Post, "user_id");
const PostComments = typed_orm.HasMany(Post, Comment, "post_id");
const CommentAuthor = typed_orm.BelongsTo(Comment, User, "user_id");

// Usage
const user = (try typed_orm.Query(User).find(allocator, &connection, 1)).?;
const posts = try UserPosts.get(allocator, &connection, &user);
defer allocator.free(posts);

for (posts) |post| {
    std.debug.print("Post: {s}\n", .{post.get("title")});

    const comments = try PostComments.get(allocator, &connection, &post);
    defer allocator.free(comments);

    for (comments) |comment| {
        const author = try CommentAuthor.get(allocator, &connection, &comment);
        if (author) |a| {
            std.debug.print("  Comment by {s}: {s}\n", .{
                a.get("name"),
                comment.get("content"),
            });
        }
    }
}
```

---

## 🛠️ Schema Generation

### Create Tables

```zig
const UserModel = typed_orm.Model(User);

// Generate CREATE TABLE SQL from struct definition
const create_sql = try UserModel.createTableSQL(allocator);
defer allocator.free(create_sql);

// Execute
try connection.exec(create_sql);
```

Generated SQL:
```sql
CREATE TABLE IF NOT EXISTS users (
  id BIGINT PRIMARY KEY AUTOINCREMENT,
  email TEXT,
  name TEXT,
  age INTEGER,
  is_active BOOLEAN,
  created_at BIGINT,
  updated_at BIGINT
)
```

---

## 🚨 Compile-Time Safety Examples

### These Compile ✅

```zig
// Correct field names
user.set("email", "test@example.com");
user.set("age", @as(i32, 25));

// Correct field in query
_ = try query.where("email", "=", "test@example.com");
_ = query.orderBy("created_at", .desc);

// Correct relationship types
const UserPosts = typed_orm.HasMany(User, Post, "user_id");
```

### These Don't Compile ❌

```zig
// ❌ Wrong field name
user.set("emai", "test@example.com");
// Error: Field 'emai' not found in User

// ❌ Wrong type
user.set("age", "twenty-five");
// Error: expected i32, found []const u8

// ❌ Wrong query field
_ = try query.where("wrong_field", "=", "value");
// Error: Field 'wrong_field' does not exist in User

// ❌ Wrong order by field
_ = query.orderBy("nonexistent", .asc);
// Error: Field 'nonexistent' does not exist in User
```

---

## 🎯 Advanced Patterns

### Soft Deletes

```zig
const User = struct {
    id: i64 = 0,
    name: []const u8,
    deleted_at: ?i64 = null,
    pub const table = "users";
};

// Soft delete
user.set("deleted_at", std.time.timestamp());
try user.save();

// Query only non-deleted
var query = typed_orm.Query(User).init(allocator, &connection);
_ = try query.where("deleted_at", "=", null);
const active_users = try query.get();
```

### Timestamps

```zig
const User = struct {
    id: i64 = 0,
    name: []const u8,
    created_at: i64 = 0,
    updated_at: i64 = 0,
    pub const table = "users";
};

// On create
user.set("created_at", std.time.timestamp());
user.set("updated_at", std.time.timestamp());
try user.save();

// On update
user.set("updated_at", std.time.timestamp());
try user.save();
```

### Pagination

```zig
fn paginate(
    allocator: std.mem.Allocator,
    connection: _database.Connection,
    page: usize,
    per_page: usize,
) ![]typed_orm.Model(User) {
    var query = typed_orm.Query(User).init(allocator, connection);
    defer query.deinit();

    const offset = (page - 1) _ per_page;

    _ = query.limit(per_page);
    _ = query.offset(offset);
    _ = query.orderBy("created_at", .desc);

    return try query.get();
}

// Usage
const page_1 = try paginate(allocator, &connection, 1, 10);
defer allocator.free(page_1);
```

---

## 📊 Performance Characteristics

### Compile-Time Overhead

- ✅ All type checking at compile time
- ✅ No runtime reflection
- ✅ Zero-cost abstractions

### Runtime Performance

- ✅ Direct struct field access
- ✅ No virtual dispatch
- ✅ Optimized SQL generation
- ✅ Connection pooling ready

### Memory Usage

- ✅ No hidden allocations
- ✅ Explicit lifetime management
- ✅ Arena-friendly patterns
- ✅ Zero-copy where possible

---

## 🆚 Comparison with Other ORMs

### vs TypeORM (TypeScript)

| Feature | Home Typed ORM | TypeORM |
|---------|----------------|---------|
| Type Safety | ✅ Compile-time | ⚠️ Runtime |
| Performance | 🚀 Native | ⚡ Node.js |
| Errors Caught | ✅ Build time | ⚠️ Runtime |
| Runtime Overhead | ✅ None | ❌ Reflection |

### vs Laravel Eloquent (PHP)

| Feature | Home Typed ORM | Eloquent |
|---------|----------------|----------|
| Type Safety | ✅ Compile-time | ❌ None |
| Performance | 🚀 Native | ⚡ PHP |
| API Style | ✅ Similar | ✅ Original |
| Relationships | ✅ Type-safe | ⚠️ Runtime |

### vs Django ORM (Python)

| Feature | Home Typed ORM | Django ORM |
|---------|----------------|------------|
| Type Safety | ✅ Compile-time | ⚠️ Optional |
| Performance | 🚀 Native | ⚡ Python |
| Query Safety | ✅ Compile-time | ⚠️ Runtime |
| Memory Usage | ✅ Low | ❌ High |

---

## ✨ Benefits Summary

### For Developers

- ✅ **Catch errors early** - At compile time, not in production
- ✅ **IDE support** - Full autocomplete and type hints
- ✅ **Refactoring safety** - Rename a field, compiler finds all uses
- ✅ **Less testing** - Type system proves correctness

### For Performance

- ✅ **Zero overhead** - No runtime type checking
- ✅ **Native speed** - Direct memory access
- ✅ **Small binaries** - No reflection metadata
- ✅ **Predictable** - No hidden allocations

### For Maintenance

- ✅ **Self-documenting** - Types are documentation
- ✅ **Refactor-friendly** - Compiler enforces correctness
- ✅ **Less bugs** - Type errors impossible at runtime
- ✅ **Clear contracts** - Function signatures tell the story

---

## 🎉 Conclusion

The Home Typed ORM provides:

✅ **100% type safety** at compile time
✅ **Zero runtime overhead** with direct struct access
✅ **Elegant API** similar to Laravel Eloquent
✅ **Type-safe relationships** validated at compile time
✅ **Comprehensive query builder** with field validation
✅ **Automatic schema generation** from struct definitions

**Result**: Catch all ORM errors at compile time, not in production!

---

_Home Programming Language - Typed ORM_
_Version 1.0.0_
_Generated: 2025-10-24_
