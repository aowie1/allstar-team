#!/usr/bin/env bash
# check-fix-scope.sh: pre-push scope check for pr-contributor in APPLY FINDINGS mode (issue #4, M3).
#
#   check-fix-scope.sh <worktree> <dispatched-sha> <allowed-json>
#
# <allowed-json> is a file holding {"paths": [...], "test_globs": [...]}:
#   paths       repo-relative paths the fix may touch (the findings' paths and the files already in
#               the PR diff), matched literally and case-sensitively;
#   test_globs  patterns for test files of those, using '*' only (matches across '/'), each starting
#               with the directory of one of the paths (no leading '*') and holding a test marker
#               (.test. .spec. _test. a test/ tests/ __tests__/ spec/ directory, or a test_ file
#               prefix), for example "src/*.test.ts" or "tests/test_*.py".
#
# Checks every change in <dispatched-sha>..HEAD and exits non-zero on any path that is out of
# scope or on the OWNER list below (case-insensitive; the OWNER list wins over <allowed-json>),
# a rename or copy where either side fails, an absolute, '.' or '..' path, a control or non-ASCII
# byte, a mode change, a new executable file, a symlink (120000) or submodule (160000), or a HEAD
# that does not descend from <dispatched-sha>. Non-zero means BLOCKED: push nothing. On success,
# push exactly the printed checked_sha: git push origin '<checked_sha>:refs/heads/<head branch>'.
#
# This file is the single source of the OWNER path list (pr-contributor points here).
#
# Exit status: 0 in scope; 4 violations or git failure; 2 bad input; 1 internal error (as in
# trusted-findings.sh). JSON is printed on stdout; checked_sha is "" unless ok is true.
# Read-only: runs git read commands only. Run it only from the plugin's installed copy.
set -euo pipefail
export LC_ALL=C

emitted=0
tmp="$(mktemp -d)"
on_exit() {
  local rc=$?
  rm -rf "$tmp"
  if [[ $emitted -eq 0 ]]; then
    printf '%s\n' '{"ok":false,"checked_sha":"","violations":[{"path":null,"reason":"internal error"}]}'
    exit 1
  fi
  exit "$rc"
}
trap on_exit EXIT

checked=""
emit() { # emit <ok> <violations-json> <exit>
  local o
  o="$(jq -n --argjson ok "$1" --argjson v "$2" --arg c "$checked" \
    '{ok: $ok, checked_sha: (if $ok then $c else "" end), violations: $v}')"
  printf '%s\n' "$o"
  emitted=1
  exit "$3"
}
bad_input() { emit false "$(jq -n --arg r "$1" '[{path: null, reason: $r}]')" 2; }

ffile() { case "$1" in /*) printf '%s' "$1" ;; *) printf './%s' "$1" ;; esac; } # no leading '-'

[[ $# -eq 3 ]] || bad_input "usage: check-fix-scope.sh <worktree> <dispatched-sha> <allowed-json>"
wt="$(ffile "$1")" sha="$2" allowed_file="$(ffile "$3")"
[[ -d $wt ]] || bad_input "worktree not found"

# Location (SR-F10, AR-F14): absolute, and not inside the repo under review, the PR worktree, or
# any linked worktree of them (same git common dir). <config dir>/plugins/ is always accepted.
case "$0" in /*) ;; *) bad_input "run from the plugin's installed copy by absolute path" ;; esac
self="$(realpath -- "$0")"
if [[ $self != "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/"* ]]; then
  mine="$(git -C "$(dirname -- "$self")" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  for d in . "$wt"; do
    if top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" && [[ -n $top && $self == "$(realpath -- "$top")/"* ]]; then
      bad_input "check-fix-scope.sh must not run from the repo under review or the PR worktree"
    fi
    if [[ -n $mine ]] && theirs="$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
      && [[ "$(realpath -- "$mine")" == "$(realpath -- "$theirs")" ]]; then
      bad_input "check-fix-scope.sh must not run from the repo under review or the PR worktree"
    fi
  done
fi

[[ $sha =~ ^[0-9a-f]{40}$ ]] || bad_input "dispatched SHA must be the full 40-character SHA"
[[ -f $allowed_file ]] || bad_input "allowed-json not found"
jq -e 'type == "object" and (keys - ["paths", "test_globs"] | length == 0)
       and ((.paths // []) | type == "array" and all(.[]; type == "string"))
       and ((.test_globs // []) | type == "array" and all(.[]; type == "string"))' "$allowed_file" >/dev/null 2>&1 \
  || bad_input "allowed-json must be {\"paths\": [strings], \"test_globs\": [strings]}"
git -C "$wt" rev-parse --verify --quiet "$sha^{commit}" >/dev/null || bad_input "dispatched SHA not in worktree"
checked="$(git -C "$wt" rev-parse --verify HEAD)"

valid_path() { # a repo-relative path with no glob, '.', '..', leading '-', control or non-ASCII characters
  [[ $1 =~ ^[A-Za-z0-9._/@+-]+$ && $1 != /* && $1 != *//* && /$1/ != */./* && /$1/ != */../* && /$1 != */-* ]]
}

allowed=()
dirs=()
while IFS= read -r a; do
  valid_path "$a" || bad_input "allowed path rejected: must be repo-relative, no glob, '.', '..' or leading '-'"
  allowed+=("$a")
  if [[ $a == */* ]]; then dirs+=("${a%/*}/"); else dirs+=(""); fi
done < <(jq -r '(.paths // [])[]' "$allowed_file")
globs=()
while IFS= read -r g; do
  [[ $g =~ ^[A-Za-z0-9._/*-]+$ && $g != /* && $g != \** && /$g/ != */../* && /$g/ != */./* && /$g != */-* ]] \
    || bad_input "test glob rejected: only letters, digits, . _ / - and *, no leading '*' or '-'"
  # SR-F16: the glob starts with the directory of one of the allowed paths.
  in_dir=0
  for d in "${dirs[@]}"; do
    if [[ $g == "$d"* ]]; then in_dir=1; break; fi
  done
  [[ $in_dir -eq 1 ]] || bad_input "test glob rejected: must start with the directory of an allowed path"
  # CR-F12: markers checked against "/<glob>", so a root tests/ directory counts.
  [[ /$g == *.test.* || /$g == *.spec.* || /$g == *_test.* || /$g == */test/* || /$g == */tests/* \
    || /$g == */__tests__/* || /$g == */spec/* || ${g##*/} == test_* ]] \
    || bad_input "test glob rejected: needs a test marker (.test. .spec. _test. test/ tests/ __tests__/ spec/ or test_ prefix)"
  globs+=("$g")
done < <(jq -r '(.test_globs // [])[]' "$allowed_file")

# OWNER list (spec Behaviour 10, N5, SR-F5, CR-F5). Lowercase; matched case-insensitively.
# Directories, matched at the root or nested:
owner_dirs=(.github .gitlab .circleci .buildkite .woodpecker .gitea/workflows .forgejo/workflows
  .claude .claude-plugin .husky .githooks .vscode .devcontainer .cursor .yarn migrations supabase)
# Plugin definitions, at the root, only when the repo is a Claude Code plugin (AR-F4): the
# manifest exists at the dispatched SHA, or anywhere in its history or any fetched ref, including
# the base branch (SR-F17), so a PR that deletes it does not switch the rule off.
owner_root_dirs=()
if git -C "$wt" cat-file -e "$sha:.claude-plugin/plugin.json" 2>/dev/null \
  || [[ -n "$(git -C "$wt" log --all --format=%H -1 -- .claude-plugin/plugin.json 2>/dev/null)" ]]; then
  owner_root_dirs=(agents commands skills hooks)
fi
# Exact repo-relative paths:
owner_paths=(codeowners docs/codeowners)
# File names, anywhere:
owner_names=(claude.md agents.md gemini.md .cursorrules .windsurfrules
  .gitattributes .gitmodules .envrc .mcp.json .pre-commit-config.yaml lefthook.yml
  .gitlab-ci.yml .travis.yml .drone.yml .woodpecker.yml azure-pipelines.yml bitbucket-pipelines.yml
  cloudbuild.yaml appveyor.yml jenkinsfile
  makefile gnumakefile justfile taskfile.yml dockerfile docker-compose.yml docker-compose.yaml compose.yml compose.yaml
  package.json package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml pnpm-workspace.yaml .pnpmfile.cjs
  bun.lock bun.lockb deno.json deno.jsonc deno.lock .npmrc .yarnrc .yarnrc.yml
  gemfile gemfile.lock go.mod go.sum go.work cargo.toml cargo.lock pyproject.toml poetry.lock
  pipfile pipfile.lock uv.lock setup.py setup.cfg composer.json composer.lock pom.xml
  gradle.lockfile mix.exs mix.lock podfile podfile.lock package.swift package.resolved
  packages.lock.json flake.nix flake.lock rust-toolchain rust-toolchain.toml .tool-versions .nvmrc
  schema.prisma)
# File-name patterns, anywhere:
owner_name_globs=('dockerfile.*' '*.dockerfile' 'requirements*.txt' 'build.gradle*' 'settings.gradle*'
  '*.csproj' '*.gemspec' '*.sql' '.env*' '*.lock' '*-lock.json' '*-lock.yaml'
  '.lefthook*' '.lintstagedrc*' 'lint-staged.config.*')

path_reason() { # path_reason <path>: print why the path is not allowed, nothing if it is
  local p="$1" lp base d g a
  if [[ ! $p =~ ^[[:print:]]+$ ]]; then echo "control or non-ASCII byte in path"; return; fi
  if [[ $p == /* ]]; then echo "absolute path"; return; fi
  if [[ /$p/ == */../* || /$p/ == */./* ]]; then echo "'..' or '.' path component"; return; fi
  lp="${p,,}"
  base="${lp##*/}"
  for d in "${owner_dirs[@]}"; do
    if [[ $lp == "$d"/* || $lp == */"$d"/* ]]; then echo "OWNER path"; return; fi
  done
  for d in "${owner_root_dirs[@]}"; do
    if [[ $lp == "$d"/* ]]; then echo "OWNER path (plugin agent, command, skill or hook definition)"; return; fi
  done
  for d in "${owner_paths[@]}"; do
    if [[ $lp == "$d" ]]; then echo "OWNER path"; return; fi
  done
  for d in "${owner_names[@]}"; do
    if [[ $base == "$d" ]]; then echo "OWNER path"; return; fi
  done
  for g in "${owner_name_globs[@]}"; do
    # shellcheck disable=SC2053 # $g is a glob pattern on purpose
    if [[ $base == $g ]]; then echo "OWNER path"; return; fi
  done
  for a in "${allowed[@]}"; do
    if [[ $p == "$a" ]]; then return; fi
  done
  for g in "${globs[@]}"; do
    # shellcheck disable=SC2053 # test globs are patterns on purpose
    if [[ $p == $g ]]; then return; fi
  done
  echo "out of scope"
}

v="[]"
add() { v="$(jq --arg p "$1" --arg r "$2" '. + [{path: $p, reason: $r}]' <<<"$v")"; }

if ! git -C "$wt" merge-base --is-ancestor "$sha" "$checked"; then
  add "HEAD" "HEAD does not descend from the dispatched SHA"
fi

# Raw diff, NUL-separated: ":<old mode> <new mode> <old sha> <new sha> <status>" then 1 or 2 paths.
if ! git -C "$wt" diff --raw -z -M --no-abbrev --no-ext-diff --no-textconv "$sha" "$checked" >"$tmp/diff"; then
  emit false '[{"path":null,"reason":"git diff failed"}]' 4
fi
truncated=0
meta=""
while IFS= read -r -d '' meta; do
  read -r omode nmode _ _ status <<<"${meta#:}" || true
  if [[ ! ${status:-} =~ ^[ACDMRTU][0-9]*$ ]]; then truncated=1; break; fi
  if ! IFS= read -r -d '' p1; then truncated=1; break; fi
  p2=""
  if [[ $status == R* || $status == C* ]]; then
    if ! IFS= read -r -d '' p2; then truncated=1; break; fi
  fi
  for p in "$p1" ${p2:+"$p2"}; do
    r="$(path_reason "$p")"
    [[ -z $r ]] || add "$p" "$r"
  done
  shown="${p2:-$p1}"
  if [[ $omode != 000000 && $nmode != 000000 && $omode != "$nmode" ]]; then add "$shown" "mode change $omode -> $nmode"; fi
  if [[ $omode == 000000 && $nmode == 100755 ]]; then add "$shown" "new executable file"; fi
  if [[ $nmode == 120000 || $omode == 120000 ]]; then add "$shown" "symlink"; fi
  if [[ $nmode == 160000 || $omode == 160000 ]]; then add "$shown" "submodule"; fi
done <"$tmp/diff"
# A record cut short by EOF: the last read -d '' fails but leaves partial data behind.
if [[ $truncated -eq 1 || -n $meta ]]; then
  add "?" "truncated diff record"
fi

if [[ "$(jq length <<<"$v")" -eq 0 ]]; then
  emit true "$v" 0
else
  emit false "$v" 4
fi
