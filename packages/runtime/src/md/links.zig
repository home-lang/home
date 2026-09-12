/// Maximum parenthesis nesting depth inside a bare inline-link destination.
/// CommonMark permits an implementation limit; cmark, commonmark.js, and Bun
/// all use 32. The bound also prevents repeated unclosed candidates from
/// turning their destination scan quadratic.
const MAX_LINK_DEST_PAREN_DEPTH: u32 = 32;

/// Maximum bracket nesting inside a wiki link. This bounds the forward scan
/// for `]]` when wiki links are enabled and many candidates are unclosed.
const MAX_WIKI_BRACKET_DEPTH: u32 = 32;

const BracketLookup = union(enum) {
    matched: usize,
    unmatched,
    unknown,
};

const BracketScan = struct {
    close: usize,
    has_inner_bracket: bool,
};

const UNMATCHED_BRACKET: OFF = std.math.maxInt(OFF);

/// Build the bracket-pair map for one top-level inline slice. While an opener
/// is unmatched, its close slot threads the previous opener's index, so no
/// second stack allocation is required. Code spans, HTML/autolinks and escapes
/// hide brackets exactly as they do in the link parser.
pub fn computeBracketMatches(self: *Parser, content: []const u8) Parser.Error!void {
    self.bracket_pairs.clearRetainingCapacity();
    self.bracket_slice_addr = @intFromPtr(content.ptr);
    self.bracket_slice_len = content.len;
    self.bracket_no_closers = false;

    if (std.mem.indexOfScalar(u8, content, '[') == null) return;
    if (std.mem.indexOfScalar(u8, content, ']') == null) {
        self.bracket_no_closers = true;
        return;
    }

    const scan_chars: []const u8 = if (self.flags.no_html_spans) "[]\\`" else "[]\\`<";
    var top = UNMATCHED_BRACKET;
    var pos: usize = 0;
    while (pos < content.len) {
        switch (content[pos]) {
            '\\' => pos += 2,
            '`' => {
                const count = inlines_mod.countBackticks(content, pos);
                if (self.findCodeSpanEnd(content, pos + count, count)) |end_pos| {
                    pos = end_pos + count;
                } else {
                    pos += count;
                }
            },
            '<' => if (!self.flags.no_html_spans) {
                if (self.findHtmlTag(content, pos)) |tag_end| {
                    pos = tag_end;
                } else if (self.findAutolink(content, pos)) |autolink| {
                    pos = autolink.end_pos;
                } else {
                    pos += 1;
                }
            } else {
                pos += 1;
            },
            '[' => {
                const index: OFF = @intCast(self.bracket_pairs.items.len);
                try self.bracket_pairs.append(self.allocator, .{ .open = @intCast(pos), .close = top });
                top = index;
                pos += 1;
            },
            ']' => {
                if (top != UNMATCHED_BRACKET) {
                    const index: usize = @intCast(top);
                    top = self.bracket_pairs.items[index].close;
                    self.bracket_pairs.items[index].close = @intCast(pos);
                }
                pos += 1;
            },
            else => {
                const relative = std.mem.indexOfAny(u8, content[pos..], scan_chars) orelse break;
                pos += relative;
            },
        }
    }

    while (top != UNMATCHED_BRACKET) {
        const index: usize = @intCast(top);
        top = self.bracket_pairs.items[index].close;
        self.bracket_pairs.items[index].close = UNMATCHED_BRACKET;
    }
}

fn bracketSliceOffset(self: *const Parser, content: []const u8) ?usize {
    const addr = @intFromPtr(content.ptr);
    if (addr < self.bracket_slice_addr) return null;
    const offset = addr - self.bracket_slice_addr;
    if (offset > self.bracket_slice_len or content.len > self.bracket_slice_len - offset) return null;
    return offset;
}

fn lookupBracket(self: *const Parser, absolute_open: usize) BracketLookup {
    if (self.bracket_no_closers) return .unmatched;
    var lo: usize = 0;
    var hi = self.bracket_pairs.items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (@as(usize, self.bracket_pairs.items[mid].open) < absolute_open) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (lo >= self.bracket_pairs.items.len or @as(usize, self.bracket_pairs.items[lo].open) != absolute_open) return .unknown;
    const close = self.bracket_pairs.items[lo].close;
    if (close == UNMATCHED_BRACKET) return .unmatched;
    return .{ .matched = @intCast(close) };
}

fn hasBracketOpenerBetween(self: *const Parser, low: usize, high: usize) bool {
    var lo: usize = 0;
    var hi = self.bracket_pairs.items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (@as(usize, self.bracket_pairs.items[mid].open) <= low) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo < self.bracket_pairs.items.len and @as(usize, self.bracket_pairs.items[lo].open) < high;
}

fn scanBracketClose(self: *Parser, content: []const u8, start: usize) ?BracketScan {
    var pos = start + 1;
    var bracket_depth: u32 = 1;
    var has_inner_bracket = false;
    while (pos < content.len and bracket_depth > 0) {
        if (content[pos] == '\\' and pos + 1 < content.len) {
            pos += 2;
            continue;
        }
        if (content[pos] == '`') {
            const count = inlines_mod.countBackticks(content, pos);
            if (self.findCodeSpanEnd(content, pos + count, count)) |end_pos| {
                pos = end_pos + count;
            } else {
                pos += count;
            }
            continue;
        }
        if (content[pos] == '<' and !self.flags.no_html_spans) {
            if (self.findHtmlTag(content, pos)) |tag_end| {
                pos = tag_end;
                continue;
            }
            if (self.findAutolink(content, pos)) |autolink| {
                pos = autolink.end_pos;
                continue;
            }
        }
        if (content[pos] == '[') {
            bracket_depth += 1;
            has_inner_bracket = true;
        }
        if (content[pos] == ']') bracket_depth -= 1;
        if (bracket_depth > 0) pos += 1;
    }
    if (bracket_depth != 0) return null;
    return .{ .close = pos, .has_inner_bracket = has_inner_bracket };
}

fn matchBracket(self: *Parser, content: []const u8, start: usize) ?BracketScan {
    const base = bracketSliceOffset(self, content) orelse return scanBracketClose(self, content, start);
    switch (lookupBracket(self, base + start)) {
        .matched => |close| {
            if (close > base and close - base < content.len) {
                return .{ .close = close - base, .has_inner_bracket = hasBracketOpenerBetween(self, base + start, close) };
            }
            return scanBracketClose(self, content, start);
        },
        .unmatched => return null,
        .unknown => return scanBracketClose(self, content, start),
    }
}

pub fn processLink(self: *Parser, content: []const u8, start: usize, base_off: OFF, is_image: bool) Parser.Error!?usize {
    _ = base_off;
    const bracket = matchBracket(self, content, start) orelse return null;
    const has_inner_bracket = bracket.has_inner_bracket;
    const label_end = bracket.close;
    const label = content[start + 1 .. label_end];
    var pos = label_end + 1;

    // Inline link: [text](url "title")
    if (pos < content.len and content[pos] == '(') {
        pos += 1;
        // Skip whitespace (including newlines from merged paragraph lines)
        while (pos < content.len and (helpers.isBlank(content[pos]) or content[pos] == '\n' or content[pos] == '\r')) pos += 1;

        // Parse destination
        var dest_start = pos;
        var dest_end = pos;
        var dest_valid = true;

        if (pos < content.len and content[pos] == '<') {
            // Angle-bracket destination (no newlines or unescaped '<' allowed)
            dest_start = pos + 1;
            pos += 1;
            var angle_valid = true;
            while (pos < content.len and content[pos] != '>') {
                if (content[pos] == '\n' or content[pos] == '\r' or content[pos] == '<') {
                    angle_valid = false;
                    break;
                }
                if (content[pos] == '\\' and pos + 1 < content.len) {
                    pos += 2;
                } else {
                    pos += 1;
                }
            }
            if (!angle_valid) return null;
            dest_end = pos;
            if (pos < content.len) pos += 1; // skip >
        } else {
            // Bare destination — balance parentheses with Bun/cmark's cap.
            var paren_depth: u32 = 0;
            while (pos < content.len and !helpers.isWhitespace(content[pos])) {
                if (content[pos] == '(') {
                    paren_depth += 1;
                    if (paren_depth > MAX_LINK_DEST_PAREN_DEPTH) {
                        dest_valid = false;
                        break;
                    }
                } else if (content[pos] == ')') {
                    if (paren_depth == 0) break;
                    paren_depth -= 1;
                }
                if (content[pos] == '\\' and pos + 1 < content.len) {
                    pos += 2;
                } else {
                    pos += 1;
                }
            }
            dest_end = pos;
        }

        if (!dest_valid) {
            // The overflowing '(' must not be reinterpreted as a title opener,
            // but reference and shortcut fallback below remain reachable.
            pos = content.len;
        }

        // Skip whitespace (including newlines)
        while (pos < content.len and (helpers.isBlank(content[pos]) or content[pos] == '\n' or content[pos] == '\r')) pos += 1;

        // Optional title
        var title: []const u8 = "";
        if (pos < content.len and (content[pos] == '"' or content[pos] == '\'' or content[pos] == '(')) {
            const close_char: u8 = if (content[pos] == '(') ')' else content[pos];
            const title_open = pos;
            pos += 1;
            const title_start = pos;
            var title_valid = true;
            while (pos < content.len and content[pos] != close_char) {
                if (content[pos] == '\\' and pos + 1 < content.len) {
                    pos += 2;
                    continue;
                }
                if (close_char == ')' and content[pos] == '(') {
                    title_valid = false;
                    break;
                }
                pos += 1;
            }
            if (title_valid) {
                title = content[title_start..pos];
                if (pos < content.len) pos += 1; // skip closing quote
            } else {
                pos = title_open;
            }
        }

        // Skip whitespace (including newlines)
        while (pos < content.len and (helpers.isBlank(content[pos]) or content[pos] == '\n' or content[pos] == '\r')) pos += 1;

        // Must end with ')'
        if (pos < content.len and content[pos] == ')') {
            pos += 1;
            const dest = content[dest_start..dest_end];

            // Link nesting prohibition: links cannot contain other links (CommonMark §6.7)
            if (!is_image and has_inner_bracket and self.labelContainsLink(label)) {
                return null;
            }

            if (self.image_nesting_level > 0) {
                // Inside image alt text — emit only text, no HTML tags
                try self.processInlineContent(label, 0);
            } else if (is_image) {
                try self.renderer.enterSpan(.img, .{ .href = dest, .title = title });
                self.image_nesting_level += 1;
                try self.processInlineContent(label, 0);
                self.image_nesting_level -= 1;
                try self.renderer.leaveSpan(.img);
            } else {
                try self.renderer.enterSpan(.a, .{ .href = dest, .title = title });
                self.link_nesting_level += 1;
                try self.processInlineContent(label, 0);
                self.link_nesting_level -= 1;
                try self.renderer.leaveSpan(.a);
            }

            return pos;
        }
    }

    // Reference link: [text][ref] or [text][] or shortcut [text]. A failed
    // inline parse may have advanced `pos` to a later '[', which is not an
    // adjacent reference label, so restore it to the byte after the label.
    pos = label_end + 1;
    if (pos < content.len and content[pos] == '[') {
        pos += 1;
        const ref_start = pos;
        while (pos < content.len and content[pos] != ']') {
            if (content[pos] == '[') break; // nested [ not allowed in ref
            if (content[pos] == '\\' and pos + 1 < content.len) {
                pos += 2;
            } else {
                pos += 1;
            }
        }
        if (pos < content.len and content[pos] == ']') {
            const ref_label = if (pos > ref_start) content[ref_start..pos] else label;
            pos += 1;
            if (self.lookupRefDef(ref_label)) |ref_def| {
                // Link nesting prohibition
                if (!is_image and has_inner_bracket and self.labelContainsLink(label)) {
                    return null;
                }
                if (!self.chargeRefDefOutput(ref_def.dest.len, ref_def.title.len)) return null;
                try self.renderRefLink(label, ref_def, is_image);
                return pos;
            }
        }
    }

    // Shortcut reference link: [text] (no following [)
    // Per CommonMark spec, shortcut refs must NOT be followed by [
    // Note: if followed by ( and inline link parsing failed above, still try shortcut
    const char_after_label: u8 = if (label_end + 1 < content.len) content[label_end + 1] else 0;
    if (char_after_label != '[') {
        if (self.lookupRefDef(label)) |ref_def| {
            // Link nesting prohibition
            if (!is_image and has_inner_bracket and self.labelContainsLink(label)) {
                return null;
            }
            if (!self.chargeRefDefOutput(ref_def.dest.len, ref_def.title.len)) return null;
            try self.renderRefLink(label, ref_def, is_image);
            return label_end + 1;
        }
    }

    return null;
}

/// Try to match a bracket pair starting at `start` and check if it forms a link.
/// Returns whether it's a link, where the label ends, and the full link end position.
pub fn tryMatchBracketLink(self: *Parser, content: []const u8, start: usize) struct { is_link: bool, label_end: usize, link_end: usize } {
    const bracket = matchBracket(self, content, start) orelse return .{ .is_link = false, .label_end = 0, .link_end = 0 };
    const label_end = bracket.close;
    const pos = label_end + 1;

    if (pos >= content.len) {
        // Shortcut reference check
        const inner_label = content[start + 1 .. label_end];
        const is_ref = self.lookupRefDef(inner_label) != null;
        return .{ .is_link = is_ref, .label_end = label_end, .link_end = label_end + 1 };
    }

    // Inline link: ](...)
    if (content[pos] == '(') {
        var p = pos + 1;
        // Skip whitespace
        while (p < content.len and (helpers.isBlank(content[p]) or content[p] == '\n' or content[p] == '\r')) p += 1;
        // Parse dest. The lookahead must use the same validity rules as
        // `processLink` or emphasis and nested-link decisions can diverge.
        if (p < content.len and content[p] == '<') {
            p += 1;
            while (p < content.len and content[p] != '>' and content[p] != '\n' and content[p] != '\r' and content[p] != '<') {
                if (content[p] == '\\' and p + 1 < content.len) {
                    p += 2;
                } else {
                    p += 1;
                }
            }
            if (p < content.len and content[p] == '>') p += 1 else return .{ .is_link = false, .label_end = label_end, .link_end = label_end + 1 };
        } else {
            var paren_depth: u32 = 0;
            while (p < content.len and !helpers.isWhitespace(content[p])) {
                if (content[p] == '(') {
                    paren_depth += 1;
                    if (paren_depth > MAX_LINK_DEST_PAREN_DEPTH) {
                        p = content.len;
                        break;
                    }
                } else if (content[p] == ')') {
                    if (paren_depth == 0) break;
                    paren_depth -= 1;
                }
                if (content[p] == '\\' and p + 1 < content.len) {
                    p += 2;
                } else {
                    p += 1;
                }
            }
        }
        // Skip whitespace
        while (p < content.len and (helpers.isBlank(content[p]) or content[p] == '\n' or content[p] == '\r')) p += 1;
        // Optional title
        if (p < content.len and (content[p] == '"' or content[p] == '\'' or content[p] == '(')) {
            const close_ch: u8 = if (content[p] == '(') ')' else content[p];
            const title_open = p;
            p += 1;
            var title_valid = true;
            while (p < content.len and content[p] != close_ch) {
                if (content[p] == '\\' and p + 1 < content.len) {
                    p += 2;
                    continue;
                }
                if (close_ch == ')' and content[p] == '(') {
                    title_valid = false;
                    break;
                }
                p += 1;
            }
            if (title_valid) {
                if (p < content.len) p += 1;
            } else {
                p = title_open;
            }
        }
        // Skip whitespace
        while (p < content.len and (helpers.isBlank(content[p]) or content[p] == '\n' or content[p] == '\r')) p += 1;
        if (p < content.len and content[p] == ')') {
            return .{ .is_link = true, .label_end = label_end, .link_end = p + 1 };
        }
    }

    // Reference link: ][...]
    if (content[pos] == '[') {
        var p = pos + 1;
        while (p < content.len and content[p] != ']') {
            if (content[p] == '[') break;
            if (content[p] == '\\' and p + 1 < content.len) {
                p += 2;
            } else {
                p += 1;
            }
        }
        if (p < content.len and content[p] == ']') {
            const ref_label = if (p > pos + 1) content[pos + 1 .. p] else content[start + 1 .. label_end];
            if (self.lookupRefDef(ref_label) != null) return .{ .is_link = true, .label_end = label_end, .link_end = p + 1 };
        }
    }

    // Shortcut references may not be followed by another '['.
    if (label_end + 1 >= content.len or content[label_end + 1] != '[') {
        const inner_label = content[start + 1 .. label_end];
        if (self.lookupRefDef(inner_label) != null) return .{ .is_link = true, .label_end = label_end, .link_end = label_end + 1 };
    }

    return .{ .is_link = false, .label_end = label_end, .link_end = label_end + 1 };
}

/// Check if a link label contains an inner link construct.
/// Used to enforce the "links cannot contain other links" rule (CommonMark §6.7).
pub fn labelContainsLink(self: *Parser, label: []const u8) bool {
    var pos: usize = 0;
    while (pos < label.len) {
        if (label[pos] == '\\' and pos + 1 < label.len) {
            pos += 2;
            continue;
        }
        // Skip code spans
        if (label[pos] == '`') {
            const count = inlines_mod.countBackticks(label, pos);
            if (self.findCodeSpanEnd(label, pos + count, count)) |end_pos| {
                pos = end_pos + count;
                continue;
            }
        }
        // Skip HTML tags and autolinks
        if (label[pos] == '<' and !self.flags.no_html_spans) {
            if (self.findHtmlTag(label, pos)) |tag_end| {
                pos = tag_end;
                continue;
            }
            if (self.findAutolink(label, pos)) |al| {
                pos = al.end_pos;
                continue;
            }
        }
        if (label[pos] == '[') {
            // Skip images (![...]) — images are allowed inside links
            const is_inner_image = pos > 0 and label[pos - 1] == '!';
            // Try to find matching ] and check for link syntax
            const inner = self.tryMatchBracketLink(label, pos);
            if (inner.is_link and !is_inner_image) return true;
            if (inner.link_end > pos) {
                // Skip past entire construct (including (url) or [ref] for images)
                pos = inner.link_end;
                continue;
            }
        }
        pos += 1;
    }
    return false;
}

/// Process wiki link: [[destination]] or [[destination|label]]
pub fn processWikiLink(self: *Parser, content: []const u8, start: usize) Parser.Error!?usize {
    // start points at first '[', next char is also '['
    var pos = start + 2;

    // Find closing ']]', checking for constraints
    const inner_start = pos;
    var pipe_pos: ?usize = null;
    var bracket_depth: u32 = 0;

    while (pos < content.len) {
        if (content[pos] == '\n' or content[pos] == '\r') {
            return null;
        }
        if (content[pos] == '[') {
            bracket_depth += 1;
            if (bracket_depth > MAX_WIKI_BRACKET_DEPTH) return null;
        } else if (content[pos] == ']') {
            if (bracket_depth > 0) {
                bracket_depth -= 1;
            } else if (pos + 1 < content.len and content[pos + 1] == ']') {
                break;
            } else {
                // Single ] without matching [, not a valid close
                return null;
            }
        } else if (content[pos] == '|' and pipe_pos == null and bracket_depth == 0) {
            pipe_pos = pos;
        }
        pos += 1;
    }

    // Must end with ]]
    if (pos >= content.len or content[pos] != ']') {
        return null;
    }

    const inner_end = pos;

    // Determine target and label
    const target = if (pipe_pos) |pp| content[inner_start..pp] else content[inner_start..inner_end];
    const label = if (pipe_pos) |pp| content[pp + 1 .. inner_end] else content[inner_start..inner_end];

    // Target must not exceed 100 characters
    if (target.len > 100) {
        return null;
    }

    // Render the wikilink
    try self.renderer.enterSpan(.wikilink, .{ .href = target });
    try self.processInlineContent(label, 0);
    try self.renderer.leaveSpan(.wikilink);

    return pos + 2; // skip both ']'
}

/// Render a reference link/image given the resolved ref def.
/// Charge one resolved reference link/image against the ref-def output budget.
/// On exhaustion the budget is zeroed so this and every later reference
/// degrades to literal text, bounding quadratic reference expansion on hostile
/// markdown (md4c, mity/md4c#238).
pub fn chargeRefDefOutput(self: *Parser, dest_len: usize, title_len: usize) bool {
    const n: u64 = @as(u64, dest_len) + @as(u64, title_len);
    if (n < self.max_ref_def_output) {
        self.max_ref_def_output -= n;
        return true;
    }
    self.max_ref_def_output = 0;
    return false;
}

pub fn renderRefLink(self: *Parser, label_content: []const u8, ref: RefDef, is_image: bool) Parser.Error!void {
    if (self.image_nesting_level > 0) {
        // Inside image alt text — emit only text, no HTML tags
        try self.processInlineContent(label_content, 0);
    } else if (is_image) {
        try self.renderer.enterSpan(.img, .{ .href = ref.dest, .title = ref.title });
        self.image_nesting_level += 1;
        try self.processInlineContent(label_content, 0);
        self.image_nesting_level -= 1;
        try self.renderer.leaveSpan(.img);
    } else {
        try self.renderer.enterSpan(.a, .{ .href = ref.dest, .title = ref.title });
        self.link_nesting_level += 1;
        try self.processInlineContent(label_content, 0);
        self.link_nesting_level -= 1;
        try self.renderer.leaveSpan(.a);
    }
}

pub fn findAutolink(self: *const Parser, content: []const u8, start: usize) ?struct { end_pos: usize, is_email: bool } {
    _ = self;
    if (start + 1 >= content.len) return null;

    const pos = start + 1;

    // Check for URI autolink: scheme://...
    if (helpers.isAlpha(content[pos])) {
        var scheme_end = pos;
        while (scheme_end < content.len and (helpers.isAlphaNum(content[scheme_end]) or
            content[scheme_end] == '+' or content[scheme_end] == '-' or content[scheme_end] == '.'))
        {
            scheme_end += 1;
        }
        const scheme_len = scheme_end - pos;
        if (scheme_len >= 2 and scheme_len <= 32 and scheme_end < content.len and content[scheme_end] == ':') {
            // URI autolink
            var uri_end = scheme_end + 1;
            while (uri_end < content.len and content[uri_end] != '>' and content[uri_end] != '<' and !helpers.isWhitespace(content[uri_end])) {
                uri_end += 1;
            }
            if (uri_end < content.len and content[uri_end] == '>') {
                return .{ .end_pos = uri_end + 1, .is_email = false };
            }
        }

        // Check for email autolink
        var email_pos = pos;
        // username part
        while (email_pos < content.len and (helpers.isAlphaNum(content[email_pos]) or
            content[email_pos] == '.' or content[email_pos] == '-' or
            content[email_pos] == '_' or content[email_pos] == '+'))
        {
            email_pos += 1;
        }
        if (email_pos < content.len and content[email_pos] == '@' and email_pos > pos) {
            email_pos += 1;
            // domain part: labels separated by '.', each 1-63 chars, alphanumeric or hyphen
            const domain_start = email_pos;
            var label_len: u32 = 0;
            var dot_count: u32 = 0;
            var valid_domain = true;
            while (email_pos < content.len and (helpers.isAlphaNum(content[email_pos]) or
                content[email_pos] == '.' or content[email_pos] == '-'))
            {
                if (content[email_pos] == '.') {
                    if (label_len == 0) {
                        valid_domain = false;
                        break;
                    }
                    label_len = 0;
                    dot_count += 1;
                } else {
                    label_len += 1;
                    if (label_len > 63) {
                        valid_domain = false;
                        break;
                    }
                }
                email_pos += 1;
            }
            if (valid_domain and email_pos < content.len and content[email_pos] == '>' and
                email_pos > domain_start and label_len > 0 and dot_count > 0 and
                helpers.isAlphaNum(content[email_pos - 1]))
            {
                return .{ .end_pos = email_pos + 1, .is_email = true };
            }
        }
    }

    return null;
}

pub fn renderAutolink(self: *Parser, url: []const u8, is_email: bool) bun.JSError!void {
    try self.renderer.enterSpan(.a, .{ .href = url, .autolink = true, .autolink_email = is_email });
    try self.emitText(.normal, url);
    try self.renderer.leaveSpan(.a);
}

const bun = @import("bun");
const helpers = @import("./helpers.zig");
const inlines_mod = @import("./inlines.zig");
const std = @import("std");

const parser_mod = @import("./parser.zig");
const Parser = parser_mod.Parser;

const ref_defs_mod = @import("./ref_defs.zig");
const RefDef = ref_defs_mod.RefDef;

const types = @import("./types.zig");
const OFF = types.OFF;
