const std = @import("std");
const reader = @import("../reader.zig");
const dfa = @import("dfa.zig");
const nfa = @import("nfa.zig");

pub const MatchError = reader.ReaderError || error{
    OutOfMemory,
};

pub const Capture = struct {
    start: ?usize = null,
    end: ?usize = null,
};

pub const Match = struct {
    span: Capture,
    groups: []Capture,

    pub fn deinit(self: Match, allocator: std.mem.Allocator) void {
        allocator.free(self.groups);
    }
};

const Thread = struct {
    inst_ptr: nfa.InstPtr,
    slots: []?usize,
};

pub const MatchEngine = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MatchEngine {
        return .{ .allocator = allocator };
    }

    pub fn isMatch(self: *const MatchEngine, program: nfa.Program, haystack: []const u8) MatchError!bool {
        if (program.capture_count == 0) {
            var cache = dfa.Cache.init(self.allocator, &program);
            defer cache.deinit();
            return cache.isMatch(haystack);
        }

        const found = try self.firstMatch(program, haystack);
        if (found) |match| {
            match.deinit(self.allocator);
            return true;
        }
        return false;
    }

    pub fn firstMatch(self: *const MatchEngine, program: nfa.Program, haystack: []const u8) MatchError!?Match {
        if (program.instructions.len == 0) return null;
        if (program.prefilter) |prefilter| {
            if (!prefilter.mayMatch(haystack)) return null;
        }
        if (program.ascii_only and std.ascii.isAscii(haystack)) {
            return self.firstMatchAscii(program, haystack);
        }

        var current: std.ArrayList(Thread) = .empty;
        defer self.deinitThreadList(&current);

        var next: std.ArrayList(Thread) = .empty;
        defer self.deinitThreadList(&next);

        var visited = try self.allocator.alloc(bool, program.instructions.len);
        defer self.allocator.free(visited);

        const start_slots = try self.allocSlots(program.slot_count);
        defer self.allocator.free(start_slots);

        @memset(visited, false);
        if (try self.addThread(program, &current, &visited, program.start, start_slots, 0, haystack.len)) |match| return match;

        var input = reader.CodePointReader(u8).init(haystack);
        while (true) {
            const start = input.pos;
            const cp = (try input.next()) orelse break;
            const end = input.pos;

            self.clearThreadList(&next);
            @memset(visited, false);

            for (current.items) |thread| {
                if (try self.step(program, &next, &visited, thread, cp, end, haystack.len)) |match| return match;
            }
            self.clearThreadList(&current);

            std.mem.swap(std.ArrayList(Thread), &current, &next);

            @memset(visited, false);
            if (start != end) {
                const restart_slots = try self.allocSlots(program.slot_count);
                defer self.allocator.free(restart_slots);
                if (try self.addThread(program, &current, &visited, program.start, restart_slots, end, haystack.len)) |match| return match;
            }
        }

        return null;
    }

    fn firstMatchAscii(self: *const MatchEngine, program: nfa.Program, haystack: []const u8) MatchError!?Match {
        var current: std.ArrayList(Thread) = .empty;
        defer self.deinitThreadList(&current);

        var next: std.ArrayList(Thread) = .empty;
        defer self.deinitThreadList(&next);

        var visited = try self.allocator.alloc(bool, program.instructions.len);
        defer self.allocator.free(visited);

        const start_slots = try self.allocSlots(program.slot_count);
        defer self.allocator.free(start_slots);

        @memset(visited, false);
        if (try self.addThread(program, &current, &visited, program.start, start_slots, 0, haystack.len)) |match| return match;

        for (haystack, 0..) |byte, index| {
            self.clearThreadList(&next);
            @memset(visited, false);

            for (current.items) |thread| {
                if (try self.step(program, &next, &visited, thread, byte, index + 1, haystack.len)) |match| return match;
            }
            self.clearThreadList(&current);

            std.mem.swap(std.ArrayList(Thread), &current, &next);

            @memset(visited, false);
            const restart_slots = try self.allocSlots(program.slot_count);
            defer self.allocator.free(restart_slots);
            if (try self.addThread(program, &current, &visited, program.start, restart_slots, index + 1, haystack.len)) |match| return match;
        }

        return null;
    }

    fn step(
        self: *const MatchEngine,
        program: nfa.Program,
        list: *std.ArrayList(Thread),
        visited: []bool,
        thread: Thread,
        cp: u32,
        next_pos: usize,
        input_len: usize,
    ) MatchError!?Match {
        switch (program.instructions[thread.inst_ptr]) {
            .literal => |literal| {
                if (literal.value != cp) return null;
                return self.addThread(program, list, visited, literal.out.?, thread.slots, next_pos, input_len);
            },
            .char_class => |class| {
                if (!classMatches(class, cp)) return null;
                return self.addThread(program, list, visited, class.out.?, thread.slots, next_pos, input_len);
            },
            .any => |any| {
                if (cp == '\n') return null;
                return self.addThread(program, list, visited, any.out.?, thread.slots, next_pos, input_len);
            },
            else => return null,
        }
    }

    fn addThread(
        self: *const MatchEngine,
        program: nfa.Program,
        list: *std.ArrayList(Thread),
        visited: []bool,
        inst_ptr: nfa.InstPtr,
        slots: []const ?usize,
        pos: usize,
        input_len: usize,
    ) MatchError!?Match {
        if (visited[inst_ptr]) return null;
        visited[inst_ptr] = true;

        switch (program.instructions[inst_ptr]) {
            .save => |save| {
                const updated_slots = try self.cloneSlots(slots);
                defer self.allocator.free(updated_slots);
                updated_slots[save.slot] = pos;
                return self.addThread(program, list, visited, save.out.?, updated_slots, pos, input_len);
            },
            .split => |split| {
                if (split.out) |out| {
                    if (try self.addThread(program, list, visited, out, slots, pos, input_len)) |match| return match;
                }
                if (split.out1) |out1| {
                    if (try self.addThread(program, list, visited, out1, slots, pos, input_len)) |match| return match;
                }
                return null;
            },
            .anchor_start => |anchor| {
                if (pos != 0) return null;
                return self.addThread(program, list, visited, anchor.out.?, slots, pos, input_len);
            },
            .anchor_end => |anchor| {
                if (pos != input_len) return null;
                return self.addThread(program, list, visited, anchor.out.?, slots, pos, input_len);
            },
            .match => return try self.buildMatch(program, slots),
            .literal, .char_class, .any => {
                if (!hasThread(list.items, inst_ptr)) {
                    try list.append(self.allocator, .{
                        .inst_ptr = inst_ptr,
                        .slots = try self.cloneSlots(slots),
                    });
                }
                return null;
            },
        }
    }

    fn allocSlots(self: *const MatchEngine, slot_count: u32) MatchError![]?usize {
        const slots = try self.allocator.alloc(?usize, slot_count);
        @memset(slots, null);
        return slots;
    }

    fn cloneSlots(self: *const MatchEngine, slots: []const ?usize) MatchError![]?usize {
        const cloned = try self.allocator.alloc(?usize, slots.len);
        @memcpy(cloned, slots);
        return cloned;
    }

    fn buildMatch(self: *const MatchEngine, program: nfa.Program, slots: []const ?usize) MatchError!Match {
        const groups = try self.allocator.alloc(Capture, program.capture_count);
        errdefer self.allocator.free(groups);

        for (groups, 0..) |*group, index| {
            const base = 2 * (index + 1);
            group.* = .{
                .start = slots[base],
                .end = slots[base + 1],
            };
        }

        return .{
            .span = .{
                .start = slots[0],
                .end = slots[1],
            },
            .groups = groups,
        };
    }

    fn clearThreadList(self: *const MatchEngine, list: *std.ArrayList(Thread)) void {
        for (list.items) |thread| self.allocator.free(thread.slots);
        list.clearRetainingCapacity();
    }

    fn deinitThreadList(self: *const MatchEngine, list: *std.ArrayList(Thread)) void {
        self.clearThreadList(list);
        list.deinit(self.allocator);
    }
};

fn hasThread(threads: []const Thread, inst_ptr: nfa.InstPtr) bool {
    for (threads) |thread| {
        if (thread.inst_ptr == inst_ptr) return true;
    }
    return false;
}

fn classMatches(class: nfa.Inst.char_class, cp: u32) bool {
    var matched = false;
    for (class.items) |item| {
        switch (item) {
            .literal => |literal| {
                if (literal == cp) {
                    matched = true;
                    break;
                }
            },
            .range => |range| {
                if (range.start <= cp and cp <= range.end) {
                    matched = true;
                    break;
                }
            },
        }
    }
    return if (class.negated) !matched else matched;
}

fn compileProgram(allocator: std.mem.Allocator, pattern: []const u8) !nfa.Program {
    const regex = @import("root.zig");

    const lowered = try regex.compile(allocator, pattern, .{});
    defer lowered.deinit(allocator);

    return nfa.compile(allocator, lowered);
}

fn expectMatch(pattern: []const u8, haystack: []const u8) !void {
    const testing = std.testing;

    const program = try compileProgram(testing.allocator, pattern);
    defer program.deinit(testing.allocator);

    var engine = MatchEngine.init(testing.allocator);
    try testing.expect(try engine.isMatch(program, haystack));
}

fn expectNoMatch(pattern: []const u8, haystack: []const u8) !void {
    const testing = std.testing;

    const program = try compileProgram(testing.allocator, pattern);
    defer program.deinit(testing.allocator);

    var engine = MatchEngine.init(testing.allocator);
    try testing.expect(!(try engine.isMatch(program, haystack)));
}

test "VM matches literals, alternation, and repetition" {
    const testing = std.testing;

    const program = try compileProgram(testing.allocator, "ab|c+");
    defer program.deinit(testing.allocator);

    var engine = MatchEngine.init(testing.allocator);

    try testing.expect(try engine.isMatch(program, "zzabyy"));
    try testing.expect(try engine.isMatch(program, "xxccc"));
    try testing.expect(!(try engine.isMatch(program, "xyz")));
}

test "VM handles character classes, dot, and UTF-8 code points" {
    const testing = std.testing;

    const program = try compileProgram(testing.allocator, "[a-c].©");
    defer program.deinit(testing.allocator);

    var engine = MatchEngine.init(testing.allocator);

    try testing.expect(try engine.isMatch(program, "bZ©"));
    try testing.expect(try engine.isMatch(program, "xxc!©yy"));
    try testing.expect(!(try engine.isMatch(program, "d!©")));
}

test "VM respects start and end anchors" {
    const testing = std.testing;

    const program = try compileProgram(testing.allocator, "^ab+$");
    defer program.deinit(testing.allocator);

    var engine = MatchEngine.init(testing.allocator);

    try testing.expect(try engine.isMatch(program, "ab"));
    try testing.expect(try engine.isMatch(program, "abbb"));
    try testing.expect(!(try engine.isMatch(program, "zabbb")));
    try testing.expect(!(try engine.isMatch(program, "abbbz")));
}

test "VM matches empty expressions and optional paths" {
    const testing = std.testing;

    const empty_program = try compileProgram(testing.allocator, "");
    defer empty_program.deinit(testing.allocator);

    const optional_program = try compileProgram(testing.allocator, "colou?r");
    defer optional_program.deinit(testing.allocator);

    var engine = MatchEngine.init(testing.allocator);

    try testing.expect(try engine.isMatch(empty_program, ""));
    try testing.expect(try engine.isMatch(empty_program, "anything"));
    try testing.expect(try engine.isMatch(optional_program, "color"));
    try testing.expect(try engine.isMatch(optional_program, "colour"));
    try testing.expect(!(try engine.isMatch(optional_program, "colouur")));
}

test "VM handles counted repetition regressions" {
    try expectMatch("a{0,2}b", "b");
    try expectMatch("a{0,2}b", "ab");
    try expectMatch("a{0,2}b", "aab");
    try expectNoMatch("a{0,2}b", "aaab");

    try expectMatch("ba{2,}c", "baaac");
    try expectNoMatch("ba{2,}c", "bac");

    try expectMatch("x{3}", "zzzxxxy");
    try expectNoMatch("x{3}", "zzxxy");
}

test "VM handles negated classes and class edge literals" {
    try expectMatch("[^a-c]+", "zzz");
    try expectMatch("[^-\\]]+", "abc");
    try expectNoMatch("[^a-c]+", "cab");
    try expectMatch("[]-^]+", "]^-");
}

test "VM handles empty alternation branches and anchor-only patterns" {
    try expectMatch("a|", "");
    try expectMatch("a|", "zzz");
    try expectMatch("|b", "bbb");
    try expectMatch("^$", "");
    try expectNoMatch("^$", "x");
}

test "VM handles escaped metacharacters literally" {
    try expectMatch("\\^\\$\\[\\]\\(\\)\\|\\?\\+\\*\\{\\}\\\\", "xx^$[]()|?+*{}\\yy");
    try expectNoMatch("\\^\\$\\[\\]\\(\\)\\|\\?\\+\\*\\{\\}\\\\", "^$[]()|?+*{}");
}

test "VM ripgrep multiline dot_no_newline regression" {
    try expectNoMatch("of this world.+detective work", "of this world\nin the province of detective work");
    try expectMatch("of this world.+detective work", "of this world and detective work");
}

test "VM ripgrep regression 93 adapted to supported syntax" {
    try expectMatch("([0-9]{1,3}\\.){3}[0-9]{1,3}", "192.168.1.1");
    try expectMatch("([0-9]{1,3}\\.){3}[0-9]{1,3}", "prefix 10.0.0.42 suffix");
    try expectNoMatch("([0-9]{1,3}\\.){3}[0-9]{1,3}", "192.168.1");
}

test "VM returns whole-match and capture spans" {
    const testing = std.testing;

    const program = try compileProgram(testing.allocator, "(ab)(c+)");
    defer program.deinit(testing.allocator);

    var engine = MatchEngine.init(testing.allocator);
    const found = (try engine.firstMatch(program, "zzabccyy")).?;
    defer found.deinit(testing.allocator);

    try testing.expectEqual(Capture{ .start = 2, .end = 6 }, found.span);
    try testing.expectEqual(@as(usize, 2), found.groups.len);
    try testing.expectEqual(Capture{ .start = 2, .end = 4 }, found.groups[0]);
    try testing.expectEqual(Capture{ .start = 4, .end = 6 }, found.groups[1]);
}

test "VM returns null when no capture match exists" {
    const testing = std.testing;

    const program = try compileProgram(testing.allocator, "(ab)+");
    defer program.deinit(testing.allocator);

    var engine = MatchEngine.init(testing.allocator);
    try testing.expect((try engine.firstMatch(program, "zzz")) == null);
}

test "VM prefilter rejects haystacks without the required literal" {
    const testing = std.testing;

    const program = try compileProgram(testing.allocator, "needle.*hay");
    defer program.deinit(testing.allocator);

    try testing.expect(program.prefilter != null);
    try testing.expect(!program.prefilter.?.mayMatch("zzz"));

    var engine = MatchEngine.init(testing.allocator);
    try testing.expect((try engine.firstMatch(program, "zzz")) == null);
    try testing.expect(try engine.isMatch(program, "needle then hay"));
}

test "VM boolean search uses the non-capturing lazy DFA path" {
    const testing = std.testing;

    const program = try compileProgram(testing.allocator, "ab|c+");
    defer program.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), program.capture_count);

    var engine = MatchEngine.init(testing.allocator);
    try testing.expect(try engine.isMatch(program, "xxcccc"));
    try testing.expect(!(try engine.isMatch(program, "xyz")));
}

test "VM uses the ASCII-first capture path for ASCII-safe programs" {
    const testing = std.testing;

    const program = try compileProgram(testing.allocator, "(ab)(cd+)");
    defer program.deinit(testing.allocator);

    try testing.expect(program.ascii_only);

    var engine = MatchEngine.init(testing.allocator);
    const found = (try engine.firstMatch(program, "zzabcdddyy")).?;
    defer found.deinit(testing.allocator);

    try testing.expectEqual(Capture{ .start = 2, .end = 7 }, found.span);
    try testing.expectEqual(Capture{ .start = 2, .end = 4 }, found.groups[0]);
    try testing.expectEqual(Capture{ .start = 4, .end = 7 }, found.groups[1]);
}
