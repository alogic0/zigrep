const std = @import("std");
const regex = @import("../regex/root.zig");
const report_mod = @import("report.zig");
const io = @import("io.zig");

pub const SearchError = regex.ParseError || regex.Nfa.CompileError || regex.Vm.MatchError || error{
    UnsupportedCaseInsensitive,
};

pub const SearchOptions = struct {
    case_insensitive: bool = false,
};

pub const Span = report_mod.Span;

pub const MatchReport = struct {
    path: []const u8,
    line_number: usize,
    // Columns stay byte-oriented to match the rest of the current search layer.
    column_number: usize,
    line: []const u8,
    // This stays null in the normal path. It is only used when a caller needs
    // the line bytes to outlive a temporary transformed haystack.
    owned_line: ?[]u8 = null,
    line_span: Span,
    match_span: Span,

    pub fn deinit(self: MatchReport, allocator: std.mem.Allocator) void {
        if (self.owned_line) |line| allocator.free(line);
    }
};

const ByteAtom = union(enum) {
    literal: []u8,
    any_byte,
    class: regex.hir.CharacterClass,
    alternation: []BytePattern,
    save_start: u32,
    save_end: u32,

    fn deinit(self: ByteAtom, allocator: std.mem.Allocator) void {
        switch (self) {
            .literal => |bytes| allocator.free(bytes),
            .class => |class| allocator.free(class.items),
            .alternation => |patterns| {
                for (patterns) |pattern| pattern.deinit(allocator);
                allocator.free(patterns);
            },
            .any_byte, .save_start, .save_end => {},
        }
    }
};

const ByteTerm = struct {
    atom: ByteAtom,
    min: u32 = 1,
    max: ?u32 = 1,

    fn deinit(self: ByteTerm, allocator: std.mem.Allocator) void {
        self.atom.deinit(allocator);
    }
};

const BytePattern = struct {
    mode: AnchoredLiteralMode,
    terms: []ByteTerm,

    fn deinit(self: BytePattern, allocator: std.mem.Allocator) void {
        for (self.terms) |term| term.deinit(allocator);
        allocator.free(self.terms);
    }
};

pub const ByteSearchPlan = union(enum) {
    none,
    single: BytePattern,
    alternation: []BytePattern,

    pub fn deinit(self: ByteSearchPlan, allocator: std.mem.Allocator) void {
        switch (self) {
            .none => {},
            .single => |pattern| pattern.deinit(allocator),
            .alternation => |patterns| {
                for (patterns) |pattern| pattern.deinit(allocator);
                allocator.free(patterns);
            },
        }
    }
};

pub const Searcher = struct {
    allocator: std.mem.Allocator,
    engine: regex.Vm.MatchEngine,
    program: regex.Nfa.Program,
    byte_plan: ByteSearchPlan,

    pub fn init(
        allocator: std.mem.Allocator,
        pattern: []const u8,
        options: SearchOptions,
    ) SearchError!Searcher {
        if (options.case_insensitive) return error.UnsupportedCaseInsensitive;

        var hir = try regex.compile(allocator, pattern, .{});
        defer hir.deinit(allocator);

        return .{
            .allocator = allocator,
            .engine = regex.Vm.MatchEngine.init(allocator),
            .program = try regex.Nfa.compile(allocator, hir),
            .byte_plan = try extractByteSearchPlan(allocator, hir),
        };
    }

    pub fn deinit(self: *Searcher) void {
        self.byte_plan.deinit(self.allocator);
        self.program.deinit(self.allocator);
    }

    pub fn reportFirstMatch(self: *Searcher, path: []const u8, haystack: []const u8) SearchError!?MatchReport {
        const found = try self.engine.firstMatch(self.program, haystack);
        if (found) |match| {
            defer match.deinit(self.allocator);
            return buildReport(path, haystack, match.span);
        }
        return null;
    }

    pub fn firstByteMatch(self: *Searcher, haystack: []const u8) regex.Vm.MatchError!?regex.Vm.Match {
        const span = switch (self.byte_plan) {
            .none => null,
            .single => |pattern| findBytePatternSpan(pattern, haystack),
            .alternation => |patterns| findByteAlternationSpan(patterns, haystack),
        } orelse return null;

        const slots = try self.allocator.alloc(?usize, (self.program.capture_count + 1) * 2);
        defer self.allocator.free(slots);
        @memset(slots, null);

        const end = switch (self.byte_plan) {
            .none => unreachable,
            .single => |pattern| try matchBytePatternAtWithSlots(self.allocator, pattern, haystack, span.start, slots),
            .alternation => |patterns| try matchByteAlternationAtWithSlots(self.allocator, patterns, haystack, span.start, slots),
        } orelse return null;
        if (end != span.end) return null;

        slots[0] = span.start;
        slots[1] = span.end;

        const groups = try self.allocator.alloc(regex.Vm.Capture, self.program.capture_count);
        errdefer self.allocator.free(groups);
        for (groups, 0..) |*group, index| {
            group.* = .{
                .start = slots[2 * (index + 1)],
                .end = slots[2 * (index + 1) + 1],
            };
        }

        return .{
            .span = .{ .start = span.start, .end = span.end },
            .groups = groups,
        };
    }

    pub fn reportFirstByteMatch(self: *Searcher, path: []const u8, haystack: []const u8) SearchError!?MatchReport {
        const found = try self.firstByteMatch(haystack) orelse return null;
        defer found.deinit(self.allocator);

        return buildReport(path, haystack, .{
            .start = found.span.start,
            .end = found.span.end,
        });
    }

    pub fn hasBytePlan(self: *const Searcher) bool {
        return switch (self.byte_plan) {
            .none => false,
            .single, .alternation => true,
        };
    }
};

pub fn reportFirstMatch(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    path: []const u8,
    haystack: []const u8,
    options: SearchOptions,
) SearchError!?MatchReport {
    var searcher = try Searcher.init(allocator, pattern, options);
    defer searcher.deinit();
    return searcher.reportFirstMatch(path, haystack);
}

fn buildReport(path: []const u8, haystack: []const u8, span: regex.Vm.Capture) MatchReport {
    std.debug.assert(span.start != null);
    std.debug.assert(span.end != null);

    const match_start = span.start.?;
    const match_end = span.end.?;
    const line_info = report_mod.deriveLineInfo(haystack, match_start);

    return .{
        .path = path,
        .line_number = line_info.line_number,
        .column_number = line_info.column_number,
        .line = haystack[line_info.line_span.start..line_info.line_span.end],
        .line_span = line_info.line_span,
        .match_span = .{
            .start = match_start,
            .end = match_end,
        },
    };
}

const AnchoredLiteralMode = enum {
    contains,
    start,
    end,
    full,
};

const BytePlanError = std.mem.Allocator.Error;
const max_expanded_byte_class_range: u32 = 256;

fn extractByteSearchPlan(allocator: std.mem.Allocator, hir: regex.Hir) BytePlanError!ByteSearchPlan {
    return switch (hir.nodes[@intFromEnum(hir.root)]) {
        .alternation => |branches| blk: {
            var patterns: std.ArrayList(BytePattern) = .empty;
            defer patterns.deinit(allocator);
            errdefer for (patterns.items) |pattern| pattern.deinit(allocator);

            for (branches) |branch| {
                const pattern = (try extractBytePattern(allocator, hir.nodes, branch)) orelse break :blk .none;
                try patterns.append(allocator, pattern);
            }

            if (patterns.items.len == 0) break :blk .none;
            if (patterns.items.len == 1) break :blk .{ .single = patterns.pop().? };
            break :blk .{ .alternation = try patterns.toOwnedSlice(allocator) };
        },
        else => if (try extractBytePattern(allocator, hir.nodes, hir.root)) |pattern|
            .{ .single = pattern }
        else
            .none,
    };
}

fn extractBytePattern(
    allocator: std.mem.Allocator,
    nodes: []const regex.hir.Node,
    root: regex.hir.NodeId,
) BytePlanError!?BytePattern {
    return switch (nodes[@intFromEnum(root)]) {
        .empty => .{
            .mode = .contains,
            .terms = try allocator.alloc(ByteTerm, 0),
        },
        .group => |group| blk: {
            var pattern = (try extractBytePattern(allocator, nodes, group.child)) orelse break :blk null;
            pattern = try wrapPatternWithCapture(allocator, pattern, group.index);
            break :blk pattern;
        },
        .literal, .dot, .char_class, .repetition => blk: {
            var keep_terms = false;
            var terms: std.ArrayList(ByteTerm) = .empty;
            defer terms.deinit(allocator);
            defer {
                if (!keep_terms) {
                    for (terms.items) |term| term.deinit(allocator);
                }
            }
            var literal_bytes: std.ArrayList(u8) = .empty;
            defer literal_bytes.deinit(allocator);

            if (!(try appendNodeToByteTerms(allocator, nodes, root, &terms, &literal_bytes))) break :blk null;
            try flushLiteralTerm(allocator, &terms, &literal_bytes);
            if (terms.items.len == 0) break :blk null;

            keep_terms = true;

            break :blk .{
                .mode = .contains,
                .terms = try terms.toOwnedSlice(allocator),
            };
        },
        .concat => |children| blk: {
            var prefix_anchor = false;
            var suffix_anchor = false;
            var start_index: usize = 0;
            var end_index: usize = children.len;

            if (children.len > 0 and std.meta.activeTag(nodes[@intFromEnum(children[0])]) == .anchor_start) {
                prefix_anchor = true;
                start_index = 1;
            }
            if (end_index > start_index and std.meta.activeTag(nodes[@intFromEnum(children[end_index - 1])]) == .anchor_end) {
                suffix_anchor = true;
                end_index -= 1;
            }
            if (start_index == end_index) {
                break :blk .{
                    .mode = if (prefix_anchor and suffix_anchor)
                        .full
                    else if (prefix_anchor)
                        .start
                    else if (suffix_anchor)
                        .end
                    else
                        .contains,
                    .terms = try allocator.alloc(ByteTerm, 0),
                };
            }

            var keep_terms = false;
            var terms: std.ArrayList(ByteTerm) = .empty;
            defer terms.deinit(allocator);
            defer {
                if (!keep_terms) {
                    for (terms.items) |term| term.deinit(allocator);
                }
            }

            var literal_bytes: std.ArrayList(u8) = .empty;
            defer literal_bytes.deinit(allocator);

            for (children[start_index..end_index]) |child| {
                if (!(try appendNodeToByteTerms(allocator, nodes, child, &terms, &literal_bytes))) break :blk null;
            }
            try flushLiteralTerm(allocator, &terms, &literal_bytes);
            if (terms.items.len == 0) break :blk null;

            keep_terms = true;

            break :blk .{
                .mode = if (prefix_anchor and suffix_anchor)
                    .full
                else if (prefix_anchor)
                    .start
                else if (suffix_anchor)
                    .end
                else
                    .contains,
                .terms = try terms.toOwnedSlice(allocator),
            };
        },
        else => null,
    };
}

fn appendNodeToByteTerms(
    allocator: std.mem.Allocator,
    nodes: []const regex.hir.Node,
    node_id: regex.hir.NodeId,
    terms: *std.ArrayList(ByteTerm),
    literal_bytes: *std.ArrayList(u8),
) BytePlanError!bool {
    switch (nodes[@intFromEnum(node_id)]) {
        .group => |group| {
            try flushLiteralTerm(allocator, terms, literal_bytes);
            try terms.append(allocator, .{ .atom = .{ .save_start = group.index } });
            if (!(try appendNodeToByteTerms(allocator, nodes, group.child, terms, literal_bytes))) return false;
            try flushLiteralTerm(allocator, terms, literal_bytes);
            try terms.append(allocator, .{ .atom = .{ .save_end = group.index } });
            return true;
        },
        .literal => |cp| {
            try appendCodePointUtf8(allocator, literal_bytes, cp);
            return true;
        },
        .dot => {
            try flushLiteralTerm(allocator, terms, literal_bytes);
            try terms.append(allocator, .{ .atom = .any_byte });
            return true;
        },
        .char_class => |class| {
            try flushLiteralTerm(allocator, terms, literal_bytes);
            if (isAsciiClass(class)) {
                const duped_items = try allocator.alloc(regex.hir.ClassItem, class.items.len);
                @memcpy(duped_items, class.items);
                try terms.append(allocator, .{
                    .atom = .{
                        .class = .{
                            .negated = class.negated,
                            .items = duped_items,
                        },
                    },
                });
                return true;
            }
            if (try classToByteTerm(allocator, class)) |term| {
                try terms.append(allocator, term);
                return true;
            }
            return false;
        },
        .repetition => |rep| {
            if (try extractRepeatableByteTerm(allocator, nodes, rep.child, rep.quantifier)) |term| {
                try flushLiteralTerm(allocator, terms, literal_bytes);
                try terms.append(allocator, term);
                return true;
            }

            const max = rep.quantifier.max orelse return false;
            if (max != rep.quantifier.min) return false;

            var count: u32 = 0;
            while (count < rep.quantifier.min) : (count += 1) {
                if (!(try appendNodeToByteTerms(allocator, nodes, rep.child, terms, literal_bytes))) return false;
            }
            return true;
        },
        else => return false,
    }
}

fn extractRepeatableByteTerm(
    allocator: std.mem.Allocator,
    nodes: []const regex.hir.Node,
    node_id: regex.hir.NodeId,
    quantifier: regex.hir.Quantifier,
) BytePlanError!?ByteTerm {
    switch (nodes[@intFromEnum(node_id)]) {
        .alternation => {
            const term = try extractAlternationByteTerm(allocator, nodes, node_id) orelse return null;
            var updated = term;
            updated.min = quantifier.min;
            updated.max = quantifier.max;
            return updated;
        },
        .group => |group| {
            var pattern = (try extractBytePattern(allocator, nodes, group.child)) orelse return null;
            errdefer pattern.deinit(allocator);
            if (pattern.mode != .contains) return null;
            pattern = try wrapPatternWithCapture(allocator, pattern, group.index);

            const patterns = try allocator.alloc(BytePattern, 1);
            patterns[0] = pattern;
            return .{
                .atom = .{ .alternation = patterns },
                .min = quantifier.min,
                .max = quantifier.max,
            };
        },
        else => {},
    }

    const atom = switch (nodes[@intFromEnum(node_id)]) {
        .literal => |cp| ByteAtom{ .literal = try dupeCodePointUtf8(allocator, cp) },
        .concat => |children| blk: {
            var pattern = try extractBytePattern(allocator, nodes, node_id) orelse return null;
            defer pattern.deinit(allocator);
            if (pattern.mode != .contains) return null;
            if (pattern.terms.len != 1) return null;
            if (pattern.terms[0].min != 1 or pattern.terms[0].max == null or pattern.terms[0].max.? != 1) return null;

            const term = pattern.terms[0];
            const dup_atom = switch (term.atom) {
                .literal => |bytes| ByteAtom{ .literal = try allocator.dupe(u8, bytes) },
                .any_byte => ByteAtom.any_byte,
                .class => |class| blk2: {
                    const duped_items = try allocator.alloc(regex.hir.ClassItem, class.items.len);
                    @memcpy(duped_items, class.items);
                    break :blk2 ByteAtom{
                        .class = .{
                            .negated = class.negated,
                            .items = duped_items,
                        },
                    };
                },
                .alternation, .save_start, .save_end => return null,
            };
            _ = children;
            break :blk dup_atom;
        },
        .dot => ByteAtom.any_byte,
        .char_class => |class| blk: {
            if (isAsciiClass(class)) {
                const duped_items = try allocator.alloc(regex.hir.ClassItem, class.items.len);
                @memcpy(duped_items, class.items);
                break :blk ByteAtom{
                    .class = .{
                        .negated = class.negated,
                        .items = duped_items,
                    },
                };
            }
            if (try classToByteTerm(allocator, class)) |term| {
                if (term.min != 1 or term.max == null or term.max.? != 1) return null;
                break :blk term.atom;
            }
            return null;
        },
        else => return null,
    };

    return .{
        .atom = atom,
        .min = quantifier.min,
        .max = quantifier.max,
    };
}

fn extractAlternationByteTerm(
    allocator: std.mem.Allocator,
    nodes: []const regex.hir.Node,
    node_id: regex.hir.NodeId,
) BytePlanError!?ByteTerm {
    const branches = switch (nodes[@intFromEnum(node_id)]) {
        .alternation => |branches| branches,
        else => return null,
    };

    var patterns: std.ArrayList(BytePattern) = .empty;
    defer patterns.deinit(allocator);
    errdefer for (patterns.items) |pattern| pattern.deinit(allocator);

    for (branches) |branch| {
        var pattern = try extractBytePattern(allocator, nodes, branch) orelse return null;
        if (pattern.mode != .contains) {
            pattern.deinit(allocator);
            return null;
        }
        try patterns.append(allocator, pattern);
    }

    if (patterns.items.len == 0) return null;

    return .{
        .atom = .{ .alternation = try patterns.toOwnedSlice(allocator) },
        .min = 1,
        .max = 1,
    };
}

fn classToByteTerm(
    allocator: std.mem.Allocator,
    class: regex.hir.CharacterClass,
) BytePlanError!?ByteTerm {
    if (class.negated) return null;
    if (class.items.len == 0) return null;

    var patterns: std.ArrayList(BytePattern) = .empty;
    defer patterns.deinit(allocator);
    errdefer for (patterns.items) |pattern| pattern.deinit(allocator);

    for (class.items) |item| {
        switch (item) {
            .literal => |cp| try patterns.append(allocator, try bytePatternForLiteralCodePoint(allocator, cp)),
            .range => |range| {
                const span = range.end - range.start + 1;
                if (span > max_expanded_byte_class_range) return null;

                var cp = range.start;
                while (cp <= range.end) : (cp += 1) {
                    try patterns.append(allocator, try bytePatternForLiteralCodePoint(allocator, cp));
                }
            },
        }
    }

    return .{
        .atom = .{ .alternation = try patterns.toOwnedSlice(allocator) },
        .min = 1,
        .max = 1,
    };
}

fn bytePatternForLiteralCodePoint(
    allocator: std.mem.Allocator,
    cp: u32,
) BytePlanError!BytePattern {
    const terms = try allocator.alloc(ByteTerm, 1);
    terms[0] = .{
        .atom = .{
            .literal = try dupeCodePointUtf8(allocator, cp),
        },
    };
    return .{
        .mode = .contains,
        .terms = terms,
    };
}

fn wrapPatternWithCapture(
    allocator: std.mem.Allocator,
    pattern: BytePattern,
    group_index: u32,
) BytePlanError!BytePattern {
    const wrapped = try allocator.alloc(ByteTerm, pattern.terms.len + 2);
    wrapped[0] = .{ .atom = .{ .save_start = group_index } };
    @memcpy(wrapped[1 .. wrapped.len - 1], pattern.terms);
    wrapped[wrapped.len - 1] = .{ .atom = .{ .save_end = group_index } };
    allocator.free(pattern.terms);

    return .{
        .mode = pattern.mode,
        .terms = wrapped,
    };
}

fn flushLiteralTerm(
    allocator: std.mem.Allocator,
    terms: *std.ArrayList(ByteTerm),
    literal_bytes: *std.ArrayList(u8),
) BytePlanError!void {
    if (literal_bytes.items.len == 0) return;
    try terms.append(allocator, .{ .atom = .{ .literal = try literal_bytes.toOwnedSlice(allocator) } });
}

fn appendCodePointUtf8(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    cp: u32,
) BytePlanError!void {
    var buf: [4]u8 = undefined;
    const scalar: u21 = @intCast(cp);
    const len = std.unicode.utf8Encode(scalar, &buf) catch unreachable;
    try out.appendSlice(allocator, buf[0..len]);
}

fn dupeCodePointUtf8(allocator: std.mem.Allocator, cp: u32) BytePlanError![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    try appendCodePointUtf8(allocator, &bytes, cp);
    return bytes.toOwnedSlice(allocator);
}

fn findByteAlternationSpan(patterns: []const BytePattern, haystack: []const u8) ?Span {
    var best: ?Span = null;
    for (patterns) |pattern| {
        const span = findBytePatternSpan(pattern, haystack) orelse continue;
        if (best == null or span.start < best.?.start) {
            best = span;
        }
    }
    return best;
}

fn findBytePatternSpan(pattern: BytePattern, haystack: []const u8) ?Span {
    return switch (pattern.mode) {
        .contains => findBytePatternContainsSpan(pattern, haystack),
        .start => matchBytePatternAt(pattern, haystack, 0),
        .end => findBytePatternAnchoredEndSpan(pattern, haystack),
        .full => findBytePatternAnchoredFullSpan(pattern, haystack),
    };
}

fn findBytePatternContainsSpan(pattern: BytePattern, haystack: []const u8) ?Span {
    var start: usize = 0;
    while (start <= haystack.len) : (start += 1) {
        if (matchBytePatternAt(pattern, haystack, start)) |span| return span;
    }
    return null;
}

fn findBytePatternAnchoredEndSpan(pattern: BytePattern, haystack: []const u8) ?Span {
    const min_len = minBytePatternLen(pattern);
    if (haystack.len < min_len) return null;
    var start = haystack.len - min_len;
    while (true) {
        if (matchBytePatternAt(pattern, haystack, start)) |span| {
            if (span.end == haystack.len) return span;
        }
        if (start == 0) break;
        start -= 1;
    }
    return null;
}

fn findBytePatternAnchoredFullSpan(pattern: BytePattern, haystack: []const u8) ?Span {
    const span = matchBytePatternAt(pattern, haystack, 0) orelse return null;
    return if (span.end == haystack.len) span else null;
}

fn matchBytePatternAt(pattern: BytePattern, haystack: []const u8, start: usize) ?Span {
    const end = matchByteTermsAt(pattern.terms, haystack, 0, start) orelse return null;
    return .{ .start = start, .end = end };
}

fn matchBytePatternAtWithSlots(
    allocator: std.mem.Allocator,
    pattern: BytePattern,
    haystack: []const u8,
    start: usize,
    slots: []?usize,
) regex.Vm.MatchError!?usize {
    return matchByteTermsAtWithSlots(allocator, pattern.terms, haystack, 0, start, slots);
}

fn minBytePatternLen(pattern: BytePattern) usize {
    var total: usize = 0;
    for (pattern.terms) |term| {
        total += term.min * byteAtomMinLen(term.atom);
    }
    return total;
}

fn matchByteTermsAt(terms: []const ByteTerm, haystack: []const u8, term_index: usize, pos: usize) ?usize {
    if (term_index >= terms.len) return pos;

    const term = terms[term_index];
    switch (term.atom) {
        .alternation => |patterns| return matchAlternationTerm(patterns, term.min, term.max, terms, term_index, haystack, pos),
        else => {},
    }

    const step = byteAtomLen(term.atom);

    var min_pos = pos;
    var matched_min: u32 = 0;
    while (matched_min < term.min) : (matched_min += 1) {
        min_pos = matchByteAtomAt(term.atom, haystack, min_pos) orelse return null;
    }

    var max_pos = min_pos;
    var max_count = matched_min;
    while (term.max == null or max_count < term.max.?) {
        max_pos = matchByteAtomAt(term.atom, haystack, max_pos) orelse break;
        max_count += 1;
    }

    var count = max_count;
    var trial_pos = max_pos;
    while (true) {
        if (matchByteTermsAt(terms, haystack, term_index + 1, trial_pos)) |end| return end;
        if (count == matched_min) break;
        count -= 1;
        trial_pos -= step;
    }

    return null;
}

fn matchByteTermsAtWithSlots(
    allocator: std.mem.Allocator,
    terms: []const ByteTerm,
    haystack: []const u8,
    term_index: usize,
    pos: usize,
    slots: []?usize,
) regex.Vm.MatchError!?usize {
    if (term_index >= terms.len) return pos;
    return matchByteTermRepsWithSlots(allocator, terms, haystack, term_index, pos, slots, 0);
}

fn matchContainedBytePatternAt(pattern: BytePattern, haystack: []const u8, pos: usize) ?usize {
    if (pattern.mode != .contains) return null;
    return matchByteTermsAt(pattern.terms, haystack, 0, pos);
}

fn matchContainedBytePatternAtWithSlots(
    allocator: std.mem.Allocator,
    pattern: BytePattern,
    haystack: []const u8,
    pos: usize,
    slots: []?usize,
) regex.Vm.MatchError!?usize {
    if (pattern.mode != .contains) return null;
    return matchByteTermsAtWithSlots(allocator, pattern.terms, haystack, 0, pos, slots);
}

fn matchAlternationTerm(
    patterns: []const BytePattern,
    min: u32,
    max: ?u32,
    terms: []const ByteTerm,
    term_index: usize,
    haystack: []const u8,
    pos: usize,
) ?usize {
    return matchAlternationTermReps(patterns, min, max, terms, term_index, haystack, pos, 0);
}

fn matchAlternationTermReps(
    patterns: []const BytePattern,
    min: u32,
    max: ?u32,
    terms: []const ByteTerm,
    term_index: usize,
    haystack: []const u8,
    pos: usize,
    count: u32,
) ?usize {
    if (count >= min) {
        if (matchByteTermsAt(terms, haystack, term_index + 1, pos)) |end| return end;
    }
    if (max != null and count >= max.?) return null;

    for (patterns) |pattern| {
        const next_pos = matchContainedBytePatternAt(pattern, haystack, pos) orelse continue;
        if (next_pos == pos) {
            const next_count = count + 1;
            if (next_count >= min) {
                if (matchByteTermsAt(terms, haystack, term_index + 1, pos)) |end| return end;
            }
            if (max != null and next_count < max.?) {
                if (matchAlternationTermReps(patterns, min, max, terms, term_index, haystack, pos, next_count)) |end| return end;
            }
            continue;
        }
        if (matchAlternationTermReps(patterns, min, max, terms, term_index, haystack, next_pos, count + 1)) |end| return end;
    }
    return null;
}

fn matchByteAlternationAtWithSlots(
    allocator: std.mem.Allocator,
    patterns: []const BytePattern,
    haystack: []const u8,
    start: usize,
    slots: []?usize,
) regex.Vm.MatchError!?usize {
    for (patterns) |pattern| {
        const snapshot = try cloneSlots(allocator, slots);
        defer allocator.free(snapshot);

        if (try matchBytePatternAtWithSlots(allocator, pattern, haystack, start, slots)) |end| return end;
        restoreSlots(slots, snapshot);
    }
    return null;
}

fn matchByteTermRepsWithSlots(
    allocator: std.mem.Allocator,
    terms: []const ByteTerm,
    haystack: []const u8,
    term_index: usize,
    pos: usize,
    slots: []?usize,
    count: u32,
) regex.Vm.MatchError!?usize {
    const term = terms[term_index];

    if (count >= term.min) {
        const rest_snapshot = try cloneSlots(allocator, slots);
        defer allocator.free(rest_snapshot);

        if (try matchByteTermsAtWithSlots(allocator, terms, haystack, term_index + 1, pos, slots)) |end| return end;
        restoreSlots(slots, rest_snapshot);
    }

    if (term.max != null and count >= term.max.?) return null;

    const atom_snapshot = try cloneSlots(allocator, slots);
    defer allocator.free(atom_snapshot);

    const next_pos = try matchByteAtomAtWithSlots(allocator, term.atom, haystack, pos, slots) orelse {
        restoreSlots(slots, atom_snapshot);
        return null;
    };

    const next_count = count + 1;
    if (next_pos == pos) {
        if (next_count >= term.min) {
            const rest_snapshot = try cloneSlots(allocator, slots);
            defer allocator.free(rest_snapshot);

            if (try matchByteTermsAtWithSlots(allocator, terms, haystack, term_index + 1, pos, slots)) |end| return end;
            restoreSlots(slots, rest_snapshot);
        }
        if (term.max != null and next_count < term.max.?) {
            if (try matchByteTermRepsWithSlots(allocator, terms, haystack, term_index, pos, slots, next_count)) |end| return end;
        }
        restoreSlots(slots, atom_snapshot);
        return null;
    }

    if (try matchByteTermRepsWithSlots(allocator, terms, haystack, term_index, next_pos, slots, next_count)) |end| return end;

    restoreSlots(slots, atom_snapshot);
    return null;
}

fn matchByteAtomAt(atom: ByteAtom, haystack: []const u8, pos: usize) ?usize {
    return switch (atom) {
        .literal => |bytes| if (pos + bytes.len <= haystack.len and std.mem.eql(u8, haystack[pos .. pos + bytes.len], bytes))
            pos + bytes.len
        else
            null,
        .any_byte => if (pos < haystack.len and haystack[pos] != '\n')
            pos + 1
        else
            null,
        .class => |class| if (pos < haystack.len and byteMatchesClass(class, haystack[pos]))
            pos + 1
        else
            null,
        .alternation => unreachable,
        .save_start, .save_end => pos,
    };
}

fn matchByteAtomAtWithSlots(
    allocator: std.mem.Allocator,
    atom: ByteAtom,
    haystack: []const u8,
    pos: usize,
    slots: []?usize,
) regex.Vm.MatchError!?usize {
    return switch (atom) {
        .literal, .any_byte, .class => matchByteAtomAt(atom, haystack, pos),
        .alternation => |patterns| blk: {
            for (patterns) |pattern| {
                const snapshot = try cloneSlots(allocator, slots);
                defer allocator.free(snapshot);

                if (try matchContainedBytePatternAtWithSlots(allocator, pattern, haystack, pos, slots)) |end| break :blk end;
                restoreSlots(slots, snapshot);
            }
            break :blk null;
        },
        .save_start => |group_index| blk: {
            slots[2 * group_index] = pos;
            break :blk pos;
        },
        .save_end => |group_index| blk: {
            slots[2 * group_index + 1] = pos;
            break :blk pos;
        },
    };
}

fn byteAtomLen(atom: ByteAtom) usize {
    return switch (atom) {
        .literal => |bytes| bytes.len,
        .any_byte, .class => 1,
        .alternation => unreachable,
        .save_start, .save_end => 0,
    };
}

fn byteAtomMinLen(atom: ByteAtom) usize {
    return switch (atom) {
        .literal => |bytes| bytes.len,
        .any_byte, .class => 1,
        .alternation => |patterns| blk: {
            var min_len: ?usize = null;
            for (patterns) |pattern| {
                const len = minBytePatternLen(pattern);
                min_len = if (min_len == null or len < min_len.?) len else min_len;
            }
            break :blk min_len orelse 0;
        },
        .save_start, .save_end => 0,
    };
}

fn cloneSlots(allocator: std.mem.Allocator, slots: []const ?usize) std.mem.Allocator.Error![]?usize {
    const snapshot = try allocator.alloc(?usize, slots.len);
    @memcpy(snapshot, slots);
    return snapshot;
}

fn restoreSlots(slots: []?usize, snapshot: []const ?usize) void {
    @memcpy(slots, snapshot);
}

fn isAsciiClass(class: regex.hir.CharacterClass) bool {
    for (class.items) |item| {
        switch (item) {
            .literal => |literal| if (literal > 0x7f) return false,
            .range => |range| if (range.start > 0x7f or range.end > 0x7f) return false,
        }
    }
    return true;
}

fn byteMatchesClass(class: regex.hir.CharacterClass, byte: u8) bool {
    const cp: u32 = byte;
    var matched = false;
    for (class.items) |item| {
        switch (item) {
            .literal => |literal| if (literal == cp) {
                matched = true;
                break;
            },
            .range => |range| if (range.start <= cp and cp <= range.end) {
                matched = true;
                break;
            },
        }
    }
    return if (class.negated) !matched else matched;
}

test "reportFirstMatch returns line-oriented match data" {
    const testing = std.testing;

    const haystack = "first line\nzzzabcqq\nthird line\n";
    const report = (try reportFirstMatch(testing.allocator, "abc", "sample.txt", haystack, .{})).?;

    defer report.deinit(testing.allocator);
    try testing.expectEqualStrings("sample.txt", report.path);
    try testing.expectEqual(@as(usize, 2), report.line_number);
    try testing.expectEqual(@as(usize, 4), report.column_number);
    try testing.expectEqualStrings("zzzabcqq", report.line);
    try testing.expect(report.owned_line == null);
    try testing.expectEqual(Span{ .start = 11, .end = 19 }, report.line_span);
    try testing.expectEqual(Span{ .start = 14, .end = 17 }, report.match_span);
}

test "reportFirstMatch handles matches on the first line" {
    const testing = std.testing;

    const haystack = "abc on line one\nsecond line\n";
    const report = (try reportFirstMatch(testing.allocator, "abc", "first.txt", haystack, .{})).?;

    defer report.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), report.line_number);
    try testing.expectEqual(@as(usize, 1), report.column_number);
    try testing.expectEqualStrings("abc on line one", report.line);
    try testing.expect(report.owned_line == null);
    try testing.expectEqual(Span{ .start = 0, .end = 15 }, report.line_span);
    try testing.expectEqual(Span{ .start = 0, .end = 3 }, report.match_span);
}

test "reportFirstMatch returns null when no match exists" {
    const testing = std.testing;

    try testing.expect((try reportFirstMatch(testing.allocator, "needle", "missing.txt", "haystack", .{})) == null);
}

test "reportFirstMatch rejects unsupported case-insensitive search for now" {
    const testing = std.testing;

    try testing.expectError(error.UnsupportedCaseInsensitive, reportFirstMatch(
        testing.allocator,
        "abc",
        "sample.txt",
        "ABC",
        .{ .case_insensitive = true },
    ));
}

test "Searcher can report exact literal matches on invalid UTF-8 through byte fallback" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "needle", .{});
    defer searcher.deinit();

    const report = searcher.reportFirstByteMatch("sample.bin", "xx\xffneedleyy").?;
    defer report.deinit(testing.allocator);

    try testing.expectEqualStrings("sample.bin", report.path);
    try testing.expectEqual(@as(usize, 1), report.line_number);
    try testing.expectEqual(@as(usize, 4), report.column_number);
    try testing.expectEqualStrings("xx\xffneedleyy", report.line);
    try testing.expect(report.owned_line == null);
    try testing.expectEqual(Span{ .start = 0, .end = 11 }, report.line_span);
    try testing.expectEqual(Span{ .start = 3, .end = 9 }, report.match_span);
}

test "Searcher byte fallback supports UTF-8 literal patterns" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "жар", .{});
    defer searcher.deinit();

    const report = (try searcher.reportFirstByteMatch("utf8.bin", "xx\xffжарyy")).?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), report.column_number);
    try testing.expectEqual(Span{ .start = 3, .end = 9 }, report.match_span);
}

test "Searcher byte fallback supports literal-only UTF-8 classes" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "[ж]", .{});
    defer searcher.deinit();

    const report = (try searcher.reportFirstByteMatch("utf8-class.bin", "xx\xffжyy")).?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), report.column_number);
    try testing.expectEqual(Span{ .start = 3, .end = 5 }, report.match_span);
}

test "Searcher byte fallback supports repetition over literal-only UTF-8 classes" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "[жё]{2}", .{});
    defer searcher.deinit();

    const report = (try searcher.reportFirstByteMatch("utf8-class.bin", "x\xffжёz")).?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), report.column_number);
    try testing.expectEqual(Span{ .start = 2, .end = 6 }, report.match_span);
}

test "Searcher byte fallback supports small UTF-8 range classes" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "[а-я]", .{});
    defer searcher.deinit();

    const report = (try searcher.reportFirstByteMatch("utf8-range.bin", "xx\xffжyy")).?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), report.column_number);
    try testing.expectEqual(Span{ .start = 3, .end = 5 }, report.match_span);
}

test "Searcher byte fallback supports repetition over small UTF-8 range classes" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "[а-я]{2}", .{});
    defer searcher.deinit();

    const report = (try searcher.reportFirstByteMatch("utf8-range.bin", "x\xffжяz")).?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), report.column_number);
    try testing.expectEqual(Span{ .start = 2, .end = 6 }, report.match_span);
}

test "Searcher byte fallback is limited to exact literal patterns" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "a.b", .{});
    defer searcher.deinit();

    try testing.expect(searcher.reportFirstByteMatch("sample.bin", "a\xffb") == null);
}

test "Searcher byte fallback supports anchored literal start and end patterns" {
    const testing = std.testing;

    var start_searcher = try Searcher.init(testing.allocator, "^needle", .{});
    defer start_searcher.deinit();
    try testing.expect(start_searcher.reportFirstByteMatch("start.bin", "needle\xfftail") != null);
    try testing.expect(start_searcher.reportFirstByteMatch("start.bin", "xxneedle") == null);

    var end_searcher = try Searcher.init(testing.allocator, "needle$", .{});
    defer end_searcher.deinit();
    try testing.expect(end_searcher.reportFirstByteMatch("end.bin", "xx\xffneedle") != null);
    try testing.expect(end_searcher.reportFirstByteMatch("end.bin", "needlexx") == null);

    var full_searcher = try Searcher.init(testing.allocator, "^needle$", .{});
    defer full_searcher.deinit();
    try testing.expect(full_searcher.reportFirstByteMatch("full.bin", "needle") != null);
    try testing.expect(full_searcher.reportFirstByteMatch("full.bin", "needle\xff") == null);
}

test "Searcher byte fallback supports ASCII literal alternation" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "foo|needle|bar", .{});
    defer searcher.deinit();

    const report = searcher.reportFirstByteMatch("alt.bin", "xx\xffneedleyy").?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), report.column_number);
    try testing.expectEqualStrings("xx\xffneedleyy", report.line);
    try testing.expectEqual(Span{ .start = 3, .end = 9 }, report.match_span);
}

test "Searcher byte fallback supports simple dot-separated ASCII patterns" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "a.b", .{});
    defer searcher.deinit();

    const report = searcher.reportFirstByteMatch("dot.bin", "xxa\xffbyy").?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), report.column_number);
    try testing.expectEqualStrings("xxa\xffbyy", report.line);
    try testing.expectEqual(Span{ .start = 2, .end = 5 }, report.match_span);
}

test "Searcher byte fallback keeps dot from matching newlines" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "a.b", .{});
    defer searcher.deinit();

    try testing.expect(searcher.reportFirstByteMatch("dot.bin", "a\nb") == null);
}

test "Searcher byte fallback supports simple ASCII class patterns" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "a[0-9]b", .{});
    defer searcher.deinit();

    const report = searcher.reportFirstByteMatch("class.bin", "xxa\xffb a7b").?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 7), report.column_number);
    try testing.expectEqual(Span{ .start = 6, .end = 9 }, report.match_span);
}

test "Searcher byte fallback supports negated ASCII class patterns" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "a[^x]b", .{});
    defer searcher.deinit();

    const report = searcher.reportFirstByteMatch("negated.bin", "a\xffb").?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), report.column_number);
    try testing.expectEqual(Span{ .start = 0, .end = 3 }, report.match_span);
}

test "Searcher byte fallback supports mixed dot and class sequences" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "a.[0-9]b", .{});
    defer searcher.deinit();

    const report = searcher.reportFirstByteMatch("mixed.bin", "xxa\xff7byy").?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), report.column_number);
    try testing.expectEqual(Span{ .start = 2, .end = 6 }, report.match_span);
}

test "Searcher byte fallback supports fixed counted repetition" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "ab{2}c", .{});
    defer searcher.deinit();

    const report = searcher.reportFirstByteMatch("repeat.bin", "xxabbcyy").?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), report.column_number);
    try testing.expectEqual(Span{ .start = 2, .end = 6 }, report.match_span);
}

test "Searcher byte fallback supports fixed repetition over wildcard and class atoms" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "a.{2}[0-9]{2}b", .{});
    defer searcher.deinit();

    const report = searcher.reportFirstByteMatch("repeat-mixed.bin", "xa\xffy42bz").?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), report.column_number);
    try testing.expectEqual(Span{ .start = 1, .end = 7 }, report.match_span);
}

test "Searcher byte fallback supports plus repetition over literal atoms" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "ab+c", .{});
    defer searcher.deinit();

    const report = searcher.reportFirstByteMatch("repeat.bin", "xxabbbc").?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), report.column_number);
    try testing.expectEqual(Span{ .start = 2, .end = 7 }, report.match_span);
}

test "Searcher byte fallback supports star repetition over wildcard atoms" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "a.*b", .{});
    defer searcher.deinit();

    const report = searcher.reportFirstByteMatch("star.bin", "xa\xffy42bz").?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), report.column_number);
    try testing.expectEqual(Span{ .start = 1, .end = 7 }, report.match_span);
}

test "Searcher byte fallback supports bounded repetition over class atoms" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "a[0-9]{1,3}b", .{});
    defer searcher.deinit();

    const report = searcher.reportFirstByteMatch("range.bin", "xa42bz").?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), report.column_number);
    try testing.expectEqual(Span{ .start = 1, .end = 5 }, report.match_span);
}

test "Searcher byte fallback supports optional repetition" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "ab?c", .{});
    defer searcher.deinit();

    try testing.expect(searcher.reportFirstByteMatch("optional.bin", "ac") != null);
    try testing.expect(searcher.reportFirstByteMatch("optional.bin", "abc") != null);
}

test "Searcher byte fallback treats simple groups transparently" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "(a.[0-9]b)", .{});
    defer searcher.deinit();

    const report = searcher.reportFirstByteMatch("group.bin", "xxa\xff7byy").?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), report.column_number);
    try testing.expectEqual(Span{ .start = 2, .end = 6 }, report.match_span);
}

test "Searcher firstByteMatch reports planner-friendly capture groups" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "(a.)([0-9]b)", .{});
    defer searcher.deinit();

    const found = (try searcher.firstByteMatch("xxa\xff7byy")).?;
    defer found.deinit(testing.allocator);

    try testing.expectEqual(@as(?usize, 2), found.span.start);
    try testing.expectEqual(@as(?usize, 6), found.span.end);
    try testing.expectEqual(@as(usize, 2), found.groups.len);
    try testing.expectEqual(@as(?usize, 2), found.groups[0].start);
    try testing.expectEqual(@as(?usize, 4), found.groups[0].end);
    try testing.expectEqual(@as(?usize, 4), found.groups[1].start);
    try testing.expectEqual(@as(?usize, 6), found.groups[1].end);
}

test "Searcher firstByteMatch preserves UTF-8 literal captures on the byte path" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "(ж)(ар)", .{});
    defer searcher.deinit();

    const found = (try searcher.firstByteMatch("xx\xffжарyy")).?;
    defer found.deinit(testing.allocator);

    try testing.expectEqual(@as(?usize, 3), found.span.start);
    try testing.expectEqual(@as(?usize, 9), found.span.end);
    try testing.expectEqual(@as(usize, 2), found.groups.len);
    try testing.expectEqual(@as(?usize, 3), found.groups[0].start);
    try testing.expectEqual(@as(?usize, 5), found.groups[0].end);
    try testing.expectEqual(@as(?usize, 5), found.groups[1].start);
    try testing.expectEqual(@as(?usize, 9), found.groups[1].end);
}

test "Searcher byte fallback supports repetition over grouped literal subpatterns" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "(ab)+c", .{});
    defer searcher.deinit();

    const report = searcher.reportFirstByteMatch("group-repeat.bin", "xxababc").?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), report.column_number);
    try testing.expectEqual(Span{ .start = 2, .end = 7 }, report.match_span);
}

test "Searcher firstByteMatch reports the last repeated group capture on the byte path" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "(ab)+c", .{});
    defer searcher.deinit();

    const found = (try searcher.firstByteMatch("xxababc")).?;
    defer found.deinit(testing.allocator);

    try testing.expectEqual(@as(?usize, 2), found.span.start);
    try testing.expectEqual(@as(?usize, 7), found.span.end);
    try testing.expectEqual(@as(usize, 1), found.groups.len);
    try testing.expectEqual(@as(?usize, 4), found.groups[0].start);
    try testing.expectEqual(@as(?usize, 6), found.groups[0].end);
}

test "Searcher byte fallback supports counted repetition over grouped simple byte patterns" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "(a[0-9]){2}", .{});
    defer searcher.deinit();

    const report = searcher.reportFirstByteMatch("group-repeat.bin", "xa4a2z").?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), report.column_number);
    try testing.expectEqual(Span{ .start = 1, .end = 5 }, report.match_span);
}

test "Searcher byte fallback supports grouped alternation inside a byte sequence" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "a(ab|cd)e", .{});
    defer searcher.deinit();

    const report = searcher.reportFirstByteMatch("group-alt.bin", "xxacdeyy").?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), report.column_number);
    try testing.expectEqual(Span{ .start = 2, .end = 6 }, report.match_span);
}

test "Searcher byte fallback supports grouped alternation with mixed simple branches" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "a((b.)|([0-9]x))c", .{});
    defer searcher.deinit();

    const report = searcher.reportFirstByteMatch("group-alt.bin", "xa7xcz").?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), report.column_number);
    try testing.expectEqual(Span{ .start = 1, .end = 5 }, report.match_span);
}

test "Searcher byte fallback supports quantified grouped alternation" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "((ab)|(cd))+e", .{});
    defer searcher.deinit();

    const report = searcher.reportFirstByteMatch("alt-repeat.bin", "xxabcdabe").?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), report.column_number);
    try testing.expectEqual(Span{ .start = 2, .end = 9 }, report.match_span);
}

test "Searcher byte fallback supports counted repetition over grouped alternation" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "((a[0-9])|(b.)){2}c", .{});
    defer searcher.deinit();

    const report = searcher.reportFirstByteMatch("alt-repeat.bin", "xa4b\xffc").?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), report.column_number);
    try testing.expectEqual(Span{ .start = 1, .end = 6 }, report.match_span);
}

test "Searcher byte fallback supports quantified grouped alternation with an empty branch" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "((|ab))+c", .{});
    defer searcher.deinit();

    try testing.expect(searcher.reportFirstByteMatch("empty-alt-repeat.bin", "c") != null);
    try testing.expect(searcher.reportFirstByteMatch("empty-alt-repeat.bin", "abc") != null);
}

test "Searcher byte fallback supports counted repetition over empty alternation branches" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "((|ab)){2}c", .{});
    defer searcher.deinit();

    try testing.expect(searcher.reportFirstByteMatch("empty-alt-repeat.bin", "c") != null);
    try testing.expect(searcher.reportFirstByteMatch("empty-alt-repeat.bin", "abc") != null);
}

test "Searcher byte fallback supports empty alternation branches inside a sequence" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "a(|b)c", .{});
    defer searcher.deinit();

    try testing.expect(searcher.reportFirstByteMatch("empty-alt.bin", "ac") != null);
    try testing.expect(searcher.reportFirstByteMatch("empty-alt.bin", "abc") != null);
}

test "Searcher byte fallback supports anchored empty matches" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "^$", .{});
    defer searcher.deinit();

    const report = searcher.reportFirstByteMatch("empty.bin", "").?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), report.line_number);
    try testing.expectEqual(@as(usize, 1), report.column_number);
    try testing.expectEqual(Span{ .start = 0, .end = 0 }, report.match_span);
}

test "reportFirstMatch stays aligned across buffered and mmap file reads" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "sample.txt",
        .data =
            "first line\n" ++
            "second line\n" ++
            "late needle here\n",
    });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);
    const file_path = try std.fs.path.join(testing.allocator, &.{ root_path, "sample.txt" });
    defer testing.allocator.free(file_path);

    const buffered = try io.readFile(testing.allocator, file_path, .{ .strategy = .buffered });
    defer buffered.deinit(testing.allocator);

    const mapped = try io.readFile(testing.allocator, file_path, .{ .strategy = .mmap });
    defer mapped.deinit(testing.allocator);

    const buffered_report = (try reportFirstMatch(
        testing.allocator,
        "needle",
        file_path,
        buffered.bytes(),
        .{},
    )).?;
    defer buffered_report.deinit(testing.allocator);

    const mapped_report = (try reportFirstMatch(
        testing.allocator,
        "needle",
        file_path,
        mapped.bytes(),
        .{},
    )).?;
    defer mapped_report.deinit(testing.allocator);

    try testing.expectEqualStrings(buffered_report.path, mapped_report.path);
    try testing.expectEqual(buffered_report.line_number, mapped_report.line_number);
    try testing.expectEqual(buffered_report.column_number, mapped_report.column_number);
    try testing.expectEqualStrings(buffered_report.line, mapped_report.line);
    try testing.expectEqual(buffered_report.line_span, mapped_report.line_span);
    try testing.expectEqual(buffered_report.match_span, mapped_report.match_span);
}
