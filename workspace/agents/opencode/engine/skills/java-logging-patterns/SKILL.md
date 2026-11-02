---
name: java-logging-patterns
description: SLF4J, Logback, structured logging, MDC correlation
triggers:
  - "logging patterns"
  - "SLF4J"
  - "Logback configuration"
sources:
  - url: https://github.com/piomin/claude-ai-spring-boot/blob/main/.claude/skills/logging-patterns/SKILL.md
    author: piomin
---

# Java Logging Patterns

SLF4J logging facade, Logback configuration, structured logging with MDC, and correlation ID patterns for distributed tracing.

## Source

References: **piomin/claude-ai-spring-boot** by piomin  
URL: https://github.com/piomin/claude-ai-spring-boot/blob/main/.claude/skills/logging-patterns/SKILL.md

## When to use

- Configuring SLF4J/Logback
- Implementing structured logging
- Adding MDC correlation IDs

## Key topics

- SLF4J parameterized logging
- Logback appenders and layouts
- MDC context propagation
- Structured JSON logging

## Load canonical skill

```
/skill java-logging-patterns
```