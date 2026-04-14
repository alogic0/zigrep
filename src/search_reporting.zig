const std = @import("std");
const zigrep = struct {
    pub const search = @import("search/root.zig");
};
const command = @import("command.zig");
const search_output = @import("search_output.zig");
const search_reporting_lines = @import("search_reporting_lines.zig");
const search_reporting_match_modes = @import("search_reporting_match_modes.zig");
const search_reporting_multiline = @import("search_reporting_multiline.zig");
const search_reporting_types = @import("search_reporting_types.zig");

// Reporting and output shaping.
// This module owns line, multiline, context, count, path-only, and match
// reporting over already-selected haystacks.

const OutputOptions = command.OutputOptions;
const OutputFormat = command.OutputFormat;
const ReportMode = command.ReportMode;
const DisplayMode = search_output.DisplayMode;

pub const ReportSummary = search_reporting_types.ReportSummary;
pub const writeFileReports = search_reporting_lines.writeFileReports;

pub fn writeFileOutput(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    bytes: []const u8,
    encoding: zigrep.search.io.InputEncoding,
    suppress_binary_output: bool,
    invert_match: bool,
    output: OutputOptions,
    output_format: OutputFormat,
    report_mode: ReportMode,
    max_count: ?usize,
    context_before: usize,
    context_after: usize,
    display_mode: DisplayMode,
) !ReportSummary {
    if (suppress_binary_output) {
        return switch (report_mode) {
            .lines => search_reporting_match_modes.writeBinaryFileMatchNotice(allocator, writer, searcher, path, bytes, encoding, invert_match),
            .files_with_matches => search_reporting_match_modes.writeFilePathOnMatch(allocator, writer, searcher, path, bytes, encoding, invert_match, output, output_format),
            .files_without_match => search_reporting_match_modes.writeFilePathWithoutMatch(allocator, writer, searcher, path, bytes, encoding, invert_match, output, output_format),
            .count => unreachable,
        };
    }
    return switch (report_mode) {
        .lines => search_reporting_lines.writeFileLines(
            allocator,
            writer,
            searcher,
            path,
            bytes,
            encoding,
            invert_match,
            output,
            output_format,
            max_count,
            context_before,
            context_after,
            display_mode,
        ),
        .count => search_reporting_match_modes.writeFileCount(allocator, writer, searcher, path, bytes, encoding, invert_match, output, output_format, max_count),
        .files_with_matches => search_reporting_match_modes.writeFilePathOnMatch(allocator, writer, searcher, path, bytes, encoding, invert_match, output, output_format),
        .files_without_match => search_reporting_match_modes.writeFilePathWithoutMatch(allocator, writer, searcher, path, bytes, encoding, invert_match, output, output_format),
    };
}

pub fn reportFileMatch(
    allocator: std.mem.Allocator,
    searcher: *zigrep.search.grep.Searcher,
    path: []const u8,
    bytes: []const u8,
    encoding: zigrep.search.io.InputEncoding,
) !?zigrep.search.grep.MatchReport {
    return search_reporting_match_modes.reportFileMatch(allocator, searcher, path, bytes, encoding);
}

pub fn formatReport(
    allocator: std.mem.Allocator,
    report: zigrep.search.grep.MatchReport,
    output: OutputOptions,
) ![]u8 {
    return search_output.formatReport(allocator, report, output);
}
