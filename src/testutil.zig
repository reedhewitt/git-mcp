//! Test-only helpers: a temp directory with an isolated git environment.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const git_mod = @import("git.zig");

pub const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    root: []const u8,
    env: std.process.Environ.Map,
    runner: git_mod.Runner,

    /// Heap-allocated so `runner.env` can point at `env`. `deinit` frees it.
    pub fn init() !*Fixture {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        const f = try gpa.create(Fixture);
        errdefer gpa.destroy(f);

        f.arena_state = .init(gpa);
        errdefer f.arena_state.deinit();
        const a = f.arena_state.allocator();

        f.tmp = std.testing.tmpDir(.{});
        errdefer f.tmp.cleanup();

        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const n = try f.tmp.dir.realPath(io, &buf);
        f.root = try a.dupe(u8, buf[0..n]);

        f.env = try std.testing.environ.createMap(a);
        try f.env.put("HOME", f.root);
        try f.env.put("GIT_CONFIG_GLOBAL", "/dev/null");
        try f.env.put("GIT_CONFIG_NOSYSTEM", "1");
        try f.env.put("GIT_AUTHOR_NAME", "Test");
        try f.env.put("GIT_COMMITTER_NAME", "Test");
        try f.env.put("GIT_AUTHOR_EMAIL", "test@example.com");
        try f.env.put("GIT_COMMITTER_EMAIL", "test@example.com");
        _ = f.env.swapRemove("GIT_SSH_COMMAND");
        _ = f.env.swapRemove("GIT_SSH");

        f.runner = .{ .io = io, .env = &f.env };
        return f;
    }

    pub fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
        f.arena_state.deinit();
        std.testing.allocator.destroy(f);
    }

    pub fn arena(f: *Fixture) Allocator {
        return f.arena_state.allocator();
    }

    /// Absolute path of `rel` inside the fixture root.
    pub fn path(f: *Fixture, rel: []const u8) []const u8 {
        return std.fs.path.join(f.arena(), &.{ f.root, rel }) catch @panic("OOM");
    }

    /// `git init -b main <rel>`; returns the absolute path.
    pub fn initRepo(f: *Fixture, rel: []const u8) ![]const u8 {
        const p = f.path(rel);
        _ = try f.git(f.root, &.{ "init", "-q", "-b", "main", p });
        return p;
    }

    /// `git init --bare -b main <rel>`; returns the absolute path.
    pub fn initBare(f: *Fixture, rel: []const u8) ![]const u8 {
        const p = f.path(rel);
        _ = try f.git(f.root, &.{ "init", "-q", "--bare", "-b", "main", p });
        return p;
    }

    /// Writes `contents` to `rel` (relative to the fixture root), creating parent dirs.
    pub fn writeFile(f: *Fixture, rel: []const u8, contents: []const u8) !void {
        try writeAbs(f.path(rel), contents);
    }

    /// Runs git in `cwd`; fails unless it exits 0. Returns stdout.
    pub fn git(f: *Fixture, cwd: []const u8, args: []const []const u8) ![]const u8 {
        const res = try f.runner.run(f.arena(), .{ .cwd = cwd, .args = args });
        if (res.exit_code == null or res.exit_code.? != 0) {
            std.debug.print("git {s} failed (exit {?d}): {s}\n", .{ args[0], res.exit_code, res.stderr });
            return error.GitFailed;
        }
        return res.stdout;
    }

    /// Writes `name` in `repo` (absolute), stages it, and commits with `msg`.
    pub fn commitFile(f: *Fixture, repo: []const u8, name: []const u8, contents: []const u8, msg: []const u8) !void {
        const p = std.fs.path.join(f.arena(), &.{ repo, name }) catch @panic("OOM");
        try writeAbs(p, contents);
        _ = try f.git(repo, &.{ "add", "--", name });
        const m = try std.fmt.allocPrint(f.arena(), "--message={s}", .{msg});
        _ = try f.git(repo, &.{ "commit", "-q", m });
    }

    fn writeAbs(abs: []const u8, contents: []const u8) !void {
        const io = std.testing.io;
        const cwd = Io.Dir.cwd();
        if (std.fs.path.dirname(abs)) |dir| try cwd.createDirPath(io, dir);
        try cwd.writeFile(io, .{ .sub_path = abs, .data = contents });
    }
};

test "fixture commits with isolated identity" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.commitFile(r, "a.txt", "hello\n", "first");
    const out = try f.git(r, &.{ "log", "-1", "--format=%an <%ae> %s" });
    try std.testing.expectEqualStrings("Test <test@example.com> first\n", out);
    const bare = try f.initBare("b.git");
    const is_bare = try f.git(bare, &.{ "rev-parse", "--is-bare-repository" });
    try std.testing.expectEqualStrings("true\n", is_bare);
}
