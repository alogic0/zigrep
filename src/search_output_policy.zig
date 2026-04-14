const std = @import("std");
const command = @import("command.zig");
const search_output = @import("search_output.zig");

pub const CliOptions = command.CliOptions;
pub const OutputOptions = command.OutputOptions;
pub const ReportMode = command.ReportMode;
pub const ReportExecutionOptions = command.ReportExecutionOptions;
pub const DisplayMode = search_output.DisplayMode;

fn isPathOnlyReportMode(mode: ReportMode) bool {
    return mode == .files_with_matches or mode == .files_without_match;
}

fn shouldUseExplicitSingleFileDefaults(options: CliOptions) bool {
    const traversal = options.traversal();
    const reporting = options.reporting();
    const hints = options.parseHints();
    if (isPathOnlyReportMode(reporting.report_mode) or reporting.output_format != .text) return false;
    if (hints.used_default_path or traversal.paths.len != 1) return false;

    const stat = if (std.fs.path.isAbsolute(traversal.paths[0])) blk: {
        const file = std.fs.openFileAbsolute(traversal.paths[0], .{}) catch return false;
        defer file.close();
        break :blk file.stat() catch return false;
    } else std.fs.cwd().statFile(traversal.paths[0]) catch return false;
    return stat.kind == .file;
}

pub fn effectivePathSearchOptions(options: CliOptions) CliOptions {
    var effective = options;
    const hints = options.parseHints();
    if (!shouldUseExplicitSingleFileDefaults(options)) return effective;

    if (!hints.filename_flag_seen) effective.output.with_filename = false;
    if (!hints.line_number_flag_seen) effective.output.line_number = false;
    if (!hints.column_number_flag_seen) effective.output.column_number = false;
    effective.output.heading = false;
    return effective;
}

pub fn effectiveStdinReporting(options: CliOptions) ReportExecutionOptions {
    var effective = options.reporting();
    effective.output = effectiveStdinOutput(options);
    return effective;
}

pub fn effectiveStdinOutput(options: CliOptions) OutputOptions {
    var effective = options.reporting().output;
    const hints = options.parseHints();
    if (!hints.filename_flag_seen and !isPathOnlyReportMode(options.reporting().report_mode)) {
        effective.with_filename = false;
    }
    return effective;
}

pub fn normalizedOutputFormat(requested: command.OutputFormat, report_mode: ReportMode) command.OutputFormat {
    if (requested == .json and report_mode != .lines) return .text;
    return requested;
}

pub fn normalizedOutputOptions(output: OutputOptions) OutputOptions {
    var effective = output;
    if (effective.heading) effective.with_filename = false;
    return effective;
}

pub fn displayMode(raw_binary_text: bool) DisplayMode {
    return if (raw_binary_text) .raw else .escaped;
}
