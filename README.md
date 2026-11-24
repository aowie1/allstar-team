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

## Consistent output, tunable detail

Every agent answers in the same shape: verdict or result first, numbered findings (`F1`, `F2`), then next steps. Reviewers share one review template and the verdicts `APPROVE | CHANGES | BLOCK`; PR comments carry a marker and the reviewed SHA.

Turn detail up or down with `.claude/allstar-team.yml` (copy [`allstar-team.example.yml`](allstar-team.example.yml)):

```yaml
output:
  verbosity: standard        # terse | standard | detailed
  surfaces: { session: standard, github: terse }   # where the output lands
  agents: { code-reviewer: detailed }              # per agent
```

Set `min_priority: p1` to list only P0 (Critical) and P1 (High) findings; the rest are counted, not hidden silently, and verdicts still reflect them. Or per run: `/allstar-team:review-pr 42 --verbosity terse --min-priority p1`. Critical and High findings, owner decisions and the reviewed SHA are shown at every level. Full spec: [`docs/output-formats.md`](docs/output-formats.md). After editing a shared block, run `scripts/check-output-contract.sh`.

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

Or copy `agents/*.md` and `commands/*.md` into a project's `.claude/`. Copy `allstar-team.example.yml` to `.claude/allstar-team.yml` to tune output.

## Per-project setup

See [`PROJECT_TEMPLATE.md`](PROJECT_TEMPLATE.md): a short block to paste into the host project's `CLAUDE.md` covering stack, quality gates, docs locations, labels, invariants and owner-decision rules.

## Requirements

- The orchestration agents use the `gh` CLI with the active account. Reads are enough for review; writes are needed for posting comments and for `pr-contributor` to push to PR branches.
- The orchestrators dispatch other agents. If your Claude Code session does not let subagents spawn subagents, they stop after planning and return the roster and prompts for the main session to run.
- Implementers (frontend, backend, database, infra) are stack-specific and not included. Add your own in the project's `.claude/agents/`; `engineering-pm` routes to them when present and falls back to `general-purpose`.
