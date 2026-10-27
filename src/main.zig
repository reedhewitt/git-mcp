const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const git = @import("git.zig");
const mcp = @import("mcp.zig");
const registry = @import("tools/registry.zig");

/// Longest accepted JSON-RPC message (one line).
const max_line = 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena_perm = init.arena.allocator();
    const env = init.environ_map;

    // GUI-launched hosts may not pass SSH_AUTH_SOCK; ask launchd once.
    var ssh_state: []const u8 = if (env.get("SSH_AUTH_SOCK") != null) "set" else "unset";
    if (builtin.os.tag == .macos and env.get("SSH_AUTH_SOCK") == null) {
        if (launchctlSshAuthSock(arena_perm, io)) |sock| {
            try env.put("SSH_AUTH_SOCK", sock);
            ssh_state = "from launchctl";
        }
    }

    const runner: git.Runner = .{
        .io = io,
        .env = env,
        .git_exe = env.get("GIT_MCP_GIT") orelse "git",
    };
    const server: mcp.Server = .{ .runner = &runner, .home = env.get("HOME"), .tools = registry.all };

    // Diagnostics go to stderr; never log values, only presence.
    const banner = try std.fmt.allocPrint(arena_perm, "{s} {s} git={s} PATH={s} SSH_AUTH_SOCK={s}\n", .{
        mcp.server_name,
        mcp.server_version,
        runner.git_exe,
        if (env.get("PATH") != null) "set" else "unset",
        ssh_state,
    });
    logStderr(io, banner);

    const in_buf = try arena_perm.alloc(u8, max_line);
    var stdin = Io.File.stdin().readerStreaming(io, in_buf);
    var out_buf: [64 * 1024]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;

    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();

    while (true) {
        _ = arena_state.reset(.retain_capacity);
        const raw = stdin.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                try out.writeAll(mcp.too_long_response ++ "\n");
                try out.flush();
                _ = stdin.interface.discardDelimiterInclusive('\n') catch |e| switch (e) {
                    error.EndOfStream => return,
                    error.ReadFailed => return stdin.err.?,
                };
                continue;
            },
            error.ReadFailed => return stdin.err.?,
        } orelse return; // EOF: exit 0
        const line = if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw;
        if (std.mem.trim(u8, line, " \t").len == 0) continue;

        const response = server.handleMessage(arena_state.allocator(), line) catch |err| {
            var buf: [128]u8 = undefined;
            logStderr(io, std.fmt.bufPrint(&buf, "git-mcp: failed to handle message: {s}\n", .{@errorName(err)}) catch "git-mcp: failed to handle message\n");
            continue;
        };
        if (response) |r| {
            try out.writeAll(r);
            try out.writeAll("\n");
            try out.flush();
        }
    }
}

fn logStderr(io: Io, msg: []const u8) void {
    Io.File.stderr().writeStreamingAll(io, msg) catch {};
}

/// `launchctl getenv SSH_AUTH_SOCK`, trimmed; null if unavailable or empty.
fn launchctlSshAuthSock(arena: std.mem.Allocator, io: Io) ?[]const u8 {
    const res = std.process.run(arena, io, .{
        .argv = &.{ "/bin/launchctl", "getenv", "SSH_AUTH_SOCK" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return null;
    if (res.term != .exited or res.term.exited != 0) return null;
    const sock = std.mem.trim(u8, res.stdout, " \t\r\n");
    return if (sock.len == 0) null else sock;
}

test {
    _ = @import("text.zig");
    _ = @import("validate.zig");
    _ = @import("git.zig");
    _ = @import("testutil.zig");
    _ = @import("mcp.zig");
    _ = @import("tools/common.zig");
    _ = @import("tools/Args.zig");
    _ = @import("tools/registry.zig");
    _ = @import("tools/inspect.zig");
    _ = @import("tools/sync.zig");
    _ = @import("tools/stage.zig");
    _ = @import("tools/branch.zig");
    _ = @import("tools/integrate.zig");
    _ = @import("tools/guard_test.zig");
}
