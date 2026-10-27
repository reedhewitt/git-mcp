//! Typed access to a tool call's `arguments` object. Unknown keys are
//! ignored: each tool reads only the keys it declares.
const Args = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const validate = @import("../validate.zig");

obj: ?*const std.json.ObjectMap,
diag: *validate.Diag,

/// Backing storage for formatted messages (no allocator here). The
/// dispatcher copies `diag.msg` into the arena before anything else runs.
threadlocal var msg_buf: [512]u8 = undefined;

fn fail(a: Args, comptime fmt: []const u8, args: anytype) validate.Error {
    a.diag.msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch "invalid arguments";
    return error.Invalid;
}

/// The value for `name`; JSON `null` counts as absent.
fn get(a: Args, name: []const u8) ?std.json.Value {
    const o = a.obj orelse return null;
    const v = o.get(name) orelse return null;
    return if (v == .null) null else v;
}

pub fn str(a: Args, name: []const u8) validate.Error!?[]const u8 {
    const v = a.get(name) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => a.fail("'{s}' must be a string", .{name}),
    };
}

pub fn reqStr(a: Args, name: []const u8) validate.Error![]const u8 {
    return try a.str(name) orelse a.fail("'{s}' is required", .{name});
}

pub fn boolean(a: Args, name: []const u8) validate.Error!?bool {
    const v = a.get(name) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => a.fail("'{s}' must be a boolean", .{name}),
    };
}

pub fn int(a: Args, name: []const u8) validate.Error!?i64 {
    const v = a.get(name) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (@floor(f) == f and @abs(f) < 1e15) @intFromFloat(f) else a.fail("'{s}' must be an integer", .{name}),
        else => a.fail("'{s}' must be an integer", .{name}),
    };
}

/// An array of strings; a single string is accepted as a one-element list.
pub fn strList(a: Args, arena: Allocator, name: []const u8) validate.Error!?[]const []const u8 {
    const v = a.get(name) orelse return null;
    switch (v) {
        .string => |s| {
            const out = try arena.alloc([]const u8, 1);
            out[0] = s;
            return out;
        },
        .array => |arr| {
            const out = try arena.alloc([]const u8, arr.items.len);
            for (arr.items, out) |item, *o| switch (item) {
                .string => |s| o.* = s,
                else => return a.fail("'{s}' must be a string or an array of strings", .{name}),
            };
            return out;
        },
        else => return a.fail("'{s}' must be a string or an array of strings", .{name}),
    }
}

/// A string naming one of `E`'s fields.
pub fn enumOf(a: Args, comptime E: type, name: []const u8) validate.Error!?E {
    const s = try a.str(name) orelse return null;
    if (std.meta.stringToEnum(E, s)) |e| return e;
    const allowed = comptime blk: {
        var list: []const u8 = "";
        for (std.meta.fieldNames(E), 0..) |field_name, i| {
            list = list ++ (if (i > 0) ", " else "") ++ field_name;
        }
        break :blk list;
    };
    return a.fail("'{s}' must be one of: {s}", .{ name, allowed });
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn parseObj(arena: Allocator, json: []const u8) !std.json.ObjectMap {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
    return v.object;
}

test "Args typed getters" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const obj = try parseObj(arena,
        \\{"s":"x","b":true,"i":3,"f":4.0,"l":["a","b"],"one":"c","n":null,"e":"ours","extra":1}
    );
    var diag: validate.Diag = .{};
    const a: Args = .{ .obj = &obj, .diag = &diag };

    try testing.expectEqualStrings("x", (try a.str("s")).?);
    try testing.expectEqual(@as(?[]const u8, null), try a.str("missing"));
    try testing.expectEqual(@as(?[]const u8, null), try a.str("n"));
    try testing.expectEqual(@as(?bool, true), try a.boolean("b"));
    try testing.expectEqual(@as(?i64, 3), try a.int("i"));
    try testing.expectEqual(@as(?i64, 4), try a.int("f"));
    const l = (try a.strList(arena, "l")).?;
    try testing.expectEqual(@as(usize, 2), l.len);
    try testing.expectEqualStrings("b", l[1]);
    try testing.expectEqualStrings("c", (try a.strList(arena, "one")).?[0]);
    const E = enum { ours, theirs };
    try testing.expectEqual(@as(?E, .ours), try a.enumOf(E, "e"));

    try testing.expectError(error.Invalid, a.str("b"));
    try testing.expectEqualStrings("'b' must be a string", diag.msg);
    try testing.expectError(error.Invalid, a.reqStr("missing"));
    try testing.expectEqualStrings("'missing' is required", diag.msg);
    try testing.expectError(error.Invalid, a.boolean("s"));
    try testing.expectError(error.Invalid, a.int("s"));
    try testing.expectError(error.Invalid, a.strList(arena, "b"));
    try testing.expectError(error.Invalid, a.enumOf(E, "s"));
    try testing.expectEqualStrings("'s' must be one of: ours, theirs", diag.msg);

    const none: Args = .{ .obj = null, .diag = &diag };
    try testing.expectEqual(@as(?[]const u8, null), try none.str("s"));
}
