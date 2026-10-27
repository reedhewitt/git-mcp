//! Merge, rebase, cherry-pick, revert, and conflict resolution. Every
//! action is non-interactive: the runner sets GIT_EDITOR=true, so `continue`
//! uses git's prepared message and never waits for an editor.
const std = @import("std");
const common = @import("common.zig");
const Ctx = common.Ctx;
const Args = common.Args;
const ToolResult = common.ToolResult;
const validate = @import("../validate.zig");

const action_prop = "\"action\":{\"type\":\"string\",\"enum\":[\"start\",\"continue\",\"abort\",\"skip\"]}";
const merge_action_prop = "\"action\":{\"type\":\"string\",\"enum\":[\"start\",\"continue\",\"abort\"]}";

pub const tools = [_]common.Tool{
    .{
        .name = "git_merge",
        .description = "Merge a branch or commit into the current branch. action 'start' (needs 'ref'; optional 'no_ff', 'ff_only', 'squash', 'message'). If it stops on conflicts, fix them (git_status shows 'Unmerged' paths; git_resolve picks one side, or edit the files), stage with git_add, then run 'continue' to finish the merge using git's prepared message, or 'abort' to go back to before the merge. 'continue' and 'abort' take only 'repo'. It never opens an editor.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ common.repo_prop ++ "," ++ merge_action_prop ++
            \\,"ref":{"type":"string","description":"start: branch or commit to merge."},"no_ff":{"type":"boolean","description":"start: always create a merge commit."},"ff_only":{"type":"boolean","description":"start: refuse unless it can fast-forward."},"squash":{"type":"boolean","description":"start: stage the combined changes without committing."},"message":{"type":"string","description":"start: merge commit message."}},"required":["repo","action"]}
        ,
        .handler = merge,
    },
    .{
        .name = "git_rebase",
        .description = "Rebase the current branch onto 'upstream' (optionally 'onto' a different base: rebase --onto <onto> <upstream>). action 'start' needs 'upstream'. If it stops on conflicts, fix them (git_resolve or edit the files), stage with git_add, then 'continue'; 'skip' drops the current commit; 'abort' restores the branch to before the rebase. Not interactive: no editor ever opens. Note that during a rebase 'ours' is the branch being rebased onto and 'theirs' is your commit being replayed.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ common.repo_prop ++ "," ++ action_prop ++
            \\,"upstream":{"type":"string","description":"start: the branch or commit to rebase onto (or the old base when 'onto' is given)."},"onto":{"type":"string","description":"start: new base commit."}},"required":["repo","action"]}
        ,
        .handler = rebase,
    },
    .{
        .name = "git_cherry_pick",
        .description = "Apply the changes of one or more commits onto the current branch. action 'start' needs 'refs' (commit ids, applied in order). On conflict, fix and git_add, then 'continue'; 'skip' drops the current commit; 'abort' cancels the whole operation.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ common.repo_prop ++ "," ++ action_prop ++
            \\,"refs":{"type":"array","items":{"type":"string"},"description":"start: commits to apply."}},"required":["repo","action"]}
        ,
        .handler = cherryPick,
    },
    .{
        .name = "git_revert",
        .description = "Create commits that undo one or more earlier commits. action 'start' needs 'refs'; 'no_commit' stages the undo without committing. On conflict, fix and git_add, then 'continue'; 'skip' drops the current commit; 'abort' cancels. Uses the default 'Revert ...' message and never opens an editor.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ common.repo_prop ++ "," ++ action_prop ++
            \\,"refs":{"type":"array","items":{"type":"string"},"description":"start: commits to revert."},"no_commit":{"type":"boolean","description":"start: apply the undo to the index and working tree without committing."}},"required":["repo","action"]}
        ,
        .handler = revert,
    },
    .{
        .name = "git_resolve",
        .description = "Resolve conflicted files by taking one whole side: 'ours' or 'theirs' (git checkout --ours/--theirs). Only works on paths currently in conflict. During a rebase, 'ours' is the branch being rebased onto and 'theirs' is the commit being replayed; during a merge, 'ours' is the current branch. This does not stage the result: the next step is git_add on the same paths, then the tool's 'continue'.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ common.repo_prop ++
            \\,"paths":{"type":"array","items":{"type":"string"},"description":"Conflicted files, relative to the repository root."},"side":{"type":"string","enum":["ours","theirs"]}},"required":["repo","paths","side"]}
        ,
        .handler = resolve,
    },
};

fn appendStr(ctx: *Ctx, argv: *std.ArrayList([]const u8), s: []const u8) !void {
    try argv.append(ctx.arena, s);
}

const MergeAction = enum { start, @"continue", abort };
const SeqAction = enum { start, @"continue", abort, skip };

/// `git <cmd> --continue|--abort|--skip` for the non-start actions.
fn control(ctx: *Ctx, repo: []const u8, cmd: []const u8, action: []const u8) !ToolResult {
    const flag = try std.fmt.allocPrint(ctx.arena, "--{s}", .{action});
    return ctx.git(repo, &.{ cmd, flag }, false);
}

fn merge(ctx: *Ctx, args: Args) !ToolResult {
    const repo = try ctx.repo(args);
    const action = try args.enumOf(MergeAction, "action") orelse return ctx.fail("'action' is required", .{});
    if (action != .start) return control(ctx, repo, "merge", @tagName(action));

    const ref = try args.reqStr("ref");
    try validate.checkName("ref", ref, &ctx.diag);
    const no_ff = try args.boolean("no_ff") orelse false;
    const ff_only = try args.boolean("ff_only") orelse false;
    if (no_ff and ff_only) return ctx.fail("'no_ff' and 'ff_only' cannot be combined", .{});
    var argv: std.ArrayList([]const u8) = .empty;
    try appendStr(ctx, &argv, "merge");
    if (no_ff) try appendStr(ctx, &argv, "--no-ff");
    if (ff_only) try appendStr(ctx, &argv, "--ff-only");
    if (try args.boolean("squash") orelse false) try appendStr(ctx, &argv, "--squash");
    if (try args.str("message")) |m| try appendStr(ctx, &argv, try std.fmt.allocPrint(ctx.arena, "--message={s}", .{m}));
    try appendStr(ctx, &argv, ref);
    return ctx.git(repo, argv.items, false);
}

fn rebase(ctx: *Ctx, args: Args) !ToolResult {
    const repo = try ctx.repo(args);
    const action = try args.enumOf(SeqAction, "action") orelse return ctx.fail("'action' is required", .{});
    if (action != .start) return control(ctx, repo, "rebase", @tagName(action));

    const upstream = try args.reqStr("upstream");
    try validate.checkName("upstream", upstream, &ctx.diag);
    var argv: std.ArrayList([]const u8) = .empty;
    try appendStr(ctx, &argv, "rebase");
    if (try args.str("onto")) |onto| {
        try validate.checkName("onto", onto, &ctx.diag);
        try appendStr(ctx, &argv, "--onto");
        try appendStr(ctx, &argv, onto);
    }
    try appendStr(ctx, &argv, upstream);
    return ctx.git(repo, argv.items, false);
}

fn refList(ctx: *Ctx, args: Args) ![]const []const u8 {
    const refs = try args.strList(ctx.arena, "refs") orelse return ctx.fail("'refs' is required", .{});
    if (refs.len == 0) return ctx.fail("'refs' must not be empty", .{});
    for (refs) |r| try validate.checkName("ref", r, &ctx.diag);
    return refs;
}

fn cherryPick(ctx: *Ctx, args: Args) !ToolResult {
    const repo = try ctx.repo(args);
    const action = try args.enumOf(SeqAction, "action") orelse return ctx.fail("'action' is required", .{});
    if (action != .start) return control(ctx, repo, "cherry-pick", @tagName(action));

    const refs = try refList(ctx, args);
    var argv: std.ArrayList([]const u8) = .empty;
    try appendStr(ctx, &argv, "cherry-pick");
    try argv.appendSlice(ctx.arena, refs);
    return ctx.git(repo, argv.items, false);
}

fn revert(ctx: *Ctx, args: Args) !ToolResult {
    const repo = try ctx.repo(args);
    const action = try args.enumOf(SeqAction, "action") orelse return ctx.fail("'action' is required", .{});
    if (action != .start) return control(ctx, repo, "revert", @tagName(action));

    const refs = try refList(ctx, args);
    var argv: std.ArrayList([]const u8) = .empty;
    try appendStr(ctx, &argv, "revert");
    try appendStr(ctx, &argv, "--no-edit");
    if (try args.boolean("no_commit") orelse false) try appendStr(ctx, &argv, "--no-commit");
    try argv.appendSlice(ctx.arena, refs);
    return ctx.git(repo, argv.items, false);
}

const Side = enum { ours, theirs };

fn resolve(ctx: *Ctx, args: Args) !ToolResult {
    const repo = try ctx.repo(args);
    const paths = try args.strList(ctx.arena, "paths") orelse return ctx.fail("'paths' is required", .{});
    if (paths.len == 0) return ctx.fail("'paths' must not be empty", .{});
    const side = try args.enumOf(Side, "side") orelse return ctx.fail("'side' is required", .{});
    for (paths) |p| try validate.checkPath(p, &ctx.diag);

    // --relative: report paths relative to `repo`, matching what the agent sends.
    const listed = try ctx.runner.run(ctx.arena, .{
        .cwd = repo,
        .args = &.{ "diff", "--name-only", "-z", "--relative", "--diff-filter=U" },
    });
    if (listed.timed_out or listed.exit_code == null or listed.exit_code.? != 0) {
        return common.formatResult(ctx.arena, listed);
    }
    for (paths) |p| {
        var found = false;
        var it = std.mem.splitScalar(u8, listed.stdout, 0);
        while (it.next()) |line| {
            if (line.len > 0 and std.mem.eql(u8, line, p)) found = true;
        }
        if (!found) return ctx.fail("'{s}' is not in conflict; git_resolve only works on conflicted files", .{p});
    }

    var argv: std.ArrayList([]const u8) = .empty;
    // Literal pathspecs: a name like "[x].txt" must not glob onto other files.
    try appendStr(ctx, &argv, "--literal-pathspecs");
    try appendStr(ctx, &argv, "checkout");
    try appendStr(ctx, &argv, if (side == .ours) "--ours" else "--theirs");
    try appendStr(ctx, &argv, "--");
    try argv.appendSlice(ctx.arena, paths);
    return ctx.git(repo, argv.items, false);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const Fixture = @import("../testutil.zig").Fixture;

fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
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

/// True if `git <args>` exits 0.
fn gitSucceeds(f: *Fixture, repo: []const u8, args: []const []const u8) !bool {
    const res = try f.runner.run(f.arena(), .{ .cwd = repo, .args = args });
    return res.exit_code != null and res.exit_code.? == 0;
}

/// main and feat both edit `f` (base "base\n"); leaves main checked out.
fn conflictingBranches(f: *Fixture, r: []const u8) !void {
    try f.commitFile(r, "f", "base\n", "base");
    _ = try f.git(r, &.{ "switch", "-q", "-c", "feat" });
    try f.commitFile(r, "f", "feat\n", "feat edit");
    _ = try f.git(r, &.{ "switch", "-q", "main" });
    try f.commitFile(r, "f", "main\n", "main edit");
}

test "merge conflict resolved via resolve + add + continue" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try conflictingBranches(f, r);

    try expectErr(try call1(f, "git_merge", r, ",\"action\":\"start\",\"ref\":\"feat\""), "CONFLICT");
    const st = try call1(f, "git_status", r, "");
    try expectOk(st);
    try testing.expect(contains(st.text, "Unmerged"));

    try expectOk(try call1(f, "git_resolve", r, ",\"paths\":[\"f\"],\"side\":\"theirs\""));
    try expectOk(try call1(f, "git_add", r, ",\"paths\":[\"f\"]"));
    try expectOk(try call1(f, "git_merge", r, ",\"action\":\"continue\""));

    try testing.expectEqualStrings("feat\n", try f.git(r, &.{ "show", "HEAD:f" }));
    try testing.expect(!try gitSucceeds(f, r, &.{ "rev-parse", "-q", "--verify", "MERGE_HEAD" }));
}

test "merge abort restores state" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try conflictingBranches(f, r);
    try expectErr(try call1(f, "git_merge", r, ",\"action\":\"start\",\"ref\":\"feat\""), "CONFLICT");
    try expectOk(try call1(f, "git_merge", r, ",\"action\":\"abort\""));
    try testing.expect(!try gitSucceeds(f, r, &.{ "rev-parse", "-q", "--verify", "MERGE_HEAD" }));
    try testing.expectEqualStrings("main\n", try f.git(r, &.{ "show", "HEAD:f" }));
}

test "resolve refuses non-conflicted paths" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.commitFile(r, "g", "g1\n", "g");
    try conflictingBranches(f, r);
    try expectErr(try call1(f, "git_merge", r, ",\"action\":\"start\",\"ref\":\"feat\""), "CONFLICT");

    try f.writeFile("r/g", "g-local\n");
    try expectErr(try call1(f, "git_resolve", r, ",\"paths\":[\"g\"],\"side\":\"ours\""), "'g' is not in conflict");
    try expectErr(try call1(f, "git_resolve", r, ",\"paths\":[\"f\",\"g\"],\"side\":\"ours\""), "'g' is not in conflict");
    try testing.expect(contains(try f.git(r, &.{ "diff", "--", "g" }), "+g-local"));
    const content = try f.git(r, &.{ "diff", "--name-only", "--diff-filter=U" });
    try testing.expectEqualStrings("f\n", content);
}

test "rebase continue and abort" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.commitFile(r, "f", "base\n", "base");
    _ = try f.git(r, &.{ "switch", "-q", "-c", "feat" });
    try f.commitFile(r, "f", "feat\n", "feat edit");
    _ = try f.git(r, &.{ "switch", "-q", "main" });
    try f.commitFile(r, "f", "main\n", "main edit");
    _ = try f.git(r, &.{ "switch", "-q", "feat" });
    const orig = try f.arena().dupe(u8, try f.git(r, &.{ "rev-parse", "HEAD" }));

    try expectErr(try call1(f, "git_rebase", r, ",\"action\":\"start\",\"upstream\":\"main\""), "CONFLICT");
    try expectOk(try call1(f, "git_rebase", r, ",\"action\":\"abort\""));
    try testing.expectEqualStrings(orig, try f.git(r, &.{ "rev-parse", "HEAD" }));

    try expectErr(try call1(f, "git_rebase", r, ",\"action\":\"start\",\"upstream\":\"main\""), "CONFLICT");
    try f.writeFile("r/f", "resolved\n");
    try expectOk(try call1(f, "git_add", r, ",\"paths\":[\"f\"]"));
    try expectOk(try call1(f, "git_rebase", r, ",\"action\":\"continue\""));
    try testing.expectEqualStrings("resolved\n", try f.git(r, &.{ "show", "HEAD:f" }));
    try testing.expectEqualStrings("feat edit\n", try f.git(r, &.{ "log", "-1", "--format=%s" }));
    try testing.expectEqualStrings("feat\n", try f.git(r, &.{ "branch", "--show-current" }));
}

test "cherry-pick and revert" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.commitFile(r, "a", "1\n", "first");
    _ = try f.git(r, &.{ "switch", "-q", "-c", "feat" });
    try f.commitFile(r, "b", "b\n", "add b");
    const sha = std.mem.trim(u8, try f.git(r, &.{ "rev-parse", "HEAD" }), "\n");
    _ = try f.git(r, &.{ "switch", "-q", "main" });

    try expectOk(try call1(f, "git_cherry_pick", r, try std.fmt.allocPrint(f.arena(), ",\"action\":\"start\",\"refs\":[\"{s}\"]", .{sha})));
    try testing.expectEqualStrings("b\n", try f.git(r, &.{ "show", "HEAD:b" }));

    try expectOk(try call1(f, "git_revert", r, ",\"action\":\"start\",\"refs\":[\"HEAD\"]"));
    const log = try f.git(r, &.{ "log", "-1", "--format=%s" });
    try testing.expect(contains(log, "Revert"));

    // no_commit leaves the revert staged
    try expectOk(try call1(f, "git_revert", r, ",\"action\":\"start\",\"refs\":\"HEAD\",\"no_commit\":true"));
    try testing.expect(contains(try f.git(r, &.{ "status", "--porcelain" }), "b"));
}

test "merge no_ff with ff_only is invalid" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.commitFile(r, "a", "1\n", "first");
    try expectErr(try call1(f, "git_merge", r, ",\"action\":\"start\",\"ref\":\"main\",\"no_ff\":true,\"ff_only\":true"), "no_ff");
}

test "merge options and validation" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.commitFile(r, "a", "1\n", "first");
    _ = try f.git(r, &.{ "switch", "-q", "-c", "feat" });
    try f.commitFile(r, "b", "b\n", "add b");
    _ = try f.git(r, &.{ "switch", "-q", "main" });
    try expectErr(try call1(f, "git_merge", r, ",\"action\":\"start\",\"ref\":\"--abort\""), "must not start with '-'");
    try expectErr(try call1(f, "git_merge", r, ",\"action\":\"skip\""), "must be one of");
    try expectErr(try call1(f, "git_merge", r, ",\"action\":\"start\""), "ref");
    try expectOk(try call1(f, "git_merge", r, ",\"action\":\"start\",\"ref\":\"feat\",\"no_ff\":true,\"message\":\"Merge feat\""));
    try testing.expectEqualStrings("Merge feat\n", try f.git(r, &.{ "log", "-1", "--format=%s" }));
}

test "resolve treats pathspecs literally" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.commitFile(r, "x.txt", "x1\n", "x");
    try f.commitFile(r, "[x].txt", "base\n", "base");
    _ = try f.git(r, &.{ "switch", "-q", "-c", "feat" });
    try f.commitFile(r, "[x].txt", "feat\n", "feat edit");
    _ = try f.git(r, &.{ "switch", "-q", "main" });
    try f.commitFile(r, "[x].txt", "main\n", "main edit");
    try expectErr(try call1(f, "git_merge", r, ",\"action\":\"start\",\"ref\":\"feat\""), "CONFLICT");
    try f.writeFile("r/x.txt", "x-local\n");

    try expectOk(try call1(f, "git_resolve", r, ",\"paths\":[\"[x].txt\"],\"side\":\"theirs\""));
    try testing.expect(contains(try f.git(r, &.{ "diff", "--", "x.txt" }), "+x-local"));
    try expectOk(try call1(f, "git_add", r, ",\"paths\":[\"[x].txt\"]"));
    try testing.expectEqualStrings("feat\n", try f.git(r, &.{ "show", ":[x].txt" }));
}

test "resolve handles quoted file names" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.commitFile(r, "a\"b.txt", "base\n", "base");
    _ = try f.git(r, &.{ "switch", "-q", "-c", "feat" });
    try f.commitFile(r, "a\"b.txt", "feat\n", "feat edit");
    _ = try f.git(r, &.{ "switch", "-q", "main" });
    try f.commitFile(r, "a\"b.txt", "main\n", "main edit");
    try expectErr(try call1(f, "git_merge", r, ",\"action\":\"start\",\"ref\":\"feat\""), "CONFLICT");
    try expectOk(try call1(f, "git_resolve", r, ",\"paths\":[\"a\\\"b.txt\"],\"side\":\"ours\""));
}

test "resolve rejects directories and dot" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.commitFile(r, "sub/clean", "c\n", "clean");
    try conflictingBranches(f, r);
    try expectErr(try call1(f, "git_merge", r, ",\"action\":\"start\",\"ref\":\"feat\""), "CONFLICT");
    try f.writeFile("r/sub/clean", "dirty\n");
    try expectErr(try call1(f, "git_resolve", r, ",\"paths\":[\".\"],\"side\":\"ours\""), "not in conflict");
    try expectErr(try call1(f, "git_resolve", r, ",\"paths\":[\"sub/\"],\"side\":\"theirs\""), "not in conflict");
    try testing.expect(contains(try f.git(r, &.{ "diff", "--", "sub/clean" }), "+dirty"));
}

test "resolve from a subdirectory repo uses relative paths" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.commitFile(r, "sub/f", "base\n", "base");
    _ = try f.git(r, &.{ "switch", "-q", "-c", "feat" });
    try f.commitFile(r, "sub/f", "feat\n", "feat edit");
    _ = try f.git(r, &.{ "switch", "-q", "main" });
    try f.commitFile(r, "sub/f", "main\n", "main edit");
    try expectErr(try call1(f, "git_merge", r, ",\"action\":\"start\",\"ref\":\"feat\""), "CONFLICT");
    const sub = try std.fs.path.join(f.arena(), &.{ r, "sub" });
    try expectOk(try call1(f, "git_resolve", sub, ",\"paths\":[\"f\"],\"side\":\"theirs\""));
    try expectOk(try call1(f, "git_add", sub, ",\"paths\":[\"f\"]"));
    try expectOk(try call1(f, "git_merge", r, ",\"action\":\"continue\""));
    try testing.expectEqualStrings("feat\n", try f.git(r, &.{ "show", "HEAD:sub/f" }));
}

test "rebase skip" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try conflictingBranches(f, r);
    _ = try f.git(r, &.{ "switch", "-q", "feat" });
    try expectErr(try call1(f, "git_rebase", r, ",\"action\":\"start\",\"upstream\":\"main\""), "CONFLICT");
    try expectOk(try call1(f, "git_rebase", r, ",\"action\":\"skip\""));
    try testing.expectEqualStrings("main edit\n", try f.git(r, &.{ "log", "-1", "--format=%s" }));
    try testing.expectEqualStrings("feat\n", try f.git(r, &.{ "branch", "--show-current" }));
}

test "cherry-pick conflict then abort" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try conflictingBranches(f, r);
    const orig = try f.arena().dupe(u8, try f.git(r, &.{ "rev-parse", "HEAD" }));
    try expectErr(try call1(f, "git_cherry_pick", r, ",\"action\":\"start\",\"refs\":[\"feat\"]"), "CONFLICT");
    try expectOk(try call1(f, "git_cherry_pick", r, ",\"action\":\"abort\""));
    try testing.expectEqualStrings(orig, try f.git(r, &.{ "rev-parse", "HEAD" }));
}

test "rebase onto" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.commitFile(r, "a", "1\n", "a");
    _ = try f.git(r, &.{ "switch", "-q", "-c", "mid" });
    try f.commitFile(r, "m", "m\n", "mid");
    _ = try f.git(r, &.{ "switch", "-q", "-c", "topic" });
    try f.commitFile(r, "t", "t\n", "topic");
    _ = try f.git(r, &.{ "switch", "-q", "main" });
    try f.commitFile(r, "z", "z\n", "main z");
    _ = try f.git(r, &.{ "switch", "-q", "topic" });
    try expectOk(try call1(f, "git_rebase", r, ",\"action\":\"start\",\"upstream\":\"mid\",\"onto\":\"main\""));
    const tree = try f.git(r, &.{ "ls-tree", "--name-only", "HEAD" });
    try testing.expect(contains(tree, "z") and contains(tree, "t") and !contains(tree, "m\n"));
}
