// CloudFormation Template Generation for Home
// Generates AWS CloudFormation templates from type-safe Zig definitions
//
// Based on the ts-cloud pattern:
// 1. Define infrastructure as typed structs
// 2. Build CloudFormation resources using module helpers
// 3. Output valid CloudFormation JSON/YAML

const std = @import("std");
const Allocator = std.mem.Allocator;
const cloud = @import("cloud.zig");

// ============================================================================
// CloudFormation Template Types
// ============================================================================

/// CloudFormation intrinsic function references
pub const Ref = struct {
    ref: []const u8,

    pub fn init(logical_id: []const u8) Ref {
        return .{ .ref = logical_id };
    }
};

/// CloudFormation Fn::GetAtt
pub const GetAtt = struct {
    resource: []const u8,
    attribute: []const u8,

    pub fn init(resource: []const u8, attribute: []const u8) GetAtt {
        return .{ .resource = resource, .attribute = attribute };
    }
};

/// CloudFormation Fn::Sub
pub const Sub = struct {
    template: []const u8,
    variables: ?std.StringHashMap(CfValue) = null,

    pub fn init(template: []const u8) Sub {
        return .{ .template = template };
    }

    pub fn withVars(template: []const u8, variables: std.StringHashMap(CfValue)) Sub {
        return .{ .template = template, .variables = variables };
    }
};

/// CloudFormation Fn::Join
pub const Join = struct {
    delimiter: []const u8,
    values: []const CfValue,

    pub fn init(delimiter: []const u8, values: []const CfValue) Join {
        return .{ .delimiter = delimiter, .values = values };
    }
};

/// CloudFormation Fn::If
pub const If = struct {
    condition: []const u8,
    if_true: *const CfValue,
    if_false: *const CfValue,

    pub fn init(condition: []const u8, if_true: *const CfValue, if_false: *const CfValue) If {
        return .{ .condition = condition, .if_true = if_true, .if_false = if_false };
    }
};

/// CloudFormation value that can be a literal or intrinsic function
pub const CfValue = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    array: []const CfValue,
    object: std.StringHashMap(CfValue),
    ref: Ref,
    get_att: GetAtt,
    sub: Sub,
    join: Join,
    cf_if: If,
    null_value,

    pub fn fromString(s: []const u8) CfValue {
        return .{ .string = s };
    }

    pub fn str(s: []const u8) CfValue {
        return .{ .string = s };
    }

    pub fn fromInt(i: i64) CfValue {
        return .{ .integer = i };
    }

    pub fn int(i: i64) CfValue {
        return .{ .integer = i };
    }

    pub fn fromBool(b: bool) CfValue {
        return .{ .boolean = b };
    }

    pub fn refTo(logical_id: []const u8) CfValue {
        return .{ .ref = Ref.init(logical_id) };
    }

    pub fn fromGetAtt(resource: []const u8, attribute: []const u8) CfValue {
        return .{ .get_att = GetAtt.init(resource, attribute) };
    }

    /// Recursively free all allocated memory in this CfValue
    pub fn deinit(self: *CfValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .array => |arr| {
                for (arr) |*item| {
                    var val = item.*;
                    val.deinit(allocator);
                }
                allocator.free(arr);
            },
            .object => |*obj| {
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    var val = entry.value_ptr.*;
                    val.deinit(allocator);
                }
                obj.deinit();
            },
            else => {},
        }
    }
};

/// CloudFormation Parameter definition
pub const Parameter = struct {
    type: ParameterType = .String,
    default: ?CfValue = null,
    description: ?[]const u8 = null,
    allowed_values: ?[]const []const u8 = null,
    min_length: ?u32 = null,
    max_length: ?u32 = null,
    min_value: ?i64 = null,
    max_value: ?i64 = null,
    no_echo: bool = false,
    constraint_description: ?[]const u8 = null,

    pub const ParameterType = enum {
        String,
        Number,
        CommaDelimitedList,
        AWS_EC2_KeyPair_KeyName,
        AWS_EC2_SecurityGroup_Id,
        AWS_EC2_Subnet_Id,
        AWS_EC2_VPC_Id,
        AWS_SSM_Parameter_Value_String,

        pub fn toString(self: ParameterType) []const u8 {
            return switch (self) {
                .String => "String",
                .Number => "Number",
                .CommaDelimitedList => "CommaDelimitedList",
                .AWS_EC2_KeyPair_KeyName => "AWS::EC2::KeyPair::KeyName",
                .AWS_EC2_SecurityGroup_Id => "AWS::EC2::SecurityGroup::Id",
                .AWS_EC2_Subnet_Id => "AWS::EC2::Subnet::Id",
                .AWS_EC2_VPC_Id => "AWS::EC2::VPC::Id",
                .AWS_SSM_Parameter_Value_String => "AWS::SSM::Parameter::Value<String>",
            };
        }
    };
};

/// CloudFormation Output definition
pub const Output = struct {
    description: ?[]const u8 = null,
    value: CfValue,
    export_name: ?[]const u8 = null,
    condition: ?[]const u8 = null,
};

/// CloudFormation Condition definition
pub const Condition = union(enum) {
    equals_cond: struct { left: CfValue, right: CfValue },
    cf_and: []const *const Condition,
    cf_or: []const *const Condition,
    cf_not: *const Condition,

    pub fn equals(left: CfValue, right: CfValue) Condition {
        return .{ .equals_cond = .{ .left = left, .right = right } };
    }
};

/// CloudFormation Resource definition
pub const Resource = struct {
    type: []const u8,
    properties: std.StringHashMap(CfValue),
    depends_on: ?[]const []const u8 = null,
    condition: ?[]const u8 = null,
    deletion_policy: ?DeletionPolicy = null,
    update_replace_policy: ?DeletionPolicy = null,
    metadata: ?std.StringHashMap(CfValue) = null,

    pub const DeletionPolicy = enum {
        Delete,
        Retain,
        Snapshot,

        pub fn toString(self: DeletionPolicy) []const u8 {
            return switch (self) {
                .Delete => "Delete",
                .Retain => "Retain",
                .Snapshot => "Snapshot",
            };
        }
    };
};

/// Complete CloudFormation Template
pub const Template = struct {
    allocator: Allocator,
    aws_template_format_version: []const u8 = "2010-09-09",
    description: ?[]const u8 = null,
    parameters: std.StringHashMap(Parameter),
    mappings: std.StringHashMap(std.StringHashMap(std.StringHashMap([]const u8))),
    conditions: std.StringHashMap(Condition),
    resources: std.StringHashMap(Resource),
    outputs: std.StringHashMap(Output),

    pub fn init(allocator: Allocator) Template {
        return .{
            .allocator = allocator,
            .parameters = std.StringHashMap(Parameter).init(allocator),
            .mappings = std.StringHashMap(std.StringHashMap(std.StringHashMap([]const u8))).init(allocator),
            .conditions = std.StringHashMap(Condition).init(allocator),
            .resources = std.StringHashMap(Resource).init(allocator),
            .outputs = std.StringHashMap(Output).init(allocator),
        };
    }

    pub fn deinit(self: *Template) void {
        self.parameters.deinit();
        self.mappings.deinit();
        self.conditions.deinit();

        var res_iter = self.resources.iterator();
        while (res_iter.next()) |entry| {
            entry.value_ptr.properties.deinit();
            if (entry.value_ptr.metadata) |*meta| {
                meta.deinit();
            }
        }
        self.resources.deinit();

        self.outputs.deinit();
    }

    pub fn addParameter(self: *Template, name: []const u8, param: Parameter) !void {
        try self.parameters.put(name, param);
    }

    pub fn addCondition(self: *Template, name: []const u8, condition: Condition) !void {
        try self.conditions.put(name, condition);
    }

    pub fn addResource(self: *Template, logical_id: []const u8, resource: Resource) !void {
        try self.resources.put(logical_id, resource);
    }

    pub fn addOutput(self: *Template, name: []const u8, output: Output) !void {
        try self.outputs.put(name, output);
    }

    /// Generate JSON representation of the CloudFormation template
    pub fn toJson(self: *const Template) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();
        const writer = &aw.writer;

        try writer.writeAll("{\n");
        try writer.writeAll("  \"AWSTemplateFormatVersion\": \"");
        try writer.writeAll(self.aws_template_format_version);
        try writer.writeAll("\"");

        if (self.description) |desc| {
            try writer.writeAll(",\n  \"Description\": \"");
            try writer.writeAll(desc);
            try writer.writeAll("\"");
        }

        // Parameters
        if (self.parameters.count() > 0) {
            try writer.writeAll(",\n  \"Parameters\": {\n");
            var first = true;
            var param_iter = self.parameters.iterator();
            while (param_iter.next()) |entry| {
                if (!first) try writer.writeAll(",\n");
                first = false;
                try self.writeParameter(writer, entry.key_ptr.*, entry.value_ptr.*);
            }
            try writer.writeAll("\n  }");
        }

        // Conditions
        if (self.conditions.count() > 0) {
            try writer.writeAll(",\n  \"Conditions\": {\n");
            var first = true;
            var cond_iter = self.conditions.iterator();
            while (cond_iter.next()) |entry| {
                if (!first) try writer.writeAll(",\n");
                first = false;
                try self.writeCondition(writer, entry.key_ptr.*, entry.value_ptr.*);
            }
            try writer.writeAll("\n  }");
        }

        // Resources
        if (self.resources.count() > 0) {
            try writer.writeAll(",\n  \"Resources\": {\n");
            var first = true;
            var res_iter = self.resources.iterator();
            while (res_iter.next()) |entry| {
                if (!first) try writer.writeAll(",\n");
                first = false;
                try self.writeResource(writer, entry.key_ptr.*, entry.value_ptr.*);
            }
            try writer.writeAll("\n  }");
        }

        // Outputs
        if (self.outputs.count() > 0) {
            try writer.writeAll(",\n  \"Outputs\": {\n");
            var first = true;
            var out_iter = self.outputs.iterator();
            while (out_iter.next()) |entry| {
                if (!first) try writer.writeAll(",\n");
                first = false;
                try self.writeOutput(writer, entry.key_ptr.*, entry.value_ptr.*);
            }
            try writer.writeAll("\n  }");
        }

        try writer.writeAll("\n}\n");
        return try aw.toOwnedSlice();
    }

    fn writeParameter(self: *const Template, writer: anytype, name: []const u8, param: Parameter) !void {
        _ = self;
        try writer.writeAll("    \"");
        try writer.writeAll(name);
        try writer.writeAll("\": {\n      \"Type\": \"");
        try writer.writeAll(param.type.toString());
        try writer.writeAll("\"");

        if (param.description) |desc| {
            try writer.writeAll(",\n      \"Description\": \"");
            try writer.writeAll(desc);
            try writer.writeAll("\"");
        }

        if (param.default) |def| {
            try writer.writeAll(",\n      \"Default\": ");
            try writeValue(writer, def, 6);
        }

        if (param.no_echo) {
            try writer.writeAll(",\n      \"NoEcho\": true");
        }

        try writer.writeAll("\n    }");
    }

    fn writeCondition(self: *const Template, writer: anytype, name: []const u8, condition: Condition) !void {
        try writer.writeAll("    \"");
        try writer.writeAll(name);
        try writer.writeAll("\": ");

        switch (condition) {
            .equals_cond => |eq| {
                try writer.writeAll("{\"Fn::Equals\": [");
                try writeValue(writer, eq.left, 0);
                try writer.writeAll(", ");
                try writeValue(writer, eq.right, 0);
                try writer.writeAll("]}");
            },
            .cf_not => |cond| {
                try writer.writeAll("{\"Fn::Not\": [");
                try self.writeConditionValue(writer, cond.*);
                try writer.writeAll("]}");
            },
            .cf_and, .cf_or => {
                // TODO: Implement AND/OR conditions
                try writer.writeAll("{}");
            },
        }
    }

    fn writeConditionValue(self: *const Template, writer: anytype, condition: Condition) !void {
        switch (condition) {
            .equals_cond => |eq| {
                try writer.writeAll("{\"Fn::Equals\": [");
                try writeValue(writer, eq.left, 0);
                try writer.writeAll(", ");
                try writeValue(writer, eq.right, 0);
                try writer.writeAll("]}");
            },
            .cf_not => |cond| {
                try writer.writeAll("{\"Fn::Not\": [");
                try self.writeConditionValue(writer, cond.*);
                try writer.writeAll("]}");
            },
            .cf_and, .cf_or => {
                try writer.writeAll("{}");
            },
        }
    }

    fn writeResource(self: *const Template, writer: anytype, logical_id: []const u8, resource: Resource) !void {
        _ = self;
        try writer.writeAll("    \"");
        try writer.writeAll(logical_id);
        try writer.writeAll("\": {\n      \"Type\": \"");
        try writer.writeAll(resource.type);
        try writer.writeAll("\"");

        if (resource.condition) |cond| {
            try writer.writeAll(",\n      \"Condition\": \"");
            try writer.writeAll(cond);
            try writer.writeAll("\"");
        }

        if (resource.deletion_policy) |policy| {
            try writer.writeAll(",\n      \"DeletionPolicy\": \"");
            try writer.writeAll(policy.toString());
            try writer.writeAll("\"");
        }

        if (resource.depends_on) |deps| {
            try writer.writeAll(",\n      \"DependsOn\": [");
            for (deps, 0..) |dep, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.writeAll("\"");
                try writer.writeAll(dep);
                try writer.writeAll("\"");
            }
            try writer.writeAll("]");
        }

        if (resource.properties.count() > 0) {
            try writer.writeAll(",\n      \"Properties\": {\n");
            var first = true;
            var prop_iter = resource.properties.iterator();
            while (prop_iter.next()) |entry| {
                if (!first) try writer.writeAll(",\n");
                first = false;
                try writer.writeAll("        \"");
                try writer.writeAll(entry.key_ptr.*);
                try writer.writeAll("\": ");
                try writeValue(writer, entry.value_ptr.*, 8);
            }
            try writer.writeAll("\n      }");
        }

        try writer.writeAll("\n    }");
    }

    fn writeOutput(self: *const Template, writer: anytype, name: []const u8, output: Output) !void {
        _ = self;
        try writer.writeAll("    \"");
        try writer.writeAll(name);
        try writer.writeAll("\": {\n");

        if (output.description) |desc| {
            try writer.writeAll("      \"Description\": \"");
            try writer.writeAll(desc);
            try writer.writeAll("\",\n");
        }

        try writer.writeAll("      \"Value\": ");
        try writeValue(writer, output.value, 6);

        if (output.export_name) |export_name| {
            try writer.writeAll(",\n      \"Export\": {\"Name\": \"");
            try writer.writeAll(export_name);
            try writer.writeAll("\"}");
        }

        if (output.condition) |cond| {
            try writer.writeAll(",\n      \"Condition\": \"");
            try writer.writeAll(cond);
            try writer.writeAll("\"");
        }

        try writer.writeAll("\n    }");
    }
};

fn writeValue(writer: anytype, value: CfValue, indent: usize) !void {
    _ = indent;
    switch (value) {
        .string => |s| {
            try writer.writeAll("\"");
            // Escape special characters
            for (s) |c| {
                switch (c) {
                    '"' => try writer.writeAll("\\\""),
                    '\\' => try writer.writeAll("\\\\"),
                    '\n' => try writer.writeAll("\\n"),
                    '\r' => try writer.writeAll("\\r"),
                    '\t' => try writer.writeAll("\\t"),
                    else => try writer.writeByte(c),
                }
            }
            try writer.writeAll("\"");
        },
        .integer => |i| {
            try writer.print("{d}", .{i});
        },
        .float => |f| {
            try writer.print("{d}", .{f});
        },
        .boolean => |b| {
            try writer.writeAll(if (b) "true" else "false");
        },
        .array => |arr| {
            try writer.writeAll("[");
            for (arr, 0..) |item, idx| {
                if (idx > 0) try writer.writeAll(", ");
                try writeValue(writer, item, 0);
            }
            try writer.writeAll("]");
        },
        .object => |obj| {
            try writer.writeAll("{");
            var first = true;
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                if (!first) try writer.writeAll(", ");
                first = false;
                try writer.writeAll("\"");
                try writer.writeAll(entry.key_ptr.*);
                try writer.writeAll("\": ");
                try writeValue(writer, entry.value_ptr.*, 0);
            }
            try writer.writeAll("}");
        },
        .ref => |r| {
            try writer.writeAll("{\"Ref\": \"");
            try writer.writeAll(r.ref);
            try writer.writeAll("\"}");
        },
        .get_att => |ga| {
            try writer.writeAll("{\"Fn::GetAtt\": [\"");
            try writer.writeAll(ga.resource);
            try writer.writeAll("\", \"");
            try writer.writeAll(ga.attribute);
            try writer.writeAll("\"]}");
        },
        .sub => |s| {
            try writer.writeAll("{\"Fn::Sub\": \"");
            try writer.writeAll(s.template);
            try writer.writeAll("\"}");
        },
        .join => |j| {
            try writer.writeAll("{\"Fn::Join\": [\"");
            try writer.writeAll(j.delimiter);
            try writer.writeAll("\", [");
            for (j.values, 0..) |v, idx| {
                if (idx > 0) try writer.writeAll(", ");
                try writeValue(writer, v, 0);
            }
            try writer.writeAll("]]}");
        },
        .cf_if => |i| {
            try writer.writeAll("{\"Fn::If\": [\"");
            try writer.writeAll(i.condition);
            try writer.writeAll("\", ");
            try writeValue(writer, i.if_true.*, 0);
            try writer.writeAll(", ");
            try writeValue(writer, i.if_false.*, 0);
            try writer.writeAll("]}");
        },
        .null_value => {
            try writer.writeAll("null");
        },
    }
}

// ============================================================================
// CloudFormation Builder
// ============================================================================

/// Builder for constructing CloudFormation templates
pub const Builder = struct {
    allocator: Allocator,
    template: Template,
    project_name: []const u8,
    environment: []const u8,

    pub fn init(allocator: Allocator, project_name: []const u8, environment: []const u8) Builder {
        var template = Template.init(allocator);
        template.description = "Generated by Home CloudFormation Builder";

        return .{
            .allocator = allocator,
            .template = template,
            .project_name = project_name,
            .environment = environment,
        };
    }

    pub fn deinit(self: *Builder) void {
        self.template.deinit();
    }

    pub fn withDescription(self: *Builder, description: []const u8) *Builder {
        self.template.description = description;
        return self;
    }

    /// Generate a logical ID from a resource name
    pub fn logicalId(self: *Builder, suffix: []const u8) ![]const u8 {
        // Convert to PascalCase and remove invalid characters
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();
        const writer = &aw.writer;

        // Add project name
        var cap_next = true;
        for (self.project_name) |c| {
            if (c == '-' or c == '_' or c == ' ') {
                cap_next = true;
            } else if (cap_next) {
                try writer.writeByte(std.ascii.toUpper(c));
                cap_next = false;
            } else {
                try writer.writeByte(c);
            }
        }

        // Add environment
        cap_next = true;
        for (self.environment) |c| {
            if (c == '-' or c == '_' or c == ' ') {
                cap_next = true;
            } else if (cap_next) {
                try writer.writeByte(std.ascii.toUpper(c));
                cap_next = false;
            } else {
                try writer.writeByte(c);
            }
        }

        // Add suffix
        cap_next = true;
        for (suffix) |c| {
            if (c == '-' or c == '_' or c == ' ') {
                cap_next = true;
            } else if (cap_next) {
                try writer.writeByte(std.ascii.toUpper(c));
                cap_next = false;
            } else {
                try writer.writeByte(c);
            }
        }

        return try aw.toOwnedSlice();
    }

    /// Generate a resource name with project/environment prefix
    pub fn resourceName(self: *Builder, suffix: []const u8) ![]const u8 {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();
        try aw.writer.print("{s}-{s}-{s}", .{ self.project_name, self.environment, suffix });
        return try aw.toOwnedSlice();
    }

    /// Add standard environment parameter
    pub fn addEnvironmentParameter(self: *Builder) !void {
        try self.template.addParameter("Environment", .{
            .type = .String,
            .default = .{ .string = self.environment },
            .description = "Deployment environment",
            .allowed_values = &[_][]const u8{ "development", "staging", "production" },
        });
    }

    /// Add IsProduction condition
    pub fn addProductionCondition(self: *Builder) !void {
        try self.template.addCondition("IsProduction", Condition.equals(
            CfValue.refTo("Environment"),
            CfValue.str("production"),
        ));
    }

    /// Build and return the template JSON
    pub fn build(self: *Builder) ![]u8 {
        return self.template.toJson();
    }

    /// Get direct access to the template for advanced modifications
    pub fn getTemplate(self: *Builder) *Template {
        return &self.template;
    }
};

// ============================================================================
// Intrinsic Function Helpers (Fn namespace like ts-cloud)
// ============================================================================

pub const Fn = struct {
    /// Create a Ref to another resource
    pub fn ref(logical_id: []const u8) CfValue {
        return CfValue.refTo(logical_id);
    }

    /// Get an attribute from a resource
    pub fn getAtt(resource: []const u8, attribute: []const u8) CfValue {
        return CfValue.fromGetAtt(resource, attribute);
    }

    /// String substitution
    pub fn sub(template: []const u8) CfValue {
        return .{ .sub = Sub.init(template) };
    }

    /// Join strings with delimiter
    pub fn join(allocator: Allocator, delimiter: []const u8, values: []const CfValue) !CfValue {
        const owned_values = try allocator.dupe(CfValue, values);
        return .{ .join = Join.init(delimiter, owned_values) };
    }

    /// Conditional value
    pub fn ifCond(allocator: Allocator, condition: []const u8, if_true: CfValue, if_false: CfValue) !CfValue {
        const true_ptr = try allocator.create(CfValue);
        true_ptr.* = if_true;
        const false_ptr = try allocator.create(CfValue);
        false_ptr.* = if_false;
        return .{ .cf_if = If.init(condition, true_ptr, false_ptr) };
    }

    /// Create equals condition
    pub fn equals(left: CfValue, right: CfValue) Condition {
        return Condition.equals(left, right);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "create basic template" {
    const allocator = std.testing.allocator;

    var builder = Builder.init(allocator, "my-app", "production");
    defer builder.deinit();

    _ = builder.withDescription("Test template");
    try builder.addEnvironmentParameter();
    try builder.addProductionCondition();

    const json = try builder.build();
    defer allocator.free(json);

    try std.testing.expect(json.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, json, "AWSTemplateFormatVersion") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Environment") != null);
}

test "generate logical id" {
    const allocator = std.testing.allocator;

    var builder = Builder.init(allocator, "my-app", "prod");
    defer builder.deinit();

    const id = try builder.logicalId("bucket");
    defer allocator.free(id);

    try std.testing.expectEqualStrings("MyAppProdBucket", id);
}

test "CfValue ref serialization" {
    const allocator = std.testing.allocator;

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    const writer = buffer.writer(allocator);
    const value = Fn.ref("MyBucket");
    try writeValue(writer, value, 0);

    try std.testing.expectEqualStrings("{\"Ref\": \"MyBucket\"}", buffer.items);
}

test "CfValue getAtt serialization" {
    const allocator = std.testing.allocator;

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    const writer = buffer.writer(allocator);
    const value = Fn.getAtt("MyBucket", "Arn");
    try writeValue(writer, value, 0);

    try std.testing.expectEqualStrings("{\"Fn::GetAtt\": [\"MyBucket\", \"Arn\"]}", buffer.items);
}
