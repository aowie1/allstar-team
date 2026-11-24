---
description: Identify and dispatch the next highest-priority work to specialist agents via engineering-pm
argument-hint: Optional focus and flags (e.g. "frontend", "unblock checkout --verbosity terse --min-priority p1")
---

Use the `engineering-pm` agent to identify and dispatch the next highest-priority work.

Focus (if provided): $ARGUMENTS

Flag: `--verbosity terse|standard|detailed` → pass `Output settings: verbosity=<level>` for this run only; otherwise the project's `.claude/allstar-team.yml` decides (default `standard`). See `docs/output-formats.md`. `--min-priority p0|p1|p2|p3` sets the lowest priority listed (`p1` = Critical and High). The PM passes the resolved settings to every agent it dispatches.

The PM should:
1. Read the project's docs and tracker to learn its process, labels and quality gates.
2. Identify the next 1–3 unblocked, non-owner-gated tasks that match the focus (or the highest priority overall). For GitHub issues, only ready issues with no open linked PR are eligible. If none are ready, run the intake and readiness gate instead: triage new issues, dispatch `principal-engineer` on triaged ones, promote to ready, then report.
3. Claim each issue (mark it in-progress, record the agent, comment) before spawning its agent.
4. For each task, confirm it needs no owner sign-off, then dispatch it to the right specialist with a self-contained prompt.
5. Wait for agents to finish, review their output for alignment, and run dual review on any pushed branch.
6. Report back: what was dispatched, what completed, what is now unblocked, new questions surfaced, and any owner decisions.

**The PM must not dispatch:**
- Blocked tasks.
- Tasks needing owner sign-off (new dependencies, auth changes, payment flows, schema changes across tables).
- Work in a future milestone unless the current one is complete.
