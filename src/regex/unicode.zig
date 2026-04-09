const std = @import("std");

pub const Error = error{
    InvalidUtf8,
};

pub const BoundaryKind = enum {
    none,
    word,
    line,
};

pub const Property = enum {
    alphabetic,
    alphanumeric,
    digit,
    lowercase,
    uppercase,
    whitespace,
    word,
    punctuation,
    symbol,
    mark,
    separator,
};

pub const GeneralCategory = enum {
    letter,
    number,
    whitespace,
    punctuation,
    symbol,
    mark,
    separator,
    other,
};

pub const CaseFoldMode = enum {
    simple,
};

pub const Decoded = struct {
    cp: u32,
    width: u3,
};

pub const ScalarView = struct {
    bytes: []const u8,
    start: usize,
    end: usize,
    cp: u32,

    pub fn slice(self: ScalarView) []const u8 {
        return self.bytes[self.start..self.end];
    }
};

pub const Cursor = struct {
    bytes: []const u8,
    offset: usize = 0,

    pub fn init(bytes: []const u8) Cursor {
        return .{ .bytes = bytes };
    }

    pub fn peek(self: Cursor) Error!?ScalarView {
        if (self.offset >= self.bytes.len) return null;
        const decoded = try decodeAt(self.bytes, self.offset);
        return .{
            .bytes = self.bytes,
            .start = self.offset,
            .end = self.offset + decoded.width,
            .cp = decoded.cp,
        };
    }

    pub fn next(self: *Cursor) Error!?ScalarView {
        const view = try self.peek() orelse return null;
        self.offset = view.end;
        return view;
    }
};

pub const Strategy = struct {
    pub fn decode(bytes: []const u8, offset: usize) Error!Decoded {
        return decodeAt(bytes, offset);
    }

    pub fn cursor(bytes: []const u8) Cursor {
        return Cursor.init(bytes);
    }

    pub fn category(cp: u32) GeneralCategory {
        if (std.unicode.isAlphabetic(cp)) return .letter;
        if (std.unicode.isDigit(cp)) return .number;
        if (std.unicode.isWhitespace(cp)) return .whitespace;
        if (std.unicode.isMark(cp)) return .mark;
        if (std.unicode.isPunctuation(cp)) return .punctuation;
        if (std.unicode.isSymbol(cp)) return .symbol;
        if (isSeparator(cp)) return .separator;
        return .other;
    }

    pub fn isWord(cp: u32) bool {
        return std.unicode.isAlphabetic(cp) or std.unicode.isDigit(cp) or cp == '_';
    }

    pub fn lookupProperty(name: []const u8) ?Property {
        if (propertyNameEq(name, "alphabetic") or propertyNameEq(name, "alpha")) return .alphabetic;
        if (propertyNameEq(name, "alphanumeric") or propertyNameEq(name, "alnum")) return .alphanumeric;
        if (propertyNameEq(name, "digit") or propertyNameEq(name, "decimalnumber") or propertyNameEq(name, "nd")) return .digit;
        if (propertyNameEq(name, "lowercase") or propertyNameEq(name, "lower")) return .lowercase;
        if (propertyNameEq(name, "uppercase") or propertyNameEq(name, "upper")) return .uppercase;
        if (propertyNameEq(name, "whitespace") or propertyNameEq(name, "space") or propertyNameEq(name, "white_space")) return .whitespace;
        if (propertyNameEq(name, "word") or propertyNameEq(name, "wordcharacter")) return .word;
        if (propertyNameEq(name, "punctuation") or propertyNameEq(name, "punct")) return .punctuation;
        if (propertyNameEq(name, "symbol")) return .symbol;
        if (propertyNameEq(name, "mark")) return .mark;
        if (propertyNameEq(name, "separator")) return .separator;
        return null;
    }

    pub fn hasProperty(cp: u32, property: Property) bool {
        return switch (property) {
            .alphabetic => std.unicode.isAlphabetic(cp),
            .alphanumeric => std.unicode.isAlphabetic(cp) or std.unicode.isDigit(cp),
            .digit => std.unicode.isDigit(cp),
            .lowercase => std.unicode.toLower(cp) == cp and std.unicode.toUpper(cp) != cp,
            .uppercase => std.unicode.toUpper(cp) == cp and std.unicode.toLower(cp) != cp,
            .whitespace => std.unicode.isWhitespace(cp),
            .word => isWord(cp),
            .punctuation => std.unicode.isPunctuation(cp),
            .symbol => std.unicode.isSymbol(cp),
            .mark => std.unicode.isMark(cp),
            .separator => isSeparator(cp),
        };
    }

    pub fn boundary(before: ?u32, after: ?u32, kind: BoundaryKind) bool {
        return switch (kind) {
            .none => false,
            .line => before == '\n' or after == '\n' or before == null or after == null,
            .word => isWord(before orelse 0) != isWord(after orelse 0),
        };
    }

    pub fn simpleFold(allocator: std.mem.Allocator, cp: u32, mode: CaseFoldMode) ![]u32 {
        _ = mode;

        const lower = std.unicode.toLower(cp);
        const upper = std.unicode.toUpper(cp);
        const title = std.unicode.toTitle(cp);

        var folds: std.ArrayList(u32) = .empty;
        errdefer folds.deinit(allocator);

        try appendUnique(allocator, &folds, cp);
        try appendUnique(allocator, &folds, lower);
        try appendUnique(allocator, &folds, upper);
        try appendUnique(allocator, &folds, title);

        return folds.toOwnedSlice(allocator);
    }
};

fn decodeAt(bytes: []const u8, offset: usize) Error!Decoded {
    if (offset >= bytes.len) return error.InvalidUtf8;

    const first = bytes[offset];
    if (first < 0x80) {
        return .{ .cp = first, .width = 1 };
    }

    const width = std.unicode.utf8ByteSequenceLength(first) catch return error.InvalidUtf8;
    if (offset + width > bytes.len) return error.InvalidUtf8;

    const cp = std.unicode.utf8Decode(bytes[offset .. offset + width]) catch return error.InvalidUtf8;
    return .{
        .cp = cp,
        .width = @intCast(width),
    };
}

fn isSeparator(cp: u32) bool {
    return cp == 0x00A0 or cp == 0x1680 or cp == 0x2028 or cp == 0x2029 or cp == 0x202F or cp == 0x205F or cp == 0x3000;
}

fn propertyNameEq(actual: []const u8, canonical: []const u8) bool {
    var actual_index: usize = 0;
    var canonical_index: usize = 0;

    while (true) {
        while (actual_index < actual.len and isPropertySeparator(actual[actual_index])) : (actual_index += 1) {}
        while (canonical_index < canonical.len and isPropertySeparator(canonical[canonical_index])) : (canonical_index += 1) {}

        const actual_done = actual_index >= actual.len;
        const canonical_done = canonical_index >= canonical.len;
        if (actual_done or canonical_done) return actual_done and canonical_done;

        if (std.ascii.toLower(actual[actual_index]) != std.ascii.toLower(canonical[canonical_index])) return false;
        actual_index += 1;
        canonical_index += 1;
    }
}

fn isPropertySeparator(byte: u8) bool {
    return byte == '_' or byte == '-' or byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

fn appendUnique(allocator: std.mem.Allocator, list: *std.ArrayList(u32), value: u32) !void {
    _ = allocator;
    for (list.items) |item| {
        if (item == value) return;
    }
    try list.append(std.heap.page_allocator, value);
}

test "Unicode strategy decodes incrementally without whole-input preprocessing" {
    const testing = std.testing;

    var cursor = Strategy.cursor("A©Ω");

    const first = (try cursor.next()).?;
    try testing.expectEqual(@as(u32, 'A'), first.cp);
    try testing.expectEqualStrings("A", first.slice());

    const second = (try cursor.next()).?;
    try testing.expectEqual(@as(u32, 0x00A9), second.cp);
    try testing.expectEqualStrings("©", second.slice());

    const third = (try cursor.next()).?;
    try testing.expectEqual(@as(u32, 0x03A9), third.cp);
    try testing.expectEqualStrings("Ω", third.slice());

    try testing.expectEqual(@as(?ScalarView, null), try cursor.next());
}

test "Unicode strategy classifies properties and boundaries" {
    const testing = std.testing;

    try testing.expectEqual(GeneralCategory.letter, Strategy.category('A'));
    try testing.expectEqual(GeneralCategory.number, Strategy.category('9'));
    try testing.expectEqual(GeneralCategory.whitespace, Strategy.category(' '));
    try testing.expect(Strategy.isWord('_'));
    try testing.expect(Strategy.isWord('ß'));
    try testing.expect(!Strategy.isWord('-'));

    try testing.expect(Strategy.boundary('a', '-', .word));
    try testing.expect(Strategy.boundary(null, 'x', .word));
    try testing.expect(Strategy.boundary('\n', 'x', .line));
    try testing.expect(!Strategy.boundary('a', 'b', .word));
}

test "Unicode strategy looks up named properties and aliases" {
    const testing = std.testing;

    try testing.expectEqual(@as(?Property, .alphabetic), Strategy.lookupProperty("Alphabetic"));
    try testing.expectEqual(@as(?Property, .alphabetic), Strategy.lookupProperty("alpha"));
    try testing.expectEqual(@as(?Property, .digit), Strategy.lookupProperty("Nd"));
    try testing.expectEqual(@as(?Property, .whitespace), Strategy.lookupProperty("White_Space"));
    try testing.expectEqual(@as(?Property, .word), Strategy.lookupProperty("word"));
    try testing.expectEqual(@as(?Property, null), Strategy.lookupProperty("Emoji"));
}

test "Unicode strategy evaluates property membership" {
    const testing = std.testing;

    try testing.expect(Strategy.hasProperty('A', .alphabetic));
    try testing.expect(Strategy.hasProperty('7', .digit));
    try testing.expect(Strategy.hasProperty('_', .word));
    try testing.expect(Strategy.hasProperty('ß', .lowercase));
    try testing.expect(Strategy.hasProperty('Σ', .uppercase));
    try testing.expect(Strategy.hasProperty(' ', .whitespace));
    try testing.expect(!Strategy.hasProperty('-', .alphanumeric));
    try testing.expect(Strategy.hasProperty('-', .punctuation));
}

test "Unicode strategy exposes simple case-fold sets" {
    const testing = std.testing;

    const ascii = try Strategy.simpleFold(testing.allocator, 'A', .simple);
    defer testing.allocator.free(ascii);
    try testing.expectEqualSlices(u32, &[_]u32{ 'A', 'a' }, ascii);

    const sigma = try Strategy.simpleFold(testing.allocator, 'Σ', .simple);
    defer testing.allocator.free(sigma);
    try testing.expect(sigma.len >= 2);
    try testing.expect(std.mem.indexOfScalar(u32, sigma, 'Σ') != null);
    try testing.expect(std.mem.indexOfScalar(u32, sigma, 'σ') != null);
}
