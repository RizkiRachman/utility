---
name: rebase-commit
description: Interactive rebase, squash, commit cleanup, history management
triggers:
  - "interactive rebase"
  - "squash commits"
  - "commit cleanup"
sources:
  - url: https://github.com/jvm-skills/jvm-skills/blob/main/.claude/skills/rebase-commit/SKILL.md
    author: jvm-skills
---

# Rebase & Commit Cleanup


## Source

References: **jvm-skills/jvm-skills** by jvm-skills  
URL: https://github.com/jvm-skills/jvm-skills/blob/main/.claude/skills/rebase-commit/SKILL.md

## When to use

- Cleaning up commit history before PR
- Squashing related commits
- Handling rebase conflicts

## Key topics

- Interactive rebase (pick, squash, fixup, reword)
- Conflict resolution during rebase
- Force-push safety (--force-with-lease)
- Commit reordering and dropping

## Load canonical skill

```
/skill rebase-commit
```