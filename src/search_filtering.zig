const std = @import("std");
const command = @import("command.zig");

const zigrep = struct {
    pub const search = @import("search/root.zig");
};

pub const CliOptions = command.CliOptions;

pub const LoadedIgnore = struct {
    base_dir: []u8,
    matcher: zigrep.search.ignore.IgnoreMatcher,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.base_dir);
        self.matcher.deinit(allocator);
    }
};

pub fn filterEntries(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    entries: []const zigrep.search.walk.Entry,
    globs: []const []const u8,
    loaded_ignores: []const LoadedIgnore,
    type_matcher: zigrep.search.types.Matcher,
    include_types: []const []const u8,
    exclude_types: []const []const u8,
) ![]const zigrep.search.walk.Entry {
    var filtered: std.ArrayList(zigrep.search.walk.Entry) = .empty;
    defer filtered.deinit(allocator);

    for (entries) |entry| {
        if (!try entryAllowed(
            allocator,
            root_path,
            entry,
            globs,
            loaded_ignores,
            type_matcher,
            include_types,
            exclude_types,
        )) continue;
        try filtered.append(allocator, entry);
    }

    return filtered.toOwnedSlice(allocator);
}

pub fn entryAllowed(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    entry: zigrep.search.walk.Entry,
    globs: []const []const u8,
    loaded_ignores: []const LoadedIgnore,
    type_matcher: zigrep.search.types.Matcher,
    include_types: []const []const u8,
    exclude_types: []const []const u8,
) !bool {
    const relative = relativeGlobPath(root_path, entry.path);
    if (!zigrep.search.glob.allowsPath(globs, relative)) return false;
    if (!type_matcher.fileAllowed(include_types, exclude_types, relative)) return false;
    if (try pathIsIgnored(allocator, entry.path, loaded_ignores)) return false;
    return true;
}

pub fn loadIgnoreMatchers(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    options: CliOptions,
) ![]LoadedIgnore {
    var loaded: std.ArrayList(LoadedIgnore) = .empty;
    errdefer {
        for (loaded.items) |item| item.deinit(allocator);
        loaded.deinit(allocator);
    }

    if (!options.no_ignore) {
        if (!options.no_ignore_vcs) {
            try loadVcsIgnoreChain(allocator, &loaded, root_path, options.no_ignore_parent);
        }
        for (options.ignore_files) |ignore_path| {
            try loadExplicitIgnoreFile(allocator, &loaded, ignore_path);
        }
    }

    return loaded.toOwnedSlice(allocator);
}

pub fn deinitLoadedIgnores(allocator: std.mem.Allocator, loaded: []LoadedIgnore) void {
    for (loaded) |item| item.deinit(allocator);
    allocator.free(loaded);
}

fn pathIsIgnored(
    allocator: std.mem.Allocator,
    entry_path: []const u8,
    loaded_ignores: []const LoadedIgnore,
) !bool {
    var ignored = false;

    for (loaded_ignores) |loaded| {
        const relative = try std.fs.path.relative(allocator, loaded.base_dir, entry_path);
        defer allocator.free(relative);
        if (std.mem.startsWith(u8, relative, "..")) continue;
        if (loaded.matcher.matchResult(.{ .path = relative })) |matched_ignore| {
            ignored = matched_ignore;
        }
    }

    return ignored;
}

fn loadVcsIgnoreChain(
    allocator: std.mem.Allocator,
    loaded: *std.ArrayList(LoadedIgnore),
    root_path: []const u8,
    no_ignore_parent: bool,
) !void {
    const search_dir = try resolveSearchDir(allocator, root_path);
    defer allocator.free(search_dir);

    var dirs: std.ArrayList([]u8) = .empty;
    defer {
        for (dirs.items) |dir| allocator.free(dir);
        dirs.deinit(allocator);
    }

    var current = try allocator.dupe(u8, search_dir);
    while (true) {
        try dirs.append(allocator, current);
        if (no_ignore_parent) break;

        const parent_opt = std.fs.path.dirname(current);
        if (parent_opt == null) break;
        const parent = parent_opt.?;
        if (parent.len == 0 or std.mem.eql(u8, parent, current)) break;
        current = try allocator.dupe(u8, parent);
    }

    var index = dirs.items.len;
    while (index > 0) {
        index -= 1;
        try loadImplicitIgnoreFileAtDir(allocator, loaded, dirs.items[index]);
    }
}

fn resolveSearchDir(allocator: std.mem.Allocator, root_path: []const u8) ![]u8 {
    const resolved = try std.fs.cwd().realpathAlloc(allocator, root_path);
    errdefer allocator.free(resolved);

    if (std.fs.cwd().openDir(root_path, .{})) |dir_opened| {
        var dir = dir_opened;
        dir.close();
        return resolved;
    } else |err| switch (err) {
        error.NotDir => {
            const dirname = std.fs.path.dirname(resolved) orelse ".";
            const duped = try allocator.dupe(u8, dirname);
            allocator.free(resolved);
            return duped;
        },
        else => return err,
    }
}

fn loadImplicitIgnoreFileAtDir(
    allocator: std.mem.Allocator,
    loaded: *std.ArrayList(LoadedIgnore),
    dir_path: []const u8,
) !void {
    const ignore_path = try std.fs.path.join(allocator, &.{ dir_path, ".gitignore" });
    defer allocator.free(ignore_path);

    const buffer = zigrep.search.io.readFileOwned(allocator, ignore_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer buffer.deinit(allocator);

    const matcher = try zigrep.search.ignore.compile(allocator, buffer.bytes);
    try loaded.append(allocator, .{
        .base_dir = try allocator.dupe(u8, dir_path),
        .matcher = matcher,
    });
}

fn loadExplicitIgnoreFile(
    allocator: std.mem.Allocator,
    loaded: *std.ArrayList(LoadedIgnore),
    ignore_path: []const u8,
) !void {
    const resolved = try std.fs.cwd().realpathAlloc(allocator, ignore_path);
    defer allocator.free(resolved);

    const buffer = try zigrep.search.io.readFileOwned(allocator, ignore_path, .{});
    defer buffer.deinit(allocator);

    const matcher = try zigrep.search.ignore.compile(allocator, buffer.bytes);
    const base_dir = std.fs.path.dirname(resolved) orelse ".";
    try loaded.append(allocator, .{
        .base_dir = try allocator.dupe(u8, base_dir),
        .matcher = matcher,
    });
}

fn relativeGlobPath(root_path: []const u8, entry_path: []const u8) []const u8 {
    if (std.mem.eql(u8, root_path, entry_path)) {
        return std.fs.path.basename(entry_path);
    }
    if (entry_path.len > root_path.len and
        std.mem.startsWith(u8, entry_path, root_path) and
        entry_path[root_path.len] == std.fs.path.sep)
    {
        return entry_path[root_path.len + 1 ..];
    }
    return entry_path;
}
