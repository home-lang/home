// Infrastructure Presets - Pre-configured CloudFormation templates
// Based on ts-cloud preset patterns for common infrastructure configurations

const std = @import("std");
const Allocator = std.mem.Allocator;
const cf = @import("cloudformation.zig");
const resources = @import("resources/resources.zig");
const Builder = cf.Builder;
const CfValue = cf.CfValue;
const Fn = cf.Fn;

// ============================================================================
// Preset Configuration Types
// ============================================================================

/// Common project configuration
pub const ProjectConfig = struct {
    name: []const u8,
    slug: []const u8,
    region: []const u8 = "us-east-1",
    environment: []const u8 = "production",
    domain: ?[]const u8 = null,
};

/// Static website preset options
pub const StaticSiteOptions = struct {
    project: ProjectConfig,
    index_document: []const u8 = "index.html",
    error_document: []const u8 = "error.html",
    enable_cdn: bool = true,
    custom_domain: ?[]const u8 = null,
    certificate_arn: ?[]const u8 = null,
};

/// Serverless API preset options
pub const ServerlessApiOptions = struct {
    project: ProjectConfig,
    runtime: resources.LambdaOptions.Runtime = .nodejs20_x,
    memory_size: u32 = 256,
    timeout: u32 = 30,
    enable_cors: bool = true,
    cors_origins: []const []const u8 = &[_][]const u8{"*"},
    dynamodb_tables: []const TableConfig = &[_]TableConfig{},
    environment_variables: []const EnvVar = &[_]EnvVar{},

    pub const TableConfig = struct {
        name: []const u8,
        partition_key: []const u8,
        sort_key: ?[]const u8 = null,
    };

    pub const EnvVar = struct {
        key: []const u8,
        value: []const u8,
    };
};

/// Full-stack app preset options (ECS + RDS + S3 + CloudFront)
pub const FullStackOptions = struct {
    project: ProjectConfig,
    container_image: []const u8,
    container_port: u16 = 3000,
    cpu: resources.FargateTaskOptions.Cpu = .@"256",
    memory: resources.FargateTaskOptions.Memory = .@"512",
    desired_count: u32 = 2,
    database_engine: resources.RdsOptions.Engine = .postgres,
    database_instance_class: resources.RdsOptions.InstanceClass = .db_t3_micro,
    enable_cdn: bool = true,
    static_bucket: bool = true,
    vpc_cidr: []const u8 = "10.0.0.0/16",
};

/// Microservices preset options
pub const MicroservicesOptions = struct {
    project: ProjectConfig,
    services: []const ServiceConfig = &[_]ServiceConfig{},
    shared_vpc: bool = true,
    enable_service_discovery: bool = true,

    pub const ServiceConfig = struct {
        name: []const u8,
        image: []const u8,
        port: u16 = 80,
        cpu: resources.FargateTaskOptions.Cpu = .@"256",
        memory: resources.FargateTaskOptions.Memory = .@"512",
        desired_count: u32 = 2,
        health_check_path: []const u8 = "/health",
    };
};

// ============================================================================
// Presets
// ============================================================================

pub const Presets = struct {
    /// Create a static website infrastructure
    /// Includes: S3 bucket, CloudFront distribution (optional), Route53 (optional)
    pub fn createStaticSite(allocator: Allocator, options: StaticSiteOptions) !*Builder {
        var builder = try allocator.create(Builder);
        builder.* = Builder.init(allocator, options.project.slug, options.project.environment);

        _ = builder.withDescription("Static website infrastructure");

        try builder.addEnvironmentParameter();
        try builder.addProductionCondition();

        const template = builder.getTemplate();

        // S3 Bucket for website content
        const bucket_id = try builder.logicalId("WebsiteBucket");
        const bucket_result = try resources.Storage.createBucket(allocator, .{
            .website = true,
            .website_index = options.index_document,
            .website_error = options.error_document,
            .public = !options.enable_cdn, // If CDN, bucket is private with OAI
            .cors_enabled = true,
            .block_public_access = options.enable_cdn,
        });
        try template.addResource(bucket_id, bucket_result.bucket);

        // Bucket policy
        if (bucket_result.bucket_policy) |policy| {
            const policy_id = try builder.logicalId("WebsiteBucketPolicy");
            try template.addResource(policy_id, policy);
        }

        // CloudFront distribution
        if (options.enable_cdn) {
            // Origin Access Identity
            const oai_id = try builder.logicalId("CloudFrontOAI");
            var oai_props = std.StringHashMap(CfValue).init(allocator);
            var oai_config = std.StringHashMap(CfValue).init(allocator);
            try oai_config.put("Comment", CfValue.str("OAI for static website"));
            try oai_props.put("CloudFrontOriginAccessIdentityConfig", .{ .object = oai_config });
            try template.addResource(oai_id, .{
                .type = "AWS::CloudFront::CloudFrontOriginAccessIdentity",
                .properties = oai_props,
            });

            // CloudFront distribution
            const dist_id = try builder.logicalId("CloudFrontDistribution");
            var dist_props = std.StringHashMap(CfValue).init(allocator);
            var dist_config = std.StringHashMap(CfValue).init(allocator);

            try dist_config.put("Enabled", CfValue.fromBool(true));
            try dist_config.put("DefaultRootObject", CfValue.str(options.index_document));
            try dist_config.put("HttpVersion", CfValue.str("http2"));
            try dist_config.put("PriceClass", CfValue.str("PriceClass_100"));

            // Origins
            var origin = std.StringHashMap(CfValue).init(allocator);
            try origin.put("Id", CfValue.str("S3Origin"));
            try origin.put("DomainName", Fn.getAtt(bucket_id, "RegionalDomainName"));

            var s3_config = std.StringHashMap(CfValue).init(allocator);
            try s3_config.put("OriginAccessIdentity", .{ .sub = cf.Sub.init("origin-access-identity/cloudfront/${" ++ oai_id ++ "}") });
            try origin.put("S3OriginConfig", .{ .object = s3_config });

            const origins = try allocator.alloc(CfValue, 1);
            origins[0] = .{ .object = origin };
            try dist_config.put("Origins", .{ .array = origins });

            // Default cache behavior
            var cache_behavior = std.StringHashMap(CfValue).init(allocator);
            try cache_behavior.put("TargetOriginId", CfValue.str("S3Origin"));
            try cache_behavior.put("ViewerProtocolPolicy", CfValue.str("redirect-to-https"));
            try cache_behavior.put("CachePolicyId", CfValue.str("658327ea-f89d-4fab-a63d-7e88639e58f6")); // CachingOptimized

            const allowed_methods = try allocator.alloc(CfValue, 2);
            allowed_methods[0] = CfValue.str("GET");
            allowed_methods[1] = CfValue.str("HEAD");
            try cache_behavior.put("AllowedMethods", .{ .array = allowed_methods });

            try dist_config.put("DefaultCacheBehavior", .{ .object = cache_behavior });

            // Custom domain
            if (options.custom_domain) |domain| {
                const aliases = try allocator.alloc(CfValue, 1);
                aliases[0] = CfValue.str(domain);
                try dist_config.put("Aliases", .{ .array = aliases });

                if (options.certificate_arn) |cert_arn| {
                    var viewer_cert = std.StringHashMap(CfValue).init(allocator);
                    try viewer_cert.put("AcmCertificateArn", CfValue.str(cert_arn));
                    try viewer_cert.put("SslSupportMethod", CfValue.str("sni-only"));
                    try viewer_cert.put("MinimumProtocolVersion", CfValue.str("TLSv1.2_2021"));
                    try dist_config.put("ViewerCertificate", .{ .object = viewer_cert });
                }
            }

            try dist_props.put("DistributionConfig", .{ .object = dist_config });
            try template.addResource(dist_id, .{
                .type = "AWS::CloudFront::Distribution",
                .properties = dist_props,
            });

            // Outputs
            try template.addOutput("CloudFrontDomainName", .{
                .description = "CloudFront distribution domain name",
                .value = Fn.getAtt(dist_id, "DomainName"),
            });
            try template.addOutput("CloudFrontDistributionId", .{
                .description = "CloudFront distribution ID",
                .value = Fn.ref(dist_id),
            });
        }

        // Outputs
        try template.addOutput("WebsiteBucketName", .{
            .description = "S3 bucket name for website content",
            .value = Fn.ref(bucket_id),
        });

        if (!options.enable_cdn) {
            try template.addOutput("WebsiteURL", .{
                .description = "Website URL",
                .value = Fn.getAtt(bucket_id, "WebsiteURL"),
            });
        }

        return builder;
    }

    /// Create a serverless API infrastructure
    /// Includes: Lambda function, API Gateway, DynamoDB tables (optional)
    pub fn createServerlessApi(allocator: Allocator, options: ServerlessApiOptions) !*Builder {
        var builder = try allocator.create(Builder);
        builder.* = Builder.init(allocator, options.project.slug, options.project.environment);

        _ = builder.withDescription("Serverless API infrastructure");

        try builder.addEnvironmentParameter();
        try builder.addProductionCondition();

        const template = builder.getTemplate();

        // Lambda execution role
        const role_id = try builder.logicalId("LambdaExecutionRole");
        var role_props = std.StringHashMap(CfValue).init(allocator);
        try role_props.put("RoleName", .{ .sub = cf.Sub.init("${AWS::StackName}-lambda-role") });

        var assume_role_policy = std.StringHashMap(CfValue).init(allocator);
        try assume_role_policy.put("Version", CfValue.str("2012-10-17"));

        var statement = std.StringHashMap(CfValue).init(allocator);
        try statement.put("Effect", CfValue.str("Allow"));

        var principal = std.StringHashMap(CfValue).init(allocator);
        try principal.put("Service", CfValue.str("lambda.amazonaws.com"));
        try statement.put("Principal", .{ .object = principal });
        try statement.put("Action", CfValue.str("sts:AssumeRole"));

        const statements = try allocator.alloc(CfValue, 1);
        statements[0] = .{ .object = statement };
        try assume_role_policy.put("Statement", .{ .array = statements });

        try role_props.put("AssumeRolePolicyDocument", .{ .object = assume_role_policy });

        // Managed policies
        const policies = try allocator.alloc(CfValue, 1);
        policies[0] = CfValue.str("arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole");
        try role_props.put("ManagedPolicyArns", .{ .array = policies });

        try template.addResource(role_id, .{
            .type = "AWS::IAM::Role",
            .properties = role_props,
        });

        // DynamoDB tables
        for (options.dynamodb_tables) |table_config| {
            const table_id = try builder.logicalId(table_config.name);
            const sort_key: ?resources.DynamoDbOptions.KeyAttribute = if (table_config.sort_key) |sk|
                .{ .name = sk, .type = .S }
            else
                null;

            const table = try resources.Database.createDynamoDbTable(allocator, .{
                .table_name = try builder.resourceName(table_config.name),
                .partition_key = .{ .name = table_config.partition_key, .type = .S },
                .sort_key = sort_key,
            });
            try template.addResource(table_id, table);

            try template.addOutput(try std.fmt.allocPrint(allocator, "{s}TableName", .{table_config.name}), .{
                .description = try std.fmt.allocPrint(allocator, "{s} DynamoDB table name", .{table_config.name}),
                .value = Fn.ref(table_id),
            });
        }

        // Lambda function
        const lambda_id = try builder.logicalId("ApiFunction");

        // Build environment variables
        var env_vars = std.ArrayList(resources.LambdaOptions.EnvVar).init(allocator);
        defer env_vars.deinit();

        for (options.environment_variables) |env| {
            try env_vars.append(.{ .key = env.key, .value = env.value });
        }
        try env_vars.append(.{ .key = "ENVIRONMENT", .value = options.project.environment });

        const lambda = try resources.Compute.createLambda(allocator, .{
            .function_name = try builder.resourceName("api"),
            .runtime = options.runtime,
            .handler = "index.handler",
            .memory_size = options.memory_size,
            .timeout = options.timeout,
            .role_ref = role_id,
            .environment = env_vars.items,
            .code_zip_file = "exports.handler = async (event) => { return { statusCode: 200, body: 'Hello from Lambda!' }; };",
        });
        try template.addResource(lambda_id, lambda);

        // HTTP API
        const api_id = try builder.logicalId("HttpApi");
        const cors_config: ?resources.HttpApiOptions.CorsConfig = if (options.enable_cors) .{
            .allow_origins = options.cors_origins,
            .allow_methods = &[_][]const u8{ "GET", "POST", "PUT", "DELETE", "OPTIONS" },
            .allow_headers = &[_][]const u8{ "Content-Type", "Authorization" },
        } else null;

        const http_api = try resources.Network.createHttpApi(allocator, .{
            .name = try builder.resourceName("api"),
            .description = "HTTP API for serverless backend",
            .cors_configuration = cors_config,
        });
        try template.addResource(api_id, http_api);

        // Lambda permission for API Gateway
        const permission_id = try builder.logicalId("LambdaApiPermission");
        var perm_props = std.StringHashMap(CfValue).init(allocator);
        try perm_props.put("FunctionName", Fn.ref(lambda_id));
        try perm_props.put("Action", CfValue.str("lambda:InvokeFunction"));
        try perm_props.put("Principal", CfValue.str("apigateway.amazonaws.com"));
        try perm_props.put("SourceArn", .{ .sub = cf.Sub.init("arn:aws:execute-api:${AWS::Region}:${AWS::AccountId}:${" ++ api_id ++ "}/*") });

        try template.addResource(permission_id, .{
            .type = "AWS::Lambda::Permission",
            .properties = perm_props,
        });

        // API integration
        const integration_id = try builder.logicalId("ApiIntegration");
        var int_props = std.StringHashMap(CfValue).init(allocator);
        try int_props.put("ApiId", Fn.ref(api_id));
        try int_props.put("IntegrationType", CfValue.str("AWS_PROXY"));
        try int_props.put("IntegrationUri", Fn.getAtt(lambda_id, "Arn"));
        try int_props.put("PayloadFormatVersion", CfValue.str("2.0"));

        try template.addResource(integration_id, .{
            .type = "AWS::ApiGatewayV2::Integration",
            .properties = int_props,
        });

        // Default route
        const route_id = try builder.logicalId("DefaultRoute");
        var route_props = std.StringHashMap(CfValue).init(allocator);
        try route_props.put("ApiId", Fn.ref(api_id));
        try route_props.put("RouteKey", CfValue.str("$default"));
        try route_props.put("Target", .{ .sub = cf.Sub.init("integrations/${" ++ integration_id ++ "}") });

        try template.addResource(route_id, .{
            .type = "AWS::ApiGatewayV2::Route",
            .properties = route_props,
        });

        // Stage
        const stage_id = try builder.logicalId("ApiStage");
        var stage_props = std.StringHashMap(CfValue).init(allocator);
        try stage_props.put("ApiId", Fn.ref(api_id));
        try stage_props.put("StageName", CfValue.str("$default"));
        try stage_props.put("AutoDeploy", CfValue.fromBool(true));

        try template.addResource(stage_id, .{
            .type = "AWS::ApiGatewayV2::Stage",
            .properties = stage_props,
        });

        // Outputs
        try template.addOutput("ApiEndpoint", .{
            .description = "HTTP API endpoint URL",
            .value = Fn.getAtt(api_id, "ApiEndpoint"),
        });

        try template.addOutput("LambdaFunctionArn", .{
            .description = "Lambda function ARN",
            .value = Fn.getAtt(lambda_id, "Arn"),
        });

        return builder;
    }

    /// Create a full-stack application infrastructure
    /// Includes: VPC, ECS Fargate, RDS, S3, CloudFront, ALB
    pub fn createFullStackApp(allocator: Allocator, options: FullStackOptions) !*Builder {
        var builder = try allocator.create(Builder);
        builder.* = Builder.init(allocator, options.project.slug, options.project.environment);

        _ = builder.withDescription("Full-stack application infrastructure");

        try builder.addEnvironmentParameter();
        try builder.addProductionCondition();

        const template = builder.getTemplate();

        // VPC
        const vpc_id = try builder.logicalId("VPC");
        const vpc = try resources.Network.createVpc(allocator, .{
            .cidr_block = options.vpc_cidr,
            .tags = &[_]resources.VpcOptions.Tag{
                .{ .key = "Name", .value = try builder.resourceName("vpc") },
            },
        });
        try template.addResource(vpc_id, vpc);

        // Internet Gateway
        const igw_id = try builder.logicalId("InternetGateway");
        const igw = try resources.Network.createInternetGateway(allocator, &[_]resources.VpcOptions.Tag{
            .{ .key = "Name", .value = try builder.resourceName("igw") },
        });
        try template.addResource(igw_id, igw);

        // Gateway attachment
        const attach_id = try builder.logicalId("GatewayAttachment");
        const attachment = try resources.Network.createGatewayAttachment(allocator, vpc_id, igw_id);
        try template.addResource(attach_id, attachment);

        // Public subnets (2 AZs)
        const subnet1_id = try builder.logicalId("PublicSubnet1");
        const subnet1 = try resources.Network.createSubnet(allocator, .{
            .vpc_ref = vpc_id,
            .cidr_block = "10.0.1.0/24",
            .availability_zone = try std.fmt.allocPrint(allocator, "{s}a", .{options.project.region}),
            .map_public_ip_on_launch = true,
            .tags = &[_]resources.SubnetOptions.Tag{
                .{ .key = "Name", .value = try builder.resourceName("public-1") },
            },
        });
        try template.addResource(subnet1_id, subnet1);

        const subnet2_id = try builder.logicalId("PublicSubnet2");
        const subnet2 = try resources.Network.createSubnet(allocator, .{
            .vpc_ref = vpc_id,
            .cidr_block = "10.0.2.0/24",
            .availability_zone = try std.fmt.allocPrint(allocator, "{s}b", .{options.project.region}),
            .map_public_ip_on_launch = true,
            .tags = &[_]resources.SubnetOptions.Tag{
                .{ .key = "Name", .value = try builder.resourceName("public-2") },
            },
        });
        try template.addResource(subnet2_id, subnet2);

        // Private subnets for database
        const db_subnet1_id = try builder.logicalId("PrivateSubnet1");
        const db_subnet1 = try resources.Network.createSubnet(allocator, .{
            .vpc_ref = vpc_id,
            .cidr_block = "10.0.10.0/24",
            .availability_zone = try std.fmt.allocPrint(allocator, "{s}a", .{options.project.region}),
            .tags = &[_]resources.SubnetOptions.Tag{
                .{ .key = "Name", .value = try builder.resourceName("private-1") },
            },
        });
        try template.addResource(db_subnet1_id, db_subnet1);

        const db_subnet2_id = try builder.logicalId("PrivateSubnet2");
        const db_subnet2 = try resources.Network.createSubnet(allocator, .{
            .vpc_ref = vpc_id,
            .cidr_block = "10.0.11.0/24",
            .availability_zone = try std.fmt.allocPrint(allocator, "{s}b", .{options.project.region}),
            .tags = &[_]resources.SubnetOptions.Tag{
                .{ .key = "Name", .value = try builder.resourceName("private-2") },
            },
        });
        try template.addResource(db_subnet2_id, db_subnet2);

        // Route table
        const rt_id = try builder.logicalId("PublicRouteTable");
        const route_table = try resources.Network.createRouteTable(allocator, vpc_id, &[_]resources.VpcOptions.Tag{
            .{ .key = "Name", .value = try builder.resourceName("public-rt") },
        });
        try template.addResource(rt_id, route_table);

        // Default route to internet
        const route_id = try builder.logicalId("DefaultRoute");
        const route = try resources.Network.createRoute(allocator, rt_id, "0.0.0.0/0", igw_id);
        var route_resource = route;
        route_resource.depends_on = &[_][]const u8{attach_id};
        try template.addResource(route_id, route_resource);

        // Route table associations
        const assoc1_id = try builder.logicalId("SubnetRouteTableAssociation1");
        const assoc1 = try resources.Network.createSubnetRouteTableAssociation(allocator, subnet1_id, rt_id);
        try template.addResource(assoc1_id, assoc1);

        const assoc2_id = try builder.logicalId("SubnetRouteTableAssociation2");
        const assoc2 = try resources.Network.createSubnetRouteTableAssociation(allocator, subnet2_id, rt_id);
        try template.addResource(assoc2_id, assoc2);

        // Security Groups
        const alb_sg_id = try builder.logicalId("ALBSecurityGroup");
        const alb_sg = try resources.Network.createWebServerSecurityGroup(allocator, vpc_id, try builder.resourceName("alb-sg"));
        try template.addResource(alb_sg_id, alb_sg);

        const app_sg_id = try builder.logicalId("AppSecurityGroup");
        const app_sg = try resources.Network.createSecurityGroup(allocator, .{
            .group_name = try builder.resourceName("app-sg"),
            .group_description = "Security group for ECS tasks",
            .vpc_ref = vpc_id,
            .ingress_rules = &[_]resources.SecurityGroupOptions.IngressRule{
                .{ .from_port = options.container_port, .to_port = options.container_port, .source_security_group_ref = alb_sg_id, .description = "From ALB" },
            },
        });
        try template.addResource(app_sg_id, app_sg);

        const db_sg_id = try builder.logicalId("DatabaseSecurityGroup");
        const db_port = options.database_engine.defaultPort();
        const db_sg = try resources.Network.createSecurityGroup(allocator, .{
            .group_name = try builder.resourceName("db-sg"),
            .group_description = "Security group for RDS",
            .vpc_ref = vpc_id,
            .ingress_rules = &[_]resources.SecurityGroupOptions.IngressRule{
                .{ .from_port = db_port, .to_port = db_port, .source_security_group_ref = app_sg_id, .description = "From App" },
            },
        });
        try template.addResource(db_sg_id, db_sg);

        // DB Subnet Group
        const db_subnet_group_id = try builder.logicalId("DBSubnetGroup");
        const db_subnet_group = try resources.Database.createSubnetGroup(allocator, .{
            .db_subnet_group_name = try builder.resourceName("db-subnet-group"),
            .db_subnet_group_description = "Database subnet group",
            .subnet_refs = &[_][]const u8{ db_subnet1_id, db_subnet2_id },
        });
        try template.addResource(db_subnet_group_id, db_subnet_group);

        // RDS Instance
        const rds_id = try builder.logicalId("Database");
        const rds = try resources.Database.createRdsInstance(allocator, .{
            .db_instance_identifier = try builder.resourceName("db"),
            .engine = options.database_engine,
            .instance_class = options.database_instance_class,
            .master_username = "admin",
            .master_password = "CHANGE_ME_USE_SECRETS_MANAGER", // Should use Secrets Manager
            .db_subnet_group_ref = db_subnet_group_id,
            .vpc_security_group_refs = &[_][]const u8{db_sg_id},
            .multi_az = std.mem.eql(u8, options.project.environment, "production"),
        });
        try template.addResource(rds_id, rds);

        // ECS Cluster
        const cluster_id = try builder.logicalId("ECSCluster");
        const cluster = try resources.Compute.createEcsCluster(allocator, try builder.resourceName("cluster"));
        try template.addResource(cluster_id, cluster);

        // Task execution role
        const exec_role_id = try builder.logicalId("TaskExecutionRole");
        var exec_role_props = std.StringHashMap(CfValue).init(allocator);
        try exec_role_props.put("RoleName", .{ .sub = cf.Sub.init("${AWS::StackName}-task-execution-role") });

        var assume_policy = std.StringHashMap(CfValue).init(allocator);
        try assume_policy.put("Version", CfValue.str("2012-10-17"));
        var stmt = std.StringHashMap(CfValue).init(allocator);
        try stmt.put("Effect", CfValue.str("Allow"));
        var principal = std.StringHashMap(CfValue).init(allocator);
        try principal.put("Service", CfValue.str("ecs-tasks.amazonaws.com"));
        try stmt.put("Principal", .{ .object = principal });
        try stmt.put("Action", CfValue.str("sts:AssumeRole"));
        const stmts = try allocator.alloc(CfValue, 1);
        stmts[0] = .{ .object = stmt };
        try assume_policy.put("Statement", .{ .array = stmts });
        try exec_role_props.put("AssumeRolePolicyDocument", .{ .object = assume_policy });

        const managed_policies = try allocator.alloc(CfValue, 1);
        managed_policies[0] = CfValue.str("arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy");
        try exec_role_props.put("ManagedPolicyArns", .{ .array = managed_policies });

        try template.addResource(exec_role_id, .{
            .type = "AWS::IAM::Role",
            .properties = exec_role_props,
        });

        // Task Definition
        const task_id = try builder.logicalId("TaskDefinition");
        const task = try resources.Compute.createFargateTask(allocator, .{
            .family = try builder.resourceName("task"),
            .cpu = options.cpu,
            .memory = options.memory,
            .execution_role_ref = exec_role_id,
            .containers = &[_]resources.FargateTaskOptions.ContainerDef{
                .{
                    .name = "app",
                    .image = options.container_image,
                    .port_mappings = &[_]resources.FargateTaskOptions.PortMapping{
                        .{ .container_port = options.container_port },
                    },
                    .log_configuration = .{
                        .log_driver = "awslogs",
                        .options = &[_]resources.FargateTaskOptions.LogConfig.LogOption{
                            .{ .name = "awslogs-group", .value = try std.fmt.allocPrint(allocator, "/ecs/{s}", .{options.project.slug}) },
                            .{ .name = "awslogs-region", .value = options.project.region },
                            .{ .name = "awslogs-stream-prefix", .value = "ecs" },
                        },
                    },
                },
            },
        });
        try template.addResource(task_id, task);

        // ALB
        const alb_id = try builder.logicalId("ApplicationLoadBalancer");
        const alb = try resources.Network.createAlb(allocator, .{
            .name = try builder.resourceName("alb"),
            .subnet_refs = &[_][]const u8{ subnet1_id, subnet2_id },
            .security_group_refs = &[_][]const u8{alb_sg_id},
        });
        try template.addResource(alb_id, alb);

        // Target Group
        const tg_id = try builder.logicalId("TargetGroup");
        const target_group = try resources.Network.createTargetGroup(allocator, .{
            .name = try builder.resourceName("tg"),
            .port = options.container_port,
            .vpc_ref = vpc_id,
            .target_type = .ip,
            .health_check = .{
                .path = "/health",
                .interval = 30,
            },
        });
        try template.addResource(tg_id, target_group);

        // Listener
        const listener_id = try builder.logicalId("Listener");
        const listener = try resources.Network.createListener(allocator, .{
            .load_balancer_ref = alb_id,
            .port = 80,
            .default_target_group_ref = tg_id,
        });
        try template.addResource(listener_id, listener);

        // ECS Service
        const service_id = try builder.logicalId("ECSService");
        var service = try resources.Compute.createEcsService(allocator, .{
            .service_name = try builder.resourceName("service"),
            .cluster_ref = cluster_id,
            .task_definition_ref = task_id,
            .desired_count = options.desired_count,
            .network_configuration = .{
                .subnets = &[_][]const u8{ subnet1_id, subnet2_id },
                .security_groups = &[_][]const u8{app_sg_id},
                .assign_public_ip = true,
            },
            .load_balancers = &[_]resources.EcsServiceOptions.LoadBalancerConfig{
                .{ .container_name = "app", .container_port = options.container_port, .target_group_ref = tg_id },
            },
            .health_check_grace_period = 60,
        });
        service.depends_on = &[_][]const u8{listener_id};
        try template.addResource(service_id, service);

        // CloudWatch Log Group
        const log_group_id = try builder.logicalId("LogGroup");
        var log_props = std.StringHashMap(CfValue).init(allocator);
        try log_props.put("LogGroupName", CfValue.str(try std.fmt.allocPrint(allocator, "/ecs/{s}", .{options.project.slug})));
        try log_props.put("RetentionInDays", CfValue.int(30));
        try template.addResource(log_group_id, .{
            .type = "AWS::Logs::LogGroup",
            .properties = log_props,
        });

        // Static assets bucket
        if (options.static_bucket) {
            const assets_id = try builder.logicalId("AssetsBucket");
            const assets_result = try resources.Storage.createPrivateBucket(allocator, try builder.resourceName("assets"));
            try template.addResource(assets_id, assets_result.bucket);

            try template.addOutput("AssetsBucketName", .{
                .description = "S3 bucket for static assets",
                .value = Fn.ref(assets_id),
            });
        }

        // Outputs
        try template.addOutput("VpcId", .{
            .description = "VPC ID",
            .value = Fn.ref(vpc_id),
        });

        try template.addOutput("ALBDnsName", .{
            .description = "Application Load Balancer DNS name",
            .value = Fn.getAtt(alb_id, "DNSName"),
        });

        try template.addOutput("DatabaseEndpoint", .{
            .description = "RDS endpoint",
            .value = Fn.getAtt(rds_id, "Endpoint.Address"),
        });

        try template.addOutput("ECSClusterArn", .{
            .description = "ECS Cluster ARN",
            .value = Fn.getAtt(cluster_id, "Arn"),
        });

        return builder;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "create static site preset" {
    const allocator = std.testing.allocator;

    const builder = try Presets.createStaticSite(allocator, .{
        .project = .{
            .name = "My Website",
            .slug = "my-website",
        },
        .enable_cdn = true,
    });
    defer allocator.destroy(builder);
    defer builder.deinit();

    const json = try builder.build();
    defer allocator.free(json);

    try std.testing.expect(json.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, json, "AWS::S3::Bucket") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "AWS::CloudFront::Distribution") != null);
}

test "create serverless api preset" {
    const allocator = std.testing.allocator;

    const builder = try Presets.createServerlessApi(allocator, .{
        .project = .{
            .name = "My API",
            .slug = "my-api",
        },
        .dynamodb_tables = &[_]ServerlessApiOptions.TableConfig{
            .{ .name = "users", .partition_key = "userId" },
        },
    });
    defer allocator.destroy(builder);
    defer builder.deinit();

    const json = try builder.build();
    defer allocator.free(json);

    try std.testing.expect(json.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, json, "AWS::Lambda::Function") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "AWS::ApiGatewayV2::Api") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "AWS::DynamoDB::Table") != null);
}
