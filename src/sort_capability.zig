const builtin = @import("builtin");

pub const CreatedSortBackend = enum {
    none,
};

pub const CreatedSortCapability = enum {
    unavailable_platform,
    unavailable_runtime,
    available,
};

pub fn createdSortBackend() CreatedSortBackend {
    return comptime switch (builtin.os.tag) {
        else => .none,
    };
}

pub fn createdSortCapability() CreatedSortCapability {
    return switch (comptime createdSortBackend()) {
        .none => .unavailable_platform,
    };
}

pub fn createdSortUnavailableMessage() []const u8 {
    return "sorting by creation time isn't supported: creation time is not available on this platform currently";
}
