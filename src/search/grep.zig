const std = @import("std");
const regex = @import("../regex/root.zig");
const report_mod = @import("report.zig");
const io = @import("io.zig");

pub const SearchError = regex.ParseError || regex.Nfa.CompileError || regex.Vm.MatchError || error{
    UnsupportedCaseInsensitivePattern,
    InvalidMultilineOptions,
};

pub const CaseMode = enum {
    sensitive,
    insensitive,
    smart,
};

pub const SearchOptions = struct {
    case_mode: CaseMode = .sensitive,
    // Phase 1 multiline plumbing: these flags define the intended engine
    // surface, even though multiline execution is not wired yet.
    multiline: bool = false,
    multiline_dotall: bool = false,
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
    utf8_class: regex.hir.CharacterClass,
    anchor_start,
    anchor_end,
    alternation: []BytePattern,
    save_start: u32,
    save_end: u32,

    fn deinit(self: ByteAtom, allocator: std.mem.Allocator) void {
        switch (self) {
            .literal => |bytes| allocator.free(bytes),
            .class, .utf8_class => |class| allocator.free(class.items),
            .alternation => |patterns| {
                for (patterns) |pattern| pattern.deinit(allocator);
                allocator.free(patterns);
            },
            .any_byte, .anchor_start, .anchor_end, .save_start, .save_end => {},
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
        if (options.multiline_dotall and !options.multiline) {
            return error.InvalidMultilineOptions;
        }

        var hir = try regex.compile(allocator, pattern, .{});
        defer hir.deinit(allocator);

        if (shouldFoldCase(pattern, options.case_mode)) {
            regex.hir.applySimpleCaseFold(allocator, &hir) catch |err| switch (err) {
                error.UnsupportedCaseInsensitivePattern => return error.UnsupportedCaseInsensitivePattern,
                error.OutOfMemory => return error.OutOfMemory,
            };
        }

        return .{
            .allocator = allocator,
            .engine = regex.Vm.MatchEngine.init(allocator),
            .program = try regex.Nfa.compile(allocator, hir, .{
                .multiline = options.multiline,
                .multiline_dotall = options.multiline_dotall,
            }),
            .byte_plan = try extractByteSearchPlan(allocator, hir),
        };
    }

    pub fn deinit(self: *Searcher) void {
        self.byte_plan.deinit(self.allocator);
        self.program.deinit(self.allocator);
    }

    pub fn reportFirstMatch(self: *Searcher, path: []const u8, haystack: []const u8) SearchError!?MatchReport {
        const found = self.engine.firstMatch(self.program, haystack) catch |err| switch (err) {
            error.InvalidUtf8 => try self.firstByteMatch(haystack),
            else => return err,
        };
        if (found) |match| {
            defer match.deinit(self.allocator);
            return buildReport(path, haystack, match.span);
        }
        return null;
    }

    pub fn forEachLineReport(
        self: *Searcher,
        path: []const u8,
        haystack: []const u8,
        context: anytype,
        comptime emit: fn (@TypeOf(context), MatchReport) anyerror!void,
    ) anyerror!bool {
        var offset: usize = 0;
        var matched = false;

        while (offset <= haystack.len) {
            const result = (try self.firstMatchFrom(haystack, offset)) orelse break;
            defer result.match.deinit(self.allocator);

            const report = buildReport(path, haystack, result.match.span);
            try emit(context, report);
            matched = true;

            const next_offset = nextLineSearchOffset(haystack, report.line_span.end);
            if (next_offset <= offset) break;
            offset = next_offset;
        }

        return matched;
    }

    pub fn forEachMatchReport(
        self: *Searcher,
        path: []const u8,
        haystack: []const u8,
        context: anytype,
        comptime emit: fn (@TypeOf(context), MatchReport) anyerror!void,
    ) anyerror!bool {
        var offset: usize = 0;
        var matched = false;

        while (offset <= haystack.len) {
            const result = (try self.firstMatchFrom(haystack, offset)) orelse break;
            defer result.match.deinit(self.allocator);

            const report = buildReport(path, haystack, result.match.span);
            try emit(context, report);
            matched = true;

            const next_offset = nextMatchSearchOffset(haystack, report.match_span);
            if (next_offset <= offset) break;
            offset = next_offset;
        }

        return matched;
    }

    pub fn firstByteMatch(self: *Searcher, haystack: []const u8) regex.Vm.MatchError!?regex.Vm.Match {
        if (self.byte_plan == .none or bytePlanNeedsGeneralVm(self.byte_plan)) {
            return self.engine.firstMatchBytes(self.program, haystack);
        }

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

    const FirstMatchResult = struct {
        match: regex.Vm.Match,
    };

    fn firstMatchFrom(self: *Searcher, haystack: []const u8, offset: usize) SearchError!?FirstMatchResult {
        if (offset > haystack.len) return null;

        const slice = haystack[offset..];
        const found = self.engine.firstMatch(self.program, slice) catch |err| switch (err) {
            error.InvalidUtf8 => try self.firstByteMatch(slice),
            else => return err,
        } orelse return null;

        var adjusted = found;
        addOffsetToCapture(&adjusted.span, offset);
        for (adjusted.groups) |*group| addOffsetToCapture(group, offset);
        return .{ .match = adjusted };
    }
};

fn shouldFoldCase(pattern: []const u8, case_mode: CaseMode) bool {
    return switch (case_mode) {
        .sensitive => false,
        .insensitive => true,
        .smart => !patternHasUppercase(pattern),
    };
}

fn patternHasUppercase(pattern: []const u8) bool {
    var index: usize = 0;
    while (index < pattern.len) {
        const byte = pattern[index];
        if (byte < 0x80) {
            if (std.ascii.isUpper(byte)) return true;
            index += 1;
            continue;
        }

        const width = std.unicode.utf8ByteSequenceLength(byte) catch {
            index += 1;
            continue;
        };
        if (index + width > pattern.len) {
            index += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(pattern[index .. index + width]) catch {
            index += 1;
            continue;
        };
        if (isUppercaseCodePoint(cp)) return true;
        index += width;
    }
    return false;
}

fn isUppercaseCodePoint(cp: u32) bool {
    if (cp <= 0x7f) return std.ascii.isUpper(@as(u8, @intCast(cp)));
    if (cp > 0xFFFF) return false;

    const upper = std.os.windows.nls.upcaseW(@as(u16, @intCast(cp)));
    if (upper != cp) return false;

    var candidate: u32 = 0;
    while (candidate <= 0xFFFF) : (candidate += 1) {
        if (candidate == cp) continue;
        if (std.os.windows.nls.upcaseW(@as(u16, @intCast(candidate))) == upper) return true;
    }
    return false;
}

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

fn expectBytePlan(pattern: []const u8, expected: bool) !void {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, pattern, .{});
    defer searcher.deinit();

    try testing.expectEqual(expected, searcher.hasBytePlan());
}

fn expectPlannerAndVmEquivalent(pattern: []const u8, haystack: []const u8) !void {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, pattern, .{});
    defer searcher.deinit();

    try testing.expect(searcher.hasBytePlan());

    const planner_match = (try searcher.firstByteMatch(haystack)).?;
    defer planner_match.deinit(testing.allocator);

    const vm_match = (try searcher.engine.firstMatchBytes(searcher.program, haystack)).?;
    defer vm_match.deinit(testing.allocator);

    try testing.expectEqual(planner_match.span, vm_match.span);
    try testing.expectEqual(@as(usize, planner_match.groups.len), vm_match.groups.len);
    for (planner_match.groups, vm_match.groups) |planner_group, vm_group| {
        try testing.expectEqual(planner_group, vm_group);
    }

    const planner_report = buildReport("sample.bin", haystack, planner_match.span);
    const vm_report = buildReport("sample.bin", haystack, vm_match.span);
    try testing.expectEqual(planner_report.line_number, vm_report.line_number);
    try testing.expectEqual(planner_report.column_number, vm_report.column_number);
    try testing.expectEqual(planner_report.line_span, vm_report.line_span);
    try testing.expectEqual(planner_report.match_span, vm_report.match_span);
    try testing.expectEqualStrings(planner_report.line, vm_report.line);
}

fn expectInvalidUtf8MatchSpan(pattern: []const u8, haystack: []const u8, expected: Span) !void {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, pattern, .{});
    defer searcher.deinit();

    const found = (try searcher.firstByteMatch(haystack)).?;
    defer found.deinit(testing.allocator);

    try testing.expectEqual(expected, .{
        .start = found.span.start.?,
        .end = found.span.end.?,
    });
}

fn addOffsetToCapture(capture: *regex.Vm.Capture, offset: usize) void {
    if (capture.start) |start| capture.start = start + offset;
    if (capture.end) |end| capture.end = end + offset;
}

fn nextLineSearchOffset(haystack: []const u8, line_end: usize) usize {
    if (line_end < haystack.len and haystack[line_end] == '\n') return line_end + 1;
    return line_end;
}

fn nextMatchSearchOffset(haystack: []const u8, match_span: Span) usize {
    if (match_span.end > match_span.start) return match_span.end;
    if (match_span.end >= haystack.len) return haystack.len + 1;

    const byte = haystack[match_span.end];
    const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch return match_span.end + 1;
    if (match_span.end + seq_len > haystack.len) return match_span.end + 1;
    _ = std.unicode.utf8Decode(haystack[match_span.end .. match_span.end + seq_len]) catch return match_span.end + 1;
    return match_span.end + seq_len;
}

fn bytePlanNeedsGeneralVm(plan: ByteSearchPlan) bool {
    return switch (plan) {
        .none => true,
        .single => |pattern| patternNeedsGeneralVm(pattern),
        .alternation => |patterns| blk: {
            for (patterns) |pattern| {
                if (patternNeedsGeneralVm(pattern)) break :blk true;
            }
            break :blk false;
        },
    };
}

fn patternNeedsGeneralVm(pattern: BytePattern) bool {
    for (pattern.terms) |term| {
        if (termNeedsGeneralVm(term)) return true;
    }
    return false;
}

fn termNeedsGeneralVm(term: ByteTerm) bool {
    return atomNeedsGeneralVm(term.atom);
}

fn atomNeedsGeneralVm(atom: ByteAtom) bool {
    return switch (atom) {
        .any_byte => true,
        .alternation => |patterns| blk: {
            for (patterns) |pattern| {
                if (patternNeedsGeneralVm(pattern)) break :blk true;
            }
            break :blk false;
        },
        .literal,
        .class,
        .utf8_class,
        .anchor_start,
        .anchor_end,
        .save_start,
        .save_end,
        => false,
    };
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
        .alternation => blk: {
            const term = (try extractAlternationByteTerm(allocator, nodes, root)) orelse break :blk null;
            const terms = try allocator.alloc(ByteTerm, 1);
            terms[0] = term;
            break :blk .{
                .mode = .contains,
                .terms = terms,
            };
        },
        .anchor_start => .{
            .mode = .start,
            .terms = try allocator.alloc(ByteTerm, 0),
        },
        .anchor_end => .{
            .mode = .end,
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
        .empty => {
            return true;
        },
        .group => |group| {
            try flushLiteralTerm(allocator, terms, literal_bytes);
            try terms.append(allocator, .{ .atom = .{ .save_start = group.index } });
            if (try extractAlternationByteTerm(allocator, nodes, group.child)) |term| {
                try terms.append(allocator, term);
            } else if (try extractBytePattern(allocator, nodes, group.child)) |pattern| {
                if (pattern.mode != .contains) {
                    pattern.deinit(allocator);
                    return false;
                }
                try appendOwnedPatternTerms(allocator, terms, pattern);
            } else if (!(try appendNodeToByteTerms(allocator, nodes, group.child, terms, literal_bytes))) {
                return false;
            }
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
        .anchor_start => {
            try flushLiteralTerm(allocator, terms, literal_bytes);
            try terms.append(allocator, .{ .atom = .anchor_start });
            return true;
        },
        .anchor_end => {
            try flushLiteralTerm(allocator, terms, literal_bytes);
            try terms.append(allocator, .{ .atom = .anchor_end });
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
            if (try classToUtf8Atom(allocator, class)) |atom| {
                try terms.append(allocator, .{ .atom = atom });
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
                .anchor_start => ByteAtom.anchor_start,
                .anchor_end => ByteAtom.anchor_end,
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
                .utf8_class, .alternation, .save_start, .save_end => return null,
            };
            _ = children;
            break :blk dup_atom;
        },
        .anchor_start => ByteAtom.anchor_start,
        .anchor_end => ByteAtom.anchor_end,
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
            if (try classToUtf8Atom(allocator, class)) |atom| {
                break :blk atom;
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
        try patterns.append(allocator, (try extractBytePattern(allocator, nodes, branch)) orelse return null);
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
    if (class.items.len == 0) return null;
    if (class.negated) return null;

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

fn classToUtf8Atom(
    allocator: std.mem.Allocator,
    class: regex.hir.CharacterClass,
) BytePlanError!?ByteAtom {
    if (class.items.len == 0) return null;
    var saw_non_ascii = false;
    for (class.items) |item| {
        switch (item) {
            .literal => |cp| {
                if (cp > 0x7f) saw_non_ascii = true;
            },
            .range => |range| {
                if (range.start > 0x7f or range.end > 0x7f) saw_non_ascii = true;
            },
        }
    }
    if (!saw_non_ascii) return null;

    const duped_items = try allocator.alloc(regex.hir.ClassItem, class.items.len);
    @memcpy(duped_items, class.items);
    return .{
        .utf8_class = .{
            .negated = class.negated,
            .items = duped_items,
        },
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

fn appendOwnedPatternTerms(
    allocator: std.mem.Allocator,
    terms: *std.ArrayList(ByteTerm),
    pattern: BytePattern,
) BytePlanError!void {
    try terms.appendSlice(allocator, pattern.terms);
    allocator.free(pattern.terms);
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
        .utf8_class => return matchUtf8ClassTerm(term, terms, term_index, haystack, pos),
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

fn matchUtf8ClassTerm(
    term: ByteTerm,
    terms: []const ByteTerm,
    term_index: usize,
    haystack: []const u8,
    pos: usize,
) ?usize {
    return matchUtf8ClassTermReps(term, terms, term_index, haystack, pos, 0);
}

fn matchUtf8ClassTermReps(
    term: ByteTerm,
    terms: []const ByteTerm,
    term_index: usize,
    haystack: []const u8,
    pos: usize,
    count: u32,
) ?usize {
    if (count >= term.min) {
        if (matchByteTermsAt(terms, haystack, term_index + 1, pos)) |end| return end;
    }
    if (term.max != null and count >= term.max.?) return null;

    const next_pos = matchByteAtomAt(term.atom, haystack, pos) orelse return null;
    return matchUtf8ClassTermReps(term, terms, term_index, haystack, next_pos, count + 1);
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
    return switch (pattern.mode) {
        .contains => matchByteTermsAt(pattern.terms, haystack, 0, pos),
        .start => if (pos == 0) matchByteTermsAt(pattern.terms, haystack, 0, pos) else null,
        .end => blk: {
            const end = matchByteTermsAt(pattern.terms, haystack, 0, pos) orelse break :blk null;
            break :blk if (end == haystack.len) end else null;
        },
        .full => if (pos == 0) blk: {
            const end = matchByteTermsAt(pattern.terms, haystack, 0, pos) orelse break :blk null;
            break :blk if (end == haystack.len) end else null;
        } else null,
    };
}

fn matchContainedBytePatternAtWithSlots(
    allocator: std.mem.Allocator,
    pattern: BytePattern,
    haystack: []const u8,
    pos: usize,
    slots: []?usize,
) regex.Vm.MatchError!?usize {
    return switch (pattern.mode) {
        .contains => matchByteTermsAtWithSlots(allocator, pattern.terms, haystack, 0, pos, slots),
        .start => if (pos == 0)
            matchByteTermsAtWithSlots(allocator, pattern.terms, haystack, 0, pos, slots)
        else
            null,
        .end => blk: {
            const end = try matchByteTermsAtWithSlots(allocator, pattern.terms, haystack, 0, pos, slots) orelse break :blk null;
            break :blk if (end == haystack.len) end else null;
        },
        .full => if (pos == 0) blk: {
            const end = try matchByteTermsAtWithSlots(allocator, pattern.terms, haystack, 0, pos, slots) orelse break :blk null;
            break :blk if (end == haystack.len) end else null;
        } else null,
    };
}

fn matchUtf8ClassTermWithSlots(
    allocator: std.mem.Allocator,
    term: ByteTerm,
    terms: []const ByteTerm,
    term_index: usize,
    haystack: []const u8,
    pos: usize,
    slots: []?usize,
) regex.Vm.MatchError!?usize {
    return matchUtf8ClassTermRepsWithSlots(allocator, term, terms, term_index, haystack, pos, slots, 0);
}

fn matchUtf8ClassTermRepsWithSlots(
    allocator: std.mem.Allocator,
    term: ByteTerm,
    terms: []const ByteTerm,
    term_index: usize,
    haystack: []const u8,
    pos: usize,
    slots: []?usize,
    count: u32,
) regex.Vm.MatchError!?usize {
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

    if (try matchUtf8ClassTermRepsWithSlots(allocator, term, terms, term_index, haystack, next_pos, slots, count + 1)) |end| return end;

    restoreSlots(slots, atom_snapshot);
    return null;
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

    if (term.atom == .utf8_class) {
        return matchUtf8ClassTermWithSlots(allocator, term, terms, term_index, haystack, pos, slots);
    }

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
        .utf8_class => |class| matchUtf8ClassAt(class, haystack, pos),
        .anchor_start => if (pos == 0) pos else null,
        .anchor_end => if (pos == haystack.len) pos else null,
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
        .literal, .any_byte, .class, .utf8_class, .anchor_start, .anchor_end => matchByteAtomAt(atom, haystack, pos),
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
        .any_byte, .class, .utf8_class => 1,
        .anchor_start, .anchor_end => 0,
        .alternation => unreachable,
        .save_start, .save_end => 0,
    };
}

fn byteAtomMinLen(atom: ByteAtom) usize {
    return switch (atom) {
        .literal => |bytes| bytes.len,
        .any_byte, .class, .utf8_class => 1,
        .anchor_start, .anchor_end => 0,
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
    return classMatchesCodePoint(class, byte);
}

fn classMatchesCodePoint(class: regex.hir.CharacterClass, cp: u32) bool {
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

fn matchUtf8ClassAt(class: regex.hir.CharacterClass, haystack: []const u8, pos: usize) ?usize {
    if (pos >= haystack.len) return null;

    const byte = haystack[pos];
    if (byte < 0x80) {
        return if (classMatchesCodePoint(class, byte)) pos + 1 else null;
    }

    const seq_len = std.unicode.utf8ByteSequenceLength(byte) catch {
        return if (class.negated) pos + 1 else null;
    };
    if (pos + seq_len > haystack.len) {
        return if (class.negated) pos + 1 else null;
    }

    const seq = haystack[pos .. pos + seq_len];
    const cp = std.unicode.utf8Decode(seq) catch {
        return if (class.negated) pos + 1 else null;
    };

    return if (classMatchesCodePoint(class, cp)) pos + seq_len else null;
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

test "Searcher forEachLineReport emits every matching line once" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "needle", .{});
    defer searcher.deinit();

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(testing.allocator);

    const Collector = struct {
        lines: *std.ArrayList([]const u8),

        fn emit(self: *@This(), report: MatchReport) !void {
            try self.lines.append(testing.allocator, report.line);
        }
    };

    var collector = Collector{ .lines = &lines };
    const matched = try searcher.forEachLineReport(
        "sample.txt",
        "needle one\nskip\nneedle two\nneedle needle\n",
        &collector,
        Collector.emit,
    );

    try testing.expect(matched);
    try testing.expectEqual(@as(usize, 3), lines.items.len);
    try testing.expectEqualStrings("needle one", lines.items[0]);
    try testing.expectEqualStrings("needle two", lines.items[1]);
    try testing.expectEqualStrings("needle needle", lines.items[2]);
}

test "Searcher forEachMatchReport emits every match occurrence" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "needle", .{});
    defer searcher.deinit();

    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(testing.allocator);

    const Collector = struct {
        spans: *std.ArrayList(Span),

        fn emit(self: *@This(), report: MatchReport) !void {
            try self.spans.append(testing.allocator, report.match_span);
        }
    };

    var collector = Collector{ .spans = &spans };
    const matched = try searcher.forEachMatchReport(
        "sample.txt",
        "needle and needle again\nneedle\n",
        &collector,
        Collector.emit,
    );

    try testing.expect(matched);
    try testing.expectEqual(@as(usize, 3), spans.items.len);
    try testing.expectEqual(Span{ .start = 0, .end = 6 }, spans.items[0]);
    try testing.expectEqual(Span{ .start = 11, .end = 17 }, spans.items[1]);
    try testing.expectEqual(Span{ .start = 24, .end = 30 }, spans.items[2]);
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

test "reportFirstMatch supports ignore-case literals" {
    const testing = std.testing;

    const report = (try reportFirstMatch(
        testing.allocator,
        "abc",
        "sample.txt",
        "ABC",
        .{ .case_mode = .insensitive },
    )).?;
    defer report.deinit(testing.allocator);

    try testing.expectEqualStrings("ABC", report.line);
    try testing.expectEqual(Span{ .start = 0, .end = 3 }, report.match_span);
}

test "reportFirstMatch supports ignore-case Unicode literals" {
    const testing = std.testing;

    const report = (try reportFirstMatch(
        testing.allocator,
        "жар",
        "sample.txt",
        "ЖАР",
        .{ .case_mode = .insensitive },
    )).?;
    defer report.deinit(testing.allocator);

    try testing.expectEqualStrings("ЖАР", report.line);
}

test "reportFirstMatch supports ignore-case classes" {
    const testing = std.testing;

    const report = (try reportFirstMatch(
        testing.allocator,
        "[a-z]+",
        "sample.txt",
        "ABC",
        .{ .case_mode = .insensitive },
    )).?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(Span{ .start = 0, .end = 3 }, report.match_span);
}

test "reportFirstMatch smart-case keeps uppercase patterns case-sensitive" {
    const testing = std.testing;

    try testing.expect((try reportFirstMatch(
        testing.allocator,
        "Abc",
        "sample.txt",
        "abc",
        .{ .case_mode = .smart },
    )) == null);

    const report = (try reportFirstMatch(
        testing.allocator,
        "abc",
        "sample.txt",
        "ABC",
        .{ .case_mode = .smart },
    )).?;
    defer report.deinit(testing.allocator);
    try testing.expectEqualStrings("ABC", report.line);
}

test "reportFirstMatch rejects oversized case-insensitive ranges" {
    const testing = std.testing;

    try testing.expectError(error.UnsupportedCaseInsensitivePattern, reportFirstMatch(
        testing.allocator,
        "[\u{0100}-\u{2000}]",
        "sample.txt",
        "abc",
        .{ .case_mode = .insensitive },
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

test "Searcher byte fallback supports negated literal-only UTF-8 classes" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "a[^ж]b", .{});
    defer searcher.deinit();

    const report = (try searcher.reportFirstByteMatch("utf8-negated.bin", "aяb")).?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), report.column_number);
    try testing.expectEqual(Span{ .start = 0, .end = 4 }, report.match_span);
    try testing.expect((try searcher.reportFirstByteMatch("utf8-negated.bin", "aжb")) == null);
}

test "Searcher byte fallback lets negated literal-only UTF-8 classes match invalid bytes" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "a[^ж]b", .{});
    defer searcher.deinit();

    const report = (try searcher.reportFirstByteMatch("utf8-negated.bin", "a\xffb")).?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), report.column_number);
    try testing.expectEqual(Span{ .start = 0, .end = 3 }, report.match_span);
}

test "Searcher byte fallback supports negated small UTF-8 range classes" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "a[^а-я]b", .{});
    defer searcher.deinit();

    const report = (try searcher.reportFirstByteMatch("utf8-negated-range.bin", "aѣb")).?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), report.column_number);
    try testing.expectEqual(Span{ .start = 0, .end = 4 }, report.match_span);
    try testing.expect((try searcher.reportFirstByteMatch("utf8-negated-range.bin", "aжb")) == null);
}

test "Searcher byte fallback lets negated small UTF-8 range classes match invalid bytes" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "a[^а-я]b", .{});
    defer searcher.deinit();

    const report = (try searcher.reportFirstByteMatch("utf8-negated-range.bin", "a\xffb")).?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), report.column_number);
    try testing.expectEqual(Span{ .start = 0, .end = 3 }, report.match_span);
}

test "Searcher byte fallback supports larger UTF-8 ranges without expansion" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "[Ā-ӿ]", .{});
    defer searcher.deinit();

    const report = (try searcher.reportFirstByteMatch("utf8-large-range.bin", "xx\xffжyy")).?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), report.column_number);
    try testing.expectEqual(Span{ .start = 3, .end = 5 }, report.match_span);
}

test "Searcher byte fallback supports negated larger UTF-8 ranges without expansion" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "a[^Ā-ӿ]b", .{});
    defer searcher.deinit();

    const report = (try searcher.reportFirstByteMatch("utf8-large-range.bin", "a字b")).?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), report.column_number);
    try testing.expectEqual(Span{ .start = 0, .end = 5 }, report.match_span);
    try testing.expect((try searcher.reportFirstByteMatch("utf8-large-range.bin", "aжb")) == null);
}

test "Searcher byte fallback supports quantified larger UTF-8 ranges" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "[Ā-ӿ]+", .{});
    defer searcher.deinit();

    const report = (try searcher.reportFirstByteMatch("utf8-large-range.bin", "xжѣz")).?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), report.column_number);
    try testing.expectEqual(Span{ .start = 1, .end = 5 }, report.match_span);
}

test "Searcher byte fallback supports counted larger UTF-8 ranges" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "[Ā-ӿ]{2}", .{});
    defer searcher.deinit();

    const report = (try searcher.reportFirstByteMatch("utf8-large-range.bin", "xжѣz")).?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), report.column_number);
    try testing.expectEqual(Span{ .start = 1, .end = 5 }, report.match_span);
}

test "Searcher byte fallback supports long quantified larger UTF-8 ranges" {
    const testing = std.testing;

    var builder: std.ArrayList(u8) = .empty;
    defer builder.deinit(testing.allocator);

    var count: usize = 0;
    while (count < 300) : (count += 1) {
        try builder.appendSlice(testing.allocator, "ж");
    }

    var searcher = try Searcher.init(testing.allocator, "[Ā-ӿ]+", .{});
    defer searcher.deinit();

    const report = (try searcher.reportFirstByteMatch("utf8-long-range.bin", builder.items)).?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), report.column_number);
    try testing.expectEqual(@as(usize, builder.items.len), report.match_span.end - report.match_span.start);
}

test "Searcher byte fallback is limited to exact literal patterns" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "a.b", .{});
    defer searcher.deinit();

    try testing.expect(searcher.reportFirstByteMatch("sample.bin", "a\xffb") == null);
}

test "Searcher byte plan inventory records current unsupported structural shapes" {
    try expectBytePlan("a^b", true);
    try expectBytePlan("a$b", true);
    try expectBytePlan("^+", true);
    try expectBytePlan("x(ab)y", true);
    try expectBytePlan("x(a.[0-9]b)y", true);
    try expectBytePlan("x(^ab)y", true);
    try expectBytePlan("(^ab)y", false);
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

test "Searcher byte fallback supports quantified bare start anchors" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "^+", .{});
    defer searcher.deinit();

    const report = (try searcher.reportFirstByteMatch("anchor.bin", "\xffabc")).?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), report.column_number);
    try testing.expectEqual(Span{ .start = 0, .end = 0 }, report.match_span);
}

test "Searcher byte fallback preserves impossible interior anchor semantics" {
    const testing = std.testing;

    var start_searcher = try Searcher.init(testing.allocator, "a^b", .{});
    defer start_searcher.deinit();
    try testing.expect((try start_searcher.reportFirstByteMatch("anchor.bin", "a\xffb")) == null);

    var end_searcher = try Searcher.init(testing.allocator, "a$b", .{});
    defer end_searcher.deinit();
    try testing.expect((try end_searcher.reportFirstByteMatch("anchor.bin", "a\xffb")) == null);

    var grouped_searcher = try Searcher.init(testing.allocator, "x(^ab)y", .{});
    defer grouped_searcher.deinit();
    try testing.expect((try grouped_searcher.reportFirstByteMatch("anchor.bin", "xaby")) == null);
}

test "Searcher byte matching falls back to the general VM when no byte plan exists" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "(^ab)y", .{});
    defer searcher.deinit();

    try testing.expect(!searcher.hasBytePlan());

    const report = (try searcher.reportFirstByteMatch("anchor.bin", "aby\xff")).?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), report.column_number);
    try testing.expectEqual(Span{ .start = 0, .end = 3 }, report.match_span);
}

test "Searcher planner and raw-byte VM agree on invalid UTF-8 spans" {
    try expectPlannerAndVmEquivalent("needle", "xx\xffneedleyy");
    try expectPlannerAndVmEquivalent("a.b", "xxa\xffbyy");
    try expectPlannerAndVmEquivalent("[ж]", "xx\xffжyy");
    try expectPlannerAndVmEquivalent("(^ab)+c", "abc");
}

test "Searcher planner and raw-byte VM agree on invalid UTF-8 capture spans" {
    try expectPlannerAndVmEquivalent("(a.)([0-9]b)", "xxa\xff7byy");
    try expectPlannerAndVmEquivalent("(ж)(ар)", "xx\xffжарyy");
}

test "Searcher dot patterns defer to the general raw-byte VM for multibyte text units" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, ".x", .{});
    defer searcher.deinit();

    try testing.expect(searcher.hasBytePlan());
    const found = (try searcher.firstByteMatch("\xff©x")).?;
    defer found.deinit(testing.allocator);

    try testing.expectEqual(regex.Vm.Capture{ .start = 1, .end = 4 }, found.span);
}

test "Searcher reportFirstMatch uses raw-byte semantics on invalid UTF-8 input" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "(^ab)y", .{});
    defer searcher.deinit();

    const report = (try searcher.reportFirstMatch("sample.bin", "aby\xff")).?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), report.column_number);
    try testing.expectEqual(Span{ .start = 0, .end = 3 }, report.match_span);
}

test "Searcher rejects multiline-dotall without multiline" {
    const testing = std.testing;

    try testing.expectError(error.InvalidMultilineOptions, Searcher.init(testing.allocator, "a.b", .{
        .multiline_dotall = true,
    }));
}

test "Searcher requires multiline for newline-matching patterns" {
    const testing = std.testing;

    try testing.expectError(error.MultilineRequired, Searcher.init(testing.allocator, "a\\nb", .{}));
}

test "Searcher multiline and dotall flags change newline matching semantics" {
    const testing = std.testing;

    var multiline = try Searcher.init(testing.allocator, "a.b", .{
        .multiline = true,
    });
    defer multiline.deinit();
    try testing.expect((try multiline.reportFirstMatch("sample.txt", "a\nb")) == null);

    var dotall = try Searcher.init(testing.allocator, "a.b", .{
        .multiline = true,
        .multiline_dotall = true,
    });
    defer dotall.deinit();
    try testing.expect((try dotall.reportFirstMatch("sample.txt", "a\nb")) != null);
}

test "Searcher forEachMatchReport advances across repeated multiline matches" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "a\\nb", .{
        .multiline = true,
    });
    defer searcher.deinit();

    const Context = struct {
        allocator: std.mem.Allocator,
        spans: std.ArrayList(Span),

        fn emit(self: *@This(), report: MatchReport) !void {
            try self.spans.append(self.allocator, report.match_span);
        }
    };

    var context = Context{
        .allocator = testing.allocator,
        .spans = .empty,
    };
    defer context.spans.deinit(testing.allocator);

    const matched = try searcher.forEachMatchReport("sample.txt", "a\nba\nb", &context, Context.emit);
    try testing.expect(matched);
    try testing.expectEqual(@as(usize, 2), context.spans.items.len);
    try testing.expectEqual(Span{ .start = 0, .end = 3 }, context.spans.items[0]);
    try testing.expectEqual(Span{ .start = 3, .end = 6 }, context.spans.items[1]);
}

test "Searcher forEachMatchReport advances through zero-width multiline matches" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "", .{
        .multiline = true,
    });
    defer searcher.deinit();

    const Context = struct {
        allocator: std.mem.Allocator,
        spans: std.ArrayList(Span),

        fn emit(self: *@This(), report: MatchReport) !void {
            try self.spans.append(self.allocator, report.match_span);
        }
    };

    var context = Context{
        .allocator = testing.allocator,
        .spans = .empty,
    };
    defer context.spans.deinit(testing.allocator);

    const matched = try searcher.forEachMatchReport("sample.txt", "a\nb", &context, Context.emit);
    try testing.expect(matched);
    try testing.expectEqual(@as(usize, 4), context.spans.items.len);
    try testing.expectEqual(Span{ .start = 0, .end = 0 }, context.spans.items[0]);
    try testing.expectEqual(Span{ .start = 1, .end = 1 }, context.spans.items[1]);
    try testing.expectEqual(Span{ .start = 2, .end = 2 }, context.spans.items[2]);
    try testing.expectEqual(Span{ .start = 3, .end = 3 }, context.spans.items[3]);
}

test "Searcher covers every HIR node kind on invalid UTF-8 input" {
    // empty
    try expectInvalidUtf8MatchSpan("", "\xff", .{ .start = 0, .end = 0 });
    // literal
    try expectInvalidUtf8MatchSpan("ж", "x\xffжy", .{ .start = 2, .end = 4 });
    // dot
    try expectInvalidUtf8MatchSpan(".", "\xff", .{ .start = 0, .end = 1 });
    // anchor_start
    try expectInvalidUtf8MatchSpan("^", "\xffx", .{ .start = 0, .end = 0 });
    // anchor_end
    try expectInvalidUtf8MatchSpan("$", "x\xff", .{ .start = 2, .end = 2 });
    // char_class
    try expectInvalidUtf8MatchSpan("[ж]", "\xffж", .{ .start = 1, .end = 3 });
    // group
    try expectInvalidUtf8MatchSpan("(ж)", "\xffж", .{ .start = 1, .end = 3 });
    // concat
    try expectInvalidUtf8MatchSpan("aж", "\xffaж", .{ .start = 1, .end = 4 });
    // alternation
    try expectInvalidUtf8MatchSpan("x|ж", "\xffж", .{ .start = 1, .end = 3 });
    // repetition
    try expectInvalidUtf8MatchSpan("ж+", "\xffжжx", .{ .start = 1, .end = 5 });
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

test "Searcher byte fallback supports grouped literal concatenation inside a larger sequence" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "x(ab)y", .{});
    defer searcher.deinit();

    const report = searcher.reportFirstByteMatch("group-seq.bin", "zzx\xffabyy").?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), report.column_number);
    try testing.expectEqual(Span{ .start = 2, .end = 7 }, report.match_span);
}

test "Searcher byte fallback supports grouped multi-term concatenation inside a larger sequence" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "x(a.[0-9]b)y", .{});
    defer searcher.deinit();

    const report = searcher.reportFirstByteMatch("group-seq.bin", "zzxa\xff7byy").?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), report.column_number);
    try testing.expectEqual(Span{ .start = 2, .end = 8 }, report.match_span);
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

test "Searcher byte fallback supports repeated grouped alternation without extra wrapper groups" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "(ab|cd)+e", .{});
    defer searcher.deinit();

    const report = (try searcher.reportFirstByteMatch("alt-repeat.bin", "xxabcdabe")).?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), report.column_number);
    try testing.expectEqual(Span{ .start = 2, .end = 9 }, report.match_span);
}

test "Searcher byte fallback supports grouped alternation with anchored branches" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "(^ab|cd)e", .{});
    defer searcher.deinit();

    try testing.expect((try searcher.reportFirstByteMatch("anchored-alt.bin", "abe")) != null);
    try testing.expect((try searcher.reportFirstByteMatch("anchored-alt.bin", "xxcde")) != null);
    try testing.expect((try searcher.reportFirstByteMatch("anchored-alt.bin", "xxabe")) == null);
}

test "Searcher byte fallback supports quantified grouped alternation with anchored branches" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "((^ab)|(cd))+e", .{});
    defer searcher.deinit();

    try testing.expect((try searcher.reportFirstByteMatch("anchored-alt.bin", "abe")) != null);
    try testing.expect((try searcher.reportFirstByteMatch("anchored-alt.bin", "cdcde")) != null);
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

test "Searcher byte fallback supports repetition over anchored grouped patterns" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "(^ab)+c", .{});
    defer searcher.deinit();

    const report = (try searcher.reportFirstByteMatch("anchored-group.bin", "abc")).?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), report.column_number);
    try testing.expectEqual(Span{ .start = 0, .end = 3 }, report.match_span);
    try testing.expect((try searcher.reportFirstByteMatch("anchored-group.bin", "xxababc")) == null);
    try testing.expect((try searcher.reportFirstByteMatch("anchored-group.bin", "ababc")) == null);
}

test "Searcher byte fallback preserves anchor semantics for counted anchored grouped patterns" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "(^ab){2}c", .{});
    defer searcher.deinit();

    try testing.expect((try searcher.reportFirstByteMatch("anchored-group.bin", "ababc")) == null);
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

test "Searcher byte fallback supports empty capture groups inside a sequence" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "a()b", .{});
    defer searcher.deinit();

    const found = (try searcher.firstByteMatch("xx\xffabyy")).?;
    defer found.deinit(testing.allocator);

    try testing.expectEqual(Span{ .start = 3, .end = 5 }, found.span);
    try testing.expectEqual(@as(usize, 1), found.groups.len);
    try testing.expectEqual(@as(?usize, 4), found.groups[0].start);
    try testing.expectEqual(@as(?usize, 4), found.groups[0].end);
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

test "Searcher byte fallback supports bare start anchors" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "^", .{});
    defer searcher.deinit();

    const report = (try searcher.reportFirstByteMatch("anchor.bin", "\xffabc")).?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), report.column_number);
    try testing.expectEqual(Span{ .start = 0, .end = 0 }, report.match_span);
}

test "Searcher byte fallback supports bare end anchors" {
    const testing = std.testing;

    var searcher = try Searcher.init(testing.allocator, "$", .{});
    defer searcher.deinit();

    const report = (try searcher.reportFirstByteMatch("anchor.bin", "abc\xff")).?;
    defer report.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 5), report.column_number);
    try testing.expectEqual(Span{ .start = 4, .end = 4 }, report.match_span);
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
