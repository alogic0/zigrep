const std = @import("std");

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
            if (std.mem.indexOf(u8, haystack, literal.bytes) != null) return true;
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
