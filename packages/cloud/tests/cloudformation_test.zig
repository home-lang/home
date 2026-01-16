// CloudFormation Module Tests
// Run with: zig build test-cloud

const std = @import("std");
const cloud = @import("cloud");

test "create basic template with builder" {
    const allocator = std.testing.allocator;

    var builder = cloud.Builder.init(allocator, "test-app", "production");
    defer builder.deinit();

    _ = builder.withDescription("Test template");
    try builder.addEnvironmentParameter();
    try builder.addProductionCondition();

    const json = try builder.build();
    defer allocator.free(json);

    try std.testing.expect(json.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, json, "AWSTemplateFormatVersion") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "2010-09-09") != null);
}

test "generate logical id" {
    const allocator = std.testing.allocator;

    var builder = cloud.Builder.init(allocator, "my-app", "prod");
    defer builder.deinit();

    const id = try builder.logicalId("bucket");
    defer allocator.free(id);

    try std.testing.expectEqualStrings("MyAppProdBucket", id);
}

test "generate resource name" {
    const allocator = std.testing.allocator;

    var builder = cloud.Builder.init(allocator, "my-app", "prod");
    defer builder.deinit();

    const name = try builder.resourceName("bucket");
    defer allocator.free(name);

    try std.testing.expectEqualStrings("my-app-prod-bucket", name);
}

test "create s3 bucket" {
    const allocator = std.testing.allocator;

    const result = try cloud.Storage.createBucket(allocator, .{
        .name = "test-bucket",
        .encryption = true,
    });

    try std.testing.expectEqualStrings("AWS::S3::Bucket", result.bucket.type);
    try std.testing.expect(result.bucket_policy == null);

    // Clean up nested CfValue structures
    var props = result.bucket.properties;
    var iter = props.iterator();
    while (iter.next()) |entry| {
        var val = entry.value_ptr.*;
        val.deinit(allocator);
    }
    props.deinit();
}

test "create lambda function" {
    const allocator = std.testing.allocator;

    const lambda = try cloud.Compute.createLambda(allocator, .{
        .function_name = "my-function",
        .runtime = .nodejs20_x,
        .handler = "index.handler",
        .code_zip_file = "exports.handler = async () => { return 'Hello'; };",
    });

    try std.testing.expectEqualStrings("AWS::Lambda::Function", lambda.type);

    // Clean up nested CfValue structures
    var props = lambda.properties;
    var iter = props.iterator();
    while (iter.next()) |entry| {
        var val = entry.value_ptr.*;
        val.deinit(allocator);
    }
    props.deinit();
}

test "create dynamodb table" {
    const allocator = std.testing.allocator;

    const table = try cloud.Database.createDynamoDbTable(allocator, .{
        .table_name = "users",
        .partition_key = .{
            .name = "userId",
            .type = .S,
        },
    });

    try std.testing.expectEqualStrings("AWS::DynamoDB::Table", table.type);

    // Clean up nested CfValue structures
    var props = table.properties;
    var iter = props.iterator();
    while (iter.next()) |entry| {
        var val = entry.value_ptr.*;
        val.deinit(allocator);
    }
    props.deinit();
}

test "create vpc" {
    const allocator = std.testing.allocator;

    const vpc = try cloud.Network.createVpc(allocator, .{
        .cidr_block = "10.0.0.0/16",
    });

    try std.testing.expectEqualStrings("AWS::EC2::VPC", vpc.type);

    // Clean up nested CfValue structures
    var props = vpc.properties;
    var iter = props.iterator();
    while (iter.next()) |entry| {
        var val = entry.value_ptr.*;
        val.deinit(allocator);
    }
    props.deinit();
}

test "create security group" {
    const allocator = std.testing.allocator;

    const sg = try cloud.Network.createSecurityGroup(allocator, .{
        .group_name = "my-sg",
        .group_description = "Test security group",
        .ingress_rules = &[_]cloud.resources.SecurityGroupOptions.IngressRule{
            .{ .from_port = 80, .to_port = 80, .cidr_ip = "0.0.0.0/0" },
            .{ .from_port = 443, .to_port = 443, .cidr_ip = "0.0.0.0/0" },
        },
    });

    try std.testing.expectEqualStrings("AWS::EC2::SecurityGroup", sg.type);

    // Clean up nested CfValue structures
    var props = sg.properties;
    var iter = props.iterator();
    while (iter.next()) |entry| {
        var val = entry.value_ptr.*;
        val.deinit(allocator);
    }
    props.deinit();
}

test "CfValue ref serialization" {
    const allocator = std.testing.allocator;

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    var template = cloud.Template.init(allocator);
    defer template.deinit();

    // Add a resource to verify template works
    var props = std.StringHashMap(cloud.CfValue).init(allocator);
    try props.put("BucketName", cloud.CfValue.str("my-bucket"));
    try template.addResource("TestBucket", .{
        .type = "AWS::S3::Bucket",
        .properties = props,
    });

    const json = try template.toJson();
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "AWS::S3::Bucket") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "my-bucket") != null);
}

test "Fn helpers" {
    // Test Fn.ref
    const ref_val = cloud.Fn.ref("MyBucket");
    try std.testing.expect(ref_val.ref.ref.len > 0);

    // Test Fn.getAtt
    const getatt_val = cloud.Fn.getAtt("MyBucket", "Arn");
    try std.testing.expectEqualStrings("MyBucket", getatt_val.get_att.resource);
    try std.testing.expectEqualStrings("Arn", getatt_val.get_att.attribute);

    // Test Fn.sub
    const sub_val = cloud.Fn.sub("arn:aws:s3:::${BucketName}/*");
    try std.testing.expectEqualStrings("arn:aws:s3:::${BucketName}/*", sub_val.sub.template);
}
