# git-mcp — Design

Date: 2026-10-27
Status: reviewed, awaiting approval

## Intent

Some AI agent hosts run the agent inside a sandbox (for example, a Linux VM that mounts the
user's project folder). Two everyday git workflows break there:

1. **Local writes trip the sandbox.** Ordinary git operations replace files inside `.git`
   (index, refs, lock files, packed objects). The sandbox treats those as file deletions and
   asks the user for permission over and over, or blocks them outright.
2. **SSH is blocked.** The sandbox has no network path to SSH remotes and no access to the
   user's SSH agent or keys, so `fetch`, `pull`, and `push` against `git@github.com:…`
   style remotes fail.

git-mcp is a small local MCP server that the agent host launches **as a normal process on the
user's machine**, outside the sandbox. It exposes the standard set of git operations as MCP
tools. The agent keeps editing working-tree files the way it already does; every git
operation goes through git-mcp, which runs the user's own `git` with the user's own
environment (SSH agent, `~/.ssh/config`, hooks, signing, credential helpers).

The motivating case: an agent maintains a markdown knowledge base and is told to commit and
push after every round of edits. That works in an unsandboxed CLI agent but not in a
sandboxed desktop agent. The goal is for the sandboxed agent to do the same git work, without
permission prompts, across any repo, including real coding projects.

This is a public, generic tool. Nothing specific to one user's machine, paths, or accounts
belongs in the repo.

## Trust model (decided)

git-mcp treats the agent and the repos it touches as **trusted**. The risk is the same as
running git from an unsandboxed CLI agent. Repo-local hooks, `core.hooksPath`,
`core.fsmonitor`, `core.sshCommand`, filters, and diff drivers all behave exactly as they do
in the user's terminal. git-mcp makes no attempt to neutralize them.

The README must say plainly that git-mcp is **not a security boundary**. By design, it lets
git (and therefore anything a repo's hooks or config run) execute on the host, outside the
agent's sandbox. Users who rely on the sandbox to handle untrusted repos or content should
know that git-mcp opens the sandbox up for git.

The anti-goals below about destructive operations and argument injection aren't about
distrusting the agent. They exist to prevent accidents: an agent mistake shouldn't be able
to cost the user work.

## Goals

- Cover the git operations a developer uses day to day: inspect, stage, commit, branch,
  merge, rebase, stash, tag, remotes, fetch/pull/push, clone, init, and conflict resolution.
- Remote operations work over SSH using the user's existing SSH agent and configuration,
  with no extra setup in git-mcp.
- Ship as a single small native binary with no runtime dependency other than `git` itself.
  Optimize for small binary size and low memory use.
- Never hang. Every git invocation is non-interactive and returns a result or a clear error.
- Make errors useful to an agent. Say what went wrong and what to do instead.

## Non-goals

- Reimplementing git. git-mcp shells out to the installed `git` binary.
- Restricting which repos the agent may touch. There is no allowlist; any path the user can
  access is fair game.
- A generic "run arbitrary git arguments" tool. (It would reopen the door to destructive
  flags; see Anti-goals.)
- Interactive git features: `rebase -i`, `add -p`, editors, pagers, credential prompts.
- Submodules, worktrees, bisect, LFS, sparse checkout, `git config` editing, and
  hosting-provider features (PRs, issues). These can come later.
- Windows support in v1. macOS is the primary target and Linux should work. Nothing should
  needlessly block either.
- An HTTP/SSE transport. v1 uses stdio only.

## Anti-goals (would make it a failure even if it "works")

- **Any path to irrecoverable data loss.** Operations that destroy work and can't be undone
  are left out. They aren't hidden behind a flag, and there's no "confirm" escape hatch. The
  user does those in their own terminal. Specifically excluded:
  - force pushes of any kind (`--force`, `--force-with-lease`, `+refspec`, `--mirror`)
  - deleting remote refs (`push --delete`, `push :branch`)
  - `reset --hard`, `reset --merge`, `reset --keep`
  - `clean` in any form
  - `branch -D` / `branch --delete --force`, `branch -M` / `-C` (overwriting rename/copy)
  - `stash drop`, `stash clear`
  - discarding uncommitted working-tree changes: `restore` of worktree files,
    `checkout -- <path>`, `checkout -f`, `switch --discard-changes` / `--force`
  - `rm -f` / `rm --force`
  - `tag -d`, `tag -f`
  - `remote remove`
  - `gc --prune=now`, `reflog expire`, `update-ref -d`, and any other plumbing
  Operations recoverable through the reflog or the remote are *in* scope (rebase,
  `reset --soft`/`--mixed`, `commit --amend`, `branch -d`, `fetch --prune`, cherry-pick,
  revert, merge/rebase `--abort`).
- **Hanging the agent.** A git command waiting forever on a passphrase, an editor, a pager,
  a host-key prompt, or a stuck network connection.
- **Argument injection.** A ref, path, message, or URL from the agent turning into a git
  option (for example a "branch name" of `--force`) or reaching a shell.
- **Clobbering the user's git/SSH configuration.** git-mcp must not override
  `core.sshCommand`, `GIT_SSH_COMMAND`, credential helpers, or identity settings the user
  has set.
- **Personal data in the repo.** No real usernames, hostnames, home paths, or remotes in code,
  tests, docs, or examples. Use obvious placeholders.

## Constraints

- **Language:** Zig 0.17.0 (current stable). Standard library only, with no third-party
  packages. Target Zig 0.17's std APIs (I/O and the JSON module changed between recent
  releases, so don't copy older examples blindly).
- **Build:** `zig build` produces one executable. A release build
  (`-Doptimize=ReleaseSmall`) should be small, aiming for well under 1 MB, and should idle
  at a few MB of RSS.
- **Protocol:** MCP over stdio, JSON-RPC 2.0, newline-delimited messages. Must handle
  `initialize` (with protocol-version negotiation), `notifications/initialized`, `ping`,
  `tools/list`, and `tools/call`, and return proper JSON-RPC errors for unknown methods
  and malformed input. stdout carries protocol messages only. Diagnostics go to stderr.
- **Host:** Must work as a stdio MCP server launched by Claude desktop via
  `claude_desktop_config.json`. Write it to the MCP spec, not to one host, so other MCP
  clients work too.
- **Paths:** The sandboxed agent may know a project under two paths: a sandbox-internal one
  (for example `/sessions/<id>/mnt/<folder>`) and the real host path. git-mcp runs on the
  host and needs the **host path**.
  - Every repo-scoped tool takes a required `repo` parameter: an absolute host path or a
    `~/`-prefixed path (expanded with `$HOME`). Paths may contain spaces.
  - Relative paths are rejected.
  - A path that doesn't exist on the host is rejected with an error that explains this
    server runs on the host and needs the host path rather than a sandbox mount path. If the
    path looks like a known sandbox mount (for example it begins with `/sessions/`), say so
    explicitly.
  - The server is stateless. There's no "current repo".
- **Environment for every git invocation:**
  - stdin is `/dev/null`. No pager (`--no-pager` or `GIT_PAGER=cat`).
  - `GIT_TERMINAL_PROMPT=0`. `GIT_EDITOR` / `GIT_SEQUENCE_EDITOR` set to a no-op so
    `merge`, `rebase --continue`, `revert`, and similar never open an editor (use git's
    default/prepared messages).
  - SSH must not prompt. If neither `GIT_SSH_COMMAND` nor `core.sshCommand` is set for the
    repo, run with `GIT_SSH_COMMAND="ssh -o BatchMode=yes"`. If the user has set either,
    leave it alone. In that case, prompts are still avoided because stdin is `/dev/null`.
  - Pass through the rest of the inherited environment untouched, including `HOME`,
    `SSH_AUTH_SOCK`, and `PATH`.
  - A timeout kills git (and its children) if it runs too long. The default is generous for
    network operations, around 2 minutes, and may be shorter for local ones. A timeout
    returns an error that says it timed out.
- **Argument safety:**
  - Build argv directly with no shell.
  - Put `--` before pathspecs.
  - Reject agent-supplied refs, branch names, remote names, and tag names that begin with
    `-`. Also validate them with `git check-ref-format` rules where cheap, or let git
    reject them, but never let them be parsed as options.
  - Commit and tag messages go in via `-m`/`-F -`-style argv, never interpolated.
- **Output:** Return git's stdout and stderr as text, with the exit code. A nonzero exit sets
  MCP `isError: true`. Cap very large output (for example at about 100 KB) with a clear
  "truncated — narrow with paths/max_count" note. Tools that list things (`log`, `branch`,
  `tag`, `stash list`) should default to a reasonable limit.

## Tools (decided shape; exact parameter names left to the builder)

All tools except `clone` and `init` take `repo`. "Optional" parameters fall back to git's own
defaults and the user's config.

| Tool | Purpose | Notable parameters / rules |
|---|---|---|
| `git_status` | Working tree state | Include branch, upstream ahead/behind, staged/unstaged/untracked, conflicted files, and any operation in progress (merge, rebase, cherry-pick, revert). A porcelain v2 based summary is fine. |
| `git_diff` | Show changes | `staged`, `ref`/`ref_range`, `paths`, `stat_only`, `context_lines` |
| `git_log` | History | `ref`, `max_count` (default ~20), `paths`, `oneline`, `since`, `author`, `grep` |
| `git_show` | One commit/object | `ref`, `paths`, `stat_only` |
| `git_blame` | Line authorship | `path`, `ref`, `line_range` |
| `git_add` | Stage | `paths` or `all` (`-A`) |
| `git_unstage` | Unstage | `paths` (`restore --staged`) |
| `git_rm` / `git_mv` | Remove/rename tracked files | `rm` without `--force`, with optional `cached`. Git refuses on uncommitted changes, which is the desired safety. |
| `git_commit` | Commit | `message` (required), `amend`, `all`, `allow_empty`. Uses the user's identity and signing config. |
| `git_reset` | Move HEAD / unstage | `mode`: `soft` \| `mixed` only, `ref` |
| `git_branch` | Branches | `action`: list \| create \| delete (`-d` only) \| rename (`-m` only) \| set_upstream. List shows upstream and tracking. |
| `git_switch` | Change branch | `branch`, `create`, `start_point`, `detach`. No `--force`/`--discard-changes`. |
| `git_merge` | Merge | `ref`, `no_ff`, `ff_only`, `squash`, `message`. `action`: start \| continue \| abort |
| `git_rebase` | Non-interactive rebase | `onto`/`upstream`. `action`: start \| continue \| skip \| abort |
| `git_cherry_pick` | Cherry-pick | `refs`. `action`: start \| continue \| skip \| abort |
| `git_revert` | Revert | `refs`, `no_commit`. `action`: start \| continue \| skip \| abort |
| `git_resolve` | Take a side in a conflict | `paths`, `side`: ours \| theirs (`checkout --ours/--theirs`). Only on currently conflicted paths, so it can't be used to discard ordinary edits. The agent then calls `git_add`. Hand edits happen through the agent's normal file editing. |
| `git_stash` | Stash | `action`: push \| pop \| apply \| list \| show. `message`, `include_untracked`, `index` |
| `git_tag` | Tags | `action`: list \| create (lightweight or annotated with `message`) |
| `git_remote` | Remotes | `action`: list (with URLs) \| add \| set_url \| rename |
| `git_fetch` | Fetch | `remote`, `all`, `prune`, `tags` |
| `git_pull` | Pull | `remote`, `branch`, `rebase` (true/false/unset = user config), `ff_only` |
| `git_push` | Push | `remote`, `branch`, `set_upstream`, `tags`. Never force, delete, or mirror, **even through config**: always pass an explicit `refs/heads/<b>:refs/heads/<b>` refspec without `+`, which overrides any configured `remote.<name>.push`. The destination is always the branch of the same name (`push.default=simple` semantics). The remote is `remote`, else `branch.<b>.pushRemote`, `remote.pushDefault`, `branch.<b>.remote`, then `origin`; reject remote `.` (a local repository). If `branch` is omitted, use the current branch; if its upstream is on the chosen remote under a different name (or `branch.<b>.merge` is not under `refs/heads/`), refuse with an error telling the agent to pass `branch` to push under its own name or push from a terminal. An explicit `branch` is always pushed under its own name. Refuse with a clear error if `remote.<name>.mirror` is true. With `tags`, push tags without force, so existing remote tags that differ are rejected by git. *(Builder's call: the "no force/delete/mirror" rule is absolute, not only about tool arguments.)* |
| `git_clone` | Clone | `url`, `directory` (absolute host path or `~/`), `branch`, `depth`. Refuse an existing non-empty directory. |
| `git_init` | Init | `directory`, `initial_branch` |

Tool descriptions should be written for an agent. Each says when to use the tool and points
out the host-path rule. The `repo` parameter description should state the host-path
requirement directly.

## Testing

- Unit tests for argument validation (option-looking refs rejected, `+`/`:` refspecs
  rejected, path rules), JSON-RPC parsing, and output truncation.
- Integration tests that start the built binary, speak MCP over stdio, and run real git
  against temp repos with a **local bare repo as the remote** (`file://`). No network or SSH
  needed in tests. Cover the main flows: init → add → commit → push → clone → pull, a merge
  conflict resolved through `git_resolve` + `git_add` + `git_merge continue`, rebase
  continue/abort, stash push/pop, and the timeout path.
- A test that every excluded destructive operation is unreachable through the tool surface.
- Test a path with spaces, plus the "sandbox path" error message.

## Docs and distribution

- `README.md` covers what it is and why (the sandbox problem, in generic terms), building
  with `zig build -Doptimize=ReleaseSmall`, a `claude_desktop_config.json` snippet with a
  placeholder binary path, the tool list, what's deliberately excluded and why, and a
  suggested line to add to the agent's global instructions ("For all git operations, use
  the git-mcp tools with the project's host path instead of running git in the shell").
- A troubleshooting section that covers SSH agent not visible to the host app
  (`SSH_AUTH_SOCK`), passphrase-protected keys not in the agent, host keys not yet in
  `known_hosts`, and commit signing that needs a GUI pinentry.
- `.gitignore`: keep the existing Zig entries and add OS and editor junk (`.DS_Store`, etc.).
- v1 is build-from-source. Prebuilt release binaries via CI are a follow-up.

## Left to the builder

- Internal code structure, module layout, and how tool schemas are declared.
- Exact parameter names, default limits, timeout values, and truncation size, within the
  guidance above.
- Whether `git_status` returns raw porcelain, a formatted summary, or both.
- How to detect "is `core.sshCommand` set" (for example
  `git config --get core.sshCommand` in the repo).
- Which MCP protocol versions to advertise, as long as current Claude desktop negotiates
  successfully.
