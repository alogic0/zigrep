const std = @import("std");
const cli_parse_helpers = @import("cli_parse_helpers.zig");
const cli_parse_state = @import("cli_parse_state.zig");
const cli_validation = @import("cli_validation.zig");
const command = @import("command.zig");
const cli_dispatch = @import("cli_dispatch.zig");

// CLI parser and usage surface.
// This module owns argument parsing, parse-time validation, and usage text.
// It intentionally does not own top-level config resolution or command dispatch.

pub const CliError = cli_parse_state.CliError;

pub const OutputOptions = command.OutputOptions;
pub const OutputFormat = command.OutputFormat;
pub const BinaryMode = command.BinaryMode;
pub const ReportMode = command.ReportMode;
pub const CliOptions = command.CliOptions;

pub const ParseResult = cli_dispatch.ParseResult;

const ParseState = cli_parse_state.ParseState;
const ParseBuffers = cli_parse_state.ParseBuffers;
const ScalarFlagResult = cli_parse_helpers.ScalarFlagResult;

pub fn parseArgs(allocator: std.mem.Allocator, argv: []const []const u8) !ParseResult {
    if (argv.len <= 1) return error.MissingPattern;

    var state: ParseState = .{};
    var buffers: ParseBuffers = .{};
    defer buffers.deinit(allocator);
    var stop_parsing_flags = false;

    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (!stop_parsing_flags and state.pattern == null and std.mem.eql(u8, arg, "--")) {
            stop_parsing_flags = true;
            continue;
        }

        if (!stop_parsing_flags and state.pattern == null and arg.len > 0 and arg[0] == '-') {
            switch (cli_parse_helpers.handleScalarFlag(&state, arg)) {
                .help => return .help,
                .version => return .version,
                .handled => continue,
                .unhandled => {},
            }
            if (try cli_parse_helpers.handleValueFlag(
                allocator,
                &state,
                &buffers,
                argv,
                &index,
                arg,
            )) {
                continue;
            }
            return error.UnknownFlag;
        }

        if (state.pattern == null) {
            state.pattern = arg;
        } else {
            try buffers.paths.append(allocator, arg);
        }
    }
    return cli_validation.finalizeParse(allocator, &state, &buffers);
}

pub fn isUsageError(err: anyerror) bool {
    return switch (err) {
        error.MissingPattern,
        error.UnknownFlag,
        error.UnknownType,
        error.MissingFlagValue,
        error.InvalidFlagValue,
        error.InvalidFlagCombination,
        error.InvalidTypeAddSpec,
        => true,
        else => false,
    };
}

pub fn writeUsage(writer: *std.Io.Writer, argv0: []const u8) !void {
    try writer.print(
        \\usage: {s} [FLAGS] PATTERN [PATH...]
        \\search recursively for PATTERN starting at each PATH, or "." when omitted
        \\  -h, --help            show this help
        \\  -V, --version         show program version
        \\  --config-path PATH    load default flags from PATH
        \\  --no-config           ignore config file support for this run
        \\  --hidden              include hidden files
        \\  -u, --unrestricted    reduce filtering; repeat to include hidden and binary files
        \\  -v, --invert-match    select non-matching lines instead of matching lines
        \\  --ignore-file PATH    load ignore rules from PATH
        \\  --no-ignore           disable ignore filtering
        \\  --no-ignore-vcs       ignore VCS ignore files like .gitignore
        \\  --no-ignore-parent    ignore parent VCS ignore files
        \\  -t TYPE              include only files matching TYPE
        \\  -T TYPE              exclude files matching TYPE
        \\  --type-add SPEC      add file type definition name:glob[,glob...]
        \\  --type-list          list known file types and exit
        \\  --follow              follow symlinks
        \\  -i, --ignore-case     search case-insensitively
        \\  -S, --smart-case      use ignore-case unless the pattern has uppercase letters
        \\  --text                search binary files and print normal match output
        \\  --binary              search binary files but suppress matching line content
        \\  -z, --search-zip      search gzip-compressed files too
        \\  --pre CMD             run CMD on each selected file path before searching
        \\  --pre-glob GLOB       apply --pre only to paths matching GLOB
        \\  -g, --glob GLOB       include or exclude paths by glob
        \\  --buffered            use the simpler file-reading method
        \\  --mmap                use the faster file-reading method when possible
        \\  -E, --encoding ENC    force input encoding: auto, none, utf8, latin1, utf16le, utf16be
        \\  -U, --multiline       enable searching across multiple lines
        \\  --multiline-dotall    make '.' match newlines in multiline mode
        \\  -j, --threads N       use up to N worker threads
        \\  --max-depth N         limit recursive walk depth
        \\  -A, --after-context N
        \\                        print N trailing context lines
        \\  -B, --before-context N
        \\                        print N leading context lines
        \\  -C, --context N       print N leading and trailing context lines
        \\  -m, --max-count N     stop after N matching lines per file
        \\  -c, --count           print matching line counts
        \\  -l, --files-with-matches
        \\                        print only matching file paths
        \\  -L, --files-without-match
        \\                        print only non-matching file paths
        \\  -o, --only-matching   print only the matched text
        \\  --json                emit newline-delimited JSON events
        \\  --stats               print search summary statistics to stderr
        \\  --null                emit NUL-delimited paths in file path output modes
        \\  --heading             group text line output by file path headings
        \\  -H, --with-filename   always print the file path
        \\  --no-filename         suppress the file path prefix
        \\  -n, --line-number     print line numbers
        \\  --no-line-number      suppress line numbers
        \\  --column              print match columns
        \\  --no-column           suppress match columns
        \\  --                    stop parsing flags
        \\
    , .{argv0});
}
