const std = @import("std");

pub fn main(init: std.process.Init) !void {
    _ = init;
}

test {
    _ = @import("text.zig");
    _ = @import("validate.zig");
    _ = @import("git.zig");
    _ = @import("testutil.zig");
}
