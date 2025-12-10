// Storage Module - S3 Bucket CloudFormation Resources
// Provides type-safe S3 bucket creation for CloudFormation templates

const std = @import("std");
const Allocator = std.mem.Allocator;
const cf = @import("../cloudformation.zig");
const CfValue = cf.CfValue;
const Resource = cf.Resource;
const Fn = cf.Fn;

/// S3 Bucket configuration options
pub const BucketOptions = struct {
    name: ?[]const u8 = null, // If null, CloudFormation generates name
    public: bool = false,
    website: bool = false,
    website_index: []const u8 = "index.html",
    website_error: []const u8 = "error.html",
    versioning: bool = false,
    encryption: bool = true,
    encryption_algorithm: EncryptionAlgorithm = .AES256,
    block_public_access: bool = true,
    cors_enabled: bool = false,
    cors_origins: []const []const u8 = &[_][]const u8{"*"},
    lifecycle_rules: []const LifecycleRule = &[_]LifecycleRule{},
    logging_bucket: ?[]const u8 = null,
    logging_prefix: ?[]const u8 = null,
    replication_bucket: ?[]const u8 = null,
    tags: []const Tag = &[_]Tag{},
    deletion_policy: cf.Resource.DeletionPolicy = .Delete,

    pub const EncryptionAlgorithm = enum {
        AES256,
        aws_kms,

        pub fn toString(self: EncryptionAlgorithm) []const u8 {
            return switch (self) {
                .AES256 => "AES256",
                .aws_kms => "aws:kms",
            };
        }
    };

    pub const Tag = struct {
        key: []const u8,
        value: []const u8,
    };
};

/// S3 Lifecycle Rule configuration
pub const LifecycleRule = struct {
    id: []const u8,
    enabled: bool = true,
    prefix: ?[]const u8 = null,
    expiration_days: ?u32 = null,
    transition_days: ?u32 = null,
    transition_storage_class: StorageClass = .GLACIER,
    noncurrent_expiration_days: ?u32 = null,

    pub const StorageClass = enum {
        GLACIER,
        GLACIER_IR,
        DEEP_ARCHIVE,
        INTELLIGENT_TIERING,
        ONEZONE_IA,
        STANDARD_IA,

        pub fn toString(self: StorageClass) []const u8 {
            return switch (self) {
                .GLACIER => "GLACIER",
                .GLACIER_IR => "GLACIER_IR",
                .DEEP_ARCHIVE => "DEEP_ARCHIVE",
                .INTELLIGENT_TIERING => "INTELLIGENT_TIERING",
                .ONEZONE_IA => "ONEZONE_IA",
                .STANDARD_IA => "STANDARD_IA",
            };
        }
    };
};

/// Storage module for creating S3 resources
pub const Storage = struct {
    /// Create an S3 bucket resource
    pub fn createBucket(allocator: Allocator, options: BucketOptions) !BucketResult {
        var props = std.StringHashMap(CfValue).init(allocator);

        // Bucket name
        if (options.name) |name| {
            try props.put("BucketName", CfValue.str(name));
        }

        // Encryption
        if (options.encryption) {
            var encryption_config = std.StringHashMap(CfValue).init(allocator);

            var rule = std.StringHashMap(CfValue).init(allocator);
            var sse_config = std.StringHashMap(CfValue).init(allocator);
            try sse_config.put("SSEAlgorithm", CfValue.str(options.encryption_algorithm.toString()));
            try rule.put("ServerSideEncryptionByDefault", .{ .object = sse_config });

            const rules = try allocator.alloc(CfValue, 1);
            rules[0] = .{ .object = rule };
            try encryption_config.put("ServerSideEncryptionConfiguration", .{ .array = rules });

            try props.put("BucketEncryption", .{ .object = encryption_config });
        }

        // Versioning
        if (options.versioning) {
            var versioning_config = std.StringHashMap(CfValue).init(allocator);
            try versioning_config.put("Status", CfValue.str("Enabled"));
            try props.put("VersioningConfiguration", .{ .object = versioning_config });
        }

        // Website configuration
        if (options.website) {
            var website_config = std.StringHashMap(CfValue).init(allocator);
            try website_config.put("IndexDocument", CfValue.str(options.website_index));
            try website_config.put("ErrorDocument", CfValue.str(options.website_error));
            try props.put("WebsiteConfiguration", .{ .object = website_config });
        }

        // Public access block
        if (options.block_public_access and !options.public) {
            var public_access = std.StringHashMap(CfValue).init(allocator);
            try public_access.put("BlockPublicAcls", CfValue.boolean(true));
            try public_access.put("BlockPublicPolicy", CfValue.boolean(true));
            try public_access.put("IgnorePublicAcls", CfValue.boolean(true));
            try public_access.put("RestrictPublicBuckets", CfValue.boolean(true));
            try props.put("PublicAccessBlockConfiguration", .{ .object = public_access });
        }

        // CORS configuration
        if (options.cors_enabled) {
            var cors_config = std.StringHashMap(CfValue).init(allocator);
            var cors_rule = std.StringHashMap(CfValue).init(allocator);

            // AllowedOrigins
            const origins = try allocator.alloc(CfValue, options.cors_origins.len);
            for (options.cors_origins, 0..) |origin, i| {
                origins[i] = CfValue.str(origin);
            }
            try cors_rule.put("AllowedOrigins", .{ .array = origins });

            // AllowedMethods
            const methods = try allocator.alloc(CfValue, 4);
            methods[0] = CfValue.str("GET");
            methods[1] = CfValue.str("PUT");
            methods[2] = CfValue.str("POST");
            methods[3] = CfValue.str("DELETE");
            try cors_rule.put("AllowedMethods", .{ .array = methods });

            // AllowedHeaders
            const headers = try allocator.alloc(CfValue, 1);
            headers[0] = CfValue.str("*");
            try cors_rule.put("AllowedHeaders", .{ .array = headers });

            const cors_rules = try allocator.alloc(CfValue, 1);
            cors_rules[0] = .{ .object = cors_rule };
            try cors_config.put("CorsRules", .{ .array = cors_rules });

            try props.put("CorsConfiguration", .{ .object = cors_config });
        }

        // Lifecycle rules
        if (options.lifecycle_rules.len > 0) {
            var lifecycle_config = std.StringHashMap(CfValue).init(allocator);
            const rules = try allocator.alloc(CfValue, options.lifecycle_rules.len);

            for (options.lifecycle_rules, 0..) |rule, i| {
                var rule_obj = std.StringHashMap(CfValue).init(allocator);
                try rule_obj.put("Id", CfValue.str(rule.id));
                try rule_obj.put("Status", CfValue.str(if (rule.enabled) "Enabled" else "Disabled"));

                if (rule.prefix) |prefix| {
                    try rule_obj.put("Prefix", CfValue.str(prefix));
                }

                if (rule.expiration_days) |days| {
                    var expiration = std.StringHashMap(CfValue).init(allocator);
                    try expiration.put("Days", CfValue.int(@intCast(days)));
                    try rule_obj.put("ExpirationInDays", CfValue.int(@intCast(days)));
                }

                if (rule.transition_days) |days| {
                    var transition = std.StringHashMap(CfValue).init(allocator);
                    try transition.put("TransitionInDays", CfValue.int(@intCast(days)));
                    try transition.put("StorageClass", CfValue.str(rule.transition_storage_class.toString()));
                    const transitions = try allocator.alloc(CfValue, 1);
                    transitions[0] = .{ .object = transition };
                    try rule_obj.put("Transitions", .{ .array = transitions });
                }

                rules[i] = .{ .object = rule_obj };
            }

            try lifecycle_config.put("Rules", .{ .array = rules });
            try props.put("LifecycleConfiguration", .{ .object = lifecycle_config });
        }

        // Logging configuration
        if (options.logging_bucket) |log_bucket| {
            var logging_config = std.StringHashMap(CfValue).init(allocator);
            try logging_config.put("DestinationBucketName", Fn.ref(log_bucket));
            if (options.logging_prefix) |prefix| {
                try logging_config.put("LogFilePrefix", CfValue.str(prefix));
            }
            try props.put("LoggingConfiguration", .{ .object = logging_config });
        }

        // Tags
        if (options.tags.len > 0) {
            const tags = try allocator.alloc(CfValue, options.tags.len);
            for (options.tags, 0..) |tag, i| {
                var tag_obj = std.StringHashMap(CfValue).init(allocator);
                try tag_obj.put("Key", CfValue.str(tag.key));
                try tag_obj.put("Value", CfValue.str(tag.value));
                tags[i] = .{ .object = tag_obj };
            }
            try props.put("Tags", .{ .array = tags });
        }

        const bucket = Resource{
            .type = "AWS::S3::Bucket",
            .properties = props,
            .deletion_policy = options.deletion_policy,
        };

        return BucketResult{
            .bucket = bucket,
            .bucket_policy = if (options.public) try createPublicBucketPolicy(allocator) else null,
        };
    }

    /// Create a bucket policy for public read access
    fn createPublicBucketPolicy(allocator: Allocator) !Resource {
        var props = std.StringHashMap(CfValue).init(allocator);

        // This will be linked to the bucket via Ref
        // The actual bucket reference needs to be set by the builder

        var policy_doc = std.StringHashMap(CfValue).init(allocator);
        try policy_doc.put("Version", CfValue.str("2012-10-17"));

        var statement = std.StringHashMap(CfValue).init(allocator);
        try statement.put("Sid", CfValue.str("PublicReadGetObject"));
        try statement.put("Effect", CfValue.str("Allow"));
        try statement.put("Principal", CfValue.str("*"));
        try statement.put("Action", CfValue.str("s3:GetObject"));
        // Resource will be set when attaching to bucket

        const statements = try allocator.alloc(CfValue, 1);
        statements[0] = .{ .object = statement };
        try policy_doc.put("Statement", .{ .array = statements });

        try props.put("PolicyDocument", .{ .object = policy_doc });

        return Resource{
            .type = "AWS::S3::BucketPolicy",
            .properties = props,
        };
    }

    /// Create a static website bucket (convenience method)
    pub fn createStaticWebsite(allocator: Allocator, name: ?[]const u8) !BucketResult {
        return createBucket(allocator, .{
            .name = name,
            .public = true,
            .website = true,
            .cors_enabled = true,
            .block_public_access = false,
        });
    }

    /// Create a private storage bucket with versioning
    pub fn createPrivateBucket(allocator: Allocator, name: ?[]const u8) !BucketResult {
        return createBucket(allocator, .{
            .name = name,
            .versioning = true,
            .encryption = true,
            .block_public_access = true,
        });
    }

    /// Create a backup bucket with lifecycle rules
    pub fn createBackupBucket(allocator: Allocator, name: ?[]const u8, retention_days: u32) !BucketResult {
        const lifecycle_rules = [_]LifecycleRule{
            .{
                .id = "move-to-glacier",
                .enabled = true,
                .transition_days = 30,
                .transition_storage_class = .GLACIER,
            },
            .{
                .id = "delete-old-backups",
                .enabled = true,
                .expiration_days = retention_days,
            },
        };

        return createBucket(allocator, .{
            .name = name,
            .versioning = true,
            .encryption = true,
            .lifecycle_rules = &lifecycle_rules,
            .deletion_policy = .Retain,
        });
    }
};

/// Result of creating a bucket
pub const BucketResult = struct {
    bucket: Resource,
    bucket_policy: ?Resource,
};

// ============================================================================
// Tests
// ============================================================================

test "create basic bucket" {
    const allocator = std.testing.allocator;

    const result = try Storage.createBucket(allocator, .{
        .name = "test-bucket",
        .encryption = true,
    });

    try std.testing.expectEqualStrings("AWS::S3::Bucket", result.bucket.type);
    try std.testing.expect(result.bucket_policy == null);

    // Clean up
    var props = result.bucket.properties;
    props.deinit();
}

test "create static website bucket" {
    const allocator = std.testing.allocator;

    const result = try Storage.createStaticWebsite(allocator, "my-website");

    try std.testing.expectEqualStrings("AWS::S3::Bucket", result.bucket.type);
    try std.testing.expect(result.bucket_policy != null);

    // Clean up
    var props = result.bucket.properties;
    props.deinit();
    if (result.bucket_policy) |*policy| {
        var policy_props = policy.properties;
        policy_props.deinit();
    }
}
