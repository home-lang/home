//! AWS core types and utilities
//!
//! This module re-exports common AWS types from cloud.zig for convenience.
//! Service clients like SQS, S3, etc. import this module to access
//! shared configuration, credentials, and signing functionality.

const cloud = @import("cloud.zig");

// Re-export core AWS types
pub const Region = cloud.Region;
pub const Credentials = cloud.Credentials;
pub const Config = cloud.Config;
pub const Signer = cloud.Signer;
pub const SignedRequest = cloud.SignedRequest;
