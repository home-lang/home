// Network Module - VPC, Subnets, Security Groups, Load Balancers
// Provides type-safe networking resource creation for CloudFormation templates

const std = @import("std");
const Allocator = std.mem.Allocator;
const cf = @import("../cloudformation.zig");
const CfValue = cf.CfValue;
const Resource = cf.Resource;
const Fn = cf.Fn;

// ============================================================================
// VPC
// ============================================================================

/// VPC configuration options
pub const VpcOptions = struct {
    cidr_block: []const u8 = "10.0.0.0/16",
    enable_dns_support: bool = true,
    enable_dns_hostnames: bool = true,
    instance_tenancy: Tenancy = .default,
    tags: []const Tag = &[_]Tag{},

    pub const Tenancy = enum {
        default,
        dedicated,
        host,

        pub fn toString(self: Tenancy) []const u8 {
            return switch (self) {
                .default => "default",
                .dedicated => "dedicated",
                .host => "host",
            };
        }
    };

    pub const Tag = struct {
        key: []const u8,
        value: []const u8,
    };
};

/// Subnet configuration options
pub const SubnetOptions = struct {
    vpc_id: ?[]const u8 = null,
    vpc_ref: ?[]const u8 = null,
    cidr_block: []const u8,
    availability_zone: ?[]const u8 = null,
    map_public_ip_on_launch: bool = false,
    tags: []const Tag = &[_]Tag{},

    pub const Tag = struct {
        key: []const u8,
        value: []const u8,
    };
};

// ============================================================================
// Security Group
// ============================================================================

/// Security Group configuration options
pub const SecurityGroupOptions = struct {
    group_name: ?[]const u8 = null,
    group_description: []const u8 = "Security group",
    vpc_id: ?[]const u8 = null,
    vpc_ref: ?[]const u8 = null,
    ingress_rules: []const IngressRule = &[_]IngressRule{},
    egress_rules: []const EgressRule = &[_]EgressRule{},
    tags: []const Tag = &[_]Tag{},

    pub const IngressRule = struct {
        ip_protocol: Protocol = .tcp,
        from_port: u16,
        to_port: u16,
        cidr_ip: ?[]const u8 = null,
        source_security_group_id: ?[]const u8 = null,
        source_security_group_ref: ?[]const u8 = null,
        description: ?[]const u8 = null,

        pub const Protocol = enum {
            tcp,
            udp,
            icmp,
            all,

            pub fn toString(self: Protocol) []const u8 {
                return switch (self) {
                    .tcp => "tcp",
                    .udp => "udp",
                    .icmp => "icmp",
                    .all => "-1",
                };
            }
        };
    };

    pub const EgressRule = struct {
        ip_protocol: IngressRule.Protocol = .all,
        from_port: u16 = 0,
        to_port: u16 = 65535,
        cidr_ip: []const u8 = "0.0.0.0/0",
        description: ?[]const u8 = null,
    };

    pub const Tag = struct {
        key: []const u8,
        value: []const u8,
    };
};

// ============================================================================
// Application Load Balancer
// ============================================================================

/// ALB configuration options
pub const AlbOptions = struct {
    name: ?[]const u8 = null,
    scheme: Scheme = .internet_facing,
    ip_address_type: IpAddressType = .ipv4,
    subnets: []const []const u8 = &[_][]const u8{},
    subnet_refs: []const []const u8 = &[_][]const u8{},
    security_groups: []const []const u8 = &[_][]const u8{},
    security_group_refs: []const []const u8 = &[_][]const u8{},
    enable_deletion_protection: bool = false,
    enable_http2: bool = true,
    idle_timeout: u32 = 60,
    access_logs: ?AccessLogs = null,
    tags: []const Tag = &[_]Tag{},

    pub const Scheme = enum {
        internet_facing,
        internal,

        pub fn toString(self: Scheme) []const u8 {
            return switch (self) {
                .internet_facing => "internet-facing",
                .internal => "internal",
            };
        }
    };

    pub const IpAddressType = enum {
        ipv4,
        dualstack,

        pub fn toString(self: IpAddressType) []const u8 {
            return switch (self) {
                .ipv4 => "ipv4",
                .dualstack => "dualstack",
            };
        }
    };

    pub const AccessLogs = struct {
        enabled: bool = true,
        s3_bucket_name: []const u8,
        s3_prefix: ?[]const u8 = null,
    };

    pub const Tag = struct {
        key: []const u8,
        value: []const u8,
    };
};

/// Target Group configuration options
pub const TargetGroupOptions = struct {
    name: ?[]const u8 = null,
    port: u16 = 80,
    protocol: Protocol = .HTTP,
    vpc_id: ?[]const u8 = null,
    vpc_ref: ?[]const u8 = null,
    target_type: TargetType = .ip,
    health_check: ?HealthCheck = null,
    deregistration_delay: u32 = 300,
    slow_start: u32 = 0,
    tags: []const Tag = &[_]Tag{},

    pub const Protocol = enum {
        HTTP,
        HTTPS,
        TCP,
        TLS,
        UDP,
        TCP_UDP,

        pub fn toString(self: Protocol) []const u8 {
            return switch (self) {
                .HTTP => "HTTP",
                .HTTPS => "HTTPS",
                .TCP => "TCP",
                .TLS => "TLS",
                .UDP => "UDP",
                .TCP_UDP => "TCP_UDP",
            };
        }
    };

    pub const TargetType = enum {
        instance,
        ip,
        lambda,
        alb,

        pub fn toString(self: TargetType) []const u8 {
            return switch (self) {
                .instance => "instance",
                .ip => "ip",
                .lambda => "lambda",
                .alb => "alb",
            };
        }
    };

    pub const HealthCheck = struct {
        enabled: bool = true,
        healthy_threshold: u32 = 3,
        unhealthy_threshold: u32 = 3,
        interval: u32 = 30,
        timeout: u32 = 5,
        path: []const u8 = "/",
        protocol: Protocol = .HTTP,
        port: ?[]const u8 = null, // "traffic-port" or specific port
        matcher: ?[]const u8 = null, // HTTP status codes
    };

    pub const Tag = struct {
        key: []const u8,
        value: []const u8,
    };
};

/// Listener configuration options
pub const ListenerOptions = struct {
    load_balancer_arn: ?[]const u8 = null,
    load_balancer_ref: ?[]const u8 = null,
    port: u16 = 80,
    protocol: TargetGroupOptions.Protocol = .HTTP,
    default_target_group_arn: ?[]const u8 = null,
    default_target_group_ref: ?[]const u8 = null,
    ssl_policy: ?[]const u8 = null,
    certificates: []const Certificate = &[_]Certificate{},

    pub const Certificate = struct {
        certificate_arn: []const u8,
    };
};

// ============================================================================
// API Gateway
// ============================================================================

/// HTTP API (API Gateway v2) configuration options
pub const HttpApiOptions = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    protocol_type: ProtocolType = .HTTP,
    cors_configuration: ?CorsConfig = null,
    disable_execute_api_endpoint: bool = false,
    tags: []const Tag = &[_]Tag{},

    pub const ProtocolType = enum {
        HTTP,
        WEBSOCKET,

        pub fn toString(self: ProtocolType) []const u8 {
            return switch (self) {
                .HTTP => "HTTP",
                .WEBSOCKET => "WEBSOCKET",
            };
        }
    };

    pub const CorsConfig = struct {
        allow_credentials: bool = false,
        allow_headers: []const []const u8 = &[_][]const u8{"*"},
        allow_methods: []const []const u8 = &[_][]const u8{"*"},
        allow_origins: []const []const u8 = &[_][]const u8{"*"},
        expose_headers: []const []const u8 = &[_][]const u8{},
        max_age: ?u32 = null,
    };

    pub const Tag = struct {
        key: []const u8,
        value: []const u8,
    };
};

// ============================================================================
// Network Module
// ============================================================================

pub const Network = struct {
    /// Create a VPC resource
    pub fn createVpc(allocator: Allocator, options: VpcOptions) !Resource {
        var props = std.StringHashMap(CfValue).init(allocator);

        try props.put("CidrBlock", CfValue.str(options.cidr_block));
        try props.put("EnableDnsSupport", CfValue.boolean(options.enable_dns_support));
        try props.put("EnableDnsHostnames", CfValue.boolean(options.enable_dns_hostnames));
        try props.put("InstanceTenancy", CfValue.str(options.instance_tenancy.toString()));

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
            .type = "AWS::EC2::VPC",
            .properties = props,
        };
    }

    /// Create a Subnet resource
    pub fn createSubnet(allocator: Allocator, options: SubnetOptions) !Resource {
        var props = std.StringHashMap(CfValue).init(allocator);

        // VPC
        if (options.vpc_ref) |vpc_ref| {
            try props.put("VpcId", Fn.ref(vpc_ref));
        } else if (options.vpc_id) |vpc_id| {
            try props.put("VpcId", CfValue.str(vpc_id));
        }

        try props.put("CidrBlock", CfValue.str(options.cidr_block));

        if (options.availability_zone) |az| {
            try props.put("AvailabilityZone", CfValue.str(az));
        }

        try props.put("MapPublicIpOnLaunch", CfValue.boolean(options.map_public_ip_on_launch));

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
            .type = "AWS::EC2::Subnet",
            .properties = props,
        };
    }

    /// Create an Internet Gateway resource
    pub fn createInternetGateway(allocator: Allocator, tags: []const VpcOptions.Tag) !Resource {
        var props = std.StringHashMap(CfValue).init(allocator);

        if (tags.len > 0) {
            const tag_values = try allocator.alloc(CfValue, tags.len);
            for (tags, 0..) |tag, i| {
                var tag_obj = std.StringHashMap(CfValue).init(allocator);
                try tag_obj.put("Key", CfValue.str(tag.key));
                try tag_obj.put("Value", CfValue.str(tag.value));
                tag_values[i] = .{ .object = tag_obj };
            }
            try props.put("Tags", .{ .array = tag_values });
        }

        return Resource{
            .type = "AWS::EC2::InternetGateway",
            .properties = props,
        };
    }

    /// Create a VPC Gateway Attachment
    pub fn createGatewayAttachment(allocator: Allocator, vpc_ref: []const u8, igw_ref: []const u8) !Resource {
        var props = std.StringHashMap(CfValue).init(allocator);

        try props.put("VpcId", Fn.ref(vpc_ref));
        try props.put("InternetGatewayId", Fn.ref(igw_ref));

        return Resource{
            .type = "AWS::EC2::VPCGatewayAttachment",
            .properties = props,
        };
    }

    /// Create a Route Table
    pub fn createRouteTable(allocator: Allocator, vpc_ref: []const u8, tags: []const VpcOptions.Tag) !Resource {
        var props = std.StringHashMap(CfValue).init(allocator);

        try props.put("VpcId", Fn.ref(vpc_ref));

        if (tags.len > 0) {
            const tag_values = try allocator.alloc(CfValue, tags.len);
            for (tags, 0..) |tag, i| {
                var tag_obj = std.StringHashMap(CfValue).init(allocator);
                try tag_obj.put("Key", CfValue.str(tag.key));
                try tag_obj.put("Value", CfValue.str(tag.value));
                tag_values[i] = .{ .object = tag_obj };
            }
            try props.put("Tags", .{ .array = tag_values });
        }

        return Resource{
            .type = "AWS::EC2::RouteTable",
            .properties = props,
        };
    }

    /// Create a Route
    pub fn createRoute(allocator: Allocator, route_table_ref: []const u8, destination_cidr: []const u8, gateway_ref: []const u8) !Resource {
        var props = std.StringHashMap(CfValue).init(allocator);

        try props.put("RouteTableId", Fn.ref(route_table_ref));
        try props.put("DestinationCidrBlock", CfValue.str(destination_cidr));
        try props.put("GatewayId", Fn.ref(gateway_ref));

        return Resource{
            .type = "AWS::EC2::Route",
            .properties = props,
        };
    }

    /// Create a Subnet Route Table Association
    pub fn createSubnetRouteTableAssociation(allocator: Allocator, subnet_ref: []const u8, route_table_ref: []const u8) !Resource {
        var props = std.StringHashMap(CfValue).init(allocator);

        try props.put("SubnetId", Fn.ref(subnet_ref));
        try props.put("RouteTableId", Fn.ref(route_table_ref));

        return Resource{
            .type = "AWS::EC2::SubnetRouteTableAssociation",
            .properties = props,
        };
    }

    /// Create a Security Group resource
    pub fn createSecurityGroup(allocator: Allocator, options: SecurityGroupOptions) !Resource {
        var props = std.StringHashMap(CfValue).init(allocator);

        if (options.group_name) |name| {
            try props.put("GroupName", CfValue.str(name));
        }

        try props.put("GroupDescription", CfValue.str(options.group_description));

        // VPC
        if (options.vpc_ref) |vpc_ref| {
            try props.put("VpcId", Fn.ref(vpc_ref));
        } else if (options.vpc_id) |vpc_id| {
            try props.put("VpcId", CfValue.str(vpc_id));
        }

        // Ingress rules
        if (options.ingress_rules.len > 0) {
            const ingress = try allocator.alloc(CfValue, options.ingress_rules.len);
            for (options.ingress_rules, 0..) |rule, i| {
                var rule_obj = std.StringHashMap(CfValue).init(allocator);
                try rule_obj.put("IpProtocol", CfValue.str(rule.ip_protocol.toString()));
                try rule_obj.put("FromPort", CfValue.int(@intCast(rule.from_port)));
                try rule_obj.put("ToPort", CfValue.int(@intCast(rule.to_port)));

                if (rule.cidr_ip) |cidr| {
                    try rule_obj.put("CidrIp", CfValue.str(cidr));
                }

                if (rule.source_security_group_ref) |sg_ref| {
                    try rule_obj.put("SourceSecurityGroupId", Fn.ref(sg_ref));
                } else if (rule.source_security_group_id) |sg_id| {
                    try rule_obj.put("SourceSecurityGroupId", CfValue.str(sg_id));
                }

                if (rule.description) |desc| {
                    try rule_obj.put("Description", CfValue.str(desc));
                }

                ingress[i] = .{ .object = rule_obj };
            }
            try props.put("SecurityGroupIngress", .{ .array = ingress });
        }

        // Egress rules
        if (options.egress_rules.len > 0) {
            const egress = try allocator.alloc(CfValue, options.egress_rules.len);
            for (options.egress_rules, 0..) |rule, i| {
                var rule_obj = std.StringHashMap(CfValue).init(allocator);
                try rule_obj.put("IpProtocol", CfValue.str(rule.ip_protocol.toString()));
                try rule_obj.put("FromPort", CfValue.int(@intCast(rule.from_port)));
                try rule_obj.put("ToPort", CfValue.int(@intCast(rule.to_port)));
                try rule_obj.put("CidrIp", CfValue.str(rule.cidr_ip));

                if (rule.description) |desc| {
                    try rule_obj.put("Description", CfValue.str(desc));
                }

                egress[i] = .{ .object = rule_obj };
            }
            try props.put("SecurityGroupEgress", .{ .array = egress });
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
            .type = "AWS::EC2::SecurityGroup",
            .properties = props,
        };
    }

    /// Create a web server security group (convenience method)
    pub fn createWebServerSecurityGroup(allocator: Allocator, vpc_ref: []const u8, name: ?[]const u8) !Resource {
        return createSecurityGroup(allocator, .{
            .group_name = name,
            .group_description = "Security group for web servers",
            .vpc_ref = vpc_ref,
            .ingress_rules = &[_]SecurityGroupOptions.IngressRule{
                .{ .from_port = 80, .to_port = 80, .cidr_ip = "0.0.0.0/0", .description = "HTTP" },
                .{ .from_port = 443, .to_port = 443, .cidr_ip = "0.0.0.0/0", .description = "HTTPS" },
            },
            .egress_rules = &[_]SecurityGroupOptions.EgressRule{
                .{ .description = "Allow all outbound" },
            },
        });
    }

    /// Create an Application Load Balancer resource
    pub fn createAlb(allocator: Allocator, options: AlbOptions) !Resource {
        var props = std.StringHashMap(CfValue).init(allocator);

        if (options.name) |name| {
            try props.put("Name", CfValue.str(name));
        }

        try props.put("Type", CfValue.str("application"));
        try props.put("Scheme", CfValue.str(options.scheme.toString()));
        try props.put("IpAddressType", CfValue.str(options.ip_address_type.toString()));

        // Subnets
        if (options.subnet_refs.len > 0) {
            const subnets = try allocator.alloc(CfValue, options.subnet_refs.len);
            for (options.subnet_refs, 0..) |subnet, i| {
                subnets[i] = Fn.ref(subnet);
            }
            try props.put("Subnets", .{ .array = subnets });
        } else if (options.subnets.len > 0) {
            const subnets = try allocator.alloc(CfValue, options.subnets.len);
            for (options.subnets, 0..) |subnet, i| {
                subnets[i] = CfValue.str(subnet);
            }
            try props.put("Subnets", .{ .array = subnets });
        }

        // Security groups
        if (options.security_group_refs.len > 0) {
            const sgs = try allocator.alloc(CfValue, options.security_group_refs.len);
            for (options.security_group_refs, 0..) |sg, i| {
                sgs[i] = Fn.ref(sg);
            }
            try props.put("SecurityGroups", .{ .array = sgs });
        } else if (options.security_groups.len > 0) {
            const sgs = try allocator.alloc(CfValue, options.security_groups.len);
            for (options.security_groups, 0..) |sg, i| {
                sgs[i] = CfValue.str(sg);
            }
            try props.put("SecurityGroups", .{ .array = sgs });
        }

        // Attributes
        var attrs: [3]CfValue = undefined;
        var attr_count: usize = 0;

        var del_protection = std.StringHashMap(CfValue).init(allocator);
        try del_protection.put("Key", CfValue.str("deletion_protection.enabled"));
        try del_protection.put("Value", CfValue.str(if (options.enable_deletion_protection) "true" else "false"));
        attrs[attr_count] = .{ .object = del_protection };
        attr_count += 1;

        var http2 = std.StringHashMap(CfValue).init(allocator);
        try http2.put("Key", CfValue.str("routing.http2.enabled"));
        try http2.put("Value", CfValue.str(if (options.enable_http2) "true" else "false"));
        attrs[attr_count] = .{ .object = http2 };
        attr_count += 1;

        var idle = std.StringHashMap(CfValue).init(allocator);
        try idle.put("Key", CfValue.str("idle_timeout.timeout_seconds"));
        var timeout_str: [16]u8 = undefined;
        const timeout_len = std.fmt.formatIntBuf(&timeout_str, options.idle_timeout, 10, .lower, .{});
        try idle.put("Value", CfValue.str(timeout_str[0..timeout_len]));
        attrs[attr_count] = .{ .object = idle };
        attr_count += 1;

        const lb_attrs = try allocator.alloc(CfValue, attr_count);
        @memcpy(lb_attrs, attrs[0..attr_count]);
        try props.put("LoadBalancerAttributes", .{ .array = lb_attrs });

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
            .type = "AWS::ElasticLoadBalancingV2::LoadBalancer",
            .properties = props,
        };
    }

    /// Create a Target Group resource
    pub fn createTargetGroup(allocator: Allocator, options: TargetGroupOptions) !Resource {
        var props = std.StringHashMap(CfValue).init(allocator);

        if (options.name) |name| {
            try props.put("Name", CfValue.str(name));
        }

        try props.put("Port", CfValue.int(@intCast(options.port)));
        try props.put("Protocol", CfValue.str(options.protocol.toString()));
        try props.put("TargetType", CfValue.str(options.target_type.toString()));

        // VPC
        if (options.vpc_ref) |vpc_ref| {
            try props.put("VpcId", Fn.ref(vpc_ref));
        } else if (options.vpc_id) |vpc_id| {
            try props.put("VpcId", CfValue.str(vpc_id));
        }

        // Health check
        if (options.health_check) |hc| {
            try props.put("HealthCheckEnabled", CfValue.boolean(hc.enabled));
            try props.put("HealthyThresholdCount", CfValue.int(@intCast(hc.healthy_threshold)));
            try props.put("UnhealthyThresholdCount", CfValue.int(@intCast(hc.unhealthy_threshold)));
            try props.put("HealthCheckIntervalSeconds", CfValue.int(@intCast(hc.interval)));
            try props.put("HealthCheckTimeoutSeconds", CfValue.int(@intCast(hc.timeout)));
            try props.put("HealthCheckPath", CfValue.str(hc.path));
            try props.put("HealthCheckProtocol", CfValue.str(hc.protocol.toString()));

            if (hc.matcher) |matcher| {
                var matcher_obj = std.StringHashMap(CfValue).init(allocator);
                try matcher_obj.put("HttpCode", CfValue.str(matcher));
                try props.put("Matcher", .{ .object = matcher_obj });
            }
        }

        try props.put("DeregistrationDelayTimeoutSeconds", CfValue.int(@intCast(options.deregistration_delay)));

        if (options.slow_start > 0) {
            try props.put("SlowStartDurationSeconds", CfValue.int(@intCast(options.slow_start)));
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
            .type = "AWS::ElasticLoadBalancingV2::TargetGroup",
            .properties = props,
        };
    }

    /// Create an ALB Listener resource
    pub fn createListener(allocator: Allocator, options: ListenerOptions) !Resource {
        var props = std.StringHashMap(CfValue).init(allocator);

        // Load balancer
        if (options.load_balancer_ref) |lb_ref| {
            try props.put("LoadBalancerArn", Fn.ref(lb_ref));
        } else if (options.load_balancer_arn) |lb_arn| {
            try props.put("LoadBalancerArn", CfValue.str(lb_arn));
        }

        try props.put("Port", CfValue.int(@intCast(options.port)));
        try props.put("Protocol", CfValue.str(options.protocol.toString()));

        // Default action
        var action = std.StringHashMap(CfValue).init(allocator);
        try action.put("Type", CfValue.str("forward"));

        if (options.default_target_group_ref) |tg_ref| {
            try action.put("TargetGroupArn", Fn.ref(tg_ref));
        } else if (options.default_target_group_arn) |tg_arn| {
            try action.put("TargetGroupArn", CfValue.str(tg_arn));
        }

        const actions = try allocator.alloc(CfValue, 1);
        actions[0] = .{ .object = action };
        try props.put("DefaultActions", .{ .array = actions });

        // SSL
        if (options.ssl_policy) |ssl| {
            try props.put("SslPolicy", CfValue.str(ssl));
        }

        if (options.certificates.len > 0) {
            const certs = try allocator.alloc(CfValue, options.certificates.len);
            for (options.certificates, 0..) |cert, i| {
                var cert_obj = std.StringHashMap(CfValue).init(allocator);
                try cert_obj.put("CertificateArn", CfValue.str(cert.certificate_arn));
                certs[i] = .{ .object = cert_obj };
            }
            try props.put("Certificates", .{ .array = certs });
        }

        return Resource{
            .type = "AWS::ElasticLoadBalancingV2::Listener",
            .properties = props,
        };
    }

    /// Create an HTTP API (API Gateway v2) resource
    pub fn createHttpApi(allocator: Allocator, options: HttpApiOptions) !Resource {
        var props = std.StringHashMap(CfValue).init(allocator);

        if (options.name) |name| {
            try props.put("Name", CfValue.str(name));
        }

        if (options.description) |desc| {
            try props.put("Description", CfValue.str(desc));
        }

        try props.put("ProtocolType", CfValue.str(options.protocol_type.toString()));

        if (options.disable_execute_api_endpoint) {
            try props.put("DisableExecuteApiEndpoint", CfValue.boolean(true));
        }

        // CORS
        if (options.cors_configuration) |cors| {
            var cors_obj = std.StringHashMap(CfValue).init(allocator);

            try cors_obj.put("AllowCredentials", CfValue.boolean(cors.allow_credentials));

            const headers = try allocator.alloc(CfValue, cors.allow_headers.len);
            for (cors.allow_headers, 0..) |h, i| {
                headers[i] = CfValue.str(h);
            }
            try cors_obj.put("AllowHeaders", .{ .array = headers });

            const methods = try allocator.alloc(CfValue, cors.allow_methods.len);
            for (cors.allow_methods, 0..) |m, i| {
                methods[i] = CfValue.str(m);
            }
            try cors_obj.put("AllowMethods", .{ .array = methods });

            const origins = try allocator.alloc(CfValue, cors.allow_origins.len);
            for (cors.allow_origins, 0..) |o, i| {
                origins[i] = CfValue.str(o);
            }
            try cors_obj.put("AllowOrigins", .{ .array = origins });

            if (cors.max_age) |max_age| {
                try cors_obj.put("MaxAge", CfValue.int(@intCast(max_age)));
            }

            try props.put("CorsConfiguration", .{ .object = cors_obj });
        }

        // Tags
        if (options.tags.len > 0) {
            var tags_obj = std.StringHashMap(CfValue).init(allocator);
            for (options.tags) |tag| {
                try tags_obj.put(tag.key, CfValue.str(tag.value));
            }
            try props.put("Tags", .{ .object = tags_obj });
        }

        return Resource{
            .type = "AWS::ApiGatewayV2::Api",
            .properties = props,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "create vpc" {
    const allocator = std.testing.allocator;

    const vpc = try Network.createVpc(allocator, .{
        .cidr_block = "10.0.0.0/16",
    });

    try std.testing.expectEqualStrings("AWS::EC2::VPC", vpc.type);

    var props = vpc.properties;
    props.deinit();
}

test "create security group" {
    const allocator = std.testing.allocator;

    const sg = try Network.createSecurityGroup(allocator, .{
        .group_name = "my-sg",
        .group_description = "Test security group",
        .ingress_rules = &[_]SecurityGroupOptions.IngressRule{
            .{ .from_port = 80, .to_port = 80, .cidr_ip = "0.0.0.0/0" },
        },
    });

    try std.testing.expectEqualStrings("AWS::EC2::SecurityGroup", sg.type);

    var props = sg.properties;
    props.deinit();
}

test "create alb" {
    const allocator = std.testing.allocator;

    const alb = try Network.createAlb(allocator, .{
        .name = "my-alb",
        .scheme = .internet_facing,
    });

    try std.testing.expectEqualStrings("AWS::ElasticLoadBalancingV2::LoadBalancer", alb.type);

    var props = alb.properties;
    props.deinit();
}
