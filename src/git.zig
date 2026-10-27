//! Runs git as a child process with a fixed prefix, a non-interactive
//! environment, an absolute deadline, process-group kill, and capped capture.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const local_timeout_ms: u64 = 30_000;
pub const network_timeout_ms: u64 = 120_000;
pub const capture_cap: usize = 1024 * 1024;

pub const RunOpts = struct {
    cwd: []const u8,
    /// Everything after the fixed `git --no-pager -c … -c …` prefix.
    args: []const []const u8,
    /// Selects the network timeout and the batch-ssh logic.
    network: bool = false,
    /// Override (tests).
    timeout_ms: ?u64 = null,
};

pub const Result = struct {
    /// null if signaled or timed out.
    exit_code: ?u8,
    stdout: []const u8,
    stderr: []const u8,
    timed_out: bool = false,
    /// True if either stream exceeded `capture_cap`.
    truncated: bool = false,
    /// The deadline that applied, so a timeout can be reported.
    timeout_ms: u64 = 0,
};

/// Explicit because `run` and `needsBatchSsh` call each other.
pub const Error = Allocator.Error || std.process.SpawnError ||
    Io.File.MultiReader.FillError || Io.File.MultiReader.UnendingError || Io.Cancelable;

pub const Runner = struct {
    io: Io,
    /// Base environment for children.
    env: *const std.process.Environ.Map,
    git_exe: []const u8 = "git",

    pub fn run(r: *const Runner, arena: Allocator, opts: RunOpts) Error!Result {
        const io = r.io;

        var argv: std.ArrayList([]const u8) = .empty;
        try argv.ensureTotalCapacity(arena, prefix.len + 1 + opts.args.len);
        argv.appendAssumeCapacity(r.git_exe);
        argv.appendSliceAssumeCapacity(&prefix);
        argv.appendSliceAssumeCapacity(opts.args);

        var env = try r.env.clone(arena);
        for (fixed_env) |kv| try env.put(kv[0], kv[1]);
        if (opts.network and try r.needsBatchSsh(arena, opts.cwd)) {
            try env.put("GIT_SSH_COMMAND", "ssh -o BatchMode=yes");
        }

        const timeout_ms = opts.timeout_ms orelse
            if (opts.network) network_timeout_ms else local_timeout_ms;
        // One absolute deadline for the whole invocation.
        const deadline = (Io.Timeout{ .duration = .{
            .raw = .fromMilliseconds(@intCast(timeout_ms)),
            .clock = .awake,
        } }).toDeadline(io).deadline;

        var child = try std.process.spawn(io, .{
            .argv = argv.items,
            .cwd = .{ .path = opts.cwd },
            .environ_map = &env,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
            // setpgid(0): the child leads a new group whose id is its pid.
            .pgid = 0,
        });
        const pid = child.id.?;
        // Set once git has been reaped by hand; `child.wait`/`child.kill`
        // must never be called after that (it would wait on the pid again).
        var term: ?std.process.Child.Term = null;

        var mr_buf: Io.File.MultiReader.Buffer(2) = undefined;
        var mr: Io.File.MultiReader = undefined;
        mr.init(arena, io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });

        defer {
            // Only reached without a reap on an error path: kill and reap.
            if (term == null) {
                killGroup(pid);
                _ = reap(pid, false);
            }
            mr.deinit();
            child.stdout.?.close(io);
            child.stderr.?.close(io);
            child.stdout = null;
            child.stderr = null;
            child.id = null;
        }

        var caps: [2]Capture = .{ .{}, .{} };
        var eof = false;
        var timed_out = false;
        // Set once git has exited: bounds the final drain.
        var drain_until: ?Io.Clock.Timestamp = null;

        while (true) {
            const now = Io.Clock.Timestamp.now(io, .awake);
            if (term == null) {
                term = reap(pid, true);
                if (term != null) drain_until = now.addDuration(slice);
            }
            if (term != null) {
                if (eof or now.compare(.gte, drain_until.?)) break;
            } else if (now.compare(.gte, deadline)) {
                killGroup(pid);
                term = reap(pid, false);
                timed_out = true;
                break;
            }

            var slice_end = now.addDuration(slice);
            const limit = drain_until orelse deadline;
            if (limit.compare(.lt, slice_end)) slice_end = limit;

            if (eof) {
                // Pipes closed but git not yet reaped: poll for its exit.
                const poll_end = now.addDuration(poll_interval);
                const wait_until = if (slice_end.compare(.lt, poll_end)) slice_end else poll_end;
                try wait_until.wait(io);
                continue;
            }

            mr.fill(64 * 1024, .{ .deadline = slice_end }) catch |err| switch (err) {
                error.Timeout => {},
                error.EndOfStream => eof = true,
                else => |e| return e,
            };
            for (&caps, 0..) |*cap, i| try cap.take(arena, mr.reader(i));
        }
        try mr.checkAnyError();

        return .{
            .exit_code = if (timed_out) null else switch (term.?) {
                .exited => |code| code,
                else => null,
            },
            .stdout = caps[0].buf.items,
            .stderr = caps[1].buf.items,
            .timed_out = timed_out,
            .truncated = caps[0].truncated or caps[1].truncated,
            .timeout_ms = timeout_ms,
        };
    }

    /// True unless the user already chose an ssh command: `GIT_SSH_COMMAND`
    /// or `GIT_SSH` in the environment, or `core.sshCommand` set for `cwd`.
    pub fn needsBatchSsh(r: *const Runner, arena: Allocator, cwd: []const u8) Error!bool {
        if (r.env.get("GIT_SSH_COMMAND") != null or r.env.get("GIT_SSH") != null) return false;
        const res = try r.run(arena, .{ .cwd = cwd, .args = &.{ "config", "--get", "core.sshCommand" } });
        return std.mem.trim(u8, res.stdout, " \t\r\n").len == 0;
    }
};

const prefix = [_][]const u8{ "--no-pager", "-c", "core.quotepath=false", "-c", "color.ui=never" };

const fixed_env = [_][2][]const u8{
    .{ "GIT_TERMINAL_PROMPT", "0" },
    .{ "GIT_EDITOR", "true" },
    .{ "GIT_SEQUENCE_EDITOR", "true" },
    .{ "GIT_PAGER", "cat" },
    .{ "GIT_MERGE_AUTOEDIT", "no" },
};

/// Read slice length, and the bound on the final drain after git exits.
const slice: Io.Clock.Duration = .{ .raw = .fromMilliseconds(250), .clock = .awake };
/// How often to check for exit once both pipes are at EOF.
const poll_interval: Io.Clock.Duration = .{ .raw = .fromMilliseconds(10), .clock = .awake };

/// Keeps the first `capture_cap` bytes of a stream and discards the rest,
/// draining the reader every time so git never blocks on a full pipe.
const Capture = struct {
    buf: std.ArrayList(u8) = .empty,
    truncated: bool = false,

    fn take(c: *Capture, arena: Allocator, reader: *Io.Reader) !void {
        const data = reader.buffered();
        const room = capture_cap - c.buf.items.len;
        const keep = @min(room, data.len);
        try c.buf.appendSlice(arena, data[0..keep]);
        if (keep < data.len) c.truncated = true;
        reader.toss(data.len);
    }
};

/// SIGKILL the whole process group led by `pid` (git plus ssh, hooks, …).
/// Errors are ignored: the group may already be gone.
fn killGroup(pid: std.posix.pid_t) void {
    std.posix.kill(-pid, .KILL) catch {};
}

/// waitpid on `pid`; with `nohang`, returns null if it is still running.
/// On macOS `posix.system.waitpid` is `std.c.waitpid` (std.posix.waitpid
/// no longer exists in 0.17).
fn reap(pid: std.posix.pid_t, comptime nohang: bool) ?std.process.Child.Term {
    const posix = std.posix;
    var status: if (@import("builtin").link_libc) c_int else i32 = undefined;
    const flags = if (nohang) posix.W.NOHANG else 0;
    while (true) {
        const rc = posix.system.waitpid(pid, &status, flags);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return null; // WNOHANG: still running
                return std.Io.Threaded.statusToTerm(@bitCast(status));
            },
            .INTR => continue,
            // ECHILD would mean a double reap; treat as gone.
            else => return .{ .unknown = 0 },
        }
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const Fixture = @import("testutil.zig").Fixture;

fn elapsedMs(start: Io.Clock.Timestamp) i64 {
    return start.untilNow(testing.io).raw.toMilliseconds();
}

/// True once no process matches `pattern` (retries briefly: killed
/// processes may take a moment to be reaped).
fn noProcessMatching(pattern: []const u8) !bool {
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const res = try std.process.run(testing.allocator, testing.io, .{ .argv = &.{ "pgrep", "-f", pattern } });
        testing.allocator.free(res.stdout);
        testing.allocator.free(res.stderr);
        if (res.term == .exited and res.term.exited == 1) return true;
        try testing.io.sleep(.fromMilliseconds(50), .awake);
    }
    return false;
}

fn pkill(pattern: []const u8) void {
    const res = std.process.run(testing.allocator, testing.io, .{ .argv = &.{ "pkill", "-f", pattern } }) catch return;
    testing.allocator.free(res.stdout);
    testing.allocator.free(res.stderr);
}

test "runs git and captures stdout" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    const res = try f.runner.run(f.arena(), .{ .cwd = r, .args = &.{ "rev-parse", "--is-inside-work-tree" } });
    try testing.expectEqual(@as(?u8, 0), res.exit_code);
    try testing.expectEqualStrings("true\n", res.stdout);
    try testing.expect(!res.timed_out);
    try testing.expect(!res.truncated);
}

test "nonzero exit is reported, not an error" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    const res = try f.runner.run(f.arena(), .{ .cwd = r, .args = &.{ "rev-parse", "--verify", "nope" } });
    try testing.expectEqual(@as(?u8, 128), res.exit_code);
    try testing.expect(res.stderr.len > 0);
}

test "sets non-interactive env" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    const ed = try f.runner.run(f.arena(), .{ .cwd = r, .args = &.{ "var", "GIT_EDITOR" } });
    try testing.expectEqual(@as(?u8, 0), ed.exit_code);
    try testing.expectEqualStrings("true\n", ed.stdout);

    const env = try f.runner.run(f.arena(), .{ .cwd = r, .args = &.{ "-c", "alias.e=!env", "e" } });
    try testing.expectEqual(@as(?u8, 0), env.exit_code);
    for ([_][]const u8{
        "GIT_TERMINAL_PROMPT=0\n",
        "GIT_EDITOR=true\n",
        "GIT_SEQUENCE_EDITOR=true\n",
        "GIT_PAGER=cat\n",
        "GIT_MERGE_AUTOEDIT=no\n",
    }) |want| {
        if (std.mem.indexOf(u8, env.stdout, want) == null) {
            std.debug.print("missing {s}", .{want});
            return error.TestExpectedEnv;
        }
    }
    // Local ops never get the batch-ssh override.
    try testing.expect(std.mem.indexOf(u8, env.stdout, "GIT_SSH_COMMAND=") == null);
}

test "times out and kills the process group" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    const start = Io.Clock.Timestamp.now(testing.io, .awake);
    const res = try f.runner.run(f.arena(), .{
        .cwd = r,
        .args = &.{ "-c", "alias.slp=!sleep 31 & sleep 31", "slp" },
        .timeout_ms = 500,
    });
    const ms = elapsedMs(start);
    try testing.expect(res.timed_out);
    try testing.expectEqual(@as(?u8, null), res.exit_code);
    try testing.expect(ms >= 400);
    try testing.expect(ms < 3000);
    try testing.expect(try noProcessMatching("sleep 31"));
}

test "returns promptly when grandchild keeps stderr open" {
    const f = try Fixture.init();
    defer f.deinit();
    // The detached grandchild deliberately outlives git; kill it afterwards.
    defer pkill("sleep 32");
    const r = try f.initRepo("r");
    const start = Io.Clock.Timestamp.now(testing.io, .awake);
    const res = try f.runner.run(f.arena(), .{
        .cwd = r,
        .args = &.{ "-c", "alias.bg=!echo hi; (sleep 32 >&2 &)", "bg" },
        .timeout_ms = 10_000,
    });
    const ms = elapsedMs(start);
    try testing.expectEqual(@as(?u8, 0), res.exit_code);
    try testing.expect(!res.timed_out);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "hi") != null);
    try testing.expect(ms < 3000);
}

test "caps captured output" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    const res = try f.runner.run(f.arena(), .{
        .cwd = r,
        .args = &.{ "-c", "alias.big=!head -c 3000000 /dev/zero | tr '\\0' a", "big" },
    });
    try testing.expectEqual(@as(?u8, 0), res.exit_code);
    try testing.expect(res.truncated);
    try testing.expectEqual(capture_cap, res.stdout.len);
    try testing.expect(std.mem.allEqual(u8, res.stdout, 'a'));
}

test "needsBatchSsh respects user config" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try testing.expect(try f.runner.needsBatchSsh(f.arena(), r));

    _ = try f.git(r, &.{ "config", "core.sshCommand", "ssh -i x" });
    try testing.expect(!try f.runner.needsBatchSsh(f.arena(), r));

    const r2 = try f.initRepo("r2");
    var env2 = try f.env.clone(f.arena());
    try env2.put("GIT_SSH_COMMAND", "ssh -i y");
    const runner2: Runner = .{ .io = testing.io, .env = &env2 };
    try testing.expect(!try runner2.needsBatchSsh(f.arena(), r2));

    var env3 = try f.env.clone(f.arena());
    try env3.put("GIT_SSH", "/bin/false");
    const runner3: Runner = .{ .io = testing.io, .env = &env3 };
    try testing.expect(!try runner3.needsBatchSsh(f.arena(), r2));
}

test "network ops get batch-mode ssh unless configured" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    const res = try f.runner.run(f.arena(), .{ .cwd = r, .args = &.{ "-c", "alias.e=!env", "e" }, .network = true });
    try testing.expectEqual(@as(?u8, 0), res.exit_code);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "GIT_SSH_COMMAND=ssh -o BatchMode=yes\n") != null);

    _ = try f.git(r, &.{ "config", "core.sshCommand", "ssh -i x" });
    const res2 = try f.runner.run(f.arena(), .{ .cwd = r, .args = &.{ "-c", "alias.e=!env", "e" }, .network = true });
    try testing.expectEqual(@as(?u8, 0), res2.exit_code);
    try testing.expect(std.mem.indexOf(u8, res2.stdout, "GIT_SSH_COMMAND=") == null);
}
