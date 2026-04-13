const std = @import("std");
const lexer_mod = @import("lexer.zig");

pub const NodeId = enum(u32) {
    _,
};

pub const Quantifier = struct {
    min: u32,
    max: ?u32,
    greedy: bool = true,
};

pub const ClassRange = struct {
    start: u32,
    end: u32,
};

pub const ClassItem = union(enum) {
    literal: u32,
    range: ClassRange,
};

pub const CharacterClass = struct {
    negated: bool,
    items: []const ClassItem,
};

pub const Node = union(enum) {
    empty,
    literal: u32,
    dot,
    anchor_start,
    anchor_end,
    word_boundary,
    not_word_boundary,
    char_class: CharacterClass,
    group: struct {
        index: u32,
        child: NodeId,
    },
    concat: []const NodeId,
    alternation: []const NodeId,
    repetition: struct {
        child: NodeId,
        quantifier: Quantifier,
    },
};

pub const Ast = struct {
    nodes: []Node,
    root: NodeId,
    capture_count: u32,

    pub fn deinit(self: Ast, allocator: std.mem.Allocator) void {
        for (self.nodes) |node| {
            switch (node) {
                .concat => |children| allocator.free(children),
                .alternation => |branches| allocator.free(branches),
                .char_class => |class| allocator.free(class.items),
                else => {},
            }
        }
        allocator.free(self.nodes);
    }
};

pub const ParseError = lexer_mod.LexError || error{
    OutOfMemory,
    UnexpectedToken,
    UnterminatedGroup,
    UnterminatedClass,
    InvalidClassRange,
    EmptyClass,
    InvalidQuantifier,
    UnsupportedGroup,
    TrailingInput,
};

pub const ParseDiagnostic = struct {
    err: ParseError,
    span: lexer_mod.Span,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: lexer_mod.Lexer(u8),
    lookahead: lexer_mod.SpannedToken,
    nodes: std.ArrayList(Node),
    last_error: ?ParseDiagnostic,
    capture_count: u32,

    pub fn init(allocator: std.mem.Allocator, pattern: []const u8) ParseError!Parser {
        var lex = lexer_mod.Lexer(u8).init(pattern);
        const first = try lex.nextSpanned();

        return .{
            .allocator = allocator,
            .lexer = lex,
            .lookahead = first,
            .nodes = .empty,
            .last_error = null,
            .capture_count = 0,
        };
    }

    pub fn parse(self: *Parser) ParseError!Ast {
        defer self.nodes.deinit(self.allocator);

        const root = self.parseAlternation() catch |err| {
            if (self.last_error == null) return self.fail(err, self.lookahead.span);
            return err;
        };
        if (self.lookahead.token != .eof) return self.fail(error.TrailingInput, self.lookahead.span);

        return .{
            .nodes = try self.nodes.toOwnedSlice(self.allocator),
            .root = root,
            .capture_count = self.capture_count,
        };
    }

    pub fn lastError(self: *const Parser) ?ParseDiagnostic {
        return self.last_error;
    }

    fn advance(self: *Parser) ParseError!void {
        self.lookahead = try self.lexer.nextSpanned();
    }

    fn parseAlternation(self: *Parser) ParseError!NodeId {
        var branches: std.ArrayList(NodeId) = .empty;
        defer branches.deinit(self.allocator);

        try branches.append(self.allocator, try self.parseConcatenation());

        while (self.lookahead.token == .alternation) {
            try self.advance();
            try branches.append(self.allocator, try self.parseConcatenation());
        }

        if (branches.items.len == 1) return branches.items[0];
        return self.push(.{ .alternation = try branches.toOwnedSlice(self.allocator) });
    }

    fn parseConcatenation(self: *Parser) ParseError!NodeId {
        var parts: std.ArrayList(NodeId) = .empty;
        defer parts.deinit(self.allocator);

        while (self.canStartPrimary()) {
            try parts.append(self.allocator, try self.parseQuantified());
        }

        return switch (parts.items.len) {
            0 => self.push(.empty),
            1 => parts.items[0],
            else => self.push(.{ .concat = try parts.toOwnedSlice(self.allocator) }),
        };
    }

    fn parseQuantified(self: *Parser) ParseError!NodeId {
        var node_id = try self.parsePrimary();

        while (true) {
            const quantifier = switch (self.lookahead.token) {
                .star => blk: {
                    try self.advance();
                    break :blk Quantifier{ .min = 0, .max = null };
                },
                .plus => blk: {
                    try self.advance();
                    break :blk Quantifier{ .min = 1, .max = null };
                },
                .question => blk: {
                    try self.advance();
                    break :blk Quantifier{ .min = 0, .max = 1 };
                },
                .l_brace => try self.parseCountedQuantifier(),
                else => return node_id,
            };

            node_id = try self.push(.{
                .repetition = .{
                    .child = node_id,
                    .quantifier = quantifier,
                },
            });
        }
    }

    fn parseCountedQuantifier(self: *Parser) ParseError!Quantifier {
        try self.advance();
        const min = try self.parseNumber();

        const max = switch (self.lookahead.token) {
            .r_brace => blk: {
                try self.advance();
                break :blk @as(?u32, min);
            },
            .comma => blk: {
                try self.advance();
                if (self.lookahead.token == .r_brace) {
                    try self.advance();
                    break :blk @as(?u32, null);
                }

                const upper = try self.parseNumber();
                if (upper < min) return error.InvalidQuantifier;
                if (self.lookahead.token != .r_brace) return error.InvalidQuantifier;
                try self.advance();
                break :blk @as(?u32, upper);
            },
            else => return error.InvalidQuantifier,
        };

        return .{ .min = min, .max = max };
    }

    fn parseNumber(self: *Parser) ParseError!u32 {
        var seen_digit = false;
        var value: u32 = 0;

        while (self.lookahead.token == .literal) {
            const cp = self.lookahead.token.literal;
            if (cp < '0' or cp > '9') break;
            seen_digit = true;

            const digit: u32 = cp - '0';
            if (value > (std.math.maxInt(u32) - digit) / 10) {
                return error.InvalidQuantifier;
            }

            value = value * 10 + digit;
            try self.advance();
        }

        if (!seen_digit) return error.InvalidQuantifier;
        return value;
    }

    fn parsePrimary(self: *Parser) ParseError!NodeId {
        switch (self.lookahead.token) {
            .literal => |cp| {
                try self.advance();
                return self.push(.{ .literal = cp });
            },
            .digit_class => {
                try self.advance();
                return self.push(.{ .char_class = try asciiDigitClass(self.allocator, false) });
            },
            .not_digit_class => {
                try self.advance();
                return self.push(.{ .char_class = try asciiDigitClass(self.allocator, true) });
            },
            .word_class => {
                try self.advance();
                return self.push(.{ .char_class = try asciiWordClass(self.allocator, false) });
            },
            .not_word_class => {
                try self.advance();
                return self.push(.{ .char_class = try asciiWordClass(self.allocator, true) });
            },
            .space_class => {
                try self.advance();
                return self.push(.{ .char_class = try asciiSpaceClass(self.allocator, false) });
            },
            .not_space_class => {
                try self.advance();
                return self.push(.{ .char_class = try asciiSpaceClass(self.allocator, true) });
            },
            .comma => {
                try self.advance();
                return self.push(.{ .literal = ',' });
            },
            .hyphen => {
                try self.advance();
                return self.push(.{ .literal = '-' });
            },
            .dot => {
                try self.advance();
                return self.push(.dot);
            },
            .anchor_start => {
                try self.advance();
                return self.push(.anchor_start);
            },
            .anchor_end => {
                try self.advance();
                return self.push(.anchor_end);
            },
            .word_boundary => {
                try self.advance();
                return self.push(.word_boundary);
            },
            .not_word_boundary => {
                try self.advance();
                return self.push(.not_word_boundary);
            },
            .l_paren => {
                const group_span = self.lookahead.span;
                try self.advance();
                if (self.lookahead.token == .question) {
                    return self.fail(error.UnsupportedGroup, group_span);
                }
                const group_index = self.capture_count;
                self.capture_count += 1;
                const expr = try self.parseAlternation();
                if (self.lookahead.token != .r_paren) return error.UnterminatedGroup;
                try self.advance();
                return self.push(.{ .group = .{
                    .index = group_index,
                    .child = expr,
                } });
            },
            .l_bracket => return self.parseClass(),
            else => return error.UnexpectedToken,
        }
    }

    fn parseClass(self: *Parser) ParseError!NodeId {
        var items: std.ArrayList(ClassItem) = .empty;
        defer items.deinit(self.allocator);

        try self.advance();

        var negated = false;
        if (self.lookahead.token == .anchor_start) {
            negated = true;
            try self.advance();
        }

        var first = true;
        while (self.lookahead.token != .eof and self.lookahead.token != .r_bracket) {
            const start = try self.parseClassAtom(first);
            first = false;

            if (self.lookahead.token == .hyphen) {
                try self.advance();
                if (self.lookahead.token == .r_bracket) {
                    try items.append(self.allocator, .{ .literal = start });
                    try items.append(self.allocator, .{ .literal = '-' });
                    break;
                }

                const range_end = try self.parseClassAtom(false);
                if (range_end < start) return error.InvalidClassRange;
                try items.append(self.allocator, .{ .range = .{ .start = start, .end = range_end } });
                continue;
            }

            try items.append(self.allocator, .{ .literal = start });
        }

        if (self.lookahead.token != .r_bracket) return error.UnterminatedClass;
        if (items.items.len == 0) return error.EmptyClass;
        try self.advance();

        return self.push(.{ .char_class = .{
            .negated = negated,
            .items = try items.toOwnedSlice(self.allocator),
        } });
    }

    fn parseClassAtom(self: *Parser, first: bool) ParseError!u32 {
        switch (self.lookahead.token) {
            .literal => |cp| {
                try self.advance();
                return cp;
            },
            .hyphen => {
                try self.advance();
                return '-';
            },
            .r_bracket => if (first) {
                try self.advance();
                return ']';
            } else return error.UnterminatedClass,
            .anchor_start => {
                try self.advance();
                return '^';
            },
            else => return error.UnexpectedToken,
        }
    }

    fn canStartPrimary(self: *const Parser) bool {
        return switch (self.lookahead.token) {
            .literal,
            .digit_class,
            .not_digit_class,
            .word_class,
            .not_word_class,
            .space_class,
            .not_space_class,
            .comma,
            .hyphen,
            .dot,
            .anchor_start,
            .anchor_end,
            .word_boundary,
            .not_word_boundary,
            .l_paren,
            .l_bracket,
            => true,
            else => false,
        };
    }

    fn asciiDigitClass(allocator: std.mem.Allocator, negated: bool) !CharacterClass {
        const items = try allocator.alloc(ClassItem, 1);
        items[0] = .{ .range = .{ .start = '0', .end = '9' } };
        return .{ .negated = negated, .items = items };
    }

    fn asciiWordClass(allocator: std.mem.Allocator, negated: bool) !CharacterClass {
        const items = try allocator.alloc(ClassItem, 4);
        items[0] = .{ .range = .{ .start = 'A', .end = 'Z' } };
        items[1] = .{ .range = .{ .start = 'a', .end = 'z' } };
        items[2] = .{ .range = .{ .start = '0', .end = '9' } };
        items[3] = .{ .literal = '_' };
        return .{ .negated = negated, .items = items };
    }

    fn asciiSpaceClass(allocator: std.mem.Allocator, negated: bool) !CharacterClass {
        const items = try allocator.alloc(ClassItem, 6);
        items[0] = .{ .literal = ' ' };
        items[1] = .{ .literal = '\t' };
        items[2] = .{ .literal = '\n' };
        items[3] = .{ .literal = '\r' };
        items[4] = .{ .literal = 0x0b };
        items[5] = .{ .literal = 0x0c };
        return .{ .negated = negated, .items = items };
    }

    fn fail(self: *Parser, err: ParseError, span: lexer_mod.Span) ParseError {
        self.last_error = .{ .err = err, .span = span };
        return err;
    }

    fn push(self: *Parser, node: Node) !NodeId {
        try self.nodes.append(self.allocator, node);
        return @enumFromInt(self.nodes.items.len - 1);
    }
};

test "Parser builds an AST for grouped alternation and quantifiers" {
    const testing = std.testing;

    var parser = try Parser.init(testing.allocator, "(ab|c)+d?");
    const ast = try parser.parse();
    defer ast.deinit(testing.allocator);

    try testing.expect(ast.nodes.len > 0);
    try testing.expectEqual(@as(u32, 1), ast.capture_count);
    try testing.expectEqual(.concat, std.meta.activeTag(ast.nodes[@intFromEnum(ast.root)]));

    const root = ast.nodes[@intFromEnum(ast.root)].concat;
    try testing.expectEqual(@as(usize, 2), root.len);

    const repeated = ast.nodes[@intFromEnum(root[0])].repetition;
    try testing.expectEqual(@as(u32, 1), repeated.quantifier.min);
    try testing.expectEqual(@as(?u32, null), repeated.quantifier.max);
    try testing.expectEqual(.group, std.meta.activeTag(ast.nodes[@intFromEnum(repeated.child)]));

    const optional = ast.nodes[@intFromEnum(root[1])].repetition;
    try testing.expectEqual(@as(u32, 0), optional.quantifier.min);
    try testing.expectEqual(@as(?u32, 1), optional.quantifier.max);
}

test "Parser accepts empty alternation branches" {
    const testing = std.testing;

    var parser = try Parser.init(testing.allocator, "a|");
    const ast = try parser.parse();
    defer ast.deinit(testing.allocator);

    try testing.expectEqual(.alternation, std.meta.activeTag(ast.nodes[@intFromEnum(ast.root)]));
    const branches = ast.nodes[@intFromEnum(ast.root)].alternation;
    try testing.expectEqual(@as(usize, 2), branches.len);
    try testing.expectEqual(.empty, std.meta.activeTag(ast.nodes[@intFromEnum(branches[1])]));
}

test "Parser supports counted repetition" {
    const testing = std.testing;

    var parser = try Parser.init(testing.allocator, "a{2,4}b{3}c{5,}");
    const ast = try parser.parse();
    defer ast.deinit(testing.allocator);

    const root = ast.nodes[@intFromEnum(ast.root)].concat;
    try testing.expectEqual(@as(usize, 3), root.len);

    const first = ast.nodes[@intFromEnum(root[0])].repetition.quantifier;
    try testing.expectEqual(@as(u32, 2), first.min);
    try testing.expectEqual(@as(?u32, 4), first.max);

    const second = ast.nodes[@intFromEnum(root[1])].repetition.quantifier;
    try testing.expectEqual(@as(u32, 3), second.min);
    try testing.expectEqual(@as(?u32, 3), second.max);

    const third = ast.nodes[@intFromEnum(root[2])].repetition.quantifier;
    try testing.expectEqual(@as(u32, 5), third.min);
    try testing.expectEqual(@as(?u32, null), third.max);
}

test "Parser supports character classes and ranges" {
    const testing = std.testing;

    var parser = try Parser.init(testing.allocator, "[^a-z0-9_]");
    const ast = try parser.parse();
    defer ast.deinit(testing.allocator);

    const class = ast.nodes[@intFromEnum(ast.root)].char_class;
    try testing.expect(class.negated);
    try testing.expectEqual(@as(usize, 3), class.items.len);
    try testing.expectEqualDeep(ClassItem{ .range = .{ .start = 'a', .end = 'z' } }, class.items[0]);
    try testing.expectEqualDeep(ClassItem{ .range = .{ .start = '0', .end = '9' } }, class.items[1]);
    try testing.expectEqualDeep(ClassItem{ .literal = '_' }, class.items[2]);
}

test "Parser rejects invalid class range and quantifier" {
    const testing = std.testing;

    var class_parser = try Parser.init(testing.allocator, "[z-a]");
    try testing.expectError(error.InvalidClassRange, class_parser.parse());

    var quant_parser = try Parser.init(testing.allocator, "a{4,2}");
    try testing.expectError(error.InvalidQuantifier, quant_parser.parse());
}

test "Parser records spans for unsupported groups and trailing input" {
    const testing = std.testing;

    var group_parser = try Parser.init(testing.allocator, "(?:a)");
    try testing.expectError(error.UnsupportedGroup, group_parser.parse());
    try testing.expectEqualDeep(ParseDiagnostic{
        .err = error.UnsupportedGroup,
        .span = .{ .start = 0, .end = 1 },
    }, group_parser.lastError().?);

    var trailing_parser = try Parser.init(testing.allocator, "a)");
    try testing.expectError(error.TrailingInput, trailing_parser.parse());
    try testing.expectEqualDeep(ParseDiagnostic{
        .err = error.TrailingInput,
        .span = .{ .start = 1, .end = 2 },
    }, trailing_parser.lastError().?);
}

test "Parser supports escaped metacharacters and class edge literals" {
    const testing = std.testing;

    var parser = try Parser.init(testing.allocator, "\\^\\$\\[\\]\\(\\)\\|\\?\\+\\*\\{\\}\\\\[-^\\]]");
    const ast = try parser.parse();
    defer ast.deinit(testing.allocator);

    try testing.expectEqual(.concat, std.meta.activeTag(ast.nodes[@intFromEnum(ast.root)]));
    const root = ast.nodes[@intFromEnum(ast.root)].concat;
    try testing.expectEqual(@as(usize, 14), root.len);

    const class = ast.nodes[@intFromEnum(root[13])].char_class;
    try testing.expect(!class.negated);
    try testing.expectEqual(@as(usize, 3), class.items.len);
    try testing.expectEqualDeep(ClassItem{ .literal = '-' }, class.items[0]);
    try testing.expectEqualDeep(ClassItem{ .literal = '^' }, class.items[1]);
    try testing.expectEqualDeep(ClassItem{ .literal = ']' }, class.items[2]);
}

test "Parser treats comma and hyphen as literals outside special contexts" {
    const testing = std.testing;

    var parser = try Parser.init(testing.allocator, "a,b-c");
    const ast = try parser.parse();
    defer ast.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 6), ast.nodes.len);
    const root = ast.nodes[@intFromEnum(ast.root)];
    const children = switch (root) {
        .concat => |children| children,
        else => return error.TestUnexpectedResult,
    };

    try testing.expectEqual(@as(usize, 5), children.len);
    try testing.expectEqualDeep(Node{ .literal = 'a' }, ast.nodes[@intFromEnum(children[0])]);
    try testing.expectEqualDeep(Node{ .literal = ',' }, ast.nodes[@intFromEnum(children[1])]);
    try testing.expectEqualDeep(Node{ .literal = 'b' }, ast.nodes[@intFromEnum(children[2])]);
    try testing.expectEqualDeep(Node{ .literal = '-' }, ast.nodes[@intFromEnum(children[3])]);
    try testing.expectEqualDeep(Node{ .literal = 'c' }, ast.nodes[@intFromEnum(children[4])]);
}

test "Parser rejects malformed classes and quantifiers with spans" {
    const testing = std.testing;

    var empty_class = try Parser.init(testing.allocator, "[]");
    try testing.expectError(error.EmptyClass, empty_class.parse());
    try testing.expectEqualDeep(ParseDiagnostic{
        .err = error.EmptyClass,
        .span = .{ .start = 1, .end = 2 },
    }, empty_class.lastError().?);

    var bad_quantifier = try Parser.init(testing.allocator, "a{,2}");
    try testing.expectError(error.InvalidQuantifier, bad_quantifier.parse());
    try testing.expectEqualDeep(ParseDiagnostic{
        .err = error.InvalidQuantifier,
        .span = .{ .start = 2, .end = 3 },
    }, bad_quantifier.lastError().?);
}

test "Parser tracks capture groups in source order" {
    const testing = std.testing;

    var parser = try Parser.init(testing.allocator, "(ab)(c(d))");
    const ast = try parser.parse();
    defer ast.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 3), ast.capture_count);
    const root = ast.nodes[@intFromEnum(ast.root)].concat;
    try testing.expectEqual(.group, std.meta.activeTag(ast.nodes[@intFromEnum(root[0])]));
    try testing.expectEqual(@as(u32, 0), ast.nodes[@intFromEnum(root[0])].group.index);
    try testing.expectEqual(.group, std.meta.activeTag(ast.nodes[@intFromEnum(root[1])]));
    try testing.expectEqual(@as(u32, 1), ast.nodes[@intFromEnum(root[1])].group.index);
}

test "Parser lowers shorthand character classes to ASCII classes" {
    const testing = std.testing;

    var parser = try Parser.init(testing.allocator, "\\d\\D\\w\\W\\s\\S");
    const ast = try parser.parse();
    defer ast.deinit(testing.allocator);

    const root = ast.nodes[@intFromEnum(ast.root)].concat;
    try testing.expectEqual(@as(usize, 6), root.len);

    const digit = ast.nodes[@intFromEnum(root[0])].char_class;
    try testing.expect(!digit.negated);
    try testing.expectEqual(@as(usize, 1), digit.items.len);
    try testing.expectEqualDeep(ClassItem{ .range = .{ .start = '0', .end = '9' } }, digit.items[0]);

    const not_digit = ast.nodes[@intFromEnum(root[1])].char_class;
    try testing.expect(not_digit.negated);

    const word = ast.nodes[@intFromEnum(root[2])].char_class;
    try testing.expect(!word.negated);
    try testing.expectEqual(@as(usize, 4), word.items.len);

    const not_word = ast.nodes[@intFromEnum(root[3])].char_class;
    try testing.expect(not_word.negated);

    const space = ast.nodes[@intFromEnum(root[4])].char_class;
    try testing.expect(!space.negated);
    try testing.expectEqual(@as(usize, 6), space.items.len);

    const not_space = ast.nodes[@intFromEnum(root[5])].char_class;
    try testing.expect(not_space.negated);
}

test "Parser supports word boundary escapes" {
    const testing = std.testing;

    var parser = try Parser.init(testing.allocator, "\\bfoo\\B");
    const ast = try parser.parse();
    defer ast.deinit(testing.allocator);

    const root = ast.nodes[@intFromEnum(ast.root)].concat;
    try testing.expectEqual(@as(usize, 5), root.len);
    try testing.expectEqual(.word_boundary, std.meta.activeTag(ast.nodes[@intFromEnum(root[0])]));
    try testing.expectEqualDeep(Node{ .literal = 'f' }, ast.nodes[@intFromEnum(root[1])]);
    try testing.expectEqualDeep(Node{ .literal = 'o' }, ast.nodes[@intFromEnum(root[2])]);
    try testing.expectEqualDeep(Node{ .literal = 'o' }, ast.nodes[@intFromEnum(root[3])]);
    try testing.expectEqual(.not_word_boundary, std.meta.activeTag(ast.nodes[@intFromEnum(root[4])]));
}

test "Parser decodes Unicode literal escapes as literals" {
    const testing = std.testing;

    var parser = try Parser.init(testing.allocator, "\\u{0436}\\u{65E5}");
    const ast = try parser.parse();
    defer ast.deinit(testing.allocator);

    const root = ast.nodes[@intFromEnum(ast.root)].concat;
    try testing.expectEqual(@as(usize, 2), root.len);
    try testing.expectEqualDeep(Node{ .literal = 0x0436 }, ast.nodes[@intFromEnum(root[0])]);
    try testing.expectEqualDeep(Node{ .literal = 0x65E5 }, ast.nodes[@intFromEnum(root[1])]);
}
