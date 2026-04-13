const std = @import("std");
const reader = @import("reader.zig");
const unicode = @import("regex/unicode.zig");

pub const LexError = reader.ReaderError || error{
    TrailingEscape,
    InvalidHexEscape,
    InvalidUnicodeEscape,
    InvalidPropertyEscape,
    UnsupportedProperty,
    UnsupportedEscape,
};

pub const Span = struct {
    start: usize,
    end: usize,
};

pub const Token = union(enum) {
    eof,
    literal: u32,
    digit_class,
    not_digit_class,
    word_class,
    not_word_class,
    space_class,
    not_space_class,
    word_boundary,
    not_word_boundary,
    unicode_property: struct {
        property: unicode.Property,
        negated: bool,
    },
    dot,
    anchor_start,
    anchor_end,
    alternation,
    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    l_brace,
    r_brace,
    star,
    plus,
    question,
    comma,
    hyphen,
};

pub const SpannedToken = struct {
    token: Token,
    span: Span,
};

pub fn Lexer(comptime T: type) type {
    return struct {
        const Self = @This();
        const Input = reader.CodePointReader(T);

        input: Input,
        source_len: usize,

        pub fn init(source: []const T) Self {
            return .{
                .input = Input.init(source),
                .source_len = source.len,
            };
        }

        pub fn next(self: *Self) LexError!Token {
            return (try self.nextSpanned()).token;
        }

        pub fn nextSpanned(self: *Self) LexError!SpannedToken {
            const start = self.input.pos;
            const cp = (try self.input.next()) orelse return .{
                .token = .eof,
                .span = .{ .start = self.source_len, .end = self.source_len },
            };

            const token = switch (cp) {
                '\\' => try self.readEscape(),
                '.' => Token.dot,
                '^' => Token.anchor_start,
                '$' => Token.anchor_end,
                '|' => Token.alternation,
                '(' => Token.l_paren,
                ')' => Token.r_paren,
                '[' => Token.l_bracket,
                ']' => Token.r_bracket,
                '{' => Token.l_brace,
                '}' => Token.r_brace,
                '*' => Token.star,
                '+' => Token.plus,
                '?' => Token.question,
                ',' => Token.comma,
                '-' => Token.hyphen,
                else => Token{ .literal = cp },
            };

            return .{
                .token = token,
                .span = .{ .start = start, .end = self.input.pos },
            };
        }

        fn readEscape(self: *Self) LexError!Token {
            const escaped = (try self.input.next()) orelse return error.TrailingEscape;
            return switch (escaped) {
                'n' => .{ .literal = '\n' },
                'r' => .{ .literal = '\r' },
                't' => .{ .literal = '\t' },
                'f' => .{ .literal = 0x0c },
                'v' => .{ .literal = 0x0b },
                '0' => .{ .literal = 0 },
                'x' => .{ .literal = try self.readHexEscape() },
                'u' => .{ .literal = try self.readUnicodeEscape() },
                'd' => .digit_class,
                'D' => .not_digit_class,
                'w' => .word_class,
                'W' => .not_word_class,
                's' => .space_class,
                'S' => .not_space_class,
                'b' => .word_boundary,
                'B' => .not_word_boundary,
                'p' => .{ .unicode_property = .{
                    .property = try self.readPropertyEscape(),
                    .negated = false,
                } },
                'P' => .{ .unicode_property = .{
                    .property = try self.readPropertyEscape(),
                    .negated = true,
                } },
                else => .{ .literal = escaped },
            };
        }

        fn readPropertyEscape(self: *Self) LexError!unicode.Property {
            const open = (try self.input.next()) orelse return error.InvalidPropertyEscape;
            if (open != '{') return error.InvalidPropertyEscape;

            const start = self.input.pos;
            while (true) {
                const cp = (try self.input.peek()) orelse return error.InvalidPropertyEscape;
                if (cp == '}') break;
                _ = try self.input.next();
            }
            const end = self.input.pos;
            if (start == end) return error.InvalidPropertyEscape;

            _ = (try self.input.next()) orelse return error.InvalidPropertyEscape;
            return unicode.Strategy.lookupProperty(self.input.buffer[start..end]) orelse error.UnsupportedProperty;
        }

        fn readHexEscape(self: *Self) LexError!u32 {
            const hi = (try self.input.next()) orelse return error.InvalidHexEscape;
            const lo = (try self.input.next()) orelse return error.InvalidHexEscape;

            const hi_nibble = std.fmt.charToDigit(@as(u8, @intCast(hi)), 16) catch return error.InvalidHexEscape;
            const lo_nibble = std.fmt.charToDigit(@as(u8, @intCast(lo)), 16) catch return error.InvalidHexEscape;
            return (hi_nibble << 4) | lo_nibble;
        }

        fn readUnicodeEscape(self: *Self) LexError!u32 {
            const open = (try self.input.next()) orelse return error.InvalidUnicodeEscape;
            if (open != '{') return error.InvalidUnicodeEscape;

            var value: u32 = 0;
            var digits: usize = 0;

            while (true) {
                const cp = (try self.input.next()) orelse return error.InvalidUnicodeEscape;
                if (cp == '}') break;

                const digit = std.fmt.charToDigit(@as(u8, @intCast(cp)), 16) catch return error.InvalidUnicodeEscape;
                if (digits == 6) return error.InvalidUnicodeEscape;
                digits += 1;

                if (value > (@as(u32, 0x10ffff) - digit) / 16) return error.InvalidUnicodeEscape;
                value = value * 16 + digit;
            }

            if (digits == 0) return error.InvalidUnicodeEscape;
            if (value > 0x10ffff) return error.InvalidUnicodeEscape;
            if (value >= 0xd800 and value <= 0xdfff) return error.InvalidUnicodeEscape;

            return value;
        }
    };
}

test "Lexer tokenizes core regex operators" {
    const testing = @import("std").testing;
    var lexer = Lexer(u8).init("a(b|c)+d?\\.[x]{2,4}-");

    try testing.expectEqualDeep(Token{ .literal = 'a' }, try lexer.next());
    try testing.expectEqualDeep(Token.l_paren, try lexer.next());
    try testing.expectEqualDeep(Token{ .literal = 'b' }, try lexer.next());
    try testing.expectEqualDeep(Token.alternation, try lexer.next());
    try testing.expectEqualDeep(Token{ .literal = 'c' }, try lexer.next());
    try testing.expectEqualDeep(Token.r_paren, try lexer.next());
    try testing.expectEqualDeep(Token.plus, try lexer.next());
    try testing.expectEqualDeep(Token{ .literal = 'd' }, try lexer.next());
    try testing.expectEqualDeep(Token.question, try lexer.next());
    try testing.expectEqualDeep(Token{ .literal = '.' }, try lexer.next());
    try testing.expectEqualDeep(Token.l_bracket, try lexer.next());
    try testing.expectEqualDeep(Token{ .literal = 'x' }, try lexer.next());
    try testing.expectEqualDeep(Token.r_bracket, try lexer.next());
    try testing.expectEqualDeep(Token.l_brace, try lexer.next());
    try testing.expectEqualDeep(Token{ .literal = '2' }, try lexer.next());
    try testing.expectEqualDeep(Token.comma, try lexer.next());
    try testing.expectEqualDeep(Token{ .literal = '4' }, try lexer.next());
    try testing.expectEqualDeep(Token.r_brace, try lexer.next());
    try testing.expectEqualDeep(Token.hyphen, try lexer.next());
    try testing.expectEqualDeep(Token.eof, try lexer.next());
}

test "Lexer decodes common escapes and tracks spans" {
    const testing = @import("std").testing;

    var lexer = Lexer(u8).init("\\n\\t\\x41");

    const newline = try lexer.nextSpanned();
    try testing.expectEqualDeep(Token{ .literal = '\n' }, newline.token);
    try testing.expectEqualDeep(Span{ .start = 0, .end = 2 }, newline.span);

    const tab = try lexer.nextSpanned();
    try testing.expectEqualDeep(Token{ .literal = '\t' }, tab.token);
    try testing.expectEqualDeep(Span{ .start = 2, .end = 4 }, tab.span);

    const hex = try lexer.nextSpanned();
    try testing.expectEqualDeep(Token{ .literal = 'A' }, hex.token);
    try testing.expectEqualDeep(Span{ .start = 4, .end = 8 }, hex.span);
}

test "Lexer decodes Unicode escapes" {
    const testing = @import("std").testing;

    var lexer = Lexer(u8).init("\\u{41}\\u{0436}");

    try testing.expectEqualDeep(Token{ .literal = 'A' }, try lexer.next());
    try testing.expectEqualDeep(Token{ .literal = 0x0436 }, try lexer.next());
    try testing.expectEqualDeep(Token.eof, try lexer.next());
}

test "Lexer rejects invalid Unicode escapes" {
    const testing = @import("std").testing;

    var missing = Lexer(u8).init("\\u");
    try testing.expectError(error.InvalidUnicodeEscape, missing.next());

    var empty = Lexer(u8).init("\\u{}");
    try testing.expectError(error.InvalidUnicodeEscape, empty.next());

    var too_large = Lexer(u8).init("\\u{110000}");
    try testing.expectError(error.InvalidUnicodeEscape, too_large.next());

    var surrogate = Lexer(u8).init("\\u{D800}");
    try testing.expectError(error.InvalidUnicodeEscape, surrogate.next());
}

test "Lexer tokenizes shorthand character classes" {
    const testing = @import("std").testing;

    var lexer = Lexer(u8).init("\\d\\D\\w\\W\\s\\S");

    try testing.expectEqualDeep(Token.digit_class, try lexer.next());
    try testing.expectEqualDeep(Token.not_digit_class, try lexer.next());
    try testing.expectEqualDeep(Token.word_class, try lexer.next());
    try testing.expectEqualDeep(Token.not_word_class, try lexer.next());
    try testing.expectEqualDeep(Token.space_class, try lexer.next());
    try testing.expectEqualDeep(Token.not_space_class, try lexer.next());
    try testing.expectEqualDeep(Token.eof, try lexer.next());
}

test "Lexer tokenizes word boundary escapes" {
    const testing = @import("std").testing;

    var lexer = Lexer(u8).init("\\b\\B");

    try testing.expectEqualDeep(Token.word_boundary, try lexer.next());
    try testing.expectEqualDeep(Token.not_word_boundary, try lexer.next());
    try testing.expectEqualDeep(Token.eof, try lexer.next());
}

test "Lexer tokenizes Unicode property escapes" {
    const testing = @import("std").testing;

    var lexer = Lexer(u8).init("\\p{Letter}\\P{White_Space}");

    try testing.expectEqualDeep(Token{ .unicode_property = .{
        .property = .letter,
        .negated = false,
    } }, try lexer.next());
    try testing.expectEqualDeep(Token{ .unicode_property = .{
        .property = .whitespace,
        .negated = true,
    } }, try lexer.next());
    try testing.expectEqualDeep(Token.eof, try lexer.next());
}

test "Lexer rejects malformed and unsupported Unicode property escapes" {
    const testing = @import("std").testing;

    var missing_brace = Lexer(u8).init("\\pLetter}");
    try testing.expectError(error.InvalidPropertyEscape, missing_brace.next());

    var empty = Lexer(u8).init("\\p{}");
    try testing.expectError(error.InvalidPropertyEscape, empty.next());

    var unsupported = Lexer(u8).init("\\p{NotARealProperty}");
    try testing.expectError(error.UnsupportedProperty, unsupported.next());
}
