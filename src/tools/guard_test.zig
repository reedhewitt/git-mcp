//! Destructive-operation guard: every operation the design excludes must be
//! unreachable through the tool surface. Each case calls a tool with an
//! excluded request, expects an error, and asserts that refs, HEAD, the index
//! and working tree, stashes, config, file contents, and the remote are all
//! exactly as they were.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const testutil = @import("../testutil.zig");
const Fixture = testutil.Fixture;
const registry = @import("registry.zig");

const Scene = struct { repo: []const u8, bare: []const u8 };

/// A repo with: a pushed `main`, an unmerged `feature` branch, a tag, a stash
/// entry, and a dirty tracked file (`a.txt`) on top of that.
fn scene(f: *Fixture) !Scene {
    const bare = try f.initBare("remote.git");
    const repo = try f.initRepo("work");
    _ = try f.git(repo, &.{ "remote", "add", "origin", bare });
    try f.commitFile(repo, "a.txt", "one\n", "first");
    try f.commitFile(repo, "b.txt", "bee\n", "second");
    _ = try f.git(repo, &.{ "push", "-q", "-u", "origin", "main" });
    _ = try f.git(repo, &.{ "tag", "v1" });
    _ = try f.git(repo, &.{ "switch", "-q", "-c", "feature" });
    try f.commitFile(repo, "f.txt", "feature only\n", "feature work");
    _ = try f.git(repo, &.{ "switch", "-q", "main" });
    try f.writeFile("work/a.txt", "stashed edit\n");
    _ = try f.git(repo, &.{ "stash", "push", "-q", "--message=keep me" });
    try f.writeFile("work/a.txt", "uncommitted edit\n");
    return .{ .repo = repo, .bare = bare };
}

/// Everything a destructive operation could change, as one string.
fn snapshot(f: *Fixture, s: Scene) ![]const u8 {
    const a = f.arena();
    const cwd = Io.Dir.cwd();
    const a_txt = try cwd.readFileAlloc(testing.io, f.path("work/a.txt"), a, .limited(1000));
    const b_txt = try cwd.readFileAlloc(testing.io, f.path("work/b.txt"), a, .limited(1000));
    const parts = [_][]const u8{
        try f.git(s.repo, &.{ "for-each-ref", "--format=%(refname) %(objectname)" }),
        try f.git(s.repo, &.{ "rev-parse", "HEAD", "HEAD^{tree}" }),
        try f.git(s.repo, &.{ "status", "--porcelain=v1", "--branch" }),
        try f.git(s.repo, &.{ "stash", "list" }),
        try f.git(s.repo, &.{ "config", "--local", "--list" }),
        try f.git(s.bare, &.{ "for-each-ref", "--format=%(refname) %(objectname)" }),
        "a.txt=", a_txt, "b.txt=", b_txt,
    };
    return std.mem.concat(a, u8, &parts);
}

const Case = struct { tool: []const u8, extra: []const u8 };

fn expectGuarded(f: *Fixture, s: Scene, cases: []const Case) !void {
    for (cases) |c| {
        const before = try snapshot(f, s);
        const json = try std.fmt.allocPrint(f.arena(), "{{\"repo\":\"{s}\"{s}}}", .{ s.repo, c.extra });
        const res = try f.call(c.tool, json);
        if (!res.is_error) {
            std.debug.print("guard case succeeded but must fail: {s} {s}\n  -> {s}\n", .{ c.tool, c.extra, res.text });
            return error.GuardBypassed;
        }
        const after = try snapshot(f, s);
        if (!std.mem.eql(u8, before, after)) {
            std.debug.print("guard case changed state: {s} {s}\n--- before\n{s}\n--- after\n{s}\n", .{ c.tool, c.extra, before, after });
            return error.StateChanged;
        }
    }
}

test "git_reset hard, merge, keep are rejected and change nothing" {
    const f = try Fixture.init();
    defer f.deinit();
    const s = try scene(f);
    try expectGuarded(f, s, &.{
        .{ .tool = "git_reset", .extra = ",\"mode\":\"hard\"" },
        .{ .tool = "git_reset", .extra = ",\"mode\":\"merge\"" },
        .{ .tool = "git_reset", .extra = ",\"mode\":\"keep\"" },
        .{ .tool = "git_reset", .extra = ",\"mode\":\"hard\",\"ref\":\"HEAD~1\"" },
        .{ .tool = "git_reset", .extra = ",\"ref\":\"--hard\"" },
        .{ .tool = "git_reset", .extra = ",\"mode\":\"--hard\"" },
    });
}

test "git_stash drop and clear are rejected and change nothing" {
    const f = try Fixture.init();
    defer f.deinit();
    const s = try scene(f);
    try expectGuarded(f, s, &.{
        .{ .tool = "git_stash", .extra = ",\"action\":\"drop\"" },
        .{ .tool = "git_stash", .extra = ",\"action\":\"drop\",\"index\":0" },
        .{ .tool = "git_stash", .extra = ",\"action\":\"clear\"" },
    });
}

test "git_branch force-style requests never delete or overwrite" {
    const f = try Fixture.init();
    defer f.deinit();
    const s = try scene(f);
    try expectGuarded(f, s, &.{
        // Safe delete: git refuses because `feature` is unmerged.
        .{ .tool = "git_branch", .extra = ",\"action\":\"delete\",\"name\":\"feature\"" },
        // Unknown keys are ignored, so this is still a plain `-d`.
        .{ .tool = "git_branch", .extra = ",\"action\":\"delete\",\"name\":\"feature\",\"force\":true" },
        .{ .tool = "git_branch", .extra = ",\"action\":\"delete\",\"name\":\"feature\",\"force\":true,\"D\":true" },
        .{ .tool = "git_branch", .extra = ",\"action\":\"force_delete\",\"name\":\"feature\"" },
        .{ .tool = "git_branch", .extra = ",\"action\":\"delete\",\"name\":\"-D\"" },
        .{ .tool = "git_branch", .extra = ",\"action\":\"delete\",\"name\":\"--force\"" },
        // Rename onto an existing branch must not overwrite it (no -M).
        .{ .tool = "git_branch", .extra = ",\"action\":\"rename\",\"name\":\"feature\",\"new_name\":\"main\",\"force\":true" },
        .{ .tool = "git_branch", .extra = ",\"action\":\"copy\",\"name\":\"feature\",\"new_name\":\"main\"" },
    });
}

test "git_push refuses force, delete, glob, and mirror forms" {
    const f = try Fixture.init();
    defer f.deinit();
    const s = try scene(f);
    try expectGuarded(f, s, &.{
        .{ .tool = "git_push", .extra = ",\"branch\":\"+main\"" },
        .{ .tool = "git_push", .extra = ",\"branch\":\":main\"" },
        .{ .tool = "git_push", .extra = ",\"branch\":\"main:+x\"" },
        .{ .tool = "git_push", .extra = ",\"branch\":\"main:main\"" },
        .{ .tool = "git_push", .extra = ",\"branch\":\"refs/heads/*\"" },
        .{ .tool = "git_push", .extra = ",\"branch\":\"--force\"" },
        .{ .tool = "git_push", .extra = ",\"branch\":\"--delete\"" },
        .{ .tool = "git_push", .extra = ",\"remote\":\"--mirror\"" },
        .{ .tool = "git_push", .extra = ",\"remote\":\"--force\",\"branch\":\"main\"" },
    });

    // A remote configured as a mirror is refused outright.
    _ = try f.git(s.repo, &.{ "config", "remote.origin.mirror", "true" });
    try expectGuarded(f, s, &.{
        .{ .tool = "git_push", .extra = "" },
        .{ .tool = "git_push", .extra = ",\"branch\":\"main\"" },
        .{ .tool = "git_push", .extra = ",\"force\":true" },
    });
}

test "git_remote remove and git_tag delete are rejected" {
    const f = try Fixture.init();
    defer f.deinit();
    const s = try scene(f);
    try expectGuarded(f, s, &.{
        .{ .tool = "git_remote", .extra = ",\"action\":\"remove\",\"name\":\"origin\"" },
        .{ .tool = "git_remote", .extra = ",\"action\":\"rm\",\"name\":\"origin\"" },
        .{ .tool = "git_tag", .extra = ",\"action\":\"delete\",\"name\":\"v1\"" },
        .{ .tool = "git_tag", .extra = ",\"action\":\"delete\",\"name\":\"v1\",\"force\":true" },
        // Re-tagging an existing name must not move it.
        .{ .tool = "git_tag", .extra = ",\"action\":\"create\",\"name\":\"v1\",\"ref\":\"feature\",\"force\":true" },
    });
}

test "git_switch, git_merge, git_rebase refuse option-looking refs" {
    const f = try Fixture.init();
    defer f.deinit();
    const s = try scene(f);
    try expectGuarded(f, s, &.{
        .{ .tool = "git_switch", .extra = ",\"branch\":\"-f\"" },
        .{ .tool = "git_switch", .extra = ",\"branch\":\"--force\"" },
        .{ .tool = "git_switch", .extra = ",\"branch\":\"--discard-changes\"" },
        .{ .tool = "git_switch", .extra = ",\"branch\":\"feature\",\"create\":true,\"start_point\":\"-f\"" },
        .{ .tool = "git_switch", .extra = ",\"branch\":\"feature\",\"force\":true,\"discard_changes\":true,\"create\":true" },
        .{ .tool = "git_merge", .extra = ",\"action\":\"start\",\"ref\":\"-f\"" },
        .{ .tool = "git_merge", .extra = ",\"action\":\"start\",\"ref\":\"--force\"" },
        .{ .tool = "git_rebase", .extra = ",\"action\":\"start\",\"upstream\":\"-f\"" },
        .{ .tool = "git_rebase", .extra = ",\"action\":\"start\",\"upstream\":\"--force\"" },
        .{ .tool = "git_rebase", .extra = ",\"action\":\"start\",\"upstream\":\"main\",\"onto\":\"--force\"" },
    });
}

test "git_rm will not remove a modified file, with or without force" {
    const f = try Fixture.init();
    defer f.deinit();
    const s = try scene(f);
    try expectGuarded(f, s, &.{
        .{ .tool = "git_rm", .extra = ",\"paths\":[\"a.txt\"]" },
        .{ .tool = "git_rm", .extra = ",\"paths\":[\"a.txt\"],\"force\":true" },
        .{ .tool = "git_rm", .extra = ",\"paths\":[\"-f\",\"a.txt\"]" },
        .{ .tool = "git_rm", .extra = ",\"paths\":[\"--force\",\"a.txt\"]" },
    });
}

test "tool surface has no clean, restore, checkout, gc, reflog, update-ref" {
    const banned = [_][]const u8{
        "git_clean",  "git_restore",    "git_checkout", "git_gc",
        "git_reflog", "git_update_ref", "git_prune",    "git_filter_branch",
    };
    for (registry.all) |t| {
        for (banned) |b| try testing.expect(!std.mem.eql(u8, t.name, b));
    }
}

test "no tool schema exposes a force-like property" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for (registry.all) |t| {
        const doc = try std.json.parseFromSliceLeaky(std.json.Value, a, t.schema, .{});
        const props = doc.object.get("properties") orelse return error.SchemaWithoutProperties;
        try testing.expect(props == .object);
        var it = props.object.iterator();
        while (it.next()) |e| {
            if (std.mem.indexOf(u8, e.key_ptr.*, "force") != null or
                std.mem.indexOf(u8, e.key_ptr.*, "discard") != null)
            {
                std.debug.print("tool {s} exposes property '{s}'\n", .{ t.name, e.key_ptr.* });
                return error.ForcePropertyExposed;
            }
        }
    }
}
