//! MCP over JSON-RPC 2.0: one request line in, at most one response line out.
const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const git_mod = @import("git.zig");
const common = @import("tools/common.zig");
const Tool = common.Tool;

pub const server_name = "git-mcp";
pub const server_version = "0.1.0";
/// Newest first; the first entry is the fallback offered to unknown clients.
pub const protocol_versions = [_][]const u8{ "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05" };

pub const instructions = "Runs git on the host machine. Always pass the repository's absolute HOST path (not a sandbox mount path such as /sessions/\u{2026}/mnt/\u{2026}). Destructive operations (force push, reset --hard, clean, branch -D, stash drop, discarding uncommitted changes) are intentionally unavailable.";

pub const Server = struct {
    runner: *const git_mod.Runner,
    home: ?[]const u8,
    tools: []const Tool,

    /// Handles one JSON-RPC message. Returns the response line (without a
    /// trailing newline), or null for notifications.
    pub fn handleMessage(s: *const Server, arena: Allocator, line: []const u8) !?[]const u8 {
        const root = json.parseFromSliceLeaky(json.Value, arena, line, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return try errorResponse(arena, null, parse_error, "Parse error"),
        };
        if (root != .object) return try errorResponse(arena, null, invalid_request, "Invalid Request: expected a JSON object");
        const msg = &root.object;

        // A usable id is a string or number; anything else is answered with id null.
        const raw_id = msg.get("id");
        const id: ?json.Value = if (raw_id) |v| switch (v) {
            .string, .integer, .float, .number_string => v,
            else => null,
        } else null;

        const version_ok = if (msg.get("jsonrpc")) |v| v == .string and std.mem.eql(u8, v.string, "2.0") else false;
        const method: ?[]const u8 = if (msg.get("method")) |v| (if (v == .string) v.string else null) else null;
        if (!version_ok or method == null or (raw_id != null and id == null and raw_id.? != .null)) {
            return try errorResponse(arena, id, invalid_request, "Invalid Request");
        }
        // No id: a notification. Never answered, whatever the method.
        if (raw_id == null) return null;

        // getPtr: the pointer must refer to the map's storage, not a copy.
        const params: ?*const json.ObjectMap = if (msg.getPtr("params")) |p| (if (p.* == .object) &p.object else null) else null;
        const m = method.?;
        if (std.mem.eql(u8, m, "initialize")) return try s.initialize(arena, id, params);
        if (std.mem.eql(u8, m, "ping")) return try resultResponse(arena, id, EmptyObject{});
        if (std.mem.eql(u8, m, "tools/list")) return try s.toolsList(arena, id);
        if (std.mem.eql(u8, m, "tools/call")) return try s.toolsCall(arena, id, params);
        return try errorResponse(arena, id, method_not_found, try std.fmt.allocPrint(arena, "Method not found: {s}", .{m}));
    }

    fn initialize(_: *const Server, arena: Allocator, id: ?json.Value, params: ?*const json.ObjectMap) ![]const u8 {
        var version: []const u8 = protocol_versions[0];
        if (params) |p| if (p.get("protocolVersion")) |v| if (v == .string) {
            for (protocol_versions) |pv| if (std.mem.eql(u8, pv, v.string)) {
                version = pv;
            };
        };
        return resultResponse(arena, id, .{
            .protocolVersion = version,
            .capabilities = .{ .tools = .{ .listChanged = false } },
            .serverInfo = .{ .name = server_name, .version = server_version },
            .instructions = instructions,
        });
    }

    fn toolsList(s: *const Server, arena: Allocator, id: ?json.Value) ![]const u8 {
        const Entry = struct { name: []const u8, description: []const u8, inputSchema: json.Value };
        const entries = try arena.alloc(Entry, s.tools.len);
        for (s.tools, entries) |t, *e| e.* = .{
            .name = t.name,
            .description = t.description,
            .inputSchema = try json.parseFromSliceLeaky(json.Value, arena, t.schema, .{}),
        };
        return resultResponse(arena, id, .{ .tools = entries });
    }

    fn toolsCall(s: *const Server, arena: Allocator, id: ?json.Value, params: ?*const json.ObjectMap) ![]const u8 {
        const p = params orelse return errorResponse(arena, id, invalid_params, "Invalid params: expected an object with 'name'");
        const name_v = p.get("name") orelse return errorResponse(arena, id, invalid_params, "Invalid params: missing tool 'name'");
        if (name_v != .string) return errorResponse(arena, id, invalid_params, "Invalid params: 'name' must be a string");
        const tool = for (s.tools) |t| {
            if (std.mem.eql(u8, t.name, name_v.string)) break t;
        } else return errorResponse(arena, id, invalid_params, try std.fmt.allocPrint(arena, "Unknown tool: {s}", .{name_v.string}));

        const args_obj: ?*const json.ObjectMap = if (p.getPtr("arguments")) |a| switch (a.*) {
            .object => &a.object,
            .null => null,
            else => return errorResponse(arena, id, invalid_params, "Invalid params: 'arguments' must be an object"),
        } else null;

        var ctx: common.Ctx = .{ .arena = arena, .runner = s.runner, .home = s.home };
        const res = try common.invoke(&ctx, tool, .{ .obj = args_obj, .diag = &ctx.diag });
        const Content = struct { type: []const u8 = "text", text: []const u8 };
        return resultResponse(arena, id, .{
            .content = &[_]Content{.{ .text = res.text }},
            .isError = res.is_error,
        });
    }
};

const parse_error = -32700;
const invalid_request = -32600;
const method_not_found = -32601;
const invalid_params = -32602;
const internal_error = -32603;

/// Response written when an input line exceeds the read buffer.
pub const too_long_response =
    \\{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error: message exceeds 1 MiB"}}
;

/// Fallback when even building an internal-error response fails.
pub const internal_error_response =
    \\{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}
;

/// The -32603 response for `line` after `handleMessage` failed: echoes the
/// request's id if it can be recovered, uses id null if not, and returns
/// null for a notification (which is never answered). Returns
/// `internal_error_response` if it cannot allocate.
pub fn internalErrorResponse(arena: Allocator, line: []const u8) ?[]const u8 {
    var id: ?json.Value = null;
    if (json.parseFromSliceLeaky(json.Value, arena, line, .{})) |root| {
        if (root == .object) {
            const raw = root.object.get("id") orelse return null;
            id = switch (raw) {
                .string, .integer, .float, .number_string => raw,
                else => null,
            };
        }
    } else |_| {}
    return errorResponse(arena, id, internal_error, "Internal error") catch internal_error_response;
}

const EmptyObject = struct {};

fn resultResponse(arena: Allocator, id: ?json.Value, result: anytype) ![]const u8 {
    return json.Stringify.valueAlloc(arena, .{ .jsonrpc = "2.0", .id = id, .result = result }, .{});
}

fn errorResponse(arena: Allocator, id: ?json.Value, code: i64, message: []const u8) ![]const u8 {
    return json.Stringify.valueAlloc(arena, .{
        .jsonrpc = "2.0",
        .id = id,
        .@"error" = .{ .code = code, .message = message },
    }, .{});
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const Fixture = @import("testutil.zig").Fixture;
const registry = @import("tools/registry.zig");

fn testServer(f: *Fixture) Server {
    return .{ .runner = &f.runner, .home = f.root, .tools = registry.all };
}

/// Sends `line` and parses the response.
fn roundTrip(f: *Fixture, line: []const u8) !json.Value {
    const s = testServer(f);
    const out = (try s.handleMessage(f.arena(), line)) orelse return error.NoResponse;
    try testing.expect(std.mem.indexOfScalar(u8, out, '\n') == null);
    return json.parseFromSliceLeaky(json.Value, f.arena(), out, .{});
}

fn field(v: json.Value, path: []const []const u8) json.Value {
    var cur = v;
    for (path) |p| cur = cur.object.get(p) orelse {
        std.debug.print("missing field '{s}'\n", .{p});
        @panic("missing field");
    };
    return cur;
}

fn errorCode(v: json.Value) i64 {
    return field(v, &.{ "error", "code" }).integer;
}

test "initialize negotiates version and echoes id" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try roundTrip(f,
        \\{"jsonrpc":"2.0","id":"a1","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}
    );
    try testing.expectEqualStrings("2.0", field(r, &.{"jsonrpc"}).string);
    try testing.expectEqualStrings("a1", field(r, &.{"id"}).string);
    try testing.expectEqualStrings("2025-06-18", field(r, &.{ "result", "protocolVersion" }).string);
    try testing.expectEqualStrings("git-mcp", field(r, &.{ "result", "serverInfo", "name" }).string);
    try testing.expectEqualStrings(server_version, field(r, &.{ "result", "serverInfo", "version" }).string);
    try testing.expectEqual(false, field(r, &.{ "result", "capabilities", "tools", "listChanged" }).bool);
    try testing.expectEqualStrings(instructions, field(r, &.{ "result", "instructions" }).string);

    const old = try roundTrip(f,
        \\{"jsonrpc":"2.0","id":7,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}
    );
    try testing.expectEqual(@as(i64, 7), field(old, &.{"id"}).integer);
    try testing.expectEqualStrings(protocol_versions[0], field(old, &.{ "result", "protocolVersion" }).string);
}

test "notifications get no response" {
    const f = try Fixture.init();
    defer f.deinit();
    const s = testServer(f);
    try testing.expectEqual(@as(?[]const u8, null), try s.handleMessage(f.arena(),
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ));
    try testing.expectEqual(@as(?[]const u8, null), try s.handleMessage(f.arena(),
        \\{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}
    ));
}

test "ping" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try roundTrip(f,
        \\{"jsonrpc":"2.0","id":3,"method":"ping"}
    );
    try testing.expectEqual(@as(usize, 0), field(r, &.{"result"}).object.count());
}

test "errors" {
    const f = try Fixture.init();
    defer f.deinit();

    const parse = try roundTrip(f, "{not json");
    try testing.expectEqual(@as(i64, -32700), errorCode(parse));
    try testing.expect(field(parse, &.{"id"}) == .null);

    const arr = try roundTrip(f, "[1]");
    try testing.expectEqual(@as(i64, -32600), errorCode(arr));
    try testing.expect(field(arr, &.{"id"}) == .null);

    const ver = try roundTrip(f,
        \\{"jsonrpc":"1.0","id":4,"method":"ping"}
    );
    try testing.expectEqual(@as(i64, -32600), errorCode(ver));

    const no_method = try roundTrip(f,
        \\{"jsonrpc":"2.0","id":5}
    );
    try testing.expectEqual(@as(i64, -32600), errorCode(no_method));

    const unknown = try roundTrip(f,
        \\{"jsonrpc":"2.0","id":1,"method":"nope"}
    );
    try testing.expectEqual(@as(i64, -32601), errorCode(unknown));
    try testing.expectEqual(@as(i64, 1), field(unknown, &.{"id"}).integer);

    const bad_tool = try roundTrip(f,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"git_nope","arguments":{}}}
    );
    try testing.expectEqual(@as(i64, -32602), errorCode(bad_tool));

    const no_name = try roundTrip(f,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"arguments":{}}}
    );
    try testing.expectEqual(@as(i64, -32602), errorCode(no_name));

    const bad_args = try roundTrip(f,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"git_status","arguments":[1]}}
    );
    try testing.expectEqual(@as(i64, -32602), errorCode(bad_args));
}

test "tools/list returns parseable schemas for every tool" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try roundTrip(f,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    );
    const list = field(r, &.{ "result", "tools" }).array.items;
    try testing.expectEqual(registry.all.len, list.len);
    for (list) |t| {
        try testing.expect(field(t, &.{"name"}).string.len > 0);
        try testing.expect(field(t, &.{"description"}).string.len > 0);
        try testing.expectEqualStrings("object", field(t, &.{ "inputSchema", "type" }).string);
    }
    try testing.expectEqualStrings("git_status", field(list[0], &.{"name"}).string);
}

test "tool validation failure is an isError result" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try roundTrip(f,
        \\{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"git_status","arguments":{"repo":"relative"}}}
    );
    try testing.expectEqual(true, field(r, &.{ "result", "isError" }).bool);
    const content = field(r, &.{ "result", "content" }).array.items;
    try testing.expectEqualStrings("text", field(content[0], &.{"type"}).string);
    try testing.expect(std.mem.indexOf(u8, field(content[0], &.{"text"}).string, "absolute host path") != null);
}

test "tools/call runs the tool" {
    const f = try Fixture.init();
    defer f.deinit();
    const repo = try f.initRepo("r");
    const line = try std.fmt.allocPrint(f.arena(),
        \\{{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{{"name":"git_status","arguments":{{"repo":"{s}","ignored_key":1}}}}}}
    , .{repo});
    const r = try roundTrip(f, line);
    try testing.expectEqual(false, field(r, &.{ "result", "isError" }).bool);
    const content = field(r, &.{ "result", "content" }).array.items;
    try testing.expect(std.mem.indexOf(u8, field(content[0], &.{"text"}).string, "On branch main") != null);
}

test "internal error response recovers the request id" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const num = internalErrorResponse(a,
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call"}
    ).?;
    const v = try json.parseFromSliceLeaky(json.Value, a, num, .{});
    try testing.expectEqual(@as(i64, 5), field(v, &.{"id"}).integer);
    try testing.expectEqual(@as(i64, -32603), errorCode(v));

    const str = try json.parseFromSliceLeaky(json.Value, a, internalErrorResponse(a,
        \\{"jsonrpc":"2.0","id":"x","method":"tools/call"}
    ).?, .{});
    try testing.expectEqualStrings("x", field(str, &.{"id"}).string);

    // Unrecoverable id: answered with id null.
    const bad = try json.parseFromSliceLeaky(json.Value, a, internalErrorResponse(a, "{nope").?, .{});
    try testing.expect(field(bad, &.{"id"}) == .null);
    try testing.expectEqual(@as(i64, -32603), errorCode(bad));

    // Notifications are never answered.
    try testing.expectEqual(@as(?[]const u8, null), internalErrorResponse(a,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    ));

    const fixed = try json.parseFromSliceLeaky(json.Value, a, internal_error_response, .{});
    try testing.expect(field(fixed, &.{"id"}) == .null);
    try testing.expectEqual(@as(i64, -32603), errorCode(fixed));
}
