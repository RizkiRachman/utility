---
name: requesting-code-review
description: Conducts thorough code reviews on others' changes. Checks correctness, design, performance, security, and adherence to conventions.
---

# Requesting Code Review

Conducts thorough code reviews on others' changes. Checks correctness, design, performance, security, and adherence to conventions.

## When to Use
- PR or changeset is ready for review
- Peer asked for a review
- Pre-merge quality gate

## What to Check
1. **Correctness**: Does the code do what it claims?
2. **Design**: Does it follow project architecture (hexagonal, Spring Boot conventions)?
3. **Edge cases**: Nulls, empty states, error conditions
4. **Security**: Input validation, injection, exposure
5. **Testing**: Adequate coverage, meaningful assertions
6. **Naming**: Clear, consistent with project
7. **Simplicity**: Could it be simpler?

## Guidelines
- Focus on the code, not the author
- Distinguish blockers from suggestions
- Provide examples for unclear feedback
- Approve only when you're confident
