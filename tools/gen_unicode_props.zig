const std = @import("std");

const Range = struct {
    start: u32,
    end: u32,
};

const CategoryKind = enum {
    letter,
    number,
    lowercase,
    uppercase,
    mark,
    punctuation,
    symbol,
    separator,
};

const Config = struct {
    zg_root: []const u8,
    unicode_data: []const u8,
    prop_list: []const u8,
    derived_core_properties: []const u8,
    output: []const u8,
};

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const config = try parseArgs(arena);

    var letter_ranges: std.ArrayList(Range) = .empty;
    defer letter_ranges.deinit(arena);

    var number_ranges: std.ArrayList(Range) = .empty;
    defer number_ranges.deinit(arena);

    var whitespace_ranges: std.ArrayList(Range) = .empty;
    defer whitespace_ranges.deinit(arena);

    var alphabetic_ranges: std.ArrayList(Range) = .empty;
    defer alphabetic_ranges.deinit(arena);

    var lowercase_ranges: std.ArrayList(Range) = .empty;
    defer lowercase_ranges.deinit(arena);

    var uppercase_ranges: std.ArrayList(Range) = .empty;
    defer uppercase_ranges.deinit(arena);

    var mark_ranges: std.ArrayList(Range) = .empty;
    defer mark_ranges.deinit(arena);

    var punctuation_ranges: std.ArrayList(Range) = .empty;
    defer punctuation_ranges.deinit(arena);

    var symbol_ranges: std.ArrayList(Range) = .empty;
    defer symbol_ranges.deinit(arena);

    var separator_ranges: std.ArrayList(Range) = .empty;
    defer separator_ranges.deinit(arena);

    try loadUnicodeData(
        arena,
        config.unicode_data,
        &letter_ranges,
        &number_ranges,
        &lowercase_ranges,
        &uppercase_ranges,
        &mark_ranges,
        &punctuation_ranges,
        &symbol_ranges,
        &separator_ranges,
    );
    try loadWhitespaceData(arena, config.prop_list, &whitespace_ranges);
    try loadNamedPropertyData(arena, config.derived_core_properties, "Alphabetic", &alphabetic_ranges);

    try writeOutput(
        config,
        letter_ranges.items,
        number_ranges.items,
        whitespace_ranges.items,
        alphabetic_ranges.items,
        lowercase_ranges.items,
        uppercase_ranges.items,
        mark_ranges.items,
        punctuation_ranges.items,
        symbol_ranges.items,
        separator_ranges.items,
    );
}

fn parseArgs(allocator: std.mem.Allocator) !Config {
    const args = try std.process.argsAlloc(allocator);
    if (args.len == 1 or hasHelpFlag(args[1..])) {
        try writeUsage();
        std.process.exit(0);
    }

    const default_zg_root = try std.fs.path.join(allocator, &.{ "..", "zig-libs", "zg" });
    const default_unicode_data = try std.fs.path.join(allocator, &.{ default_zg_root, "data", "unicode", "UnicodeData.txt" });
    const default_prop_list = try std.fs.path.join(allocator, &.{ default_zg_root, "data", "unicode", "PropList.txt" });
    const default_derived_core_properties = try std.fs.path.join(allocator, &.{ default_zg_root, "data", "unicode", "DerivedCoreProperties.txt" });

    var config = Config{
        .zg_root = default_zg_root,
        .unicode_data = default_unicode_data,
        .prop_list = default_prop_list,
        .derived_core_properties = default_derived_core_properties,
        .output = "",
    };

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--zg-root")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            config.zg_root = args[i];
            config.unicode_data = try std.fs.path.join(allocator, &.{ config.zg_root, "data", "unicode", "UnicodeData.txt" });
            config.prop_list = try std.fs.path.join(allocator, &.{ config.zg_root, "data", "unicode", "PropList.txt" });
            config.derived_core_properties = try std.fs.path.join(allocator, &.{ config.zg_root, "data", "unicode", "DerivedCoreProperties.txt" });
        } else if (std.mem.eql(u8, arg, "--unicode-data")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            config.unicode_data = args[i];
        } else if (std.mem.eql(u8, arg, "--prop-list")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            config.prop_list = args[i];
        } else if (std.mem.eql(u8, arg, "--derived-core-properties")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            config.derived_core_properties = args[i];
        } else if (std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            config.output = args[i];
        } else {
            return error.InvalidArgument;
        }
    }

    if (config.output.len == 0) return error.MissingArgument;

    try ensureFileExists(config.unicode_data);
    try ensureFileExists(config.prop_list);
    try ensureFileExists(config.derived_core_properties);

    return config;
}

fn hasHelpFlag(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return true;
    }
    return false;
}

fn writeUsage() !void {
    std.debug.print(
        \\usage: gen_unicode_props.zig [--zg-root PATH] [--unicode-data PATH] [--prop-list PATH] [--derived-core-properties PATH] --output PATH
        \\
        \\Default data source:
        \\  ../zig-libs/zg/data/unicode relative to the zigrep repo root
        \\
        \\Examples:
        \\  zig run tools/gen_unicode_props.zig -- --zg-root ../zig-libs/zg --output src/regex/unicode_props_generated.zig
        \\  zig run tools/gen_unicode_props.zig -- --unicode-data /path/to/UnicodeData.txt --prop-list /path/to/PropList.txt --derived-core-properties /path/to/DerivedCoreProperties.txt --output src/regex/unicode_props_generated.zig
        \\
    , .{});
}

fn ensureFileExists(path: []const u8) !void {
    std.fs.cwd().access(path, .{}) catch return error.FileNotFound;
}

fn loadUnicodeData(
    allocator: std.mem.Allocator,
    path: []const u8,
    letter_ranges: *std.ArrayList(Range),
    number_ranges: *std.ArrayList(Range),
    lowercase_ranges: *std.ArrayList(Range),
    uppercase_ranges: *std.ArrayList(Range),
    mark_ranges: *std.ArrayList(Range),
    punctuation_ranges: *std.ArrayList(Range),
    symbol_ranges: *std.ArrayList(Range),
    separator_ranges: *std.ArrayList(Range),
) !void {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024 * 1024);

    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    var range_start: ?u32 = null;
    var range_kind: ?CategoryKind = null;

    while (lines.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, "\r");
        if (line.len == 0) continue;

        var fields = std.mem.splitScalar(u8, line, ';');
        const code_field = fields.next() orelse continue;
        const name_field = fields.next() orelse continue;
        const category_field = fields.next() orelse continue;

        const cp = try std.fmt.parseInt(u32, code_field, 16);
        if (std.mem.endsWith(u8, name_field, ", First>")) {
            range_start = cp;
            range_kind = categoryKind(category_field);
            continue;
        }
        if (std.mem.endsWith(u8, name_field, ", Last>")) {
            if (range_start) |start| {
                if (range_kind) |kind| {
                    try appendCategoryRange(
                        allocator,
                        kind,
                        start,
                        cp,
                        letter_ranges,
                        number_ranges,
                        lowercase_ranges,
                        uppercase_ranges,
                        mark_ranges,
                        punctuation_ranges,
                        symbol_ranges,
                        separator_ranges,
                    );
                }
            }
            range_start = null;
            range_kind = null;
            continue;
        }

        if (categoryKind(category_field)) |kind| {
            try appendCategoryRange(
                allocator,
                kind,
                cp,
                cp,
                letter_ranges,
                number_ranges,
                lowercase_ranges,
                uppercase_ranges,
                mark_ranges,
                punctuation_ranges,
                symbol_ranges,
                separator_ranges,
            );
        }
    }
}

fn categoryKind(category: []const u8) ?CategoryKind {
    if (category.len == 0) return null;
    if (std.mem.eql(u8, category, "Ll")) return .lowercase;
    if (std.mem.eql(u8, category, "Lu")) return .uppercase;
    return switch (category[0]) {
        'L' => .letter,
        'M' => .mark,
        'N' => .number,
        'P' => .punctuation,
        'S' => .symbol,
        'Z' => .separator,
        else => null,
    };
}

fn appendCategoryRange(
    allocator: std.mem.Allocator,
    kind: CategoryKind,
    start: u32,
    end: u32,
    letter_ranges: *std.ArrayList(Range),
    number_ranges: *std.ArrayList(Range),
    lowercase_ranges: *std.ArrayList(Range),
    uppercase_ranges: *std.ArrayList(Range),
    mark_ranges: *std.ArrayList(Range),
    punctuation_ranges: *std.ArrayList(Range),
    symbol_ranges: *std.ArrayList(Range),
    separator_ranges: *std.ArrayList(Range),
) !void {
    switch (kind) {
        .letter => try appendMergedRange(allocator, letter_ranges, .{ .start = start, .end = end }),
        .mark => try appendMergedRange(allocator, mark_ranges, .{ .start = start, .end = end }),
        .number => try appendMergedRange(allocator, number_ranges, .{ .start = start, .end = end }),
        .punctuation => try appendMergedRange(allocator, punctuation_ranges, .{ .start = start, .end = end }),
        .separator => try appendMergedRange(allocator, separator_ranges, .{ .start = start, .end = end }),
        .lowercase => {
            try appendMergedRange(allocator, letter_ranges, .{ .start = start, .end = end });
            try appendMergedRange(allocator, lowercase_ranges, .{ .start = start, .end = end });
        },
        .symbol => try appendMergedRange(allocator, symbol_ranges, .{ .start = start, .end = end }),
        .uppercase => {
            try appendMergedRange(allocator, letter_ranges, .{ .start = start, .end = end });
            try appendMergedRange(allocator, uppercase_ranges, .{ .start = start, .end = end });
        },
    }
}

fn loadWhitespaceData(
    allocator: std.mem.Allocator,
    path: []const u8,
    whitespace_ranges: *std.ArrayList(Range),
) !void {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);

    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line_trimmed = std.mem.trimRight(u8, line_raw, "\r");
        const line = if (std.mem.indexOfScalar(u8, line_trimmed, '#')) |index|
            std.mem.trim(u8, line_trimmed[0..index], " \t")
        else
            std.mem.trim(u8, line_trimmed, " \t");

        if (line.len == 0) continue;

        const sep = std.mem.indexOfScalar(u8, line, ';') orelse continue;
        const lhs = std.mem.trim(u8, line[0..sep], " \t");
        const rhs = std.mem.trim(u8, line[sep + 1 ..], " \t");
        if (!std.mem.eql(u8, rhs, "White_Space")) continue;

        const range = if (std.mem.indexOf(u8, lhs, "..")) |dots|
            Range{
                .start = try std.fmt.parseInt(u32, lhs[0..dots], 16),
                .end = try std.fmt.parseInt(u32, lhs[dots + 2 ..], 16),
            }
        else
            blk: {
                const cp = try std.fmt.parseInt(u32, lhs, 16);
                break :blk Range{ .start = cp, .end = cp };
            };

        try appendMergedRange(allocator, whitespace_ranges, range);
    }
}

fn loadNamedPropertyData(
    allocator: std.mem.Allocator,
    path: []const u8,
    property_name: []const u8,
    ranges: *std.ArrayList(Range),
) !void {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 32 * 1024 * 1024);

    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line_trimmed = std.mem.trimRight(u8, line_raw, "\r");
        const line = if (std.mem.indexOfScalar(u8, line_trimmed, '#')) |index|
            std.mem.trim(u8, line_trimmed[0..index], " \t")
        else
            std.mem.trim(u8, line_trimmed, " \t");

        if (line.len == 0) continue;

        const sep = std.mem.indexOfScalar(u8, line, ';') orelse continue;
        const lhs = std.mem.trim(u8, line[0..sep], " \t");
        const rhs = std.mem.trim(u8, line[sep + 1 ..], " \t");
        if (!std.mem.eql(u8, rhs, property_name)) continue;

        const range = if (std.mem.indexOf(u8, lhs, "..")) |dots|
            Range{
                .start = try std.fmt.parseInt(u32, lhs[0..dots], 16),
                .end = try std.fmt.parseInt(u32, lhs[dots + 2 ..], 16),
            }
        else
            blk: {
                const cp = try std.fmt.parseInt(u32, lhs, 16);
                break :blk Range{ .start = cp, .end = cp };
            };

        try appendMergedRange(allocator, ranges, range);
    }
}

fn appendMergedRange(
    allocator: std.mem.Allocator,
    ranges: *std.ArrayList(Range),
    range: Range,
) !void {
    if (ranges.items.len == 0) {
        try ranges.append(allocator, range);
        return;
    }

    const last = &ranges.items[ranges.items.len - 1];
    if (range.start <= last.end + 1) {
        if (range.end > last.end) last.end = range.end;
        return;
    }

    try ranges.append(allocator, range);
}

fn writeOutput(
    config: Config,
    letter_ranges: []const Range,
    number_ranges: []const Range,
    whitespace_ranges: []const Range,
    alphabetic_ranges: []const Range,
    lowercase_ranges: []const Range,
    uppercase_ranges: []const Range,
    mark_ranges: []const Range,
    punctuation_ranges: []const Range,
    symbol_ranges: []const Range,
    separator_ranges: []const Range,
) !void {
    const output_path = config.output;
    if (std.fs.path.dirname(output_path)) |dir_path| {
        try std.fs.cwd().makePath(dir_path);
    }

    var file = try std.fs.cwd().createFile(output_path, .{ .truncate = true });
    defer file.close();

    var buf: [4096]u8 = undefined;
    var writer = file.writer(&buf);

    try writer.interface.print("// Generated by tools/gen_unicode_props.zig\n", .{});
    try writer.interface.print("// Source inputs:\n", .{});
    try writer.interface.print("// - {s}\n", .{config.unicode_data});
    try writer.interface.print("// - {s}\n", .{config.prop_list});
    try writer.interface.print("// - {s}\n", .{config.derived_core_properties});
    try writer.interface.print("// Data source repository:\n", .{});
    try writer.interface.print("// - {s}\n", .{config.zg_root});
    try writer.interface.print("// - https://codeberg.org/atman/zg\n\n", .{});
    try writer.interface.print("pub const Range = struct {{\n", .{});
    try writer.interface.print("    start: u32,\n", .{});
    try writer.interface.print("    end: u32,\n", .{});
    try writer.interface.print("}};\n\n", .{});

    try writeRangeList(&writer.interface, "letter_ranges", letter_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "number_ranges", number_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "whitespace_ranges", whitespace_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "alphabetic_ranges", alphabetic_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "lowercase_ranges", lowercase_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "uppercase_ranges", uppercase_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "mark_ranges", mark_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "punctuation_ranges", punctuation_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "symbol_ranges", symbol_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "separator_ranges", separator_ranges);
    try writer.interface.flush();
}

fn writeRangeList(writer: anytype, name: []const u8, ranges: []const Range) !void {
    try writer.print("pub const {s} = [_]Range{{\n", .{name});
    for (ranges) |range| {
        try writer.print("    .{{ .start = 0x{X}, .end = 0x{X} }},\n", .{ range.start, range.end });
    }
    try writer.print("}};\n", .{});
}
