const std = @import("std");
const generated = @import("unicode_props_generated.zig");

pub const Error = error{
    InvalidUtf8,
};

pub const BoundaryKind = enum {
    none,
    word,
    line,
};

pub const Property = enum {
    letter,
    number,
    whitespace,
    alphabetic,
    lowercase,
    uppercase,
    mark,
    punctuation,
    separator,
    symbol,
};

pub const GeneralCategory = enum {
    letter,
    number,
    whitespace,
    other,
};

pub const CaseFoldMode = enum {
    simple,
};

pub const CaseFold = struct {
    canonical: u32,
    equivalents: []u32,

    pub fn deinit(self: CaseFold, allocator: std.mem.Allocator) void {
        allocator.free(self.equivalents);
    }
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
        if (inRanges(cp, &generated.letter_ranges)) return .letter;
        if (inRanges(cp, &generated.number_ranges)) return .number;
        if (inRanges(cp, &generated.whitespace_ranges)) return .whitespace;
        return .other;
    }

    pub fn isWord(cp: u32) bool {
        return cp <= 0x7f and (std.ascii.isAlphanumeric(@intCast(cp)) or cp == '_');
    }

    pub fn lookupProperty(name: []const u8) ?Property {
        if (propertyNameEq(name, "letter") or propertyNameEq(name, "l")) return .letter;
        if (propertyNameEq(name, "number") or propertyNameEq(name, "n")) return .number;
        if (propertyNameEq(name, "whitespace") or propertyNameEq(name, "space") or propertyNameEq(name, "white_space")) return .whitespace;
        if (propertyNameEq(name, "alphabetic") or propertyNameEq(name, "alpha")) return .alphabetic;
        if (propertyNameEq(name, "lowercase") or propertyNameEq(name, "lower") or propertyNameEq(name, "ll")) return .lowercase;
        if (propertyNameEq(name, "mark") or propertyNameEq(name, "m")) return .mark;
        if (propertyNameEq(name, "punctuation") or propertyNameEq(name, "punct") or propertyNameEq(name, "p")) return .punctuation;
        if (propertyNameEq(name, "separator") or propertyNameEq(name, "z")) return .separator;
        if (propertyNameEq(name, "symbol") or propertyNameEq(name, "s")) return .symbol;
        if (propertyNameEq(name, "uppercase") or propertyNameEq(name, "upper") or propertyNameEq(name, "lu")) return .uppercase;
        return null;
    }

    pub fn hasProperty(cp: u32, property: Property) bool {
        return switch (property) {
            .letter => inRanges(cp, &generated.letter_ranges),
            .number => inRanges(cp, &generated.number_ranges),
            .whitespace => inRanges(cp, &generated.whitespace_ranges),
            .alphabetic => inRanges(cp, &generated.alphabetic_ranges),
            .lowercase => inRanges(cp, &generated.lowercase_ranges),
            .mark => inRanges(cp, &generated.mark_ranges),
            .punctuation => inRanges(cp, &generated.punctuation_ranges),
            .separator => inRanges(cp, &generated.separator_ranges),
            .symbol => inRanges(cp, &generated.symbol_ranges),
            .uppercase => inRanges(cp, &generated.uppercase_ranges),
        };
    }

    pub fn boundary(before: ?u32, after: ?u32, kind: BoundaryKind) bool {
        return switch (kind) {
            .none => false,
            .line => before == '\n' or after == '\n' or before == null or after == null,
            .word => isWord(before orelse 0) != isWord(after orelse 0),
        };
    }

    pub fn boundaryAt(bytes: []const u8, offset: usize, kind: BoundaryKind) Error!bool {
        if (offset > bytes.len) return error.InvalidUtf8;
        const before = try scalarBefore(bytes, offset);
        const after = try scalarAtOrAfter(bytes, offset);
        return boundary(before, after, kind);
    }

    pub fn lineStart(bytes: []const u8, offset: usize) Error!bool {
        if (offset > bytes.len) return error.InvalidUtf8;
        const before = try scalarBefore(bytes, offset);
        return before == null or before.? == '\n';
    }

    pub fn lineEnd(bytes: []const u8, offset: usize) Error!bool {
        if (offset > bytes.len) return error.InvalidUtf8;
        const after = try scalarAtOrAfter(bytes, offset);
        return after == null or after.? == '\n';
    }

    pub fn foldScalar(cp: u32, mode: CaseFoldMode) u32 {
        return switch (mode) {
            .simple => foldScalarSimple(cp),
        };
    }

    pub fn foldedEq(a: u32, b: u32, mode: CaseFoldMode) bool {
        return foldScalar(a, mode) == foldScalar(b, mode);
    }

    pub fn foldSet(allocator: std.mem.Allocator, cp: u32, mode: CaseFoldMode) !CaseFold {
        const canonical = foldScalar(cp, mode);

        var folds: std.ArrayList(u32) = .empty;
        errdefer folds.deinit(allocator);

        try appendUnique(allocator, &folds, cp);
        try appendUnique(allocator, &folds, canonical);

        const lower = foldScalar(simpleLower(cp), mode);
        const upper = foldScalar(simpleUpper(cp), mode);
        const title = foldScalar(simpleUpper(cp), mode);

        try appendUnique(allocator, &folds, lower);
        try appendUnique(allocator, &folds, upper);
        try appendUnique(allocator, &folds, title);
        if (canonical == 'σ') {
            try appendUnique(allocator, &folds, 'ς');
        }

        return .{
            .canonical = canonical,
            .equivalents = try folds.toOwnedSlice(allocator),
        };
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

fn scalarAtOrAfter(bytes: []const u8, offset: usize) Error!?u32 {
    if (offset == bytes.len) return null;
    const decoded = try decodeAt(bytes, offset);
    return decoded.cp;
}

fn scalarBefore(bytes: []const u8, offset: usize) Error!?u32 {
    if (offset == 0) return null;

    var start = offset - 1;
    var steps: u8 = 0;
    while (start > 0 and isUtf8Continuation(bytes[start])) : (start -= 1) {
        steps += 1;
        if (steps > 3) return error.InvalidUtf8;
    }

    const decoded = try decodeAt(bytes, start);
    if (start + decoded.width != offset) return error.InvalidUtf8;
    return decoded.cp;
}

fn inRanges(cp: u32, ranges: []const generated.Range) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;

    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const range = ranges[mid];
        if (cp < range.start) {
            hi = mid;
        } else if (cp > range.end) {
            lo = mid + 1;
        } else {
            return true;
        }
    }

    return false;
}

fn foldScalarSimple(cp: u32) u32 {
    return switch (cp) {
        // Greek sigma variants share a simple fold bucket.
        'Σ', 'σ', 'ς' => 'σ',
        else => simpleLower(cp),
    };
}

fn simpleLower(cp: u32) u32 {
    if (cp >= 'A' and cp <= 'Z') return cp + 32;
    if (cp >= 0x0410 and cp <= 0x042F) return cp + 0x20;
    return switch (cp) {
        0x0401 => 0x0451, // Ё
        else => cp,
    };
}

fn simpleUpper(cp: u32) u32 {
    if (cp >= 'a' and cp <= 'z') return cp - 32;
    if (cp >= 0x0430 and cp <= 0x044F) return cp - 0x20;
    return switch (cp) {
        'σ', 'ς' => 'Σ',
        0x0451 => 0x0401, // ё
        else => cp,
    };
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
    for (list.items) |item| {
        if (item == value) return;
    }
    try list.append(allocator, value);
}

fn isUtf8Continuation(byte: u8) bool {
    return (byte & 0b1100_0000) == 0b1000_0000;
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
    try testing.expect(!Strategy.isWord('-'));

    try testing.expect(Strategy.boundary('a', '-', .word));
    try testing.expect(Strategy.boundary(null, 'x', .word));
    try testing.expect(Strategy.boundary('\n', 'x', .line));
    try testing.expect(!Strategy.boundary('a', 'b', .word));
}

test "Unicode strategy looks up named properties and aliases" {
    const testing = std.testing;

    try testing.expectEqual(@as(?Property, .letter), Strategy.lookupProperty("Letter"));
    try testing.expectEqual(@as(?Property, .letter), Strategy.lookupProperty("L"));
    try testing.expectEqual(@as(?Property, .number), Strategy.lookupProperty("Number"));
    try testing.expectEqual(@as(?Property, .whitespace), Strategy.lookupProperty("White_Space"));
    try testing.expectEqual(@as(?Property, .alphabetic), Strategy.lookupProperty("Alphabetic"));
    try testing.expectEqual(@as(?Property, .alphabetic), Strategy.lookupProperty("alpha"));
    try testing.expectEqual(@as(?Property, .lowercase), Strategy.lookupProperty("Ll"));
    try testing.expectEqual(@as(?Property, .mark), Strategy.lookupProperty("M"));
    try testing.expectEqual(@as(?Property, .punctuation), Strategy.lookupProperty("P"));
    try testing.expectEqual(@as(?Property, .separator), Strategy.lookupProperty("Z"));
    try testing.expectEqual(@as(?Property, .symbol), Strategy.lookupProperty("S"));
    try testing.expectEqual(@as(?Property, .uppercase), Strategy.lookupProperty("Uppercase"));
    try testing.expectEqual(@as(?Property, null), Strategy.lookupProperty("Emoji"));
}

test "Unicode strategy evaluates property membership" {
    const testing = std.testing;

    try testing.expect(Strategy.hasProperty('A', .letter));
    try testing.expect(Strategy.hasProperty('ß', .letter));
    try testing.expect(Strategy.hasProperty('7', .number));
    try testing.expect(Strategy.hasProperty(' ', .whitespace));
    try testing.expect(Strategy.hasProperty(0x0345, .alphabetic));
    try testing.expect(Strategy.hasProperty('ß', .lowercase));
    try testing.expect(Strategy.hasProperty(0x0345, .mark));
    try testing.expect(Strategy.hasProperty('-', .punctuation));
    try testing.expect(Strategy.hasProperty(' ', .separator));
    try testing.expect(Strategy.hasProperty('+', .symbol));
    try testing.expect(Strategy.hasProperty('Σ', .uppercase));
    try testing.expect(!Strategy.hasProperty('-', .letter));
}

test "Unicode strategy exposes simple case-fold sets" {
    const testing = std.testing;

    const ascii = try Strategy.foldSet(testing.allocator, 'A', .simple);
    defer ascii.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 'a'), ascii.canonical);
    try testing.expectEqualSlices(u32, &[_]u32{ 'A', 'a' }, ascii.equivalents);

    const sigma = try Strategy.foldSet(testing.allocator, 'Σ', .simple);
    defer sigma.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 'σ'), sigma.canonical);
    try testing.expect(std.mem.indexOfScalar(u32, sigma.equivalents, 'Σ') != null);
    try testing.expect(std.mem.indexOfScalar(u32, sigma.equivalents, 'σ') != null);
    try testing.expect(std.mem.indexOfScalar(u32, sigma.equivalents, 'ς') != null);
}

test "Unicode strategy performs folded scalar comparison" {
    const testing = std.testing;

    try testing.expect(Strategy.foldedEq('A', 'a', .simple));
    try testing.expect(Strategy.foldedEq('Σ', 'σ', .simple));
    try testing.expect(Strategy.foldedEq('Σ', 'ς', .simple));
    try testing.expect(!Strategy.foldedEq('A', 'b', .simple));
}

test "Unicode strategy evaluates boundaries at byte offsets" {
    const testing = std.testing;

    const text = "éclair x\nβeta";
    const e_accent_end = "é".len;
    const space_offset = "éclair".len;
    const line_break_offset = "éclair x".len;
    const beta_offset = "éclair x\n".len;

    try testing.expect(!(try Strategy.boundaryAt(text, 0, .word)));
    try testing.expect(try Strategy.boundaryAt(text, e_accent_end, .word));
    try testing.expect(try Strategy.boundaryAt(text, space_offset, .word));
    try testing.expect(try Strategy.boundaryAt(text, line_break_offset, .line));
    try testing.expect(try Strategy.lineStart(text, 0));
    try testing.expect(!(try Strategy.lineStart(text, space_offset)));
    try testing.expect(try Strategy.lineStart(text, beta_offset));
    try testing.expect(try Strategy.lineEnd(text, line_break_offset));
}

test "Unicode strategy rejects invalid boundary offsets inside UTF-8 scalars" {
    const testing = std.testing;

    const text = "©";
    try testing.expectError(error.InvalidUtf8, Strategy.boundaryAt(text, 1, .word));
}
