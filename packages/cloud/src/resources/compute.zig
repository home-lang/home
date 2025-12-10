// Compute Module - EC2, Lambda, ECS CloudFormation Resources
// Provides type-safe compute resource creation for CloudFormation templates

const std = @import("std");
const Allocator = std.mem.Allocator;
const cf = @import("../cloudformation.zig");
const CfValue = cf.CfValue;
const Resource = cf.Resource;
const Fn = cf.Fn;

// ============================================================================
// Lambda Function
// ============================================================================

/// Lambda function configuration options
pub const LambdaOptions = struct {
    function_name: ?[]const u8 = null,
    runtime: Runtime = .nodejs20_x,
    handler: []const u8 = "index.handler",
    memory_size: u32 = 128,
    timeout: u32 = 30,
    description: ?[]const u8 = null,
    environment: []const EnvVar = &[_]EnvVar{},
    role_arn: ?[]const u8 = null,
    role_ref: ?[]const u8 = null, // Logical ID of IAM role
    vpc_config: ?VpcConfig = null,
    reserved_concurrency: ?u32 = null,
    layers: []const []const u8 = &[_][]const u8{},
    code_s3_bucket: ?[]const u8 = null,
    code_s3_key: ?[]const u8 = null,
    code_zip_file: ?[]const u8 = null, // Inline code (for small functions)
    architectures: Architecture = .x86_64,
    tracing: bool = false,
    tags: []const Tag = &[_]Tag{},

    pub const Runtime = enum {
        nodejs18_x,
        nodejs20_x,
        python3_9,
        python3_10,
        python3_11,
        python3_12,
        java17,
        java21,
        dotnet6,
        dotnet8,
        go1_x,
        ruby3_2,
        provided_al2,
        provided_al2023,

        pub fn toString(self: Runtime) []const u8 {
            return switch (self) {
                .nodejs18_x => "nodejs18.x",
                .nodejs20_x => "nodejs20.x",
                .python3_9 => "python3.9",
                .python3_10 => "python3.10",
                .python3_11 => "python3.11",
                .python3_12 => "python3.12",
                .java17 => "java17",
                .java21 => "java21",
                .dotnet6 => "dotnet6",
                .dotnet8 => "dotnet8",
                .go1_x => "go1.x",
                .ruby3_2 => "ruby3.2",
                .provided_al2 => "provided.al2",
                .provided_al2023 => "provided.al2023",
            };
        }
    };

    pub const Architecture = enum {
        x86_64,
        arm64,

        pub fn toString(self: Architecture) []const u8 {
            return switch (self) {
                .x86_64 => "x86_64",
                .arm64 => "arm64",
            };
        }
    };

    pub const EnvVar = struct {
        key: []const u8,
        value: []const u8,
    };

    pub const VpcConfig = struct {
        subnet_ids: []const []const u8,
        security_group_ids: []const []const u8,
    };

    pub const Tag = struct {
        key: []const u8,
        value: []const u8,
    };
};

// ============================================================================
// EC2 Instance
// ============================================================================

/// EC2 instance configuration options
pub const Ec2Options = struct {
    instance_type: InstanceType = .t3_micro,
    ami_id: ?[]const u8 = null,
    ami_ref: ?[]const u8 = null, // Reference to a parameter or mapping
    key_name: ?[]const u8 = null,
    subnet_id: ?[]const u8 = null,
    subnet_ref: ?[]const u8 = null,
    security_group_ids: []const []const u8 = &[_][]const u8{},
    security_group_refs: []const []const u8 = &[_][]const u8{},
    iam_instance_profile: ?[]const u8 = null,
    user_data: ?[]const u8 = null,
    ebs_optimized: bool = false,
    monitoring: bool = false,
    disable_api_termination: bool = false,
    root_volume_size: ?u32 = null,
    root_volume_type: VolumeType = .gp3,
    tags: []const Tag = &[_]Tag{},

    pub const InstanceType = enum {
        t3_micro,
        t3_small,
        t3_medium,
        t3_large,
        t3_xlarge,
        t3_2xlarge,
        m5_large,
        m5_xlarge,
        m5_2xlarge,
        m5_4xlarge,
        c5_large,
        c5_xlarge,
        c5_2xlarge,
        r5_large,
        r5_xlarge,

        pub fn toString(self: InstanceType) []const u8 {
            return switch (self) {
                .t3_micro => "t3.micro",
                .t3_small => "t3.small",
                .t3_medium => "t3.medium",
                .t3_large => "t3.large",
                .t3_xlarge => "t3.xlarge",
                .t3_2xlarge => "t3.2xlarge",
                .m5_large => "m5.large",
                .m5_xlarge => "m5.xlarge",
                .m5_2xlarge => "m5.2xlarge",
                .m5_4xlarge => "m5.4xlarge",
                .c5_large => "c5.large",
                .c5_xlarge => "c5.xlarge",
                .c5_2xlarge => "c5.2xlarge",
                .r5_large => "r5.large",
                .r5_xlarge => "r5.xlarge",
            };
        }
    };

    pub const VolumeType = enum {
        gp2,
        gp3,
        io1,
        io2,
        st1,
        sc1,

        pub fn toString(self: VolumeType) []const u8 {
            return switch (self) {
                .gp2 => "gp2",
                .gp3 => "gp3",
                .io1 => "io1",
                .io2 => "io2",
                .st1 => "st1",
                .sc1 => "sc1",
            };
        }
    };

    pub const Tag = struct {
        key: []const u8,
        value: []const u8,
    };
};

// ============================================================================
// ECS (Fargate)
// ============================================================================

/// ECS Fargate task definition options
pub const FargateTaskOptions = struct {
    family: []const u8,
    cpu: Cpu = .@"256",
    memory: Memory = .@"512",
    execution_role_arn: ?[]const u8 = null,
    execution_role_ref: ?[]const u8 = null,
    task_role_arn: ?[]const u8 = null,
    task_role_ref: ?[]const u8 = null,
    containers: []const ContainerDef = &[_]ContainerDef{},
    volumes: []const Volume = &[_]Volume{},
    tags: []const Tag = &[_]Tag{},

    pub const Cpu = enum {
        @"256",
        @"512",
        @"1024",
        @"2048",
        @"4096",

        pub fn toString(self: Cpu) []const u8 {
            return switch (self) {
                .@"256" => "256",
                .@"512" => "512",
                .@"1024" => "1024",
                .@"2048" => "2048",
                .@"4096" => "4096",
            };
        }
    };

    pub const Memory = enum {
        @"512",
        @"1024",
        @"2048",
        @"4096",
        @"8192",
        @"16384",

        pub fn toString(self: Memory) []const u8 {
            return switch (self) {
                .@"512" => "512",
                .@"1024" => "1024",
                .@"2048" => "2048",
                .@"4096" => "4096",
                .@"8192" => "8192",
                .@"16384" => "16384",
            };
        }
    };

    pub const ContainerDef = struct {
        name: []const u8,
        image: []const u8,
        port_mappings: []const PortMapping = &[_]PortMapping{},
        environment: []const EnvVar = &[_]EnvVar{},
        secrets: []const Secret = &[_]Secret{},
        cpu: ?u32 = null,
        memory: ?u32 = null,
        memory_reservation: ?u32 = null,
        essential: bool = true,
        command: []const []const u8 = &[_][]const u8{},
        entry_point: []const []const u8 = &[_][]const u8{},
        health_check: ?HealthCheck = null,
        log_configuration: ?LogConfig = null,
    };

    pub const PortMapping = struct {
        container_port: u16,
        host_port: ?u16 = null,
        protocol: Protocol = .tcp,

        pub const Protocol = enum {
            tcp,
            udp,

            pub fn toString(self: Protocol) []const u8 {
                return switch (self) {
                    .tcp => "tcp",
                    .udp => "udp",
                };
            }
        };
    };

    pub const EnvVar = struct {
        name: []const u8,
        value: []const u8,
    };

    pub const Secret = struct {
        name: []const u8,
        value_from: []const u8, // ARN of secret or SSM parameter
    };

    pub const HealthCheck = struct {
        command: []const []const u8,
        interval: u32 = 30,
        timeout: u32 = 5,
        retries: u32 = 3,
        start_period: u32 = 0,
    };

    pub const LogConfig = struct {
        log_driver: []const u8 = "awslogs",
        options: []const LogOption = &[_]LogOption{},

        pub const LogOption = struct {
            name: []const u8,
            value: []const u8,
        };
    };

    pub const Volume = struct {
        name: []const u8,
        efs_volume_configuration: ?EfsConfig = null,

        pub const EfsConfig = struct {
            file_system_id: []const u8,
            root_directory: []const u8 = "/",
            transit_encryption: bool = true,
        };
    };

    pub const Tag = struct {
        key: []const u8,
        value: []const u8,
    };
};

/// ECS Service options
pub const EcsServiceOptions = struct {
    service_name: ?[]const u8 = null,
    cluster_arn: ?[]const u8 = null,
    cluster_ref: ?[]const u8 = null,
    task_definition_arn: ?[]const u8 = null,
    task_definition_ref: ?[]const u8 = null,
    desired_count: u32 = 1,
    launch_type: LaunchType = .FARGATE,
    platform_version: []const u8 = "LATEST",
    network_configuration: ?NetworkConfig = null,
    load_balancers: []const LoadBalancerConfig = &[_]LoadBalancerConfig{},
    health_check_grace_period: ?u32 = null,
    enable_ecs_managed_tags: bool = true,
    propagate_tags: PropagateTagsFrom = .SERVICE,
    deployment_configuration: ?DeploymentConfig = null,
    tags: []const Tag = &[_]Tag{},

    pub const LaunchType = enum {
        FARGATE,
        EC2,

        pub fn toString(self: LaunchType) []const u8 {
            return switch (self) {
                .FARGATE => "FARGATE",
                .EC2 => "EC2",
            };
        }
    };

    pub const PropagateTagsFrom = enum {
        SERVICE,
        TASK_DEFINITION,

        pub fn toString(self: PropagateTagsFrom) []const u8 {
            return switch (self) {
                .SERVICE => "SERVICE",
                .TASK_DEFINITION => "TASK_DEFINITION",
            };
        }
    };

    pub const NetworkConfig = struct {
        subnets: []const []const u8,
        security_groups: []const []const u8,
        assign_public_ip: bool = false,
    };

    pub const LoadBalancerConfig = struct {
        container_name: []const u8,
        container_port: u16,
        target_group_arn: ?[]const u8 = null,
        target_group_ref: ?[]const u8 = null,
    };

    pub const DeploymentConfig = struct {
        maximum_percent: u32 = 200,
        minimum_healthy_percent: u32 = 100,
    };

    pub const Tag = struct {
        key: []const u8,
        value: []const u8,
    };
};

// ============================================================================
// Compute Module
// ============================================================================

pub const Compute = struct {
    /// Create a Lambda function resource
    pub fn createLambda(allocator: Allocator, options: LambdaOptions) !Resource {
        var props = std.StringHashMap(CfValue).init(allocator);

        if (options.function_name) |name| {
            try props.put("FunctionName", CfValue.str(name));
        }

        try props.put("Runtime", CfValue.str(options.runtime.toString()));
        try props.put("Handler", CfValue.str(options.handler));
        try props.put("MemorySize", CfValue.int(@intCast(options.memory_size)));
        try props.put("Timeout", CfValue.int(@intCast(options.timeout)));

        // Architectures
        const archs = try allocator.alloc(CfValue, 1);
        archs[0] = CfValue.str(options.architectures.toString());
        try props.put("Architectures", .{ .array = archs });

        if (options.description) |desc| {
            try props.put("Description", CfValue.str(desc));
        }

        // Role
        if (options.role_ref) |role_ref| {
            try props.put("Role", Fn.getAtt(role_ref, "Arn"));
        } else if (options.role_arn) |role_arn| {
            try props.put("Role", CfValue.str(role_arn));
        }

        // Environment variables
        if (options.environment.len > 0) {
            var env_config = std.StringHashMap(CfValue).init(allocator);
            var env_vars = std.StringHashMap(CfValue).init(allocator);

            for (options.environment) |env| {
                try env_vars.put(env.key, CfValue.str(env.value));
            }

            try env_config.put("Variables", .{ .object = env_vars });
            try props.put("Environment", .{ .object = env_config });
        }

        // Code
        var code = std.StringHashMap(CfValue).init(allocator);
        if (options.code_s3_bucket) |bucket| {
            try code.put("S3Bucket", CfValue.str(bucket));
            if (options.code_s3_key) |key| {
                try code.put("S3Key", CfValue.str(key));
            }
        } else if (options.code_zip_file) |zip| {
            try code.put("ZipFile", CfValue.str(zip));
        }
        try props.put("Code", .{ .object = code });

        // VPC Config
        if (options.vpc_config) |vpc| {
            var vpc_obj = std.StringHashMap(CfValue).init(allocator);

            const subnets = try allocator.alloc(CfValue, vpc.subnet_ids.len);
            for (vpc.subnet_ids, 0..) |subnet, i| {
                subnets[i] = CfValue.str(subnet);
            }
            try vpc_obj.put("SubnetIds", .{ .array = subnets });

            const sgs = try allocator.alloc(CfValue, vpc.security_group_ids.len);
            for (vpc.security_group_ids, 0..) |sg, i| {
                sgs[i] = CfValue.str(sg);
            }
            try vpc_obj.put("SecurityGroupIds", .{ .array = sgs });

            try props.put("VpcConfig", .{ .object = vpc_obj });
        }

        // Reserved concurrency
        if (options.reserved_concurrency) |concurrency| {
            try props.put("ReservedConcurrentExecutions", CfValue.int(@intCast(concurrency)));
        }

        // Tracing
        if (options.tracing) {
            var tracing = std.StringHashMap(CfValue).init(allocator);
            try tracing.put("Mode", CfValue.str("Active"));
            try props.put("TracingConfig", .{ .object = tracing });
        }

        // Layers
        if (options.layers.len > 0) {
            const layers = try allocator.alloc(CfValue, options.layers.len);
            for (options.layers, 0..) |layer, i| {
                layers[i] = CfValue.str(layer);
            }
            try props.put("Layers", .{ .array = layers });
        }

        return Resource{
            .type = "AWS::Lambda::Function",
            .properties = props,
        };
    }

    /// Create an EC2 instance resource
    pub fn createEc2Instance(allocator: Allocator, options: Ec2Options) !Resource {
        var props = std.StringHashMap(CfValue).init(allocator);

        try props.put("InstanceType", CfValue.str(options.instance_type.toString()));

        // AMI
        if (options.ami_ref) |ami_ref| {
            try props.put("ImageId", Fn.ref(ami_ref));
        } else if (options.ami_id) |ami_id| {
            try props.put("ImageId", CfValue.str(ami_id));
        }

        if (options.key_name) |key| {
            try props.put("KeyName", CfValue.str(key));
        }

        // Subnet
        if (options.subnet_ref) |subnet_ref| {
            try props.put("SubnetId", Fn.ref(subnet_ref));
        } else if (options.subnet_id) |subnet_id| {
            try props.put("SubnetId", CfValue.str(subnet_id));
        }

        // Security groups
        if (options.security_group_refs.len > 0) {
            const sgs = try allocator.alloc(CfValue, options.security_group_refs.len);
            for (options.security_group_refs, 0..) |sg, i| {
                sgs[i] = Fn.ref(sg);
            }
            try props.put("SecurityGroupIds", .{ .array = sgs });
        } else if (options.security_group_ids.len > 0) {
            const sgs = try allocator.alloc(CfValue, options.security_group_ids.len);
            for (options.security_group_ids, 0..) |sg, i| {
                sgs[i] = CfValue.str(sg);
            }
            try props.put("SecurityGroupIds", .{ .array = sgs });
        }

        if (options.iam_instance_profile) |profile| {
            try props.put("IamInstanceProfile", CfValue.str(profile));
        }

        if (options.user_data) |user_data| {
            // Base64 encode user data
            try props.put("UserData", .{ .sub = cf.Sub.init(user_data) });
        }

        if (options.ebs_optimized) {
            try props.put("EbsOptimized", CfValue.boolean(true));
        }

        if (options.monitoring) {
            try props.put("Monitoring", CfValue.boolean(true));
        }

        if (options.disable_api_termination) {
            try props.put("DisableApiTermination", CfValue.boolean(true));
        }

        // Root volume
        if (options.root_volume_size) |size| {
            var block_devices = std.StringHashMap(CfValue).init(allocator);
            try block_devices.put("DeviceName", CfValue.str("/dev/xvda"));

            var ebs = std.StringHashMap(CfValue).init(allocator);
            try ebs.put("VolumeSize", CfValue.int(@intCast(size)));
            try ebs.put("VolumeType", CfValue.str(options.root_volume_type.toString()));
            try ebs.put("DeleteOnTermination", CfValue.boolean(true));
            try block_devices.put("Ebs", .{ .object = ebs });

            const devices = try allocator.alloc(CfValue, 1);
            devices[0] = .{ .object = block_devices };
            try props.put("BlockDeviceMappings", .{ .array = devices });
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
            .type = "AWS::EC2::Instance",
            .properties = props,
        };
    }

    /// Create an ECS Cluster
    pub fn createEcsCluster(allocator: Allocator, cluster_name: ?[]const u8) !Resource {
        var props = std.StringHashMap(CfValue).init(allocator);

        if (cluster_name) |name| {
            try props.put("ClusterName", CfValue.str(name));
        }

        // Enable Container Insights by default
        var settings = std.StringHashMap(CfValue).init(allocator);
        try settings.put("Name", CfValue.str("containerInsights"));
        try settings.put("Value", CfValue.str("enabled"));
        const cluster_settings = try allocator.alloc(CfValue, 1);
        cluster_settings[0] = .{ .object = settings };
        try props.put("ClusterSettings", .{ .array = cluster_settings });

        return Resource{
            .type = "AWS::ECS::Cluster",
            .properties = props,
        };
    }

    /// Create an ECS Fargate Task Definition
    pub fn createFargateTask(allocator: Allocator, options: FargateTaskOptions) !Resource {
        var props = std.StringHashMap(CfValue).init(allocator);

        try props.put("Family", CfValue.str(options.family));
        try props.put("Cpu", CfValue.str(options.cpu.toString()));
        try props.put("Memory", CfValue.str(options.memory.toString()));
        try props.put("NetworkMode", CfValue.str("awsvpc"));
        try props.put("RequiresCompatibilities", .{ .array = &[_]CfValue{CfValue.str("FARGATE")} });

        // Execution role
        if (options.execution_role_ref) |role_ref| {
            try props.put("ExecutionRoleArn", Fn.getAtt(role_ref, "Arn"));
        } else if (options.execution_role_arn) |role_arn| {
            try props.put("ExecutionRoleArn", CfValue.str(role_arn));
        }

        // Task role
        if (options.task_role_ref) |role_ref| {
            try props.put("TaskRoleArn", Fn.getAtt(role_ref, "Arn"));
        } else if (options.task_role_arn) |role_arn| {
            try props.put("TaskRoleArn", CfValue.str(role_arn));
        }

        // Container definitions
        if (options.containers.len > 0) {
            const containers = try allocator.alloc(CfValue, options.containers.len);
            for (options.containers, 0..) |container, i| {
                var container_obj = std.StringHashMap(CfValue).init(allocator);
                try container_obj.put("Name", CfValue.str(container.name));
                try container_obj.put("Image", CfValue.str(container.image));
                try container_obj.put("Essential", CfValue.boolean(container.essential));

                if (container.cpu) |cpu| {
                    try container_obj.put("Cpu", CfValue.int(@intCast(cpu)));
                }
                if (container.memory) |mem| {
                    try container_obj.put("Memory", CfValue.int(@intCast(mem)));
                }

                // Port mappings
                if (container.port_mappings.len > 0) {
                    const ports = try allocator.alloc(CfValue, container.port_mappings.len);
                    for (container.port_mappings, 0..) |pm, j| {
                        var port_obj = std.StringHashMap(CfValue).init(allocator);
                        try port_obj.put("ContainerPort", CfValue.int(@intCast(pm.container_port)));
                        try port_obj.put("Protocol", CfValue.str(pm.protocol.toString()));
                        ports[j] = .{ .object = port_obj };
                    }
                    try container_obj.put("PortMappings", .{ .array = ports });
                }

                // Environment
                if (container.environment.len > 0) {
                    const envs = try allocator.alloc(CfValue, container.environment.len);
                    for (container.environment, 0..) |env, j| {
                        var env_obj = std.StringHashMap(CfValue).init(allocator);
                        try env_obj.put("Name", CfValue.str(env.name));
                        try env_obj.put("Value", CfValue.str(env.value));
                        envs[j] = .{ .object = env_obj };
                    }
                    try container_obj.put("Environment", .{ .array = envs });
                }

                // Log configuration
                if (container.log_configuration) |log_config| {
                    var log_obj = std.StringHashMap(CfValue).init(allocator);
                    try log_obj.put("LogDriver", CfValue.str(log_config.log_driver));

                    if (log_config.options.len > 0) {
                        var opts = std.StringHashMap(CfValue).init(allocator);
                        for (log_config.options) |opt| {
                            try opts.put(opt.name, CfValue.str(opt.value));
                        }
                        try log_obj.put("Options", .{ .object = opts });
                    }

                    try container_obj.put("LogConfiguration", .{ .object = log_obj });
                }

                containers[i] = .{ .object = container_obj };
            }
            try props.put("ContainerDefinitions", .{ .array = containers });
        }

        return Resource{
            .type = "AWS::ECS::TaskDefinition",
            .properties = props,
        };
    }

    /// Create an ECS Service
    pub fn createEcsService(allocator: Allocator, options: EcsServiceOptions) !Resource {
        var props = std.StringHashMap(CfValue).init(allocator);

        if (options.service_name) |name| {
            try props.put("ServiceName", CfValue.str(name));
        }

        // Cluster
        if (options.cluster_ref) |cluster_ref| {
            try props.put("Cluster", Fn.ref(cluster_ref));
        } else if (options.cluster_arn) |cluster_arn| {
            try props.put("Cluster", CfValue.str(cluster_arn));
        }

        // Task definition
        if (options.task_definition_ref) |task_ref| {
            try props.put("TaskDefinition", Fn.ref(task_ref));
        } else if (options.task_definition_arn) |task_arn| {
            try props.put("TaskDefinition", CfValue.str(task_arn));
        }

        try props.put("DesiredCount", CfValue.int(@intCast(options.desired_count)));
        try props.put("LaunchType", CfValue.str(options.launch_type.toString()));
        try props.put("PlatformVersion", CfValue.str(options.platform_version));
        try props.put("EnableECSManagedTags", CfValue.boolean(options.enable_ecs_managed_tags));
        try props.put("PropagateTags", CfValue.str(options.propagate_tags.toString()));

        // Network configuration
        if (options.network_configuration) |network| {
            var net_config = std.StringHashMap(CfValue).init(allocator);
            var awsvpc = std.StringHashMap(CfValue).init(allocator);

            const subnets = try allocator.alloc(CfValue, network.subnets.len);
            for (network.subnets, 0..) |subnet, i| {
                subnets[i] = CfValue.str(subnet);
            }
            try awsvpc.put("Subnets", .{ .array = subnets });

            const sgs = try allocator.alloc(CfValue, network.security_groups.len);
            for (network.security_groups, 0..) |sg, i| {
                sgs[i] = CfValue.str(sg);
            }
            try awsvpc.put("SecurityGroups", .{ .array = sgs });

            try awsvpc.put("AssignPublicIp", CfValue.str(if (network.assign_public_ip) "ENABLED" else "DISABLED"));

            try net_config.put("AwsvpcConfiguration", .{ .object = awsvpc });
            try props.put("NetworkConfiguration", .{ .object = net_config });
        }

        // Load balancers
        if (options.load_balancers.len > 0) {
            const lbs = try allocator.alloc(CfValue, options.load_balancers.len);
            for (options.load_balancers, 0..) |lb, i| {
                var lb_obj = std.StringHashMap(CfValue).init(allocator);
                try lb_obj.put("ContainerName", CfValue.str(lb.container_name));
                try lb_obj.put("ContainerPort", CfValue.int(@intCast(lb.container_port)));

                if (lb.target_group_ref) |tg_ref| {
                    try lb_obj.put("TargetGroupArn", Fn.ref(tg_ref));
                } else if (lb.target_group_arn) |tg_arn| {
                    try lb_obj.put("TargetGroupArn", CfValue.str(tg_arn));
                }

                lbs[i] = .{ .object = lb_obj };
            }
            try props.put("LoadBalancers", .{ .array = lbs });

            if (options.health_check_grace_period) |grace| {
                try props.put("HealthCheckGracePeriodSeconds", CfValue.int(@intCast(grace)));
            }
        }

        // Deployment configuration
        if (options.deployment_configuration) |deploy| {
            var deploy_config = std.StringHashMap(CfValue).init(allocator);
            try deploy_config.put("MaximumPercent", CfValue.int(@intCast(deploy.maximum_percent)));
            try deploy_config.put("MinimumHealthyPercent", CfValue.int(@intCast(deploy.minimum_healthy_percent)));
            try props.put("DeploymentConfiguration", .{ .object = deploy_config });
        }

        return Resource{
            .type = "AWS::ECS::Service",
            .properties = props,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "create lambda function" {
    const allocator = std.testing.allocator;

    const lambda = try Compute.createLambda(allocator, .{
        .function_name = "my-function",
        .runtime = .nodejs20_x,
        .handler = "index.handler",
        .code_zip_file = "exports.handler = async () => { return 'Hello'; };",
    });

    try std.testing.expectEqualStrings("AWS::Lambda::Function", lambda.type);

    var props = lambda.properties;
    props.deinit();
}

test "create ec2 instance" {
    const allocator = std.testing.allocator;

    const ec2 = try Compute.createEc2Instance(allocator, .{
        .instance_type = .t3_micro,
        .ami_id = "ami-12345678",
    });

    try std.testing.expectEqualStrings("AWS::EC2::Instance", ec2.type);

    var props = ec2.properties;
    props.deinit();
}

test "create ecs cluster" {
    const allocator = std.testing.allocator;

    const cluster = try Compute.createEcsCluster(allocator, "my-cluster");

    try std.testing.expectEqualStrings("AWS::ECS::Cluster", cluster.type);

    var props = cluster.properties;
    props.deinit();
}
