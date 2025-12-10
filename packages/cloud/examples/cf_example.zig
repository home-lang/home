// Example: Generate a CloudFormation template using Home's cloud module
//
// Run with: zig run packages/cloud/examples/cf_example.zig
//
// This demonstrates:
// 1. Creating infrastructure using the type-safe Builder
// 2. Adding S3 buckets, Lambda functions, and other resources
// 3. Generating valid CloudFormation JSON output

const std = @import("std");
const cloud = @import("../src/cloud.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Example 1: Simple S3 bucket
    std.debug.print("\n=== Example 1: Simple S3 Bucket ===\n\n", .{});
    {
        var builder = cloud.Builder.init(allocator, "my-app", "production");
        defer builder.deinit();

        _ = builder.withDescription("Simple S3 bucket infrastructure");

        const template = builder.getTemplate();

        // Create a static website bucket
        const bucket_result = try cloud.Storage.createStaticWebsite(allocator, "my-app-website");
        try template.addResource("WebsiteBucket", bucket_result.bucket);

        if (bucket_result.bucket_policy) |policy| {
            try template.addResource("WebsiteBucketPolicy", policy);
        }

        // Add output
        try template.addOutput("BucketName", .{
            .description = "Name of the S3 bucket",
            .value = cloud.Fn.ref("WebsiteBucket"),
        });

        const json = try builder.build();
        defer allocator.free(json);
        std.debug.print("{s}\n", .{json});
    }

    // Example 2: Serverless API with DynamoDB
    std.debug.print("\n=== Example 2: Serverless API ===\n\n", .{});
    {
        var builder = cloud.Builder.init(allocator, "my-api", "production");
        defer builder.deinit();

        _ = builder.withDescription("Serverless API with DynamoDB backend");
        try builder.addEnvironmentParameter();
        try builder.addProductionCondition();

        const template = builder.getTemplate();

        // DynamoDB table
        const users_table = try cloud.Database.createSimpleTable(allocator, "users", "userId");
        try template.addResource("UsersTable", users_table);

        // Lambda function
        const lambda = try cloud.Compute.createLambda(allocator, .{
            .function_name = "api-handler",
            .runtime = .nodejs20_x,
            .handler = "index.handler",
            .memory_size = 256,
            .timeout = 30,
            .code_zip_file = "exports.handler = async (event) => { return { statusCode: 200, body: 'Hello!' }; };",
        });
        try template.addResource("ApiFunction", lambda);

        // HTTP API
        const api = try cloud.Network.createHttpApi(allocator, .{
            .name = "my-api",
            .cors_configuration = .{
                .allow_origins = &[_][]const u8{"*"},
                .allow_methods = &[_][]const u8{ "GET", "POST" },
            },
        });
        try template.addResource("HttpApi", api);

        // Outputs
        try template.addOutput("TableName", .{
            .description = "DynamoDB table name",
            .value = cloud.Fn.ref("UsersTable"),
        });

        try template.addOutput("FunctionArn", .{
            .description = "Lambda function ARN",
            .value = cloud.Fn.getAtt("ApiFunction", "Arn"),
        });

        const json = try builder.build();
        defer allocator.free(json);
        std.debug.print("{s}\n", .{json});
    }

    // Example 3: Full VPC with subnets and security groups
    std.debug.print("\n=== Example 3: VPC Infrastructure ===\n\n", .{});
    {
        var builder = cloud.Builder.init(allocator, "my-network", "production");
        defer builder.deinit();

        _ = builder.withDescription("VPC with public and private subnets");

        const template = builder.getTemplate();

        // VPC
        const vpc = try cloud.Network.createVpc(allocator, .{
            .cidr_block = "10.0.0.0/16",
            .tags = &[_]cloud.resources.VpcOptions.Tag{
                .{ .key = "Name", .value = "my-vpc" },
            },
        });
        try template.addResource("VPC", vpc);

        // Public subnet
        const public_subnet = try cloud.Network.createSubnet(allocator, .{
            .vpc_ref = "VPC",
            .cidr_block = "10.0.1.0/24",
            .map_public_ip_on_launch = true,
            .tags = &[_]cloud.resources.SubnetOptions.Tag{
                .{ .key = "Name", .value = "public-subnet-1" },
            },
        });
        try template.addResource("PublicSubnet1", public_subnet);

        // Security group
        const sg = try cloud.Network.createWebServerSecurityGroup(allocator, "VPC", "web-sg");
        try template.addResource("WebSecurityGroup", sg);

        // Outputs
        try template.addOutput("VpcId", .{
            .description = "VPC ID",
            .value = cloud.Fn.ref("VPC"),
        });

        try template.addOutput("SubnetId", .{
            .description = "Public subnet ID",
            .value = cloud.Fn.ref("PublicSubnet1"),
        });

        const json = try builder.build();
        defer allocator.free(json);
        std.debug.print("{s}\n", .{json});
    }

    std.debug.print("\n=== All examples completed! ===\n", .{});
    std.debug.print("These templates can be deployed with: aws cloudformation deploy --template-file <file> --stack-name <name>\n\n", .{});
}
