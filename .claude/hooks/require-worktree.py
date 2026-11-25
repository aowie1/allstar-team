#!/usr/bin/env python3
"""PreToolUse hook: keep new work out of the primary checkout.

Denies Edit/Write/NotebookEdit and mutating git commands whose target is a
primary checkout (a repo whose git dir equals its common dir), so new work
happens in a linked worktree. Targets outside any git repo, and linked
worktrees, are allowed.

This guards against accidents. It is not a security boundary: non-git writes
from Bash (sed -i, redirects, scripts) are not inspected. See CLAUDE.md for the
known gaps.

Reads the hook input JSON on stdin. To deny, prints a PreToolUse
permissionDecision of "deny" and exits 0. Otherwise prints nothing and exits 0,
so the normal permission flow applies. On any internal error it fails open:
one stderr line, exit 0. Needs git >= 2.31 (rev-parse --path-format).
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
READ_ONLY = {"status", "log", "diff", "show", "rev-parse", "ls-files", "grep", "blame", "fetch",
             "merge-base", "rev-list", "describe", "ls-remote", "ls-tree", "cat-file",
             "for-each-ref", "show-ref", "shortlog", "name-rev", "check-ignore", "version", "help"}
WORKTREE_OK = {"list", "add", "remove", "prune"}
# Global git options that do not change the target or behaviour.
HARMLESS_GLOBAL = {"--no-pager", "-P", "--paginate", "-p", "--no-optional-locks"}
# `git branch` flags that only list, and the ones among them that take an optional commit.
BRANCH_LIST_FLAGS = {"-a", "--all", "-r", "--remotes", "-v", "-vv", "--verbose", "-l", "--list",
                     "--show-current", "--color", "--no-color", "--column", "--no-column",
                     "-i", "--ignore-case", "--omit-empty"}
BRANCH_COMMIT_FLAGS = {"--contains", "--no-contains", "--merged", "--no-merged", "--points-at"}
TAG_WRITE_FLAGS = {"-d", "--delete", "-a", "--annotate", "-s", "--sign", "-u", "-f", "--force",
                   "-m", "-F", "-e", "--edit"}
SYMREF_READ_FLAGS = {"-q", "--quiet", "--short", "--recurse", "--no-recurse"}
# Prefixes that run the next word as the command.
WRAPPERS = {"time", "command", "exec", "nice"}
ASSIGNMENT = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)", re.S)
PUNCT = set("();<>|&\n")
# `<<EOF`, `<<-EOF`, `<< 'EOF'`, `<<"EOF"`, but not a `<<<` here-string.
HEREDOC = re.compile(r"(?<!<)<<(?!<)-?[ \t]*(['\"]?)([A-Za-z0-9_.-]+)\1")
GIT_OR_GH = re.compile(r"(^|[\s;&|(`])(git|gh)(\s|$)")
SHORT_CLUSTER = re.compile(r"-[A-Za-z]+")


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
    # Drop every GIT_* variable so the session's environment cannot redirect detection.
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    r = subprocess.run(
        ["git", "-C", path, "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir"],
        capture_output=True, text=True, env=env,
    )
    lines = r.stdout.split("\n")
    if r.returncode != 0 or len(lines) < 2:
        return None
    if not (os.path.isabs(lines[0]) and os.path.isabs(lines[1])):
        # git < 2.31 echoes the unknown --path-format option and exits 0.
        raise RuntimeError("git >= 2.31 is required for rev-parse --path-format")
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


def parse_git(args, cwd):
    """Split argv after `git` into (targets, unsafe_global, sub, rest).

    targets: directories the command acts on (cwd after every -C, plus any
    --git-dir/--work-tree). unsafe_global: a global option other than -C and the
    pager/lock flags was given (-c, --git-dir, --work-tree, ...).
    """
    targets, extra, unsafe = [], [], False
    i = 0
    while i < len(args) and args[i].startswith("-"):
        a = args[i]
        if a in ("-C", "-c", "--git-dir", "--work-tree"):
            val = args[i + 1] if i + 1 < len(args) else ""
            if a == "-C":
                cwd = resolve(cwd, val)
            else:
                unsafe = True
                if a != "-c":
                    extra.append(val)
            i += 2
            continue
        if a.startswith(("--git-dir=", "--work-tree=")):
            extra.append(a.split("=", 1)[1])
        if a not in HARMLESS_GLOBAL:
            unsafe = True
        i += 1
    targets = [cwd] + [resolve(cwd, d) for d in extra if d]
    sub = args[i] if i < len(args) else None
    return targets, unsafe, sub, args[i + 1:]


def git_allowed(args, unsafe, sub, rest):
    """True if the git command is on the primary-checkout allowlist."""
    if sub is None:
        return not unsafe or args in (["--version"], ["--help"])
    if unsafe:
        return False
    if sub in READ_ONLY:
        return True
    if sub == "worktree":
        return bool(rest) and rest[0] in WORKTREE_OK
    if sub == "branch":
        positional, i = [], 0
        while i < len(rest):
            a = rest[i]
            if a in BRANCH_COMMIT_FLAGS:
                if i + 1 < len(rest) and not rest[i + 1].startswith("-"):
                    i += 1  # the commit after the flag is not a new branch name
            elif a.startswith("-"):
                name = a.split("=", 1)[0]
                if a not in BRANCH_LIST_FLAGS and name not in BRANCH_COMMIT_FLAGS | {"--format", "--sort"}:
                    return False
            else:
                positional.append(a)
            i += 1
        return not positional or "-l" in rest or "--list" in rest
    if sub == "remote":
        return rest in ([], ["-v"], ["--verbose"])
    if sub == "config":
        return bool(rest) and rest[0] == "--get"
    if sub == "symbolic-ref":
        flags = [a for a in rest if a.startswith("-")]
        return all(f in SYMREF_READ_FLAGS for f in flags) and len(rest) - len(flags) <= 1
    if sub == "stash":
        return rest[:1] == ["list"]
    if sub == "tag":
        listing = not rest or "-l" in rest or "--list" in rest
        return listing and not TAG_WRITE_FLAGS.intersection(rest)
    return False


def gh_denied(args):
    """args: argv after `gh`. True for gh commands that change the local checkout."""
    i = 0
    while i < len(args) and args[i].startswith("-"):
        i += 2 if args[i] in ("-R", "--repo") else 1
    words, rest = args[i:i + 2], args[i + 2:]
    if words == ["pr", "checkout"] or words == ["repo", "sync"]:
        return True
    return words == ["pr", "merge"] and any(
        a in ("-d", "--delete-branch") or (SHORT_CLUSTER.fullmatch(a) and "d" in a) for a in rest)


def strip_heredocs(command):
    """Drop heredoc bodies, which are data, not commands, and may hold unbalanced quotes."""
    out, pending = [], []
    for line in command.split("\n"):
        if pending:
            if line.strip() == pending[0]:
                pending.pop(0)
            continue
        out.append(line)
        pending += [m.group(2) for m in HEREDOC.finditer(line)]
    return "\n".join(out)


def segments(command):
    """Yield the argv of each simple command, split on ; & | ( ) and newlines.

    Redirections and their targets are dropped. Quoted newlines stay in one token.
    Raises ValueError if the command cannot be tokenized.
    """
    lex = shlex.shlex(strip_heredocs(command), posix=True, punctuation_chars="();<>|&\n")
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    lex.commenters = ""
    seg, skip = [], False
    for tok in lex:
        if skip:
            skip = False
        elif set(tok) <= PUNCT:
            redirect = "<" in tok or ">" in tok
            if not redirect or set(tok) & set(";|()\n"):
                if seg:
                    yield seg
                seg = []
            elif seg and seg[-1].isdigit():
                seg.pop()  # fd number, as in 2>/dev/null
            skip = redirect  # the redirect target (a file, or an fd after >&)
        else:
            seg.append(tok)
    if seg:
        yield seg


def check_bash(command, cwd):
    """Return (root, command) for the first denied command, or None.

    command is None when the whole command could not be parsed.
    """
    try:
        segs = list(segments(command))
    except ValueError:
        # Unparseable (odd quoting): deny git/gh from a primary checkout, allow the rest.
        root = primary_root(cwd)
        if root and GIT_OR_GH.search(command):
            return root, None  # main() words the reason for this case
        return None
    exported = []  # GIT_DIR/GIT_WORK_TREE values from `export`, seen by later segments
    for argv in segs:
        extra = list(exported)
        while argv:
            m = ASSIGNMENT.fullmatch(argv[0])
            if m:
                # inline VAR=value prefixes, including ALLSTAR_ALLOW_PRIMARY (ignored)
                if m.group(1) in ("GIT_DIR", "GIT_WORK_TREE") and m.group(2):
                    extra.append(m.group(2))
                argv = argv[1:]
            elif os.path.basename(argv[0]) in WRAPPERS:
                nice = os.path.basename(argv[0]) == "nice"
                argv = argv[1:]
                while argv and argv[0].startswith("-"):
                    argv = argv[2:] if nice and argv[0] == "-n" else argv[1:]
            else:
                break
        if not argv:
            continue
        prog = os.path.basename(argv[0])
        if prog in ("cd", "pushd"):
            args = argv[1:]
            while args and args[0].startswith("-") and args[0] != "-":
                args = args[1:]  # -L, -P, --
            if not args:
                cwd = resolve(cwd, "~")
            elif args[0] != "-":  # `cd -` (previous dir) is unknown here: keep cwd
                cwd = resolve(cwd, args[0])
        elif prog == "export":
            for a in argv[1:]:
                m = ASSIGNMENT.fullmatch(a)
                if m and m.group(1) in ("GIT_DIR", "GIT_WORK_TREE") and m.group(2):
                    exported.append(m.group(2))
        elif prog == "git":
            targets, unsafe, sub, rest = parse_git(argv[1:], cwd)
            targets += [resolve(cwd, d) for d in extra]
            unsafe = unsafe or bool(extra)
            for target in targets:
                root = primary_root(target)
                if root and not git_allowed(argv[1:], unsafe, sub, rest):
                    return root, " ".join(argv)
        elif prog == "gh" and gh_denied(argv[1:]):
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
    if tool in ("Edit", "Write", "NotebookEdit"):
        path = tool_input.get("notebook_path") or tool_input.get("file_path")
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
            what = (f"denied a git/gh command in the primary checkout {root} "
                    f"(command could not be parsed; split it or simplify its quoting)" if cmd is None
                    else f"`{cmd}` targets the primary checkout {root}, and this command is not "
                         f"on the primary-checkout allowlist (see CLAUDE.md)")
            deny(f"require-worktree: {what}. "
                 f"Do new work in a linked worktree instead. From {root} run: {SUGGESTION} "
                 f"and run the command there.")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:  # fail open: never block work because the guard itself broke
        reason = f"{type(e).__name__}: {e}".replace("\n", " ")
        print(f"require-worktree: disabled ({reason})", file=sys.stderr)
        sys.exit(0)
