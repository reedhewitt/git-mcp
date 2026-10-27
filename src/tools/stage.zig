//! Staging and committing: add, unstage, rm, mv, commit, reset. None of these
//! pass `-f`/`--force`/`--hard`, so they cannot discard uncommitted work.
const std = @import("std");
const common = @import("common.zig");
const Ctx = common.Ctx;
const Args = common.Args;
const ToolResult = common.ToolResult;
const validate = @import("../validate.zig");

pub const tools = [_]common.Tool{
    .{
        .name = "git_add",
        .description = "Stage changes so they are included in the next commit. Pass 'paths' to stage specific files or directories, or 'all' to stage every change in the repository (new, modified, and deleted files). Exactly one of 'paths' or 'all' is required. Check the result with git_status.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ common.repo_prop ++
            \\,"paths":{"type":"array","items":{"type":"string"},"description":"Files or directories to stage."},"all":{"type":"boolean","description":"Stage everything (git add -A). Do not combine with 'paths'."}},"required":["repo"]}
        ,
        .handler = add,
    },
    .{
        .name = "git_unstage",
        .description = "Remove files from the staging area without touching their contents in the working tree (the inverse of git_add). Works in a repository with no commits yet. Your edits are kept.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ common.repo_prop ++
            \\,"paths":{"type":"array","items":{"type":"string"},"description":"Files or directories to unstage."}},"required":["repo","paths"]}
        ,
        .handler = unstage,
    },
    .{
        .name = "git_rm",
        .description = "Remove files from version control and stage the removal. By default the files are also deleted from disk; use 'cached' to stop tracking them but keep them on disk. It never forces: git refuses to remove files with uncommitted changes, and so does this tool.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ common.repo_prop ++
            \\,"paths":{"type":"array","items":{"type":"string"},"description":"Files (or directories, with 'recursive') to remove."},"cached":{"type":"boolean","description":"Only remove from the index; keep the files on disk."},"recursive":{"type":"boolean","description":"Allow removing directories."}},"required":["repo","paths"]}
        ,
        .handler = rm,
    },
    .{
        .name = "git_mv",
        .description = "Move or rename a tracked file or directory and stage the move. It never overwrites an existing destination.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ common.repo_prop ++
            \\,"source":{"type":"string","description":"Existing tracked path."},"destination":{"type":"string","description":"New path."}},"required":["repo","source","destination"]}
        ,
        .handler = mv,
    },
    .{
        .name = "git_commit",
        .description = "Record the staged changes as a new commit on the current branch. 'message' is required unless 'amend' is true (then the previous message is reused). Use git_add first to stage changes, or pass 'all' to include every modified tracked file. 'amend' rewrites the most recent commit: only amend a commit that has not been pushed.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ common.repo_prop ++
            \\,"message":{"type":"string","description":"Commit message (may be multi-line)."},"amend":{"type":"boolean","description":"Replace the last commit instead of adding a new one."},"all":{"type":"boolean","description":"Also stage all modified and deleted tracked files (git commit -a). Untracked files are not included."},"allow_empty":{"type":"boolean","description":"Allow a commit with no changes."}},"required":["repo"]}
        ,
        .handler = commit,
    },
    .{
        .name = "git_reset",
        .description = "Move the current branch to another commit, e.g. to undo the last commit. 'soft' keeps your changes staged; 'mixed' (default) keeps them in the working tree but unstaged. Working-tree files are never overwritten, so this cannot discard uncommitted work (there is no hard mode).",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ common.repo_prop ++
            \\,"mode":{"type":"string","enum":["soft","mixed"],"description":"soft or mixed (default mixed)."},"ref":{"type":"string","description":"Commit to move to (default HEAD), e.g. HEAD~1."}},"required":["repo"]}
        ,
        .handler = reset,
    },
};

fn checkedPaths(ctx: *Ctx, args: Args, name: []const u8) ![]const []const u8 {
    const ps = try args.strList(ctx.arena, name) orelse return ctx.fail("'{s}' is required", .{name});
    if (ps.len == 0) return ctx.fail("'{s}' must not be empty", .{name});
    for (ps) |p| try validate.checkPath(p, &ctx.diag);
    return ps;
}

fn build(ctx: *Ctx, head: []const []const u8, paths: []const []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(ctx.arena, head);
    try argv.append(ctx.arena, "--");
    try argv.appendSlice(ctx.arena, paths);
    return argv.items;
}

fn add(ctx: *Ctx, args: Args) !ToolResult {
    const repo = try ctx.repo(args);
    const all = try args.boolean("all") orelse false;
    const has_paths = (try args.strList(ctx.arena, "paths")) != null;
    if (all == has_paths) return ctx.fail("provide exactly one of 'paths' or 'all'", .{});
    if (all) return ctx.git(repo, &.{ "add", "-A" }, false);
    const ps = try checkedPaths(ctx, args, "paths");
    return ctx.git(repo, try build(ctx, &.{"add"}, ps), false);
}

fn unstage(ctx: *Ctx, args: Args) !ToolResult {
    const repo = try ctx.repo(args);
    const ps = try checkedPaths(ctx, args, "paths");
    return ctx.git(repo, try build(ctx, &.{ "reset", "-q" }, ps), false);
}

fn rm(ctx: *Ctx, args: Args) !ToolResult {
    const repo = try ctx.repo(args);
    const ps = try checkedPaths(ctx, args, "paths");
    var head: std.ArrayList([]const u8) = .empty;
    try head.append(ctx.arena, "rm");
    if (try args.boolean("cached") orelse false) try head.append(ctx.arena, "--cached");
    if (try args.boolean("recursive") orelse false) try head.append(ctx.arena, "-r");
    return ctx.git(repo, try build(ctx, head.items, ps), false);
}

fn mv(ctx: *Ctx, args: Args) !ToolResult {
    const repo = try ctx.repo(args);
    const src = try args.reqStr("source");
    try validate.checkPath(src, &ctx.diag);
    const dst = try args.reqStr("destination");
    try validate.checkPath(dst, &ctx.diag);
    return ctx.git(repo, &.{ "mv", "--", src, dst }, false);
}

fn commit(ctx: *Ctx, args: Args) !ToolResult {
    const repo = try ctx.repo(args);
    const message = try args.str("message");
    const amend = try args.boolean("amend") orelse false;
    if (message == null and !amend) return ctx.fail("'message' is required unless 'amend' is true", .{});

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(ctx.arena, "commit");
    if (try args.boolean("all") orelse false) try argv.append(ctx.arena, "-a");
    if (amend) try argv.append(ctx.arena, "--amend");
    if (try args.boolean("allow_empty") orelse false) try argv.append(ctx.arena, "--allow-empty");
    if (message) |m| {
        try argv.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "--message={s}", .{m}));
    } else {
        try argv.append(ctx.arena, "--no-edit");
    }
    return ctx.git(repo, argv.items, false);
}

const ResetMode = enum { soft, mixed };

fn reset(ctx: *Ctx, args: Args) !ToolResult {
    const repo = try ctx.repo(args);
    const mode = try args.enumOf(ResetMode, "mode") orelse .mixed;
    const ref = try args.str("ref") orelse "HEAD";
    try validate.checkName("ref", ref, &ctx.diag);
    const flag = try std.fmt.allocPrint(ctx.arena, "--{s}", .{@tagName(mode)});
    return ctx.git(repo, &.{ "reset", flag, ref }, false);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const Fixture = @import("../testutil.zig").Fixture;
const Io = std.Io;

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn fileExists(p: []const u8) bool {
    Io.Dir.cwd().access(testing.io, p, .{}) catch return false;
    return true;
}

fn expectOk(res: ToolResult) !void {
    if (res.is_error) std.debug.print("unexpected tool error: {s}\n", .{res.text});
    try testing.expect(!res.is_error);
}

fn expectErr(res: ToolResult, needle: []const u8) !void {
    if (!res.is_error or !contains(res.text, needle)) {
        std.debug.print("expected error containing '{s}', got (is_error={}): {s}\n", .{ needle, res.is_error, res.text });
    }
    try testing.expect(res.is_error);
    try testing.expect(contains(res.text, needle));
}

fn call1(f: *Fixture, tool: []const u8, repo: []const u8, extra: []const u8) !ToolResult {
    return f.call(tool, try std.fmt.allocPrint(f.arena(), "{{\"repo\":\"{s}\"{s}}}", .{ repo, extra }));
}

test "add, commit, amend" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.writeFile("r/f", "hello\n");
    try expectOk(try call1(f, "git_add", r, ",\"paths\":[\"f\"]"));
    try expectOk(try call1(f, "git_commit", r, ",\"message\":\"line1\\n\\nbody \\\"quoted\\\" \u{2713}\""));
    try testing.expectEqualStrings("line1\n\nbody \"quoted\" \u{2713}\n\n", try f.git(r, &.{ "log", "-1", "--format=%B" }));

    try expectOk(try call1(f, "git_commit", r, ",\"amend\":true"));
    try testing.expectEqualStrings("1\n", try f.git(r, &.{ "rev-list", "--count", "HEAD" }));
    try testing.expectEqualStrings("line1\n\nbody \"quoted\" \u{2713}\n\n", try f.git(r, &.{ "log", "-1", "--format=%B" }));
}

test "add all and commit all" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.commitFile(r, "a", "1\n", "first");
    try f.writeFile("r/a", "2\n");
    try f.writeFile("r/new", "n\n");
    try expectOk(try call1(f, "git_add", r, ",\"all\":true"));
    try testing.expectEqualStrings("M  a\nA  new\n", try f.git(r, &.{ "status", "--porcelain" }));
    try expectOk(try call1(f, "git_commit", r, ",\"message\":\"x\",\"allow_empty\":true"));
    try f.writeFile("r/a", "3\n");
    try expectOk(try call1(f, "git_commit", r, ",\"message\":\"y\",\"all\":true"));
    try testing.expectEqualStrings("", try f.git(r, &.{ "status", "--porcelain" }));
}

test "add requires paths or all" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try expectErr(try call1(f, "git_add", r, ""), "exactly one of");
    try expectErr(try call1(f, "git_add", r, ",\"all\":true,\"paths\":[\"f\"]"), "exactly one of");
    try expectErr(try call1(f, "git_add", r, ",\"paths\":[]"), "must not be empty");
}

test "commit without message is an error unless amend" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try expectErr(try call1(f, "git_commit", r, ""), "'message' is required");
}

test "unstage in repo with no commits" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.writeFile("r/f", "x\n");
    _ = try f.git(r, &.{ "add", "--", "f" });
    try expectOk(try call1(f, "git_unstage", r, ",\"paths\":[\"f\"]"));
    try testing.expectEqualStrings("?? f\n", try f.git(r, &.{ "status", "--porcelain" }));
}

test "rm refuses modified files and never forces" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.commitFile(r, "f", "1\n", "first");
    try f.writeFile("r/f", "changed\n");
    try expectErr(try call1(f, "git_rm", r, ",\"paths\":[\"f\"]"), "git exited");
    try testing.expect(fileExists(f.path("r/f")));
    // --cached keeps the file on disk.
    try f.commitFile(r, "g", "g\n", "second");
    try expectOk(try call1(f, "git_rm", r, ",\"paths\":[\"g\"],\"cached\":true"));
    try testing.expect(fileExists(f.path("r/g")));
    try expectErr(try call1(f, "git_rm", r, ",\"paths\":[\"-f\"]"), "git exited");
}

test "mv renames and refuses to overwrite" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.commitFile(r, "a", "1\n", "first");
    try f.commitFile(r, "b", "2\n", "second");
    try expectErr(try call1(f, "git_mv", r, ",\"source\":\"a\",\"destination\":\"b\""), "git exited");
    try testing.expect(fileExists(f.path("r/a")));
    try expectOk(try call1(f, "git_mv", r, ",\"source\":\"a\",\"destination\":\"c\""));
    try testing.expect(fileExists(f.path("r/c")));
    try testing.expect(!fileExists(f.path("r/a")));
}

test "reset soft and mixed only" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.commitFile(r, "a", "1\n", "first");
    try f.commitFile(r, "b", "2\n", "second");
    try expectOk(try call1(f, "git_reset", r, ",\"mode\":\"soft\",\"ref\":\"HEAD~1\""));
    try testing.expectEqualStrings("A  b\n", try f.git(r, &.{ "status", "--porcelain" }));
    try expectOk(try call1(f, "git_reset", r, ""));
    try testing.expectEqualStrings("?? b\n", try f.git(r, &.{ "status", "--porcelain" }));
    try testing.expect(fileExists(f.path("r/b")));

    try expectErr(try call1(f, "git_reset", r, ",\"mode\":\"hard\""), "soft, mixed");
    try expectErr(try call1(f, "git_reset", r, ",\"ref\":\"--hard\""), "'-'");
    try testing.expect(fileExists(f.path("r/b")));
}
