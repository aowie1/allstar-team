# allstar-team

A team of specialist agents to build quickly and accurately and ship secure and robust code.

Portable Claude Code agent roles. Stack-neutral: each agent reads the host project's `CLAUDE.md`, `AGENTS.md`, README and ADRs for conventions instead of hardcoding them.

## Agents

**Specialists**

| Agent | Model | Role |
|---|---|---|
| `code-reviewer` | opus | Bugs, security, type safety, local conventions in a diff |
| `alignment-reviewer` | opus | Scope, roadmap, architecture and naming fit |
| `principal-engineer` | opus | Technical gate on an issue before implementation |
| `qa-specialist` | sonnet | Tests, flaky-test root causes, load scenarios |
| `documentation-specialist` | sonnet | PRDs, TRDs, ADRs, runbooks, CLAUDE.md |
| `system-design-architect` | opus | System design and architecture review |
| `security-specialist` | opus | Threat models and security review (read-only) |

**Orchestration**

| Agent | Model | Role |
|---|---|---|
| `engineering-pm` | opus | Triage, readiness gate, dispatch, dual-review flow, status reports, owner-decision tracking |
| `review-dispatcher` | opus | Triages a PR, runs the right reviewers in parallel, posts findings, keeps a living tracker, drives the fix loop |
| `pr-contributor` | opus | Unblocks a PR: merge conflicts, red gates, review feedback; pushes minimal fixes to the PR branch |

## Commands

| Command | What it does |
|---|---|
| `/allstar-team:work [focus]` | `engineering-pm` picks and dispatches the next unblocked, ready tasks |
| `/allstar-team:review-pr <n> [--review-only]` | `review-dispatcher` reviews a PR; fixes it via `pr-contributor` unless `--review-only` |
| `/allstar-team:status [standup\|eod\|focus]` | `engineering-pm` writes a status report |

## How the flow fits together

```
issue ─▶ engineering-pm (triage) ─▶ principal-engineer (review) ─▶ ready
      ─▶ implementer pushes branch ─▶ code-reviewer + alignment-reviewer (+ risk reviewers)
      ─▶ PR ─▶ review-dispatcher ─▶ reviewers in parallel ─▶ verdicts
           └─ conflicts / red CI / changes requested ─▶ pr-contributor ─▶ re-review
      ─▶ READY TO MERGE (a human merges)
```

Nothing here approves or merges a PR. Owner decisions (new dependency, auth model, schema, payments, de-scoping) stop the workflow and are surfaced for a human.

## Install

Via marketplace (from the pushed repo):

```
/plugin marketplace add aowie1/allstar-team
/plugin install allstar-team@allstar-team
```

Local, for development:

```
claude --plugin-dir /path/to/allstar-team
```

Or copy `agents/*.md` and `commands/*.md` into a project's `.claude/`.

## Per-project setup

See [`PROJECT_TEMPLATE.md`](PROJECT_TEMPLATE.md): a short block to paste into the host project's `CLAUDE.md` covering stack, quality gates, docs locations, labels, invariants and owner-decision rules.

## Requirements

- The orchestration agents use the `gh` CLI with the active account. Reads are enough for review; writes are needed for posting comments and for `pr-contributor` to push to PR branches.
- The orchestrators dispatch other agents. If your Claude Code session does not let subagents spawn subagents, they stop after planning and return the roster and prompts for the main session to run.
- Implementers (frontend, backend, database, infra) are stack-specific and not included. Add your own in the project's `.claude/agents/`; `engineering-pm` routes to them when present and falls back to `general-purpose`.
