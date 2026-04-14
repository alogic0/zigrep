const std = @import("std");

pub const WalkOptions = struct {
    threads: usize = 0,
    max_depth: ?usize = null,
    include_hidden: bool = false,
    follow_symlinks: bool = false,
};

pub const EntryKind = enum {
    file,
    directory,
    symlink,
    other,
};

pub const Entry = struct {
    path: []const u8,
    kind: EntryKind,
    depth: usize,
    accessed_ns: i128,
    modified_ns: i128,
    changed_ns: i128,

    pub fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const WalkError = error{
    OutOfMemory,
    StopWalk,
    CurrentWorkingDirectoryUnlinked,
} || std.fs.Dir.OpenError || std.fs.Dir.StatFileError || std.fs.Dir.AccessError || std.fs.Dir.Iterator.Error || std.fs.Dir.RealPathError;

const VisitedDirs = std.StringHashMapUnmanaged(void);
const NoopWarningHandler = struct {
    pub fn warn(_: @This(), _: []const u8, _: anyerror) void {}
};

pub fn collectFiles(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    options: WalkOptions,
) WalkError![]Entry {
    return collectFilesWithWarnings(allocator, root_path, options, NoopWarningHandler{});
}

pub fn collectFilesWithWarnings(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    options: WalkOptions,
    warning_handler: anytype,
) WalkError![]Entry {
    var files: std.ArrayList(Entry) = .empty;
    errdefer {
        for (files.items) |entry| entry.deinit(allocator);
        files.deinit(allocator);
    }

    try walk(allocator, root_path, options, Walker{
        .allocator = allocator,
        .context = &files,
        .visitFn = collectFileEntry,
    }, warning_handler);

    return files.toOwnedSlice(allocator);
}

pub fn walk(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    options: WalkOptions,
    visitor: anytype,
    warning_handler: anytype,
) WalkError!void {
    var visited_dirs: VisitedDirs = .empty;
    defer deinitVisitedDirs(allocator, &visited_dirs);

    const root_kind = try classifyPath(root_path);
    switch (root_kind) {
        .file => {
            const stat = try std.fs.cwd().statFile(root_path);
            const owned = try allocator.dupe(u8, root_path);
            try visitor.visit(.{
                .path = owned,
                .kind = .file,
                .depth = 0,
                .accessed_ns = stat.atime,
                .modified_ns = stat.mtime,
                .changed_ns = stat.ctime,
            });
        },
        .directory => try walkDir(allocator, root_path, options, 0, false, &visited_dirs, visitor, warning_handler),
        .symlink => if (options.follow_symlinks) {
            try walkFollowedPath(allocator, root_path, options, 0, false, &visited_dirs, visitor, warning_handler);
        },
        .other => {},
    }
}

const Walker = struct {
    allocator: std.mem.Allocator,
    context: *std.ArrayList(Entry),
    visitFn: *const fn (std.mem.Allocator, *std.ArrayList(Entry), Entry) WalkError!void,

    fn visit(self: Walker, entry: Entry) WalkError!void {
        try self.visitFn(self.allocator, self.context, entry);
    }
};

fn collectFileEntry(allocator: std.mem.Allocator, files: *std.ArrayList(Entry), entry: Entry) WalkError!void {
    if (entry.kind != .file) {
        entry.deinit(allocator);
        return;
    }
    try files.append(allocator, entry);
}

fn walkDir(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    options: WalkOptions,
    depth: usize,
    allow_warn_skip: bool,
    visited_dirs: *VisitedDirs,
    visitor: anytype,
    warning_handler: anytype,
) WalkError!void {
    if (!try rememberVisitedDir(allocator, visited_dirs, dir_path, allow_warn_skip, warning_handler)) return;

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        if (allow_warn_skip and shouldWarnAndSkipTraversalError(err)) {
            warning_handler.warn(dir_path, err);
            return;
        }
        return err;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |child| {
        if (!options.include_hidden and isHidden(child.name)) continue;

        const child_path = try std.fs.path.join(allocator, &.{ dir_path, child.name });
        defer allocator.free(child_path);

        const child_depth = depth + 1;
        const kind = entryKind(child.kind);

        switch (kind) {
            .file => {
                const stat = std.fs.cwd().statFile(child_path) catch |err| {
                    if (shouldWarnAndSkipTraversalError(err)) {
                        warning_handler.warn(child_path, err);
                        continue;
                    }
                    return err;
                };
                const owned = try allocator.dupe(u8, child_path);
                try visitor.visit(.{
                    .path = owned,
                    .kind = .file,
                    .depth = child_depth,
                    .accessed_ns = stat.atime,
                    .modified_ns = stat.mtime,
                    .changed_ns = stat.ctime,
                });
            },
            .directory => {
                if (options.max_depth) |max_depth| {
                    if (child_depth > max_depth) continue;
                }
                try walkDir(allocator, child_path, options, child_depth, true, visited_dirs, visitor, warning_handler);
            },
            .symlink => {
                if (options.follow_symlinks) {
                    try walkFollowedPath(allocator, child_path, options, child_depth, true, visited_dirs, visitor, warning_handler);
                }
            },
            .other => {},
        }
    }
}

fn walkFollowedPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: WalkOptions,
    depth: usize,
    allow_warn_skip: bool,
    visited_dirs: *VisitedDirs,
    visitor: anytype,
    warning_handler: anytype,
) WalkError!void {
    const kind = classifyPath(path) catch |err| {
        if (allow_warn_skip and shouldWarnAndSkipTraversalError(err)) {
            warning_handler.warn(path, err);
            return;
        }
        return err;
    };
    switch (kind) {
        .file => {
            const stat = std.fs.cwd().statFile(path) catch |err| {
                if (allow_warn_skip and shouldWarnAndSkipTraversalError(err)) {
                    warning_handler.warn(path, err);
                    return;
                }
                return err;
            };
            const owned = try allocator.dupe(u8, path);
            try visitor.visit(.{
                .path = owned,
                .kind = .file,
                .depth = depth,
                .accessed_ns = stat.atime,
                .modified_ns = stat.mtime,
                .changed_ns = stat.ctime,
            });
        },
        .directory => {
            if (options.max_depth) |max_depth| {
                if (depth > max_depth) return;
            }
            try walkDir(allocator, path, options, depth, allow_warn_skip, visited_dirs, visitor, warning_handler);
        },
        else => {},
    }
}

fn rememberVisitedDir(
    allocator: std.mem.Allocator,
    visited_dirs: *VisitedDirs,
    dir_path: []const u8,
    allow_warn_skip: bool,
    warning_handler: anytype,
) WalkError!bool {
    const canonical = std.fs.cwd().realpathAlloc(allocator, dir_path) catch |err| {
        if (allow_warn_skip and shouldWarnAndSkipTraversalError(err)) {
            warning_handler.warn(dir_path, err);
            return false;
        }
        return err;
    };
    errdefer allocator.free(canonical);

    const gop = try visited_dirs.getOrPut(allocator, canonical);
    if (gop.found_existing) {
        allocator.free(canonical);
        return false;
    }
    gop.value_ptr.* = {};
    return true;
}

fn shouldWarnAndSkipTraversalError(err: anyerror) bool {
    return switch (err) {
        error.AccessDenied,
        error.FileNotFound,
        error.NameTooLong,
        error.NotDir,
        error.SymLinkLoop,
        => true,
        else => false,
    };
}

fn deinitVisitedDirs(allocator: std.mem.Allocator, visited_dirs: *VisitedDirs) void {
    var it = visited_dirs.keyIterator();
    while (it.next()) |key| allocator.free(key.*);
    visited_dirs.deinit(allocator);
}

fn classifyPath(path: []const u8) WalkError!EntryKind {
    const stat = try std.fs.cwd().statFile(path);
    return switch (stat.kind) {
        .file => .file,
        .directory => .directory,
        .sym_link => .symlink,
        else => .other,
    };
}

fn entryKind(kind: std.fs.File.Kind) EntryKind {
    return switch (kind) {
        .file => .file,
        .directory => .directory,
        .sym_link => .symlink,
        else => .other,
    };
}

fn isHidden(name: []const u8) bool {
    return name.len > 0 and name[0] == '.';
}

test "walk collects files recursively" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src/nested");
    try tmp.dir.writeFile(.{ .sub_path = "root.txt", .data = "root" });
    try tmp.dir.writeFile(.{ .sub_path = "src/lib.zig", .data = "lib" });
    try tmp.dir.writeFile(.{ .sub_path = "src/nested/mod.zig", .data = "mod" });

    const root_path = try std.fs.path.join(testing.allocator, &.{ tmp.dir.realpathAlloc(testing.allocator, ".") catch unreachable });
    defer testing.allocator.free(root_path);

    const entries = try collectFiles(testing.allocator, root_path, .{});
    defer {
        for (entries) |entry| entry.deinit(testing.allocator);
        testing.allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 3), entries.len);
}

test "walk honors max depth and hidden filtering" {
    const testing = std.testing;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src/deep");
    try tmp.dir.writeFile(.{ .sub_path = ".hidden", .data = "hidden" });
    try tmp.dir.writeFile(.{ .sub_path = "src/visible.txt", .data = "visible" });
    try tmp.dir.writeFile(.{ .sub_path = "src/deep/file.txt", .data = "deep" });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    const shallow = try collectFiles(testing.allocator, root_path, .{ .max_depth = 1 });
    defer {
        for (shallow) |entry| entry.deinit(testing.allocator);
        testing.allocator.free(shallow);
    }

    try testing.expectEqual(@as(usize, 1), shallow.len);
    try testing.expect(std.mem.endsWith(u8, shallow[0].path, "visible.txt"));

    const with_hidden = try collectFiles(testing.allocator, root_path, .{ .include_hidden = true });
    defer {
        for (with_hidden) |entry| entry.deinit(testing.allocator);
        testing.allocator.free(with_hidden);
    }

    try testing.expectEqual(@as(usize, 3), with_hidden.len);
}

test "walk follow mode avoids symlink directory cycles" {
    const testing = std.testing;
    const builtin = @import("builtin");

    switch (builtin.os.tag) {
        .windows, .wasi => return,
        else => {},
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("root/sub");
    try tmp.dir.writeFile(.{ .sub_path = "root/sub/file.txt", .data = "loop safe" });
    try tmp.dir.symLink("..", "root/sub/parent-link", .{ .is_directory = true });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, "root");
    defer testing.allocator.free(root_path);

    const entries = try collectFiles(testing.allocator, root_path, .{ .follow_symlinks = true });
    defer {
        for (entries) |entry| entry.deinit(testing.allocator);
        testing.allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expect(std.mem.endsWith(u8, entries[0].path, "file.txt"));
}

test "walk can warn and skip unreadable child directories" {
    const testing = std.testing;
    const builtin = @import("builtin");

    switch (builtin.os.tag) {
        .windows, .wasi => return,
        else => {},
    }

    const WarningCapture = struct {
        writer: *std.Io.Writer.Allocating,

        pub fn warn(self: @This(), path: []const u8, err: anyerror) void {
            self.writer.writer.print("warning: skipping directory {s}: {s}\n", .{ path, @errorName(err) }) catch {};
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("root/blocked");
    try tmp.dir.writeFile(.{ .sub_path = "root/visible.txt", .data = "visible" });
    try tmp.dir.writeFile(.{ .sub_path = "root/blocked/secret.txt", .data = "secret" });

    var blocked = try tmp.dir.openDir("root/blocked", .{});
    defer blocked.close();
    try blocked.chmod(0);
    defer blocked.chmod(0o755) catch {};

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, "root");
    defer testing.allocator.free(root_path);

    var warning_capture: std.Io.Writer.Allocating = .init(testing.allocator);
    defer warning_capture.deinit();

    const entries = try collectFilesWithWarnings(testing.allocator, root_path, .{}, WarningCapture{
        .writer = &warning_capture,
    });
    defer {
        for (entries) |entry| entry.deinit(testing.allocator);
        testing.allocator.free(entries);
    }

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expect(std.mem.endsWith(u8, entries[0].path, "visible.txt"));
    try testing.expect(std.mem.containsAtLeast(u8, warning_capture.written(), 1, "warning: skipping directory "));
}

test "walk visitor can stop traversal early" {
    const testing = std.testing;

    const StopAfterFirst = struct {
        allocator: std.mem.Allocator,
        count: *usize,

        pub fn visit(self: @This(), entry: Entry) WalkError!void {
            defer entry.deinit(self.allocator);
            if (entry.kind != .file) return;
            self.count.* += 1;
            return error.StopWalk;
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("src/nested");
    try tmp.dir.writeFile(.{ .sub_path = "one.txt", .data = "one" });
    try tmp.dir.writeFile(.{ .sub_path = "src/two.txt", .data = "two" });
    try tmp.dir.writeFile(.{ .sub_path = "src/nested/three.txt", .data = "three" });

    const root_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_path);

    var count: usize = 0;
    walk(testing.allocator, root_path, .{}, StopAfterFirst{
        .allocator = testing.allocator,
        .count = &count,
    }, NoopWarningHandler{}) catch |err| switch (err) {
        error.StopWalk => {},
        else => return err,
    };

    try testing.expectEqual(@as(usize, 1), count);
}
