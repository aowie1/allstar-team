# allstar-team

A team of specialist agents to build quickly and accurately and ship secure and robust code.

Portable Claude Code agent roles. Stack-neutral: each agent reads the host project's `CLAUDE.md`, `AGENTS.md`, README and ADRs for conventions instead of hardcoding them.

| Agent | Model | Role |
|---|---|---|
| `code-reviewer` | opus | Bugs, security, type safety, local conventions in a diff |
| `alignment-reviewer` | opus | Scope, roadmap, architecture and naming fit |
| `principal-engineer` | opus | Technical gate on an issue before implementation |
| `qa-specialist` | sonnet | Tests, flaky-test root causes, load scenarios |
| `documentation-specialist` | sonnet | PRDs, TRDs, ADRs, runbooks, CLAUDE.md |
| `system-design-architect` | opus | System design and architecture review |
| `security-specialist` | opus | Threat models and security review (read-only) |

## Install

Via marketplace (from a pushed repo):

```
/plugin marketplace add aowie1/allstar-team
/plugin install allstar-team@allstar-team
```

Local, for development:

```
claude --plugin-dir /path/to/allstar-team
```

Or copy `agents/*.md` into a project's `.claude/agents/`.

## Per-project setup

Put project facts in the host project's `CLAUDE.md`: stack, test commands, where specs and ADRs live, branch and PR conventions. The agents pick them up from there.

## Not included (Crowdline-specific)

`engineering-pm`, `review-dispatcher`, `pr-contributor`, `dba-specialist`, `backend-specialist`, `frontend-specialist`, `devops-specialist` depend on Crowdline's GitHub App helpers, label lifecycle, openspec layout and stack.
