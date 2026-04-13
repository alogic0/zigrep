const std = @import("std");
const parser = @import("../parser.zig");
const literal_mod = @import("literal.zig");
const unicode = @import("unicode.zig");

pub const NodeId = enum(u32) {
    _,
};

pub const ClassRange = parser.ClassRange;
pub const ClassItem = union(enum) {
    literal: u32,
    range: ClassRange,
    folded_range: ClassRange,
    unicode_property: struct {
        property: unicode.Property,
        negated: bool,
    },
};
pub const CharacterClass = struct {
    negated: bool,
    items: []const ClassItem,
};
pub const Quantifier = parser.Quantifier;

pub const Node = union(enum) {
    empty,
    literal: u32,
    dot,
    anchor_start,
    anchor_end,
    word_boundary: struct {
        ascii_only: bool,
    },
    not_word_boundary: struct {
        ascii_only: bool,
    },
    unicode_property: struct {
        property: unicode.Property,
        negated: bool,
    },
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

pub const Prefix = struct {
    exact: bool,
    bytes: []const u8,
};

pub const FastPath = union(enum) {
    none,
    exact_literal: []const u8,
    literal_prefix: []const u8,
};

pub const Hir = struct {
    nodes: []Node,
    root: NodeId,
    capture_count: u32,
    literals: []literal_mod.LiteralSequence,
    prefix: Prefix,
    fast_path: FastPath,

    pub fn deinit(self: Hir, allocator: std.mem.Allocator) void {
        for (self.nodes) |node| {
            switch (node) {
                .concat => |children| allocator.free(children),
                .alternation => |branches| allocator.free(branches),
                .char_class => |class| allocator.free(class.items),
                else => {},
            }
        }

        allocator.free(self.nodes);
        allocator.free(self.literals);
        allocator.free(self.prefix.bytes);
    }
};

pub const LowerError = error{
    OutOfMemory,
};

pub const CaseFoldError = error{
    OutOfMemory,
    UnsupportedCaseInsensitivePattern,
};

const max_case_folded_range_size: u32 = 2048;

pub fn lower(allocator: std.mem.Allocator, ast: parser.Ast) LowerError!Hir {
    var nodes: std.ArrayList(Node) = .empty;
    errdefer {
        for (nodes.items) |node| {
            switch (node) {
                .concat => |children| allocator.free(children),
                .alternation => |branches| allocator.free(branches),
                .char_class => |class| allocator.free(class.items),
                else => {},
            }
        }
        nodes.deinit(allocator);
    }

    const root = try lowerNode(allocator, ast, ast.root, &nodes);
    const prefix = try extractPrefix(allocator, nodes.items, root);
    errdefer allocator.free(prefix.bytes);
    const literals = try extractLiterals(allocator, prefix.bytes);

    return .{
        .nodes = try nodes.toOwnedSlice(allocator),
        .root = root,
        .capture_count = ast.capture_count,
        .literals = literals,
        .prefix = prefix,
        .fast_path = if (prefix.bytes.len == 0)
            .none
        else if (prefix.exact)
            .{ .exact_literal = prefix.bytes }
        else
            .{ .literal_prefix = prefix.bytes },
    };
}

pub fn applySimpleCaseFold(allocator: std.mem.Allocator, hir: *Hir) CaseFoldError!void {
    for (hir.nodes) |*node| {
        switch (node.*) {
            .literal => |cp| {
                node.* = .{ .char_class = try foldedLiteralClass(allocator, cp) };
            },
            .unicode_property => |property| {
                node.* = .{ .unicode_property = .{
                    .property = foldCaseProperty(property.property),
                    .negated = property.negated,
                } };
            },
            .char_class => |class| {
                if (classIsUniversalScalarClass(class)) {
                    allocator.free(class.items);
                    node.* = .{ .unicode_property = .{
                        .property = .any,
                        .negated = false,
                    } };
                    continue;
                }

                const folded = try foldedCharacterClass(allocator, class);
                allocator.free(class.items);
                node.* = .{ .char_class = folded };
            },
            else => {},
        }
    }

    allocator.free(hir.prefix.bytes);
    hir.prefix = .{
        .exact = false,
        .bytes = try allocator.alloc(u8, 0),
    };
    allocator.free(hir.literals);
    hir.literals = try allocator.alloc(literal_mod.LiteralSequence, 0);
    hir.fast_path = .none;
}

fn lowerNode(
    allocator: std.mem.Allocator,
    ast: parser.Ast,
    node_id: parser.NodeId,
    out: *std.ArrayList(Node),
) LowerError!NodeId {
    const node = ast.nodes[@intFromEnum(node_id)];
    const lowered: Node = switch (node) {
        .empty => .empty,
        .literal => |cp| .{ .literal = cp },
        .dot => .dot,
        .anchor_start => .anchor_start,
        .anchor_end => .anchor_end,
        .word_boundary => |boundary| .{ .word_boundary = .{ .ascii_only = boundary.ascii_only } },
        .not_word_boundary => |boundary| .{ .not_word_boundary = .{ .ascii_only = boundary.ascii_only } },
        .unicode_property => |property| .{ .unicode_property = .{
            .property = property.property,
            .negated = property.negated,
        } },
        .char_class => |class| .{ .char_class = .{
            .negated = class.negated,
            .items = try lowerClassItems(allocator, class.items),
        } },
        .group => |group| .{ .group = .{
            .index = group.index,
            .child = try lowerNode(allocator, ast, group.child, out),
        } },
        .concat => |children| .{ .concat = try lowerChildren(allocator, ast, children, out) },
        .alternation => |branches| .{ .alternation = try lowerChildren(allocator, ast, branches, out) },
        .repetition => |rep| .{ .repetition = .{
            .child = try lowerNode(allocator, ast, rep.child, out),
            .quantifier = rep.quantifier,
        } },
    };

    try out.append(allocator, lowered);
    return @enumFromInt(out.items.len - 1);
}

fn lowerChildren(
    allocator: std.mem.Allocator,
    ast: parser.Ast,
    input: []const parser.NodeId,
    out: *std.ArrayList(Node),
) LowerError![]const NodeId {
    var lowered = try allocator.alloc(NodeId, input.len);
    errdefer allocator.free(lowered);

    for (input, 0..) |child, index| {
        lowered[index] = try lowerNode(allocator, ast, child, out);
    }

    return lowered;
}

fn lowerClassItems(allocator: std.mem.Allocator, items: []const parser.ClassItem) LowerError![]const ClassItem {
    const lowered = try allocator.alloc(ClassItem, items.len);
    errdefer allocator.free(lowered);

    for (items, 0..) |item, index| {
        lowered[index] = switch (item) {
            .literal => |cp| .{ .literal = cp },
            .range => |range| .{ .range = range },
            .unicode_property => |property| .{ .unicode_property = .{
                .property = property.property,
                .negated = property.negated,
            } },
        };
    }

    return lowered;
}

fn dupClassItems(allocator: std.mem.Allocator, items: []const ClassItem) LowerError![]const ClassItem {
    const duped = try allocator.alloc(ClassItem, items.len);
    @memcpy(duped, items);
    return duped;
}

fn extractPrefix(allocator: std.mem.Allocator, nodes: []const Node, root: NodeId) LowerError!Prefix {
    return prefixForNode(allocator, nodes, root);
}

fn prefixForNode(allocator: std.mem.Allocator, nodes: []const Node, node_id: NodeId) LowerError!Prefix {
    switch (nodes[@intFromEnum(node_id)]) {
        .empty => return .{
            .exact = true,
            .bytes = try allocator.alloc(u8, 0),
        },
        .unicode_property => return .{
            .exact = false,
            .bytes = try allocator.alloc(u8, 0),
        },
        .literal => |cp| {
            if (cp > 0x7f) {
                return .{
                    .exact = false,
                    .bytes = try allocator.alloc(u8, 0),
                };
            }

            const bytes = try allocator.alloc(u8, 1);
            bytes[0] = @as(u8, @intCast(cp));
            return .{ .exact = true, .bytes = bytes };
        },
        .concat => |children| {
            var builder: std.ArrayList(u8) = .empty;
            defer builder.deinit(allocator);

            var exact = true;
            for (children) |child| {
                const child_prefix = try prefixForNode(allocator, nodes, child);
                defer allocator.free(child_prefix.bytes);

                try builder.appendSlice(allocator, child_prefix.bytes);
                if (!child_prefix.exact) {
                    exact = false;
                    break;
                }
            }

            return .{
                .exact = exact,
                .bytes = try builder.toOwnedSlice(allocator),
            };
        },
        .alternation => |branches| {
            if (branches.len == 0) {
                return .{
                    .exact = false,
                    .bytes = try allocator.alloc(u8, 0),
                };
            }

            const first = try prefixForNode(allocator, nodes, branches[0]);
            defer allocator.free(first.bytes);

            var common_len = first.bytes.len;
            var exact = first.exact;

            for (branches[1..]) |branch| {
                const branch_prefix = try prefixForNode(allocator, nodes, branch);
                defer allocator.free(branch_prefix.bytes);

                common_len = @min(common_len, branch_prefix.bytes.len);
                var i: usize = 0;
                while (i < common_len and first.bytes[i] == branch_prefix.bytes[i]) : (i += 1) {}
                common_len = i;
                exact = exact and branch_prefix.exact and common_len == first.bytes.len and common_len == branch_prefix.bytes.len;
            }

            const bytes = try allocator.alloc(u8, common_len);
            @memcpy(bytes, first.bytes[0..common_len]);
            return .{ .exact = exact, .bytes = bytes };
        },
        else => return .{
            .exact = false,
            .bytes = try allocator.alloc(u8, 0),
        },
    }
}

fn extractLiterals(allocator: std.mem.Allocator, prefix: []const u8) LowerError![]literal_mod.LiteralSequence {
    if (prefix.len == 0) return allocator.alloc(literal_mod.LiteralSequence, 0);

    var literals = try allocator.alloc(literal_mod.LiteralSequence, 1);
    literals[0] = .{ .bytes = prefix };
    return literals;
}

fn foldedLiteralClass(allocator: std.mem.Allocator, cp: u32) CaseFoldError!CharacterClass {
    var items: std.ArrayList(ClassItem) = .empty;
    errdefer items.deinit(allocator);

    try appendFoldedCodePointItems(allocator, &items, cp);
    return .{
        .negated = false,
        .items = try items.toOwnedSlice(allocator),
    };
}

fn foldedCharacterClass(allocator: std.mem.Allocator, class: CharacterClass) CaseFoldError!CharacterClass {
    var items: std.ArrayList(ClassItem) = .empty;
    errdefer items.deinit(allocator);

    for (class.items) |item| {
        switch (item) {
            .literal => |cp| try appendFoldedCodePointItems(allocator, &items, cp),
            .range => |range| {
                const range_len = range.end - range.start + 1;
                if (range_len > max_case_folded_range_size) {
                    try items.append(allocator, .{ .folded_range = range });
                    continue;
                }

                var cp = range.start;
                while (cp <= range.end) : (cp += 1) {
                    try appendFoldedCodePointItems(allocator, &items, cp);
                }
            },
            .folded_range => |range| try items.append(allocator, .{ .folded_range = range }),
            .unicode_property => |property| try items.append(allocator, .{
                .unicode_property = .{
                    .property = foldCaseProperty(property.property),
                    .negated = property.negated,
                },
            }),
        }
    }

    return .{
        .negated = class.negated,
        .items = try items.toOwnedSlice(allocator),
    };
}

fn classIsUniversalScalarClass(class: CharacterClass) bool {
    if (class.negated or class.items.len != 1) return false;
    return switch (class.items[0]) {
        .range => |range| range.start == 0 and range.end == 0x10FFFF,
        else => false,
    };
}

fn appendFoldedCodePointItems(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(ClassItem),
    cp: u32,
) CaseFoldError!void {
    const equivalents = try simpleCaseFoldSetAlloc(allocator, cp);
    defer allocator.free(equivalents);

    for (equivalents) |equivalent| {
        try appendUniqueLiteralItem(allocator, items, equivalent);
    }
}

fn appendUniqueLiteralItem(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(ClassItem),
    cp: u32,
) CaseFoldError!void {
    for (items.items) |item| {
        switch (item) {
            .literal => |existing| if (existing == cp) return,
            .range => |range| if (range.start <= cp and cp <= range.end) return,
            .folded_range => |range| if (range.start <= cp and cp <= range.end) return,
            .unicode_property => {},
        }
    }
    try items.append(allocator, .{ .literal = cp });
}

fn simpleCaseFoldSetAlloc(allocator: std.mem.Allocator, cp: u32) CaseFoldError![]u32 {
    const fold = try unicode.Strategy.foldSet(allocator, cp, .simple);
    defer fold.deinit(allocator);
    return allocator.dupe(u32, fold.equivalents);
}

fn foldCaseProperty(property: unicode.Property) unicode.Property {
    return switch (property) {
        .lowercase, .uppercase, .titlecase_letter => .casefolded_case_letter,
        else => property,
    };
}

test "HIR lowering preserves shape and extracts prefix analysis" {
    const testing = std.testing;

    var p = try parser.Parser.init(testing.allocator, "abc|abd");
    const ast = try p.parse();
    defer ast.deinit(testing.allocator);

    const hir = try lower(testing.allocator, ast);
    defer hir.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), hir.capture_count);
    try testing.expectEqual(.alternation, std.meta.activeTag(hir.nodes[@intFromEnum(hir.root)]));
    try testing.expectEqualStrings("ab", hir.prefix.bytes);
    try testing.expect(!hir.prefix.exact);
    try testing.expectEqual(@as(usize, 1), hir.literals.len);
    try testing.expectEqualStrings("ab", hir.literals[0].bytes);
    try testing.expectEqual(.literal_prefix, std.meta.activeTag(hir.fast_path));
}

test "HIR lowering detects exact literal matches" {
    const testing = std.testing;

    var p = try parser.Parser.init(testing.allocator, "literal");
    const ast = try p.parse();
    defer ast.deinit(testing.allocator);

    const hir = try lower(testing.allocator, ast);
    defer hir.deinit(testing.allocator);

    try testing.expect(hir.prefix.exact);
    try testing.expectEqualStrings("literal", hir.prefix.bytes);
    try testing.expectEqual(.exact_literal, std.meta.activeTag(hir.fast_path));
}

test "HIR lowering preserves capture groups" {
    const testing = std.testing;

    var p = try parser.Parser.init(testing.allocator, "(ab)(c)");
    const ast = try p.parse();
    defer ast.deinit(testing.allocator);

    const hir = try lower(testing.allocator, ast);
    defer hir.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 2), hir.capture_count);
    const root = hir.nodes[@intFromEnum(hir.root)].concat;
    try testing.expectEqual(.group, std.meta.activeTag(hir.nodes[@intFromEnum(root[0])]));
    try testing.expectEqual(@as(u32, 0), hir.nodes[@intFromEnum(root[0])].group.index);
    try testing.expectEqual(.group, std.meta.activeTag(hir.nodes[@intFromEnum(root[1])]));
    try testing.expectEqual(@as(u32, 1), hir.nodes[@intFromEnum(root[1])].group.index);
}
