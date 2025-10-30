const std = @import("std");
const config_mod = @import("config");
const BaseConfigLoader = config_mod.ConfigLoader;
const linter_mod = @import("linter.zig");
const LinterConfig = linter_mod.LinterConfig;
const RuleConfig = linter_mod.RuleConfig;
const Severity = linter_mod.Severity;

/// Linter-specific configuration loader
/// Uses shared config utilities from the config package
pub const LinterConfigLoader = struct {
    allocator: std.mem.Allocator,
    base_loader: BaseConfigLoader,

    pub fn init(allocator: std.mem.Allocator) LinterConfigLoader {
        return .{
            .allocator = allocator,
            .base_loader = BaseConfigLoader.init(allocator),
        };
    }

    /// Load linter configuration from project directory
    pub fn loadConfig(self: *LinterConfigLoader, project_dir: ?[]const u8) !LinterConfig {
        // Try to find config file
        const config_path = self.base_loader.findConfigFile(project_dir) catch {
            // No config file found, use defaults
            return try linter_mod.createDefaultConfig(self.allocator);
        };
        defer self.allocator.free(config_path);

        // Load file content
        const content = try self.base_loader.loadConfigFile(config_path);
        defer self.allocator.free(content);

        // Parse based on file type
        if (std.mem.endsWith(u8, config_path, ".jsonc") or std.mem.endsWith(u8, config_path, ".json")) {
            return try self.parseJsonConfig(content);
        } else if (std.mem.endsWith(u8, config_path, ".toml")) {
            return try self.parseTomlConfig(content);
        }

        return error.UnsupportedConfigFormat;
    }

    fn parseJsonConfig(self: *LinterConfigLoader, content: []const u8) !LinterConfig {
        var parsed = try self.base_loader.parseJson(content);
        defer parsed.deinit();

        const root = parsed.value;
        
        // Look for "linter" field in the JSON
        const linter_obj = BaseConfigLoader.getJsonField(root, "linter") orelse {
            return try linter_mod.createDefaultConfig(self.allocator);
        };

        var config = LinterConfig.init(self.allocator);

        // Parse linter settings
        if (BaseConfigLoader.getJsonField(linter_obj, "max_line_length")) |val| {
            if (BaseConfigLoader.getJsonInt(val)) |int_val| {
                config.max_line_length = @intCast(int_val);
            }
        }
        if (BaseConfigLoader.getJsonField(linter_obj, "indent_size")) |val| {
            if (BaseConfigLoader.getJsonInt(val)) |int_val| {
                config.indent_size = @intCast(int_val);
            }
        }
        if (BaseConfigLoader.getJsonField(linter_obj, "use_spaces")) |val| {
            if (BaseConfigLoader.getJsonBool(val)) |bool_val| {
                config.use_spaces = bool_val;
            }
        }
        if (BaseConfigLoader.getJsonField(linter_obj, "trailing_comma")) |val| {
            if (BaseConfigLoader.getJsonBool(val)) |bool_val| {
                config.trailing_comma = bool_val;
            }
        }
        if (BaseConfigLoader.getJsonField(linter_obj, "semicolons")) |val| {
            if (BaseConfigLoader.getJsonBool(val)) |bool_val| {
                config.semicolons = bool_val;
            }
        }
        if (BaseConfigLoader.getJsonField(linter_obj, "quote_style")) |val| {
            if (BaseConfigLoader.getJsonString(val)) |str_val| {
                config.quote_style = if (std.mem.eql(u8, str_val, "single"))
                    .single
                else
                    .double;
            }
        }

        // Parse rules
        if (BaseConfigLoader.getJsonField(linter_obj, "rules")) |rules_value| {
            if (BaseConfigLoader.getJsonObject(rules_value)) |rules_obj| {
                var it = rules_obj.iterator();
                while (it.next()) |entry| {
                    const rule_id = entry.key_ptr.*;
                    const rule_value = entry.value_ptr.*;

                    const rule_config = try self.parseRuleConfig(rule_value);
                    try config.setRule(rule_id, rule_config);
                }
            }
        }

        return config;
    }

    fn parseTomlConfig(self: *LinterConfigLoader, content: []const u8) !LinterConfig {
        _ = content;
        _ = self;
        // Simplified - use default config for now
        // Full TOML parsing would go here
        return try linter_mod.createDefaultConfig(self.allocator);
    }

    fn parseRuleConfig(self: *LinterConfigLoader, value: std.json.Value) !RuleConfig {
        _ = self;
        
        var rule_config = RuleConfig{};

        if (BaseConfigLoader.getJsonObject(value)) |obj| {
            if (obj.get("enabled")) |enabled| {
                if (BaseConfigLoader.getJsonBool(enabled)) |bool_val| {
                    rule_config.enabled = bool_val;
                }
            }
            if (obj.get("auto_fix")) |auto_fix| {
                if (BaseConfigLoader.getJsonBool(auto_fix)) |bool_val| {
                    rule_config.auto_fix = bool_val;
                }
            }
            if (obj.get("severity")) |severity| {
                if (BaseConfigLoader.getJsonString(severity)) |severity_str| {
                    rule_config.severity = if (std.mem.eql(u8, severity_str, "error"))
                        .error_
                    else if (std.mem.eql(u8, severity_str, "warning"))
                        .warning
                    else if (std.mem.eql(u8, severity_str, "info"))
                        .info
                    else
                        .hint;
                }
            }
        }

        return rule_config;
    }
};
