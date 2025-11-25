const std = @import("std");
const DocParser = @import("parser.zig").DocParser;
const DocItem = DocParser.DocItem;

/// Advanced search indexer for documentation
///
/// Features:
/// - Full-text search with relevance scoring
/// - Fuzzy matching for typos
/// - TF-IDF scoring
/// - Autocomplete suggestions
/// - Tag-based filtering
pub const SearchIndexer = struct {
    allocator: std.mem.Allocator,
    documents: std.ArrayList(Document),
    word_index: std.StringHashMap(std.ArrayList(usize)),
    tf_idf_scores: std.AutoHashMap(usize, f32),

    pub const Document = struct {
        id: usize,
        name: []const u8,
        kind: []const u8,
        description: []const u8,
        tags: []const []const u8,
        signature: ?[]const u8,
        url: []const u8,
        search_content: []const u8, // Combined searchable content
    };

    pub const SearchResult = struct {
        document_id: usize,
        score: f32,
        matched_terms: []const []const u8,
        highlight_ranges: []const Range,

        pub const Range = struct {
            start: usize,
            end: usize,
        };
    };

    pub fn init(allocator: std.mem.Allocator) SearchIndexer {
        return .{
            .allocator = allocator,
            .documents = std.ArrayList(Document).init(allocator),
            .word_index = std.StringHashMap(std.ArrayList(usize)).init(allocator),
            .tf_idf_scores = std.AutoHashMap(usize, f32).init(allocator),
        };
    }

    pub fn deinit(self: *SearchIndexer) void {
        for (self.documents.items) |doc| {
            self.allocator.free(doc.name);
            self.allocator.free(doc.kind);
            self.allocator.free(doc.description);
            for (doc.tags) |tag| {
                self.allocator.free(tag);
            }
            self.allocator.free(doc.tags);
            if (doc.signature) |sig| {
                self.allocator.free(sig);
            }
            self.allocator.free(doc.url);
            self.allocator.free(doc.search_content);
        }
        self.documents.deinit();

        var it = self.word_index.valueIterator();
        while (it.next()) |list| {
            list.deinit();
        }
        self.word_index.deinit();
        self.tf_idf_scores.deinit();
    }

    /// Build search index from documentation items
    pub fn buildIndex(self: *SearchIndexer, items: []const DocItem) !void {
        for (items, 0..) |item, i| {
            const doc = try self.createDocument(item, i);
            try self.documents.append(doc);

            // Index all words in the document
            try self.indexDocument(doc);
        }

        // Calculate TF-IDF scores
        try self.calculateTFIDF();
    }

    fn createDocument(self: *SearchIndexer, item: DocItem, id: usize) !Document {
        // Collect tags
        var tags_list = std.ArrayList([]const u8).init(self.allocator);
        var tag_it = item.tags.iterator();
        while (tag_it.next()) |entry| {
            try tags_list.append(try self.allocator.dupe(u8, entry.key_ptr.*));
        }

        // Build searchable content (lowercase for case-insensitive search)
        var content = std.ArrayList(u8).init(self.allocator);
        defer content.deinit();

        try content.appendSlice(item.name);
        try content.append(' ');
        try content.appendSlice(item.description);
        try content.append(' ');

        if (item.signature) |sig| {
            try content.appendSlice(sig);
            try content.append(' ');
        }

        for (item.params) |param| {
            try content.appendSlice(param.name);
            try content.append(' ');
            try content.appendSlice(param.description);
            try content.append(' ');
        }

        const lowercase_content = try self.allocator.alloc(u8, content.items.len);
        _ = std.ascii.lowerString(lowercase_content, content.items);

        return Document{
            .id = id,
            .name = try self.allocator.dupe(u8, item.name),
            .kind = try self.allocator.dupe(u8, @tagName(item.kind)),
            .description = try self.allocator.dupe(u8, item.description),
            .tags = try tags_list.toOwnedSlice(),
            .signature = if (item.signature) |sig| try self.allocator.dupe(u8, sig) else null,
            .url = try std.fmt.allocPrint(self.allocator, "{s}.html", .{item.name}),
            .search_content = lowercase_content,
        };
    }

    fn indexDocument(self: *SearchIndexer, doc: Document) !void {
        // Tokenize content into words
        var it = std.mem.tokenizeAny(u8, doc.search_content, " \t\n\r.,;:()[]{}\"'<>");
        while (it.next()) |word| {
            if (word.len < 2) continue; // Skip very short words

            var result = try self.word_index.getOrPut(word);
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayList(usize).init(self.allocator);
                result.key_ptr.* = try self.allocator.dupe(u8, word);
            }

            // Add document ID to this word's posting list
            try result.value_ptr.append(doc.id);
        }
    }

    fn calculateTFIDF(self: *SearchIndexer) !void {
        const total_docs: f32 = @floatFromInt(self.documents.items.len);

        var word_it = self.word_index.iterator();
        while (word_it.next()) |entry| {
            const word = entry.key_ptr.*;
            const doc_ids = entry.value_ptr.*;

            // Calculate IDF (inverse document frequency)
            const docs_with_word: f32 = @floatFromInt(doc_ids.items.len);
            const idf = @log(total_docs / docs_with_word);

            // Calculate TF-IDF for each document
            for (doc_ids.items) |doc_id| {
                const doc = self.documents.items[doc_id];

                // Calculate TF (term frequency)
                var count: usize = 0;
                var it = std.mem.tokenizeAny(u8, doc.search_content, " \t\n\r.,;:()[]{}\"'<>");
                while (it.next()) |token| {
                    if (std.mem.eql(u8, token, word)) {
                        count += 1;
                    }
                }

                const tf: f32 = @floatFromInt(count);
                const tf_idf = tf * idf;

                // Store score (simplified: using word hash as key)
                const key = std.hash.Wyhash.hash(doc_id, word);
                try self.tf_idf_scores.put(@truncate(key), tf_idf);
            }
        }
    }

    /// Search for documents matching the query
    pub fn search(self: *SearchIndexer, query: []const u8, max_results: usize) ![]SearchResult {
        // Normalize query to lowercase
        const lowercase_query = try self.allocator.alloc(u8, query.len);
        defer self.allocator.free(lowercase_query);
        _ = std.ascii.lowerString(lowercase_query, query);

        // Tokenize query
        var query_terms = std.ArrayList([]const u8).init(self.allocator);
        defer query_terms.deinit();

        var it = std.mem.tokenizeAny(u8, lowercase_query, " \t\n\r");
        while (it.next()) |term| {
            if (term.len >= 2) {
                try query_terms.append(term);
            }
        }

        if (query_terms.items.len == 0) {
            return &[_]SearchResult{};
        }

        // Score each document
        var scores = std.AutoHashMap(usize, f32).init(self.allocator);
        defer scores.deinit();

        for (query_terms.items) |term| {
            if (self.word_index.get(term)) |doc_ids| {
                for (doc_ids.items) |doc_id| {
                    const result = try scores.getOrPut(doc_id);
                    if (!result.found_existing) {
                        result.value_ptr.* = 0.0;
                    }

                    // Add TF-IDF score
                    const key = std.hash.Wyhash.hash(doc_id, term);
                    if (self.tf_idf_scores.get(@truncate(key))) |score| {
                        result.value_ptr.* += score;
                    }

                    // Boost score if term is in name (exact match)
                    const doc = self.documents.items[doc_id];
                    if (std.mem.indexOf(u8, doc.name, term) != null) {
                        result.value_ptr.* *= 2.0;
                    }
                }
            }

            // Fuzzy matching for potential typos
            try self.addFuzzyMatches(term, &scores);
        }

        // Convert to results array and sort by score
        var results = std.ArrayList(SearchResult).init(self.allocator);
        defer results.deinit();

        var score_it = scores.iterator();
        while (score_it.next()) |entry| {
            try results.append(SearchResult{
                .document_id = entry.key_ptr.*,
                .score = entry.value_ptr.*,
                .matched_terms = try self.allocator.dupe([]const u8, query_terms.items),
                .highlight_ranges = &[_]SearchResult.Range{},
            });
        }

        // Sort by score (descending)
        std.mem.sort(SearchResult, results.items, {}, struct {
            fn lessThan(_: void, a: SearchResult, b: SearchResult) bool {
                return a.score > b.score;
            }
        }.lessThan);

        // Limit results
        const limit = @min(max_results, results.items.len);
        return try self.allocator.dupe(SearchResult, results.items[0..limit]);
    }

    fn addFuzzyMatches(self: *SearchIndexer, term: []const u8, scores: *std.AutoHashMap(usize, f32)) !void {
        var word_it = self.word_index.iterator();
        while (word_it.next()) |entry| {
            const word = entry.key_ptr.*;
            const doc_ids = entry.value_ptr.*;

            // Calculate edit distance (Levenshtein distance)
            const distance = try self.editDistance(term, word);

            // If edit distance is small, add with reduced score
            if (distance <= 2 and term.len >= 4) {
                const penalty: f32 = @floatFromInt(distance);
                const fuzzy_score = 0.5 / (1.0 + penalty);

                for (doc_ids.items) |doc_id| {
                    const result = try scores.getOrPut(doc_id);
                    if (!result.found_existing) {
                        result.value_ptr.* = 0.0;
                    }
                    result.value_ptr.* += fuzzy_score;
                }
            }
        }
    }

    fn editDistance(self: *SearchIndexer, a: []const u8, b: []const u8) !usize {
        _ = self;

        if (a.len == 0) return b.len;
        if (b.len == 0) return a.len;

        // Simplified Levenshtein distance (dynamic programming)
        const len_a = a.len + 1;
        const len_b = b.len + 1;

        // Only allocate for small strings to avoid memory issues
        if (len_a > 100 or len_b > 100) return 999;

        var matrix = try self.allocator.alloc(usize, len_a * len_b);
        defer self.allocator.free(matrix);

        // Initialize first row and column
        for (0..len_a) |i| {
            matrix[i * len_b] = i;
        }
        for (0..len_b) |j| {
            matrix[j] = j;
        }

        // Fill matrix
        for (1..len_a) |i| {
            for (1..len_b) |j| {
                const cost: usize = if (a[i - 1] == b[j - 1]) 0 else 1;

                const deletion = matrix[(i - 1) * len_b + j] + 1;
                const insertion = matrix[i * len_b + (j - 1)] + 1;
                const substitution = matrix[(i - 1) * len_b + (j - 1)] + cost;

                matrix[i * len_b + j] = @min(deletion, @min(insertion, substitution));
            }
        }

        return matrix[(len_a - 1) * len_b + (len_b - 1)];
    }

    /// Get autocomplete suggestions
    pub fn autocomplete(self: *SearchIndexer, prefix: []const u8, max_suggestions: usize) ![][]const u8 {
        const lowercase_prefix = try self.allocator.alloc(u8, prefix.len);
        defer self.allocator.free(lowercase_prefix);
        _ = std.ascii.lowerString(lowercase_prefix, prefix);

        var suggestions = std.ArrayList([]const u8).init(self.allocator);
        defer suggestions.deinit();

        // Find words starting with prefix
        var word_it = self.word_index.iterator();
        while (word_it.next()) |entry| {
            const word = entry.key_ptr.*;

            if (std.mem.startsWith(u8, word, lowercase_prefix)) {
                try suggestions.append(try self.allocator.dupe(u8, word));

                if (suggestions.items.len >= max_suggestions) break;
            }
        }

        // Sort suggestions alphabetically
        std.mem.sort([]const u8, suggestions.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        return suggestions.toOwnedSlice();
    }

    /// Export search index to JSON
    pub fn exportToJSON(self: *SearchIndexer) ![]u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        errdefer buffer.deinit();

        const writer = buffer.writer();

        try writer.writeAll("{\"documents\":[");

        for (self.documents.items, 0..) |doc, i| {
            if (i > 0) try writer.writeAll(",");

            try writer.writeAll("{");
            try writer.print("\"id\":{d},", .{doc.id});
            try writer.print("\"name\":\"{s}\",", .{self.escapeJSON(doc.name)});
            try writer.print("\"kind\":\"{s}\",", .{doc.kind});
            try writer.print("\"description\":\"{s}\",", .{self.escapeJSON(doc.description)});
            try writer.print("\"url\":\"{s}\",", .{doc.url});

            try writer.writeAll("\"tags\":[");
            for (doc.tags, 0..) |tag, j| {
                if (j > 0) try writer.writeAll(",");
                try writer.print("\"{s}\"", .{tag});
            }
            try writer.writeAll("]");

            try writer.writeAll("}");
        }

        try writer.writeAll("]}");

        return buffer.toOwnedSlice();
    }

    fn escapeJSON(self: *SearchIndexer, str: []const u8) []const u8 {
        _ = self;
        // Simplified: in production would handle all JSON special chars
        return str;
    }
};

/// Search UI generator for JavaScript
pub const SearchUIGenerator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SearchUIGenerator {
        return .{ .allocator = allocator };
    }

    /// Generate enhanced search JavaScript
    pub fn generateSearchJS(self: *SearchUIGenerator) ![]u8 {
        _ = self;

        return
            \\// Enhanced search functionality with fuzzy matching and autocomplete
            \\let searchIndex = [];
            \\let searchInput = null;
            \\let resultsContainer = null;
            \\let autocompleteContainer = null;
            \\
            \\// Load search index
            \\fetch('search-index.json')
            \\  .then(r => r.json())
            \\  .then(data => {
            \\    searchIndex = data.documents;
            \\    initializeSearch();
            \\  });
            \\
            \\function initializeSearch() {
            \\  searchInput = document.getElementById('search');
            \\  resultsContainer = document.getElementById('search-results');
            \\  autocompleteContainer = document.getElementById('autocomplete');
            \\
            \\  if (!searchInput) return;
            \\
            \\  // Search on input
            \\  searchInput.addEventListener('input', debounce(handleSearch, 300));
            \\
            \\  // Autocomplete on keyup
            \\  searchInput.addEventListener('keyup', debounce(handleAutocomplete, 200));
            \\
            \\  // Clear on escape
            \\  searchInput.addEventListener('keydown', (e) => {
            \\    if (e.key === 'Escape') {
            \\      clearSearch();
            \\    }
            \\  });
            \\}
            \\
            \\function handleSearch() {
            \\  const query = searchInput.value.trim().toLowerCase();
            \\
            \\  if (!query) {
            \\    clearSearch();
            \\    return;
            \\  }
            \\
            \\  const results = search(query);
            \\  displayResults(results, query);
            \\}
            \\
            \\function search(query) {
            \\  const terms = query.split(/\s+/).filter(t => t.length >= 2);
            \\  if (terms.length === 0) return [];
            \\
            \\  const scores = new Map();
            \\
            \\  searchIndex.forEach(doc => {
            \\    let score = 0;
            \\
            \\    terms.forEach(term => {
            \\      // Exact match in name (highest score)
            \\      if (doc.name.toLowerCase().includes(term)) {
            \\        score += 10;
            \\      }
            \\
            \\      // Match in description
            \\      if (doc.description.toLowerCase().includes(term)) {
            \\        score += 5;
            \\      }
            \\
            \\      // Match in kind
            \\      if (doc.kind.toLowerCase().includes(term)) {
            \\        score += 3;
            \\      }
            \\
            \\      // Fuzzy match (Levenshtein distance <= 2)
            \\      const nameWords = doc.name.toLowerCase().split(/[^a-z0-9]+/);
            \\      nameWords.forEach(word => {
            \\        const distance = levenshtein(term, word);
            \\        if (distance <= 2 && term.length >= 4) {
            \\          score += Math.max(0, 2 - distance);
            \\        }
            \\      });
            \\    });
            \\
            \\    if (score > 0) {
            \\      scores.set(doc, score);
            \\    }
            \\  });
            \\
            \\  return Array.from(scores.entries())
            \\    .sort((a, b) => b[1] - a[1])
            \\    .slice(0, 10)
            \\    .map(([doc, score]) => ({ doc, score }));
            \\}
            \\
            \\function displayResults(results, query) {
            \\  if (results.length === 0) {
            \\    resultsContainer.innerHTML = '<div class="no-results">No results found</div>';
            \\    return;
            \\  }
            \\
            \\  resultsContainer.innerHTML = results.map(({ doc, score }) => {
            \\    const highlighted = highlightMatches(doc.description, query);
            \\    return `
            \\      <div class="search-result" data-score="${score}">
            \\        <a href="${doc.url}">
            \\          <strong>${doc.name}</strong>
            \\          <span class="kind">${doc.kind}</span>
            \\        </a>
            \\        <p>${highlighted.slice(0, 150)}${highlighted.length > 150 ? '...' : ''}</p>
            \\      </div>
            \\    `;
            \\  }).join('');
            \\}
            \\
            \\function highlightMatches(text, query) {
            \\  const terms = query.split(/\s+/).filter(t => t.length >= 2);
            \\  let result = text;
            \\
            \\  terms.forEach(term => {
            \\    const regex = new RegExp(`(${escapeRegex(term)})`, 'gi');
            \\    result = result.replace(regex, '<mark>$1</mark>');
            \\  });
            \\
            \\  return result;
            \\}
            \\
            \\function handleAutocomplete() {
            \\  const query = searchInput.value.trim();
            \\
            \\  if (query.length < 2) {
            \\    autocompleteContainer.innerHTML = '';
            \\    return;
            \\  }
            \\
            \\  const suggestions = getSuggestions(query);
            \\  displaySuggestions(suggestions);
            \\}
            \\
            \\function getSuggestions(prefix) {
            \\  const lowerPrefix = prefix.toLowerCase();
            \\  const suggestions = new Set();
            \\
            \\  searchIndex.forEach(doc => {
            \\    if (doc.name.toLowerCase().startsWith(lowerPrefix)) {
            \\      suggestions.add(doc.name);
            \\    }
            \\
            \\    // Also suggest from description words
            \\    const words = doc.description.toLowerCase().split(/\s+/);
            \\    words.forEach(word => {
            \\      if (word.startsWith(lowerPrefix) && word.length >= prefix.length) {
            \\        suggestions.add(word);
            \\      }
            \\    });
            \\  });
            \\
            \\  return Array.from(suggestions).slice(0, 5);
            \\}
            \\
            \\function displaySuggestions(suggestions) {
            \\  if (suggestions.length === 0) {
            \\    autocompleteContainer.innerHTML = '';
            \\    return;
            \\  }
            \\
            \\  autocompleteContainer.innerHTML = suggestions.map(s =>
            \\    `<div class="suggestion" onclick="fillSearch('${s}')">${s}</div>`
            \\  ).join('');
            \\}
            \\
            \\function fillSearch(text) {
            \\  searchInput.value = text;
            \\  handleSearch();
            \\  autocompleteContainer.innerHTML = '';
            \\}
            \\
            \\function clearSearch() {
            \\  resultsContainer.innerHTML = '';
            \\  autocompleteContainer.innerHTML = '';
            \\}
            \\
            \\// Levenshtein distance for fuzzy matching
            \\function levenshtein(a, b) {
            \\  if (a.length === 0) return b.length;
            \\  if (b.length === 0) return a.length;
            \\
            \\  const matrix = Array(a.length + 1).fill(null).map(() =>
            \\    Array(b.length + 1).fill(0)
            \\  );
            \\
            \\  for (let i = 0; i <= a.length; i++) matrix[i][0] = i;
            \\  for (let j = 0; j <= b.length; j++) matrix[0][j] = j;
            \\
            \\  for (let i = 1; i <= a.length; i++) {
            \\    for (let j = 1; j <= b.length; j++) {
            \\      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
            \\      matrix[i][j] = Math.min(
            \\        matrix[i - 1][j] + 1,
            \\        matrix[i][j - 1] + 1,
            \\        matrix[i - 1][j - 1] + cost
            \\      );
            \\    }
            \\  }
            \\
            \\  return matrix[a.length][b.length];
            \\}
            \\
            \\function debounce(func, wait) {
            \\  let timeout;
            \\  return function(...args) {
            \\    clearTimeout(timeout);
            \\    timeout = setTimeout(() => func.apply(this, args), wait);
            \\  };
            \\}
            \\
            \\function escapeRegex(str) {
            \\  return str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
            \\}
            \\
        ;
    }
};
