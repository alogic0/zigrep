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

pub const script_property_base: u16 = 0x400;

pub const Property = enum(u16) {
    any,
    ascii,
    letter,
    number,
    whitespace,
    alphabetic,
    cased,
    case_ignorable,
    id_start,
    id_continue,
    xid_start,
    xid_continue,
    default_ignorable_code_point,
    shorthand_word,
    shorthand_whitespace,
    emoji,
    lowercase,
    uppercase,
    titlecase_letter,
    modifier_letter,
    other_letter,
    mark,
    nonspacing_mark,
    spacing_mark,
    enclosing_mark,
    decimal_number,
    letter_number,
    other_number,
    punctuation,
    connector_punctuation,
    dash_punctuation,
    open_punctuation,
    close_punctuation,
    initial_punctuation,
    final_punctuation,
    other_punctuation,
    separator,
    space_separator,
    line_separator,
    paragraph_separator,
    symbol,
    math_symbol,
    currency_symbol,
    modifier_symbol,
    other_symbol,
    other,
    control,
    format,
    surrogate,
    private_use,
    unassigned,
    script_base = script_property_base,
    _,
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

    pub fn isUnicodeDigit(cp: u32) bool {
        return hasProperty(cp, .decimal_number);
    }

    pub fn isUnicodeWhitespace(cp: u32) bool {
        return hasProperty(cp, .whitespace);
    }

    pub fn isUnicodeWord(cp: u32) bool {
        return hasProperty(cp, .alphabetic) or
            hasProperty(cp, .mark) or
            hasProperty(cp, .decimal_number) or
            hasProperty(cp, .connector_punctuation) or
            isJoinControl(cp);
    }

    pub fn lookupProperty(name: []const u8) ?Property {
        if (propertyNameEq(name, "any")) return .any;
        if (propertyNameEq(name, "ascii")) return .ascii;
        if (lookupScriptProperty(name)) |property| return property;
        if (propertyNameEq(name, "letter") or propertyNameEq(name, "l")) return .letter;
        if (propertyNameEq(name, "number") or propertyNameEq(name, "n")) return .number;
        if (propertyNameEq(name, "whitespace") or propertyNameEq(name, "space") or propertyNameEq(name, "white_space")) return .whitespace;
        if (propertyNameEq(name, "alphabetic") or propertyNameEq(name, "alpha")) return .alphabetic;
        if (propertyNameEq(name, "cased")) return .cased;
        if (propertyNameEq(name, "case_ignorable")) return .case_ignorable;
        if (propertyNameEq(name, "id_start")) return .id_start;
        if (propertyNameEq(name, "id_continue")) return .id_continue;
        if (propertyNameEq(name, "xid_start")) return .xid_start;
        if (propertyNameEq(name, "xid_continue")) return .xid_continue;
        if (propertyNameEq(name, "default_ignorable_code_point")) return .default_ignorable_code_point;
        if (propertyNameEq(name, "emoji")) return .emoji;
        if (propertyNameEq(name, "lowercase") or propertyNameEq(name, "lower") or propertyNameEq(name, "ll")) return .lowercase;
        if (propertyNameEq(name, "uppercase") or propertyNameEq(name, "upper") or propertyNameEq(name, "lu")) return .uppercase;
        if (propertyNameEq(name, "titlecase_letter") or propertyNameEq(name, "lt")) return .titlecase_letter;
        if (propertyNameEq(name, "modifier_letter") or propertyNameEq(name, "lm")) return .modifier_letter;
        if (propertyNameEq(name, "other_letter") or propertyNameEq(name, "lo")) return .other_letter;
        if (propertyNameEq(name, "mark") or propertyNameEq(name, "m")) return .mark;
        if (propertyNameEq(name, "nonspacing_mark") or propertyNameEq(name, "mn")) return .nonspacing_mark;
        if (propertyNameEq(name, "spacing_mark") or propertyNameEq(name, "mc")) return .spacing_mark;
        if (propertyNameEq(name, "enclosing_mark") or propertyNameEq(name, "me")) return .enclosing_mark;
        if (propertyNameEq(name, "decimal_number") or propertyNameEq(name, "nd")) return .decimal_number;
        if (propertyNameEq(name, "letter_number") or propertyNameEq(name, "nl")) return .letter_number;
        if (propertyNameEq(name, "other_number") or propertyNameEq(name, "no")) return .other_number;
        if (propertyNameEq(name, "punctuation") or propertyNameEq(name, "punct") or propertyNameEq(name, "p")) return .punctuation;
        if (propertyNameEq(name, "connector_punctuation") or propertyNameEq(name, "pc")) return .connector_punctuation;
        if (propertyNameEq(name, "dash_punctuation") or propertyNameEq(name, "pd")) return .dash_punctuation;
        if (propertyNameEq(name, "open_punctuation") or propertyNameEq(name, "ps")) return .open_punctuation;
        if (propertyNameEq(name, "close_punctuation") or propertyNameEq(name, "pe")) return .close_punctuation;
        if (propertyNameEq(name, "initial_punctuation") or propertyNameEq(name, "pi")) return .initial_punctuation;
        if (propertyNameEq(name, "final_punctuation") or propertyNameEq(name, "pf")) return .final_punctuation;
        if (propertyNameEq(name, "other_punctuation") or propertyNameEq(name, "po")) return .other_punctuation;
        if (propertyNameEq(name, "separator") or propertyNameEq(name, "z")) return .separator;
        if (propertyNameEq(name, "space_separator") or propertyNameEq(name, "zs")) return .space_separator;
        if (propertyNameEq(name, "line_separator") or propertyNameEq(name, "zl")) return .line_separator;
        if (propertyNameEq(name, "paragraph_separator") or propertyNameEq(name, "zp")) return .paragraph_separator;
        if (propertyNameEq(name, "symbol") or propertyNameEq(name, "s")) return .symbol;
        if (propertyNameEq(name, "math_symbol") or propertyNameEq(name, "sm")) return .math_symbol;
        if (propertyNameEq(name, "currency_symbol") or propertyNameEq(name, "sc")) return .currency_symbol;
        if (propertyNameEq(name, "modifier_symbol") or propertyNameEq(name, "sk")) return .modifier_symbol;
        if (propertyNameEq(name, "other_symbol") or propertyNameEq(name, "so")) return .other_symbol;
        if (propertyNameEq(name, "other") or propertyNameEq(name, "c")) return .other;
        if (propertyNameEq(name, "control") or propertyNameEq(name, "cc")) return .control;
        if (propertyNameEq(name, "format") or propertyNameEq(name, "cf")) return .format;
        if (propertyNameEq(name, "surrogate") or propertyNameEq(name, "cs")) return .surrogate;
        if (propertyNameEq(name, "private_use") or propertyNameEq(name, "co")) return .private_use;
        if (propertyNameEq(name, "unassigned") or propertyNameEq(name, "cn")) return .unassigned;
        return null;
    }

    pub fn hasProperty(cp: u32, property: Property) bool {
        if (scriptSpecForProperty(property)) |spec| {
            const matched = inRanges(cp, spec.ranges);
            if (@intFromEnum(property) == generated.script_unknown_property_id) {
                return matched or
                    inRanges(cp, &generated.unassigned_ranges) or
                    inRanges(cp, &generated.private_use_ranges) or
                    inRanges(cp, &generated.surrogate_ranges);
            }
            return matched;
        }

        return switch (property) {
            .any => cp <= 0x10FFFF and !(cp >= 0xD800 and cp <= 0xDFFF),
            .ascii => cp <= 0x7F,
            .letter => inRanges(cp, &generated.letter_ranges),
            .number => inRanges(cp, &generated.number_ranges),
            .whitespace => inRanges(cp, &generated.whitespace_ranges),
            .alphabetic => inRanges(cp, &generated.alphabetic_ranges),
            .cased => inRanges(cp, &generated.cased_ranges),
            .case_ignorable => inRanges(cp, &generated.case_ignorable_ranges),
            .id_start => inRanges(cp, &generated.id_start_ranges),
            .id_continue => inRanges(cp, &generated.id_continue_ranges),
            .xid_start => inRanges(cp, &generated.xid_start_ranges),
            .xid_continue => inRanges(cp, &generated.xid_continue_ranges),
            .default_ignorable_code_point => inRanges(cp, &generated.default_ignorable_code_point_ranges),
            .shorthand_word => isUnicodeWord(cp),
            .shorthand_whitespace => inRanges(cp, &generated.whitespace_ranges),
            .emoji => inRanges(cp, &generated.emoji_ranges),
            .lowercase => inRanges(cp, &generated.lowercase_ranges),
            .uppercase => inRanges(cp, &generated.uppercase_ranges),
            .titlecase_letter => inRanges(cp, &generated.titlecase_letter_ranges),
            .modifier_letter => inRanges(cp, &generated.modifier_letter_ranges),
            .other_letter => inRanges(cp, &generated.other_letter_ranges),
            .mark => inRanges(cp, &generated.mark_ranges),
            .nonspacing_mark => inRanges(cp, &generated.nonspacing_mark_ranges),
            .spacing_mark => inRanges(cp, &generated.spacing_mark_ranges),
            .enclosing_mark => inRanges(cp, &generated.enclosing_mark_ranges),
            .decimal_number => inRanges(cp, &generated.decimal_number_ranges),
            .letter_number => inRanges(cp, &generated.letter_number_ranges),
            .other_number => inRanges(cp, &generated.other_number_ranges),
            .punctuation => inRanges(cp, &generated.punctuation_ranges),
            .connector_punctuation => inRanges(cp, &generated.connector_punctuation_ranges),
            .dash_punctuation => inRanges(cp, &generated.dash_punctuation_ranges),
            .open_punctuation => inRanges(cp, &generated.open_punctuation_ranges),
            .close_punctuation => inRanges(cp, &generated.close_punctuation_ranges),
            .initial_punctuation => inRanges(cp, &generated.initial_punctuation_ranges),
            .final_punctuation => inRanges(cp, &generated.final_punctuation_ranges),
            .other_punctuation => inRanges(cp, &generated.other_punctuation_ranges),
            .separator => inRanges(cp, &generated.separator_ranges),
            .space_separator => inRanges(cp, &generated.space_separator_ranges),
            .line_separator => inRanges(cp, &generated.line_separator_ranges),
            .paragraph_separator => inRanges(cp, &generated.paragraph_separator_ranges),
            .symbol => inRanges(cp, &generated.symbol_ranges),
            .math_symbol => inRanges(cp, &generated.math_symbol_ranges),
            .currency_symbol => inRanges(cp, &generated.currency_symbol_ranges),
            .modifier_symbol => inRanges(cp, &generated.modifier_symbol_ranges),
            .other_symbol => inRanges(cp, &generated.other_symbol_ranges),
            .other => inRanges(cp, &generated.other_ranges),
            .control => inRanges(cp, &generated.control_ranges),
            .format => inRanges(cp, &generated.format_ranges),
            .surrogate => inRanges(cp, &generated.surrogate_ranges),
            .private_use => inRanges(cp, &generated.private_use_ranges),
            .unassigned => inRanges(cp, &generated.unassigned_ranges),
            else => false,
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

fn lookupScriptProperty(name: []const u8) ?Property {
    if (std.mem.indexOfScalar(u8, name, '=')) |eq_index| {
        const lhs = std.mem.trim(u8, name[0..eq_index], " \t\r\n");
        const rhs = std.mem.trim(u8, name[eq_index + 1 ..], " \t\r\n");
        if (!(propertyNameEq(lhs, "script") or propertyNameEq(lhs, "sc"))) return null;
        return lookupScriptName(rhs);
    }

    return lookupScriptName(name);
}

fn lookupScriptName(name: []const u8) ?Property {
    for (generated.script_specs) |spec| {
        if (propertyNameEq(name, spec.long_name) or propertyNameEq(name, spec.short_name)) {
            return @enumFromInt(spec.property_id);
        }
    }
    return null;
}

fn scriptSpecForProperty(property: Property) ?generated.ScriptSpec {
    const property_id = @intFromEnum(property);
    if (property_id < script_property_base) return null;
    const index = property_id - script_property_base;
    if (index >= generated.script_specs.len) return null;
    return generated.script_specs[index];
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

fn isJoinControl(cp: u32) bool {
    return cp == 0x200C or cp == 0x200D;
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

test "Unicode strategy exposes planned Unicode shorthand predicates" {
    const testing = std.testing;

    try testing.expect(Strategy.isUnicodeDigit('3'));
    try testing.expect(Strategy.isUnicodeDigit('١'));
    try testing.expect(!Strategy.isUnicodeDigit(0x00B2));

    try testing.expect(Strategy.isUnicodeWhitespace(' '));
    try testing.expect(Strategy.isUnicodeWhitespace('\t'));
    try testing.expect(Strategy.isUnicodeWhitespace(0x00A0));
    try testing.expect(Strategy.isUnicodeWhitespace('\n'));
    try testing.expect(!Strategy.isUnicodeWhitespace('A'));

    try testing.expect(Strategy.isUnicodeWord('A'));
    try testing.expect(Strategy.isUnicodeWord('Ж'));
    try testing.expect(Strategy.isUnicodeWord('β'));
    try testing.expect(Strategy.isUnicodeWord('١'));
    try testing.expect(Strategy.isUnicodeWord('_'));
    try testing.expect(Strategy.isUnicodeWord(0x0345));
    try testing.expect(Strategy.isUnicodeWord(0x200C));
    try testing.expect(Strategy.isUnicodeWord(0x200D));
    try testing.expect(!Strategy.isUnicodeWord('-'));
    try testing.expect(!Strategy.isUnicodeWord(' '));
}

test "Unicode strategy looks up named properties and aliases" {
    const testing = std.testing;

    try testing.expectEqual(@as(?Property, .any), Strategy.lookupProperty("Any"));
    try testing.expectEqual(@as(?Property, .ascii), Strategy.lookupProperty("ASCII"));
    const greek = Strategy.lookupProperty("Greek").?;
    try testing.expectEqual(greek, Strategy.lookupProperty("Grek").?);
    try testing.expectEqual(greek, Strategy.lookupProperty("Script=Greek").?);
    try testing.expectEqual(greek, Strategy.lookupProperty("sc=Grek").?);
    const common = Strategy.lookupProperty("Common").?;
    try testing.expectEqual(common, Strategy.lookupProperty("Zyyy").?);
    const inherited = Strategy.lookupProperty("Inherited").?;
    try testing.expectEqual(inherited, Strategy.lookupProperty("Zinh").?);
    const unknown = Strategy.lookupProperty("Unknown").?;
    try testing.expectEqual(unknown, Strategy.lookupProperty("Zzzz").?);
    try testing.expect(Strategy.lookupProperty("Hebrew") != null);
    try testing.expect(Strategy.lookupProperty("Hebr") != null);
    try testing.expectEqual(@as(?Property, .letter), Strategy.lookupProperty("Letter"));
    try testing.expectEqual(@as(?Property, .letter), Strategy.lookupProperty("L"));
    try testing.expectEqual(@as(?Property, .number), Strategy.lookupProperty("Number"));
    try testing.expectEqual(@as(?Property, .whitespace), Strategy.lookupProperty("White_Space"));
    try testing.expectEqual(@as(?Property, .alphabetic), Strategy.lookupProperty("Alphabetic"));
    try testing.expectEqual(@as(?Property, .alphabetic), Strategy.lookupProperty("alpha"));
    try testing.expectEqual(@as(?Property, .cased), Strategy.lookupProperty("Cased"));
    try testing.expectEqual(@as(?Property, .case_ignorable), Strategy.lookupProperty("Case_Ignorable"));
    try testing.expectEqual(@as(?Property, .id_start), Strategy.lookupProperty("ID_Start"));
    try testing.expectEqual(@as(?Property, .id_continue), Strategy.lookupProperty("ID_Continue"));
    try testing.expectEqual(@as(?Property, .xid_start), Strategy.lookupProperty("XID_Start"));
    try testing.expectEqual(@as(?Property, .xid_continue), Strategy.lookupProperty("XID_Continue"));
    try testing.expectEqual(@as(?Property, .default_ignorable_code_point), Strategy.lookupProperty("Default_Ignorable_Code_Point"));
    try testing.expectEqual(@as(?Property, .emoji), Strategy.lookupProperty("Emoji"));
    try testing.expectEqual(@as(?Property, .lowercase), Strategy.lookupProperty("Ll"));
    try testing.expectEqual(@as(?Property, .titlecase_letter), Strategy.lookupProperty("Lt"));
    try testing.expectEqual(@as(?Property, .modifier_letter), Strategy.lookupProperty("Lm"));
    try testing.expectEqual(@as(?Property, .other_letter), Strategy.lookupProperty("Lo"));
    try testing.expectEqual(@as(?Property, .mark), Strategy.lookupProperty("M"));
    try testing.expectEqual(@as(?Property, .nonspacing_mark), Strategy.lookupProperty("Mn"));
    try testing.expectEqual(@as(?Property, .spacing_mark), Strategy.lookupProperty("Mc"));
    try testing.expectEqual(@as(?Property, .enclosing_mark), Strategy.lookupProperty("Me"));
    try testing.expectEqual(@as(?Property, .decimal_number), Strategy.lookupProperty("Nd"));
    try testing.expectEqual(@as(?Property, .letter_number), Strategy.lookupProperty("Nl"));
    try testing.expectEqual(@as(?Property, .other_number), Strategy.lookupProperty("No"));
    try testing.expectEqual(@as(?Property, .punctuation), Strategy.lookupProperty("P"));
    try testing.expectEqual(@as(?Property, .connector_punctuation), Strategy.lookupProperty("Pc"));
    try testing.expectEqual(@as(?Property, .dash_punctuation), Strategy.lookupProperty("Pd"));
    try testing.expectEqual(@as(?Property, .open_punctuation), Strategy.lookupProperty("Ps"));
    try testing.expectEqual(@as(?Property, .close_punctuation), Strategy.lookupProperty("Pe"));
    try testing.expectEqual(@as(?Property, .initial_punctuation), Strategy.lookupProperty("Pi"));
    try testing.expectEqual(@as(?Property, .final_punctuation), Strategy.lookupProperty("Pf"));
    try testing.expectEqual(@as(?Property, .other_punctuation), Strategy.lookupProperty("Po"));
    try testing.expectEqual(@as(?Property, .separator), Strategy.lookupProperty("Z"));
    try testing.expectEqual(@as(?Property, .space_separator), Strategy.lookupProperty("Zs"));
    try testing.expectEqual(@as(?Property, .line_separator), Strategy.lookupProperty("Zl"));
    try testing.expectEqual(@as(?Property, .paragraph_separator), Strategy.lookupProperty("Zp"));
    try testing.expectEqual(@as(?Property, .symbol), Strategy.lookupProperty("S"));
    try testing.expectEqual(@as(?Property, .math_symbol), Strategy.lookupProperty("Sm"));
    try testing.expectEqual(@as(?Property, .currency_symbol), Strategy.lookupProperty("Sc"));
    try testing.expectEqual(@as(?Property, .modifier_symbol), Strategy.lookupProperty("Sk"));
    try testing.expectEqual(@as(?Property, .other_symbol), Strategy.lookupProperty("So"));
    try testing.expectEqual(@as(?Property, .other), Strategy.lookupProperty("C"));
    try testing.expectEqual(@as(?Property, .control), Strategy.lookupProperty("Cc"));
    try testing.expectEqual(@as(?Property, .format), Strategy.lookupProperty("Cf"));
    try testing.expectEqual(@as(?Property, .surrogate), Strategy.lookupProperty("Cs"));
    try testing.expectEqual(@as(?Property, .private_use), Strategy.lookupProperty("Co"));
    try testing.expectEqual(@as(?Property, .unassigned), Strategy.lookupProperty("Cn"));
    try testing.expectEqual(@as(?Property, .uppercase), Strategy.lookupProperty("Uppercase"));
}

test "Unicode strategy evaluates property membership" {
    const testing = std.testing;

    try testing.expect(Strategy.hasProperty('A', .any));
    try testing.expect(Strategy.hasProperty('A', .ascii));
    try testing.expect(!Strategy.hasProperty('ж', .ascii));
    try testing.expect(Strategy.hasProperty('A', Strategy.lookupProperty("Latin").?));
    try testing.expect(Strategy.hasProperty('Ω', Strategy.lookupProperty("Greek").?));
    try testing.expect(Strategy.hasProperty('Ж', Strategy.lookupProperty("Cyrillic").?));
    try testing.expect(Strategy.hasProperty('+', Strategy.lookupProperty("Common").?));
    try testing.expect(Strategy.hasProperty(0x0301, Strategy.lookupProperty("Inherited").?));
    try testing.expect(Strategy.hasProperty(0x0378, Strategy.lookupProperty("Unknown").?));
    try testing.expect(Strategy.hasProperty('א', Strategy.lookupProperty("Hebrew").?));
    try testing.expect(Strategy.hasProperty('A', .letter));
    try testing.expect(Strategy.hasProperty('ß', .letter));
    try testing.expect(Strategy.hasProperty('7', .number));
    try testing.expect(Strategy.hasProperty(' ', .whitespace));
    try testing.expect(Strategy.hasProperty(0x0345, .alphabetic));
    try testing.expect(Strategy.hasProperty('Σ', .cased));
    try testing.expect(Strategy.hasProperty(0x0345, .case_ignorable));
    try testing.expect(Strategy.hasProperty('A', .id_start));
    try testing.expect(Strategy.hasProperty('0', .id_continue));
    try testing.expect(Strategy.hasProperty('A', .xid_start));
    try testing.expect(Strategy.hasProperty('0', .xid_continue));
    try testing.expect(Strategy.hasProperty(0x00AD, .default_ignorable_code_point));
    try testing.expect(Strategy.hasProperty(0x1F600, .emoji));
    try testing.expect(Strategy.hasProperty('ß', .lowercase));
    try testing.expect(Strategy.hasProperty(0x01C5, .titlecase_letter));
    try testing.expect(Strategy.hasProperty(0x02B0, .modifier_letter));
    try testing.expect(Strategy.hasProperty('中', .other_letter));
    try testing.expect(Strategy.hasProperty(0x0345, .mark));
    try testing.expect(Strategy.hasProperty(0x0345, .nonspacing_mark));
    try testing.expect(Strategy.hasProperty(0x093E, .spacing_mark));
    try testing.expect(Strategy.hasProperty(0x20DD, .enclosing_mark));
    try testing.expect(Strategy.hasProperty('7', .decimal_number));
    try testing.expect(Strategy.hasProperty(0x2160, .letter_number));
    try testing.expect(Strategy.hasProperty(0x00B2, .other_number));
    try testing.expect(Strategy.hasProperty('-', .punctuation));
    try testing.expect(Strategy.hasProperty('_', .connector_punctuation));
    try testing.expect(Strategy.hasProperty('-', .dash_punctuation));
    try testing.expect(Strategy.hasProperty('(', .open_punctuation));
    try testing.expect(Strategy.hasProperty(')', .close_punctuation));
    try testing.expect(Strategy.hasProperty('«', .initial_punctuation));
    try testing.expect(Strategy.hasProperty('»', .final_punctuation));
    try testing.expect(Strategy.hasProperty('!', .other_punctuation));
    try testing.expect(Strategy.hasProperty(' ', .separator));
    try testing.expect(Strategy.hasProperty(' ', .space_separator));
    try testing.expect(Strategy.hasProperty(0x2028, .line_separator));
    try testing.expect(Strategy.hasProperty(0x2029, .paragraph_separator));
    try testing.expect(Strategy.hasProperty('+', .symbol));
    try testing.expect(Strategy.hasProperty('+', .math_symbol));
    try testing.expect(Strategy.hasProperty('$', .currency_symbol));
    try testing.expect(Strategy.hasProperty('^', .modifier_symbol));
    try testing.expect(Strategy.hasProperty(0x2603, .other_symbol));
    try testing.expect(Strategy.hasProperty('Σ', .uppercase));
    try testing.expect(Strategy.hasProperty(0xE000, .other));
    try testing.expect(Strategy.hasProperty(0x0001, .control));
    try testing.expect(Strategy.hasProperty(0x200E, .format));
    try testing.expect(Strategy.hasProperty(0xD800, .surrogate));
    try testing.expect(Strategy.hasProperty(0xE000, .private_use));
    try testing.expect(Strategy.hasProperty(0x0378, .unassigned));
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
