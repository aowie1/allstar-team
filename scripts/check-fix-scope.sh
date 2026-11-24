#!/usr/bin/env bash
# check-fix-scope.sh: pre-push scope check for pr-contributor in APPLY FINDINGS mode (issue #4, M3).
#
#   check-fix-scope.sh <worktree> <dispatched-sha> <allowed-json>
#
# <allowed-json> is a file holding a JSON array of repo-relative paths the fix may touch: the
# findings' paths, files already in the PR diff, and test files for those. An entry may use '*'
# (matches across '/') for the project's existing test-file patterns, for example "src/*.test.ts".
#
# Checks every change in <dispatched-sha>..HEAD and exits non-zero on any path that is out of
# scope or on the OWNER list (case-insensitive; the OWNER list wins over the allowed list), a
# rename or copy where either side fails, an absolute or '..' path, a mode change, a symlink
# (120000) or submodule (160000), or a HEAD that does not descend from <dispatched-sha>.
# Non-zero means BLOCKED: push nothing.
#
# Exit status: 0 in scope; 4 violations; 2 bad input. JSON is printed on stdout.
# Read-only: runs git read commands only. Run it only from the plugin's installed copy.
set -euo pipefail
export LC_ALL=C

out() { # out <ok> <violations-json>
  jq -n --argjson ok "$1" --argjson v "$2" '{ok: $ok, violations: $v}'
}
bad_input() { jq -n --arg r "$1" '{ok: false, violations: [{path: null, reason: $r}]}'; exit 2; }

[[ $# -eq 3 ]] || bad_input "usage: check-fix-scope.sh <worktree> <dispatched-sha> <allowed-json>"
wt="$1" sha="$2" allowed_file="$3"
case "$0" in /*) ;; *) bad_input "run from the plugin's installed copy by absolute path" ;; esac
[[ -d $wt ]] || bad_input "worktree not found"
[[ $sha =~ ^[0-9a-f]{40}$ ]] || bad_input "dispatched SHA must be the full 40-character SHA"
[[ -f $allowed_file ]] || bad_input "allowed-json not found"
jq -e 'type == "array" and all(.[]; type == "string" and length > 0)' "$allowed_file" >/dev/null 2>&1 \
  || bad_input "allowed-json must be a JSON array of non-empty strings"
git -C "$wt" rev-parse --verify --quiet "$sha^{commit}" >/dev/null || bad_input "dispatched SHA not in worktree"

allowed=()
while IFS= read -r a; do allowed+=("${a,,}"); done < <(jq -r '.[]' "$allowed_file")

# OWNER list (spec Behaviour 10, N5). Lowercase; '*' matches across '/'.
owner_dirs=(.github .gitlab .circleci .buildkite .claude .claude-plugin .husky .githooks .vscode/tasks.json)
owner_root_dirs=(agents commands skills hooks)
owner_names=(claude.md agents.md .gitattributes .gitmodules .envrc .mcp.json .pre-commit-config.yaml
  .gitlab-ci.yml .travis.yml .drone.yml azure-pipelines.yml bitbucket-pipelines.yml jenkinsfile
  makefile gnumakefile dockerfile docker-compose.yml docker-compose.yaml compose.yml compose.yaml
  package.json package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml pnpm-workspace.yaml
  bun.lock bun.lockb deno.json deno.jsonc deno.lock .npmrc .yarnrc .yarnrc.yml
  gemfile gemfile.lock go.mod go.sum go.work cargo.toml cargo.lock pyproject.toml poetry.lock
  pipfile pipfile.lock uv.lock setup.py setup.cfg composer.json composer.lock pom.xml
  gradle.lockfile mix.exs mix.lock podfile podfile.lock package.swift package.resolved
  packages.lock.json flake.nix flake.lock)
owner_name_globs=('dockerfile.*' '*.dockerfile' 'requirements*.txt' 'build.gradle*' 'settings.gradle*'
  '*.csproj' '.env*' '*.lock' '*-lock.json' '*-lock.yaml')

path_reason() { # path_reason <path>: print why the path is not allowed, nothing if it is
  local p="$1" lp base d g a
  if [[ $p == /* ]]; then echo "absolute path"; return; fi
  if [[ /$p/ == */../* || /$p/ == */./* ]]; then echo "'..' or '.' path component"; return; fi
  if [[ $p =~ [[:cntrl:]] ]]; then echo "control character in path"; return; fi
  lp="${p,,}"
  base="${lp##*/}"
  for d in "${owner_dirs[@]}"; do
    if [[ $lp == "$d" || $lp == "$d"/* || $lp == */"$d" || $lp == */"$d"/* ]]; then echo "OWNER path"; return; fi
  done
  for d in "${owner_root_dirs[@]}"; do
    if [[ $lp == "$d"/* ]]; then echo "OWNER path (agent, command, skill or hook definition)"; return; fi
  done
  for d in "${owner_names[@]}"; do
    if [[ $base == "$d" ]]; then echo "OWNER path"; return; fi
  done
  for g in "${owner_name_globs[@]}"; do
    # shellcheck disable=SC2053 # $g is a glob pattern on purpose
    if [[ $base == $g ]]; then echo "OWNER path"; return; fi
  done
  for a in "${allowed[@]}"; do
    # shellcheck disable=SC2053 # allowed entries may be glob patterns
    if [[ $lp == "$a" || $lp == $a ]]; then return; fi
  done
  echo "out of scope"
}

v="[]"
add() { v="$(jq --arg p "$1" --arg r "$2" '. + [{path: $p, reason: $r}]' <<<"$v")"; }

if ! git -C "$wt" merge-base --is-ancestor "$sha" HEAD; then
  add "HEAD" "HEAD does not descend from the dispatched SHA"
fi

# Raw diff, NUL-separated: ":<old mode> <new mode> <old sha> <new sha> <status>" then 1 or 2 paths.
while IFS= read -r -d '' meta; do
  read -r omode nmode _ _ status <<<"${meta#:}"
  IFS= read -r -d '' p1
  p2=""
  if [[ $status == R* || $status == C* ]]; then IFS= read -r -d '' p2; fi
  for p in "$p1" ${p2:+"$p2"}; do
    r="$(path_reason "$p")"
    [[ -z $r ]] || add "$p" "$r"
  done
  shown="${p2:-$p1}"
  if [[ $omode != 000000 && $nmode != 000000 && $omode != "$nmode" ]]; then add "$shown" "mode change $omode -> $nmode"; fi
  if [[ $nmode == 120000 || $omode == 120000 ]]; then add "$shown" "symlink"; fi
  if [[ $nmode == 160000 || $omode == 160000 ]]; then add "$shown" "submodule"; fi
done < <(git -C "$wt" diff --raw -z -M --no-abbrev --no-ext-diff --no-textconv "$sha" HEAD)

if [[ "$(jq length <<<"$v")" -eq 0 ]]; then
  out true "$v"
else
  out false "$v"
  exit 4
fi
