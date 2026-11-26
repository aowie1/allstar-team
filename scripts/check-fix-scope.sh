#!/usr/bin/env bash
# check-fix-scope.sh: pre-push scope check for pr-contributor in APPLY FINDINGS mode (issue #4, M3).
#
#   check-fix-scope.sh [--base <base branch>] <worktree> <dispatched-sha> <allowed-json>
#
# This header is the single source of the scope rules: the OWNER path list (below) and the
# allowed-json and test-glob rules (here). pr-contributor points here instead of repeating them.
#
# <allowed-json> is a file holding {"paths": [...], "test_globs": [...]}:
#   paths       repo-relative paths the fix may touch: the findings' paths and the files already
#               in the PR diff. Matched literally and case-sensitively. Each must use only
#               A-Z a-z 0-9 . _ / @ + -, with no '.', '..' or '-'-leading component.
#   test_globs  patterns for the test files of those paths. Rules, all required:
#               - only A-Z a-z 0-9 . _ / - and '*' ('*' matches across '/'); no leading '*' or '-';
#                 no '.' or '..' component;
#               - starts with a test-glob root: the directory of a nested allowed path (src/ for
#                 src/a.py), or one of the root test directories tests/ test/ spec/ __tests__/.
#                 Root-level allowed paths (README.md) add no root of their own;
#               - holds a test marker: .test. .spec. _test. a test/ tests/ __tests__/ spec/
#                 directory, or a test_ file-name prefix;
#               - does not name a test-bootstrap file (conftest.py, pytest.ini, jest.setup.*,
#                 jest.config.*, setupTests.*, vitest.setup.*, vitest.config.*). Bootstrap files
#                 are never allowed through a glob, at any depth, even when they carry a marker.
#               Examples: "src/*.test.ts", "tests/test_*.py".
# --base names the PR's base branch; origin/<base> then also decides the plugin rule (below).
#
# Checks every change in <dispatched-sha>..HEAD and exits non-zero on any path that is out of
# scope or on the OWNER list below (case-insensitive; the OWNER list wins over <allowed-json>),
# a rename or copy where either side fails, an absolute, '.' or '..' path, a control or non-ASCII
# byte, a mode change, a new executable file, a symlink (120000) or submodule (160000), or a HEAD
# that does not descend from <dispatched-sha>. Non-zero means BLOCKED: push nothing. On success,
# push exactly the printed checked_sha: git push origin '<checked_sha>:refs/heads/<head branch>'.
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

usage="usage: check-fix-scope.sh [--base <base branch>] <worktree> <dispatched-sha> <allowed-json>"
base=""
if [[ ${1:-} == --base ]]; then
  [[ $# -ge 2 ]] || bad_input "$usage"
  base="$2"
  shift 2
  [[ $base =~ ^[A-Za-z0-9._/-]{1,200}$ ]] && git check-ref-format "refs/heads/$base" \
    || bad_input "invalid base branch name"
fi
[[ $# -eq 3 ]] || bad_input "$usage"
wt="$(ffile "$1")" sha="$2" allowed_file="$(ffile "$3")"
[[ -d $wt ]] || bad_input "worktree not found"

# Location (SR-F10, AR-F14, SR-F18, CR-F21): absolute, and not inside the repo under review, the
# PR worktree, or any linked worktree of them (same git common dir). The checks run for every
# location, including an install under <config dir>/plugins/; a git dir whose common dir cannot
# be resolved is refused, never skipped.
location_fail() { bad_input "check-fix-scope.sh must not run from the repo under review or the PR worktree"; }
common_dir() { # common_dir <dir>: absolute git common dir, "" outside git; exit 1 if unresolvable
  git -C "$1" rev-parse --git-dir >/dev/null 2>&1 || { printf ''; return 0; }
  local c
  c="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" && [[ -n $c ]] || return 1
  realpath -- "$c"
}
case "$0" in /*) ;; *) bad_input "run from the plugin's installed copy by absolute path" ;; esac
self="$(realpath -- "$0")"
mine="$(common_dir "$(dirname -- "$self")")" || bad_input "cannot resolve the script's git common dir"
for d in . "$wt"; do
  if top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" && [[ -n $top && $self == "$(realpath -- "$top")/"* ]]; then
    location_fail
  fi
  theirs="$(common_dir "$d")" || bad_input "cannot resolve the git common dir of $d"
  if [[ -n $mine && $mine == "$theirs" ]]; then location_fail; fi
done

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

is_bootstrap() { # test-bootstrap file names, never allowed through a glob (CR-F18)
  local b="${1##*/}"
  b="${b,,}"
  case "$b" in
    conftest.py | pytest.ini | jest.setup.* | jest.config.* | setuptests.* | vitest.setup.* | vitest.config.*) return 0 ;;
  esac
  return 1
}

allowed=()
dirs=(tests/ test/ spec/ __tests__/) # root test directories; never "" (CR-F18)
while IFS= read -r a; do
  valid_path "$a" || bad_input "allowed path rejected: must be repo-relative, no glob, '.', '..' or leading '-'"
  allowed+=("$a")
  if [[ $a == */* ]]; then dirs+=("${a%/*}/"); fi
done < <(jq -r '(.paths // [])[]' "$allowed_file")
globs=()
while IFS= read -r g; do
  [[ $g =~ ^[A-Za-z0-9._/*-]+$ && $g != /* && $g != \** && /$g/ != */../* && /$g/ != */./* && /$g != */-* ]] \
    || bad_input "test glob rejected: only letters, digits, . _ / - and *, no leading '*' or '-'"
  # SR-F16, CR-F18: the glob starts with a test-glob root.
  in_dir=0
  for d in "${dirs[@]}"; do
    if [[ $g == "$d"* ]]; then in_dir=1; break; fi
  done
  [[ $in_dir -eq 1 ]] || bad_input "test glob rejected: must start with the directory of a nested allowed path or tests/ test/ spec/ __tests__/"
  ! is_bootstrap "$g" || bad_input "test glob rejected: names a test-bootstrap file"
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
# manifest exists at the dispatched SHA, anywhere in that SHA's history (so a PR that deletes it
# does not switch the rule off, SR-F17), or on origin/<base> when --base is given (AR-F19).
# Unrelated branches do not count. Any unexpected git failure counts as a plugin repo.
plugin_repo() {
  local m=.claude-plugin/plugin.json out
  git -C "$wt" cat-file -e "$sha:$m" 2>/dev/null && return 0
  git -C "$wt" rev-parse --verify --quiet "$sha^{tree}" >/dev/null || return 0
  out="$(git -C "$wt" log -1 --format=%H "$sha" -- "$m" 2>/dev/null)" || return 0
  [[ -z $out ]] || return 0
  if [[ -n $base ]]; then
    git -C "$wt" rev-parse --verify --quiet "refs/remotes/origin/$base^{commit}" >/dev/null || return 0
    git -C "$wt" cat-file -e "refs/remotes/origin/$base:$m" 2>/dev/null && return 0
  fi
  return 1
}
owner_root_dirs=()
if plugin_repo; then
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
    if [[ $p == $g ]] && ! is_bootstrap "$p"; then return; fi
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
