#!/usr/bin/env bash
# trusted-findings.sh: the read-only trust filter behind /allstar-team:implement-fixes (issue #4).
#
#   trusted-findings.sh <owner/repo> <pr-number>
#       Print one JSON object: the findings from the single trusted dispatch summary on the PR,
#       the shared fix-round counter and the apply guards, or a refusal.
#   trusted-findings.sh --check-reason < reason-file
#       Validate a --skip reason read from standard input.
#   trusted-findings.sh --check-ids [findings-json] < ids-file
#       Validate a comma-separated --skip id list read from standard input. With the JSON this
#       script printed for the PR, also reject ids that are not among its findings.
#
# Exit status: 0 ok (apply_refusal may still be set); 3 refusal; 1 internal error. JSON is
# printed on stdout in every case.
# Read-only: GraphQL queries only (no mutations), nothing is written to GitHub. Uses only gh, jq
# and git. Run it only from the plugin's installed copy, by absolute path; never from the repo
# under review or a PR worktree.
set -euo pipefail
export LC_ALL=C

mode="trusted"
case "${1:-}" in --check-reason | --check-ids) mode="check" ;; esac

emitted=0
tmp="$(mktemp -d)"
on_exit() {
  local rc=$?
  rm -rf "$tmp"
  if [[ $emitted -eq 0 ]]; then
    if [[ $mode == check ]]; then
      printf '%s\n' '{"ok":false,"refusal":"internal error"}'
    else
      printf '%s\n' '{"head_sha":null,"head_branch":null,"branch_ok":false,"round":null,"findings":[],"rejected":[],"not_shown":{},"ignored":[],"flagged":[],"refusal":"internal error","viewer":null,"pr_author":null,"can_apply":false,"apply_refusal":"internal error","base_branch":null,"default_branch":null,"tracker_comment_id":null,"pr_fix_comment_id":null}'
    fi
    exit 1
  fi
  exit "$rc"
}
trap on_exit EXIT

viewer="" pr_author="" head_sha="" head_branch="" base_branch="" default_branch="" round=""

refuse() { # refuse <reason>: print the full output shape with a refusal, exit 3
  local o
  o="$(jq -n --arg r "$1" --arg viewer "$viewer" --arg author "$pr_author" --arg head "$head_sha" \
    --arg branch "$head_branch" --arg base "$base_branch" --arg def "$default_branch" --arg round "$round" '
    def n: if . == "" then null else . end;
    {head_sha: ($head|n), head_branch: ($branch|n), branch_ok: false,
     round: (if $round == "" then null else ($round|tonumber) end),
     findings: [], rejected: [], not_shown: {}, ignored: [], flagged: [], refusal: $r,
     viewer: ($viewer|n), pr_author: ($author|n), can_apply: false, apply_refusal: $r,
     base_branch: ($base|n), default_branch: ($def|n), tracker_comment_id: null, pr_fix_comment_id: null}')"
  printf '%s\n' "$o"
  emitted=1
  exit 3
}

check_fail() { # check_fail <reason>: refusal for the --check-* modes
  local o
  o="$(jq -n --arg r "$1" '{ok: false, refusal: $r}')"
  printf '%s\n' "$o"
  emitted=1
  exit 3
}

fail() { if [[ $mode == check ]]; then check_fail "$1"; else refuse "$1"; fi; }

# Location (spec L1, SR-F10, AR-F14): an absolute path, and not from the repo the caller is
# working in or any linked worktree of it (same git common dir). A marketplace install lives
# under <config dir>/plugins/; a --plugin-dir development checkout of another repo is accepted.
self_check() {
  local self top mine theirs
  case "$0" in /*) ;; *) fail "trusted-findings.sh must be run from the plugin's installed copy by absolute path" ;; esac
  self="$(realpath -- "$0")"
  [[ $self == "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/"* ]] && return 0
  if top="$(git rev-parse --show-toplevel 2>/dev/null)" && [[ -n $top && $self == "$(realpath -- "$top")/"* ]]; then
    fail "trusted-findings.sh must not run from the repo under review"
  fi
  if mine="$(git -C "$(dirname -- "$self")" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    && theirs="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    && [[ "$(realpath -- "$mine")" == "$(realpath -- "$theirs")" ]]; then
    fail "trusted-findings.sh must not run from the repo under review"
  fi
}

ffile() { case "$1" in /*) printf '%s' "$1" ;; *) printf './%s' "$1" ;; esac; } # no leading '-'

gql() { # gql <gh api graphql args...>: print the response, or record why and return 1
  local out
  if ! out="$(gh api graphql "$@" 2>"$tmp/err")"; then
    printf 'gh api failed: %s' "$(head -c 200 "$tmp/err" | tr -d '\000-\037')" >"$tmp/why"
    return 1
  fi
  if ! jq -e '(.data != null) and ((.errors // []) | length == 0)' >/dev/null 2>&1 <<<"$out"; then
    printf 'gh api returned errors' >"$tmp/why"
    return 1
  fi
  printf '%s' "$out"
}

why() { cat "$tmp/why" 2>/dev/null || printf 'gh api failed'; }

# page_once <name> <connection path> <pin path> <gh api graphql args...>
# Follows pageInfo until complete, writes all nodes to $tmp/<name>.json and the first page to
# $tmp/<name>.first. Returns 1 (reason in $tmp/why) on a gh error, a missing object, a value at
# <pin path> that changes between pages, or totalCount != nodes fetched.
page_once() {
  local name="$1" path="$2" pin="$3" cursor="" resp pages=0
  shift 3
  : >"$tmp/$name.pages"
  : >"$tmp/$name.pins"
  while :; do
    if [[ -z $cursor ]]; then
      resp="$(gql "$@")" || return 1
    else
      resp="$(gql "$@" -f cursor="$cursor")" || return 1
    fi
    if ! jq -e "$path != null" >/dev/null <<<"$resp"; then
      printf 'not found' >"$tmp/why"
      return 1
    fi
    [[ $pages -gt 0 ]] || printf '%s' "$resp" >"$tmp/$name.first"
    jq -c "$path | .nodes" <<<"$resp" >>"$tmp/$name.pages"
    jq -c "$pin" <<<"$resp" >>"$tmp/$name.pins"
    jq -c "$path | .totalCount" <<<"$resp" >"$tmp/$name.total"
    pages=$((pages + 1))
    if [[ "$(jq -r "$path | .pageInfo.hasNextPage" <<<"$resp")" != true ]]; then
      break
    fi
    cursor="$(jq -r "$path | .pageInfo.endCursor" <<<"$resp")"
    if [[ ! $cursor =~ ^[A-Za-z0-9+/=_-]+$ || $pages -ge 200 ]]; then
      printf 'pagination failed' >"$tmp/why"
      return 1
    fi
  done
  if [[ "$(sort -u "$tmp/$name.pins" | wc -l)" -ne 1 ]]; then
    printf 'PR head moved while fetching' >"$tmp/why"
    return 1
  fi
  jq -s 'add // []' "$tmp/$name.pages" >"$tmp/$name.json"
  if [[ "$(jq length "$tmp/$name.json")" -ne "$(cat "$tmp/$name.total")" ]]; then
    printf 'totalCount mismatch on %s' "$name" >"$tmp/why"
    return 1
  fi
}

page_all() { # page_once, retried once on a totalCount mismatch (SR-F14)
  page_once "$@" && return 0
  [[ "$(why)" == "totalCount mismatch"* ]] || return 1
  page_once "$@"
}

comment_fields='id databaseId viewerDidAuthor author{login} body userContentEdits(first:100){totalCount pageInfo{hasNextPage endCursor} nodes{editor{login}}}'
edits_query='query($id:ID!,$cursor:String){node(id:$id){... on IssueComment{userContentEdits(first:100,after:$cursor){totalCount pageInfo{hasNextPage endCursor} nodes{editor{login}}}}}}'

# complete_edits <name>: page userContentEdits to the end for every comment by the pinned identity
# (other authors' comments are untrusted whatever their edits) and write $tmp/<name>.comments:
# [{id, databaseId, viewerDidAuthor, author, body, edits, edits_total}]
complete_edits() {
  local name="$1" id
  printf '{}' >"$tmp/$name.extra"
  while IFS= read -r id; do
    [[ $id =~ ^[A-Za-z0-9_=-]+$ ]] || { printf 'unexpected node id' >"$tmp/why"; return 1; }
    page_all edits '.data.node.userContentEdits' 'null' -f query="$edits_query" -f id="$id" || return 1
    jq --arg id "$id" --slurpfile e "$tmp/edits.json" '. + {($id): $e[0]}' "$tmp/$name.extra" >"$tmp/$name.extra.new"
    mv "$tmp/$name.extra.new" "$tmp/$name.extra"
  done < <(jq -r --arg v "$viewer" '.[] | select(.viewerDidAuthor == true and .author.login == $v)
                                      | select(.userContentEdits.pageInfo.hasNextPage) | .id' "$tmp/$name.json")
  jq --slurpfile x "$tmp/$name.extra" '
    map(. as $c | {id, databaseId, viewerDidAuthor, author, body,
                   edits: ($x[0][$c.id] // $c.userContentEdits.nodes),
                   edits_total: $c.userContentEdits.totalCount})' "$tmp/$name.json" >"$tmp/$name.comments"
  if ! jq -e --arg v "$viewer" 'all(.[] | select(.viewerDidAuthor == true and .author.login == $v);
                                    (.edits | length) == .edits_total)' >/dev/null "$tmp/$name.comments"; then
    printf 'totalCount mismatch on comment edits' >"$tmp/why"
    return 1
  fi
}

read_stdin() { # read_stdin: standard input to $tmp/in, refusing NUL bytes and oversized input
  head -c 4097 >"$tmp/in"
  [[ "$(wc -c <"$tmp/in")" -le 4096 ]] || check_fail "input too long"
  [[ "$(tr -d '\000' <"$tmp/in" | wc -c)" -eq "$(wc -c <"$tmp/in")" ]] || check_fail "input contains a NUL byte"
}

input_value() { # print $tmp/in without one trailing newline
  local s
  s="$(cat "$tmp/in"; printf x)"
  s="${s%x}"
  printf '%s' "${s%$'\n'}"
}

check_reason() {
  local s low re sep tok colon
  read_stdin
  s="$(input_value)"
  # NFKC is not available in bash/jq. Rejecting every byte outside this ASCII set is stricter:
  # format, control and bidirectional characters (and any other non-ASCII text) never pass.
  re='^[A-Za-z0-9 .,;:'\''()/_+=?!-]{1,200}$'
  [[ $s =~ $re ]] || check_fail "reason must be 1-200 characters from A-Z a-z 0-9 space and . , ; : ' ( ) / _ + = ? ! -"
  [[ $s =~ [A-Za-z0-9] ]] || check_fail "reason must contain a letter or digit"
  low="${s,,}"
  # CR-F7: tokens at a word start, with any run of separators inside them or before a colon.
  sep='[ _.-]*'
  tok="(^|[^a-z])(review${sep}only|confirm${sep}before${sep}fix|fix${sep}confirmed|apply${sep}findings|confirmed${sep}fix${sep}at|head${sep}branch|base${sep}branch|skip${sep}ids|output${sep}settings)"
  colon="(^|[^a-z])(round|agent|held|dry${sep}run)[^a-z0-9]*:"
  if [[ $low =~ $tok || $low =~ $colon || $low == *'://'* ]]; then
    check_fail "reason contains a reserved token"
  fi
  local o
  o="$(jq -n --arg r "$s" '{ok: true, reason: $r}')"
  printf '%s\n' "$o"
  emitted=1
}

check_ids() {
  local file="${1:-}" s p o ids=()
  if [[ -n $file ]]; then
    file="$(ffile "$file")"
    [[ -f $file ]] || check_fail "findings file not found"
    jq -e '.refusal == null and (.findings | type == "array")' "$file" >/dev/null 2>&1 \
      || check_fail "findings file has a refusal or no findings"
  fi
  read_stdin
  s="$(input_value)"
  [[ $s =~ ^[A-Za-z0-9:,\ -]{1,1000}$ ]] || check_fail "ids may contain only letters, digits, ':', '-', ',' and spaces"
  [[ ! $s =~ ,[\ ]*$ ]] || check_fail "trailing comma in id list"
  IFS=',' read -ra parts <<<"$s"
  [[ ${#parts[@]} -gt 0 ]] || check_fail "no ids given"
  for p in "${parts[@]}"; do
    p="${p#"${p%%[! ]*}"}"
    p="${p%"${p##*[! ]}"}"
    if [[ -z $p ]]; then
      check_fail "empty id in list"
    elif [[ $p =~ ^[Ff]?[0-9]+$ ]]; then
      check_fail "bare finding id rejected: $p (use <reviewer>:F<n>)"
    elif [[ ! $p =~ ^[a-z0-9-]+:F[1-9][0-9]*$ ]]; then
      check_fail "malformed finding id: $p (use <reviewer>:F<n>)"
    fi
    if [[ -n $file ]] && ! jq -e --arg id "$p" 'any(.findings[]; .id == $id)' "$file" >/dev/null; then
      check_fail "unknown finding id: $p"
    fi
    ids+=("$p")
  done
  o="$(printf '%s\n' "${ids[@]}" | jq -R . | jq -s '{ok: true, ids: unique}')"
  printf '%s\n' "$o"
  emitted=1
}

trusted() {
  [[ $# -eq 2 ]] || refuse "usage: trusted-findings.sh <owner/repo> <pr-number>"
  local nwo="$1" n="$2" owner repo resp pr_query issue_query commits_query issue branch_ok=false
  [[ $nwo =~ ^[A-Za-z0-9-]{1,39}/[A-Za-z0-9._-]{1,100}$ ]] || refuse "invalid owner/repo"
  owner="${nwo%%/*}"
  repo="${nwo#*/}"
  [[ $repo != . && $repo != .. ]] || refuse "invalid owner/repo"
  [[ $n =~ ^[1-9][0-9]{0,8}$ ]] || refuse "invalid PR number"

  # 1. Pin the identity (fail closed).
  resp="$(gql -f query='{viewer{login}}')" || refuse "identity lookup failed"
  viewer="$(jq -r '.data.viewer.login // empty' <<<"$resp")"
  [[ -n $viewer ]] || refuse "identity lookup failed"

  # 2. The PR, every comment, every edit of the pinned identity's comments.
  pr_query='query($owner:String!,$repo:String!,$n:Int!,$cursor:String){repository(owner:$owner,name:$repo){nameWithOwner defaultBranchRef{name} pullRequest(number:$n){state headRefOid headRefName baseRefName isCrossRepository author{login} closingIssuesReferences(first:50){totalCount nodes{number repository{nameWithOwner}}} comments(first:100,after:$cursor){totalCount pageInfo{hasNextPage endCursor} nodes{'"$comment_fields"'}}}}}'
  page_all pr '.data.repository.pullRequest.comments' '.data.repository.pullRequest.headRefOid' \
    -f query="$pr_query" -f owner="$owner" -f repo="$repo" -F n="$n" || refuse "$(why)"
  complete_edits pr || refuse "$(why)"
  jq '.data.repository | .pullRequest + {defaultBranch: .defaultBranchRef.name, nameWithOwner}
      | del(.comments)' "$tmp/pr.first" >"$tmp/meta.json"
  head_sha="$(jq -r '.headRefOid // empty' "$tmp/meta.json")"
  head_branch="$(jq -r '.headRefName // empty' "$tmp/meta.json")"
  base_branch="$(jq -r '.baseRefName // empty' "$tmp/meta.json")"
  default_branch="$(jq -r '.defaultBranch // empty' "$tmp/meta.json")"
  pr_author="$(jq -r '.author.login // empty' "$tmp/meta.json")"
  [[ $head_sha =~ ^[0-9a-f]{40}$ ]] || refuse "PR head SHA unreadable"
  # D4: a head branch outside this set never reaches a push.
  if [[ $head_branch =~ ^[A-Za-z0-9._/-]{1,200}$ ]] && git check-ref-format "refs/heads/$head_branch"; then
    branch_ok=true
  fi
  jq -e '.closingIssuesReferences.totalCount == (.closingIssuesReferences.nodes | length)' \
    "$tmp/meta.json" >/dev/null || refuse "totalCount mismatch on linked issues"

  # 3. Comments on linked issues in the same repo (the tracker lives there).
  issue_query='query($owner:String!,$repo:String!,$n:Int!,$cursor:String){repository(owner:$owner,name:$repo){issue(number:$n){comments(first:100,after:$cursor){totalCount pageInfo{hasNextPage endCursor} nodes{'"$comment_fields"'}}}}}'
  printf '[]' >"$tmp/trackers.json"
  while IFS= read -r issue; do
    [[ $issue =~ ^[1-9][0-9]{0,8}$ ]] || refuse "unexpected linked issue number"
    page_all issue '.data.repository.issue.comments' 'null' \
      -f query="$issue_query" -f owner="$owner" -f repo="$repo" -F n="$issue" || refuse "$(why)"
    complete_edits issue || refuse "$(why)"
    jq --argjson i "$issue" --slurpfile c "$tmp/issue.comments" '. + ($c[0] | map(. + {issue: $i}))' \
      "$tmp/trackers.json" >"$tmp/trackers.new"
    mv "$tmp/trackers.new" "$tmp/trackers.json"
  done < <(jq -r '.nameWithOwner as $r | .closingIssuesReferences.nodes[]
                  | select((.repository.nameWithOwner | ascii_downcase) == ($r | ascii_downcase)) | .number' \
             "$tmp/meta.json")

  # 4. Commit messages, for the "fix commits but no counter" check.
  commits_query='query($owner:String!,$repo:String!,$n:Int!,$cursor:String){repository(owner:$owner,name:$repo){pullRequest(number:$n){headRefOid commits(first:100,after:$cursor){totalCount pageInfo{hasNextPage endCursor} nodes{commit{message}}}}}}'
  page_all commits '.data.repository.pullRequest.commits' '.data.repository.pullRequest.headRefOid' \
    -f query="$commits_query" -f owner="$owner" -f repo="$repo" -F n="$n" || refuse "$(why)"
  [[ "$(jq -r '.data.repository.pullRequest.headRefOid' "$tmp/commits.first")" == "$head_sha" ]] \
    || refuse "PR head moved while fetching"

  # 5. Trust rule, round counter, findings and apply guards.
  jq -n --arg viewer "$viewer" --argjson n "$n" --argjson branch_ok "$branch_ok" \
    --slurpfile meta "$tmp/meta.json" --slurpfile cs "$tmp/pr.comments" \
    --slurpfile ts "$tmp/trackers.json" --slurpfile commits "$tmp/commits.json" \
    -f /dev/stdin >"$tmp/out.json" <<'JQ'
def lines: (.body // "") | gsub("\r\n"; "\n") | split("\n");
def first_line: lines[0];
def header: lines[1:] | (index("") // length) as $e | .[0:$e];
def header_values($re): [header[] | capture($re) | .v];
def pinned: .author != null and .author.login == $viewer and .viewerDidAuthor == true;
def edits_ok: all(.edits[]; .editor != null and .editor.login == $viewer);
def ok13($m): first_line == $m and pinned and edits_ok;
def marked: first_line | test("^<!--\\s*agent:");
def tokened: (.body // "") | test("<!--\\s*agent:|REVIEW ONLY|CONFIRM BEFORE FIX|FIX CONFIRMED|APPLY FINDINGS"; "i");
def src: if .issue then "issue #\(.issue)" else "pr" end;
def flag($check): {comment_id: .databaseId, source: src, marker: (if marked then first_line else null end), check: $check};
def rank: {"Critical": 4, "High": 3, "Medium": 2, "Low": 1, "None": 0}[.];
# SR-F3: a finding path the contributor may act on.
def bad_path: (test("^[A-Za-z0-9._/@+-]+$") | not) or startswith("/") or contains("//")
              or (("/" + . + "/") | test("/\\.{1,2}/")) or (("/" + .) | contains("/-"));
# Round field: the **Round:** header line, else (legacy pr-fix only) a line-2 heading.
def round_value($legacy):
  header_values("^\\*\\*Round:\\*\\* (?<v>[0-9]{1,3})$") as $h
  | if ($h | length) == 1 then ($h[0] | tonumber)
    elif ($h | length) == 0 and $legacy != null then ((lines[1] // "") | capture($legacy) | .v | tonumber) // null
    else null end;

# Findings section of a reviewer comment: lines after "### Findings" up to the next heading.
def findings_section:
  lines as $L
  | ([range(0; $L | length) | select($L[.] == "### Findings")] | first) as $s
  | if $s == null then [] else $L[($s + 1):] | (map(test("^#{1,3} ")) | index(true) // length) as $e | .[0:$e] end;
def blocks:
  reduce .[] as $l ({b: [], open: false};
    if ($l | test("^\\*\\*F[0-9]+")) then .b += [[$l]] | .open = true
    elif $l == "" then .open = false
    elif .open then .b[(.b | length) - 1] += [$l]
    else . end) | .b;
def parse_finding($role; $cid; $sha):
  . as $blk
  | ($blk[0] | capture("^\\*\\*F(?<n>[0-9]+)(?<hdr>(?: · .*?)?)\\*\\*(?<rest>(?:\\s.*)?)$"))
      // error("unparseable finding header in \($role) comment \($cid)")
  | . as $m
  | ($m.hdr | ltrimstr(" · ") | split(" · ") | map(gsub("^\\s+|\\s+$"; ""))) as $segs
  | "\($role):F\($m.n)" as $id
  | (first($segs[] | gsub("^[^A-Za-z]+"; "") | select(IN("Critical", "High", "Medium", "Low"))) // null) as $sev
  | (any($segs[]; ascii_downcase == "resolved")) as $resolved
  | (first($segs[] | capture("^`(?<l>[^`]+)`$") | .l) // null) as $loc
  # CR-F14: "docs/x.md § Section" names a file and a section, not a line.
  | (if $loc == null then {path: null, line: null}
     elif ($loc | contains("§")) then {path: ($loc | split("§")[0] | gsub("^\\s+|\\s+$"; "") | if . == "" then null else . end), line: null}
     else ($loc | capture("^(?<p>[^:]+):(?<ln>[0-9]+)") | {path: .p, line: (.ln | tonumber)}) // {path: $loc, line: null}
     end) as $pl
  | (first($blk[] | capture("\\*\\*Fix:\\*\\*\\s*(?<f>.*)$") | .f
       | sub(" · \\*\\*Owner decision:\\*\\*.*$"; "") | gsub("^\\s+|\\s+$"; "")) // null) as $fix
  | if $resolved then empty
    elif $sev == null then error("unparseable finding \($id)")
    else {id: $id, severity: $sev, path: $pl.path, line: $pl.line, fix: $fix, comment_id: $cid, reviewed_sha: $sha}
    end;
def not_shown_counts:
  first(findings_section[] | capture("^\\*\\*Not shown:\\*\\* (?<t>.*)$") | .t) // null
  | if . == null then null
    else reduce (scan("([0-9]+) (Critical|High|Medium|Low)")) as $p ({}; .[$p[1]] = ((.[$p[1]] // 0) + ($p[0] | tonumber)))
    end;

# Verdict table: the one table with exactly this header row.
def verdict_rows:
  lines as $L
  | [range(0; $L | length) | select($L[.] == "| Reviewer | Verdict | Concern | Reviewed SHA | Comment id |")] as $h
  | if ($h | length) != 1 then error("summary verdict table missing or duplicated")
    elif (($L[$h[0] + 1] // "") | test("^\\|( *:?-+:? *\\|){5}$")) | not then error("summary verdict table malformed")
    else $L[($h[0] + 2):] | (map(startswith("|") | not) | index(true) // length) as $e | .[0:$e]
      | map(split("|") | if length != 7 then error("summary verdict table malformed")
                         else .[1:6] | map(gsub("^\\s+|\\s+$"; ""))
                           | {role: .[0], verdict: .[1], concern: .[2], sha: .[3], id: .[4]} end)
      | if length == 0 then error("dispatch summary has an empty verdict table")
        elif all(.[]; (.role | test("^[a-z0-9-]+$")) and (.verdict | IN("APPROVE", "CHANGES", "BLOCK"))
               and (.concern | IN("Critical", "High", "Medium", "Low", "None"))
               and (.sha | test("^[0-9a-f]{40}$")) and (.id | test("^[0-9]{1,15}$")))
           and ((map(.role) | unique | length) == length) and ((map(.id) | unique | length) == length)
        then map(.id |= tonumber) else error("summary verdict table malformed") end
    end;

$meta[0] as $p | $cs[0] as $cs | $ts[0] as $ts | $commits[0] as $commits
| "<!-- agent: review-dispatcher | review-dispatch -->" as $summ
| "<!-- agent: pr-contributor | pr-fix -->" as $fixm
| "<!-- agent: review-dispatcher | pr-tracker PR#\($n) -->" as $trkm

# Untrusted-source bookkeeping. D3: every comment by the pinned identity edited by another (or a
# deleted) account is flagged, whatever its first line.
| ([($cs + $ts)[] | select(pinned | not) | select(marked or tokened) | flag("(2) author")]
   + [($cs + $ts)[] | select(pinned and (edits_ok | not)) | flag("(3) edits")]) as $flagged0
| [$cs[] | select((pinned | not) and (marked | not) and (tokened | not)) | {comment_id: .databaseId, reason: "untrusted source"}] as $ignored

| {head_sha: $p.headRefOid, head_branch: $p.headRefName, round: null, findings: [], rejected: [], not_shown: {},
   ignored: $ignored, flagged: $flagged0, refusal: null, viewer: $viewer,
   pr_author: ($p.author.login // null), can_apply: false, apply_refusal: null,
   base_branch: $p.baseRefName, default_branch: $p.defaultBranch,
   tracker_comment_id: ([$ts[] | select(ok13($trkm)) | .databaseId] | max),
   pr_fix_comment_id: ([$cs[] | select(ok13($fixm)) | .databaseId] | max),
   counter: null}

# Round counter (Behaviour 8, M1, D2, D3): the larger trusted **Round:** field of pr-fix and tracker.
# Counter problems block contributor dispatch (apply_refusal, round null), not the dry run.
| if any(($cs + $ts)[]; pinned and (edits_ok | not)) then .counter = "round counter tampered"
  else
    ([$cs[] | select(ok13($fixm)) | round_value("^## PR fix — Round (?<v>[0-9]{1,3})$")]
     + [$ts[] | select(ok13($trkm)) | round_value(null)]) as $vals
    | if any($vals[]; . == null) then .counter = "round counter unreadable"
      elif ($vals | length) > 0 then .round = ($vals | max)
      elif any($commits[]; (.commit.message // "") | test("\\b[a-z0-9-]+:F[0-9]+\\b"))
        then .counter = "commits cite finding ids but no trusted round counter exists"
      else .round = 0 end
  end

# Exactly one trusted dispatch summary on the PR, at the current head (checks (1)-(3), (5)).
| [$cs[] | select(ok13($summ))] as $s
| if ($s | length) == 0 then .refusal = "no trusted dispatch summary"
  elif ($s | length) > 1 then .refusal = "multiple trusted dispatch summaries"
  else ($s[0] | header_values("^\\*\\*Head SHA:\\*\\* (?<v>[0-9a-f]{40})$")) as $hs
    | if ($hs | length) != 1 then .refusal = "dispatch summary has no full head SHA"
      elif $hs[0] != $p.headRefOid then .refusal = "head moved since review"
      else . as $o | try ($o + {rows: ($s[0] | verdict_rows)}) catch ($o + {refusal: .})
      end
  end

# Reviewer comments by the ids in the verdict table (check (4)), then their findings.
| if .refusal then del(.rows) else
    . as $o
    | try (
        reduce $o.rows[] as $r ($o | del(.rows);
          ([$cs[] | select(.databaseId == $r.id)] | first) as $c
          | if $c == null then error("listed reviewer comment \($r.id) not found on the PR")
            elif ($c | first_line) != "<!-- agent: \($r.role) | pr-review -->" then .flagged += [$c | flag("(1) marker")]
            elif ($c | pinned | not) then .
            elif ($c | edits_ok | not) then .
            elif (($c | header_values("^\\*\\*Reviewed SHA:\\*\\* (?<v>[0-9a-f]{7,40})$")) as $v
                  | ($v | length) != 1 or ($r.sha | startswith($v[0]) | not))
              then .flagged += [$c | flag("(4) verdict table")]
            else
              [$c | findings_section | blocks[] | parse_finding($r.role; $r.id; $r.sha)] as $fs
              | ($c | not_shown_counts) as $ns
              # CR-F3: what was parsed must account for the concern the summary recorded.
              | (([$fs[].severity] + ($ns // {} | keys)) | map(rank) | max // 0) as $top
              | if $top != ($r.concern | rank) then error("findings unparseable for \($r.role)") else . end
              | .findings += [$fs[] | select(.path != null and (.path | bad_path | not))]
              | .rejected += [$fs[] | select(.path == null) | {id, path, reason: "no file path"}]
              | .rejected += [$fs[] | select(.path != null and (.path | bad_path)) | {id, path, reason: "path rejected"}]
              | if $ns then .not_shown[$r.role] = $ns else . end
            end)
        | if (.findings + .rejected | map(.id) | unique | length) != (.findings + .rejected | length)
          then error("duplicate finding id") else . end
      ) catch (. as $e | $o | del(.rows) | .refusal = $e)
  end

# Apply guards (D1, D3, D4, S-F12, round cap, M2).
| .branch_ok = $branch_ok
| .apply_refusal = (
    if .counter then .counter
    elif .refusal then .refusal
    elif $p.state != "OPEN" then "PR is not open"
    elif $p.isCrossRepository then "fork PR: never push to a fork; use --dry-run"
    elif ($branch_ok | not) then "invalid head branch name"
    elif .head_branch == .base_branch or .head_branch == .default_branch then "head branch is the base or default branch"
    elif .pr_author == null or .pr_author != .viewer then "caller is not the PR author; only --dry-run is allowed"
    elif .round >= 4 then "round cap reached (4 rounds)"
    else null end)
| .can_apply = (.apply_refusal == null)
| if .refusal then .findings = [] | .rejected = [] | .not_shown = {} else . end
| {head_sha, head_branch, branch_ok, round, findings, rejected, not_shown, ignored, flagged, refusal,
   viewer, pr_author, can_apply, apply_refusal, base_branch, default_branch,
   tracker_comment_id, pr_fix_comment_id}
JQ
  cat "$tmp/out.json"
  emitted=1
  if [[ "$(jq -r '.refusal // empty' "$tmp/out.json")" != "" ]]; then
    exit 3
  fi
}

self_check
case "${1:-}" in
  --check-reason) [[ $# -eq 1 ]] || check_fail "usage: --check-reason < reason-file"; check_reason ;;
  --check-ids) [[ $# -le 2 ]] || check_fail "usage: --check-ids [findings-json] < ids-file"; check_ids "${2:-}" ;;
  *) trusted "$@" ;;
esac
