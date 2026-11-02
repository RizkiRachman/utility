---
name: awesome-pr
description: Write excellent pull requests — Conventional Commit titles, a high-signal description template, review checklist, small-PR sizing, and gh CLI / GitHub API fallback. Use when creating, reviewing, or preparing a pull request.
license: MIT
compatibility: opencode
tags:
  - pull-request
  - github
  - review
  - release
---

# Awesome PR

Standard for pull requests, distilled from Conventional Commits and high-performing open-source review practice.

## When to Use

- Creating a new pull request
- Preparing a branch for review
- Reviewing a PR description before requesting reviewers

## PR Title

Format: `<type>(<scope>): <summary>` — Conventional Commits.

| Type | Use for |
|------|---------|
| `feat` | New user-facing capability |
| `fix` | Bug fix |
| `refactor` | Behavior-preserving restructuring |
| `docs` | Documentation only |
| `test` | Tests only (no behavior change) |
| `chore` | Maintenance, tooling, deps |
| `perf` | Performance improvement |
| `build` | Build system or dependencies |
| `ci` | CI/CD pipeline config |

Rules:

- **Imperative mood**: "add caching", not "added caching" or "adds caching".
- **≤ 72 characters** total. The summary is the commit-message subject, not the changelog.
- **Lowercase** summary start; no trailing period.
- Scope optional but recommended: `fix(parser): handle empty input`.

Examples:

```
feat(auth): add session refresh on token expiry
fix(api): reject null payload on batch endpoint
refactor(storage): extract blob client behind port
docs: update quick start for v2 install path
```

## PR Body Template

Use this exact markdown. Copy it, fill every section, delete sections that do not apply (only Screenshots is optional by design).

```markdown
## Summary
- <What changed — one bullet>
- <Why it changed — one bullet>
- <Key decision or tradeoff, if any>

## Changes
- `<path/to/file>` — <what changed and why>
- Renamed `oldSymbol` → `newSymbol` (find-and-replace free, call-graph safe)

## Testing
- `npm test` / `mvn verify` / `cargo test` — <pass/fail, counts>
- Manual: <steps tried, expected vs actual>

## Impact / Risk
- Blast radius: <modules/services touched; upstream callers>
- Breaking changes: <none | detail>
- Migration/rollback: <how to revert safely>

## Screenshots
<!-- UI changes only — before/after. Delete section otherwise. -->

## Related Issues
Closes #<N>

## Checklist
- [ ] Builds and tests pass locally
- [ ] No secrets or credentials committed
- [ ] Docs / CHANGELOG updated
- [ ] Backward compatible, or migration noted
- [ ] Rollback plan stated
- [ ] Self-review completed
- [ ] Linked issue referenced
```

## Checklist (non-negotiable)

- Builds and tests pass — CI green is the floor, not the goal.
- No secrets — scan the diff for tokens, keys, `.env` files before pushing.
- Docs / CHANGELOG updated when behavior or interfaces change.
- Backward compatible, or migration path documented in Impact/Risk.
- Rollback plan — how to revert in production without data loss.
- Self-review done — read your own diff as a reviewer before requesting one.
- Linked issue — every PR closes or references an issue.

## Small PRs

- **Aim for < 400 changed lines.** Review quality collapses above it.
- **One logical change per PR.** Fixing a bug and upgrading a dependency? Two PRs.
- **Split docs-only from behavior changes** — different reviewers, different risk.
- Refactor first (behavior-preserving), then the behavior change on top.

## Draft vs Ready

- Open as a **draft** while work-in-progress — signals "not ready", unblocks early CI feedback.
- Mark **ready for review** only after self-review passes and the checklist is clean.
- Never request formal review on a draft; do that by mentioning reviewers in a comment if early eyes are needed.

## Reviewer Guidance

- Request **1–2 reviewers**, not the whole team — more is noise, fewer is a bus-factor risk.
- **State what to focus on** in the PR description or a comment: risky area, novel design, subtle edge case.
- Example: "Reviewer focus: the retry loop in `sync.go` — backoff math and the timeout interaction."

## Create the PR

Preferred — GitHub CLI:

```bash
gh pr create --title "feat(auth): add session refresh on token expiry" \
  --body-file .github/pr-body.md --base main --head feat/session-refresh
```

`gh` may be unavailable (not installed, no auth). Fallbacks, in order:

1. **Compare URL** — open in a browser, paste the body manually:
   `https://github.com/<owner>/<repo>/compare/main...<branch>?expand=1`
2. **REST API** — authenticated `POST`, no token in the command itself (use `GH_TOKEN` env or your credential helper):
   ```
   POST /repos/{owner}/{repo}/pulls
   { "title": "...", "head": "<branch>", "base": "main", "body": "..." }
   ```

Never paste a token into a command, script, or this template.

## lean-ctx Conventions

- `lean-ctx ctx_delta` before opening the PR — verify the diff touches only intended symbols.
- `lean-ctx ctx_impact <changed symbol> upstream` — paste the blast radius into Impact/Risk.
- `lean-ctx ctx_shell` for any test/build commands quoted in the Testing section.
- Never rename via find-and-replace; `ctx_refactor` keeps the call graph consistent.
