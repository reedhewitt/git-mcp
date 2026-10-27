# git-mcp
A local MCP server for sandboxed agents to perform git tasks

git-mcp is a small [Model Context Protocol](https://modelcontextprotocol.io) server, written in Zig with no dependencies. The agent host launches it as a normal process on your machine, outside the agent's sandbox. It exposes the usual git operations as tools and runs your own `git` with your own environment.

## Why

Some agent hosts run the agent inside a sandbox, for example a Linux VM that mounts your project folder. Two everyday git workflows break there:

1. **Local writes trip the sandbox.** Ordinary git operations replace files inside `.git` (the index, refs, lock files, packed objects). The sandbox treats those as file deletions and either asks you for permission over and over or blocks them.
2. **SSH is blocked.** The sandbox has no network path to SSH remotes and no access to your SSH agent or keys, so `fetch`, `pull`, and `push` against `git@host:...` remotes fail.

With git-mcp, the agent keeps editing working-tree files the way it already does, and every git operation goes through the server. It uses your SSH agent, `~/.ssh/config`, hooks, signing setup, and credential helpers, so none of it has to be reachable from inside the sandbox.

## Not a security boundary

git-mcp treats the agent and the repositories it touches as trusted. It is the same risk as running git from an unsandboxed command-line agent. Repo-local hooks, `core.hooksPath`, `core.fsmonitor`, `core.sshCommand`, filters, and diff drivers all behave exactly as they do in your terminal, and git-mcp makes no attempt to neutralize them.

By design, git-mcp lets git, and therefore anything a repository's hooks or config run, execute on your machine outside the agent's sandbox. If you rely on the sandbox to handle untrusted repositories or content, be aware that git-mcp opens the sandbox up for git.

The restrictions described below on destructive operations and on argument injection exist to prevent accidents, not because the agent is distrusted: a mistake by the agent should not cost you work.

## Build

Requires Zig 0.17.0.

```sh
zig build -Doptimize=ReleaseSmall
```

The binary is `zig-out/bin/git-mcp`. It speaks MCP over stdio.

## Configure Claude desktop

Add the server to `claude_desktop_config.json`, using the absolute path to the binary you built:

```json
{
  "mcpServers": {
    "git": {
      "command": "/path/to/git-mcp/zig-out/bin/git-mcp"
    }
  }
}
```

To use a specific `git` binary instead of the first one on `PATH`, set `GIT_MCP_GIT`:

```json
{
  "mcpServers": {
    "git": {
      "command": "/path/to/git-mcp/zig-out/bin/git-mcp",
      "env": { "GIT_MCP_GIT": "/path/to/git" }
    }
  }
}
```

Restart the app after editing the config.

### Suggested agent instruction

Add a line like this to the agent's global instructions so it does not try to run git in the sandbox shell:

> For all git operations, use the git-mcp tools with the project's absolute host path instead of running git in the shell.

Every repository tool takes an absolute `repo` path on the host (a leading `~/` is accepted), not a path as seen from inside the sandbox.

## Tools

| Tool | What it does |
| --- | --- |
| `git_status` | Branch, ahead/behind, staged, unstaged, and untracked changes, and any merge, rebase, or cherry-pick in progress. |
| `git_diff` | Unified diff of unstaged changes, staged changes, or against a ref or range; `stat_only` for a summary. |
| `git_log` | Commit history, with filters for ref, paths, date, author, and message. |
| `git_show` | One commit's message and diff, or the object a ref names. |
| `git_blame` | Which commit and author last changed each line of a file, optionally for a line range. |
| `git_fetch` | Download commits, branches, and tags from a remote without touching your working tree. |
| `git_pull` | Fetch and integrate into the current branch (merge, rebase, or fast-forward only). |
| `git_push` | Push one branch to the remote branch of the same name (like `push.default=simple`). The remote is `remote`, else the branch's `pushRemote`, `remote.pushDefault`, its upstream remote, or `origin`. If the current branch tracks a differently named branch on that remote, it refuses unless you pass `branch`. Never forces, deletes remote refs, or mirrors. |
| `git_clone` | Clone a remote repository into a new directory. |
| `git_init` | Create a new repository; safe in an existing one. |
| `git_remote` | `list`, `add`, `set_url`, or `rename` remotes. |
| `git_add` | Stage specific `paths`, or everything with `all`. |
| `git_unstage` | Remove files from the index and keep your edits. |
| `git_rm` | Remove tracked files and stage the removal; `cached` keeps them on disk. Never forces. |
| `git_mv` | Move or rename a tracked file; never overwrites. |
| `git_commit` | Commit the staged changes; supports `amend`. |
| `git_reset` | Move the branch with `soft` or `mixed` (default). Working-tree files are never overwritten. |
| `git_branch` | `list`, `create`, `rename`, `delete` (safe delete only), or `set_upstream`. |
| `git_switch` | Switch branches, create one, or detach. Refuses rather than discard changes. |
| `git_tag` | `list` or `create` tags (lightweight or annotated); never overwrites. |
| `git_stash` | `push`, `pop`, `apply`, `list`, or `show`. |
| `git_merge` | `start`, `continue`, or `abort` a merge. |
| `git_rebase` | `start` (optionally `onto`), `continue`, `skip`, or `abort` a rebase. Never interactive. |
| `git_cherry_pick` | Apply commits; `continue`, `skip`, or `abort` on conflict. |
| `git_revert` | Create commits that undo earlier ones; `continue`, `skip`, or `abort` on conflict. |
| `git_resolve` | Resolve conflicted files by taking the `ours` or `theirs` side of each path. |

Every git command is non-interactive: no editor, pager, or terminal prompt can open. Most local operations time out after 30 seconds. Network operations (`fetch`, `pull`, `push`, `clone`) and local operations that run hooks (`commit`, `merge`, `rebase`, `cherry-pick`, `revert`, `stash`, `switch`) get 120 seconds. On a timeout git and its children get SIGTERM, so git can remove its lock files, and SIGKILL 3 seconds later if they are still running. If git was interrupted anyway, a stale `.git/*.lock` file may need removing. Long output is truncated with a note telling the agent how to narrow the request.

## Deliberately unavailable

These operations are left out entirely. They are not hidden behind a flag, and there is no "confirm" escape hatch. Do them in your own terminal.

- Force pushes of any kind (`--force`, `--force-with-lease`, `+refspec`, `--mirror`)
- Deleting remote refs (`push --delete`, `push :branch`)
- `reset --hard`, `reset --merge`, `reset --keep`
- `clean` in any form
- `branch -D` and `branch --delete --force`, `branch -M` and `-C` (overwriting rename or copy)
- `stash drop`, `stash clear`
- Discarding uncommitted working-tree changes: `restore` of worktree files, `checkout -- <path>`, `checkout -f`, `switch --discard-changes` and `--force`
- `rm -f` and `rm --force`
- `tag -d` and `tag -f`
- `remote remove`
- `gc --prune=now`, `reflog expire`, `update-ref -d`, and other plumbing

Operations that can be recovered through the reflog or the remote are available: rebase, `reset --soft` and `--mixed`, `commit --amend`, `branch -d`, `fetch --prune`, cherry-pick, revert, and merge or rebase `--abort`.

Refs, branch, tag, and remote names, and URLs may not begin with `-`, pathspecs always follow `--`, and commit messages are passed as `--message=<text>`, so a value from the agent can never turn into a git option. The test suite exercises each exclusion above.

## Troubleshooting

The server writes one startup line to stderr, showing the version, which `git` it uses, and whether `PATH` and `SSH_AUTH_SOCK` were found (never their values). Claude desktop writes MCP server stderr to `~/Library/Logs/Claude/mcp-server-<name>.log`, where `<name>` is the key you used in the config (`git` in the examples above).

- **SSH agent not visible.** Apps launched from the Dock or Finder do not inherit your shell's `SSH_AUTH_SOCK`. If it is unset, on macOS git-mcp falls back to `launchctl getenv SSH_AUTH_SOCK`. If that is empty too, the startup line says so; set `SSH_AUTH_SOCK` in the config's `env` block, or make sure your agent is loaded at login.
- **Passphrase-protected keys.** Git cannot prompt, so a key must already be loaded in the agent. Run `ssh-add` in a terminal (on macOS, `ssh-add --apple-use-keychain` stores the passphrase).
- **Host key not yet trusted.** Network operations run ssh in batch mode, so an unknown host fails instead of asking. Connect once from a terminal (`ssh git@host`) to add the host to `known_hosts`. git-mcp does not override `GIT_SSH_COMMAND`, `GIT_SSH`, or `core.sshCommand` if you have set them.
- **Commit signing.** Signing works only if the key or passphrase is available without a terminal. GPG signing that relies on a GUI pinentry needs a pinentry program that works in the host app's session; otherwise sign in your terminal or turn signing off for the repository.
- **Errors about a path that exists.** The agent may have passed a path as the sandbox sees it. The `repo` argument must be the path on your machine.

## Development

```sh
zig build test
```

Tests create throwaway repositories and bare remotes in temporary directories with an isolated git configuration, so they never touch your own repositories or settings. `src/tools/guard_test.zig` checks that every excluded destructive operation is rejected and leaves refs, files, stashes, and the remote unchanged.

## License

See [LICENSE](LICENSE).
