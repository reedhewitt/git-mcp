//! End-to-end: spawn the built binary and speak MCP over its stdio.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const build_options = @import("build_options");
const Fixture = @import("testutil").Fixture;

const Server = struct {
    child: std.process.Child,
    reader: Io.File.Reader,
    buf: []u8,

    /// Spawns the server with the fixture's isolated environment (HOME,
    /// git config, identity, GIT_CEILING_DIRECTORIES).
    fn start(f: *Fixture) !Server {
        const io = testing.io;
        var child = try std.process.spawn(io, .{
            .argv = &.{build_options.exe_path},
            .environ_map = &f.env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        errdefer child.kill(io);
        const buf = try f.arena().alloc(u8, 64 * 1024);
        return .{ .child = child, .reader = child.stdout.?.readerStreaming(io, buf), .buf = buf };
    }

    fn send(s: *Server, line: []const u8) !void {
        try s.child.stdin.?.writeStreamingAll(testing.io, line);
        try s.child.stdin.?.writeStreamingAll(testing.io, "\n");
    }

    fn recv(s: *Server, arena: std.mem.Allocator) !std.json.Value {
        const line = (try s.reader.interface.takeDelimiter('\n')) orelse return error.EndOfStream;
        return std.json.parseFromSliceLeaky(std.json.Value, arena, try arena.dupe(u8, line), .{});
    }

    /// Closes stdin and waits; the server must exit 0 on EOF.
    fn finish(s: *Server) !void {
        s.child.stdin.?.close(testing.io);
        s.child.stdin = null;
        const term = try s.child.wait(testing.io);
        try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);
    }
};

test "binary speaks MCP over stdio" {
    const f = try Fixture.init();
    defer f.deinit();
    const repo = try f.initRepo("my repo");
    try f.commitFile(repo, "a.txt", "a\n", "first");

    var s = try Server.start(f);
    errdefer s.child.kill(testing.io);
    try s.send(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"e2e","version":"1"}}}
    );
    try s.send(
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );
    try s.send(
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    );
    try s.send(try std.fmt.allocPrint(f.arena(),
        \\{{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{{"name":"git_status","arguments":{{"repo":"{s}"}}}}}}
    , .{repo}));

    const a = f.arena();
    const r1 = try s.recv(a);
    try testing.expectEqual(@as(i64, 1), r1.object.get("id").?.integer);
    try testing.expectEqualStrings("2025-06-18", r1.object.get("result").?.object.get("protocolVersion").?.string);

    const r2 = try s.recv(a);
    try testing.expectEqual(@as(i64, 2), r2.object.get("id").?.integer);
    var found = false;
    for (r2.object.get("result").?.object.get("tools").?.array.items) |t| {
        if (std.mem.eql(u8, t.object.get("name").?.string, "git_status")) found = true;
    }
    try testing.expect(found);

    const r3 = try s.recv(a);
    try testing.expectEqual(@as(i64, 3), r3.object.get("id").?.integer);
    const result = r3.object.get("result").?.object;
    try testing.expectEqual(false, result.get("isError").?.bool);
    const txt = result.get("content").?.array.items[0].object.get("text").?.string;
    try testing.expect(std.mem.indexOf(u8, txt, "On branch main") != null);

    try s.finish();
}

test "oversized line is rejected and server keeps serving" {
    const f = try Fixture.init();
    defer f.deinit();
    var s = try Server.start(f);
    errdefer s.child.kill(testing.io);

    const big = try f.arena().alloc(u8, 2 * 1024 * 1024);
    @memset(big, 'x');
    try s.send(big);
    try s.send(
        \\{"jsonrpc":"2.0","id":9,"method":"ping"}
    );

    const a = f.arena();
    const r1 = try s.recv(a);
    try testing.expectEqual(@as(i64, -32700), r1.object.get("error").?.object.get("code").?.integer);
    try testing.expect(r1.object.get("id").? == .null);
    const r2 = try s.recv(a);
    try testing.expectEqual(@as(i64, 9), r2.object.get("id").?.integer);
    try testing.expect(r2.object.get("result") != null);

    try s.finish();
}
