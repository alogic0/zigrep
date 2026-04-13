const std = @import("std");
const zigrep = @import("zigrep");
const cli = zigrep.cli;
const cli_entry = @import("cli_entry");
const search = zigrep.search;

const OutputFormat = cli.OutputFormat;
const BinaryMode = cli.BinaryMode;
const ReportMode = cli.ReportMode;
const parseArgs = cli.parseArgs;
const writeFatalError = cli_entry.writeFatalError;

test "parseArgs defaults to current directory search" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "needle" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqualStrings("needle", opts.pattern);
            try testing.expectEqual(@as(usize, 1), opts.paths.len);
            try testing.expectEqualStrings(".", opts.paths[0]);
            try testing.expectEqual(@as(usize, 0), opts.globs.len);
            try testing.expectEqual(@as(usize, 0), opts.ignore_files.len);
            try testing.expect(!opts.include_hidden);
            try testing.expect(!opts.follow_symlinks);
            try testing.expect(!opts.no_ignore);
            try testing.expect(!opts.no_ignore_vcs);
            try testing.expect(!opts.no_ignore_parent);
            try testing.expectEqual(BinaryMode.skip, opts.binary_mode);
            try testing.expectEqual(search.grep.CaseMode.sensitive, opts.case_mode);
            try testing.expectEqual(search.io.ReadStrategy.mmap, opts.read_strategy);
            try testing.expectEqual(search.io.InputEncoding.auto, opts.encoding);
            try testing.expect(!opts.multiline);
            try testing.expect(!opts.multiline_dotall);
            try testing.expectEqual(@as(?usize, null), opts.parallel_jobs);
            try testing.expectEqual(@as(?usize, null), opts.max_depth);
            try testing.expect(opts.output.with_filename);
            try testing.expect(opts.output.line_number);
            try testing.expect(opts.output.column_number);
            try testing.expect(!opts.output.only_matching);
            try testing.expect(!opts.output.null_path_terminator);
            try testing.expect(!opts.output.heading);
            try testing.expectEqual(OutputFormat.text, opts.output_format);
            try testing.expectEqual(ReportMode.lines, opts.report_mode);
            try testing.expect(!opts.show_stats);
            try testing.expect(!opts.invert_match);
        },
        .help => unreachable,
        .version => unreachable,
        .type_list => unreachable,
    }
}

test "parseArgs accepts version flag" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "--version" });
    switch (parsed) {
        .version => {},
        else => return error.TestExpectedEqual,
    }
}

test "writeFatalError includes usage for CLI usage errors" {
    const testing = std.testing;

    var stderr_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_capture.deinit();

    try writeFatalError(&stderr_capture.writer, "zigrep", error.MissingPattern);

    try testing.expect(std.mem.containsAtLeast(u8, stderr_capture.written(), 1, "error: MissingPattern\n"));
    try testing.expect(std.mem.containsAtLeast(u8, stderr_capture.written(), 1, "usage: zigrep [FLAGS] PATTERN [PATH...]\n"));
}

test "writeFatalError omits usage for runtime search errors" {
    const testing = std.testing;

    var stderr_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_capture.deinit();

    try writeFatalError(&stderr_capture.writer, "zigrep", error.FileNotFound);

    try testing.expectEqualStrings("error: FileNotFound\n", stderr_capture.written());
}

test "parseArgs treats version-like args as positional after the pattern starts" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "needle", "--version" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqualStrings("needle", opts.pattern);
            try testing.expectEqual(@as(usize, 1), opts.paths.len);
            try testing.expectEqualStrings("--version", opts.paths[0]);
        },
        .help, .version, .type_list => return error.TestExpectedEqual,
    }
}

test "parseArgs treats help-like args as positional after terminator" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "--", "--help" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqualStrings("--help", opts.pattern);
            try testing.expectEqual(@as(usize, 1), opts.paths.len);
            try testing.expectEqualStrings(".", opts.paths[0]);
        },
        .help, .version, .type_list => return error.TestExpectedEqual,
    }
}

test "parseArgs accepts numeric and formatting flags" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{
        "zigrep",
        "-j",
        "4",
        "--max-depth",
        "2",
        "--max-count",
        "3",
        "--count",
        "--only-matching",
        "--encoding",
        "utf16le",
        "--no-filename",
        "--no-column",
        "--",
        "-literal",
        "src",
    });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqualStrings("-literal", opts.pattern);
            try testing.expectEqual(@as(?usize, 4), opts.parallel_jobs);
            try testing.expectEqual(@as(?usize, 2), opts.max_depth);
            try testing.expectEqual(@as(?usize, 3), opts.max_count);
            try testing.expectEqual(search.io.InputEncoding.utf16le, opts.encoding);
            try testing.expect(!opts.output.with_filename);
            try testing.expect(opts.output.line_number);
            try testing.expect(!opts.output.column_number);
            try testing.expect(opts.output.only_matching);
            try testing.expectEqual(ReportMode.count, opts.report_mode);
            try testing.expectEqual(@as(usize, 1), opts.paths.len);
            try testing.expectEqualStrings("src", opts.paths[0]);
        },
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts files-without-match mode" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "--files-without-match", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqual(ReportMode.files_without_match, opts.report_mode);
            try testing.expectEqualStrings("needle", opts.pattern);
            try testing.expectEqual(@as(usize, 1), opts.paths.len);
            try testing.expectEqualStrings("src", opts.paths[0]);
        },
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts max-count mode" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "-m", "2", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqual(@as(?usize, 2), opts.max_count);
            try testing.expectEqualStrings("needle", opts.pattern);
            try testing.expectEqual(@as(usize, 1), opts.paths.len);
            try testing.expectEqualStrings("src", opts.paths[0]);
        },
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts before and after context flags" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "-B", "2", "-A", "3", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqual(@as(usize, 2), opts.context_before);
            try testing.expectEqual(@as(usize, 3), opts.context_after);
        },
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts repeated glob flags" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "-g", "*.zig", "--glob", "!main.zig", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqual(@as(usize, 2), opts.globs.len);
            try testing.expectEqualStrings("*.zig", opts.globs[0]);
            try testing.expectEqualStrings("!main.zig", opts.globs[1]);
            try testing.expectEqualStrings("needle", opts.pattern);
        },
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts ignore control flags" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{
        "zigrep",
        "--ignore-file",
        "custom.ignore",
        "--no-ignore-vcs",
        "--no-ignore-parent",
        "needle",
        "src",
    });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqual(@as(usize, 1), opts.ignore_files.len);
            try testing.expectEqualStrings("custom.ignore", opts.ignore_files[0]);
            try testing.expect(!opts.no_ignore);
            try testing.expect(opts.no_ignore_vcs);
            try testing.expect(opts.no_ignore_parent);
        },
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts unrestricted flags" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{
        "zigrep",
        "-uu",
        "--unrestricted",
        "needle",
        "src",
    });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expect(opts.no_ignore);
            try testing.expect(opts.include_hidden);
            try testing.expectEqual(BinaryMode.text, opts.binary_mode);
        },
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts json output flag" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "--json", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqual(OutputFormat.json, opts.output_format);
            try testing.expectEqual(ReportMode.lines, opts.report_mode);
        },
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts raw-byte encoding mode" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "-E", "none", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| try testing.expectEqual(search.io.InputEncoding.none, opts.encoding),
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts latin1 encoding mode" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "-E", "latin1", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| try testing.expectEqual(search.io.InputEncoding.latin1, opts.encoding),
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts multiline flags" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "-U", "--multiline-dotall", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expect(opts.multiline);
            try testing.expect(opts.multiline_dotall);
        },
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs rejects multiline-dotall without multiline" {
    const testing = std.testing;

    try testing.expectError(error.InvalidFlagCombination, parseArgs(testing.allocator, &.{
        "zigrep",
        "--multiline-dotall",
        "needle",
        "src",
    }));
}

test "runCli rejects unsupported multiline output combinations for now" {
    const testing = std.testing;

    var stdout_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr_capture.deinit();

    try testing.expectError(error.InvalidFlagCombination, cli_entry.runCli(
        testing.allocator,
        &stdout_capture.writer,
        &stderr_capture.writer,
        &.{ "zigrep", "-U", "--max-count", "1", "needle", "." },
    ));
}

test "parseArgs accepts null output flag for path modes" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "--null", "-l", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expect(opts.output.null_path_terminator);
            try testing.expectEqual(ReportMode.files_with_matches, opts.report_mode);
        },
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts stats flag" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "--stats", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| try testing.expect(opts.show_stats),
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts heading flag" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "--heading", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expect(opts.output.heading);
            try testing.expect(!opts.output.with_filename);
            try testing.expectEqual(ReportMode.lines, opts.report_mode);
        },
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts invert-match flag" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "-v", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| try testing.expect(opts.invert_match),
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts binary mode flag" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "--binary", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| try testing.expectEqual(BinaryMode.suppress, opts.binary_mode),
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts compressed search flag" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{ "zigrep", "-z", "needle", "src" });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        else => unreachable,
    };

    switch (parsed) {
        .run => |opts| try testing.expect(opts.search_compressed),
        else => unreachable,
    }
}

test "parseArgs accepts preprocessor flags" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{
        "zigrep",
        "--pre",
        "/bin/cat",
        "--pre-glob",
        "*.wrapped",
        "needle",
        "src",
    });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        else => unreachable,
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqualStrings("/bin/cat", opts.preprocessor.?);
            try testing.expectEqual(@as(usize, 1), opts.pre_globs.len);
            try testing.expectEqualStrings("*.wrapped", opts.pre_globs[0]);
        },
        else => unreachable,
    }
}

test "parseArgs accepts ignore-case and smart-case flags" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{
        "zigrep",
        "-i",
        "--smart-case",
        "needle",
        "src",
    });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqual(search.grep.CaseMode.smart, opts.case_mode);
        },
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts file type flags" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{
        "zigrep",
        "-t",
        "zig",
        "-T",
        "markdown",
        "--type-add",
        "web:*.web,*.page",
        "needle",
        "src",
    });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .run => |opts| {
            try testing.expectEqualStrings("needle", opts.pattern);
            try testing.expectEqual(@as(usize, 1), opts.include_types.len);
            try testing.expectEqualStrings("zig", opts.include_types[0]);
            try testing.expectEqual(@as(usize, 1), opts.exclude_types.len);
            try testing.expectEqualStrings("markdown", opts.exclude_types[0]);
            try testing.expectEqual(@as(usize, 1), opts.type_adds.len);
            try testing.expectEqualStrings("web:*.web,*.page", opts.type_adds[0]);
        },
        .help, .version, .type_list => unreachable,
    }
}

test "parseArgs accepts type-list without pattern" {
    const testing = std.testing;

    const parsed = try parseArgs(testing.allocator, &.{
        "zigrep",
        "--type-add",
        "web:*.web",
        "--type-list",
    });
    defer switch (parsed) {
        .run => |opts| opts.deinit(testing.allocator),
        .type_list => |opts| opts.deinit(testing.allocator),
        .help, .version => {},
    };

    switch (parsed) {
        .type_list => |opts| {
            try testing.expectEqual(@as(usize, 1), opts.type_adds.len);
            try testing.expectEqualStrings("web:*.web", opts.type_adds[0]);
        },
        .help, .version, .run => unreachable,
    }
}

test "parseArgs rejects invalid numeric flags" {
    const testing = std.testing;

    try testing.expectError(error.InvalidFlagValue, parseArgs(testing.allocator, &.{
        "zigrep",
        "-j",
        "0",
        "needle",
    }));
    try testing.expectError(error.MissingFlagValue, parseArgs(testing.allocator, &.{
        "zigrep",
        "--max-depth",
    }));
    try testing.expectError(error.InvalidFlagValue, parseArgs(testing.allocator, &.{
        "zigrep",
        "--encoding",
        "latin2",
        "needle",
    }));
    try testing.expectError(error.InvalidFlagCombination, parseArgs(testing.allocator, &.{
        "zigrep",
        "--count",
        "-C",
        "1",
        "needle",
    }));
    try testing.expectError(error.InvalidFlagCombination, parseArgs(testing.allocator, &.{
        "zigrep",
        "--only-matching",
        "-A",
        "1",
        "needle",
    }));
    try testing.expectError(error.InvalidFlagCombination, parseArgs(testing.allocator, &.{
        "zigrep",
        "--json",
        "-C",
        "1",
        "needle",
    }));
    try testing.expectError(error.InvalidFlagCombination, parseArgs(testing.allocator, &.{
        "zigrep",
        "--null",
        "needle",
    }));
    try testing.expectError(error.InvalidFlagCombination, parseArgs(testing.allocator, &.{
        "zigrep",
        "--json",
        "--null",
        "-l",
        "needle",
    }));
    try testing.expectError(error.InvalidFlagCombination, parseArgs(testing.allocator, &.{
        "zigrep",
        "--heading",
        "--count",
        "needle",
    }));
    try testing.expectError(error.InvalidFlagCombination, parseArgs(testing.allocator, &.{
        "zigrep",
        "-v",
        "--only-matching",
        "needle",
    }));
    try testing.expectError(error.InvalidFlagCombination, parseArgs(testing.allocator, &.{
        "zigrep",
        "-v",
        "-C",
        "1",
        "needle",
    }));
    try testing.expectError(error.InvalidFlagCombination, parseArgs(testing.allocator, &.{
        "zigrep",
        "--binary",
        "--count",
        "needle",
    }));
    try testing.expectError(error.InvalidFlagCombination, parseArgs(testing.allocator, &.{
        "zigrep",
        "--binary",
        "--json",
        "needle",
    }));
    try testing.expectError(error.InvalidFlagCombination, parseArgs(testing.allocator, &.{
        "zigrep",
        "--pre-glob",
        "*.wrapped",
        "needle",
    }));
}
