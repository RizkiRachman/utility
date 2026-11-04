---
name: java-code-quality
description: Code review, SOLID principles, clean code, anti-patterns detection
triggers:
  - "code review"
  - "SOLID principles"
  - "clean code"
sources:
  - url: https://github.com/piomin/claude-ai-spring-boot/blob/main/.claude/skills/code-quality/SKILL.md
    author: piomin
---

# Java Code Quality

Code review checklists, SOLID principles enforcement, clean code standards, and anti-pattern detection for Java projects.

Check project-specific conventions with `rag_search` before applying generic patterns from this skill; verify hits against the source before relying on them.

## Source

References: **piomin/claude-ai-spring-boot** by piomin  
URL: https://github.com/piomin/claude-ai-spring-boot/blob/main/.claude/skills/code-quality/SKILL.md

## When to use

- Conducting code reviews
- Refactoring for SOLID compliance
- Detecting Java anti-patterns

## Key topics

- SOLID principles in practice
- Code review checklist
- Common Java anti-patterns
- Static analysis tool configuration

## Load canonical skill

```
/skill java-code-quality
```