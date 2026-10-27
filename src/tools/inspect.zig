//! Read-only inspection tools.
const std = @import("std");
const common = @import("common.zig");
const Ctx = common.Ctx;
const Args = common.Args;
const ToolResult = common.ToolResult;

pub const tools = [_]common.Tool{
    .{
        .name = "git_status",
        .description = "Show the state of a repository on the HOST machine: current branch, ahead/behind its upstream, staged, unstaged, and untracked changes, and any merge, rebase, or cherry-pick in progress (with git's hints on how to continue). Use it before committing, after pulling, or whenever you are unsure what state the repo is in. Pass the repository's absolute host path, not a sandbox path.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ common.repo_prop ++
            \\,"untracked":{"type":"boolean","description":"List untracked files (default true). Set false to hide them in large trees."}},"required":["repo"]}
        ,
        .handler = status,
    },
};

fn status(ctx: *Ctx, args: Args) !ToolResult {
    const repo = try ctx.repo(args);
    const untracked = try args.boolean("untracked") orelse true;
    // Long format: it reports ahead/behind and in-progress operations with hints.
    const argv: []const []const u8 = if (untracked) &.{"status"} else &.{ "status", "-uno" };
    return ctx.git(repo, argv, false);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const Fixture = @import("../testutil.zig").Fixture;

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "status reports branch and changes" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.commitFile(r, "a.txt", "one\n", "first");
    try f.writeFile("r/a.txt", "two\n");
    try f.writeFile("r/new.txt", "new\n");

    const args = try std.fmt.allocPrint(f.arena(), "{{\"repo\":\"{s}\"}}", .{r});
    const res = try f.call("git_status", args);
    try testing.expect(!res.is_error);
    try testing.expect(contains(res.text, "On branch main"));
    try testing.expect(contains(res.text, "modified:"));
    try testing.expect(contains(res.text, "new.txt"));

    const args2 = try std.fmt.allocPrint(f.arena(), "{{\"repo\":\"{s}\",\"untracked\":false}}", .{r});
    const res2 = try f.call("git_status", args2);
    try testing.expect(!res2.is_error);
    try testing.expect(contains(res2.text, "modified:"));
    try testing.expect(!contains(res2.text, "new.txt"));
}

test "status works with spaces in path" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("with space/kb");
    const args = try std.fmt.allocPrint(f.arena(), "{{\"repo\":\"{s}\"}}", .{r});
    const res = try f.call("git_status", args);
    try testing.expect(!res.is_error);
    try testing.expect(contains(res.text, "On branch main"));
}

test "status rejects a non-boolean untracked" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    const args = try std.fmt.allocPrint(f.arena(), "{{\"repo\":\"{s}\",\"untracked\":\"no\"}}", .{r});
    const res = try f.call("git_status", args);
    try testing.expect(res.is_error);
    try testing.expectEqualStrings("'untracked' must be a boolean", res.text);
}
