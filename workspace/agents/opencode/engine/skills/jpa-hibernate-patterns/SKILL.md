---
name: jpa-hibernate-patterns
description: N+1 prevention, lazy loading, @EntityGraph, batch fetching, query optimization
triggers:
  - "JPA patterns"
  - "Hibernate optimization"
  - "N+1 query"
sources:
  - url: https://github.com/piomin/claude-ai-spring-boot/blob/main/.claude/skills/jpa-patterns/SKILL.md
    author: piomin
---

# JPA Hibernate Patterns

JPA and Hibernate optimization patterns — N+1 query prevention, lazy loading strategies, @EntityGraph, batch fetching, and query optimization.

## Source

References: **piomin/claude-ai-spring-boot** by piomin  
URL: https://github.com/piomin/claude-ai-spring-boot/blob/main/.claude/skills/jpa-patterns/SKILL.md

## When to use

- Fixing N+1 select problems
- Optimizing entity graph loading
- Configuring batch fetching

## Key topics

- @EntityGraph and dynamic entity graphs
- Fetch strategies (LAZY vs EAGER)
- Batch fetching and subselect fetching
- Hibernate query plan cache

## Load canonical skill

```
/skill jpa-hibernate-patterns
```