---
name: gradle-test-runner
description: Gradle test execution, filtering, parallel runs, test configuration
triggers:
  - "Gradle test"
  - "test runner"
  - "parallel testing"
sources:
  - url: https://github.com/jvm-skills/jvm-skills/blob/main/.claude/skills/test-gradle/SKILL.md
    author: jvm-skills
---

# Gradle Test Runner

Gradle test execution patterns — test filtering, parallel test execution, test report configuration, and CI integration.

## Source

References: **jvm-skills/jvm-skills** by jvm-skills  
URL: https://github.com/jvm-skills/jvm-skills/blob/main/.claude/skills/test-gradle/SKILL.md

## When to use

- Configuring Gradle test tasks
- Running tests in parallel
- Filtering tests by category or tag

## Key topics

- Test task configuration (forkEvery, maxParallelForks)
- Test filtering with JUnit Platform tags
- Parallel test execution strategies
- HTML/XML report configuration

## Load canonical skill

```
/skill gradle-test-runner
```