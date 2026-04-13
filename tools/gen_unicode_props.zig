const std = @import("std");

const Range = struct {
    start: u32,
    end: u32,
};

const ScriptAlias = struct {
    long_name: []const u8,
    short_name: []const u8,
};

const CaseFoldMapping = struct {
    from: u32,
    to: u32,
};

const ScriptEntry = struct {
    long_name: []const u8,
    short_name: []const u8,
    ranges: std.ArrayList(Range),
};

const CategoryKind = enum {
    letter,
    number,
    lowercase,
    uppercase,
    titlecase_letter,
    modifier_letter,
    other_letter,
    mark,
    nonspacing_mark,
    spacing_mark,
    enclosing_mark,
    decimal_number,
    letter_number,
    other_number,
    punctuation,
    connector_punctuation,
    dash_punctuation,
    open_punctuation,
    close_punctuation,
    initial_punctuation,
    final_punctuation,
    other_punctuation,
    symbol,
    math_symbol,
    currency_symbol,
    modifier_symbol,
    other_symbol,
    separator,
    space_separator,
    line_separator,
    paragraph_separator,
    other,
    control,
    format,
    surrogate,
    private_use,
    unassigned,
};

const Config = struct {
    zg_root: []const u8,
    unicode_data: []const u8,
    prop_list: []const u8,
    derived_core_properties: []const u8,
    derived_general_category: []const u8,
    scripts: []const u8,
    property_value_aliases: []const u8,
    emoji_data: []const u8,
    case_folding: []const u8,
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

    var cased_ranges: std.ArrayList(Range) = .empty;
    defer cased_ranges.deinit(arena);

    var case_ignorable_ranges: std.ArrayList(Range) = .empty;
    defer case_ignorable_ranges.deinit(arena);

    var id_start_ranges: std.ArrayList(Range) = .empty;
    defer id_start_ranges.deinit(arena);

    var id_continue_ranges: std.ArrayList(Range) = .empty;
    defer id_continue_ranges.deinit(arena);

    var xid_start_ranges: std.ArrayList(Range) = .empty;
    defer xid_start_ranges.deinit(arena);

    var xid_continue_ranges: std.ArrayList(Range) = .empty;
    defer xid_continue_ranges.deinit(arena);

    var default_ignorable_code_point_ranges: std.ArrayList(Range) = .empty;
    defer default_ignorable_code_point_ranges.deinit(arena);

    var emoji_ranges: std.ArrayList(Range) = .empty;
    defer emoji_ranges.deinit(arena);

    var simple_case_fold_mappings: std.ArrayList(CaseFoldMapping) = .empty;
    defer simple_case_fold_mappings.deinit(arena);

    var latin_script_ranges: std.ArrayList(Range) = .empty;
    defer latin_script_ranges.deinit(arena);

    var greek_script_ranges: std.ArrayList(Range) = .empty;
    defer greek_script_ranges.deinit(arena);

    var cyrillic_script_ranges: std.ArrayList(Range) = .empty;
    defer cyrillic_script_ranges.deinit(arena);

    var common_script_ranges: std.ArrayList(Range) = .empty;
    defer common_script_ranges.deinit(arena);

    var inherited_script_ranges: std.ArrayList(Range) = .empty;
    defer inherited_script_ranges.deinit(arena);

    var unknown_script_ranges: std.ArrayList(Range) = .empty;
    defer unknown_script_ranges.deinit(arena);

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

    var other_ranges: std.ArrayList(Range) = .empty;
    defer other_ranges.deinit(arena);

    var titlecase_letter_ranges: std.ArrayList(Range) = .empty;
    defer titlecase_letter_ranges.deinit(arena);

    var modifier_letter_ranges: std.ArrayList(Range) = .empty;
    defer modifier_letter_ranges.deinit(arena);

    var other_letter_ranges: std.ArrayList(Range) = .empty;
    defer other_letter_ranges.deinit(arena);

    var nonspacing_mark_ranges: std.ArrayList(Range) = .empty;
    defer nonspacing_mark_ranges.deinit(arena);

    var spacing_mark_ranges: std.ArrayList(Range) = .empty;
    defer spacing_mark_ranges.deinit(arena);

    var enclosing_mark_ranges: std.ArrayList(Range) = .empty;
    defer enclosing_mark_ranges.deinit(arena);

    var decimal_number_ranges: std.ArrayList(Range) = .empty;
    defer decimal_number_ranges.deinit(arena);

    var letter_number_ranges: std.ArrayList(Range) = .empty;
    defer letter_number_ranges.deinit(arena);

    var other_number_ranges: std.ArrayList(Range) = .empty;
    defer other_number_ranges.deinit(arena);

    var connector_punctuation_ranges: std.ArrayList(Range) = .empty;
    defer connector_punctuation_ranges.deinit(arena);

    var dash_punctuation_ranges: std.ArrayList(Range) = .empty;
    defer dash_punctuation_ranges.deinit(arena);

    var open_punctuation_ranges: std.ArrayList(Range) = .empty;
    defer open_punctuation_ranges.deinit(arena);

    var close_punctuation_ranges: std.ArrayList(Range) = .empty;
    defer close_punctuation_ranges.deinit(arena);

    var initial_punctuation_ranges: std.ArrayList(Range) = .empty;
    defer initial_punctuation_ranges.deinit(arena);

    var final_punctuation_ranges: std.ArrayList(Range) = .empty;
    defer final_punctuation_ranges.deinit(arena);

    var other_punctuation_ranges: std.ArrayList(Range) = .empty;
    defer other_punctuation_ranges.deinit(arena);

    var math_symbol_ranges: std.ArrayList(Range) = .empty;
    defer math_symbol_ranges.deinit(arena);

    var currency_symbol_ranges: std.ArrayList(Range) = .empty;
    defer currency_symbol_ranges.deinit(arena);

    var modifier_symbol_ranges: std.ArrayList(Range) = .empty;
    defer modifier_symbol_ranges.deinit(arena);

    var other_symbol_ranges: std.ArrayList(Range) = .empty;
    defer other_symbol_ranges.deinit(arena);

    var space_separator_ranges: std.ArrayList(Range) = .empty;
    defer space_separator_ranges.deinit(arena);

    var line_separator_ranges: std.ArrayList(Range) = .empty;
    defer line_separator_ranges.deinit(arena);

    var paragraph_separator_ranges: std.ArrayList(Range) = .empty;
    defer paragraph_separator_ranges.deinit(arena);

    var control_ranges: std.ArrayList(Range) = .empty;
    defer control_ranges.deinit(arena);

    var format_ranges: std.ArrayList(Range) = .empty;
    defer format_ranges.deinit(arena);

    var surrogate_ranges: std.ArrayList(Range) = .empty;
    defer surrogate_ranges.deinit(arena);

    var private_use_ranges: std.ArrayList(Range) = .empty;
    defer private_use_ranges.deinit(arena);

    var unassigned_ranges: std.ArrayList(Range) = .empty;
    defer unassigned_ranges.deinit(arena);

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
    try loadNamedPropertyData(arena, config.derived_core_properties, "Cased", &cased_ranges);
    try loadNamedPropertyData(arena, config.derived_core_properties, "Case_Ignorable", &case_ignorable_ranges);
    try loadNamedPropertyData(arena, config.derived_core_properties, "ID_Start", &id_start_ranges);
    try loadNamedPropertyData(arena, config.derived_core_properties, "ID_Continue", &id_continue_ranges);
    try loadNamedPropertyData(arena, config.derived_core_properties, "XID_Start", &xid_start_ranges);
    try loadNamedPropertyData(arena, config.derived_core_properties, "XID_Continue", &xid_continue_ranges);
    try loadNamedPropertyData(arena, config.derived_core_properties, "Default_Ignorable_Code_Point", &default_ignorable_code_point_ranges);
    try loadNamedPropertyData(arena, config.emoji_data, "Emoji", &emoji_ranges);
    try loadCaseFoldingData(arena, config.case_folding, &simple_case_fold_mappings);
    try loadNamedScriptData(arena, config.scripts, "Latin", &latin_script_ranges);
    try loadNamedScriptData(arena, config.scripts, "Greek", &greek_script_ranges);
    try loadNamedScriptData(arena, config.scripts, "Cyrillic", &cyrillic_script_ranges);
    try loadNamedScriptData(arena, config.scripts, "Common", &common_script_ranges);
    try loadNamedScriptData(arena, config.scripts, "Inherited", &inherited_script_ranges);
    try loadNamedScriptData(arena, config.scripts, "Unknown", &unknown_script_ranges);
    var script_aliases = try loadScriptAliases(arena, config.property_value_aliases);
    defer script_aliases.deinit(arena);

    var script_entries = try loadScripts(arena, config.scripts, script_aliases.items);
    defer {
        for (script_entries.items) |*entry| entry.ranges.deinit(arena);
        script_entries.deinit(arena);
    }
    try loadGeneralCategoryData(
        arena,
        config.derived_general_category,
        &titlecase_letter_ranges,
        &modifier_letter_ranges,
        &other_letter_ranges,
        &nonspacing_mark_ranges,
        &spacing_mark_ranges,
        &enclosing_mark_ranges,
        &decimal_number_ranges,
        &letter_number_ranges,
        &other_number_ranges,
        &connector_punctuation_ranges,
        &dash_punctuation_ranges,
        &open_punctuation_ranges,
        &close_punctuation_ranges,
        &initial_punctuation_ranges,
        &final_punctuation_ranges,
        &other_punctuation_ranges,
        &math_symbol_ranges,
        &currency_symbol_ranges,
        &modifier_symbol_ranges,
        &other_symbol_ranges,
        &space_separator_ranges,
        &line_separator_ranges,
        &paragraph_separator_ranges,
        &control_ranges,
        &format_ranges,
        &surrogate_ranges,
        &private_use_ranges,
        &unassigned_ranges,
        &other_ranges,
    );

    try writeOutput(
        config,
        letter_ranges.items,
        number_ranges.items,
        whitespace_ranges.items,
        alphabetic_ranges.items,
        cased_ranges.items,
        case_ignorable_ranges.items,
        id_start_ranges.items,
        id_continue_ranges.items,
        xid_start_ranges.items,
        xid_continue_ranges.items,
        default_ignorable_code_point_ranges.items,
        emoji_ranges.items,
        simple_case_fold_mappings.items,
        latin_script_ranges.items,
        greek_script_ranges.items,
        cyrillic_script_ranges.items,
        common_script_ranges.items,
        inherited_script_ranges.items,
        unknown_script_ranges.items,
        script_entries.items,
        lowercase_ranges.items,
        uppercase_ranges.items,
        mark_ranges.items,
        punctuation_ranges.items,
        symbol_ranges.items,
        separator_ranges.items,
        other_ranges.items,
        titlecase_letter_ranges.items,
        modifier_letter_ranges.items,
        other_letter_ranges.items,
        nonspacing_mark_ranges.items,
        spacing_mark_ranges.items,
        enclosing_mark_ranges.items,
        decimal_number_ranges.items,
        letter_number_ranges.items,
        other_number_ranges.items,
        connector_punctuation_ranges.items,
        dash_punctuation_ranges.items,
        open_punctuation_ranges.items,
        close_punctuation_ranges.items,
        initial_punctuation_ranges.items,
        final_punctuation_ranges.items,
        other_punctuation_ranges.items,
        math_symbol_ranges.items,
        currency_symbol_ranges.items,
        modifier_symbol_ranges.items,
        other_symbol_ranges.items,
        space_separator_ranges.items,
        line_separator_ranges.items,
        paragraph_separator_ranges.items,
        control_ranges.items,
        format_ranges.items,
        surrogate_ranges.items,
        private_use_ranges.items,
        unassigned_ranges.items,
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
    const default_derived_general_category = try std.fs.path.join(allocator, &.{ default_zg_root, "data", "unicode", "extracted", "DerivedGeneralCategory.txt" });
    const default_scripts = try std.fs.path.join(allocator, &.{ default_zg_root, "data", "unicode", "Scripts.txt" });
    const default_property_value_aliases = try std.fs.path.join(allocator, &.{ default_zg_root, "data", "unicode", "PropertyValueAliases.txt" });
    const default_emoji_data = try std.fs.path.join(allocator, &.{ default_zg_root, "data", "unicode", "emoji", "emoji-data.txt" });
    const default_case_folding = try std.fs.path.join(allocator, &.{ default_zg_root, "data", "unicode", "CaseFolding.txt" });

    var config = Config{
        .zg_root = default_zg_root,
        .unicode_data = default_unicode_data,
        .prop_list = default_prop_list,
        .derived_core_properties = default_derived_core_properties,
        .derived_general_category = default_derived_general_category,
        .scripts = default_scripts,
        .property_value_aliases = default_property_value_aliases,
        .emoji_data = default_emoji_data,
        .case_folding = default_case_folding,
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
            config.derived_general_category = try std.fs.path.join(allocator, &.{ config.zg_root, "data", "unicode", "extracted", "DerivedGeneralCategory.txt" });
            config.scripts = try std.fs.path.join(allocator, &.{ config.zg_root, "data", "unicode", "Scripts.txt" });
            config.property_value_aliases = try std.fs.path.join(allocator, &.{ config.zg_root, "data", "unicode", "PropertyValueAliases.txt" });
            config.emoji_data = try std.fs.path.join(allocator, &.{ config.zg_root, "data", "unicode", "emoji", "emoji-data.txt" });
            config.case_folding = try std.fs.path.join(allocator, &.{ config.zg_root, "data", "unicode", "CaseFolding.txt" });
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
        } else if (std.mem.eql(u8, arg, "--derived-general-category")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            config.derived_general_category = args[i];
        } else if (std.mem.eql(u8, arg, "--scripts")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            config.scripts = args[i];
        } else if (std.mem.eql(u8, arg, "--property-value-aliases")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            config.property_value_aliases = args[i];
        } else if (std.mem.eql(u8, arg, "--emoji-data")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            config.emoji_data = args[i];
        } else if (std.mem.eql(u8, arg, "--case-folding")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            config.case_folding = args[i];
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
    try ensureFileExists(config.derived_general_category);
    try ensureFileExists(config.scripts);
    try ensureFileExists(config.property_value_aliases);
    try ensureFileExists(config.emoji_data);
    try ensureFileExists(config.case_folding);

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
        \\                             [--derived-general-category PATH] [--scripts PATH] [--property-value-aliases PATH] [--emoji-data PATH] [--case-folding PATH]
        \\
        \\Default data source:
        \\  ../zig-libs/zg/data/unicode relative to the zigrep repo root
        \\
        \\Examples:
        \\  zig run tools/gen_unicode_props.zig -- --zg-root ../zig-libs/zg --output src/regex/unicode_props_generated.zig
        \\  zig run tools/gen_unicode_props.zig -- --unicode-data /path/to/UnicodeData.txt --prop-list /path/to/PropList.txt --derived-core-properties /path/to/DerivedCoreProperties.txt --derived-general-category /path/to/DerivedGeneralCategory.txt --scripts /path/to/Scripts.txt --property-value-aliases /path/to/PropertyValueAliases.txt --emoji-data /path/to/emoji-data.txt --case-folding /path/to/CaseFolding.txt --output src/regex/unicode_props_generated.zig
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
        else => unreachable,
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

fn loadCaseFoldingData(
    allocator: std.mem.Allocator,
    path: []const u8,
    mappings: *std.ArrayList(CaseFoldMapping),
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

        var fields = std.mem.splitScalar(u8, line, ';');
        const from_field = std.mem.trim(u8, fields.next() orelse continue, " \t");
        const status_field = std.mem.trim(u8, fields.next() orelse continue, " \t");
        const to_field = std.mem.trim(u8, fields.next() orelse continue, " \t");

        if (!(std.mem.eql(u8, status_field, "C") or std.mem.eql(u8, status_field, "S"))) continue;
        if (std.mem.indexOfScalar(u8, to_field, ' ') != null) continue;

        try mappings.append(allocator, .{
            .from = try std.fmt.parseInt(u32, from_field, 16),
            .to = try std.fmt.parseInt(u32, to_field, 16),
        });
    }
}

fn loadGeneralCategoryData(
    allocator: std.mem.Allocator,
    path: []const u8,
    titlecase_letter_ranges: *std.ArrayList(Range),
    modifier_letter_ranges: *std.ArrayList(Range),
    other_letter_ranges: *std.ArrayList(Range),
    nonspacing_mark_ranges: *std.ArrayList(Range),
    spacing_mark_ranges: *std.ArrayList(Range),
    enclosing_mark_ranges: *std.ArrayList(Range),
    decimal_number_ranges: *std.ArrayList(Range),
    letter_number_ranges: *std.ArrayList(Range),
    other_number_ranges: *std.ArrayList(Range),
    connector_punctuation_ranges: *std.ArrayList(Range),
    dash_punctuation_ranges: *std.ArrayList(Range),
    open_punctuation_ranges: *std.ArrayList(Range),
    close_punctuation_ranges: *std.ArrayList(Range),
    initial_punctuation_ranges: *std.ArrayList(Range),
    final_punctuation_ranges: *std.ArrayList(Range),
    other_punctuation_ranges: *std.ArrayList(Range),
    math_symbol_ranges: *std.ArrayList(Range),
    currency_symbol_ranges: *std.ArrayList(Range),
    modifier_symbol_ranges: *std.ArrayList(Range),
    other_symbol_ranges: *std.ArrayList(Range),
    space_separator_ranges: *std.ArrayList(Range),
    line_separator_ranges: *std.ArrayList(Range),
    paragraph_separator_ranges: *std.ArrayList(Range),
    control_ranges: *std.ArrayList(Range),
    format_ranges: *std.ArrayList(Range),
    surrogate_ranges: *std.ArrayList(Range),
    private_use_ranges: *std.ArrayList(Range),
    unassigned_ranges: *std.ArrayList(Range),
    other_ranges: *std.ArrayList(Range),
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
        const kind = generalCategoryKind(rhs) orelse continue;

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

        switch (kind) {
            .titlecase_letter => try appendMergedRange(allocator, titlecase_letter_ranges, range),
            .modifier_letter => try appendMergedRange(allocator, modifier_letter_ranges, range),
            .other_letter => try appendMergedRange(allocator, other_letter_ranges, range),
            .nonspacing_mark => try appendMergedRange(allocator, nonspacing_mark_ranges, range),
            .spacing_mark => try appendMergedRange(allocator, spacing_mark_ranges, range),
            .enclosing_mark => try appendMergedRange(allocator, enclosing_mark_ranges, range),
            .decimal_number => try appendMergedRange(allocator, decimal_number_ranges, range),
            .letter_number => try appendMergedRange(allocator, letter_number_ranges, range),
            .other_number => try appendMergedRange(allocator, other_number_ranges, range),
            .connector_punctuation => try appendMergedRange(allocator, connector_punctuation_ranges, range),
            .dash_punctuation => try appendMergedRange(allocator, dash_punctuation_ranges, range),
            .open_punctuation => try appendMergedRange(allocator, open_punctuation_ranges, range),
            .close_punctuation => try appendMergedRange(allocator, close_punctuation_ranges, range),
            .initial_punctuation => try appendMergedRange(allocator, initial_punctuation_ranges, range),
            .final_punctuation => try appendMergedRange(allocator, final_punctuation_ranges, range),
            .other_punctuation => try appendMergedRange(allocator, other_punctuation_ranges, range),
            .math_symbol => try appendMergedRange(allocator, math_symbol_ranges, range),
            .currency_symbol => try appendMergedRange(allocator, currency_symbol_ranges, range),
            .modifier_symbol => try appendMergedRange(allocator, modifier_symbol_ranges, range),
            .other_symbol => try appendMergedRange(allocator, other_symbol_ranges, range),
            .space_separator => try appendMergedRange(allocator, space_separator_ranges, range),
            .line_separator => try appendMergedRange(allocator, line_separator_ranges, range),
            .paragraph_separator => try appendMergedRange(allocator, paragraph_separator_ranges, range),
            .control => {
                try appendMergedRange(allocator, control_ranges, range);
                try appendMergedRange(allocator, other_ranges, range);
            },
            .format => {
                try appendMergedRange(allocator, format_ranges, range);
                try appendMergedRange(allocator, other_ranges, range);
            },
            .surrogate => {
                try appendMergedRange(allocator, surrogate_ranges, range);
                try appendMergedRange(allocator, other_ranges, range);
            },
            .private_use => {
                try appendMergedRange(allocator, private_use_ranges, range);
                try appendMergedRange(allocator, other_ranges, range);
            },
            .unassigned => {
                try appendMergedRange(allocator, unassigned_ranges, range);
                try appendMergedRange(allocator, other_ranges, range);
            },
            else => unreachable,
        }
    }
}

fn loadNamedScriptData(
    allocator: std.mem.Allocator,
    path: []const u8,
    script_name: []const u8,
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
        if (!std.mem.eql(u8, rhs, script_name)) continue;

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

fn loadScriptAliases(
    allocator: std.mem.Allocator,
    path: []const u8,
) !std.ArrayList(ScriptAlias) {
    var aliases: std.ArrayList(ScriptAlias) = .empty;

    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 8 * 1024 * 1024);
    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line_trimmed = std.mem.trimRight(u8, line_raw, "\r");
        const line = if (std.mem.indexOfScalar(u8, line_trimmed, '#')) |index|
            std.mem.trim(u8, line_trimmed[0..index], " \t")
        else
            std.mem.trim(u8, line_trimmed, " \t");

        if (line.len == 0) continue;

        var fields = std.mem.splitScalar(u8, line, ';');
        const property = std.mem.trim(u8, fields.next() orelse continue, " \t");
        if (!std.mem.eql(u8, property, "sc")) continue;

        const short_name = std.mem.trim(u8, fields.next() orelse continue, " \t");
        const long_name = std.mem.trim(u8, fields.next() orelse continue, " \t");
        try aliases.append(allocator, .{
            .long_name = long_name,
            .short_name = short_name,
        });
    }

    return aliases;
}

fn loadScripts(
    allocator: std.mem.Allocator,
    path: []const u8,
    aliases: []const ScriptAlias,
) !std.ArrayList(ScriptEntry) {
    var entries: std.ArrayList(ScriptEntry) = .empty;

    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
    var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line_trimmed = std.mem.trimRight(u8, line_raw, "\r");
        const line = if (std.mem.indexOfScalar(u8, line_trimmed, '#')) |index|
            std.mem.trim(u8, line_trimmed[0..index], " \t")
        else
            std.mem.trim(u8, line_trimmed, " \t");

        if (line.len == 0 or line[0] == '@') continue;

        const sep = std.mem.indexOfScalar(u8, line, ';') orelse continue;
        const lhs = std.mem.trim(u8, line[0..sep], " \t");
        const rhs = std.mem.trim(u8, line[sep + 1 ..], " \t");

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

        const entry = try ensureScriptEntry(allocator, &entries, rhs, aliases);
        try appendMergedRange(allocator, &entry.ranges, range);
    }

    _ = try ensureScriptEntry(allocator, &entries, "Unknown", aliases);
    return entries;
}

fn ensureScriptEntry(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(ScriptEntry),
    long_name: []const u8,
    aliases: []const ScriptAlias,
) !*ScriptEntry {
    for (entries.items) |*entry| {
        if (std.mem.eql(u8, entry.long_name, long_name)) return entry;
    }

    const short_name = findScriptAlias(long_name, aliases) orelse long_name;
    try entries.append(allocator, .{
        .long_name = long_name,
        .short_name = short_name,
        .ranges = .empty,
    });
    return &entries.items[entries.items.len - 1];
}

fn findScriptAlias(long_name: []const u8, aliases: []const ScriptAlias) ?[]const u8 {
    for (aliases) |alias| {
        if (std.mem.eql(u8, alias.long_name, long_name)) return alias.short_name;
    }
    return null;
}

fn generalCategoryKind(name: []const u8) ?CategoryKind {
    if (std.mem.eql(u8, name, "Lt")) return .titlecase_letter;
    if (std.mem.eql(u8, name, "Lm")) return .modifier_letter;
    if (std.mem.eql(u8, name, "Lo")) return .other_letter;
    if (std.mem.eql(u8, name, "Mn")) return .nonspacing_mark;
    if (std.mem.eql(u8, name, "Mc")) return .spacing_mark;
    if (std.mem.eql(u8, name, "Me")) return .enclosing_mark;
    if (std.mem.eql(u8, name, "Nd")) return .decimal_number;
    if (std.mem.eql(u8, name, "Nl")) return .letter_number;
    if (std.mem.eql(u8, name, "No")) return .other_number;
    if (std.mem.eql(u8, name, "Pc")) return .connector_punctuation;
    if (std.mem.eql(u8, name, "Pd")) return .dash_punctuation;
    if (std.mem.eql(u8, name, "Ps")) return .open_punctuation;
    if (std.mem.eql(u8, name, "Pe")) return .close_punctuation;
    if (std.mem.eql(u8, name, "Pi")) return .initial_punctuation;
    if (std.mem.eql(u8, name, "Pf")) return .final_punctuation;
    if (std.mem.eql(u8, name, "Po")) return .other_punctuation;
    if (std.mem.eql(u8, name, "Sm")) return .math_symbol;
    if (std.mem.eql(u8, name, "Sc")) return .currency_symbol;
    if (std.mem.eql(u8, name, "Sk")) return .modifier_symbol;
    if (std.mem.eql(u8, name, "So")) return .other_symbol;
    if (std.mem.eql(u8, name, "Zs")) return .space_separator;
    if (std.mem.eql(u8, name, "Zl")) return .line_separator;
    if (std.mem.eql(u8, name, "Zp")) return .paragraph_separator;
    if (std.mem.eql(u8, name, "Cc")) return .control;
    if (std.mem.eql(u8, name, "Cf")) return .format;
    if (std.mem.eql(u8, name, "Cs")) return .surrogate;
    if (std.mem.eql(u8, name, "Co")) return .private_use;
    if (std.mem.eql(u8, name, "Cn")) return .unassigned;
    return null;
}

fn appendMergedRange(
    allocator: std.mem.Allocator,
    ranges: *std.ArrayList(Range),
    range: Range,
) !void {
    var insert_at: usize = 0;
    while (insert_at < ranges.items.len and ranges.items[insert_at].start < range.start) : (insert_at += 1) {}

    try ranges.insert(allocator, insert_at, range);

    if (insert_at > 0) {
        const prev = &ranges.items[insert_at - 1];
        const curr = &ranges.items[insert_at];
        if (curr.start <= prev.end + 1) {
            if (curr.end > prev.end) prev.end = curr.end;
            _ = ranges.orderedRemove(insert_at);
            insert_at -= 1;
        }
    }

    while (insert_at + 1 < ranges.items.len) {
        const curr = &ranges.items[insert_at];
        const next = ranges.items[insert_at + 1];
        if (next.start > curr.end + 1) break;
        if (next.end > curr.end) curr.end = next.end;
        _ = ranges.orderedRemove(insert_at + 1);
    }
}

fn writeOutput(
    config: Config,
    letter_ranges: []const Range,
    number_ranges: []const Range,
    whitespace_ranges: []const Range,
    alphabetic_ranges: []const Range,
    cased_ranges: []const Range,
    case_ignorable_ranges: []const Range,
    id_start_ranges: []const Range,
    id_continue_ranges: []const Range,
    xid_start_ranges: []const Range,
    xid_continue_ranges: []const Range,
    default_ignorable_code_point_ranges: []const Range,
    emoji_ranges: []const Range,
    simple_case_fold_mappings: []const CaseFoldMapping,
    latin_script_ranges: []const Range,
    greek_script_ranges: []const Range,
    cyrillic_script_ranges: []const Range,
    common_script_ranges: []const Range,
    inherited_script_ranges: []const Range,
    unknown_script_ranges: []const Range,
    script_entries: []const ScriptEntry,
    lowercase_ranges: []const Range,
    uppercase_ranges: []const Range,
    mark_ranges: []const Range,
    punctuation_ranges: []const Range,
    symbol_ranges: []const Range,
    separator_ranges: []const Range,
    other_ranges: []const Range,
    titlecase_letter_ranges: []const Range,
    modifier_letter_ranges: []const Range,
    other_letter_ranges: []const Range,
    nonspacing_mark_ranges: []const Range,
    spacing_mark_ranges: []const Range,
    enclosing_mark_ranges: []const Range,
    decimal_number_ranges: []const Range,
    letter_number_ranges: []const Range,
    other_number_ranges: []const Range,
    connector_punctuation_ranges: []const Range,
    dash_punctuation_ranges: []const Range,
    open_punctuation_ranges: []const Range,
    close_punctuation_ranges: []const Range,
    initial_punctuation_ranges: []const Range,
    final_punctuation_ranges: []const Range,
    other_punctuation_ranges: []const Range,
    math_symbol_ranges: []const Range,
    currency_symbol_ranges: []const Range,
    modifier_symbol_ranges: []const Range,
    other_symbol_ranges: []const Range,
    space_separator_ranges: []const Range,
    line_separator_ranges: []const Range,
    paragraph_separator_ranges: []const Range,
    control_ranges: []const Range,
    format_ranges: []const Range,
    surrogate_ranges: []const Range,
    private_use_ranges: []const Range,
    unassigned_ranges: []const Range,
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
    try writer.interface.print("// - {s}\n", .{config.derived_general_category});
    try writer.interface.print("// - {s}\n", .{config.scripts});
    try writer.interface.print("// - {s}\n", .{config.property_value_aliases});
    try writer.interface.print("// - {s}\n", .{config.emoji_data});
    try writer.interface.print("// - {s}\n", .{config.case_folding});
    try writer.interface.print("// Data source repository:\n", .{});
    try writer.interface.print("// - {s}\n", .{config.zg_root});
    try writer.interface.print("// - https://codeberg.org/atman/zg\n\n", .{});
    try writer.interface.print("pub const Range = struct {{\n", .{});
    try writer.interface.print("    start: u32,\n", .{});
    try writer.interface.print("    end: u32,\n", .{});
    try writer.interface.print("}};\n\n", .{});
    try writer.interface.print("pub const CaseFoldMapping = struct {{\n", .{});
    try writer.interface.print("    from: u32,\n", .{});
    try writer.interface.print("    to: u32,\n", .{});
    try writer.interface.print("}};\n\n", .{});
    try writer.interface.print("pub const script_property_base: u16 = 0x400;\n", .{});
    try writer.interface.print("pub const ScriptSpec = struct {{\n", .{});
    try writer.interface.print("    long_name: []const u8,\n", .{});
    try writer.interface.print("    short_name: []const u8,\n", .{});
    try writer.interface.print("    property_id: u16,\n", .{});
    try writer.interface.print("    ranges: []const Range,\n", .{});
    try writer.interface.print("}};\n\n", .{});

    try writeRangeList(&writer.interface, "letter_ranges", letter_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "number_ranges", number_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "whitespace_ranges", whitespace_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "alphabetic_ranges", alphabetic_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "cased_ranges", cased_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "case_ignorable_ranges", case_ignorable_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "id_start_ranges", id_start_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "id_continue_ranges", id_continue_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "xid_start_ranges", xid_start_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "xid_continue_ranges", xid_continue_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "default_ignorable_code_point_ranges", default_ignorable_code_point_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "emoji_ranges", emoji_ranges);
    try writer.interface.print("\n", .{});
    try writeCaseFoldMappings(&writer.interface, simple_case_fold_mappings);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "latin_script_ranges", latin_script_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "greek_script_ranges", greek_script_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "cyrillic_script_ranges", cyrillic_script_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "common_script_ranges", common_script_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "inherited_script_ranges", inherited_script_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "unknown_script_ranges", unknown_script_ranges);
    try writer.interface.print("\n", .{});
    try writeScriptSpecs(&writer.interface, script_entries);
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
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "other_ranges", other_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "titlecase_letter_ranges", titlecase_letter_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "modifier_letter_ranges", modifier_letter_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "other_letter_ranges", other_letter_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "nonspacing_mark_ranges", nonspacing_mark_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "spacing_mark_ranges", spacing_mark_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "enclosing_mark_ranges", enclosing_mark_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "decimal_number_ranges", decimal_number_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "letter_number_ranges", letter_number_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "other_number_ranges", other_number_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "connector_punctuation_ranges", connector_punctuation_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "dash_punctuation_ranges", dash_punctuation_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "open_punctuation_ranges", open_punctuation_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "close_punctuation_ranges", close_punctuation_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "initial_punctuation_ranges", initial_punctuation_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "final_punctuation_ranges", final_punctuation_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "other_punctuation_ranges", other_punctuation_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "math_symbol_ranges", math_symbol_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "currency_symbol_ranges", currency_symbol_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "modifier_symbol_ranges", modifier_symbol_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "other_symbol_ranges", other_symbol_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "space_separator_ranges", space_separator_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "line_separator_ranges", line_separator_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "paragraph_separator_ranges", paragraph_separator_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "control_ranges", control_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "format_ranges", format_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "surrogate_ranges", surrogate_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "private_use_ranges", private_use_ranges);
    try writer.interface.print("\n", .{});
    try writeRangeList(&writer.interface, "unassigned_ranges", unassigned_ranges);
    try writer.interface.flush();
}

fn writeRangeList(writer: anytype, name: []const u8, ranges: []const Range) !void {
    try writer.print("pub const {s} = [_]Range{{\n", .{name});
    for (ranges) |range| {
        try writer.print("    .{{ .start = 0x{X}, .end = 0x{X} }},\n", .{ range.start, range.end });
    }
    try writer.print("}};\n", .{});
}

fn writeCaseFoldMappings(writer: anytype, mappings: []const CaseFoldMapping) !void {
    try writer.print("pub const simple_case_fold_mappings = [_]CaseFoldMapping{{\n", .{});
    for (mappings) |mapping| {
        try writer.print("    .{{ .from = 0x{X}, .to = 0x{X} }},\n", .{ mapping.from, mapping.to });
    }
    try writer.print("}};\n", .{});
}

fn writeScriptSpecs(writer: anytype, script_entries: []const ScriptEntry) !void {
    for (script_entries, 0..) |entry, index| {
        try writer.print("pub const script_ranges_{d} = [_]Range{{\n", .{index});
        for (entry.ranges.items) |range| {
            try writer.print("    .{{ .start = 0x{X}, .end = 0x{X} }},\n", .{ range.start, range.end });
        }
        try writer.print("}};\n\n", .{});
    }

    var unknown_index: ?usize = null;
    try writer.print("pub const script_specs = [_]ScriptSpec{{\n", .{});
    for (script_entries, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.long_name, "Unknown")) unknown_index = index;
        try writer.print(
            "    .{{ .long_name = \"{s}\", .short_name = \"{s}\", .property_id = script_property_base + {d}, .ranges = script_ranges_{d}[0..] }},\n",
            .{ entry.long_name, entry.short_name, index, index },
        );
    }
    try writer.print("}};\n", .{});
    try writer.print("pub const script_unknown_property_id: u16 = script_property_base + {d};\n", .{unknown_index orelse 0});
}
