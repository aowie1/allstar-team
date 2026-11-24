---
description: Triage a PR and dispatch the right review agents via review-dispatcher; keeps the PR tracker and linked issue in sync
argument-hint: PR number or URL, optionally with repo and flags (e.g. "42", "owner/repo#42 --review-only --verbosity terse --min-priority p1")
---

Review PR: $ARGUMENTS

Dispatch the `review-dispatcher` agent with the PR number (use the current repo unless one is given). Fix mode is the default: conflicts, red gates and Critical/High review feedback go to `pr-contributor`, then the affected reviewers re-review (max 4 rounds). Flag, passed to the dispatcher verbatim:

- `--review-only` → pass `REVIEW ONLY`: review and report, never dispatch the contributor.
- `--verbosity terse|standard|detailed` → pass `Output settings: verbosity=<level>` for this run only; otherwise the project's `.claude/allstar-team.yml` decides (default `standard`). See `docs/output-formats.md`.
- `--min-priority p0|p1|p2|p3` → pass `min_priority=<p>` for this run only: list findings at or above it (`p1` = Critical and High; `p0` is treated as `p1`, since PR comments always list High). Hidden findings are counted, and verdicts still reflect them.

Pass a flag only when the user typed it. The dispatcher will:

1. Snapshot the PR with `gh`: state, head SHA, linked issue, CI, changed files, earlier agent comments.
2. Triage from the diff and the issue's labels, then run in parallel: `code-reviewer` + `alignment-reviewer` always, and security, architecture, QA, docs and installed domain specialists as warranted. On a re-run it re-reviews only what the new commits affect.
3. Post each reviewer's comment on the PR (verdict `APPROVE`/`CHANGES`/`BLOCK`, concern level, reviewed SHA) plus a dispatch summary, each at its resolved verbosity (flags apply to all; per-agent config entries still apply).
4. If changes are requested, run the fix loop: the contributor fixes the code items, then reviewers re-run.
5. Update the linked issue: a living tracker comment, and label moves only if the project uses status labels.

It never approves or merges. Report back: combined state, roster and why, each reviewer's verdict and concern, label moves made, and the next human action.

For a branch with no PR yet, use `engineering-pm` section 4 (it reviews the branch before a PR exists); the dispatcher needs a PR to track.
