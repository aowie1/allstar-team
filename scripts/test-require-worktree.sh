#!/usr/bin/env bash
# Feed PreToolUse hook-input fixtures to .claude/hooks/require-worktree.py and check each decision.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
hook="$root/.claude/hooks/require-worktree.py"
py="$(command -v python3)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/require-worktree.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

g() { git -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false "$@" >/dev/null 2>&1; }

primary="$tmp/primary"
mkdir -p "$primary/sub"
g init -q -b main "$primary"
echo x > "$primary/sub/file.txt"
g -C "$primary" add .
g -C "$primary" commit -q -m init
g -C "$primary" worktree add -b feature "$tmp/linked"
g -C "$primary" worktree add --detach "$tmp/detached"
g init -q -b main "$tmp/other"
mkdir -p "$tmp/norepo" "$tmp/nobin"
ln -s "$primary" "$tmp/link"
P="$primary" L="$tmp/linked" N="$tmp/norepo"

fails=0
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

# run <stdin> [env...]: sets out, err, rc
run() {
  local input="$1"; shift
  rc=0
  out="$(printf '%s' "$input" | env -u ALLSTAR_ALLOW_PRIMARY "$@" "$py" "$hook" 2>"$tmp/err")" || rc=$?
  err="$(cat "$tmp/err")"
}

# check <label> <allow|deny> <tool> <cwd> <file_path-or-command> [env...]
check() {
  local label="$1" want="$2" tool="$3" cwd="$4" arg="$5"; shift 5
  local input
  input="$("$py" -c 'import json,sys; t,c,a=sys.argv[1:]; k={"Bash":"command","NotebookEdit":"notebook_path"}.get(t,"file_path"); print(json.dumps({"hook_event_name":"PreToolUse","tool_name":t,"cwd":c,"tool_input":{k:a}}))' "$tool" "$cwd" "$arg")"
  run "$input" "$@"
  if [ "$rc" -ne 0 ] || [ -n "$err" ]; then fail "$label: exit $rc, stderr: $err"; return; fi
  if [ "$want" = allow ]; then
    if [ -z "$out" ]; then echo "ok   $label (allow)"; else fail "$label: want allow, got: $out"; fi
  elif printf '%s' "$out" | grep -q '"permissionDecision": "deny"'; then
    if printf '%s' "$out" | grep -qF 'git worktree add -b <branch> ../worktrees/<name> origin/main'; then
      echo "ok   $label (deny)"
    else
      fail "$label: deny message lacks the worktree command"
    fi
  else
    fail "$label: want deny, got: ${out:-<empty>}"
  fi
}

# fail_open <label> <stdin> [env...]: no decision, exit 0, one "disabled" line on stderr
fail_open() {
  local label="$1" input="$2"; shift 2
  run "$input" "$@"
  if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ "$(printf '%s\n' "$err" | grep -c '^require-worktree: disabled (')" = 1 ] \
     && [ "$(printf '%s\n' "$err" | wc -l)" = 1 ]; then
    echo "ok   $label (fail open)"
  else
    fail "$label: rc=$rc out=$out err=$err"
  fi
}

# Edit / Write / NotebookEdit
check "primary Edit"                  deny  Edit  "$P" "$P/sub/file.txt"
check "primary Write"                 deny  Write "$P" "$P/new.txt"
check "primary subdirectory Edit"     deny  Edit  "$P/sub" "file.txt"
check "primary path not existing yet" deny  Write "$tmp" "$P/a/b/c/new.txt"
check "primary via symlink"           deny  Edit  "$tmp" "$tmp/link/sub/file.txt"
check "primary NotebookEdit"          deny  NotebookEdit "$P" "$P/nb.ipynb"
check "linked worktree Edit"          allow Edit  "$P" "$L/sub/file.txt"
check "linked worktree Write"         allow Write "$P" "$L/new.txt"
check "linked NotebookEdit"           allow NotebookEdit "$P" "$L/nb.ipynb"
check "detached worktree Edit"        allow Edit  "$P" "$tmp/detached/sub/file.txt"
check "detached worktree Write"       allow Write "$P" "$tmp/detached/new.txt"
check "TMPDIR path outside a repo"    allow Write "$tmp" "$N/x.txt"
check "linked path not existing yet"  allow Write "$P" "$L/a/b/new.txt"
check "GIT_DIR in env is ignored"     allow Edit  "$P" "$L/sub/file.txt" GIT_DIR="$P/.git"
check "GIT_COMMON_DIR in env ignored" deny  Edit  "$P" "$P/sub/file.txt" GIT_COMMON_DIR="$tmp/other/.git"

# Bash: denied in the primary checkout
check "git -C primary commit"         deny  Bash "$N" "git -C $P commit -m x"
check "cd primary && git add"         deny  Bash "$N" "cd $P && git add ."
check "pushd primary && git add"      deny  Bash "$N" "pushd $P && git add ."
check "git -c x=y commit"             deny  Bash "$P" "git -c x=y commit -m x"
check "git -c x=y -C primary commit"  deny  Bash "$N" "git -c a.b=c -C $P commit -m x"
check "--git-dir= --work-tree= commit" deny Bash "$N" "git --git-dir=$P/.git --work-tree=$P commit -m x"
check "--git-dir <dir> commit"        deny  Bash "$N" "git --git-dir $P/.git commit -m x"
check "inline GIT_DIR= commit"        deny  Bash "$N" "GIT_DIR=$P/.git git commit -m x"
check "git commit in subdirectory"    deny  Bash "$P/sub" "git commit -m x"
check "git checkout in primary"       deny  Bash "$P" "git checkout -b other"
check "git branch create in primary"  deny  Bash "$P" "git branch other"
check "git symbolic-ref write"        deny  Bash "$P" "git symbolic-ref HEAD refs/heads/x"
check "git symbolic-ref -d"           deny  Bash "$P" "git symbolic-ref -d HEAD"
check "git stash push"                deny  Bash "$P" "git stash"
check "git tag create"                deny  Bash "$P" "git tag v1"
check "time git commit"               deny  Bash "$P" "time git commit -m x"
check "command git commit"            deny  Bash "$P" "command git commit -m x"
check "nice -n 5 git commit"          deny  Bash "$P" "nice -n 5 git commit -m x"
check "exec git commit"               deny  Bash "$P" "exec git commit -m x"
check "second command after ;"        deny  Bash "$P" "git status; git push"
check "status NL commit"              deny  Bash "$P" $'git status\ngit commit -m x'
check "echo NL commit"                deny  Bash "$P" $'echo hi\ngit commit -m x'
check "blank line then commit"        deny  Bash "$P" $'git status\n\ngit commit -m x'
check "cd primary NL git add"         deny  Bash "$N" $'cd '"$P"$'\ngit add .'
check "gh pr checkout in primary"     deny  Bash "$P" "gh pr checkout 12"
check "gh -R o/r pr checkout"         deny  Bash "$P" "gh -R o/r pr checkout 12"
check "gh pr merge --delete-branch"   deny  Bash "$P" "gh pr merge 12 --squash --delete-branch"
check "gh pr merge -d"                deny  Bash "$P" "gh pr merge 12 -d"
check "gh repo sync"                  deny  Bash "$P" "gh repo sync"
check "escape hatch inline ignored"   deny  Bash "$P" "ALLSTAR_ALLOW_PRIMARY=1 git commit -m x"
check "escape hatch other value"      deny  Bash "$P" "git commit -m x" ALLSTAR_ALLOW_PRIMARY=0

# Bash: allowed in the primary checkout
check "git worktree add from primary" allow Bash "$P" "git worktree add -b x ../worktrees/x origin/main"
check "git status in primary"         allow Bash "$P" "git status"
check "git -C primary log"            allow Bash "$N" "git -C $P log --oneline"
check "read-only chain in primary"    allow Bash "$P" "git fetch origin && git diff && git branch -vv && git remote -v && git config --get user.name"
check "more read-only in primary"     allow Bash "$P" "git merge-base HEAD main; git rev-list -n1 HEAD; git describe --always; git ls-tree HEAD; git cat-file -t HEAD; git for-each-ref; git show-ref; git shortlog -s; git name-rev HEAD; git check-ignore x; git version; git help log"
check "git symbolic-ref query"        allow Bash "$P" "git symbolic-ref refs/remotes/origin/HEAD"
check "git symbolic-ref --short HEAD" allow Bash "$P" "git symbolic-ref --short HEAD"
check "git --version / bare remote"   allow Bash "$P" "git --version && git remote"
check "git branch --contains/--merged" allow Bash "$P" "git branch --contains HEAD && git branch --merged main"
check "stash list / tag -l"           allow Bash "$P" "git stash list && git tag -l 'v*' && git tag"
check "redirects in primary"          allow Bash "$P" "git branch 2>/dev/null; git status > $N/out 2>&1"
check "quoted NL in primary log"      allow Bash "$P" $'git log --grep "a\ncommit"'
check "gh pr merge without -d"        allow Bash "$P" "gh pr merge 12 --squash"
check "non-git command in primary"    allow Bash "$P" "ls -la"

# Bash: allowed in a linked worktree
check "git commit in linked"          allow Bash "$L" "git add . && git commit -m x"
check "quoted multi-line -m in linked" allow Bash "$L" $'git commit -m "line one\n\nline two"'
check "cd linked from primary"        allow Bash "$P" "cd $L && git commit -m x"
check "git -C linked commit"          allow Bash "$P" "git -C $L commit -m x"
check "gh pr checkout in linked"      allow Bash "$L" "gh pr checkout 12"

# Escape hatch from the hook's own environment
check "escape hatch in env: Edit"     allow Edit "$P" "$P/sub/file.txt" ALLSTAR_ALLOW_PRIMARY=1
check "escape hatch in env: commit"   allow Bash "$P" "git commit -m x" ALLSTAR_ALLOW_PRIMARY=1

# Fail open
fail_open "malformed stdin" "not json"
fail_open "git missing" '{"tool_name":"Edit","cwd":"/","tool_input":{"file_path":"'"$P"'/sub/file.txt"}}' PATH="$tmp/nobin"

if [ "$fails" -ne 0 ]; then
  echo "$fails failure(s)"; exit 1
fi
echo "all passed"
