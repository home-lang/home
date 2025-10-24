const std = @import("std");
const typed_orm = @import("typed_orm");
const database = @import("database");

/// Example 1: Define a User model with type safety
const User = struct {
    // Primary key with auto-increment
    id: i64 = 0,

    // Required fields
    email: []const u8,
    name: []const u8,
    password: []const u8,

    // Optional fields
    age: ?i32 = null,
    bio: ?[]const u8 = null,

    // Boolean
    is_active: bool = true,

    // Timestamps (would be auto-managed in production)
    created_at: i64 = 0,
    updated_at: i64 = 0,

    // Tell ORM this is the users table
    pub const table = "users";
};

/// Example 2: Define a Post model with relationships
const Post = struct {
    id: i64 = 0,
    user_id: i64,
    title: []const u8,
    content: []const u8,
    published: bool = false,
    view_count: i32 = 0,
    created_at: i64 = 0,
    updated_at: i64 = 0,

    pub const table = "posts";
};

/// Example 3: Define a Comment model
const Comment = struct {
    id: i64 = 0,
    post_id: i64,
    user_id: i64,
    content: []const u8,
    created_at: i64 = 0,

    pub const table = "comments";
};

/// Example 4: Define a Profile model (one-to-one with User)
const Profile = struct {
    id: i64 = 0,
    user_id: i64,
    avatar_url: ?[]const u8 = null,
    website: ?[]const u8 = null,
    location: ?[]const u8 = null,

    pub const table = "profiles";
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Connect to database
    var connection = try database.Connection.open(":memory:");
    defer connection.deinit();

    // ============================================
    // EXAMPLE 1: Create Tables (Compile-Time Type Safety)
    // ============================================

    std.debug.print("\n=== Creating Tables ===\n", .{});

    const UserModel = typed_orm.Model(User);
    const PostModel = typed_orm.Model(Post);
    const CommentModel = typed_orm.Model(Comment);
    const ProfileModel = typed_orm.Model(Profile);

    // Generate CREATE TABLE SQL at compile time!
    const create_users = try UserModel.createTableSQL(allocator);
    defer allocator.free(create_users);
    std.debug.print("SQL: {s}\n", .{create_users});
    try connection.exec(create_users);

    const create_posts = try PostModel.createTableSQL(allocator);
    defer allocator.free(create_posts);
    try connection.exec(create_posts);

    const create_comments = try CommentModel.createTableSQL(allocator);
    defer allocator.free(create_comments);
    try connection.exec(create_comments);

    const create_profiles = try ProfileModel.createTableSQL(allocator);
    defer allocator.free(create_profiles);
    try connection.exec(create_profiles);

    // ============================================
    // EXAMPLE 2: Create Records (Type-Safe)
    // ============================================

    std.debug.print("\n=== Creating Users ===\n", .{});

    // Create a new user - all fields are type-checked at compile time!
    var user1 = UserModel.new(allocator, &connection);
    user1.set("email", "alice@example.com"); // Compile error if wrong type!
    user1.set("name", "Alice Smith");
    user1.set("password", "hashed_password_123");
    user1.set("age", @as(i32, 28)); // Type-safe: must be i32
    user1.set("is_active", true); // Type-safe: must be bool
    user1.set("created_at", std.time.timestamp());

    try user1.save();
    std.debug.print("✅ Created user: {s} (ID: {d})\n", .{ user1.get("name"), user1.get("id") });

    // Create another user
    var user2 = UserModel.init(allocator, &connection, .{
        .id = 0,
        .email = "bob@example.com",
        .name = "Bob Johnson",
        .password = "hashed_password_456",
        .age = 35,
        .bio = "Software developer",
        .is_active = true,
        .created_at = std.time.timestamp(),
        .updated_at = std.time.timestamp(),
    });
    try user2.save();
    std.debug.print("✅ Created user: {s} (ID: {d})\n", .{ user2.get("name"), user2.get("id") });

    // ============================================
    // EXAMPLE 3: Type-Safe Queries
    // ============================================

    std.debug.print("\n=== Type-Safe Queries ===\n", .{});

    // Query builder with compile-time field validation
    var user_query = typed_orm.Query(User).init(allocator, &connection);
    defer user_query.deinit();

    // This compiles: 'email' exists in User
    _ = try user_query.where("email", "=", "alice@example.com");

    // This would be a COMPILE ERROR:
    // _ = try user_query.where("invalid_field", "=", "value");
    // Error: Field 'invalid_field' does not exist in User

    const found_user = try user_query.first();
    if (found_user) |user| {
        std.debug.print("✅ Found user by email: {s}\n", .{user.get("name")});
    }

    // ============================================
    // EXAMPLE 4: Advanced Queries with Type Safety
    // ============================================

    std.debug.print("\n=== Advanced Queries ===\n", .{});

    var active_users_query = typed_orm.Query(User).init(allocator, &connection);
    defer active_users_query.deinit();

    // Chain queries with compile-time field validation
    _ = try active_users_query
        .where("is_active", "=", true)
        .orderBy("created_at", .desc)
        .limit(10);

    const active_users = try active_users_query.get();
    defer allocator.free(active_users);

    std.debug.print("✅ Found {d} active users\n", .{active_users.len});
    for (active_users) |user| {
        std.debug.print("  - {s} ({s})\n", .{ user.get("name"), user.get("email") });
    }

    // ============================================
    // EXAMPLE 5: Update Records (Type-Safe)
    // ============================================

    std.debug.print("\n=== Updating Records ===\n", .{});

    // Update user - all fields type-checked!
    user1.set("age", @as(i32, 29)); // Birthday!
    user1.set("updated_at", std.time.timestamp());
    try user1.save();

    std.debug.print("✅ Updated user age to {d}\n", .{user1.get("age")});

    // ============================================
    // EXAMPLE 6: Create Related Records
    // ============================================

    std.debug.print("\n=== Creating Related Records ===\n", .{});

    // Create posts for user1
    var post1 = PostModel.init(allocator, &connection, .{
        .id = 0,
        .user_id = user1.get("id"),
        .title = "My First Post",
        .content = "This is my first blog post using Home ORM!",
        .published = true,
        .view_count = 0,
        .created_at = std.time.timestamp(),
        .updated_at = std.time.timestamp(),
    });
    try post1.save();
    std.debug.print("✅ Created post: {s}\n", .{post1.get("title")});

    var post2 = PostModel.init(allocator, &connection, .{
        .id = 0,
        .user_id = user1.get("id"),
        .title = "Type-Safe ORM is Amazing",
        .content = "Compile-time type checking prevents so many bugs!",
        .published = true,
        .view_count = 0,
        .created_at = std.time.timestamp(),
        .updated_at = std.time.timestamp(),
    });
    try post2.save();
    std.debug.print("✅ Created post: {s}\n", .{post2.get("title")});

    // Create comment on post1
    var comment1 = CommentModel.init(allocator, &connection, .{
        .id = 0,
        .post_id = post1.get("id"),
        .user_id = user2.get("id"),
        .content = "Great post!",
        .created_at = std.time.timestamp(),
    });
    try comment1.save();
    std.debug.print("✅ Created comment by {s}\n", .{user2.get("name")});

    // Create profile for user1
    var profile1 = ProfileModel.init(allocator, &connection, .{
        .id = 0,
        .user_id = user1.get("id"),
        .avatar_url = "https://example.com/avatar.jpg",
        .website = "https://alice.dev",
        .location = "San Francisco, CA",
    });
    try profile1.save();
    std.debug.print("✅ Created profile for {s}\n", .{user1.get("name")});

    // ============================================
    // EXAMPLE 7: Type-Safe Relationships
    // ============================================

    std.debug.print("\n=== Type-Safe Relationships ===\n", .{});

    // Has-Many: Get all posts for a user
    const UserPosts = typed_orm.HasMany(User, Post, "user_id");
    const user_posts = try UserPosts.get(allocator, &connection, &user1);
    defer allocator.free(user_posts);

    std.debug.print("✅ User '{s}' has {d} posts:\n", .{ user1.get("name"), user_posts.len });
    for (user_posts) |post| {
        std.debug.print("  - {s}\n", .{post.get("title")});
    }

    // Belongs-To: Get the user who wrote a post
    const PostUser = typed_orm.BelongsTo(Post, User, "user_id");
    const post_author = try PostUser.get(allocator, &connection, &post1);

    if (post_author) |author| {
        std.debug.print("✅ Post '{s}' was written by: {s}\n", .{
            post1.get("title"),
            author.get("name"),
        });
    }

    // Has-One: Get profile for user
    const UserProfile = typed_orm.HasOne(User, Profile, "user_id");
    const user_profile = try UserProfile.get(allocator, &connection, &user1);

    if (user_profile) |profile| {
        std.debug.print("✅ User '{s}' profile website: {s}\n", .{
            user1.get("name"),
            profile.get("website") orelse "N/A",
        });
    }

    // Has-Many: Get all comments on a post
    const PostComments = typed_orm.HasMany(Post, Comment, "post_id");
    const post_comments = try PostComments.get(allocator, &connection, &post1);
    defer allocator.free(post_comments);

    std.debug.print("✅ Post '{s}' has {d} comments\n", .{
        post1.get("title"),
        post_comments.len,
    });

    // ============================================
    // EXAMPLE 8: Complex Queries
    // ============================================

    std.debug.print("\n=== Complex Queries ===\n", .{});

    // Find posts by specific user with filters
    var user_posts_query = typed_orm.Query(Post).init(allocator, &connection);
    defer user_posts_query.deinit();

    _ = try user_posts_query
        .where("user_id", "=", user1.get("id"))
        .where("published", "=", true)
        .orderBy("view_count", .desc)
        .limit(5);

    const published_posts = try user_posts_query.get();
    defer allocator.free(published_posts);

    std.debug.print("✅ Found {d} published posts\n", .{published_posts.len});

    // Count total users
    var count_query = typed_orm.Query(User).init(allocator, &connection);
    defer count_query.deinit();

    const total_users = try count_query.count();
    std.debug.print("✅ Total users in database: {d}\n", .{total_users});

    // Check if active users exist
    var exists_query = typed_orm.Query(User).init(allocator, &connection);
    defer exists_query.deinit();

    _ = try exists_query.where("is_active", "=", true);
    const has_active = try exists_query.exists();
    std.debug.print("✅ Has active users: {}\n", .{has_active});

    // ============================================
    // EXAMPLE 9: Find by ID
    // ============================================

    std.debug.print("\n=== Find by ID ===\n", .{});

    const found_by_id = try typed_orm.Query(User).find(allocator, &connection, user1.get("id"));
    if (found_by_id) |user| {
        std.debug.print("✅ Found user by ID: {s}\n", .{user.get("name")});
    }

    // ============================================
    // EXAMPLE 10: Delete Records
    // ============================================

    std.debug.print("\n=== Deleting Records ===\n", .{});

    // Delete a comment
    try comment1.delete();
    std.debug.print("✅ Deleted comment\n", .{});

    // Verify deletion
    var verify_query = typed_orm.Query(Comment).init(allocator, &connection);
    defer verify_query.deinit();

    const comment_count = try verify_query.count();
    std.debug.print("✅ Comments remaining: {d}\n", .{comment_count});

    // ============================================
    // EXAMPLE 11: Demonstrate Compile-Time Safety
    // ============================================

    std.debug.print("\n=== Compile-Time Type Safety ===\n", .{});

    // These all work because types match:
    user1.set("name", "Alice"); // ✅ string
    user1.set("age", @as(i32, 30)); // ✅ i32
    user1.set("is_active", false); // ✅ bool

    // These would cause COMPILE ERRORS:
    // user1.set("age", "thirty"); // ❌ Error: expected i32, found []const u8
    // user1.set("is_active", 1); // ❌ Error: expected bool, found comptime_int
    // user1.set("nonexistent", "value"); // ❌ Error: field not found

    // Query field validation at compile time:
    var safe_query = typed_orm.Query(User).init(allocator, &connection);
    defer safe_query.deinit();

    // ✅ These compile:
    _ = try safe_query.where("email", "=", "test@example.com");
    _ = safe_query.orderBy("created_at", .desc);

    // ❌ These would be COMPILE ERRORS:
    // _ = try safe_query.where("wrong_field", "=", "value");
    // _ = safe_query.orderBy("invalid_column", .asc);

    std.debug.print("✅ All type safety checks passed at compile time!\n", .{});

    std.debug.print("\n=== Example Complete! ===\n", .{});
}
