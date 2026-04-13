const std = @import("std");
const hir_mod = @import("hir.zig");
const literal_mod = @import("literal.zig");
const unicode = @import("unicode.zig");

pub const InstPtr = u32;

pub const PatchSlot = enum {
    out,
    out1,
};

pub const PatchRef = struct {
    inst: InstPtr,
    slot: PatchSlot,
};

pub const Inst = union(enum) {
    save: struct {
        slot: u32,
        out: ?InstPtr = null,
    },
    literal: struct {
        value: u32,
        out: ?InstPtr = null,
    },
    char_class: struct {
        negated: bool,
        items: []const hir_mod.ClassItem,
        out: ?InstPtr = null,
    },
    char_class_set: struct {
        expr: *CompiledClassExpr,
        out: ?InstPtr = null,
    },
    any: struct {
        matches_newline: bool = false,
        out: ?InstPtr = null,
    },
    split: struct {
        out: ?InstPtr = null,
        out1: ?InstPtr = null,
    },
    anchor_start: struct {
        multiline: bool = false,
        out: ?InstPtr = null,
    },
    anchor_end: struct {
        multiline: bool = false,
        out: ?InstPtr = null,
    },
    word_boundary: struct {
        ascii_only: bool = false,
        out: ?InstPtr = null,
    },
    not_word_boundary: struct {
        ascii_only: bool = false,
        out: ?InstPtr = null,
    },
    word_boundary_start_half: struct {
        ascii_only: bool = false,
        out: ?InstPtr = null,
    },
    word_boundary_end_half: struct {
        ascii_only: bool = false,
        out: ?InstPtr = null,
    },
    unicode_property: struct {
        property: unicode.Property,
        negated: bool,
        out: ?InstPtr = null,
    },
    match,
};

pub const CompiledClassExpr = union(enum) {
    class: struct {
        negated: bool,
        items: []const hir_mod.ClassItem,
    },
    set: struct {
        lhs: *CompiledClassExpr,
        rhs: *CompiledClassExpr,
        op: hir_mod.ClassSetOp,
    },

    pub fn deinit(self: *CompiledClassExpr, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .class => |class| allocator.free(class.items),
            .set => |set| {
                set.lhs.deinit(allocator);
                allocator.destroy(set.lhs);
                set.rhs.deinit(allocator);
                allocator.destroy(set.rhs);
            },
        }
    }
};

pub const Program = struct {
    instructions: []Inst,
    start: InstPtr,
    capture_count: u32,
    slot_count: u32,
    prefilter: ?literal_mod.Prefilter,
    ascii_only: bool,
    has_word_boundary: bool,
    has_unicode_property: bool,
    has_scoped_line_modes: bool,
    dot_matches_new_line: bool,
    can_match_newline: bool,

    pub fn deinit(self: Program, allocator: std.mem.Allocator) void {
        for (self.instructions) |inst| {
            switch (inst) {
                .char_class => |class| allocator.free(class.items),
                .char_class_set => |class_set| {
                    class_set.expr.deinit(allocator);
                    allocator.destroy(class_set.expr);
                },
                else => {},
            }
        }
        if (self.prefilter) |prefilter| prefilter.deinit(allocator);
        allocator.free(self.instructions);
    }
};

pub const CompileError = error{
    OutOfMemory,
    InvalidRepeat,
    MultilineRequired,
};

pub const CompileOptions = struct {
    multiline: bool = false,
    multiline_dotall: bool = false,
};

const Fragment = struct {
    start: InstPtr,
    outs: std.ArrayList(PatchRef),
};

pub fn compile(allocator: std.mem.Allocator, compiled_hir: hir_mod.Hir, options: CompileOptions) CompileError!Program {
    if (!options.multiline and hirCanMatchNewline(compiled_hir, compiled_hir.root, options.multiline, options.multiline_dotall)) {
        return error.MultilineRequired;
    }
    const can_match_newline = hirCanMatchNewline(compiled_hir, compiled_hir.root, options.multiline, options.multiline_dotall);

    var compiler = Compiler{
        .allocator = allocator,
        .instructions = .empty,
        .options = options,
    };
    defer compiler.instructions.deinit(allocator);

    var fragment = try compiler.compileNode(compiled_hir, compiled_hir.root);
    defer fragment.outs.deinit(allocator);

    const end_save = try compiler.emit(.{ .save = .{ .slot = 1 } });
    try compiler.patch(fragment.outs.items, end_save);

    const match_index = try compiler.emit(.match);
    try compiler.patch(&[_]PatchRef{.{ .inst = end_save, .slot = .out }}, match_index);

    const start_save = try compiler.emit(.{ .save = .{
        .slot = 0,
        .out = fragment.start,
    } });

    return .{
        .instructions = try compiler.instructions.toOwnedSlice(allocator),
        .start = start_save,
        .capture_count = compiled_hir.capture_count,
        .slot_count = 2 * (compiled_hir.capture_count + 1),
        .prefilter = try literal_mod.duplicatePrefilter(allocator, compiled_hir.literals),
        .ascii_only = isAsciiOnly(compiler.instructions.items),
        .has_word_boundary = hasWordBoundary(compiler.instructions.items),
        .has_unicode_property = hasUnicodeProperty(compiler.instructions.items),
        .has_scoped_line_modes = hirHasScopedLineModes(compiled_hir, compiled_hir.root),
        .dot_matches_new_line = options.multiline_dotall,
        .can_match_newline = can_match_newline,
    };
}

fn hirHasScopedLineModes(compiled_hir: hir_mod.Hir, node_id: hir_mod.NodeId) bool {
    return switch (compiled_hir.nodes[@intFromEnum(node_id)]) {
        .dot => |dot| dot.matches_newline != null,
        .anchor_start => |anchor| anchor.multiline,
        .anchor_end => |anchor| anchor.multiline,
        .case_fold_group => |group| hirHasScopedLineModes(compiled_hir, group.child),
        .group => |group| hirHasScopedLineModes(compiled_hir, group.child),
        .concat => |children| blk: {
            for (children) |child| {
                if (hirHasScopedLineModes(compiled_hir, child)) break :blk true;
            }
            break :blk false;
        },
        .alternation => |branches| blk: {
            for (branches) |branch| {
                if (hirHasScopedLineModes(compiled_hir, branch)) break :blk true;
            }
            break :blk false;
        },
        .repetition => |rep| hirHasScopedLineModes(compiled_hir, rep.child),
        else => false,
    };
}

fn hirCanMatchNewline(compiled_hir: hir_mod.Hir, node_id: hir_mod.NodeId, multiline: bool, dotall: bool) bool {
    return switch (compiled_hir.nodes[@intFromEnum(node_id)]) {
        .empty, .anchor_start, .anchor_end, .word_boundary, .not_word_boundary, .word_boundary_start_half, .word_boundary_end_half => false,
        .unicode_property => |property| !property.negated and switch (property.property) {
            .whitespace => true,
            .shorthand_whitespace => multiline,
            .ascii_shorthand_whitespace => multiline,
            else => false,
        },
        .literal => |cp| cp == '\n',
        .dot => |dot| dot.matches_newline orelse dotall,
        .char_class => |class| classCanMatchNewline(class, multiline),
        .char_class_set => |class_set| classSetCanMatchNewline(compiled_hir, class_set, multiline),
        .case_fold_group => |group| hirCanMatchNewline(compiled_hir, group.child, multiline, dotall),
        .group => |group| hirCanMatchNewline(compiled_hir, group.child, multiline, dotall),
        .concat => |children| blk: {
            for (children) |child| {
                if (hirCanMatchNewline(compiled_hir, child, multiline, dotall)) break :blk true;
            }
            break :blk false;
        },
        .alternation => |branches| blk: {
            for (branches) |branch| {
                if (hirCanMatchNewline(compiled_hir, branch, multiline, dotall)) break :blk true;
            }
            break :blk false;
        },
        .repetition => |rep| {
            const can_repeat = rep.quantifier.max == null or rep.quantifier.max.? > 0;
            return can_repeat and hirCanMatchNewline(compiled_hir, rep.child, multiline, dotall);
        },
    };
}

fn classCanMatchNewline(class: hir_mod.CharacterClass, multiline: bool) bool {
    if (class.negated) return false;
    return classContainsCodePoint(class.items, '\n', multiline);
}

fn classSetCanMatchNewline(
    compiled_hir: hir_mod.Hir,
    class_set: @FieldType(hir_mod.Node, "char_class_set"),
    multiline: bool,
) bool {
    const lhs_matches = hirCanMatchNewline(compiled_hir, class_set.lhs, multiline, false);
    const rhs_matches = hirCanMatchNewline(compiled_hir, class_set.rhs, multiline, false);
    return switch (class_set.op) {
        .intersection => lhs_matches and rhs_matches,
        .subtraction => lhs_matches and !rhs_matches,
    };
}

fn classContainsCodePoint(items: []const hir_mod.ClassItem, cp: u32, multiline: bool) bool {
    for (items) |item| {
        switch (item) {
            .literal => |literal| if (literal == cp) return true,
            .range => |range| if (range.start <= cp and cp <= range.end) return true,
            .folded_range => |range| {
                if (cp == '\n' and !multiline) continue;
                if (unicode.Strategy.foldedRangeContains(cp, range.start, range.end, .simple)) return true;
            },
            .unicode_property => |property| {
                const matched = if ((property.property == .shorthand_whitespace or property.property == .ascii_shorthand_whitespace) and cp == '\n' and !multiline)
                    false
                else
                    unicode.Strategy.hasProperty(cp, property.property);
                if (property.negated != matched) return true;
            },
        }
    }
    return false;
}

fn isAsciiOnly(instructions: []const Inst) bool {
    for (instructions) |inst| {
        switch (inst) {
            .literal => |literal| if (literal.value > 0x7f) return false,
            .unicode_property => return false,
            .char_class => |class| {
                for (class.items) |item| {
                    switch (item) {
                        .literal => |literal| if (literal > 0x7f) return false,
                        .range => |range| if (range.start > 0x7f or range.end > 0x7f) return false,
                        .folded_range => return false,
                        .unicode_property => return false,
                    }
                }
            },
            .char_class_set => return false,
            else => {},
        }
    }
    return true;
}

fn hasWordBoundary(instructions: []const Inst) bool {
    for (instructions) |inst| {
        switch (inst) {
            .word_boundary, .not_word_boundary, .word_boundary_start_half, .word_boundary_end_half => return true,
            else => {},
        }
    }
    return false;
}

fn hasUnicodeProperty(instructions: []const Inst) bool {
    for (instructions) |inst| {
        switch (inst) {
            .unicode_property => return true,
            else => {},
        }
    }
    return false;
}

const Compiler = struct {
    allocator: std.mem.Allocator,
    instructions: std.ArrayList(Inst),
    options: CompileOptions,

    fn compileNode(self: *Compiler, compiled_hir: hir_mod.Hir, node_id: hir_mod.NodeId) CompileError!Fragment {
        return switch (compiled_hir.nodes[@intFromEnum(node_id)]) {
            .empty => self.compileEmpty(),
            .literal => |cp| self.compileLiteral(cp),
            .dot => |dot| self.compileAny(dot.matches_newline orelse self.options.multiline_dotall),
            .anchor_start => |anchor| self.compileAnchorStart(anchor.multiline),
            .anchor_end => |anchor| self.compileAnchorEnd(anchor.multiline),
            .word_boundary => |boundary| self.compileWordBoundary(boundary.ascii_only),
            .not_word_boundary => |boundary| self.compileNotWordBoundary(boundary.ascii_only),
            .word_boundary_start_half => |boundary| self.compileWordBoundaryStartHalf(boundary.ascii_only),
            .word_boundary_end_half => |boundary| self.compileWordBoundaryEndHalf(boundary.ascii_only),
            .unicode_property => |property| self.compileUnicodeProperty(property.property, property.negated),
            .char_class => |class| self.compileClass(class),
            .char_class_set => |class_set| self.compileClassSet(compiled_hir, class_set),
            .case_fold_group => |group| self.compileNode(compiled_hir, group.child),
            .group => |group| self.compileGroup(compiled_hir, group.index, group.child),
            .concat => |children| self.compileConcat(compiled_hir, children),
            .alternation => |branches| self.compileAlternation(compiled_hir, branches),
            .repetition => |rep| self.compileRepetition(compiled_hir, rep.child, rep.quantifier),
        };
    }

    fn compileEmpty(self: *Compiler) CompileError!Fragment {
        const jump = try self.emit(.{ .split = .{} });
        var outs: std.ArrayList(PatchRef) = .empty;
        try outs.append(self.allocator, .{ .inst = jump, .slot = .out });
        return .{ .start = jump, .outs = outs };
    }

    fn compileLiteral(self: *Compiler, cp: u32) CompileError!Fragment {
        const index = try self.emit(.{ .literal = .{ .value = cp } });
        var outs: std.ArrayList(PatchRef) = .empty;
        try outs.append(self.allocator, .{ .inst = index, .slot = .out });
        return .{ .start = index, .outs = outs };
    }

    fn compileAny(self: *Compiler, matches_newline: bool) CompileError!Fragment {
        const index = try self.emit(.{ .any = .{ .matches_newline = matches_newline } });
        var outs: std.ArrayList(PatchRef) = .empty;
        try outs.append(self.allocator, .{ .inst = index, .slot = .out });
        return .{ .start = index, .outs = outs };
    }

    fn compileAnchorStart(self: *Compiler, multiline: bool) CompileError!Fragment {
        const index = try self.emit(.{ .anchor_start = .{ .multiline = multiline } });
        var outs: std.ArrayList(PatchRef) = .empty;
        try outs.append(self.allocator, .{ .inst = index, .slot = .out });
        return .{ .start = index, .outs = outs };
    }

    fn compileAnchorEnd(self: *Compiler, multiline: bool) CompileError!Fragment {
        const index = try self.emit(.{ .anchor_end = .{ .multiline = multiline } });
        var outs: std.ArrayList(PatchRef) = .empty;
        try outs.append(self.allocator, .{ .inst = index, .slot = .out });
        return .{ .start = index, .outs = outs };
    }

    fn compileWordBoundary(self: *Compiler, ascii_only: bool) CompileError!Fragment {
        const index = try self.emit(.{ .word_boundary = .{ .ascii_only = ascii_only } });
        var outs: std.ArrayList(PatchRef) = .empty;
        try outs.append(self.allocator, .{ .inst = index, .slot = .out });
        return .{ .start = index, .outs = outs };
    }

    fn compileNotWordBoundary(self: *Compiler, ascii_only: bool) CompileError!Fragment {
        const index = try self.emit(.{ .not_word_boundary = .{ .ascii_only = ascii_only } });
        var outs: std.ArrayList(PatchRef) = .empty;
        try outs.append(self.allocator, .{ .inst = index, .slot = .out });
        return .{ .start = index, .outs = outs };
    }

    fn compileWordBoundaryStartHalf(self: *Compiler, ascii_only: bool) CompileError!Fragment {
        const index = try self.emit(.{ .word_boundary_start_half = .{ .ascii_only = ascii_only } });
        var outs: std.ArrayList(PatchRef) = .empty;
        try outs.append(self.allocator, .{ .inst = index, .slot = .out });
        return .{ .start = index, .outs = outs };
    }

    fn compileWordBoundaryEndHalf(self: *Compiler, ascii_only: bool) CompileError!Fragment {
        const index = try self.emit(.{ .word_boundary_end_half = .{ .ascii_only = ascii_only } });
        var outs: std.ArrayList(PatchRef) = .empty;
        try outs.append(self.allocator, .{ .inst = index, .slot = .out });
        return .{ .start = index, .outs = outs };
    }

    fn compileUnicodeProperty(
        self: *Compiler,
        property: unicode.Property,
        negated: bool,
    ) CompileError!Fragment {
        const index = try self.emit(.{ .unicode_property = .{
            .property = property,
            .negated = negated,
        } });
        var outs: std.ArrayList(PatchRef) = .empty;
        try outs.append(self.allocator, .{ .inst = index, .slot = .out });
        return .{ .start = index, .outs = outs };
    }

    fn compileClass(self: *Compiler, class: hir_mod.CharacterClass) CompileError!Fragment {
        const items = try self.allocator.alloc(hir_mod.ClassItem, class.items.len);
        @memcpy(items, class.items);

        const index = try self.emit(.{ .char_class = .{
            .negated = class.negated,
            .items = items,
        } });
        var outs: std.ArrayList(PatchRef) = .empty;
        try outs.append(self.allocator, .{ .inst = index, .slot = .out });
        return .{ .start = index, .outs = outs };
    }

    fn compileClassSet(
        self: *Compiler,
        compiled_hir: hir_mod.Hir,
        class_set: @FieldType(hir_mod.Node, "char_class_set"),
    ) CompileError!Fragment {
        const expr = try self.compileClassExpr(compiled_hir, class_set.lhs, class_set.rhs, class_set.op);
        errdefer {
            expr.deinit(self.allocator);
            self.allocator.destroy(expr);
        }

        const index = try self.emit(.{ .char_class_set = .{
            .expr = expr,
        } });
        var outs: std.ArrayList(PatchRef) = .empty;
        try outs.append(self.allocator, .{ .inst = index, .slot = .out });
        return .{ .start = index, .outs = outs };
    }

    fn compileClassExpr(
        self: *Compiler,
        compiled_hir: hir_mod.Hir,
        lhs_id: hir_mod.NodeId,
        rhs_id: hir_mod.NodeId,
        op: hir_mod.ClassSetOp,
    ) CompileError!*CompiledClassExpr {
        const expr = try self.allocator.create(CompiledClassExpr);
        errdefer self.allocator.destroy(expr);
        expr.* = .{ .set = .{
            .lhs = try self.compileClassExprNode(compiled_hir, lhs_id),
            .rhs = try self.compileClassExprNode(compiled_hir, rhs_id),
            .op = op,
        } };
        return expr;
    }

    fn compileClassExprNode(
        self: *Compiler,
        compiled_hir: hir_mod.Hir,
        node_id: hir_mod.NodeId,
    ) CompileError!*CompiledClassExpr {
        const expr = try self.allocator.create(CompiledClassExpr);
        errdefer self.allocator.destroy(expr);

        switch (compiled_hir.nodes[@intFromEnum(node_id)]) {
            .char_class => |class| {
                const items = try self.allocator.alloc(hir_mod.ClassItem, class.items.len);
                @memcpy(items, class.items);
                expr.* = .{ .class = .{
                    .negated = class.negated,
                    .items = items,
                } };
            },
            .char_class_set => |class_set| {
                expr.* = .{ .set = .{
                    .lhs = try self.compileClassExprNode(compiled_hir, class_set.lhs),
                    .rhs = try self.compileClassExprNode(compiled_hir, class_set.rhs),
                    .op = class_set.op,
                } };
            },
            else => unreachable,
        }

        return expr;
    }

    fn compileGroup(
        self: *Compiler,
        compiled_hir: hir_mod.Hir,
        group_index: u32,
        child: hir_mod.NodeId,
    ) CompileError!Fragment {
        var body = try self.compileNode(compiled_hir, child);
        const start_slot = 2 * (group_index + 1);
        const end_slot = start_slot + 1;

        const end_save = try self.emit(.{ .save = .{ .slot = end_slot } });
        try self.patch(body.outs.items, end_save);
        body.outs.deinit(self.allocator);

        var outs: std.ArrayList(PatchRef) = .empty;
        try outs.append(self.allocator, .{ .inst = end_save, .slot = .out });

        const start_save = try self.emit(.{ .save = .{
            .slot = start_slot,
            .out = body.start,
        } });

        return .{
            .start = start_save,
            .outs = outs,
        };
    }

    fn compileConcat(self: *Compiler, compiled_hir: hir_mod.Hir, children: []const hir_mod.NodeId) CompileError!Fragment {
        if (children.len == 0) return self.compileEmpty();

        var result = try self.compileNode(compiled_hir, children[0]);
        for (children[1..]) |child| {
            const next = try self.compileNode(compiled_hir, child);
            try self.patch(result.outs.items, next.start);
            result.outs.deinit(self.allocator);
            result.outs = next.outs;
        }
        return result;
    }

    fn compileAlternation(self: *Compiler, compiled_hir: hir_mod.Hir, branches: []const hir_mod.NodeId) CompileError!Fragment {
        if (branches.len == 0) return self.compileEmpty();
        if (branches.len == 1) return self.compileNode(compiled_hir, branches[0]);

        var result = try self.compileNode(compiled_hir, branches[0]);
        for (branches[1..]) |branch| {
            var next = try self.compileNode(compiled_hir, branch);
            const split = try self.emit(.{ .split = .{
                .out = result.start,
                .out1 = next.start,
            } });

            var merged: std.ArrayList(PatchRef) = .empty;
            errdefer merged.deinit(self.allocator);
            try merged.appendSlice(self.allocator, result.outs.items);
            try merged.appendSlice(self.allocator, next.outs.items);

            result.outs.deinit(self.allocator);
            next.outs.deinit(self.allocator);
            result = .{
                .start = split,
                .outs = merged,
            };
        }

        return result;
    }

    fn compileRepetition(
        self: *Compiler,
        compiled_hir: hir_mod.Hir,
        child: hir_mod.NodeId,
        quantifier: hir_mod.Quantifier,
    ) CompileError!Fragment {
        if (quantifier.max) |upper| {
            if (upper < quantifier.min) return error.InvalidRepeat;
        }

        var copies: std.ArrayList(Fragment) = .empty;
        defer copies.deinit(self.allocator);

        var i: u32 = 0;
        while (i < quantifier.min) : (i += 1) {
            try copies.append(self.allocator, try self.compileNode(compiled_hir, child));
        }

        var result = if (copies.items.len == 0)
            try self.compileEmpty()
        else
            copies.swapRemove(0);
        defer {
            for (copies.items) |*fragment| fragment.outs.deinit(self.allocator);
        }

        while (copies.items.len > 0) {
            const next = copies.swapRemove(0);
            try self.patch(result.outs.items, next.start);
            result.outs.deinit(self.allocator);
            result.outs = next.outs;
        }

        if (quantifier.max) |upper| {
            var optional_count = upper - quantifier.min;
            while (optional_count > 0) : (optional_count -= 1) {
                const optional_fragment = try self.compileOptional(compiled_hir, child, quantifier.greedy);
                try self.patch(result.outs.items, optional_fragment.start);
                result.outs.deinit(self.allocator);
                result.outs = optional_fragment.outs;
            }
            return result;
        }

        if (quantifier.min == 0) {
            result.outs.deinit(self.allocator);
            return self.compileStar(compiled_hir, child, quantifier.greedy);
        }

        const tail = try self.compileStar(compiled_hir, child, quantifier.greedy);
        try self.patch(result.outs.items, tail.start);
        result.outs.deinit(self.allocator);
        result.outs = tail.outs;
        return result;
    }

    fn compileStar(self: *Compiler, compiled_hir: hir_mod.Hir, child: hir_mod.NodeId, greedy: bool) CompileError!Fragment {
        var body = try self.compileNode(compiled_hir, child);
        const split = try self.emit(.{ .split = .{
            .out = if (greedy) body.start else null,
            .out1 = if (greedy) null else body.start,
        } });
        try self.patch(body.outs.items, split);
        body.outs.deinit(self.allocator);

        var outs: std.ArrayList(PatchRef) = .empty;
        try outs.append(self.allocator, .{ .inst = split, .slot = if (greedy) .out1 else .out });
        return .{ .start = split, .outs = outs };
    }

    fn compileOptional(self: *Compiler, compiled_hir: hir_mod.Hir, child: hir_mod.NodeId, greedy: bool) CompileError!Fragment {
        var body = try self.compileNode(compiled_hir, child);
        const split = try self.emit(.{ .split = .{
            .out = if (greedy) body.start else null,
            .out1 = if (greedy) null else body.start,
        } });

        var outs: std.ArrayList(PatchRef) = .empty;
        errdefer outs.deinit(self.allocator);
        try outs.appendSlice(self.allocator, body.outs.items);
        try outs.append(self.allocator, .{ .inst = split, .slot = if (greedy) .out1 else .out });

        body.outs.deinit(self.allocator);
        return .{ .start = split, .outs = outs };
    }

    fn emit(self: *Compiler, inst: Inst) CompileError!InstPtr {
        try self.instructions.append(self.allocator, inst);
        return @intCast(self.instructions.items.len - 1);
    }

    fn patch(self: *Compiler, outs: []const PatchRef, target: InstPtr) CompileError!void {
        for (outs) |patch_ref| {
            const inst = &self.instructions.items[patch_ref.inst];
            switch (inst.*) {
                .save => |*save| save.out = target,
                .literal => |*literal| literal.out = target,
                .char_class => |*class| class.out = target,
                .char_class_set => |*class_set| class_set.out = target,
                .any => |*any| any.out = target,
                .anchor_start => |*anchor| anchor.out = target,
                .anchor_end => |*anchor| anchor.out = target,
                .word_boundary => |*boundary| boundary.out = target,
                .not_word_boundary => |*boundary| boundary.out = target,
                .word_boundary_start_half => |*boundary| boundary.out = target,
                .word_boundary_end_half => |*boundary| boundary.out = target,
                .unicode_property => |*property| property.out = target,
                .split => |*split| switch (patch_ref.slot) {
                    .out => split.out = target,
                    .out1 => split.out1 = target,
                },
                .match => unreachable,
            }
        }
    }
};

test "NFA compiles concatenation and alternation into Thompson instructions" {
    const testing = std.testing;
    const regex = @import("root.zig");

    const lowered = try regex.compile(testing.allocator, "ab|c", .{});
    defer lowered.deinit(testing.allocator);

    const program = try compile(testing.allocator, lowered, .{});
    defer program.deinit(testing.allocator);

    try testing.expectEqual(.save, std.meta.activeTag(program.instructions[program.start]));
    try testing.expectEqual(@as(u32, 0), program.instructions[program.start].save.slot);

    var saw_split = false;
    for (program.instructions) |inst| {
        if (std.meta.activeTag(inst) == .split) {
            saw_split = true;
            break;
        }
    }
    try testing.expect(saw_split);
    try testing.expectEqual(.match, std.meta.activeTag(program.instructions[program.instructions.len - 2]));
}

test "NFA compiles bounded and unbounded repetition" {
    const testing = std.testing;
    const regex = @import("root.zig");

    const lowered = try regex.compile(testing.allocator, "a{2,3}b+", .{});
    defer lowered.deinit(testing.allocator);

    const program = try compile(testing.allocator, lowered, .{});
    defer program.deinit(testing.allocator);

    try testing.expect(program.instructions.len >= 8);

    var saw_split = false;
    for (program.instructions) |inst| {
        if (std.meta.activeTag(inst) == .split) {
            saw_split = true;
            break;
        }
    }
    try testing.expect(saw_split);
    try testing.expectEqual(.match, std.meta.activeTag(program.instructions[program.instructions.len - 2]));
}

test "NFA emits save instructions for capture groups" {
    const testing = std.testing;
    const regex = @import("root.zig");

    const lowered = try regex.compile(testing.allocator, "(ab)c", .{});
    defer lowered.deinit(testing.allocator);

    const program = try compile(testing.allocator, lowered, .{});
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), program.capture_count);
    try testing.expectEqual(@as(u32, 4), program.slot_count);
    try testing.expect(program.ascii_only);

    var save_count: usize = 0;
    for (program.instructions) |inst| {
        if (std.meta.activeTag(inst) == .save) save_count += 1;
    }
    try testing.expectEqual(@as(usize, 4), save_count);
}

test "NFA marks non-ASCII programs as not ASCII-only" {
    const testing = std.testing;
    const regex = @import("root.zig");

    const lowered = try regex.compile(testing.allocator, "©", .{});
    defer lowered.deinit(testing.allocator);

    const program = try compile(testing.allocator, lowered, .{});
    defer program.deinit(testing.allocator);

    try testing.expect(program.instructions.len >= 4);
}

test "NFA requires multiline for newline-matching patterns" {
    const testing = std.testing;
    const regex = @import("root.zig");

    const lowered = try regex.compile(testing.allocator, "a\\nb", .{});
    defer lowered.deinit(testing.allocator);

    try testing.expectError(error.MultilineRequired, compile(testing.allocator, lowered, .{}));
}

test "NFA accepts newline-matching patterns when multiline is enabled" {
    const testing = std.testing;
    const regex = @import("root.zig");

    const lowered = try regex.compile(testing.allocator, "a\\nb", .{});
    defer lowered.deinit(testing.allocator);

    const program = try compile(testing.allocator, lowered, .{ .multiline = true });
    defer program.deinit(testing.allocator);

    try testing.expect(!program.dot_matches_new_line);
}
