# allstar-team

A Claude Code plugin: agents in `agents/`, commands in `commands/`, the shared output spec in `docs/output-formats.md`, and small scripts in `scripts/`. See `README.md`.

This repo keeps `.claude/allstar-team.yml` local (gitignored), so agents reviewing this repo use the defaults.

## Work in a linked worktree, never the primary checkout

All new work happens in a linked git worktree. The primary checkout (the directory the repo was cloned into) is left alone, because it often has someone else's branch and uncommitted state.

Create a worktree from the primary checkout and work there:

```
git fetch origin
git worktree add -b <branch> ../worktrees/<name> origin/main
```

Worktrees branch from `origin/main` after `git fetch`, so the primary checkout's branch rarely needs updating. To update it, use a plain shell or `ALLSTAR_ALLOW_PRIMARY=1` (below).

The project hook `.claude/hooks/require-worktree.py`, wired in `.claude/settings.json`, enforces this for Edit, Write, NotebookEdit and Bash:

- Edit, Write and NotebookEdit are denied when the target file (or, for a new file, its nearest existing parent directory, with symlinks resolved) is in a primary checkout. They are allowed in linked worktrees, including `--detach` ones, and outside any git repo.
- Bash git commands that target a primary checkout are allowed only from this allowlist:
  - read-only: `status`, `log`, `diff`, `show`, `rev-parse`, `ls-files`, `grep`, `blame`, `merge-base`, `rev-list`, `describe`, `ls-remote`, `ls-tree`, `cat-file`, `for-each-ref`, `show-ref`, `shortlog`, `name-rev`, `check-ignore`, `version`, `help`, `git --version`/`--help`, list-form `branch` (including `--contains`/`--merged <commit>`), `remote` and `remote -v`, `config --get`, query-form `symbolic-ref` (no `-d`, no second argument), `stash list`, and `tag` with no arguments or with `-l`/`--list`
  - `fetch`
  - `worktree add|remove|prune|list`

  Every other git subcommand is denied, and so is any global option other than `-C` and the pager/lock flags (so `-c`, `--git-dir`, `--work-tree` are denied), as well as an inline `GIT_DIR=`/`GIT_WORK_TREE=` prefix. The target is the session directory, adjusted for `cd`/`pushd <dir>` and `git -C <dir>`, plus any `--git-dir`/`--work-tree`.
- `gh pr checkout`, `gh pr merge -d|--delete-branch` and `gh repo sync` are denied in a primary checkout.
- The hook skips heredoc bodies, splits the command on `;`, `&&`, `||`, `|`, `&`, parentheses and newlines, looks through `VAR=value`, `time`, `command`, `exec` and `nice` prefixes, and carries `export GIT_DIR=`/`GIT_WORK_TREE=` forward to later commands. `cd`/`pushd` options such as `--` are skipped.
- If the command cannot be parsed (for example unbalanced quotes in a comment or in `$'...'`), it is denied when the session directory is a primary checkout and the command mentions `git` or `gh`, with a message asking you to split it or simplify its quoting. Otherwise it is allowed.
- A primary checkout is a repo whose `git rev-parse --git-dir` equals its `--git-common-dir`, checked with every `GIT_*` variable removed from the environment.

The hook needs `python3` and git 2.31 or later (`rev-parse --path-format=absolute`). It fails open: if it hits any internal error (malformed hook input, git missing, or git older than 2.31, detected when `rev-parse` does not return absolute paths), it prints one line, `require-worktree: disabled (<reason>)`, to stderr and allows the call. An unparseable Bash command is not an internal error; it is handled as described above.

### Escape hatch: `ALLSTAR_ALLOW_PRIMARY=1`

Setting `ALLSTAR_ALLOW_PRIMARY=1` when you start the session (`ALLSTAR_ALLOW_PRIMARY=1 claude`) disables the primary-checkout block for that whole session. It is an escape hatch only, for maintainers doing repo-level chores in the primary checkout. Do not set it by default.

The hook reads the variable from its own process environment. Writing it inline in a command (`ALLSTAR_ALLOW_PRIMARY=1 git commit ...`) has no effect, and the command is still denied.

### Known gaps

The hook prevents accidents. It is not a security boundary. It inspects only Edit, Write, NotebookEdit and the git and `gh` invocations it can parse. These are not blocked:

- non-git writes from Bash, such as `sed -i`, `>` redirects, `cp`, `rm` or scripts, and git's own file outputs such as `git diff --output=<file>`
- git or gh run through another program or a nested shell: `bash -c`, `sh -c`, `eval`, `xargs`, `env`, `sudo`, `find -exec`, aliases and shell functions
- command substitution and process substitution: backticks, `$(...)`, `<(...)`
- `popd`, `cd -` (the directory is left unchanged), and a `cd` inside a `( ... )` subshell, which is treated as if it carried on after the subshell
- an unparseable command whose session directory is not the primary checkout but that `cd`s into it or uses `git -C <primary>`
- `gh` commands other than the three listed above (merge policy belongs to the plugin hook, #10)
- a primary checkout reached through `GIT_DIR`/`GIT_WORK_TREE` set in the environment the session was started with (only an inline prefix on the command is caught)

## Checks

There is no CI. Before pushing, run:

- `bash scripts/check-output-contract.sh` after editing a shared output block
- `bash scripts/test-require-worktree.sh` after changing the worktree hook
