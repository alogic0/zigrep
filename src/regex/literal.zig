const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const LiteralSequence = struct {
    bytes: []const u8 = "",
};

pub const Prefilter = struct {
    required: []const LiteralSequence,

    pub fn deinit(self: Prefilter, allocator: std.mem.Allocator) void {
        for (self.required) |literal| allocator.free(literal.bytes);
        allocator.free(self.required);
    }

    pub fn mayMatch(self: Prefilter, haystack: []const u8) bool {
        if (self.required.len == 0) return true;

        for (self.required) |literal| {
            if (literal.bytes.len == 0) continue;
            if (containsLiteral(haystack, literal.bytes)) return true;
        }
        return false;
    }

    pub fn isAscii(self: Prefilter) bool {
        for (self.required) |literal| {
            for (literal.bytes) |byte| {
                if (!std.ascii.isAscii(byte)) return false;
            }
        }
        return true;
    }
};

pub fn duplicatePrefilter(
    allocator: std.mem.Allocator,
    literals: []const LiteralSequence,
) !?Prefilter {
    if (literals.len == 0) return null;

    const duped = try allocator.alloc(LiteralSequence, literals.len);
    errdefer allocator.free(duped);

    for (literals, 0..) |literal, index| {
        duped[index] = .{
            .bytes = try allocator.dupe(u8, literal.bytes),
        };
        errdefer {
            var i: usize = 0;
            while (i <= index) : (i += 1) allocator.free(duped[i].bytes);
        }
    }

    return .{ .required = duped };
}

fn containsLiteral(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len == 1 and shouldUseSimdByteScan()) {
        return simdContainsByte(haystack, needle[0]);
    }
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn shouldUseSimdByteScan() bool {
    if (!build_options.simd_prefilter) return false;

    return switch (builtin.cpu.arch) {
        .x86_64, .x86, .aarch64, .arm => true,
        else => false,
    };
}

fn simdContainsByte(haystack: []const u8, needle: u8) bool {
    const lane_count = 16;
    const Vec = @Vector(lane_count, u8);

    var index: usize = 0;
    const broadcast: Vec = @splat(needle);
    while (index + lane_count <= haystack.len) : (index += lane_count) {
        const chunk: *align(1) const Vec = @ptrCast(haystack[index .. index + lane_count].ptr);
        const matches = chunk.* == broadcast;
        if (@reduce(.Or, matches)) return true;
    }

    while (index < haystack.len) : (index += 1) {
        if (haystack[index] == needle) return true;
    }
    return false;
}

test "Prefilter accepts haystacks containing a required literal" {
    const testing = std.testing;

    const prefilter = Prefilter{
        .required = &[_]LiteralSequence{
            .{ .bytes = "needle" },
        },
    };

    try testing.expect(prefilter.mayMatch("haystack with needle inside"));
    try testing.expect(!prefilter.mayMatch("haystack only"));
}

test "Prefilter single-byte scanning matches the generic path" {
    const testing = std.testing;

    try testing.expect(containsLiteral("abcxyz", "x"));
    try testing.expect(!containsLiteral("abcxyz", "q"));
    try testing.expect(containsLiteral("abcxyz", "xyz"));
}

test "duplicatePrefilter copies literal bytes" {
    const testing = std.testing;

    const prefilter = (try duplicatePrefilter(testing.allocator, &[_]LiteralSequence{
        .{ .bytes = "ab" },
    })).?;
    defer prefilter.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), prefilter.required.len);
    try testing.expectEqualStrings("ab", prefilter.required[0].bytes);
}

test "Prefilter detects ASCII-only literals" {
    const testing = std.testing;

    try testing.expect((Prefilter{
        .required = &[_]LiteralSequence{.{ .bytes = "ascii" }},
    }).isAscii());

    try testing.expect(!(Prefilter{
        .required = &[_]LiteralSequence{.{ .bytes = "©" }},
    }).isAscii());
}
