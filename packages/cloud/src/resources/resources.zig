// Resources Module - Re-exports all AWS resource modules
// Provides a single import point for all CloudFormation resource builders

pub const storage = @import("storage.zig");
pub const compute = @import("compute.zig");
pub const database = @import("database.zig");
pub const network = @import("network.zig");

// Convenience re-exports
pub const Storage = storage.Storage;
pub const Compute = compute.Compute;
pub const Database = database.Database;
pub const Network = network.Network;

// Type re-exports for common options
pub const BucketOptions = storage.BucketOptions;
pub const LambdaOptions = compute.LambdaOptions;
pub const Ec2Options = compute.Ec2Options;
pub const FargateTaskOptions = compute.FargateTaskOptions;
pub const EcsServiceOptions = compute.EcsServiceOptions;
pub const RdsOptions = database.RdsOptions;
pub const DynamoDbOptions = database.DynamoDbOptions;
pub const VpcOptions = network.VpcOptions;
pub const SubnetOptions = network.SubnetOptions;
pub const SecurityGroupOptions = network.SecurityGroupOptions;
pub const AlbOptions = network.AlbOptions;
pub const TargetGroupOptions = network.TargetGroupOptions;
pub const HttpApiOptions = network.HttpApiOptions;
