---
name: java-optional
description: Java Optional patterns, antipatterns, best practices for null safety
triggers:
  - "optional pattern"
  - "null safety"
  - "optional antipatterns"
sources:
  - url: https://github.com/martinfrancois/java-optionals-skill/blob/main/skills/java-optionals/SKILL.md
    author: martinfrancois
---

# Java Optional

Java Optional patterns, common antipatterns, and best practices for compile-time null safety and expressive API design.

## Source

References: **martinfrancois/java-optionals-skill** by François Martin  
URL: https://github.com/martinfrancois/java-optionals-skill/blob/main/skills/java-optionals/SKILL.md

## When to use

- Designing APIs with Optional return types
- Avoiding null-related NPEs
- Refactoring null checks to Optional

## Key topics

- Optional creation patterns (of, ofNullable, empty)
- Chaining with map/flatMap/filter
- orElse vs orElseGet pitfalls
- Optional in fields and method parameters

## Load canonical skill

```
/skill java-optional
```