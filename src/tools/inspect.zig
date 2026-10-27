//! Read-only inspection tools.
const std = @import("std");
const common = @import("common.zig");
const Ctx = common.Ctx;
const Args = common.Args;
const ToolResult = common.ToolResult;
const validate = @import("../validate.zig");

pub const tools = [_]common.Tool{
    .{
        .name = "git_status",
        .description = "Show the state of a repository on the HOST machine: current branch, ahead/behind its upstream, staged, unstaged, and untracked changes, and any merge, rebase, or cherry-pick in progress (with git's hints on how to continue). Use it before committing, after pulling, or whenever you are unsure what state the repo is in. Pass the repository's absolute host path, not a sandbox path.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ common.repo_prop ++
            \\,"untracked":{"type":"boolean","description":"List untracked files (default true). Set false to hide them in large trees."}},"required":["repo"]}
        ,
        .handler = status,
    },
    .{
        .name = "git_diff",
        .description = "Show changes as a unified diff on the HOST. By default shows unstaged changes (working tree vs index); with 'staged' shows what is staged for commit; with 'ref' compares against a commit or range (e.g. 'main', 'HEAD~3', 'a..b', 'a...b'). Use 'stat_only' for a per-file summary first when the change may be large; output is capped at 100 KiB.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ common.repo_prop ++
            \\,"staged":{"type":"boolean","description":"Show staged changes (index vs HEAD) instead of unstaged."},"ref":{"type":"string","description":"Commit, or range a..b / a...b, to diff against. Must not start with '-'."},"paths":{"type":"array","items":{"type":"string"},"description":"Limit the diff to these paths (relative to the repo)."},"stat_only":{"type":"boolean","description":"Only show a per-file change summary."},"context_lines":{"type":"integer","minimum":0,"description":"Lines of context around each change (default 3)."}},"required":["repo"]}
        ,
        .handler = diffTool,
    },
    .{
        .name = "git_log",
        .description = "Show commit history on the HOST. Defaults to the 20 most recent commits in one-line form for the current branch. Use 'ref' for another branch/tag/range, 'paths' to see history of specific files, and 'since', 'author', 'grep' to filter. Set 'oneline' false for full messages, authors, and dates.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ common.repo_prop ++
            \\,"ref":{"type":"string","description":"Branch, tag, commit, or range to start from (default: HEAD). Must not start with '-'."},"max_count":{"type":"integer","minimum":1,"maximum":500,"description":"Maximum commits to show (default 20, max 500)."},"paths":{"type":"array","items":{"type":"string"},"description":"Only commits touching these paths."},"oneline":{"type":"boolean","description":"One line per commit (default true). false gives full commit details."},"since":{"type":"string","description":"Only commits after this date, e.g. '2 weeks ago' or '2026-01-01'."},"author":{"type":"string","description":"Only commits whose author matches this pattern."},"grep":{"type":"string","description":"Only commits whose message matches this pattern."}},"required":["repo"]}
        ,
        .handler = logTool,
    },
    .{
        .name = "git_show",
        .description = "Show one commit on the HOST: its message, author, date, and diff (or the object a ref names). Defaults to HEAD. Use 'stat_only' for a file summary of a large commit, and 'paths' to restrict the diff.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ common.repo_prop ++
            \\,"ref":{"type":"string","description":"Commit, tag, or <rev>:<path> to show (default: HEAD). Must not start with '-'."},"paths":{"type":"array","items":{"type":"string"},"description":"Limit the diff to these paths."},"stat_only":{"type":"boolean","description":"Only show a per-file change summary."}},"required":["repo"]}
        ,
        .handler = showTool,
    },
    .{
        .name = "git_blame",
        .description = "Show which commit and author last changed each line of a file, on the HOST. Use 'start_line' and 'end_line' together to limit the output to a range, which is advisable for large files.",
        .schema = "{\"type\":\"object\",\"properties\":{" ++ common.repo_prop ++
            \\,"path":{"type":"string","description":"File to annotate, relative to the repo."},"ref":{"type":"string","description":"Commit to blame as of (default: working tree). Must not start with '-'."},"start_line":{"type":"integer","minimum":1,"description":"First line of the range (requires end_line)."},"end_line":{"type":"integer","minimum":1,"description":"Last line of the range (requires start_line)."}},"required":["repo","path"]}
        ,
        .handler = blameTool,
    },
};

fn status(ctx: *Ctx, args: Args) !ToolResult {
    const repo = try ctx.repo(args);
    const untracked = try args.boolean("untracked") orelse true;
    // Long format: it reports ahead/behind and in-progress operations with hints.
    const argv: []const []const u8 = if (untracked) &.{"status"} else &.{ "status", "-uno" };
    return ctx.git(repo, argv, false);
}

fn optRef(ctx: *Ctx, args: Args) !?[]const u8 {
    const r = try args.str("ref") orelse return null;
    try validate.checkName("ref", r, &ctx.diag);
    return r;
}

fn optPaths(ctx: *Ctx, args: Args) ![]const []const u8 {
    const ps = try args.strList(ctx.arena, "paths") orelse return &.{};
    for (ps) |p| try validate.checkPath(p, &ctx.diag);
    return ps;
}

fn diffTool(ctx: *Ctx, args: Args) !ToolResult {
    const repo = try ctx.repo(args);
    const staged = try args.boolean("staged") orelse false;
    const stat_only = try args.boolean("stat_only") orelse false;
    const context = try args.int("context_lines");
    const ref = try optRef(ctx, args);
    const paths = try optPaths(ctx, args);

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(ctx.arena, "diff");
    if (staged) try argv.append(ctx.arena, "--cached");
    if (stat_only) try argv.append(ctx.arena, "--stat");
    if (context) |n| {
        if (n < 0 or n > 1000) return ctx.fail("'context_lines' must be between 0 and 1000", .{});
        try argv.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "-U{d}", .{n}));
    }
    if (ref) |r| try argv.append(ctx.arena, r);
    try argv.append(ctx.arena, "--");
    try argv.appendSlice(ctx.arena, paths);
    return ctx.git(repo, argv.items, false);
}

fn logTool(ctx: *Ctx, args: Args) !ToolResult {
    const repo = try ctx.repo(args);
    const n = try args.int("max_count") orelse 20;
    if (n < 1 or n > 500) return ctx.fail("'max_count' must be between 1 and 500", .{});
    const oneline = try args.boolean("oneline") orelse true;
    const since = try args.str("since");
    const author = try args.str("author");
    const grep = try args.str("grep");
    const ref = try optRef(ctx, args);
    const paths = try optPaths(ctx, args);

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(ctx.arena, "log");
    try argv.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "--max-count={d}", .{n}));
    if (oneline) try argv.appendSlice(ctx.arena, &.{ "--oneline", "--decorate" });
    if (since) |v| try argv.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "--since={s}", .{v}));
    if (author) |v| try argv.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "--author={s}", .{v}));
    if (grep) |v| try argv.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "--grep={s}", .{v}));
    if (ref) |r| try argv.append(ctx.arena, r);
    try argv.append(ctx.arena, "--");
    try argv.appendSlice(ctx.arena, paths);
    return ctx.git(repo, argv.items, false);
}

fn showTool(ctx: *Ctx, args: Args) !ToolResult {
    const repo = try ctx.repo(args);
    const stat_only = try args.boolean("stat_only") orelse false;
    const ref = try optRef(ctx, args) orelse "HEAD";
    const paths = try optPaths(ctx, args);

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(ctx.arena, "show");
    if (stat_only) try argv.append(ctx.arena, "--stat");
    try argv.append(ctx.arena, ref);
    try argv.append(ctx.arena, "--");
    try argv.appendSlice(ctx.arena, paths);
    return ctx.git(repo, argv.items, false);
}

fn blameTool(ctx: *Ctx, args: Args) !ToolResult {
    const repo = try ctx.repo(args);
    const path = try args.reqStr("path");
    try validate.checkPath(path, &ctx.diag);
    const ref = try optRef(ctx, args);
    const start = try args.int("start_line");
    const end = try args.int("end_line");

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(ctx.arena, "blame");
    if (start != null or end != null) {
        const s = start orelse return ctx.fail("'start_line' and 'end_line' must be given together", .{});
        const e = end orelse return ctx.fail("'start_line' and 'end_line' must be given together", .{});
        if (s < 1 or e < s) return ctx.fail("line range must satisfy 1 <= start_line <= end_line", .{});
        try argv.append(ctx.arena, "-L");
        try argv.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "{d},{d}", .{ s, e }));
    }
    if (ref) |r| try argv.append(ctx.arena, r);
    try argv.append(ctx.arena, "--");
    try argv.append(ctx.arena, path);
    return ctx.git(repo, argv.items, false);
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

fn callRepo(f: *Fixture, tool: []const u8, r: []const u8, extra: []const u8) !common.ToolResult {
    const args = try std.fmt.allocPrint(f.arena(), "{{\"repo\":\"{s}\"{s}}}", .{ r, extra });
    return f.call(tool, args);
}

test "diff unstaged, staged, stat" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.commitFile(r, "a.txt", "old\n", "first");
    try f.writeFile("r/a.txt", "new\n");

    const un = try callRepo(f, "git_diff", r, "");
    try testing.expect(!un.is_error);
    try testing.expect(contains(un.text, "+new"));

    const st0 = try callRepo(f, "git_diff", r, ",\"staged\":true");
    try testing.expectEqualStrings("OK (no output)", st0.text);

    _ = try f.git(r, &.{ "add", "--", "a.txt" });
    const st = try callRepo(f, "git_diff", r, ",\"staged\":true");
    try testing.expect(contains(st.text, "+new"));
    const un2 = try callRepo(f, "git_diff", r, "");
    try testing.expectEqualStrings("OK (no output)", un2.text);

    const stat = try callRepo(f, "git_diff", r, ",\"staged\":true,\"stat_only\":true");
    try testing.expect(contains(stat.text, "1 file changed"));

    const rng = try callRepo(f, "git_diff", r, ",\"ref\":\"HEAD\",\"paths\":[\"a.txt\"],\"context_lines\":1");
    try testing.expect(!rng.is_error);
    try testing.expect(contains(rng.text, "+new"));

    const bad = try callRepo(f, "git_diff", r, ",\"ref\":\"--output=x\"");
    try testing.expect(bad.is_error);
}

test "diff of huge file is truncated, response valid" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    const a = f.arena();
    const size = 3 * 1024 * 1024;
    const big = try a.alloc(u8, size);
    @memset(big, 'a');
    var i: usize = 79;
    while (i < size) : (i += 80) big[i] = '\n';
    try f.commitFile(r, "big.txt", big, "big");
    @memset(big, 'b');
    i = 79;
    while (i < size) : (i += 80) big[i] = '\n';
    try f.writeFile("r/big.txt", big);

    const res = try callRepo(f, "git_diff", r, "");
    try testing.expect(!res.is_error);
    try testing.expect(std.mem.endsWith(u8, res.text, common.truncation_note));
    try testing.expect(res.text.len <= common.output_cap + common.truncation_note.len);
    try testing.expect(std.unicode.utf8ValidateSlice(res.text));
}

test "log defaults and limits" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    var i: usize = 0;
    while (i < 25) : (i += 1) {
        const msg = try std.fmt.allocPrint(f.arena(), "c{d}", .{i});
        try f.commitFile(r, "a.txt", msg, msg);
    }
    const res = try callRepo(f, "git_log", r, "");
    try testing.expect(!res.is_error);
    try testing.expectEqual(@as(usize, 20), std.mem.count(u8, res.text, "\n"));

    const five = try callRepo(f, "git_log", r, ",\"max_count\":5,\"grep\":\"c2\",\"author\":\"Test\",\"paths\":[\"a.txt\"]");
    try testing.expect(!five.is_error);
    try testing.expect(contains(five.text, "c24"));

    const full = try callRepo(f, "git_log", r, ",\"max_count\":1,\"oneline\":false");
    try testing.expect(contains(full.text, "Author: Test"));

    const over = try callRepo(f, "git_log", r, ",\"max_count\":600");
    try testing.expect(over.is_error);
    const zero = try callRepo(f, "git_log", r, ",\"max_count\":0");
    try testing.expect(zero.is_error);
    const dash = try callRepo(f, "git_log", r, ",\"ref\":\"-p\"");
    try testing.expect(dash.is_error);
}

test "log on unborn branch is an error result, not a crash" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    const res = try callRepo(f, "git_log", r, "");
    try testing.expect(res.is_error);
}

test "log with latin-1 commit message is sanitized" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.writeFile("r/a.txt", "x\n");
    _ = try f.git(r, &.{ "add", "--", "a.txt" });
    try f.writeFile("msg.txt", "caf\xe9\n");
    _ = try f.git(r, &.{ "-c", "i18n.commitEncoding=latin1", "commit", "-q", "-F", f.path("msg.txt") });
    const res = try callRepo(f, "git_log", r, "");
    try testing.expect(!res.is_error);
    try testing.expect(std.unicode.utf8ValidateSlice(res.text));
}

test "show and blame" {
    const f = try Fixture.init();
    defer f.deinit();
    const r = try f.initRepo("r");
    try f.commitFile(r, "a.txt", "l1\nl2\n", "the subject");

    const show = try callRepo(f, "git_show", r, "");
    try testing.expect(!show.is_error);
    try testing.expect(contains(show.text, "the subject"));
    const ss = try callRepo(f, "git_show", r, ",\"ref\":\"HEAD\",\"stat_only\":true,\"paths\":[\"a.txt\"]");
    try testing.expect(contains(ss.text, "1 file changed"));

    const b = try callRepo(f, "git_blame", r, ",\"path\":\"a.txt\",\"start_line\":1,\"end_line\":1");
    try testing.expect(!b.is_error);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, b.text, "\n"));
    const all = try callRepo(f, "git_blame", r, ",\"path\":\"a.txt\",\"ref\":\"HEAD\"");
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, all.text, "\n"));

    const bad = try callRepo(f, "git_blame", r, ",\"path\":\"a.txt\",\"start_line\":2,\"end_line\":1");
    try testing.expect(bad.is_error);
    const half = try callRepo(f, "git_blame", r, ",\"path\":\"a.txt\",\"start_line\":1");
    try testing.expect(half.is_error);
    const zero = try callRepo(f, "git_blame", r, ",\"path\":\"a.txt\",\"start_line\":0,\"end_line\":1");
    try testing.expect(zero.is_error);
    const nopath = try callRepo(f, "git_blame", r, "");
    try testing.expect(nopath.is_error);
}
