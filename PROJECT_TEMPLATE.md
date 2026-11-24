# Project setup for allstar-team

The agents are stack-neutral. They learn a project from its own docs. Copy the section below into the host project's `CLAUDE.md` (fill in what applies, delete what doesn't) and they get sharper immediately.

```markdown
## Agent context (allstar-team)

**Stack:** {language, framework, datastore, hosting}

**Quality gates (run in this order before any PR):**
1. {type-check command}
2. {lint command}
3. {build command}
4. {unit test command}
5. {e2e command, if any}

**Where things live:**
- Specs / design docs: {path}
- ADRs / decisions: {path}
- Reports (optional): {path}

**Tracker:** {GitHub issues | GitHub Project N | docs/ROADMAP.md}

**Status labels (if used):** new, triaged, reviewed, ready, in-progress, in-review, blocked, needs-owner
**Priority / type / area labels:** {list}

**Invariants (never break):**
- {e.g. access checks run first in every protected handler}
- {e.g. webhook signatures are verified before any processing}

**Owner decisions (stop and ask):**
- New dependency or third-party service
- Auth model change
- Schema change across tables
- Payments or money movement
- {project-specific}

**PR policy:**
- Branches: `{agent}/{short-desc}`; implementers push but do not open PRs.
- {Standing permission for the PM to open PRs after dual review? yes/no}
- Commit style: {conventional commits | other}
```

## Output verbosity (optional)

Agents default to `standard`. To change how much they write, copy `allstar-team.example.yml` to `.claude/allstar-team.yml` and set `output.verbosity` (`terse | standard | detailed`), per surface (`session`, `github`) or per agent. See `docs/output-formats.md`.

## Agents installed alongside

List any project-specific specialists (frontend, backend, database, infra) in `.claude/agents/`. `engineering-pm` routes implementation to them when present, otherwise to `general-purpose`.

## GitHub CLI

The orchestration agents use the `gh` CLI with whatever account is active. Make sure it has the access you intend (read for review, write if you want the dispatcher to post comments and the contributor to push to PR branches).
