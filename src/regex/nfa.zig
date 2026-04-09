const std = @import("std");
const hir_mod = @import("hir.zig");

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
    any: struct {
        out: ?InstPtr = null,
    },
    split: struct {
        out: ?InstPtr = null,
        out1: ?InstPtr = null,
    },
    anchor_start: struct {
        out: ?InstPtr = null,
    },
    anchor_end: struct {
        out: ?InstPtr = null,
    },
    match,
};

pub const Program = struct {
    instructions: []Inst,
    start: InstPtr,
    capture_count: u32,
    slot_count: u32,

    pub fn deinit(self: Program, allocator: std.mem.Allocator) void {
        for (self.instructions) |inst| {
            switch (inst) {
                .char_class => |class| allocator.free(class.items),
                else => {},
            }
        }
        allocator.free(self.instructions);
    }
};

pub const CompileError = error{
    OutOfMemory,
    InvalidRepeat,
};

const Fragment = struct {
    start: InstPtr,
    outs: std.ArrayList(PatchRef),
};

pub fn compile(allocator: std.mem.Allocator, compiled_hir: hir_mod.Hir) CompileError!Program {
    var compiler = Compiler{
        .allocator = allocator,
        .instructions = .empty,
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
    };
}

const Compiler = struct {
    allocator: std.mem.Allocator,
    instructions: std.ArrayList(Inst),

    fn compileNode(self: *Compiler, compiled_hir: hir_mod.Hir, node_id: hir_mod.NodeId) CompileError!Fragment {
        return switch (compiled_hir.nodes[@intFromEnum(node_id)]) {
            .empty => self.compileEmpty(),
            .literal => |cp| self.compileLiteral(cp),
            .dot => self.compileAny(),
            .anchor_start => self.compileAnchorStart(),
            .anchor_end => self.compileAnchorEnd(),
            .char_class => |class| self.compileClass(class),
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

    fn compileAny(self: *Compiler) CompileError!Fragment {
        const index = try self.emit(.{ .any = .{} });
        var outs: std.ArrayList(PatchRef) = .empty;
        try outs.append(self.allocator, .{ .inst = index, .slot = .out });
        return .{ .start = index, .outs = outs };
    }

    fn compileAnchorStart(self: *Compiler) CompileError!Fragment {
        const index = try self.emit(.{ .anchor_start = .{} });
        var outs: std.ArrayList(PatchRef) = .empty;
        try outs.append(self.allocator, .{ .inst = index, .slot = .out });
        return .{ .start = index, .outs = outs };
    }

    fn compileAnchorEnd(self: *Compiler) CompileError!Fragment {
        const index = try self.emit(.{ .anchor_end = .{} });
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
            const next = try self.compileNode(compiled_hir, branch);
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
                const optional_fragment = try self.compileOptional(compiled_hir, child);
                try self.patch(result.outs.items, optional_fragment.start);
                result.outs.deinit(self.allocator);
                result.outs = optional_fragment.outs;
            }
            return result;
        }

        if (quantifier.min == 0) {
            result.outs.deinit(self.allocator);
            return self.compileStar(compiled_hir, child);
        }

        const tail = try self.compileStar(compiled_hir, child);
        try self.patch(result.outs.items, tail.start);
        result.outs.deinit(self.allocator);
        result.outs = tail.outs;
        return result;
    }

    fn compileStar(self: *Compiler, compiled_hir: hir_mod.Hir, child: hir_mod.NodeId) CompileError!Fragment {
        var body = try self.compileNode(compiled_hir, child);
        const split = try self.emit(.{ .split = .{
            .out = body.start,
            .out1 = null,
        } });
        try self.patch(body.outs.items, split);
        body.outs.deinit(self.allocator);

        var outs: std.ArrayList(PatchRef) = .empty;
        try outs.append(self.allocator, .{ .inst = split, .slot = .out1 });
        return .{ .start = split, .outs = outs };
    }

    fn compileOptional(self: *Compiler, compiled_hir: hir_mod.Hir, child: hir_mod.NodeId) CompileError!Fragment {
        var body = try self.compileNode(compiled_hir, child);
        const split = try self.emit(.{ .split = .{
            .out = body.start,
            .out1 = null,
        } });

        var outs: std.ArrayList(PatchRef) = .empty;
        errdefer outs.deinit(self.allocator);
        try outs.appendSlice(self.allocator, body.outs.items);
        try outs.append(self.allocator, .{ .inst = split, .slot = .out1 });

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
                .any => |*any| any.out = target,
                .anchor_start => |*anchor| anchor.out = target,
                .anchor_end => |*anchor| anchor.out = target,
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

    const program = try compile(testing.allocator, lowered);
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

    const program = try compile(testing.allocator, lowered);
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

    const program = try compile(testing.allocator, lowered);
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), program.capture_count);
    try testing.expectEqual(@as(u32, 4), program.slot_count);

    var save_count: usize = 0;
    for (program.instructions) |inst| {
        if (std.meta.activeTag(inst) == .save) save_count += 1;
    }
    try testing.expectEqual(@as(usize, 4), save_count);
}
