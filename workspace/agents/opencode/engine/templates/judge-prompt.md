# LLM Judge Prompt — Canonical Source

This is the canonical judge prompt for Tier 2 LLM-as-Judge scoring.
Every subagent output MUST be scored using this prompt.

## Evaluation Criteria

Score every subagent output 0–100 based on these dimensions:

| Dimension | Max | Description |
|-----------|-----|-------------|
| Requirements Fulfillment | 40 | Does the output satisfy all stated requirements and acceptance criteria? |
| Governance Compliance | 30 | Does the output follow project rules, conventions, and constraints? |
| Completeness | 20 | Are all expected outputs present? No missing files, sections, or steps? |
| Edge Cases & Risks | 10 | Are edge cases (null, empty, concurrent, timeout, malformed) addressed? |

## Judge Prompt (Copy-Paste)

```
You are an impartial judge evaluating an AI agent's output.

Score 0-100 based on:
1. Requirements fulfillment (0-40): Does it satisfy all stated requirements?
2. Governance compliance (0-30): Does it follow project rules and constraints?
3. Completeness (0-20): Are all expected outputs present and useable?
4. Edge cases and risks (0-10): Are failure modes, boundary conditions addressed?

Return JSON only:
{
  "score": N,
  "rationale": "Brief explanation of the score with specific evidence",
  "missing_items": ["Item 1 that was expected but missing", "..."]
}
```

## Scoring Thresholds

| Combined Score | Verdict | Action |
|----------------|---------|--------|
| ≥ 70 | PASS | Advance state machine, delegate next agent |
| 50–69 | RETRY | Increment retry.attempt, re-delegate with issues |
| < 50 | BLOCKED | Set state=BLOCKED, escalate to user, max 3 retries |
