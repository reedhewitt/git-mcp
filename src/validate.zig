const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Diag = struct { msg: []const u8 = "" };
pub const Error = error{ Invalid, OutOfMemory };

fn fail(diag: *Diag, msg: []const u8) Error {
    diag.msg = msg;
    return error.Invalid;
}

/// Expands `~`, requires an absolute path, strips trailing slashes.
fn normalize(arena: Allocator, home: ?[]const u8, raw: []const u8, diag: *Diag) Error![]const u8 {
    var path: []const u8 = raw;
    if (std.mem.eql(u8, raw, "~") or std.mem.startsWith(u8, raw, "~/")) {
        const h = home orelse return fail(diag, "HOME is not set; pass an absolute path");
        path = try std.fmt.allocPrint(arena, "{s}{s}", .{ h, raw[1..] });
    }
    if (path.len == 0 or path[0] != '/') {
        return fail(diag, try std.fmt.allocPrint(
            arena,
            "path must be an absolute host path (got '{s}'); this server runs on the host, not in the sandbox",
            .{raw},
        ));
    }
    while (path.len > 1 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
    return path;
}

fn isDir(io: Io, path: []const u8) bool {
    var d = Io.Dir.openDirAbsolute(io, path, .{ .access_sub_paths = false }) catch return false;
    d.close(io);
    return true;
}

/// Resolves a repository path on the host. It must exist and be a directory.
pub fn resolveRepo(arena: Allocator, io: Io, home: ?[]const u8, raw: []const u8, diag: *Diag) Error![]const u8 {
    const path = try normalize(arena, home, raw, diag);
    if (!isDir(io, path)) {
        const hint = if (std.mem.startsWith(u8, path, "/sessions/"))
            " This looks like a sandbox mount path. Use the folder's real path on the host machine (for example /Users/<name>/\u{2026})."
        else
            "";
        return fail(diag, try std.fmt.allocPrint(
            arena,
            "'{s}' does not exist or is not a directory. This server runs on the host and needs the host path.{s}",
            .{ path, hint },
        ));
    }
    return path;
}

/// Resolves a clone/init target. The target may not exist, but its parent must.
pub fn resolveTarget(arena: Allocator, io: Io, home: ?[]const u8, raw: []const u8, diag: *Diag) Error![]const u8 {
    const path = try normalize(arena, home, raw, diag);
    const parent = std.fs.path.dirname(path) orelse return path;
    if (!isDir(io, parent)) {
        return fail(diag, try std.fmt.allocPrint(
            arena,
            "parent directory '{s}' does not exist on the host; this server runs on the host and needs the host path",
            .{parent},
        ));
    }
    return path;
}

/// Backing storage for formatted messages from the context-free checks, which
/// have no allocator. Single-threaded use: each message is read before the
/// next check runs.
threadlocal var msg_buf: [256]u8 = undefined;

fn failFmt(diag: *Diag, comptime fmt: []const u8, args: anytype) Error {
    diag.msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch "invalid input";
    return error.Invalid;
}

fn hasControl(value: []const u8) bool {
    for (value) |c| if (c < 0x20 or c == 0x7f) return true;
    return false;
}

pub fn checkName(kind: []const u8, value: []const u8, diag: *Diag) Error!void {
    if (value.len == 0) return failFmt(diag, "{s} name must not be empty", .{kind});
    if (value[0] == '-') return failFmt(diag, "{s} name must not start with '-'", .{kind});
    if (hasControl(value)) return failFmt(diag, "{s} name must not contain control characters", .{kind});
}

/// A branch to push: a plain branch name. `+` and `:` get a message about
/// force pushes and deletions; anything else must pass `checkBranch`.
pub fn checkPushBranch(value: []const u8, diag: *Diag) Error!void {
    try checkName("branch", value, diag);
    if (value[0] == '+' or std.mem.indexOfScalar(u8, value, ':') != null) {
        return fail(diag, "force pushes and remote deletions are not supported; run them in a terminal");
    }
    try checkBranch(value, diag);
}

/// A single, real branch name: `checkName` plus git's ref-format rules
/// (as `git check-ref-format --branch`), so no globs, refspecs, or ranges.
/// A leading `+` is rejected too: it would read as a forced refspec.
pub fn checkBranch(value: []const u8, diag: *Diag) Error!void {
    try checkName("branch", value, diag);
    if (!isValidBranchName(value)) {
        return fail(diag, "not a valid branch name: use a single branch name, without globs (*?[), refspecs (+ :), spaces, '..', '@{', or ~^\\");
    }
}

fn isValidBranchName(v: []const u8) bool {
    if (v[0] == '+' or std.mem.eql(u8, v, "@")) return false;
    if (v[0] == '/' or v[v.len - 1] == '/' or v[v.len - 1] == '.') return false;
    for ([_][]const u8{ "..", "//", "@{", "/." }) |seq| {
        if (std.mem.indexOf(u8, v, seq) != null) return false;
    }
    if (v[0] == '.') return false;
    for (v) |c| switch (c) {
        ' ', '~', '^', ':', '?', '*', '[', '\\' => return false,
        else => if (c < 0x20 or c == 0x7f) return false,
    };
    // No path component may end in ".lock".
    var it = std.mem.splitScalar(u8, v, '/');
    while (it.next()) |comp| if (std.mem.endsWith(u8, comp, ".lock")) return false;
    return true;
}

pub fn checkPath(value: []const u8, diag: *Diag) Error!void {
    if (value.len == 0) return fail(diag, "path must not be empty");
    if (std.mem.indexOfScalar(u8, value, 0) != null) return fail(diag, "path must not contain NUL bytes");
}

pub fn checkUrl(value: []const u8, diag: *Diag) Error!void {
    return checkName("url", value, diag);
}

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

test "resolveRepo" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "with space", .default_dir);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const p = try arena.dupe(u8, buf[0..n]);
    const home = std.fs.path.dirname(p).?;
    var diag: Diag = .{};

    try expectEqualStrings(p, try resolveRepo(arena, io, null, p, &diag));
    try expectEqualStrings(p, try resolveRepo(arena, io, null, try std.fmt.allocPrint(arena, "{s}/", .{p}), &diag));
    const tilde = try std.fmt.allocPrint(arena, "~/{s}", .{p[home.len + 1 ..]});
    try expectEqualStrings(p, try resolveRepo(arena, io, home, tilde, &diag));
    try expectEqualStrings(home, try resolveRepo(arena, io, home, "~", &diag));
    try expectEqualStrings("/", try resolveRepo(arena, io, null, "/", &diag));

    try expectError(error.Invalid, resolveRepo(arena, io, null, "~/x", &diag));
    try expect(std.mem.indexOf(u8, diag.msg, "HOME is not set") != null);

    try expectError(error.Invalid, resolveRepo(arena, io, null, "relative/x", &diag));
    try expect(std.mem.indexOf(u8, diag.msg, "absolute host path") != null);

    try expectError(error.Invalid, resolveRepo(arena, io, null, try std.fmt.allocPrint(arena, "{s}/nope", .{p}), &diag));
    try expect(std.mem.indexOf(u8, diag.msg, "host path") != null);
    try expect(std.mem.indexOf(u8, diag.msg, "sandbox mount path") == null);

    try expectError(error.Invalid, resolveRepo(arena, io, null, "/sessions/abc/mnt/kb", &diag));
    try expect(std.mem.indexOf(u8, diag.msg, "sandbox mount path") != null);

    const spaced = try std.fmt.allocPrint(arena, "{s}/with space", .{p});
    try expectEqualStrings(spaced, try resolveRepo(arena, io, null, spaced, &diag));

    // A file is not a directory.
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "x" });
    try expectError(error.Invalid, resolveRepo(arena, io, null, try std.fmt.allocPrint(arena, "{s}/f.txt", .{p}), &diag));
}

test "resolveTarget allows a missing leaf but not a missing parent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const p = try arena.dupe(u8, buf[0..n]);
    var diag: Diag = .{};

    const fresh = try std.fmt.allocPrint(arena, "{s}/newrepo", .{p});
    try expectEqualStrings(fresh, try resolveTarget(arena, io, null, fresh, &diag));
    try expectEqualStrings(fresh, try resolveTarget(arena, io, null, try std.fmt.allocPrint(arena, "{s}/", .{fresh}), &diag));

    try expectError(error.Invalid, resolveTarget(arena, io, null, try std.fmt.allocPrint(arena, "{s}/no/such/x", .{p}), &diag));
    try expect(std.mem.indexOf(u8, diag.msg, "parent") != null);
    try expectError(error.Invalid, resolveTarget(arena, io, null, "rel/x", &diag));
    try expect(std.mem.indexOf(u8, diag.msg, "absolute host path") != null);
}

test "checkName / checkPushBranch / checkUrl" {
    var diag: Diag = .{};
    for ([_][]const u8{ "main", "feature/x", "HEAD~2", "a..b", "stash@{0}" }) |ok| {
        try checkName("branch", ok, &diag);
    }
    for ([_][]const u8{ "-f", "--force", "", "a\nb", "a\x7fb" }) |bad| {
        try expectError(error.Invalid, checkName("branch", bad, &diag));
    }
    try expectError(error.Invalid, checkName("branch", "-f", &diag));
    try expectEqualStrings("branch name must not start with '-'", diag.msg);

    try checkPushBranch("main", &diag);
    for ([_][]const u8{ "+main", "main:other", ":main" }) |bad| {
        try expectError(error.Invalid, checkPushBranch(bad, &diag));
        try expect(std.mem.indexOf(u8, diag.msg, "terminal") != null);
    }
    try expectError(error.Invalid, checkPushBranch("-x", &diag));

    try expectError(error.Invalid, checkUrl("-uexample", &diag));
    try checkUrl("git@example.com:o/r.git", &diag);
    try checkUrl("https://example.com/r.git", &diag);
}

test "checkBranch rejects globs, refspecs, and invalid ref names" {
    var diag: Diag = .{};
    for ([_][]const u8{ "main", "feature/x", "v1.2", "a-b_c", "user@host" }) |ok| {
        try checkBranch(ok, &diag);
        try checkPushBranch(ok, &diag);
    }
    for ([_][]const u8{
        "*",        "feat/*",   "a?b",   "a[b",    "a\\b", "a b",    "a~1",    "a^",
        "a..b",     "/a",       "a/",    "a//b",   ".a",     "a/.b",   "a.lock", "a.",
        "@",        "a@{1}",    "+main", "main:x", "-f",     "",
    }) |bad| {
        try expectError(error.Invalid, checkBranch(bad, &diag));
        try expectError(error.Invalid, checkPushBranch(bad, &diag));
    }
    try expectError(error.Invalid, checkPushBranch("*", &diag));
    try expect(std.mem.indexOf(u8, diag.msg, "not a valid branch name") != null);
    // Force-looking input keeps the specific message.
    try expectError(error.Invalid, checkPushBranch("+main", &diag));
    try expect(std.mem.indexOf(u8, diag.msg, "terminal") != null);
}

test "checkPath" {
    var diag: Diag = .{};
    try checkPath("src/main.zig", &diag);
    try checkPath("-dash", &diag);
    try expectError(error.Invalid, checkPath("", &diag));
    try expectError(error.Invalid, checkPath("a\x00b", &diag));
}
