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

const ByteLiteralCase = struct {
    mode: AnchoredLiteralMode,
    literal: []u8,

    fn deinit(self: ByteLiteralCase, allocator: std.mem.Allocator) void {
        allocator.free(self.literal);
    }
};

const ByteWildcardCase = struct {
    mode: AnchoredLiteralMode,
    prefix: []u8,
    suffix: []u8,

    fn deinit(self: ByteWildcardCase, allocator: std.mem.Allocator) void {
        allocator.free(self.prefix);
        allocator.free(self.suffix);
    }
};

pub const ByteSearchPlan = union(enum) {
    none,
    single: ByteLiteralCase,
    wildcard: ByteWildcardCase,
    alternation: []ByteLiteralCase,

    pub fn deinit(self: ByteSearchPlan, allocator: std.mem.Allocator) void {
        switch (self) {
            .none => {},
            .single => |literal_case| literal_case.deinit(allocator),
            .wildcard => |wildcard_case| wildcard_case.deinit(allocator),
            .alternation => |cases| {
                for (cases) |literal_case| literal_case.deinit(allocator);
                allocator.free(cases);
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

    pub fn reportFirstByteMatch(self: *Searcher, path: []const u8, haystack: []const u8) ?MatchReport {
        const span = switch (self.byte_plan) {
            .none => null,
            .single => |literal_case| findByteLiteralSpan(literal_case, haystack),
            .wildcard => |wildcard_case| findByteWildcardSpan(wildcard_case, haystack),
            .alternation => |cases| findByteAlternationSpan(cases, haystack),
        } orelse return null;

        return buildReport(path, haystack, .{
            .start = span.start,
            .end = span.end,
        });
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

fn extractByteSearchPlan(allocator: std.mem.Allocator, hir: regex.Hir) !ByteSearchPlan {
    return switch (hir.nodes[@intFromEnum(hir.root)]) {
        .alternation => |branches| blk: {
            var cases: std.ArrayList(ByteLiteralCase) = .empty;
            defer cases.deinit(allocator);
            errdefer for (cases.items) |literal_case| literal_case.deinit(allocator);

            for (branches) |branch| {
                const literal_case = (try extractByteLiteralCase(allocator, hir.nodes, branch)) orelse break :blk .none;
                try cases.append(allocator, literal_case);
            }

            if (cases.items.len == 0) break :blk .none;
            if (cases.items.len == 1) break :blk .{ .single = cases.pop().? };
            break :blk .{ .alternation = try cases.toOwnedSlice(allocator) };
        },
        else => if (try extractByteLiteralCase(allocator, hir.nodes, hir.root)) |literal_case|
            .{ .single = literal_case }
        else if (try extractByteWildcardCase(allocator, hir.nodes, hir.root)) |wildcard_case|
            .{ .wildcard = wildcard_case }
        else
            .none,
    };
}

fn extractByteLiteralCase(
    allocator: std.mem.Allocator,
    nodes: []const regex.hir.Node,
    root: regex.hir.NodeId,
) !?ByteLiteralCase {
    return switch (nodes[@intFromEnum(root)]) {
        .literal => |cp| if (cp <= 0x7f)
            .{
                .mode = .contains,
                .literal = try allocator.dupe(u8, &[_]u8{@as(u8, @intCast(cp))}),
            }
        else
            null,
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
            if (start_index == end_index) break :blk null;

            var bytes = std.ArrayList(u8).empty;
            defer bytes.deinit(allocator);

            for (children[start_index..end_index]) |child| {
                switch (nodes[@intFromEnum(child)]) {
                    .literal => |cp| {
                        if (cp > 0x7f) break :blk null;
                        try bytes.append(allocator, @as(u8, @intCast(cp)));
                    },
                    else => break :blk null,
                }
            }
            if (bytes.items.len == 0) break :blk null;

            break :blk .{
                .mode = if (prefix_anchor and suffix_anchor)
                    .full
                else if (prefix_anchor)
                    .start
                else if (suffix_anchor)
                    .end
                else
                    .contains,
                .literal = try bytes.toOwnedSlice(allocator),
            };
        },
        else => null,
    };
}

fn extractByteWildcardCase(
    allocator: std.mem.Allocator,
    nodes: []const regex.hir.Node,
    root: regex.hir.NodeId,
) !?ByteWildcardCase {
    return switch (nodes[@intFromEnum(root)]) {
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
            if (end_index - start_index < 2) break :blk null;

            var dot_index: ?usize = null;
            var dot_count: usize = 0;
            for (children[start_index..end_index], start_index..) |child, absolute_index| {
                switch (nodes[@intFromEnum(child)]) {
                    .dot => {
                        dot_count += 1;
                        dot_index = absolute_index;
                    },
                    .literal => |cp| if (cp > 0x7f) break :blk null,
                    else => break :blk null,
                }
            }
            if (dot_count != 1) break :blk null;

            const split = dot_index.?;
            const prefix = try collectAsciiLiteralRange(allocator, nodes, children[start_index..split]);
            errdefer allocator.free(prefix);
            const suffix = try collectAsciiLiteralRange(allocator, nodes, children[split + 1 .. end_index]);
            errdefer allocator.free(suffix);

            if (prefix.len == 0 and suffix.len == 0) break :blk null;

            break :blk .{
                .mode = if (prefix_anchor and suffix_anchor)
                    .full
                else if (prefix_anchor)
                    .start
                else if (suffix_anchor)
                    .end
                else
                    .contains,
                .prefix = prefix,
                .suffix = suffix,
            };
        },
        else => null,
    };
}

fn collectAsciiLiteralRange(
    allocator: std.mem.Allocator,
    nodes: []const regex.hir.Node,
    children: []const regex.hir.NodeId,
) ![]u8 {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(allocator);

    for (children) |child| {
        try bytes.append(allocator, @as(u8, @intCast(nodes[@intFromEnum(child)].literal)));
    }
    return bytes.toOwnedSlice(allocator);
}

fn findByteAlternationSpan(cases: []const ByteLiteralCase, haystack: []const u8) ?Span {
    var best: ?Span = null;
    for (cases) |literal_case| {
        const span = findByteLiteralSpan(literal_case, haystack) orelse continue;
        if (best == null or span.start < best.?.start) {
            best = span;
        }
    }
    return best;
}

fn findByteLiteralSpan(literal_case: ByteLiteralCase, haystack: []const u8) ?Span {
    return switch (literal_case.mode) {
        .contains => if (std.mem.indexOf(u8, haystack, literal_case.literal)) |start| Span{
            .start = start,
            .end = start + literal_case.literal.len,
        } else null,
        .start => if (std.mem.startsWith(u8, haystack, literal_case.literal)) Span{
            .start = 0,
            .end = literal_case.literal.len,
        } else null,
        .end => if (std.mem.endsWith(u8, haystack, literal_case.literal)) Span{
            .start = haystack.len - literal_case.literal.len,
            .end = haystack.len,
        } else null,
        .full => if (std.mem.eql(u8, haystack, literal_case.literal)) Span{
            .start = 0,
            .end = haystack.len,
        } else null,
    };
}

fn findByteWildcardSpan(wildcard_case: ByteWildcardCase, haystack: []const u8) ?Span {
    return switch (wildcard_case.mode) {
        .contains => findByteWildcardContainsSpan(wildcard_case, haystack),
        .start => findByteWildcardAnchoredStartSpan(wildcard_case, haystack),
        .end => findByteWildcardAnchoredEndSpan(wildcard_case, haystack),
        .full => findByteWildcardAnchoredFullSpan(wildcard_case, haystack),
    };
}

fn findByteWildcardContainsSpan(wildcard_case: ByteWildcardCase, haystack: []const u8) ?Span {
    var start_index: usize = 0;
    while (start_index <= haystack.len) {
        const prefix_index = if (wildcard_case.prefix.len == 0)
            start_index
        else
            (std.mem.indexOfPos(u8, haystack, start_index, wildcard_case.prefix) orelse return null);

        const wildcard_index = prefix_index + wildcard_case.prefix.len;
        if (wildcard_index >= haystack.len) return null;
        if (haystack[wildcard_index] == '\n') {
            start_index = prefix_index + 1;
            continue;
        }

        const suffix_start = wildcard_index + 1;
        if (suffix_start + wildcard_case.suffix.len > haystack.len) return null;
        if (std.mem.eql(u8, haystack[suffix_start .. suffix_start + wildcard_case.suffix.len], wildcard_case.suffix)) {
            return .{
                .start = prefix_index,
                .end = suffix_start + wildcard_case.suffix.len,
            };
        }

        start_index = prefix_index + 1;
    }
    return null;
}

fn findByteWildcardAnchoredStartSpan(wildcard_case: ByteWildcardCase, haystack: []const u8) ?Span {
    if (!std.mem.startsWith(u8, haystack, wildcard_case.prefix)) return null;
    const wildcard_index = wildcard_case.prefix.len;
    if (wildcard_index >= haystack.len or haystack[wildcard_index] == '\n') return null;
    const suffix_start = wildcard_index + 1;
    if (suffix_start + wildcard_case.suffix.len > haystack.len) return null;
    if (!std.mem.eql(u8, haystack[suffix_start .. suffix_start + wildcard_case.suffix.len], wildcard_case.suffix)) return null;
    return .{ .start = 0, .end = suffix_start + wildcard_case.suffix.len };
}

fn findByteWildcardAnchoredEndSpan(wildcard_case: ByteWildcardCase, haystack: []const u8) ?Span {
    const total_len = wildcard_case.prefix.len + 1 + wildcard_case.suffix.len;
    if (haystack.len < total_len) return null;
    const start = haystack.len - total_len;
    if (!std.mem.eql(u8, haystack[start .. start + wildcard_case.prefix.len], wildcard_case.prefix)) return null;
    const wildcard_index = start + wildcard_case.prefix.len;
    if (haystack[wildcard_index] == '\n') return null;
    if (!std.mem.eql(u8, haystack[wildcard_index + 1 ..], wildcard_case.suffix)) return null;
    return .{ .start = start, .end = haystack.len };
}

fn findByteWildcardAnchoredFullSpan(wildcard_case: ByteWildcardCase, haystack: []const u8) ?Span {
    const total_len = wildcard_case.prefix.len + 1 + wildcard_case.suffix.len;
    if (haystack.len != total_len) return null;
    if (!std.mem.startsWith(u8, haystack, wildcard_case.prefix)) return null;
    const wildcard_index = wildcard_case.prefix.len;
    if (haystack[wildcard_index] == '\n') return null;
    if (!std.mem.eql(u8, haystack[wildcard_index + 1 ..], wildcard_case.suffix)) return null;
    return .{ .start = 0, .end = haystack.len };
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
