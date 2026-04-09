const std = @import("std");
const reader = @import("../reader.zig");
const nfa = @import("nfa.zig");

pub const MatchError = reader.ReaderError || error{
    OutOfMemory,
};

pub const MatchEngine = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MatchEngine {
        return .{ .allocator = allocator };
    }

    pub fn isMatch(self: *const MatchEngine, program: nfa.Program, haystack: []const u8) MatchError!bool {
        if (program.instructions.len == 0) return false;

        var current: std.ArrayList(nfa.InstPtr) = .empty;
        defer current.deinit(self.allocator);

        var next: std.ArrayList(nfa.InstPtr) = .empty;
        defer next.deinit(self.allocator);

        var visited = try self.allocator.alloc(bool, program.instructions.len);
        defer self.allocator.free(visited);

        @memset(visited, false);
        if (try self.addThread(program, &current, &visited, program.start, 0, haystack.len)) return true;

        var input = reader.CodePointReader(u8).init(haystack);
        while (true) {
            const start = input.pos;
            const cp = (try input.next()) orelse break;
            const end = input.pos;

            next.clearRetainingCapacity();
            @memset(visited, false);

            for (current.items) |inst_ptr| {
                if (try self.step(program, &next, &visited, inst_ptr, cp, end, haystack.len)) return true;
            }

            std.mem.swap(std.ArrayList(nfa.InstPtr), &current, &next);

            @memset(visited, false);
            if (start != end) {
                if (try self.addThread(program, &current, &visited, program.start, end, haystack.len)) return true;
            }
        }

        return false;
    }

    fn step(
        self: *const MatchEngine,
        program: nfa.Program,
        list: *std.ArrayList(nfa.InstPtr),
        visited: []bool,
        inst_ptr: nfa.InstPtr,
        cp: u32,
        next_pos: usize,
        input_len: usize,
    ) MatchError!bool {
        switch (program.instructions[inst_ptr]) {
            .literal => |literal| {
                if (literal.value != cp) return false;
                return self.addThread(program, list, visited, literal.out.?, next_pos, input_len);
            },
            .char_class => |class| {
                if (!classMatches(class, cp)) return false;
                return self.addThread(program, list, visited, class.out.?, next_pos, input_len);
            },
            .any => |any| {
                if (cp == '\n') return false;
                return self.addThread(program, list, visited, any.out.?, next_pos, input_len);
            },
            else => return false,
        }
    }

    fn addThread(
        self: *const MatchEngine,
        program: nfa.Program,
        list: *std.ArrayList(nfa.InstPtr),
        visited: []bool,
        inst_ptr: nfa.InstPtr,
        pos: usize,
        input_len: usize,
    ) MatchError!bool {
        if (visited[inst_ptr]) return false;
        visited[inst_ptr] = true;

        switch (program.instructions[inst_ptr]) {
            .split => |split| {
                if (split.out) |out| {
                    if (try self.addThread(program, list, visited, out, pos, input_len)) return true;
                }
                if (split.out1) |out1| {
                    if (try self.addThread(program, list, visited, out1, pos, input_len)) return true;
                }
                return false;
            },
            .anchor_start => |anchor| {
                if (pos != 0) return false;
                return self.addThread(program, list, visited, anchor.out.?, pos, input_len);
            },
            .anchor_end => |anchor| {
                if (pos != input_len) return false;
                return self.addThread(program, list, visited, anchor.out.?, pos, input_len);
            },
            .match => return true,
            .literal, .char_class, .any => {
                try list.append(self.allocator, inst_ptr);
                return false;
            },
        }
    }
};

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
    // Ported from ripgrep tests/multiline.rs: dot_no_newline.
    try expectNoMatch("of this world.+detective work", "of this world\nin the province of detective work");
    try expectMatch("of this world.+detective work", "of this world and detective work");
}

test "VM ripgrep regression 93 adapted to supported syntax" {
    // Ported from ripgrep tests/regression.rs issue 93, replacing \d with [0-9].
    try expectMatch("([0-9]{1,3}\\.){3}[0-9]{1,3}", "192.168.1.1");
    try expectMatch("([0-9]{1,3}\\.){3}[0-9]{1,3}", "prefix 10.0.0.42 suffix");
    try expectNoMatch("([0-9]{1,3}\\.){3}[0-9]{1,3}", "192.168.1");
}
