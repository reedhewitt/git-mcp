//! Branches, switching, tags, and stashes. Nothing here is irreversible: no
//! `branch -D/-M/-C`, no `switch --force/--discard-changes/-C`, no `tag -f/-d`,
//! and no `stash drop/clear`.
const std = @import("std");
const common = @import("common.zig");
const Ctx = common.Ctx;
const Args = common.Args;
const ToolResult = common.ToolResult;
const validate = @import("../validate.zig");

pub const tools = [_]common.Tool{
    .{
        .name = "git_branch",
        .description = "List, create, rename, delete, or set the upstream of local branches. 'list' shows branches with their upstream and last commit ('all' includes remote-tracking branches). 'create' needs 'name' (optional 'start_point'; it does not switch to it, use git_switch). 'rename' renames 'name' (default: current branch) to 'new_name' and refuses to overwrite an existing branch. 'delete' only deletes branches that are fully merged. 'set_upstream' needs 'upstream', e.g. origin/main.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ common.repo_prop ++
            \\,"action":{"type":"string","enum":["list","create","delete","rename","set_upstream"]},"name":{"type":"string","description":"Branch to act on."},"start_point":{"type":"string","description":"create: commit or branch to start from (default HEAD)."},"new_name":{"type":"string","description":"rename: the new branch name."},"upstream":{"type":"string","description":"set_upstream: remote-tracking branch, e.g. origin/main."},"all":{"type":"boolean","description":"list: include remote-tracking branches."}},"required":["repo","action"]}
        ,
        .handler = branch,
    },
    .{
        .name = "git_switch",
        .description = "Switch to another branch, or create one with 'create' (optionally from 'start_point') and switch to it. 'detach' checks out a commit without a branch. It never discards work: if uncommitted changes would be overwritten, git refuses and nothing changes. Commit or stash first with git_commit or git_stash.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ common.repo_prop ++
            \\,"branch":{"type":"string","description":"Branch to switch to (or the new branch name with 'create')."},"create":{"type":"boolean","description":"Create the branch (git switch -c)."},"start_point":{"type":"string","description":"Commit or branch to start the new branch from."},"detach":{"type":"boolean","description":"Detach HEAD at the given commit or branch."}},"required":["repo","branch"]}
        ,
        .handler = switchTool,
    },
    .{
        .name = "git_tag",
        .description = "List or create tags. 'list' shows tags with the first line of their message; 'pattern' filters them (e.g. v1.*). 'create' makes a tag at 'ref' (default HEAD); with 'message' it is an annotated tag, otherwise lightweight. It will not overwrite an existing tag, and there is no delete.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ common.repo_prop ++
            \\,"action":{"type":"string","enum":["list","create"]},"name":{"type":"string","description":"create: tag name."},"ref":{"type":"string","description":"create: commit to tag (default HEAD)."},"message":{"type":"string","description":"create: annotation message (makes an annotated tag)."},"pattern":{"type":"string","description":"list: glob filter."}},"required":["repo","action"]}
        ,
        .handler = tag,
    },
    .{
        .name = "git_stash",
        .description = "Shelve and restore uncommitted changes. 'push' stashes tracked changes ('include_untracked' adds new files; optional 'message'). 'pop' re-applies a stash and removes it if it applies cleanly; 'apply' re-applies and keeps it. 'list' shows stashes. 'show' summarizes one ('patch' for the full diff). 'index' selects stash@{index} (default 0, the newest). There is no drop or clear.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ common.repo_prop ++
            \\,"action":{"type":"string","enum":["push","pop","apply","list","show"]},"message":{"type":"string","description":"push: stash description."},"include_untracked":{"type":"boolean","description":"push: also stash untracked files."},"index":{"type":"integer","minimum":0,"description":"pop/apply/show: which stash (0 = newest)."},"patch":{"type":"boolean","description":"show: full diff instead of a summary."}},"required":["repo","action"]}
        ,
        .handler = stash,
    },
};

fn appendStr(ctx: *Ctx, argv: *std.ArrayList([]const u8), s: []const u8) !void {
    try argv.append(ctx.arena, s);
}

const BranchAction = enum { list, create, delete, rename, set_upstream };

fn branch(ctx: *Ctx, args: Args) !ToolResult {
    const repo = try ctx.repo(args);
    const action = try args.enumOf(BranchAction, "action") orelse return ctx.fail("'action' is required", .{});
    var argv: std.ArrayList([]const u8) = .empty;
    try appendStr(ctx, &argv, "branch");
    switch (action) {
        .list => {
            try appendStr(ctx, &argv, "-vv");
            if (try args.boolean("all") orelse false) try appendStr(ctx, &argv, "--all");
        },
        .create => {
            const name = try args.reqStr("name");
            try validate.checkBranch(name, &ctx.diag);
            try appendStr(ctx, &argv, name);
            if (try args.str("start_point")) |sp| {
                try validate.checkName("start_point", sp, &ctx.diag);
                try appendStr(ctx, &argv, sp);
            }
        },
        .delete => {
            const name = try args.reqStr("name");
            try validate.checkName("branch", name, &ctx.diag);
            try appendStr(ctx, &argv, "-d");
            try appendStr(ctx, &argv, name);
        },
        .rename => {
            const new_name = try args.reqStr("new_name");
            try validate.checkBranch(new_name, &ctx.diag);
            try appendStr(ctx, &argv, "-m");
            if (try args.str("name")) |name| {
                try validate.checkName("branch", name, &ctx.diag);
                try appendStr(ctx, &argv, name);
            }
            try appendStr(ctx, &argv, new_name);
        },
        .set_upstream => {
            const up = try args.reqStr("upstream");
            try validate.checkName("upstream", up, &ctx.diag);
            try appendStr(ctx, &argv, try std.fmt.allocPrint(ctx.arena, "--set-upstream-to={s}", .{up}));
            if (try args.str("name")) |name| {
                try validate.checkName("branch", name, &ctx.diag);
                try appendStr(ctx, &argv, name);
            }
        },
    }
    return ctx.git(repo, argv.items, false);
}

fn switchTool(ctx: *Ctx, args: Args) !ToolResult {
    const repo = try ctx.repo(args);
    const name = try args.reqStr("branch");
    const create = try args.boolean("create") orelse false;
    const detach = try args.boolean("detach") orelse false;
    if (create) try validate.checkBranch(name, &ctx.diag) else try validate.checkName("branch", name, &ctx.diag);
    const start = try args.str("start_point");
    if (start) |sp| try validate.checkName("start_point", sp, &ctx.diag);
    if (start != null and !create and !detach) return ctx.fail("'start_point' requires 'create' or 'detach'", .{});

    var argv: std.ArrayList([]const u8) = .empty;
    try appendStr(ctx, &argv, "switch");
    if (create) try appendStr(ctx, &argv, "-c");
    if (detach) try appendStr(ctx, &argv, "--detach");
    try appendStr(ctx, &argv, name);
    if (start) |sp| try appendStr(ctx, &argv, sp);
    return ctx.gitLong(repo, argv.items);
}

const TagAction = enum { list, create };

fn tag(ctx: *Ctx, args: Args) !ToolResult {
    const repo = try ctx.repo(args);
    const action = try args.enumOf(TagAction, "action") orelse return ctx.fail("'action' is required", .{});
    var argv: std.ArrayList([]const u8) = .empty;
    try appendStr(ctx, &argv, "tag");
    switch (action) {
        .list => {
            try appendStr(ctx, &argv, "-l");
            try appendStr(ctx, &argv, "-n1");
            if (try args.str("pattern")) |p| {
                try validate.checkName("pattern", p, &ctx.diag);
                try appendStr(ctx, &argv, p);
            }
        },
        .create => {
            const name = try args.reqStr("name");
            try validate.checkBranch(name, &ctx.diag);
            if (try args.str("message")) |m| {
                try appendStr(ctx, &argv, "-a");
                try appendStr(ctx, &argv, try std.fmt.allocPrint(ctx.arena, "--message={s}", .{m}));
            }
            try appendStr(ctx, &argv, name);
            if (try args.str("ref")) |ref| {
                try validate.checkName("ref", ref, &ctx.diag);
                try appendStr(ctx, &argv, ref);
            }
        },
    }
    return ctx.git(repo, argv.items, false);
}

const StashAction = enum { push, pop, apply, list, show };

fn stash(ctx: *Ctx, args: Args) !ToolResult {
    const repo = try ctx.repo(args);
    const action = try args.enumOf(StashAction, "action") orelse return ctx.fail("'action' is required", .{});
    var argv: std.ArrayList([]const u8) = .empty;
    try appendStr(ctx, &argv, "stash");
    try appendStr(ctx, &argv, @tagName(action));
    switch (action) {
        .push => {
            if (try args.boolean("include_untracked") orelse false) try appendStr(ctx, &argv, "-u");
            if (try args.str("message")) |m| {
                try appendStr(ctx, &argv, try std.fmt.allocPrint(ctx.arena, "--message={s}", .{m}));
            }
        },
        .list => {},
        .pop, .apply, .show => {
            if (action == .show and (try args.boolean("patch") orelse false)) try appendStr(ctx, &argv, "-p");
            if (try args.int("index")) |i| {
                if (i < 0) return ctx.fail("'index' must be 0 or greater", .{});
                try appendStr(ctx, &argv, try std.fmt.allocPrint(ctx.arena, "stash@{{{d}}}", .{i}));
            }
        },
    }
    return ctx.gitLong(repo, argv.items);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const Fixture = @import("../testutil.zig").Fixture;
const Io = std.Io;

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
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

test "branch create, list, rename, safe delete" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.commitFile(r, "a", "1\n", "first");
    try expectOk(try call1(f, "git_branch", r, ",\"action\":\"create\",\"name\":\"feat\""));
    const listed = try call1(f, "git_branch", r, ",\"action\":\"list\"");
    try expectOk(listed);
    try testing.expect(contains(listed.text, "feat"));
    try expectOk(try call1(f, "git_branch", r, ",\"action\":\"rename\",\"name\":\"feat\",\"new_name\":\"feat2\""));
    try testing.expect(contains(try f.git(r, &.{ "branch", "--list" }), "feat2"));

    try expectOk(try call1(f, "git_switch", r, ",\"branch\":\"feat2\""));
    try f.commitFile(r, "b", "2\n", "on feat2");
    try expectOk(try call1(f, "git_switch", r, ",\"branch\":\"main\""));
    try expectErr(try call1(f, "git_branch", r, ",\"action\":\"delete\",\"name\":\"feat2\""), "not fully merged");
    try testing.expect(contains(try f.git(r, &.{ "branch", "--list" }), "feat2"));

    // Invalid names and unsupported actions.
    try expectErr(try call1(f, "git_branch", r, ",\"action\":\"create\",\"name\":\"bad name\""), "not a valid branch name");
    try expectErr(try call1(f, "git_branch", r, ",\"action\":\"rename\",\"name\":\"main\",\"new_name\":\"x*\""), "not a valid branch name");
    try expectErr(try call1(f, "git_branch", r, ",\"action\":\"force_delete\",\"name\":\"feat2\""), "must be one of");
    try expectErr(try call1(f, "git_branch", r, ",\"action\":\"delete\",\"name\":\"-D\""), "'-'");
}

test "branch set_upstream" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.commitFile(r, "a", "1\n", "first");
    try expectOk(try call1(f, "git_branch", r, ",\"action\":\"create\",\"name\":\"feat\""));
    try expectOk(try call1(f, "git_branch", r, ",\"action\":\"set_upstream\",\"name\":\"feat\",\"upstream\":\"main\""));
    try testing.expectEqualStrings("main\n", try f.git(r, &.{ "rev-parse", "--abbrev-ref", "feat@{upstream}" }));
}

test "switch refuses to clobber local changes" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.commitFile(r, "a", "1\n", "first");
    _ = try f.git(r, &.{ "switch", "-q", "-c", "other" });
    try f.commitFile(r, "a", "other\n", "other change");
    _ = try f.git(r, &.{ "switch", "-q", "main" });
    try f.writeFile("r/a", "local\n");
    try expectErr(try call1(f, "git_switch", r, ",\"branch\":\"other\""), "git exited");
    const content = try Io.Dir.cwd().readFileAlloc(testing.io, f.path("r/a"), f.arena(), .limited(100));
    try testing.expectEqualStrings("local\n", content);
    try expectErr(try call1(f, "git_switch", r, ",\"branch\":\"other\",\"create\":true,\"start_point\":\"-f\""), "'-'");
}

test "switch create and detach" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.commitFile(r, "a", "1\n", "first");
    try expectOk(try call1(f, "git_switch", r, ",\"branch\":\"n\",\"create\":true,\"start_point\":\"HEAD\""));
    try testing.expectEqualStrings("n\n", try f.git(r, &.{ "branch", "--show-current" }));
    try expectErr(try call1(f, "git_switch", r, ",\"branch\":\"a b\",\"create\":true"), "not a valid branch name");
    try expectOk(try call1(f, "git_switch", r, ",\"branch\":\"main\",\"detach\":true"));
    try testing.expectEqualStrings("", try f.git(r, &.{ "branch", "--show-current" }));
}

test "tag create and list; no overwrite" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.commitFile(r, "a", "1\n", "first");
    try expectOk(try call1(f, "git_tag", r, ",\"action\":\"create\",\"name\":\"v1\",\"message\":\"release one\""));
    try expectOk(try call1(f, "git_tag", r, ",\"action\":\"create\",\"name\":\"light\",\"ref\":\"HEAD\""));
    const listed = try call1(f, "git_tag", r, ",\"action\":\"list\"");
    try expectOk(listed);
    try testing.expect(contains(listed.text, "v1"));
    try testing.expect(contains(listed.text, "release one"));
    const filtered = try call1(f, "git_tag", r, ",\"action\":\"list\",\"pattern\":\"v*\"");
    try testing.expect(!contains(filtered.text, "light"));
    try f.commitFile(r, "b", "2\n", "second");
    try expectErr(try call1(f, "git_tag", r, ",\"action\":\"create\",\"name\":\"v1\",\"message\":\"again\""), "git exited");
    try expectErr(try call1(f, "git_tag", r, ",\"action\":\"delete\",\"name\":\"v1\""), "must be one of");
    // The original tag still points at the first commit.
    try testing.expectEqualStrings("1\n", try f.git(r, &.{ "rev-list", "--count", "v1" }));
}

test "stash push, list, pop; no drop" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.commitFile(r, "a", "1\n", "first");
    try f.writeFile("r/a", "changed\n");
    try expectOk(try call1(f, "git_stash", r, ",\"action\":\"push\",\"message\":\"wip\""));
    try testing.expectEqualStrings("", try f.git(r, &.{ "status", "--porcelain" }));
    const listed = try call1(f, "git_stash", r, ",\"action\":\"list\"");
    try expectOk(listed);
    try testing.expect(contains(listed.text, "stash@{0}"));
    try testing.expect(contains(listed.text, "wip"));
    const shown = try call1(f, "git_stash", r, ",\"action\":\"show\",\"patch\":true,\"index\":0");
    try expectOk(shown);
    try testing.expect(contains(shown.text, "+changed"));
    try expectOk(try call1(f, "git_stash", r, ",\"action\":\"pop\""));
    try testing.expectEqualStrings(" M a\n", try f.git(r, &.{ "status", "--porcelain" }));
    try testing.expectEqualStrings("", try f.git(r, &.{ "stash", "list" }));

    try expectErr(try call1(f, "git_stash", r, ",\"action\":\"drop\""), "must be one of");
    try expectErr(try call1(f, "git_stash", r, ",\"action\":\"clear\""), "must be one of");
    try expectErr(try call1(f, "git_stash", r, ",\"action\":\"apply\",\"index\":-1"), "index");
}

test "stash include_untracked and apply keeps the stash" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.commitFile(r, "a", "1\n", "first");
    try f.writeFile("r/new", "n\n");
    try expectOk(try call1(f, "git_stash", r, ",\"action\":\"push\",\"include_untracked\":true"));
    try testing.expectEqualStrings("", try f.git(r, &.{ "status", "--porcelain" }));
    try expectOk(try call1(f, "git_stash", r, ",\"action\":\"apply\",\"index\":0"));
    try testing.expectEqualStrings("?? new\n", try f.git(r, &.{ "status", "--porcelain" }));
    try testing.expect(contains(try f.git(r, &.{ "stash", "list" }), "stash@{0}"));
}
