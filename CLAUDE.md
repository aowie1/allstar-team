# allstar-team

A Claude Code plugin: agents in `agents/`, commands in `commands/`, the shared output spec in `docs/output-formats.md`, and small scripts in `scripts/`. See `README.md`.

## Work in a linked worktree, never the primary checkout

All new work happens in a linked git worktree. The primary checkout (the directory the repo was cloned into) is left alone, because it often has someone else's branch and uncommitted state.

Create a worktree from the primary checkout and work there:

```
git worktree add -b <branch> ../worktrees/<name> origin/main
```

The project hook `.claude/hooks/require-worktree.py`, wired in `.claude/settings.json`, enforces this for Edit, Write and Bash:

- Edit and Write are denied when the target file (or, for a new file, its nearest existing parent directory) is in a primary checkout. They are allowed in linked worktrees, including `--detach` ones, and outside any git repo.
- Bash git commands that target a primary checkout (the session directory, adjusted for `cd <dir> &&` and `git -C <dir>`) are allowed only if they are read-only (`status`, `log`, `diff`, `show`, `rev-parse`, `ls-files`, `grep`, `blame`, list-form `branch`, `remote -v`, `config --get`), `fetch`, or `worktree add|remove|prune|list`. Every other git subcommand, any `git -c`, and `gh pr checkout` are denied.
- A primary checkout is a repo whose `git rev-parse --git-dir` equals its `--git-common-dir`.

The hook needs only `python3`.

### Escape hatch: `ALLSTAR_ALLOW_PRIMARY=1`

Setting `ALLSTAR_ALLOW_PRIMARY=1` when you start the session (`ALLSTAR_ALLOW_PRIMARY=1 claude`) disables the primary-checkout block for that whole session. It is an escape hatch only, for maintainers doing repo-level chores in the primary checkout. Do not set it by default.

The hook reads the variable from its own process environment. Writing it inline in a command (`ALLSTAR_ALLOW_PRIMARY=1 git commit ...`) has no effect, and the command is still denied.

### Known gaps

The hook prevents accidents. It is not a security boundary. It inspects only Edit, Write and git or `gh pr checkout` invocations it can parse. Non-git writes from Bash, such as `sed -i`, `>` redirects, `cp`, or scripts, are not blocked. Neither are git commands hidden behind other programs (`bash -c`, `xargs`, `env`).

## Checks

There is no CI. Before pushing, run:

- `bash scripts/check-output-contract.sh` after editing a shared output block
- `bash scripts/test-require-worktree.sh` after changing the worktree hook
