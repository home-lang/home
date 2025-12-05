const std = @import("std");

/// Locale identifier (e.g., "en", "en-US", "fr-FR")
pub const Locale = struct {
    language: []const u8,
    region: ?[]const u8,

    pub fn parse(locale_str: []const u8) Locale {
        if (std.mem.indexOf(u8, locale_str, "-")) |dash_pos| {
            return .{
                .language = locale_str[0..dash_pos],
                .region = locale_str[dash_pos + 1 ..],
            };
        }
        if (std.mem.indexOf(u8, locale_str, "_")) |underscore_pos| {
            return .{
                .language = locale_str[0..underscore_pos],
                .region = locale_str[underscore_pos + 1 ..],
            };
        }
        return .{
            .language = locale_str,
            .region = null,
        };
    }

    pub fn toString(self: Locale, buf: []u8) ![]const u8 {
        if (self.region) |r| {
            return std.fmt.bufPrint(buf, "{s}-{s}", .{ self.language, r });
        }
        return std.fmt.bufPrint(buf, "{s}", .{self.language});
    }
};

/// Pluralization rule types
pub const PluralRule = enum {
    zero,
    one,
    two,
    few,
    many,
    other,
};

/// Pluralization rules for different languages
pub const PluralRules = struct {
    /// Get plural rule for a count in a specific language
    pub fn getRule(language: []const u8, count: i64) PluralRule {
        // English, German, etc. (one/other)
        if (std.mem.eql(u8, language, "en") or
            std.mem.eql(u8, language, "de") or
            std.mem.eql(u8, language, "nl") or
            std.mem.eql(u8, language, "sv"))
        {
            return if (count == 1) .one else .other;
        }

        // French, Portuguese (zero is singular)
        if (std.mem.eql(u8, language, "fr") or std.mem.eql(u8, language, "pt")) {
            return if (count == 0 or count == 1) .one else .other;
        }

        // Russian, Polish (complex rules)
        if (std.mem.eql(u8, language, "ru") or std.mem.eql(u8, language, "pl")) {
            const abs_count = if (count < 0) -count else count;
            const mod10 = @mod(abs_count, 10);
            const mod100 = @mod(abs_count, 100);

            if (mod10 == 1 and mod100 != 11) return .one;
            if (mod10 >= 2 and mod10 <= 4 and (mod100 < 12 or mod100 > 14)) return .few;
            return .many;
        }

        // Arabic (zero/one/two/few/many/other)
        if (std.mem.eql(u8, language, "ar")) {
            if (count == 0) return .zero;
            if (count == 1) return .one;
            if (count == 2) return .two;
            const mod100 = @mod(count, 100);
            if (mod100 >= 3 and mod100 <= 10) return .few;
            if (mod100 >= 11 and mod100 <= 99) return .many;
            return .other;
        }

        // Japanese, Chinese, Korean (no plural forms)
        if (std.mem.eql(u8, language, "ja") or
            std.mem.eql(u8, language, "zh") or
            std.mem.eql(u8, language, "ko"))
        {
            return .other;
        }

        // Default: one/other like English
        return if (count == 1) .one else .other;
    }
};

/// Translation message with optional plural forms
pub const Message = struct {
    singular: []const u8,
    plural: ?[]const u8 = null,
    zero: ?[]const u8 = null,
    two: ?[]const u8 = null,
    few: ?[]const u8 = null,
    many: ?[]const u8 = null,

    pub fn simple(text: []const u8) Message {
        return .{ .singular = text };
    }

    pub fn withPlural(singular: []const u8, plural: []const u8) Message {
        return .{ .singular = singular, .plural = plural };
    }

    pub fn get(self: Message, rule: PluralRule) []const u8 {
        return switch (rule) {
            .zero => self.zero orelse self.singular,
            .one => self.singular,
            .two => self.two orelse self.plural orelse self.singular,
            .few => self.few orelse self.plural orelse self.singular,
            .many => self.many orelse self.plural orelse self.singular,
            .other => self.plural orelse self.singular,
        };
    }
};

/// Translation catalog for a single locale
pub const Catalog = struct {
    allocator: std.mem.Allocator,
    locale: Locale,
    messages: std.StringHashMap(Message),
    fallback: ?*Catalog,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, locale: Locale) Self {
        return .{
            .allocator = allocator,
            .locale = locale,
            .messages = std.StringHashMap(Message).init(allocator),
            .fallback = null,
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.messages.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.messages.deinit();
    }

    pub fn setFallback(self: *Self, fallback: *Catalog) void {
        self.fallback = fallback;
    }

    pub fn add(self: *Self, key: []const u8, message: Message) !void {
        const owned_key = try self.allocator.dupe(u8, key);
        try self.messages.put(owned_key, message);
    }

    pub fn get(self: *Self, key: []const u8) ?Message {
        if (self.messages.get(key)) |msg| {
            return msg;
        }
        if (self.fallback) |fb| {
            return fb.get(key);
        }
        return null;
    }

    pub fn has(self: *Self, key: []const u8) bool {
        return self.messages.contains(key) or
            (self.fallback != null and self.fallback.?.has(key));
    }
};

/// Translator - main interface for translations
pub const Translator = struct {
    allocator: std.mem.Allocator,
    catalogs: std.StringHashMap(*Catalog),
    current_locale: Locale,
    fallback_locale: Locale,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, default_locale: []const u8) Self {
        return .{
            .allocator = allocator,
            .catalogs = std.StringHashMap(*Catalog).init(allocator),
            .current_locale = Locale.parse(default_locale),
            .fallback_locale = Locale.parse("en"),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.catalogs.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.catalogs.deinit();
    }

    /// Set the current locale
    pub fn setLocale(self: *Self, locale: []const u8) void {
        self.current_locale = Locale.parse(locale);
    }

    /// Set the fallback locale
    pub fn setFallbackLocale(self: *Self, locale: []const u8) void {
        self.fallback_locale = Locale.parse(locale);
    }

    /// Add a catalog for a locale
    pub fn addCatalog(self: *Self, locale_str: []const u8) !*Catalog {
        const catalog = try self.allocator.create(Catalog);
        catalog.* = Catalog.init(self.allocator, Locale.parse(locale_str));

        const key = try self.allocator.dupe(u8, locale_str);
        try self.catalogs.put(key, catalog);

        return catalog;
    }

    /// Get catalog for a locale
    pub fn getCatalog(self: *Self, locale_str: []const u8) ?*Catalog {
        return self.catalogs.get(locale_str);
    }

    /// Translate a key
    pub fn translate(self: *Self, key: []const u8) []const u8 {
        return self.translateWithParams(key, &[_][]const u8{});
    }

    /// Translate with parameter substitution
    pub fn translateWithParams(self: *Self, key: []const u8, params: []const []const u8) []const u8 {
        // Try current locale
        var locale_buf: [16]u8 = undefined;
        const locale_str = self.current_locale.toString(&locale_buf) catch return key;

        if (self.catalogs.get(locale_str)) |catalog| {
            if (catalog.get(key)) |msg| {
                return self.substituteParams(msg.singular, params);
            }
        }

        // Try language only (e.g., "en" from "en-US")
        if (self.catalogs.get(self.current_locale.language)) |catalog| {
            if (catalog.get(key)) |msg| {
                return self.substituteParams(msg.singular, params);
            }
        }

        // Try fallback locale
        const fallback_str = self.fallback_locale.toString(&locale_buf) catch return key;
        if (self.catalogs.get(fallback_str)) |catalog| {
            if (catalog.get(key)) |msg| {
                return self.substituteParams(msg.singular, params);
            }
        }

        // Return key as-is
        return key;
    }

    /// Translate with pluralization
    pub fn translatePlural(self: *Self, key: []const u8, count: i64) []const u8 {
        var locale_buf: [16]u8 = undefined;
        const locale_str = self.current_locale.toString(&locale_buf) catch return key;
        const rule = PluralRules.getRule(self.current_locale.language, count);

        if (self.catalogs.get(locale_str)) |catalog| {
            if (catalog.get(key)) |msg| {
                return msg.get(rule);
            }
        }

        if (self.catalogs.get(self.current_locale.language)) |catalog| {
            if (catalog.get(key)) |msg| {
                return msg.get(rule);
            }
        }

        return key;
    }

    /// Translate with count parameter substitution
    pub fn translateCount(self: *Self, key: []const u8, count: i64) ![]const u8 {
        const base = self.translatePlural(key, count);

        // Substitute :count placeholder
        var count_buf: [32]u8 = undefined;
        const count_str = try std.fmt.bufPrint(&count_buf, "{d}", .{count});

        return self.substituteParams(base, &[_][]const u8{count_str});
    }

    fn substituteParams(self: *Self, template: []const u8, params: []const []const u8) []const u8 {
        _ = self;
        _ = params;
        // Simple substitution - in real impl would replace :0, :1, etc.
        return template;
    }

    /// Shorthand for translate
    pub fn t(self: *Self, key: []const u8) []const u8 {
        return self.translate(key);
    }

    /// Shorthand for translate plural
    pub fn tc(self: *Self, key: []const u8, count: i64) []const u8 {
        return self.translatePlural(key, count);
    }
};

/// Message formatter for complex messages
pub const MessageFormatter = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Format a message with named parameters
    /// Example: "Hello, {name}!" with .{.name = "World"} -> "Hello, World!"
    pub fn format(self: *Self, template: []const u8, params: std.StringHashMap([]const u8)) ![]const u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < template.len) {
            if (template[i] == '{') {
                const end = std.mem.indexOfScalarPos(u8, template, i + 1, '}') orelse {
                    try result.append(self.allocator, template[i]);
                    i += 1;
                    continue;
                };

                const param_name = template[i + 1 .. end];
                if (params.get(param_name)) |value| {
                    try result.appendSlice(self.allocator, value);
                } else {
                    try result.appendSlice(self.allocator, template[i .. end + 1]);
                }
                i = end + 1;
            } else {
                try result.append(self.allocator, template[i]);
                i += 1;
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Format with positional parameters
    /// Example: "Hello, {0}! You have {1} messages." with ["World", "5"]
    pub fn formatPositional(self: *Self, template: []const u8, params: []const []const u8) ![]const u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < template.len) {
            if (template[i] == '{') {
                const end = std.mem.indexOfScalarPos(u8, template, i + 1, '}') orelse {
                    try result.append(self.allocator, template[i]);
                    i += 1;
                    continue;
                };

                const param_str = template[i + 1 .. end];
                const param_idx = std.fmt.parseInt(usize, param_str, 10) catch {
                    try result.appendSlice(self.allocator, template[i .. end + 1]);
                    i = end + 1;
                    continue;
                };

                if (param_idx < params.len) {
                    try result.appendSlice(self.allocator, params[param_idx]);
                } else {
                    try result.appendSlice(self.allocator, template[i .. end + 1]);
                }
                i = end + 1;
            } else {
                try result.append(self.allocator, template[i]);
                i += 1;
            }
        }

        return result.toOwnedSlice(self.allocator);
    }
};

// Tests
test "locale parsing" {
    const en = Locale.parse("en");
    try std.testing.expectEqualStrings("en", en.language);
    try std.testing.expect(en.region == null);

    const en_us = Locale.parse("en-US");
    try std.testing.expectEqualStrings("en", en_us.language);
    try std.testing.expectEqualStrings("US", en_us.region.?);

    const fr_fr = Locale.parse("fr_FR");
    try std.testing.expectEqualStrings("fr", fr_fr.language);
    try std.testing.expectEqualStrings("FR", fr_fr.region.?);
}

test "plural rules english" {
    try std.testing.expectEqual(PluralRule.one, PluralRules.getRule("en", 1));
    try std.testing.expectEqual(PluralRule.other, PluralRules.getRule("en", 0));
    try std.testing.expectEqual(PluralRule.other, PluralRules.getRule("en", 2));
    try std.testing.expectEqual(PluralRule.other, PluralRules.getRule("en", 5));
}

test "plural rules french" {
    try std.testing.expectEqual(PluralRule.one, PluralRules.getRule("fr", 0));
    try std.testing.expectEqual(PluralRule.one, PluralRules.getRule("fr", 1));
    try std.testing.expectEqual(PluralRule.other, PluralRules.getRule("fr", 2));
}

test "message simple" {
    const msg = Message.simple("Hello");
    try std.testing.expectEqualStrings("Hello", msg.get(.one));
    try std.testing.expectEqualStrings("Hello", msg.get(.other));
}

test "message with plural" {
    const msg = Message.withPlural("1 item", "{count} items");
    try std.testing.expectEqualStrings("1 item", msg.get(.one));
    try std.testing.expectEqualStrings("{count} items", msg.get(.other));
}

test "catalog basic" {
    const allocator = std.testing.allocator;

    var catalog = Catalog.init(allocator, Locale.parse("en"));
    defer catalog.deinit();

    try catalog.add("greeting", Message.simple("Hello"));
    try catalog.add("items", Message.withPlural("1 item", "{count} items"));

    const greeting = catalog.get("greeting");
    try std.testing.expect(greeting != null);
    try std.testing.expectEqualStrings("Hello", greeting.?.singular);

    try std.testing.expect(catalog.has("greeting"));
    try std.testing.expect(!catalog.has("nonexistent"));
}

test "translator basic" {
    const allocator = std.testing.allocator;

    var translator = Translator.init(allocator, "en");
    defer translator.deinit();

    const en = try translator.addCatalog("en");
    try en.add("greeting", Message.simple("Hello"));
    try en.add("farewell", Message.simple("Goodbye"));

    try std.testing.expectEqualStrings("Hello", translator.t("greeting"));
    try std.testing.expectEqualStrings("Goodbye", translator.t("farewell"));
    try std.testing.expectEqualStrings("unknown.key", translator.t("unknown.key"));
}

test "translator plural" {
    const allocator = std.testing.allocator;

    var translator = Translator.init(allocator, "en");
    defer translator.deinit();

    const en = try translator.addCatalog("en");
    try en.add("items", Message.withPlural("1 item", "multiple items"));

    try std.testing.expectEqualStrings("1 item", translator.tc("items", 1));
    try std.testing.expectEqualStrings("multiple items", translator.tc("items", 0));
    try std.testing.expectEqualStrings("multiple items", translator.tc("items", 5));
}

test "message formatter positional" {
    const allocator = std.testing.allocator;

    var formatter = MessageFormatter.init(allocator);
    const result = try formatter.formatPositional("Hello, {0}! You have {1} messages.", &[_][]const u8{ "World", "5" });
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello, World! You have 5 messages.", result);
}

test "message formatter named" {
    const allocator = std.testing.allocator;

    var formatter = MessageFormatter.init(allocator);

    var params = std.StringHashMap([]const u8).init(allocator);
    defer params.deinit();
    try params.put("name", "Alice");
    try params.put("count", "3");

    const result = try formatter.format("Hello, {name}! You have {count} new messages.", params);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello, Alice! You have 3 new messages.", result);
}
