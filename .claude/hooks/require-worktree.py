#!/usr/bin/env python3
"""PreToolUse hook: keep new work out of the primary checkout.

Denies Edit/Write and mutating git commands whose target is a primary checkout
(a repo whose git dir equals its common dir), so new work happens in a linked
worktree. Targets outside any git repo, and linked worktrees, are allowed.

This guards against accidents. It is not a security boundary: non-git writes
from Bash (sed -i, redirects, scripts) are not inspected.

Reads the hook input JSON on stdin. To deny, prints a PreToolUse
permissionDecision of "deny" and exits 0. Otherwise prints nothing and exits 0,
so the normal permission flow applies.
"""
import json
import os
import re
import shlex
import subprocess
import sys

# ESCAPE HATCH: ALLSTAR_ALLOW_PRIMARY=1
# When this variable is set to 1 in the environment Claude Code was started
# with (for example `ALLSTAR_ALLOW_PRIMARY=1 claude`), this hook allows
# everything and the primary-checkout block is disabled for that whole session.
# It is an escape hatch only, for maintainers doing repo-level chores in the
# primary checkout. It is read from this hook process's own environment, never
# from the Bash command text, so an inline `ALLSTAR_ALLOW_PRIMARY=1 git commit`
# is still denied.
ESCAPE_HATCH = "ALLSTAR_ALLOW_PRIMARY"

SUGGESTION = "git worktree add -b <branch> ../worktrees/<name> origin/main"

# git subcommands allowed in the primary checkout without further checks.
READ_ONLY = {"status", "log", "diff", "show", "rev-parse", "ls-files", "grep", "blame", "fetch"}
WORKTREE_OK = {"list", "add", "remove", "prune"}
# Global git options that do not change the target or behaviour.
HARMLESS_GLOBAL = {"--no-pager", "-P", "--paginate", "-p", "--no-optional-locks"}
# `git branch` flags that only list.
BRANCH_LIST_FLAGS = {"-a", "--all", "-r", "--remotes", "-v", "-vv", "--verbose", "-l", "--list",
                     "--show-current", "--contains", "--no-contains", "--merged", "--no-merged",
                     "--points-at", "--color", "--no-color", "--column", "--no-column",
                     "-i", "--ignore-case", "--omit-empty"}
SEPARATORS = {"&&", "||", ";", "|", "&", "(", ")", "\n", ";;", "|&"}
ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")


def git_dirs(path):
    """Return (git_dir, common_dir) for the repo containing path, or None if not in a repo."""
    path = os.path.realpath(path)
    while not os.path.exists(path):
        parent = os.path.dirname(path)
        if parent == path:
            return None
        path = parent
    if not os.path.isdir(path):
        path = os.path.dirname(path)
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_DIR", "GIT_WORK_TREE")}
    r = subprocess.run(
        ["git", "-C", path, "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"],
        capture_output=True, text=True, env=env,
    )
    lines = r.stdout.split("\n")
    if r.returncode != 0 or len(lines) < 2:
        return None
    return os.path.realpath(lines[0]), os.path.realpath(lines[1])


def primary_root(path):
    """Return the primary checkout's root if path is inside a primary checkout, else None."""
    dirs = git_dirs(path)
    if dirs is None or dirs[0] != dirs[1]:
        return None
    common = dirs[1]
    return os.path.dirname(common) if os.path.basename(common) == ".git" else common


def resolve(base, d):
    return os.path.normpath(os.path.join(base, os.path.expanduser(os.path.expandvars(d))))


def git_allowed(args):
    """args: argv after `git`. True if the command is on the primary-checkout allowlist."""
    i = 0
    while i < len(args) and args[i].startswith("-"):
        if args[i] == "-C":
            i += 2  # the target was already resolved by git_target
            continue
        if args[i] not in HARMLESS_GLOBAL:
            return False  # includes `git -c`, --git-dir, --work-tree
        i += 1
    if i >= len(args):
        return True
    sub, rest = args[i], args[i + 1:]
    if sub in READ_ONLY:
        return True
    if sub == "worktree":
        return bool(rest) and rest[0] in WORKTREE_OK
    if sub == "branch":
        flags = [a for a in rest if a.startswith("-")]
        positional = [a for a in rest if not a.startswith("-")]
        if any(f not in BRANCH_LIST_FLAGS and not f.startswith(("--format=", "--sort=")) for f in flags):
            return False
        return not positional or "-l" in flags or "--list" in flags
    if sub == "remote":
        return rest in (["-v"], ["--verbose"])
    if sub == "config":
        return bool(rest) and rest[0] == "--get"
    return False


def git_target(args, cwd):
    """Apply every `-C <dir>` before the subcommand to cwd."""
    i = 0
    while i < len(args) and args[i].startswith("-"):
        if args[i] == "-C" and i + 1 < len(args):
            cwd = resolve(cwd, args[i + 1])
            i += 2
            continue
        i += 1
    return cwd


def segments(command):
    lex = shlex.shlex(command, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    lex.commenters = ""
    seg = []
    for tok in lex:
        if tok in SEPARATORS:
            if seg:
                yield seg
            seg = []
        else:
            seg.append(tok)
    if seg:
        yield seg


def check_bash(command, cwd):
    """Return (target, description) for the first denied command, or None."""
    try:
        segs = list(segments(command))
    except ValueError:
        return None  # unbalanced quotes: the shell will reject it anyway
    for argv in segs:
        while argv and ASSIGNMENT.match(argv[0]):
            argv = argv[1:]  # inline VAR=value prefixes, including ALLSTAR_ALLOW_PRIMARY
        if not argv:
            continue
        prog = os.path.basename(argv[0])
        if prog == "cd":
            cwd = resolve(cwd, argv[1] if len(argv) > 1 else "~")
        elif prog == "git":
            target = git_target(argv[1:], cwd)
            root = primary_root(target)
            if root and not git_allowed(argv[1:]):
                return root, " ".join(argv)
        elif prog == "gh" and argv[1:3] == ["pr", "checkout"]:
            root = primary_root(cwd)
            if root:
                return root, " ".join(argv)
    return None


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))
    sys.exit(0)


def main():
    if os.environ.get(ESCAPE_HATCH) == "1":
        return  # escape hatch, see the comment at the top of this file
    data = json.load(sys.stdin)
    tool = data.get("tool_name")
    tool_input = data.get("tool_input") or {}
    cwd = data.get("cwd") or os.getcwd()
    if tool in ("Edit", "Write"):
        path = tool_input.get("file_path")
        if not path:
            return
        path = resolve(cwd, path)
        root = primary_root(path)
        if root:
            deny(f"require-worktree: {path} is in the primary checkout {root}. "
                 f"Do new work in a linked worktree instead. From {root} run: {SUGGESTION} "
                 f"and edit the file there.")
    elif tool == "Bash":
        hit = check_bash(tool_input.get("command") or "", cwd)
        if hit:
            root, cmd = hit
            deny(f"require-worktree: `{cmd}` targets the primary checkout {root}, where only "
                 f"read-only git, fetch and `git worktree add|remove|prune|list` are allowed. "
                 f"Do new work in a linked worktree instead. From {root} run: {SUGGESTION} "
                 f"and run the command there.")


if __name__ == "__main__":
    main()
