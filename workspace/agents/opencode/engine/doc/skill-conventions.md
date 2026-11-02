<!-- omit from toc -->
# Skill Conventions

[![Doc][doc-shield]][doc-url]

## Directory Structure

Every skill follows this format for cross-agent portability:

```
skills/<name>/
  package.json        # npm metadata
  SKILL.md            # main instruction file
  instructions/       # (optional) additional instruction files
  prompts/            # (optional) reusable prompt templates
  .cursor/rules/      # (optional) Cursor-specific rules
  .windsurf/rules/    # (optional) Windsurf-specific rules
```

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Cross-Agent Placement

Each skill is compatible with these agents depending on the target:

| Agent | File Location |
|-------|---------------|
| OpenCode | `~/.config/opencode/skills/<name>/SKILL.md` (symlinked to `/opt/engine/skills/`) |
| Claude Code | Project root `CLAUDE.md` or `instructions/<name>.md` |
| Cursor | `.cursor/rules/<name>.mdc` |
| Windsurf | `.windsurf/rules/<name>.md` |
| Cline | `.clinerules/<name>.md` |
| GitHub Copilot | `.github/copilot-instructions.md` (merged) |

### Skill-to-Agent Mapping

Specific skills and their primary agent assignments:

| Skill | Primary Agent | Purpose |
|-------|--------------|---------|
| `audit-observability` | `orchestrator`, `scrum-master` | State contract audit trail, orchestration observability, score analytics, cross-service consistency enforcement |
| `orchestration-template` | `orchestrator`, `scrum-master` | Contract-based multi-agent orchestration, state machine enforcement |
| `business-analyst` | `product-manager`, `system-analyst` | Requirements gathering, acceptance criteria (GWT), value prioritization |
| `writing-plans` | `product-manager`, `system-analyst` | Structured implementation plans, dependency graphs, rollback strategy |
| `system-analyst` | `system-analyst`, `software-architect` | Architecture evaluation, dependency mapping, impact analysis |
| `test-driven-development` | `developer` | Red/green/refactor cycle |
| `software-developer` | `developer` | Full-stack conventions, clean code, SOLID |
| `devops-expert` | `devops-engineer` | CI/CD, containerization, deployment strategies |
| `observability-and-instrumentation` | `devops-engineer` | Logging, metrics, tracing, alerting, SLI/SLO |
| `systematic-debugging` | `fixer`, `developer` | Structured root cause analysis for bounded fixes |
| `code-review-and-quality` | `quality-analyst`, `security-engineer` | Review checklists, quality metrics |
| `qa-expert` | `quality-analyst` | Test strategy, coverage analysis, regression prevention |
| `security-expert` | `security-engineer`, `quality-analyst` | Vulnerability assessment, secure coding, compliance |
| `verification-before-completion` | `learner`, `quality-analyst` | Verify success criteria before marking complete |
| `adaptive-solver` | `scrum-master` | Meta-cognitive uncertainty resolution for blocked tasks |

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Publishing

Skills can be published to skills.sh via `npx skills deploy`. Each skill must have:
- `package.json` with `name`, `version`, `description`, `keywords`
- `SKILL.md` with the skill instructions

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- REFERENCE LINKS -->

[doc-shield]: https://img.shields.io/badge/DOC-文档-blue?style=for-the-badge
[doc-url]: #

[docs-shield]: https://img.shields.io/badge/DOCS-文档-blue?style=for-the-badge
[docs-url]: #

[github-shield]: https://img.shields.io/badge/GitHub-181717?style=for-the-badge&logo=github
[github-url]: #
