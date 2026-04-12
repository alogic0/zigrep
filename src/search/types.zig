const std = @import("std");
const glob = @import("glob.zig");

pub const TypeDef = struct {
    name: []u8,
    globs: []const []u8,

    pub fn deinit(self: TypeDef, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.globs) |pattern| allocator.free(pattern);
        allocator.free(self.globs);
    }
};

pub const Matcher = struct {
    defs: []TypeDef,

    pub fn deinit(self: Matcher, allocator: std.mem.Allocator) void {
        for (self.defs) |def| def.deinit(allocator);
        allocator.free(self.defs);
    }

    pub fn typeMatches(self: Matcher, type_name: []const u8, path: []const u8) bool {
        const def = self.findType(type_name) orelse return false;
        for (def.globs) |pattern| {
            if (glob.matchesPathPattern(pattern, path)) return true;
        }
        return false;
    }

    pub fn fileAllowed(self: Matcher, include_types: []const []const u8, exclude_types: []const []const u8, path: []const u8) bool {
        if (include_types.len != 0) {
            var included = false;
            for (include_types) |type_name| {
                if (self.typeMatches(type_name, path)) {
                    included = true;
                    break;
                }
            }
            if (!included) return false;
        }

        for (exclude_types) |type_name| {
            if (self.typeMatches(type_name, path)) return false;
        }
        return true;
    }

    pub fn hasType(self: Matcher, name: []const u8) bool {
        return self.findType(name) != null;
    }

    pub fn findType(self: Matcher, name: []const u8) ?TypeDef {
        for (self.defs) |def| {
            if (std.mem.eql(u8, def.name, name)) return def;
        }
        return null;
    }
};

pub fn init(allocator: std.mem.Allocator, type_add_specs: []const []const u8) !Matcher {
    var defs: std.ArrayList(TypeDef) = .empty;
    errdefer {
        for (defs.items) |def| def.deinit(allocator);
        defs.deinit(allocator);
    }

    for (builtin_defs) |builtin| {
        try defs.append(allocator, .{
            .name = try allocator.dupe(u8, builtin.name),
            .globs = try dupePatterns(allocator, builtin.globs),
        });
    }

    for (type_add_specs) |spec| {
        try applyTypeAddSpec(allocator, &defs, spec);
    }

    return .{ .defs = try defs.toOwnedSlice(allocator) };
}

pub fn writeTypeList(writer: *std.Io.Writer, matcher: Matcher) !void {
    for (matcher.defs) |def| {
        try writer.print("{s}: ", .{def.name});
        for (def.globs, 0..) |pattern, index| {
            if (index != 0) try writer.writeAll(", ");
            try writer.writeAll(pattern);
        }
        try writer.writeByte('\n');
    }
}

pub fn validateSelectedTypes(matcher: Matcher, include_types: []const []const u8, exclude_types: []const []const u8) !void {
    for (include_types) |type_name| {
        if (!matcher.hasType(type_name)) return error.UnknownType;
    }
    for (exclude_types) |type_name| {
        if (!matcher.hasType(type_name)) return error.UnknownType;
    }
}

const BuiltinDef = struct {
    name: []const u8,
    globs: []const []const u8,
};

const builtin_defs = [_]BuiltinDef{
    .{ .name = "zig", .globs = &.{"*.zig"} },
    .{ .name = "c", .globs = &.{"*.c", "*.h"} },
    .{ .name = "cpp", .globs = &.{"*.cc", "*.cpp", "*.cxx", "*.hpp", "*.hh", "*.hxx"} },
    .{ .name = "rust", .globs = &.{"*.rs"} },
    .{ .name = "python", .globs = &.{"*.py"} },
    .{ .name = "shell", .globs = &.{"*.sh", "*.bash", "*.zsh"} },
    .{ .name = "markdown", .globs = &.{"*.md"} },
    .{ .name = "json", .globs = &.{"*.json"} },
    .{ .name = "yaml", .globs = &.{"*.yaml", "*.yml"} },
    .{ .name = "toml", .globs = &.{"*.toml"} },
    .{ .name = "html", .globs = &.{"*.html", "*.htm"} },
    .{ .name = "css", .globs = &.{"*.css"} },
    .{ .name = "javascript", .globs = &.{"*.js", "*.mjs", "*.cjs"} },
    .{ .name = "typescript", .globs = &.{"*.ts", "*.tsx"} },
    .{ .name = "text", .globs = &.{"*.txt"} },
};

fn dupePatterns(allocator: std.mem.Allocator, patterns: []const []const u8) ![]const []u8 {
    const duped = try allocator.alloc([]u8, patterns.len);
    errdefer {
        for (duped[0..patterns.len]) |pattern| allocator.free(pattern);
        allocator.free(duped);
    }

    for (patterns, 0..) |pattern, index| {
        duped[index] = try allocator.dupe(u8, pattern);
    }
    return duped;
}

fn applyTypeAddSpec(allocator: std.mem.Allocator, defs: *std.ArrayList(TypeDef), spec: []const u8) !void {
    const colon_index = std.mem.indexOfScalar(u8, spec, ':') orelse return error.InvalidTypeAddSpec;
    const type_name = spec[0..colon_index];
    const patterns_blob = spec[colon_index + 1 ..];
    if (type_name.len == 0 or patterns_blob.len == 0) return error.InvalidTypeAddSpec;

    var patterns_iter = std.mem.splitScalar(u8, patterns_blob, ',');
    var new_patterns: std.ArrayList([]u8) = .empty;
    defer new_patterns.deinit(allocator);

    while (patterns_iter.next()) |pattern| {
        if (pattern.len == 0) continue;
        try new_patterns.append(allocator, try allocator.dupe(u8, pattern));
    }
    if (new_patterns.items.len == 0) return error.InvalidTypeAddSpec;

    for (defs.items) |*def| {
        if (!std.mem.eql(u8, def.name, type_name)) continue;

        const combined = try allocator.alloc([]u8, def.globs.len + new_patterns.items.len);
        @memcpy(combined[0..def.globs.len], def.globs);
        @memcpy(combined[def.globs.len..], new_patterns.items);
        allocator.free(def.globs);
        def.globs = combined;
        new_patterns.clearRetainingCapacity();
        return;
    }

    try defs.append(allocator, .{
        .name = try allocator.dupe(u8, type_name),
        .globs = try new_patterns.toOwnedSlice(allocator),
    });
}

test "type matcher matches built-in types" {
    const testing = std.testing;

    const matcher = try init(testing.allocator, &.{});
    defer matcher.deinit(testing.allocator);

    try testing.expect(matcher.typeMatches("zig", "src/main.zig"));
    try testing.expect(matcher.typeMatches("markdown", "docs/readme.md"));
    try testing.expect(!matcher.typeMatches("zig", "README.md"));
}

test "type matcher supports type-add extensions" {
    const testing = std.testing;

    const matcher = try init(testing.allocator, &.{"web:*.web,*.page"});
    defer matcher.deinit(testing.allocator);

    try testing.expect(matcher.typeMatches("web", "src/home.web"));
    try testing.expect(matcher.typeMatches("web", "src/index.page"));
}

test "type matcher applies include and exclude type filters" {
    const testing = std.testing;

    const matcher = try init(testing.allocator, &.{});
    defer matcher.deinit(testing.allocator);

    try testing.expect(matcher.fileAllowed(&.{"zig"}, &.{}, "src/main.zig"));
    try testing.expect(!matcher.fileAllowed(&.{"zig"}, &.{}, "README.md"));
    try testing.expect(!matcher.fileAllowed(&.{}, &.{"zig"}, "src/main.zig"));
}
