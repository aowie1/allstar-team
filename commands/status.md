---
description: Generate a project status report via engineering-pm
argument-hint: "standup" for a short brief, "eod" for an end-of-day report, or a focus area (e.g. "open questions", "agent alignment"); add --verbosity terse|standard|detailed to override the project setting
---

Use the `engineering-pm` agent to generate a project status report.

Arguments: $ARGUMENTS

The agent should:
1. Read the project's docs and tracker (issues, project board, or status doc) to learn where status lives.
2. Read recent git activity and any prior report.
3. Check the code against documented status where it matters, and flag drift.
4. Report in the standard shape: owner decisions first, then done, in progress, blocked, drift and risks, open questions (with owner and blocking status), and next tasks.
   - `standup`: verbosity `terse`: one screen, owner decisions, blockers, next.
   - `eod`: verbosity `detailed`: the full report with evidence per item.
   - `--verbosity <level>`: sets the level for this run. With no flag or keyword, the project's `.claude/allstar-team.yml` decides (default `standard`).
5. Return the report inline. Write it to a file only if the project has a reports convention or the user asks.
6. Surface every `OWNER DECISION` prominently, each with a `→ Recommend:`.
