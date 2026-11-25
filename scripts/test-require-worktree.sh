#!/usr/bin/env bash
# Feed PreToolUse hook-input fixtures to .claude/hooks/require-worktree.py and check each decision.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
hook="$root/.claude/hooks/require-worktree.py"
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
mkdir -p "$tmp/norepo"
ln -s "$primary" "$tmp/link"

fails=0
# check <label> <expected allow|deny> <tool> <cwd> <file_path-or-command> [env...]
check() {
  local label="$1" want="$2" tool="$3" cwd="$4" arg="$5"; shift 5
  local input out got
  input="$(python3 -c 'import json,sys; t,c,a=sys.argv[1:]; k="command" if t=="Bash" else "file_path"; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":t,"cwd":c,"tool_input":{k:a}}))' "$tool" "$cwd" "$arg")"
  out="$(printf '%s' "$input" | env -u ALLSTAR_ALLOW_PRIMARY -u GIT_DIR -u GIT_WORK_TREE "$@" python3 "$hook")"
  if printf '%s' "$out" | grep -q '"permissionDecision": "deny"'; then got=deny; else got=allow; fi
  if [ "$got" = "$want" ]; then
    echo "ok   $label ($got)"
  else
    echo "FAIL $label: want $want, got $got"; fails=$((fails + 1))
  fi
  if [ "$got" = deny ] && ! printf '%s' "$out" | grep -q 'git worktree add -b <branch> ../worktrees/<name> origin/main'; then
    echo "FAIL $label: deny message lacks the worktree command"; fails=$((fails + 1))
  fi
}

check "primary Edit"                 deny  Edit  "$primary"  "$primary/sub/file.txt"
check "primary Write"                deny  Write "$primary"  "$primary/new.txt"
check "primary subdirectory Edit"    deny  Edit  "$primary/sub" "file.txt"
check "primary path not existing yet" deny Write "$tmp"      "$primary/a/b/c/new.txt"
check "primary via symlink"          deny  Edit  "$tmp"      "$tmp/link/sub/file.txt"
check "linked worktree Edit"         allow Edit  "$primary"  "$tmp/linked/sub/file.txt"
check "linked worktree Write"        allow Write "$primary"  "$tmp/linked/new.txt"
check "detached worktree Edit"       allow Edit  "$primary"  "$tmp/detached/sub/file.txt"
check "detached worktree Write"      allow Write "$primary"  "$tmp/detached/new.txt"
check "TMPDIR path outside a repo"   allow Write "$tmp"      "$tmp/norepo/x.txt"
check "linked path not existing yet" allow Write "$primary"  "$tmp/linked/a/b/new.txt"
check "GIT_DIR in env is ignored"    allow Edit  "$primary"  "$tmp/linked/sub/file.txt" GIT_DIR="$primary/.git"

check "git -C primary commit"        deny  Bash "$tmp/norepo" "git -C $primary commit -m x"
check "cd primary && git add"        deny  Bash "$tmp/norepo" "cd $primary && git add ."
check "git -c x=y commit"            deny  Bash "$primary"   "git -c x=y commit -m x"
check "git commit in subdirectory"   deny  Bash "$primary/sub" "git commit -m x"
check "git checkout in primary"      deny  Bash "$primary"   "git checkout -b other"
check "git branch create in primary" deny  Bash "$primary"   "git branch other"
check "gh pr checkout in primary"    deny  Bash "$primary"   "gh pr checkout 12"
check "second command denied"        deny  Bash "$primary"   "git status; git push"
check "git worktree add from primary" allow Bash "$primary"  "git worktree add -b x ../worktrees/x origin/main"
check "git status in primary"        allow Bash "$primary"   "git status"
check "git -C primary log"           allow Bash "$tmp/norepo" "git -C $primary log --oneline"
check "read-only set in primary"     allow Bash "$primary"   "git fetch origin && git diff && git branch -vv && git remote -v && git config --get user.name"
check "git commit in linked"         allow Bash "$tmp/linked" "git add . && git commit -m x"
check "cd linked from primary"       allow Bash "$primary"   "cd $tmp/linked && git commit -m x"
check "git -C linked commit"         allow Bash "$primary"   "git -C $tmp/linked commit -m x"
check "non-git command in primary"   allow Bash "$primary"   "ls -la"

check "escape hatch in env: Edit"    allow Edit "$primary"   "$primary/sub/file.txt" ALLSTAR_ALLOW_PRIMARY=1
check "escape hatch in env: commit"  allow Bash "$primary"   "git commit -m x" ALLSTAR_ALLOW_PRIMARY=1
check "escape hatch inline ignored"  deny  Bash "$primary"   "ALLSTAR_ALLOW_PRIMARY=1 git commit -m x"
check "escape hatch other value"     deny  Bash "$primary"   "git commit -m x" ALLSTAR_ALLOW_PRIMARY=0

if [ "$fails" -ne 0 ]; then
  echo "$fails failure(s)"; exit 1
fi
echo "all passed"
