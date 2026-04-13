const std = @import("std");
const reader = @import("../reader.zig");
const nfa = @import("nfa.zig");
const unicode = @import("unicode.zig");

pub const Error = reader.ReaderError || error{
    OutOfMemory,
};

const ContextFlags = packed struct(u2) {
    at_start: bool,
    at_end: bool,
};

const State = struct {
    insts: []nfa.InstPtr,
    flags: ContextFlags,
    is_match: bool,
    transitions: std.AutoHashMap(u64, u32),

    fn deinit(self: *State, allocator: std.mem.Allocator) void {
        allocator.free(self.insts);
        self.transitions.deinit();
    }
};

pub const Cache = struct {
    allocator: std.mem.Allocator,
    program: *const nfa.Program,
    states: std.ArrayList(State),

    pub fn init(allocator: std.mem.Allocator, program: *const nfa.Program) Cache {
        return .{
            .allocator = allocator,
            .program = program,
            .states = .empty,
        };
    }

    pub fn deinit(self: *Cache) void {
        for (self.states.items) |*state| state.deinit(self.allocator);
        self.states.deinit(self.allocator);
    }

    pub fn isMatch(self: *Cache, haystack: []const u8) Error!bool {
        if (self.program.instructions.len == 0) return false;
        if (self.program.prefilter) |prefilter| {
            if (!prefilter.mayMatch(haystack)) return false;
        }
        if (self.program.ascii_only and isAsciiBytes(haystack)) {
            return self.isMatchAscii(haystack);
        }

        var current = try self.startState(0, haystack.len);
        if (self.states.items[current].is_match) return true;

        var input = reader.CodePointReader(u8).init(haystack);
        while (true) {
            const start = input.pos;
            const cp = (try input.next()) orelse break;
            const end = input.pos;
            _ = start;

            current = try self.nextState(current, cp, end, haystack.len);
            if (self.states.items[current].is_match) return true;
        }

        return false;
    }

    fn isMatchAscii(self: *Cache, haystack: []const u8) Error!bool {
        var current = try self.startState(0, haystack.len);
        if (self.states.items[current].is_match) return true;

        for (haystack, 0..) |byte, index| {
            current = try self.nextState(current, byte, index + 1, haystack.len);
            if (self.states.items[current].is_match) return true;
        }

        return false;
    }

    fn startState(self: *Cache, pos: usize, input_len: usize) Error!u32 {
        var builder: std.ArrayList(nfa.InstPtr) = .empty;
        defer builder.deinit(self.allocator);

        const visited = try self.allocator.alloc(bool, self.program.instructions.len);
        defer self.allocator.free(visited);
        @memset(visited, false);

        const flags = contextFlags(pos, input_len);
        var matched = false;
        if (try self.addEpsilonClosure(&builder, visited, self.program.start, pos, input_len, &matched)) {
            matched = true;
        }

        sortInsts(builder.items);
        return try self.internState(builder.items, flags, matched);
    }

    fn nextState(self: *Cache, state_id: u32, cp: u32, next_pos: usize, input_len: usize) Error!u32 {
        const flags = contextFlags(next_pos, input_len);
        const key = transitionKey(cp, flags);

        if (self.states.items[state_id].transitions.get(key)) |existing| return existing;

        var builder: std.ArrayList(nfa.InstPtr) = .empty;
        defer builder.deinit(self.allocator);

        const visited = try self.allocator.alloc(bool, self.program.instructions.len);
        defer self.allocator.free(visited);
        @memset(visited, false);

        var matched = false;
        for (self.states.items[state_id].insts) |inst_ptr| {
            switch (self.program.instructions[inst_ptr]) {
                .literal => |literal| {
                    if (literal.value == cp) {
                        if (try self.addEpsilonClosure(&builder, visited, literal.out.?, next_pos, input_len, &matched)) {
                            matched = true;
                        }
                    }
                },
                .char_class => |class| {
                    if (classMatches(class, cp, self.program.*)) {
                        if (try self.addEpsilonClosure(&builder, visited, class.out.?, next_pos, input_len, &matched)) {
                            matched = true;
                        }
                    }
                },
                .char_class_set => |class_set| {
                    if (classSetMatches(class_set, cp, self.program.*)) {
                        if (try self.addEpsilonClosure(&builder, visited, class_set.out.?, next_pos, input_len, &matched)) {
                            matched = true;
                        }
                    }
                },
                .unicode_property => |property| {
                    const matched_property = unicode.Strategy.hasProperty(cp, property.property);
                    if (property.negated != matched_property) {
                        if (try self.addEpsilonClosure(&builder, visited, property.out.?, next_pos, input_len, &matched)) {
                            matched = true;
                        }
                    }
                },
                .any => |any| {
                    if (any.matches_newline or cp != '\n') {
                        if (try self.addEpsilonClosure(&builder, visited, any.out.?, next_pos, input_len, &matched)) {
                            matched = true;
                        }
                    }
                },
                else => {},
            }
        }

        if (try self.addEpsilonClosure(&builder, visited, self.program.start, next_pos, input_len, &matched)) {
            matched = true;
        }

        sortInsts(builder.items);
        const next_id = try self.internState(builder.items, flags, matched);
        try self.states.items[state_id].transitions.put(key, next_id);
        return next_id;
    }

    fn addEpsilonClosure(
        self: *Cache,
        builder: *std.ArrayList(nfa.InstPtr),
        visited: []bool,
        inst_ptr: nfa.InstPtr,
        pos: usize,
        input_len: usize,
        matched: *bool,
    ) Error!bool {
        if (visited[inst_ptr]) return false;
        visited[inst_ptr] = true;

        switch (self.program.instructions[inst_ptr]) {
            .save => |save| return self.addEpsilonClosure(builder, visited, save.out.?, pos, input_len, matched),
            .split => |split| {
                if (split.out) |out| _ = try self.addEpsilonClosure(builder, visited, out, pos, input_len, matched);
                if (split.out1) |out1| _ = try self.addEpsilonClosure(builder, visited, out1, pos, input_len, matched);
                return false;
            },
            .anchor_start => |anchor| {
                if (pos != 0) return false;
                return self.addEpsilonClosure(builder, visited, anchor.out.?, pos, input_len, matched);
            },
            .anchor_end => |anchor| {
                if (pos != input_len) return false;
                return self.addEpsilonClosure(builder, visited, anchor.out.?, pos, input_len, matched);
            },
            .word_boundary, .not_word_boundary, .word_boundary_start_half, .word_boundary_end_half => unreachable,
            .match => {
                matched.* = true;
                return true;
            },
            .literal, .char_class, .char_class_set, .unicode_property, .any => {
                try builder.append(self.allocator, inst_ptr);
                return false;
            },
        }
    }

    fn internState(self: *Cache, insts: []const nfa.InstPtr, flags: ContextFlags, is_match: bool) Error!u32 {
        for (self.states.items, 0..) |state, index| {
            if (state.flags == flags and state.is_match == is_match and std.mem.eql(nfa.InstPtr, state.insts, insts)) {
                return @intCast(index);
            }
        }

        const duped = try self.allocator.dupe(nfa.InstPtr, insts);
        errdefer self.allocator.free(duped);

        try self.states.append(self.allocator, .{
            .insts = duped,
            .flags = flags,
            .is_match = is_match,
            .transitions = std.AutoHashMap(u64, u32).init(self.allocator),
        });
        return @intCast(self.states.items.len - 1);
    }
};

fn contextFlags(pos: usize, input_len: usize) ContextFlags {
    return .{
        .at_start = pos == 0,
        .at_end = pos == input_len,
    };
}

fn transitionKey(cp: u32, flags: ContextFlags) u64 {
    const flag_bits: u64 =
        (@as(u64, @intFromBool(flags.at_start)) << 1) |
        @as(u64, @intFromBool(flags.at_end));
    return (@as(u64, cp) << 2) | flag_bits;
}

fn sortInsts(insts: []nfa.InstPtr) void {
    std.sort.heap(nfa.InstPtr, insts, {}, comptime std.sort.asc(nfa.InstPtr));
}

fn classMatches(class: anytype, cp: u32, program: nfa.Program) bool {
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
            .folded_range => |range| {
                if (cp != '\n' or program.can_match_newline) {
                    if (unicode.Strategy.foldedRangeContains(cp, range.start, range.end, .simple)) {
                        matched = true;
                        break;
                    }
                }
            },
            .unicode_property => |property| {
                const property_matched = unicode.Strategy.hasProperty(cp, property.property);
                if (property.negated != property_matched) {
                    matched = true;
                    break;
                }
            },
        }
    }
    return if (class.negated) !matched else matched;
}

fn classSetMatches(class_set: anytype, cp: u32, program: nfa.Program) bool {
    return classExprMatches(class_set.expr, cp, program);
}

fn classExprMatches(expr: *const nfa.CompiledClassExpr, cp: u32, program: nfa.Program) bool {
    return switch (expr.*) {
        .class => |class| classMatches(class, cp, program),
        .set => |set| {
            const lhs_matched = classExprMatches(set.lhs, cp, program);
            const rhs_matched = classExprMatches(set.rhs, cp, program);
            return switch (set.op) {
                .intersection => lhs_matched and rhs_matched,
                .subtraction => lhs_matched and !rhs_matched,
            };
        },
    };
}

fn isAsciiBytes(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (!std.ascii.isAscii(byte)) return false;
    }
    return true;
}

fn compileProgram(allocator: std.mem.Allocator, pattern: []const u8) !nfa.Program {
    const regex = @import("root.zig");

    const lowered = try regex.compile(allocator, pattern, .{});
    defer lowered.deinit(allocator);

    return nfa.compile(allocator, lowered, .{});
}

test "Lazy DFA matches non-capturing literals and alternation" {
    const testing = std.testing;

    const program = try compileProgram(testing.allocator, "ab|cd");
    defer program.deinit(testing.allocator);

    var cache = Cache.init(testing.allocator, &program);
    defer cache.deinit();

    try testing.expect(try cache.isMatch("zzabyy"));
    try testing.expect(try cache.isMatch("xxcd"));
    try testing.expect(!(try cache.isMatch("xyz")));
}

test "Lazy DFA handles anchors and restart semantics" {
    const testing = std.testing;

    const anchored = try compileProgram(testing.allocator, "^ab+$");
    defer anchored.deinit(testing.allocator);

    var anchored_cache = Cache.init(testing.allocator, &anchored);
    defer anchored_cache.deinit();

    try testing.expect(try anchored_cache.isMatch("abbb"));
    try testing.expect(!(try anchored_cache.isMatch("zabbb")));

    const search = try compileProgram(testing.allocator, "needle");
    defer search.deinit(testing.allocator);

    var search_cache = Cache.init(testing.allocator, &search);
    defer search_cache.deinit();

    try testing.expect(try search_cache.isMatch("hay needle stack"));
}

test "Lazy DFA uses the ASCII-first path for ASCII-safe programs" {
    const testing = std.testing;

    const program = try compileProgram(testing.allocator, "abc.*xyz");
    defer program.deinit(testing.allocator);

    try testing.expect(program.ascii_only);

    var cache = Cache.init(testing.allocator, &program);
    defer cache.deinit();

    try testing.expect(try cache.isMatch("123abc---xyz456"));
    try testing.expect(!(try cache.isMatch("123abc---xy©")));
}
