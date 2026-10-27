//! Shared tool framework: the handler signature, per-call context, and the
//! conversion of git results into MCP tool results.
const std = @import("std");
const Allocator = std.mem.Allocator;
const git_mod = @import("../git.zig");
const validate = @import("../validate.zig");
const text = @import("../text.zig");
pub const Args = @import("Args.zig");

/// Cap on text returned to the agent.
pub const output_cap: usize = 100 * 1024;
pub const truncation_note = "\n\u{2026} [output truncated at 100 KiB; narrow the request with paths, max_count, or stat_only]";

pub const ToolResult = struct { text: []const u8, is_error: bool = false };
pub const Handler = *const fn (ctx: *Ctx, args: Args) anyerror!ToolResult;
pub const Tool = struct { name: []const u8, description: []const u8, schema: []const u8, handler: Handler };

/// JSON fragment for the `repo` property shared by every repo-scoped tool.
pub const repo_prop =
    \\"repo":{"type":"string","description":"Absolute path to the repository on the HOST machine (or ~/…). Not a sandbox path."}
;

pub const Ctx = struct {
    arena: Allocator,
    runner: *const git_mod.Runner,
    home: ?[]const u8,
    diag: validate.Diag = .{},

    /// The required `repo` argument, resolved to an existing host directory.
    pub fn repo(ctx: *Ctx, args: Args) ![]const u8 {
        const raw = try args.reqStr("repo");
        return validate.resolveRepo(ctx.arena, ctx.runner.io, ctx.home, raw, &ctx.diag);
    }

    /// Runs git in `cwd` and formats the outcome as a tool result.
    pub fn git(ctx: *Ctx, cwd: []const u8, args: []const []const u8, network: bool) !ToolResult {
        const r = try ctx.runner.run(ctx.arena, .{ .cwd = cwd, .args = args, .network = network });
        return formatResult(ctx.arena, r);
    }

    /// Like `git` for local ops that run hooks (commit, merge, rebase,
    /// cherry-pick, revert, stash, switch): they get the longer timeout.
    pub fn gitLong(ctx: *Ctx, cwd: []const u8, args: []const []const u8) !ToolResult {
        const r = try ctx.runner.run(ctx.arena, .{ .cwd = cwd, .args = args, .long = true });
        return formatResult(ctx.arena, r);
    }

    /// Records a validation message and returns `error.Invalid`.
    pub fn fail(ctx: *Ctx, comptime fmt: []const u8, a: anytype) error{Invalid} {
        ctx.diag.msg = std.fmt.allocPrint(ctx.arena, fmt, a) catch "invalid arguments (out of memory formatting message)";
        return error.Invalid;
    }
};

/// exit 0: stdout (plus stderr under a marker); otherwise an error naming
/// the exit code, signal, or timeout, followed by stderr and stdout. The
/// text is valid UTF-8 and capped at `output_cap`.
pub fn formatResult(arena: Allocator, r: git_mod.Result) !ToolResult {
    var out: std.ArrayList(u8) = .empty;
    var is_error = true;
    if (r.timed_out) {
        try out.print(arena, "git timed out after {d}s and was stopped. If git was interrupted, a stale .git/*.lock file may need removing.\n", .{r.timeout_ms / 1000});
        try out.appendSlice(arena, r.stderr);
        try out.appendSlice(arena, r.stdout);
    } else if (r.exit_code) |code| {
        if (code == 0) {
            is_error = false;
            try out.appendSlice(arena, r.stdout);
            if (r.stderr.len > 0) {
                try out.appendSlice(arena, "\n[stderr]\n");
                try out.appendSlice(arena, r.stderr);
            }
            if (out.items.len == 0) try out.appendSlice(arena, "OK (no output)");
        } else {
            try out.print(arena, "git exited with code {d}\n", .{code});
            try out.appendSlice(arena, r.stderr);
            try out.appendSlice(arena, r.stdout);
        }
    } else {
        try out.appendSlice(arena, "git was terminated by a signal\n");
        try out.appendSlice(arena, r.stderr);
        try out.appendSlice(arena, r.stdout);
    }

    const clean = try text.sanitizeUtf8(arena, out.items);
    const t = text.truncate(clean, output_cap);
    const result_text = if (t.truncated or r.truncated)
        try std.mem.concat(arena, u8, &.{ t.text, truncation_note })
    else
        t.text;
    return .{ .text = result_text, .is_error = is_error };
}

/// Runs `tool` and maps its errors to tool results: `error.Invalid` becomes
/// the validation message, a failure to start git names `git_exe`, and
/// anything else is an internal error. The text is
/// always valid UTF-8 (it is embedded in JSON).
pub fn invoke(ctx: *Ctx, tool: Tool, args: Args) !ToolResult {
    var res = tool.handler(ctx, args) catch |err| switch (err) {
        error.Invalid => ToolResult{ .text = try ctx.arena.dupe(u8, ctx.diag.msg), .is_error = true },
        else => ToolResult{
            .text = if (isSpawnError(err))
                try std.fmt.allocPrint(ctx.arena, "could not run git ('{s}'): {s}; set GIT_MCP_GIT or PATH", .{ ctx.runner.git_exe, @errorName(err) })
            else
                try std.fmt.allocPrint(ctx.arena, "internal error: {s}", .{@errorName(err)}),
            .is_error = true,
        },
    };
    res.text = try text.sanitizeUtf8(ctx.arena, res.text);
    return res;
}

/// True for errors in `std.process.SpawnError` (git not found, not
/// executable, …). Handlers do no file I/O of their own that can fail this
/// way; only reading git's pipes shares a few of these names.
fn isSpawnError(err: anyerror) bool {
    if (err == error.OutOfMemory or err == error.Canceled) return false;
    inline for (comptime @typeInfo(std.process.SpawnError).error_set.error_names.?) |name| {
        if (err == @field(anyerror, name)) return true;
    }
    return false;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "formatResult success, stderr, empty" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const ok = try formatResult(a, .{ .exit_code = 0, .stdout = "out\n", .stderr = "" });
    try testing.expect(!ok.is_error);
    try testing.expectEqualStrings("out\n", ok.text);

    const warn = try formatResult(a, .{ .exit_code = 0, .stdout = "out\n", .stderr = "warn\n" });
    try testing.expectEqualStrings("out\n\n[stderr]\nwarn\n", warn.text);

    const empty = try formatResult(a, .{ .exit_code = 0, .stdout = "", .stderr = "" });
    try testing.expectEqualStrings("OK (no output)", empty.text);
}

test "formatResult failure, signal, timeout" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const bad = try formatResult(a, .{ .exit_code = 128, .stdout = "o", .stderr = "fatal: x\n" });
    try testing.expect(bad.is_error);
    try testing.expectEqualStrings("git exited with code 128\nfatal: x\no", bad.text);

    const sig = try formatResult(a, .{ .exit_code = null, .stdout = "", .stderr = "e" });
    try testing.expect(sig.is_error);
    try testing.expect(std.mem.startsWith(u8, sig.text, "git was terminated by a signal\n"));

    const to = try formatResult(a, .{ .exit_code = null, .stdout = "part", .stderr = "", .timed_out = true, .timeout_ms = 30_000 });
    try testing.expect(to.is_error);
    try testing.expectEqualStrings("git timed out after 30s and was stopped. If git was interrupted, a stale .git/*.lock file may need removing.\npart", to.text);
}

test "formatResult sanitizes and truncates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const bad_utf8 = try formatResult(a, .{ .exit_code = 0, .stdout = "a\xffb", .stderr = "" });
    try testing.expectEqualStrings("a\u{FFFD}b", bad_utf8.text);

    const big = try a.alloc(u8, output_cap + 10);
    @memset(big, 'x');
    const t = try formatResult(a, .{ .exit_code = 0, .stdout = big, .stderr = "" });
    try testing.expect(std.mem.endsWith(u8, t.text, truncation_note));
    try testing.expectEqual(output_cap + truncation_note.len, t.text.len);

    const capped = try formatResult(a, .{ .exit_code = 0, .stdout = "short", .stderr = "", .truncated = true });
    try testing.expectEqualStrings("short" ++ truncation_note, capped.text);
}

test "a git that cannot be spawned gets a clear message" {
    const Fixture = @import("../testutil.zig").Fixture;
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    f.runner.git_exe = "/nonexistent/git";
    const want = "could not run git ('/nonexistent/git'): FileNotFound; set GIT_MCP_GIT or PATH";
    // A plain run, and push, whose helper queries run git first.
    for ([_][]const u8{ "git_status", "git_push" }) |tool| {
        const res = try f.call(tool, try std.fmt.allocPrint(f.arena(), "{{\"repo\":\"{s}\"}}", .{r}));
        try testing.expect(res.is_error);
        try testing.expectEqualStrings(want, res.text);
    }
}
