// Shared search result and stats types used across the decomposed search stack.
pub const SearchStats = struct {
    searched_files: usize = 0,
    matched_files: usize = 0,
    searched_bytes: usize = 0,
    skipped_binary_files: usize = 0,
    warnings_emitted: usize = 0,

    pub fn add(self: *SearchStats, other: SearchStats) void {
        self.searched_files += other.searched_files;
        self.matched_files += other.matched_files;
        self.searched_bytes += other.searched_bytes;
        self.skipped_binary_files += other.skipped_binary_files;
        self.warnings_emitted += other.warnings_emitted;
    }
};

pub const SearchResult = struct {
    matched: bool,
    stats: SearchStats = .{},
};
