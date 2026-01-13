// Database Module - RDS, DynamoDB CloudFormation Resources
// Provides type-safe database resource creation for CloudFormation templates

const std = @import("std");
const Allocator = std.mem.Allocator;
const cf = @import("../cloudformation.zig");
const CfValue = cf.CfValue;
const Resource = cf.Resource;
const Fn = cf.Fn;

// ============================================================================
// RDS (Relational Database Service)
// ============================================================================

/// RDS instance configuration options
pub const RdsOptions = struct {
    db_instance_identifier: ?[]const u8 = null,
    engine: Engine = .postgres,
    engine_version: ?[]const u8 = null,
    instance_class: InstanceClass = .db_t3_micro,
    allocated_storage: u32 = 20,
    max_allocated_storage: ?u32 = null, // For autoscaling
    storage_type: StorageType = .gp3,
    storage_iops: ?u32 = null, // For io1/io2
    master_username: []const u8 = "admin",
    master_password_ref: ?[]const u8 = null, // Reference to Secrets Manager or SSM
    master_password: ?[]const u8 = null, // Direct password (not recommended)
    db_name: ?[]const u8 = null,
    port: ?u16 = null,
    multi_az: bool = false,
    publicly_accessible: bool = false,
    vpc_security_group_ids: []const []const u8 = &[_][]const u8{},
    vpc_security_group_refs: []const []const u8 = &[_][]const u8{},
    db_subnet_group_name: ?[]const u8 = null,
    db_subnet_group_ref: ?[]const u8 = null,
    backup_retention_period: u32 = 7,
    preferred_backup_window: ?[]const u8 = null,
    preferred_maintenance_window: ?[]const u8 = null,
    auto_minor_version_upgrade: bool = true,
    deletion_protection: bool = false,
    storage_encrypted: bool = true,
    kms_key_id: ?[]const u8 = null,
    performance_insights_enabled: bool = false,
    monitoring_interval: u32 = 0, // 0 = disabled
    monitoring_role_arn: ?[]const u8 = null,
    enable_cloudwatch_logs_exports: []const []const u8 = &[_][]const u8{},
    tags: []const Tag = &[_]Tag{},
    deletion_policy: cf.Resource.DeletionPolicy = .Snapshot,

    pub const Engine = enum {
        postgres,
        mysql,
        mariadb,
        oracle_ee,
        oracle_se2,
        sqlserver_ee,
        sqlserver_se,
        sqlserver_ex,
        sqlserver_web,

        pub fn toString(self: Engine) []const u8 {
            return switch (self) {
                .postgres => "postgres",
                .mysql => "mysql",
                .mariadb => "mariadb",
                .oracle_ee => "oracle-ee",
                .oracle_se2 => "oracle-se2",
                .sqlserver_ee => "sqlserver-ee",
                .sqlserver_se => "sqlserver-se",
                .sqlserver_ex => "sqlserver-ex",
                .sqlserver_web => "sqlserver-web",
            };
        }

        pub fn defaultPort(self: Engine) u16 {
            return switch (self) {
                .postgres => 5432,
                .mysql, .mariadb => 3306,
                .oracle_ee, .oracle_se2 => 1521,
                .sqlserver_ee, .sqlserver_se, .sqlserver_ex, .sqlserver_web => 1433,
            };
        }
    };

    pub const InstanceClass = enum {
        db_t3_micro,
        db_t3_small,
        db_t3_medium,
        db_t3_large,
        db_t3_xlarge,
        db_t3_2xlarge,
        db_m5_large,
        db_m5_xlarge,
        db_m5_2xlarge,
        db_m5_4xlarge,
        db_r5_large,
        db_r5_xlarge,
        db_r5_2xlarge,

        pub fn toString(self: InstanceClass) []const u8 {
            return switch (self) {
                .db_t3_micro => "db.t3.micro",
                .db_t3_small => "db.t3.small",
                .db_t3_medium => "db.t3.medium",
                .db_t3_large => "db.t3.large",
                .db_t3_xlarge => "db.t3.xlarge",
                .db_t3_2xlarge => "db.t3.2xlarge",
                .db_m5_large => "db.m5.large",
                .db_m5_xlarge => "db.m5.xlarge",
                .db_m5_2xlarge => "db.m5.2xlarge",
                .db_m5_4xlarge => "db.m5.4xlarge",
                .db_r5_large => "db.r5.large",
                .db_r5_xlarge => "db.r5.xlarge",
                .db_r5_2xlarge => "db.r5.2xlarge",
            };
        }
    };

    pub const StorageType = enum {
        gp2,
        gp3,
        io1,
        io2,
        standard,

        pub fn toString(self: StorageType) []const u8 {
            return switch (self) {
                .gp2 => "gp2",
                .gp3 => "gp3",
                .io1 => "io1",
                .io2 => "io2",
                .standard => "standard",
            };
        }
    };

    pub const Tag = struct {
        key: []const u8,
        value: []const u8,
    };
};

/// RDS Subnet Group options
pub const SubnetGroupOptions = struct {
    db_subnet_group_name: ?[]const u8 = null,
    db_subnet_group_description: []const u8 = "Database subnet group",
    subnet_ids: []const []const u8 = &[_][]const u8{},
    subnet_refs: []const []const u8 = &[_][]const u8{},
    tags: []const Tag = &[_]Tag{},

    pub const Tag = struct {
        key: []const u8,
        value: []const u8,
    };
};

// ============================================================================
// DynamoDB
// ============================================================================

/// DynamoDB table configuration options
pub const DynamoDbOptions = struct {
    table_name: ?[]const u8 = null,
    partition_key: KeyAttribute,
    sort_key: ?KeyAttribute = null,
    billing_mode: BillingMode = .PAY_PER_REQUEST,
    read_capacity: ?u32 = null, // For PROVISIONED
    write_capacity: ?u32 = null, // For PROVISIONED
    global_secondary_indexes: []const GlobalSecondaryIndex = &[_]GlobalSecondaryIndex{},
    local_secondary_indexes: []const LocalSecondaryIndex = &[_]LocalSecondaryIndex{},
    stream_specification: ?StreamSpec = null,
    ttl_attribute: ?[]const u8 = null,
    point_in_time_recovery: bool = false,
    encryption: EncryptionType = .AWS_OWNED,
    kms_key_arn: ?[]const u8 = null,
    tags: []const Tag = &[_]Tag{},
    deletion_policy: cf.Resource.DeletionPolicy = .Delete,

    pub const KeyAttribute = struct {
        name: []const u8,
        type: AttributeType,

        pub const AttributeType = enum {
            S, // String
            N, // Number
            B, // Binary

            pub fn toString(self: AttributeType) []const u8 {
                return switch (self) {
                    .S => "S",
                    .N => "N",
                    .B => "B",
                };
            }
        };
    };

    pub const BillingMode = enum {
        PAY_PER_REQUEST,
        PROVISIONED,

        pub fn toString(self: BillingMode) []const u8 {
            return switch (self) {
                .PAY_PER_REQUEST => "PAY_PER_REQUEST",
                .PROVISIONED => "PROVISIONED",
            };
        }
    };

    pub const GlobalSecondaryIndex = struct {
        index_name: []const u8,
        partition_key: KeyAttribute,
        sort_key: ?KeyAttribute = null,
        projection_type: ProjectionType = .ALL,
        non_key_attributes: []const []const u8 = &[_][]const u8{},
        read_capacity: ?u32 = null,
        write_capacity: ?u32 = null,

        pub const ProjectionType = enum {
            ALL,
            KEYS_ONLY,
            INCLUDE,

            pub fn toString(self: ProjectionType) []const u8 {
                return switch (self) {
                    .ALL => "ALL",
                    .KEYS_ONLY => "KEYS_ONLY",
                    .INCLUDE => "INCLUDE",
                };
            }
        };
    };

    pub const LocalSecondaryIndex = struct {
        index_name: []const u8,
        sort_key: KeyAttribute,
        projection_type: GlobalSecondaryIndex.ProjectionType = .ALL,
        non_key_attributes: []const []const u8 = &[_][]const u8{},
    };

    pub const StreamSpec = struct {
        stream_view_type: StreamViewType = .NEW_AND_OLD_IMAGES,

        pub const StreamViewType = enum {
            KEYS_ONLY,
            NEW_IMAGE,
            OLD_IMAGE,
            NEW_AND_OLD_IMAGES,

            pub fn toString(self: StreamViewType) []const u8 {
                return switch (self) {
                    .KEYS_ONLY => "KEYS_ONLY",
                    .NEW_IMAGE => "NEW_IMAGE",
                    .OLD_IMAGE => "OLD_IMAGE",
                    .NEW_AND_OLD_IMAGES => "NEW_AND_OLD_IMAGES",
                };
            }
        };
    };

    pub const EncryptionType = enum {
        AWS_OWNED,
        AWS_MANAGED,
        CUSTOMER_MANAGED,

        pub fn toString(self: EncryptionType) []const u8 {
            return switch (self) {
                .AWS_OWNED => "DEFAULT",
                .AWS_MANAGED => "KMS",
                .CUSTOMER_MANAGED => "KMS",
            };
        }
    };

    pub const Tag = struct {
        key: []const u8,
        value: []const u8,
    };
};

// ============================================================================
// Database Module
// ============================================================================

pub const Database = struct {
    /// Create an RDS instance resource
    pub fn createRdsInstance(allocator: Allocator, options: RdsOptions) !Resource {
        var props = std.StringHashMap(CfValue).init(allocator);

        if (options.db_instance_identifier) |id| {
            try props.put("DBInstanceIdentifier", CfValue.str(id));
        }

        try props.put("Engine", CfValue.str(options.engine.toString()));

        if (options.engine_version) |version| {
            try props.put("EngineVersion", CfValue.str(version));
        }

        try props.put("DBInstanceClass", CfValue.str(options.instance_class.toString()));
        try props.put("AllocatedStorage", CfValue.int(@intCast(options.allocated_storage)));
        try props.put("StorageType", CfValue.str(options.storage_type.toString()));

        if (options.max_allocated_storage) |max| {
            try props.put("MaxAllocatedStorage", CfValue.int(@intCast(max)));
        }

        if (options.storage_iops) |iops| {
            try props.put("Iops", CfValue.int(@intCast(iops)));
        }

        try props.put("MasterUsername", CfValue.str(options.master_username));

        // Password handling
        if (options.master_password_ref) |ref| {
            try props.put("MasterUserPassword", .{ .sub = cf.Sub.init(ref) });
        } else if (options.master_password) |pwd| {
            try props.put("MasterUserPassword", CfValue.str(pwd));
        }

        if (options.db_name) |name| {
            try props.put("DBName", CfValue.str(name));
        }

        const port = options.port orelse options.engine.defaultPort();
        try props.put("Port", CfValue.int(@intCast(port)));

        try props.put("MultiAZ", CfValue.fromBool(options.multi_az));
        try props.put("PubliclyAccessible", CfValue.fromBool(options.publicly_accessible));

        // Security groups
        if (options.vpc_security_group_refs.len > 0) {
            const sgs = try allocator.alloc(CfValue, options.vpc_security_group_refs.len);
            for (options.vpc_security_group_refs, 0..) |sg, i| {
                sgs[i] = Fn.ref(sg);
            }
            try props.put("VPCSecurityGroups", .{ .array = sgs });
        } else if (options.vpc_security_group_ids.len > 0) {
            const sgs = try allocator.alloc(CfValue, options.vpc_security_group_ids.len);
            for (options.vpc_security_group_ids, 0..) |sg, i| {
                sgs[i] = CfValue.str(sg);
            }
            try props.put("VPCSecurityGroups", .{ .array = sgs });
        }

        // Subnet group
        if (options.db_subnet_group_ref) |ref| {
            try props.put("DBSubnetGroupName", Fn.ref(ref));
        } else if (options.db_subnet_group_name) |name| {
            try props.put("DBSubnetGroupName", CfValue.str(name));
        }

        try props.put("BackupRetentionPeriod", CfValue.int(@intCast(options.backup_retention_period)));

        if (options.preferred_backup_window) |window| {
            try props.put("PreferredBackupWindow", CfValue.str(window));
        }

        if (options.preferred_maintenance_window) |window| {
            try props.put("PreferredMaintenanceWindow", CfValue.str(window));
        }

        try props.put("AutoMinorVersionUpgrade", CfValue.fromBool(options.auto_minor_version_upgrade));
        try props.put("DeletionProtection", CfValue.fromBool(options.deletion_protection));
        try props.put("StorageEncrypted", CfValue.fromBool(options.storage_encrypted));

        if (options.kms_key_id) |kms| {
            try props.put("KmsKeyId", CfValue.str(kms));
        }

        if (options.performance_insights_enabled) {
            try props.put("EnablePerformanceInsights", CfValue.fromBool(true));
        }

        if (options.monitoring_interval > 0) {
            try props.put("MonitoringInterval", CfValue.int(@intCast(options.monitoring_interval)));
            if (options.monitoring_role_arn) |role| {
                try props.put("MonitoringRoleArn", CfValue.str(role));
            }
        }

        // CloudWatch logs
        if (options.enable_cloudwatch_logs_exports.len > 0) {
            const logs = try allocator.alloc(CfValue, options.enable_cloudwatch_logs_exports.len);
            for (options.enable_cloudwatch_logs_exports, 0..) |log, i| {
                logs[i] = CfValue.str(log);
            }
            try props.put("EnableCloudwatchLogsExports", .{ .array = logs });
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

        return Resource{
            .type = "AWS::RDS::DBInstance",
            .properties = props,
            .deletion_policy = options.deletion_policy,
        };
    }

    /// Create an RDS Subnet Group
    pub fn createSubnetGroup(allocator: Allocator, options: SubnetGroupOptions) !Resource {
        var props = std.StringHashMap(CfValue).init(allocator);

        if (options.db_subnet_group_name) |name| {
            try props.put("DBSubnetGroupName", CfValue.str(name));
        }

        try props.put("DBSubnetGroupDescription", CfValue.str(options.db_subnet_group_description));

        // Subnets
        if (options.subnet_refs.len > 0) {
            const subnets = try allocator.alloc(CfValue, options.subnet_refs.len);
            for (options.subnet_refs, 0..) |subnet, i| {
                subnets[i] = Fn.ref(subnet);
            }
            try props.put("SubnetIds", .{ .array = subnets });
        } else if (options.subnet_ids.len > 0) {
            const subnets = try allocator.alloc(CfValue, options.subnet_ids.len);
            for (options.subnet_ids, 0..) |subnet, i| {
                subnets[i] = CfValue.str(subnet);
            }
            try props.put("SubnetIds", .{ .array = subnets });
        }

        return Resource{
            .type = "AWS::RDS::DBSubnetGroup",
            .properties = props,
        };
    }

    /// Create a DynamoDB table resource
    pub fn createDynamoDbTable(allocator: Allocator, options: DynamoDbOptions) !Resource {
        var props = std.StringHashMap(CfValue).init(allocator);

        if (options.table_name) |name| {
            try props.put("TableName", CfValue.str(name));
        }

        // Key schema
        var key_count: usize = 1;
        if (options.sort_key != null) key_count = 2;

        const key_schema = try allocator.alloc(CfValue, key_count);
        var pk = std.StringHashMap(CfValue).init(allocator);
        try pk.put("AttributeName", CfValue.str(options.partition_key.name));
        try pk.put("KeyType", CfValue.str("HASH"));
        key_schema[0] = .{ .object = pk };

        if (options.sort_key) |sk| {
            var sk_obj = std.StringHashMap(CfValue).init(allocator);
            try sk_obj.put("AttributeName", CfValue.str(sk.name));
            try sk_obj.put("KeyType", CfValue.str("RANGE"));
            key_schema[1] = .{ .object = sk_obj };
        }
        try props.put("KeySchema", .{ .array = key_schema });

        // Attribute definitions
        var attr_count: usize = 1;
        if (options.sort_key != null) attr_count += 1;
        for (options.global_secondary_indexes) |gsi| {
            attr_count += 1;
            if (gsi.sort_key != null) attr_count += 1;
        }
        for (options.local_secondary_indexes) |_| {
            attr_count += 1;
        }

        const attr_defs = try allocator.alloc(CfValue, attr_count);
        var attr_idx: usize = 0;

        // Primary key attributes
        var pk_attr = std.StringHashMap(CfValue).init(allocator);
        try pk_attr.put("AttributeName", CfValue.str(options.partition_key.name));
        try pk_attr.put("AttributeType", CfValue.str(options.partition_key.type.toString()));
        attr_defs[attr_idx] = .{ .object = pk_attr };
        attr_idx += 1;

        if (options.sort_key) |sk| {
            var sk_attr = std.StringHashMap(CfValue).init(allocator);
            try sk_attr.put("AttributeName", CfValue.str(sk.name));
            try sk_attr.put("AttributeType", CfValue.str(sk.type.toString()));
            attr_defs[attr_idx] = .{ .object = sk_attr };
            attr_idx += 1;
        }

        // GSI attributes
        for (options.global_secondary_indexes) |gsi| {
            var gsi_pk_attr = std.StringHashMap(CfValue).init(allocator);
            try gsi_pk_attr.put("AttributeName", CfValue.str(gsi.partition_key.name));
            try gsi_pk_attr.put("AttributeType", CfValue.str(gsi.partition_key.type.toString()));
            attr_defs[attr_idx] = .{ .object = gsi_pk_attr };
            attr_idx += 1;

            if (gsi.sort_key) |sk| {
                var gsi_sk_attr = std.StringHashMap(CfValue).init(allocator);
                try gsi_sk_attr.put("AttributeName", CfValue.str(sk.name));
                try gsi_sk_attr.put("AttributeType", CfValue.str(sk.type.toString()));
                attr_defs[attr_idx] = .{ .object = gsi_sk_attr };
                attr_idx += 1;
            }
        }

        // LSI attributes
        for (options.local_secondary_indexes) |lsi| {
            var lsi_sk_attr = std.StringHashMap(CfValue).init(allocator);
            try lsi_sk_attr.put("AttributeName", CfValue.str(lsi.sort_key.name));
            try lsi_sk_attr.put("AttributeType", CfValue.str(lsi.sort_key.type.toString()));
            attr_defs[attr_idx] = .{ .object = lsi_sk_attr };
            attr_idx += 1;
        }

        try props.put("AttributeDefinitions", .{ .array = attr_defs[0..attr_idx] });

        // Billing mode
        try props.put("BillingMode", CfValue.str(options.billing_mode.toString()));

        if (options.billing_mode == .PROVISIONED) {
            var throughput = std.StringHashMap(CfValue).init(allocator);
            try throughput.put("ReadCapacityUnits", CfValue.int(@intCast(options.read_capacity orelse 5)));
            try throughput.put("WriteCapacityUnits", CfValue.int(@intCast(options.write_capacity orelse 5)));
            try props.put("ProvisionedThroughput", .{ .object = throughput });
        }

        // GSIs
        if (options.global_secondary_indexes.len > 0) {
            const gsis = try allocator.alloc(CfValue, options.global_secondary_indexes.len);
            for (options.global_secondary_indexes, 0..) |gsi, i| {
                var gsi_obj = std.StringHashMap(CfValue).init(allocator);
                try gsi_obj.put("IndexName", CfValue.str(gsi.index_name));

                // Key schema
                var gsi_key_count: usize = 1;
                if (gsi.sort_key != null) gsi_key_count = 2;
                const gsi_keys = try allocator.alloc(CfValue, gsi_key_count);

                var gsi_pk = std.StringHashMap(CfValue).init(allocator);
                try gsi_pk.put("AttributeName", CfValue.str(gsi.partition_key.name));
                try gsi_pk.put("KeyType", CfValue.str("HASH"));
                gsi_keys[0] = .{ .object = gsi_pk };

                if (gsi.sort_key) |sk| {
                    var gsi_sk = std.StringHashMap(CfValue).init(allocator);
                    try gsi_sk.put("AttributeName", CfValue.str(sk.name));
                    try gsi_sk.put("KeyType", CfValue.str("RANGE"));
                    gsi_keys[1] = .{ .object = gsi_sk };
                }
                try gsi_obj.put("KeySchema", .{ .array = gsi_keys });

                // Projection
                var projection = std.StringHashMap(CfValue).init(allocator);
                try projection.put("ProjectionType", CfValue.str(gsi.projection_type.toString()));
                if (gsi.projection_type == .INCLUDE and gsi.non_key_attributes.len > 0) {
                    const attrs = try allocator.alloc(CfValue, gsi.non_key_attributes.len);
                    for (gsi.non_key_attributes, 0..) |attr, j| {
                        attrs[j] = CfValue.str(attr);
                    }
                    try projection.put("NonKeyAttributes", .{ .array = attrs });
                }
                try gsi_obj.put("Projection", .{ .object = projection });

                gsis[i] = .{ .object = gsi_obj };
            }
            try props.put("GlobalSecondaryIndexes", .{ .array = gsis });
        }

        // Stream specification
        if (options.stream_specification) |stream| {
            var stream_spec = std.StringHashMap(CfValue).init(allocator);
            try stream_spec.put("StreamViewType", CfValue.str(stream.stream_view_type.toString()));
            try props.put("StreamSpecification", .{ .object = stream_spec });
        }

        // TTL
        if (options.ttl_attribute) |ttl| {
            var ttl_spec = std.StringHashMap(CfValue).init(allocator);
            try ttl_spec.put("AttributeName", CfValue.str(ttl));
            try ttl_spec.put("Enabled", CfValue.fromBool(true));
            try props.put("TimeToLiveSpecification", .{ .object = ttl_spec });
        }

        // Point in time recovery
        if (options.point_in_time_recovery) {
            var pitr = std.StringHashMap(CfValue).init(allocator);
            try pitr.put("PointInTimeRecoveryEnabled", CfValue.fromBool(true));
            try props.put("PointInTimeRecoverySpecification", .{ .object = pitr });
        }

        // Encryption
        if (options.encryption != .AWS_OWNED) {
            var sse = std.StringHashMap(CfValue).init(allocator);
            try sse.put("SSEEnabled", CfValue.fromBool(true));
            try sse.put("SSEType", CfValue.str(options.encryption.toString()));
            if (options.kms_key_arn) |kms| {
                try sse.put("KMSMasterKeyId", CfValue.str(kms));
            }
            try props.put("SSESpecification", .{ .object = sse });
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

        return Resource{
            .type = "AWS::DynamoDB::Table",
            .properties = props,
            .deletion_policy = options.deletion_policy,
        };
    }

    /// Create a simple DynamoDB table (convenience method)
    pub fn createSimpleTable(allocator: Allocator, table_name: ?[]const u8, partition_key_name: []const u8) !Resource {
        return createDynamoDbTable(allocator, .{
            .table_name = table_name,
            .partition_key = .{
                .name = partition_key_name,
                .type = .S,
            },
        });
    }

    /// Create a PostgreSQL RDS instance (convenience method)
    pub fn createPostgres(allocator: Allocator, identifier: ?[]const u8, instance_class: RdsOptions.InstanceClass) !Resource {
        return createRdsInstance(allocator, .{
            .db_instance_identifier = identifier,
            .engine = .postgres,
            .instance_class = instance_class,
            .storage_encrypted = true,
            .multi_az = false,
        });
    }

    /// Create a MySQL RDS instance (convenience method)
    pub fn createMysql(allocator: Allocator, identifier: ?[]const u8, instance_class: RdsOptions.InstanceClass) !Resource {
        return createRdsInstance(allocator, .{
            .db_instance_identifier = identifier,
            .engine = .mysql,
            .instance_class = instance_class,
            .storage_encrypted = true,
            .multi_az = false,
        });
    }
};

// ============================================================================
// Tests
// ============================================================================

test "create rds postgres instance" {
    const allocator = std.testing.allocator;

    const rds = try Database.createRdsInstance(allocator, .{
        .db_instance_identifier = "my-postgres",
        .engine = .postgres,
        .instance_class = .db_t3_micro,
        .master_username = "admin",
        .master_password = "password123",
    });

    try std.testing.expectEqualStrings("AWS::RDS::DBInstance", rds.type);

    var props = rds.properties;
    props.deinit();
}

test "create dynamodb table" {
    const allocator = std.testing.allocator;

    const table = try Database.createDynamoDbTable(allocator, .{
        .table_name = "my-table",
        .partition_key = .{
            .name = "pk",
            .type = .S,
        },
        .sort_key = .{
            .name = "sk",
            .type = .S,
        },
    });

    try std.testing.expectEqualStrings("AWS::DynamoDB::Table", table.type);

    var props = table.properties;
    props.deinit();
}

test "create simple dynamodb table" {
    const allocator = std.testing.allocator;

    const table = try Database.createSimpleTable(allocator, "users", "userId");

    try std.testing.expectEqualStrings("AWS::DynamoDB::Table", table.type);

    var props = table.properties;
    props.deinit();
}
