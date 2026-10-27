//! Every tool the server exposes, in `tools/list` order.
const common = @import("common.zig");
const inspect = @import("inspect.zig");
const sync = @import("sync.zig");
const stage = @import("stage.zig");

pub const all: []const common.Tool = &(inspect.tools ++ sync.tools ++ stage.tools);

pub fn find(name: []const u8) ?common.Tool {
    for (all) |t| {
        if (@import("std").mem.eql(u8, t.name, name)) return t;
    }
    return null;
}
