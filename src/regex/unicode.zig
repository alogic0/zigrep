const std = @import("std");

pub const Error = error{
    InvalidUtf8,
};

pub const BoundaryKind = enum {
    none,
    word,
    line,
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
