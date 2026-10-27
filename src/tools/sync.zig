//! Tools that talk to remotes or create repositories: fetch, pull, push,
//! clone, init, and remote management.
const std = @import("std");
const common = @import("common.zig");
const Ctx = common.Ctx;
const Args = common.Args;
const ToolResult = common.ToolResult;
const validate = @import("../validate.zig");

const remote_prop =
    \\"remote":{"type":"string","description":"Remote name (default: the branch's upstream remote, else git's default)."}
;

const push_remote_prop =
    \\"remote":{"type":"string","description":"Remote to push to (default: the branch's pushRemote, then remote.pushDefault, then its upstream remote, then origin)."}
;

pub const tools = [_]common.Tool{
    .{
        .name = "git_fetch",
        .description = "Download commits, branches, and tags from a remote without changing your working tree or local branches. Use it to see what others pushed (then compare with git_status or a log) before deciding to pull, merge, or rebase. Runs on the HOST with the user's SSH agent and credentials.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ common.repo_prop ++ "," ++ remote_prop ++
            \\,"all":{"type":"boolean","description":"Fetch from every configured remote."},"prune":{"type":"boolean","description":"Remove remote-tracking branches that no longer exist on the remote."},"tags":{"type":"boolean","description":"Also fetch all tags."}},"required":["repo"]}
        ,
        .handler = fetch,
    },
    .{
        .name = "git_pull",
        .description = "Fetch from a remote and integrate the changes into the current branch (merge or rebase). Use it to bring a branch up to date, and to resolve a push that was rejected as non-fast-forward. If it stops on conflicts, inspect them with git_status. Runs on the HOST with the user's SSH agent and credentials.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ common.repo_prop ++ "," ++ remote_prop ++
            \\,"branch":{"type":"string","description":"Remote branch to pull. Requires 'remote'. Default: the current branch's upstream."},"rebase":{"type":"boolean","description":"true: rebase onto the fetched branch; false: merge. Omit to follow the user's git config."},"ff_only":{"type":"boolean","description":"Only fast-forward; fail instead of creating a merge commit."}},"required":["repo"]}
        ,
        .handler = pull,
    },
    .{
        .name = "git_push",
        .description = "Upload the commits of one local branch to a remote. Use it after committing to publish your work. It pushes the current branch (or 'branch') to the branch of the SAME name on the remote, like git's push.default=simple. If the current branch tracks a differently named remote branch (e.g. a 'feat' branch created from origin/main), it refuses rather than update that branch; pass 'branch' to push it under its own name. It NEVER force-pushes, deletes remote branches, or mirrors, even if git config asks for it. If the push is rejected as non-fast-forward (the remote has commits you don't), run git_pull, resolve any conflicts, and push again. Runs on the HOST with the user's SSH agent and credentials.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ common.repo_prop ++ "," ++ push_remote_prop ++
            \\,"branch":{"type":"string","description":"Local branch to push (default: the current branch); it is pushed to the remote branch of the same name. A plain name only: no '+' or ':' refspecs."},"set_upstream":{"type":"boolean","description":"Record the pushed branch as this branch's upstream (git push -u). Use on the first push of a new branch."},"tags":{"type":"boolean","description":"Also push tags (never forced: tags that differ on the remote are rejected)."}},"required":["repo"]}
        ,
        .handler = push,
    },
    .{
        .name = "git_clone",
        .description = "Clone a remote repository into a new directory on the HOST machine. Use it to get a local copy of a repository to work in. The target directory must not exist or must be empty, and its parent must exist. Runs with the user's SSH agent and credentials.",
        .schema =
        \\{"type":"object","properties":{"url":{"type":"string","description":"Repository URL (https://, ssh://, git@host:path, or an absolute path)."},"directory":{"type":"string","description":"Absolute HOST path (or ~/…) of the new directory to clone into. Not a sandbox path."},"branch":{"type":"string","description":"Branch to check out instead of the remote's default."},"depth":{"type":"integer","minimum":1,"description":"Create a shallow clone with this many commits."}},"required":["url","directory"]}
        ,
        .handler = clone,
    },
    .{
        .name = "git_init",
        .description = "Create a new, empty git repository on the HOST machine. Use it to start version control in a new or existing directory. Running it in an existing repository is safe and does not overwrite anything.",
        .schema =
        \\{"type":"object","properties":{"directory":{"type":"string","description":"Absolute HOST path (or ~/…) of the directory to initialize; created if missing (its parent must exist). Not a sandbox path."},"initial_branch":{"type":"string","description":"Name of the first branch (default: git's configured default)."}},"required":["directory"]}
        ,
        .handler = init,
    },
    .{
        .name = "git_remote",
        .description = "List, add, re-point, or rename a repository's remotes. Use 'list' to see which remotes exist and their URLs before fetching or pushing; 'add' to connect a new remote; 'set_url' to change where a remote points; 'rename' to rename one. Removing remotes is not supported.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ common.repo_prop ++
            \\,"action":{"type":"string","enum":["list","add","set_url","rename"],"description":"What to do."},"name":{"type":"string","description":"Remote name (add, set_url, rename)."},"url":{"type":"string","description":"Remote URL (add, set_url)."},"new_name":{"type":"string","description":"New remote name (rename)."}},"required":["repo","action"]}
        ,
        .handler = remote,
    },
};

/// Agent-supplied remote name, validated.
fn optRemote(ctx: *Ctx, args: Args) !?[]const u8 {
    const r = try args.str("remote") orelse return null;
    try validate.checkName("remote", r, &ctx.diag);
    return r;
}

/// Trimmed stdout of a helper git query, or null if it failed or printed nothing.
fn query(ctx: *Ctx, cwd: []const u8, argv: []const []const u8) !?[]const u8 {
    const res = try ctx.runner.run(ctx.arena, .{ .cwd = cwd, .args = argv });
    if (res.exit_code == null or res.exit_code.? != 0) return null;
    const out = std.mem.trim(u8, res.stdout, " \t\r\n");
    return if (out.len == 0) null else out;
}

fn configGet(ctx: *Ctx, cwd: []const u8, comptime fmt: []const u8, a: anytype) !?[]const u8 {
    const key = try std.fmt.allocPrint(ctx.arena, fmt, a);
    return query(ctx, cwd, &.{ "config", "--get", key });
}

fn fetch(ctx: *Ctx, args: Args) !ToolResult {
    const repo = try ctx.repo(args);
    const r = try optRemote(ctx, args);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(ctx.arena, "fetch");
    if (try args.boolean("all") orelse false) try argv.append(ctx.arena, "--all");
    if (try args.boolean("prune") orelse false) try argv.append(ctx.arena, "--prune");
    if (try args.boolean("tags") orelse false) try argv.append(ctx.arena, "--tags");
    if (r) |name| try argv.append(ctx.arena, name);
    return ctx.git(repo, argv.items, true);
}

fn pull(ctx: *Ctx, args: Args) !ToolResult {
    const repo = try ctx.repo(args);
    const r = try optRemote(ctx, args);
    const branch = try args.str("branch");
    if (branch) |b| {
        // A refspec or glob here could force-update or write local branches.
        try validate.checkBranch(b, &ctx.diag);
        if (r == null) return ctx.fail("'branch' requires 'remote'", .{});
    }
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(ctx.arena, "pull");
    if (try args.boolean("rebase")) |rb| try argv.append(ctx.arena, if (rb) "--rebase" else "--no-rebase");
    if (try args.boolean("ff_only") orelse false) try argv.append(ctx.arena, "--ff-only");
    if (r) |name| try argv.append(ctx.arena, name);
    if (branch) |b| try argv.append(ctx.arena, b);
    return ctx.git(repo, argv.items, true);
}

fn push(ctx: *Ctx, args: Args) !ToolResult {
    const repo = try ctx.repo(args);

    // Validate agent input before it is used to build config keys.
    const branch_arg = try args.str("branch");
    if (branch_arg) |b| try validate.checkPushBranch(b, &ctx.diag);
    const remote_arg = try optRemote(ctx, args);

    const branch = branch_arg orelse
        try query(ctx, repo, &.{ "symbolic-ref", "--short", "-q", "HEAD" }) orelse
        return ctx.fail("HEAD is detached; pass 'branch' explicitly", .{});
    try validate.checkPushBranch(branch, &ctx.diag);

    // push.default=simple: pick the remote the way `git push` does, and
    // always push to the branch of the same name.
    const upstream_remote = try configGet(ctx, repo, "branch.{s}.remote", .{branch});
    const r = remote_arg orelse
        try configGet(ctx, repo, "branch.{s}.pushRemote", .{branch}) orelse
        try query(ctx, repo, &.{ "config", "--get", "remote.pushDefault" }) orelse
        upstream_remote orelse "origin";
    try validate.checkName("remote", r, &ctx.diag);
    if (std.mem.eql(u8, r, ".")) return ctx.fail("remote '.' is a local repository; nothing to push", .{});

    // Without an explicit 'branch', refuse when the upstream on this remote
    // has a different name (git's "simple" rule). A merge value outside
    // refs/heads/ counts as different.
    if (branch_arg == null) if (upstream_remote) |ur| if (std.mem.eql(u8, ur, r)) {
        if (try configGet(ctx, repo, "branch.{s}.merge", .{branch})) |merge| {
            const heads = "refs/heads/";
            const other = if (std.mem.startsWith(u8, merge, heads)) merge[heads.len..] else merge;
            if (!std.mem.startsWith(u8, merge, heads) or !std.mem.eql(u8, other, branch)) {
                return ctx.fail("branch '{s}' tracks '{s}/{s}', a different name; push refuses to update a differently named remote branch. Pass 'branch' to push '{s}' under its own name, or push from a terminal.", .{ branch, r, other, branch });
            }
        }
    };

    const mirror_key = try std.fmt.allocPrint(ctx.arena, "remote.{s}.mirror", .{r});
    if (try query(ctx, repo, &.{ "config", "--type=bool", "--get", mirror_key })) |m| {
        if (std.mem.eql(u8, m, "true")) {
            return ctx.fail("remote '{s}' is configured as a mirror; pushing to it is not supported", .{r});
        }
    }

    // An explicit refspec without '+' overrides any configured remote.<r>.push.
    const refspec = try std.fmt.allocPrint(ctx.arena, "refs/heads/{s}:refs/heads/{s}", .{ branch, branch });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(ctx.arena, "push");
    if (try args.boolean("set_upstream") orelse false) try argv.append(ctx.arena, "-u");
    if (try args.boolean("tags") orelse false) try argv.append(ctx.arena, "--tags");
    try argv.appendSlice(ctx.arena, &.{ r, refspec });
    return ctx.git(repo, argv.items, true);
}

fn clone(ctx: *Ctx, args: Args) !ToolResult {
    const url = try args.reqStr("url");
    try validate.checkUrl(url, &ctx.diag);
    const target = try validate.resolveTarget(ctx.arena, ctx.runner.io, ctx.home, try args.reqStr("directory"), &ctx.diag);
    const branch = try args.str("branch");
    if (branch) |b| try validate.checkName("branch", b, &ctx.diag);
    const depth = try args.int("depth");
    if (depth) |d| if (d < 1) return ctx.fail("'depth' must be at least 1", .{});

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(ctx.arena, "clone");
    if (branch) |b| try argv.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "--branch={s}", .{b}));
    if (depth) |d| try argv.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "--depth={d}", .{d}));
    try argv.appendSlice(ctx.arena, &.{ "--", url, target });
    return ctx.git(std.fs.path.dirname(target) orelse "/", argv.items, true);
}

fn init(ctx: *Ctx, args: Args) !ToolResult {
    const target = try validate.resolveTarget(ctx.arena, ctx.runner.io, ctx.home, try args.reqStr("directory"), &ctx.diag);
    const initial = try args.str("initial_branch");
    if (initial) |b| try validate.checkName("branch", b, &ctx.diag);

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(ctx.arena, "init");
    if (initial) |b| try argv.appendSlice(ctx.arena, &.{ "-b", b });
    try argv.appendSlice(ctx.arena, &.{ "--", target });
    return ctx.git(std.fs.path.dirname(target) orelse "/", argv.items, false);
}

const RemoteAction = enum { list, add, set_url, rename };

fn remote(ctx: *Ctx, args: Args) !ToolResult {
    const repo = try ctx.repo(args);
    const action = try args.enumOf(RemoteAction, "action") orelse return ctx.fail("'action' is required", .{});
    if (action == .list) return ctx.git(repo, &.{ "remote", "-v" }, false);

    const name = try args.reqStr("name");
    try validate.checkName("remote", name, &ctx.diag);
    switch (action) {
        .list => unreachable,
        .add, .set_url => {
            const url = try args.reqStr("url");
            try validate.checkUrl(url, &ctx.diag);
            const sub = if (action == .add) "add" else "set-url";
            return ctx.git(repo, &.{ "remote", sub, name, url }, false);
        },
        .rename => {
            const new_name = try args.reqStr("new_name");
            try validate.checkName("remote", new_name, &ctx.diag);
            return ctx.git(repo, &.{ "remote", "rename", name, new_name }, false);
        },
    }
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

fn refExists(f: *Fixture, repo: []const u8, ref: []const u8) !bool {
    const res = try f.runner.run(f.arena(), .{ .cwd = repo, .args = &.{ "rev-parse", "--verify", "-q", ref } });
    return res.exit_code != null and res.exit_code.? == 0;
}

/// `a` (main, one commit) pushed to bare `origin.git` with upstream set.
fn pushedRepo(f: *Fixture) !struct { a: []const u8, bare: []const u8 } {
    const bare = try f.initBare("origin.git");
    const a = try f.initRepo("a");
    try f.commitFile(a, "file", "one\n", "first");
    _ = try f.git(a, &.{ "remote", "add", "origin", bare });
    _ = try f.git(a, &.{ "push", "-q", "-u", "origin", "main" });
    return .{ .a = a, .bare = bare };
}

test "init, commit, push, clone, pull round trip" {
    const f = try Fixture.init();
    defer f.deinit();
    const ar = f.arena();
    const bare = try f.initBare("origin.git");
    const a = f.path("a");

    try expectOk(try f.call("git_init", try std.fmt.allocPrint(ar, "{{\"directory\":\"{s}\",\"initial_branch\":\"main\"}}", .{a})));
    try f.commitFile(a, "file", "one\n", "first");
    try expectOk(try f.call("git_remote", try std.fmt.allocPrint(ar, "{{\"repo\":\"{s}\",\"action\":\"add\",\"name\":\"origin\",\"url\":\"{s}\"}}", .{ a, bare })));
    const listed = try f.call("git_remote", try std.fmt.allocPrint(ar, "{{\"repo\":\"{s}\",\"action\":\"list\"}}", .{a}));
    try expectOk(listed);
    try testing.expect(contains(listed.text, "origin"));
    try testing.expect(contains(listed.text, bare));

    try expectOk(try f.call("git_push", try std.fmt.allocPrint(ar, "{{\"repo\":\"{s}\",\"set_upstream\":true}}", .{a})));
    try testing.expectEqualStrings("refs/heads/main\n", try f.git(a, &.{ "config", "branch.main.merge" }));
    try testing.expectEqualStrings("origin\n", try f.git(a, &.{ "config", "branch.main.remote" }));

    const b = f.path("b");
    try expectOk(try f.call("git_clone", try std.fmt.allocPrint(ar, "{{\"url\":\"{s}\",\"directory\":\"{s}\"}}", .{ bare, b })));
    try testing.expect(fileExists(f.path("b/file")));

    try f.commitFile(a, "second", "two\n", "second");
    try expectOk(try f.call("git_push", try std.fmt.allocPrint(ar, "{{\"repo\":\"{s}\"}}", .{a})));
    try expectOk(try f.call("git_fetch", try std.fmt.allocPrint(ar, "{{\"repo\":\"{s}\",\"prune\":true}}", .{b})));
    try expectOk(try f.call("git_pull", try std.fmt.allocPrint(ar, "{{\"repo\":\"{s}\",\"ff_only\":true}}", .{b})));
    try testing.expect(fileExists(f.path("b/second")));
}

test "push refuses to publish a branch into a differently named upstream" {
    const f = try Fixture.init();
    defer f.deinit();
    const ar = f.arena();
    const r = try pushedRepo(f);
    _ = try f.git(r.a, &.{ "fetch", "-q", "origin" });
    _ = try f.git(r.a, &.{ "switch", "-q", "-c", "feat", "--track", "origin/main" });
    try testing.expectEqualStrings("refs/heads/main\n", try f.git(r.a, &.{ "config", "branch.feat.merge" }));
    try f.commitFile(r.a, "feat", "f\n", "feature");
    const main_before = try f.git(r.bare, &.{ "rev-parse", "refs/heads/main" });

    const res = try f.call("git_push", try std.fmt.allocPrint(ar, "{{\"repo\":\"{s}\"}}", .{r.a}));
    try expectErr(res, "branch 'feat' tracks 'origin/main', a different name; push refuses to update a differently named remote branch. Pass 'branch' to push 'feat' under its own name, or push from a terminal.");
    try testing.expectEqualStrings(main_before, try f.git(r.bare, &.{ "rev-parse", "refs/heads/main" }));
    try testing.expect(!try refExists(f, r.bare, "refs/heads/feat"));

    // Naming the branch explicitly pushes it under its own name.
    try expectOk(try f.call("git_push", try std.fmt.allocPrint(ar, "{{\"repo\":\"{s}\",\"branch\":\"feat\"}}", .{r.a})));
    try testing.expectEqualStrings(try f.git(r.a, &.{ "rev-parse", "feat" }), try f.git(r.bare, &.{ "rev-parse", "refs/heads/feat" }));
    try testing.expectEqualStrings(main_before, try f.git(r.bare, &.{ "rev-parse", "refs/heads/main" }));
}

test "push treats a merge value outside refs/heads as mismatched" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try pushedRepo(f);
    _ = try f.git(r.a, &.{ "config", "branch.main.merge", "main" });
    const res = try f.call("git_push", try std.fmt.allocPrint(f.arena(), "{{\"repo\":\"{s}\"}}", .{r.a}));
    try expectErr(res, "branch 'main' tracks 'origin/main', a different name");
}

test "push honors branch pushRemote and remote.pushDefault" {
    const f = try Fixture.init();
    defer f.deinit();
    const ar = f.arena();
    const r = try pushedRepo(f);
    const fork = try f.initBare("fork.git");
    const other = try f.initBare("other.git");
    _ = try f.git(r.a, &.{ "remote", "add", "fork", fork });
    _ = try f.git(r.a, &.{ "remote", "add", "other", other });
    try f.commitFile(r.a, "two", "2\n", "second");
    const head = try f.git(r.a, &.{ "rev-parse", "HEAD" });
    const origin_before = try f.git(r.bare, &.{ "rev-parse", "refs/heads/main" });

    _ = try f.git(r.a, &.{ "config", "remote.pushDefault", "other" });
    try expectOk(try f.call("git_push", try std.fmt.allocPrint(ar, "{{\"repo\":\"{s}\"}}", .{r.a})));
    try testing.expectEqualStrings(head, try f.git(other, &.{ "rev-parse", "refs/heads/main" }));

    // branch.<b>.pushRemote wins over remote.pushDefault.
    _ = try f.git(r.a, &.{ "config", "branch.main.pushRemote", "fork" });
    try expectOk(try f.call("git_push", try std.fmt.allocPrint(ar, "{{\"repo\":\"{s}\"}}", .{r.a})));
    try testing.expectEqualStrings(head, try f.git(fork, &.{ "rev-parse", "refs/heads/main" }));

    // The upstream remote was never pushed to.
    try testing.expectEqualStrings(origin_before, try f.git(r.bare, &.{ "rev-parse", "refs/heads/main" }));
}

test "push rejects the local remote '.'" {
    const f = try Fixture.init();
    defer f.deinit();
    const ar = f.arena();
    const r = try pushedRepo(f);
    const explicit = try f.call("git_push", try std.fmt.allocPrint(ar, "{{\"repo\":\"{s}\",\"remote\":\".\"}}", .{r.a}));
    try expectErr(explicit, "remote '.' is a local repository; nothing to push");

    // `git branch -t topic main` records remote '.'.
    _ = try f.git(r.a, &.{ "switch", "-q", "-c", "topic", "--track", "main" });
    try testing.expectEqualStrings(".\n", try f.git(r.a, &.{ "config", "branch.topic.remote" }));
    const configured = try f.call("git_push", try std.fmt.allocPrint(ar, "{{\"repo\":\"{s}\"}}", .{r.a}));
    try expectErr(configured, "remote '.' is a local repository; nothing to push");
}

test "push never forces, even with force refspec in config" {
    const f = try Fixture.init();
    defer f.deinit();
    const ar = f.arena();
    const r = try pushedRepo(f);
    const b = f.path("b");
    _ = try f.git(f.root, &.{ "clone", "-q", r.bare, b });

    try f.commitFile(r.a, "from-a", "a\n", "a side");
    _ = try f.git(r.a, &.{ "push", "-q", "origin", "main" });
    try f.commitFile(b, "from-b", "b\n", "b side");
    _ = try f.git(b, &.{ "config", "remote.origin.push", "+refs/heads/*:refs/heads/*" });

    const res = try f.call("git_push", try std.fmt.allocPrint(ar, "{{\"repo\":\"{s}\"}}", .{b}));
    try testing.expect(res.is_error);
    try testing.expect(contains(res.text, "rejected") or contains(res.text, "non-fast-forward"));
    const a_head = try f.git(r.a, &.{ "rev-parse", "HEAD" });
    try testing.expectEqualStrings(a_head, try f.git(r.bare, &.{ "rev-parse", "refs/heads/main" }));
}

test "push refuses mirror remotes" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try pushedRepo(f);
    _ = try f.git(r.a, &.{ "config", "remote.origin.mirror", "yes" });
    const res = try f.call("git_push", try std.fmt.allocPrint(f.arena(), "{{\"repo\":\"{s}\"}}", .{r.a}));
    try expectErr(res, "remote 'origin' is configured as a mirror; pushing to it is not supported");
}

test "push rejects force-looking branch names" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try pushedRepo(f);
    const cases = [_]struct { branch: []const u8, needle: []const u8 }{
        .{ .branch = "+main", .needle = "terminal" },
        .{ .branch = "main:x", .needle = "terminal" },
        .{ .branch = ":main", .needle = "terminal" },
        .{ .branch = "-f", .needle = "'-'" },
    };
    for (cases) |c| {
        const res = try f.call("git_push", try std.fmt.allocPrint(f.arena(), "{{\"repo\":\"{s}\",\"branch\":\"{s}\"}}", .{ r.a, c.branch }));
        try expectErr(res, c.needle);
    }
    const bad_remote = try f.call("git_push", try std.fmt.allocPrint(f.arena(), "{{\"repo\":\"{s}\",\"remote\":\"--mirror\"}}", .{r.a}));
    try expectErr(bad_remote, "'-'");
}

test "push rejects glob branch names and pushes nothing" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try pushedRepo(f);
    _ = try f.git(r.a, &.{ "branch", "extra1" });
    _ = try f.git(r.a, &.{ "branch", "extra2" });
    const before = try f.git(r.bare, &.{ "for-each-ref", "--format=%(refname)" });
    for ([_][]const u8{ "*", "extra?", "extra[12]" }) |b| {
        const res = try f.call("git_push", try std.fmt.allocPrint(f.arena(), "{{\"repo\":\"{s}\",\"branch\":\"{s}\"}}", .{ r.a, b }));
        try expectErr(res, "not a valid branch name");
    }
    // A glob upstream in config is rejected too.
    _ = try f.git(r.a, &.{ "config", "branch.main.merge", "refs/heads/*" });
    try expectErr(try f.call("git_push", try std.fmt.allocPrint(f.arena(), "{{\"repo\":\"{s}\"}}", .{r.a})), "a different name");
    try testing.expectEqualStrings(before, try f.git(r.bare, &.{ "for-each-ref", "--format=%(refname)" }));
}

test "pull rejects glob and refspec branches" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try pushedRepo(f);
    for ([_][]const u8{ "*", "+main", "main:main", "a b" }) |b| {
        const res = try f.call("git_pull", try std.fmt.allocPrint(f.arena(), "{{\"repo\":\"{s}\",\"remote\":\"origin\",\"branch\":\"{s}\"}}", .{ r.a, b }));
        try expectErr(res, "branch");
        try testing.expect(!contains(res.text, "git exited"));
    }
}

test "push rejects a force-looking upstream from config" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try pushedRepo(f);
    _ = try f.git(r.a, &.{ "config", "branch.main.merge", "+refs/heads/main" });
    const res = try f.call("git_push", try std.fmt.allocPrint(f.arena(), "{{\"repo\":\"{s}\"}}", .{r.a}));
    try expectErr(res, "a different name");
    try expectErr(res, "push from a terminal");
}

test "push from detached HEAD without branch fails clearly" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try pushedRepo(f);
    _ = try f.git(r.a, &.{ "checkout", "-q", "--detach" });
    const res = try f.call("git_push", try std.fmt.allocPrint(f.arena(), "{{\"repo\":\"{s}\"}}", .{r.a}));
    try expectErr(res, "HEAD is detached; pass 'branch' explicitly");
}

test "clone rejects option-looking url and non-empty target" {
    const f = try Fixture.init();
    defer f.deinit();
    const ar = f.arena();
    const r = try pushedRepo(f);

    const bad_url = try f.call("git_clone", try std.fmt.allocPrint(ar, "{{\"url\":\"-uevil\",\"directory\":\"{s}\"}}", .{f.path("c")}));
    try expectErr(bad_url, "'-'");
    try testing.expect(!fileExists(f.path("c")));

    try f.writeFile("full/x.txt", "x\n");
    const full = try f.call("git_clone", try std.fmt.allocPrint(ar, "{{\"url\":\"{s}\",\"directory\":\"{s}\"}}", .{ r.bare, f.path("full") }));
    try expectErr(full, "not an empty directory");

    const depth0 = try f.call("git_clone", try std.fmt.allocPrint(ar, "{{\"url\":\"{s}\",\"directory\":\"{s}\",\"depth\":0}}", .{ r.bare, f.path("d") }));
    try expectErr(depth0, "depth");

    const rel = try f.call("git_clone", try std.fmt.allocPrint(ar, "{{\"url\":\"{s}\",\"directory\":\"rel/d\"}}", .{r.bare}));
    try expectErr(rel, "absolute host path");
}

test "clone with branch and depth" {
    const f = try Fixture.init();
    defer f.deinit();
    const ar = f.arena();
    const r = try pushedRepo(f);
    try f.commitFile(r.a, "f2", "2\n", "second");
    _ = try f.git(r.a, &.{ "push", "-q", "origin", "main:other" });
    const url = try std.fmt.allocPrint(ar, "file://{s}", .{r.bare});
    try expectOk(try f.call("git_clone", try std.fmt.allocPrint(ar, "{{\"url\":\"{s}\",\"directory\":\"{s}\",\"branch\":\"other\",\"depth\":1}}", .{ url, f.path("c") })));
    try testing.expectEqualStrings("other\n", try f.git(f.path("c"), &.{ "symbolic-ref", "--short", "HEAD" }));
    try testing.expectEqualStrings("1\n", try f.git(f.path("c"), &.{ "rev-list", "--count", "HEAD" }));
}

test "remote has no remove action" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try pushedRepo(f);
    const res = try f.call("git_remote", try std.fmt.allocPrint(f.arena(), "{{\"repo\":\"{s}\",\"action\":\"remove\",\"name\":\"origin\"}}", .{r.a}));
    try expectErr(res, "'action' must be one of: list, add, set_url, rename");
    try testing.expectEqualStrings("origin\n", try f.git(r.a, &.{"remote"}));
}

test "remote set_url and rename" {
    const f = try Fixture.init();
    defer f.deinit();
    const ar = f.arena();
    const r = try pushedRepo(f);
    try expectOk(try f.call("git_remote", try std.fmt.allocPrint(ar, "{{\"repo\":\"{s}\",\"action\":\"set_url\",\"name\":\"origin\",\"url\":\"https://example.com/r.git\"}}", .{r.a})));
    try testing.expectEqualStrings("https://example.com/r.git\n", try f.git(r.a, &.{ "remote", "get-url", "origin" }));
    try expectOk(try f.call("git_remote", try std.fmt.allocPrint(ar, "{{\"repo\":\"{s}\",\"action\":\"rename\",\"name\":\"origin\",\"new_name\":\"upstream\"}}", .{r.a})));
    try testing.expectEqualStrings("upstream\n", try f.git(r.a, &.{"remote"}));

    try expectErr(try f.call("git_remote", try std.fmt.allocPrint(ar, "{{\"repo\":\"{s}\",\"action\":\"add\",\"name\":\"x\"}}", .{r.a})), "'url' is required");
    try expectErr(try f.call("git_remote", try std.fmt.allocPrint(ar, "{{\"repo\":\"{s}\",\"action\":\"add\",\"name\":\"x\",\"url\":\"--upload-pack=evil\"}}", .{r.a})), "'-'");
    try expectErr(try f.call("git_remote", try std.fmt.allocPrint(ar, "{{\"repo\":\"{s}\"}}", .{r.a})), "'action' is required");
}

test "pull rejects a branch without a remote" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try pushedRepo(f);
    const res = try f.call("git_pull", try std.fmt.allocPrint(f.arena(), "{{\"repo\":\"{s}\",\"branch\":\"main\"}}", .{r.a}));
    try expectErr(res, "'remote'");
}

test "network ops use batch ssh" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    _ = try f.git(r, &.{ "remote", "add", "origin", "ssh://nobody@127.0.0.1:1/x.git" });
    const start = Io.Clock.Timestamp.now(testing.io, .awake);
    const res = try f.call("git_fetch", try std.fmt.allocPrint(f.arena(), "{{\"repo\":\"{s}\",\"remote\":\"origin\"}}", .{r}));
    const elapsed = start.untilNow(testing.io).raw.toMilliseconds();
    try testing.expect(res.is_error);
    try testing.expect(elapsed < 10_000);
}
