// Tiny shared owner for report-summary data that needs to cross reporting
// family modules without creating import cycles back through the facade.
pub const ReportSummary = struct {
    matched: bool = false,
    matched_lines: usize = 0,
    matches: usize = 0,
};
