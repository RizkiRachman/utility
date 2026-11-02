---
name: adaptive-solver
description: A meta-cognitive reasoning loop for AI agents facing ambiguity, low confidence, or failed approaches. Instead of guessing or stopping, the agent enters a structured loop: detect the gap, inventory available skills, hypothesize the best fit, attempt it, evaluate the result, and retry with the next candidate — all within its own reasoning context.
---

# Adaptive Solver

A reasoning framework that turns impasse into a systematic search. When the agent hits a wall — ambiguous input, flagging confidence, or a tool call that returned nothing useful — this skill governs *how* it thinks, pivots, and converges without asking the user.

The adaptive solver is the **in-agent** half of a two-level uncertainty model:

| Level | Where | Mechanism | When |
|-------|-------|-----------|------|
| **Level 1: In-agent** | Inside the agent's reasoning | Adaptive Solver loop | Ambiguity, low confidence, failed attempt mid-task |
| **Level 2: Cross-agent** | Orchestrator level | `uncertainties[]` in contract envelope + RETRY/BLOCKED flow | Uncertainty requires different agent type or human input |

Level 1 (this skill) handles ~90% of cases. Only escalate to Level 2 when the adaptive loop exhausts its 3 attempts and the agent still cannot resolve.

## When This Skill Activates

Three distinct trigger conditions. Any one is sufficient:

1. **Ambiguous input** — The user's request has multiple valid interpretations, or key information is missing that changes which approach is correct.

2. **Low agent confidence** — The agent has an answer but confidence is below threshold (≤ 3/5 on the rubric below). This includes cases where the agent is pattern-matching rather than reasoning from first principles.

3. **Failed attempt** — A tool call returned empty or unexpected results, a skill was read but didn't apply cleanly, or the agent's output didn't satisfy the goal when self-checked.

**Do not activate for:** Mechanical operations (renaming, formatting, file moves), one-line changes with obvious correctness, pure tooling operations (running tests, listing files), or when the user explicitly asked for speed over verification.

## The Adaptive Loop

Run this loop in your internal reasoning. Do NOT surface the loop mechanics to the user — only surface final output and confidence.

```
PHASE 1: DETECT
  │
  ▼
PHASE 2: INVENTORY
  │
  ▼
PHASE 3: HYPOTHESIZE
  │
  ▼
PHASE 4: ATTEMPT
  │
  ▼
PHASE 5: EVALUATE ────→ resolved? ──→ COMMIT
  │                      │
  └──── retry < 3 ──────┘
         (pick next candidate)
```

### Phase 1: DETECT

Identify which trigger fired. Name it explicitly.

```
I'm stuck because: [ambiguity | low confidence | failed attempt]
The specific gap is: ___
```

**Don't skip this phase.** Vague gaps produce vague hypotheses. Be precise about what's blocking progress.

### Phase 2: INVENTORY

List every available skill and general strategy option. For each, ask: "Does this address my specific gap?"

Score each candidate on two axes:

| Axis | Scale | Meaning |
|------|-------|---------|
| **Relevance** | 1–3 | How directly does this address the named gap? (3 = directly resolves it) |
| **Feasibility** | 1–3 | Can the agent actually execute this right now? (3 = tool/skill available, data present) |

**Priority Score = Relevance × Feasibility.** Rank top 3 by score. If tied, prefer higher Relevance.

Stop at 3 candidates. The loop gives you 3 retries max — matching one candidate per retry is intentional.

**Gap type → matching heuristic:**

| Gap Type | Priority Match |
|----------|---------------|
| **Information gap** (missing data) | Tools that retrieve external data (web search, file reading, MCP connectors). If none exist → commit with best-effort and flag the gap. |
| **Interpretation gap** (multiple valid readings) | Structured decomposition first (see Fallback Strategies §2). Try most likely interpretation, score, retry with next if low. |
| **Capability gap** (no skill covers the task) | Scan for partial overlap — can a skill handle 70%? Combine two skills? Fall back to first-principles strategy. |
| **Confidence gap** (can't verify correctness) | Find a verification path. Derive answer from a different angle. Identify the specific assumption lowering confidence. |

### Phase 3: HYPOTHESIZE

Pick the rank-1 candidate from Phase 2. State **why** it might resolve the gap.

If no skill in the inventory cleanly matches, pick a first-principles fallback strategy (see Fallback Strategies below).

### Phase 4: ATTEMPT

Execute the hypothesis. Keep the attempt scoped — don't over-commit on the first try. Use the skill or strategy as intended.

### Phase 5: EVALUATE

Score the result using the Confidence Rubric (below). Ask three questions:

1. **Does this resolve my original gap?** (Yes / Partial / No)
2. **What confidence do I have in this result?** (1–5 per rubric)
3. **Should I commit or retry?**

Decision matrix:

| Gap Resolved? | Confidence | Action |
|---------------|------------|--------|
| Yes | ≥ 4/5 | → **COMMIT** |
| Partial | 3/5 | → Retry with next candidate (if attempt < 3) |
| No | ≤ 2/5 | → **Exhaust this strategy.** Move to next candidate. |
| Attempt 3 | Any | → **COMMIT** with best-available answer and explicit confidence |

**Maximum retries: 3.** After 3 attempts without a confident result, commit to the best-available answer with explicit confidence score. The user gets resolution, not an infinite loop.

## In-Context State Tracking

Since there is no file I/O for internal state, maintain a **mental ledger** across loop iterations:

```
[Attempt 1] Strategy: <name> | Gap addressed: Yes/Partial/No | Confidence: 2/5
[Attempt 2] Strategy: <name> | Gap addressed: Yes/Partial/No | Confidence: 4/5
→ Selected: Attempt 2 result
```

- Never reset confidence gains. If attempt 1 partially resolved the gap, attempt 2 builds on that partial result.
- Mark a strategy as EXHAUSTED once tried. Don't re-rank it.
- If two strategies produce conflicting answers, use the higher-confidence one and note the `!!` conflict in the final output.

## COMMIT: Escape Hatch

When the loop exits (either resolved or max retries reached), format the final answer:

```
[Answer content here — complete and actionable]

Confidence: ★★★★☆ (4/5)
Basis: [One sentence explaining what approach worked or what remains uncertain]
```

**Confidence display rules:**

| Score | Show confidence? |
|-------|-----------------|
| 5/5 | No — omit entirely |
| 4/5, no retry, unambiguous input | No |
| 4/5, retry occurred OR input was ambiguous | Yes |
| ≤ 3/5 | Always |
| Max retries hit (any score) | Always |

## Reference: Confidence Rubric

Score on a 1–5 scale. Be honest — low scores are information, not failure.

### ★☆☆☆☆ (1/5) — No Progress
- Output is a guess with no grounding
- The gap that triggered the loop is completely unresolved
- Agent cannot explain *why* this is the answer
- High chance of hallucination

**Action:** Exhaust this strategy. Move to next candidate immediately.

### ★★☆☆☆ (2/5) — Marginal Signal
- Output addresses surface form but misses core intent
- Answer is plausible but relies on unverifiable assumptions
- One key piece of information is still missing
- Contradictions present in the reasoning

**Action:** Retry with a different strategy unless this is attempt 3. On attempt 3: commit with confidence displayed, note what's uncertain.

### ★★★☆☆ (3/5) — Partial Resolution
- Main gap is addressed, but edge cases or secondary questions remain open
- Answer is correct for the most likely interpretation
- Minor assumptions made, but they're reasonable
- Agent can defend this answer but acknowledges limitations

**Action:** If a better strategy is ranked and untried: retry. If this is the best available: commit with confidence displayed.

### ★★★★☆ (4/5) — High Confidence
- Gap is resolved for the primary use case
- Answer grounded in skill output, tool output, or sound reasoning
- Assumptions are explicit and justified
- Agent would stake reputation on this answer

**Action:** Commit. Show confidence only if a retry occurred or input was ambiguous.

### ★★★★★ (5/5) — Certain
- Answer is verifiable, derived directly from authoritative source or tool output
- No meaningful assumptions made
- No ambiguity remains in interpretation or approach
- Any reasonable agent would reach the same answer

**Action:** Commit. Do NOT show confidence score — it adds noise at this level.

### Quick Calibration

Ask these before scoring:

1. **Can I explain WHY this is the answer?** No → max score 2.
2. **Did I have to assume something unverifiable?** Yes → cap at 3 unless assumption is documented.
3. **Does the answer address what the user *actually* wants, not just what they said?** No → max score 3.
4. **Would a different reasonable approach give a different answer?** Yes → cap at 4.
5. **Is the answer derived from a tool/skill output or first principles?** Yes → eligible for 5.

## Reference: Fallback Strategies

Use when no available skill directly addresses the gap. These are first-principles reasoning patterns — no tools needed.

### Strategy 1: Decomposition
**Best for:** Capability gap. Task is too broad or composite for any single skill.

1. List every distinct requirement (not steps — outcomes).
2. For each requirement, check if any skill covers it.
3. Assemble partial results from multiple skills into a unified answer.
4. Note any requirement no skill covers — that remainder is your irreducible gap.

**Confidence:** If the irreducible gap is small and non-critical, can yield 4/5. If central to the task, cap at 3/5.

### Strategy 2: Interpretation Enumeration
**Best for:** Interpretation gap. Input has 2–4 distinct valid readings.

1. List all plausible interpretations (max 4 — if more, ask the user).
2. Score each by likelihood given conversation context.
3. Solve for the highest-likelihood interpretation.
4. Check: does the answer also partially satisfy the runner-up? If yes, mention both.
5. If two interpretations are equally likely with very different answers: solve for both and present both, noting the ambiguity.

**Confidence:** Max 4/5 (an assumption was made). Only 5/5 if user explicitly confirms interpretation.

### Strategy 3: Constraint Relaxation
**Best for:** Capability or confidence gap. Requirements seem contradictory or make the solution space empty.

1. List every constraint (must-haves, must-nots, format requirements).
2. Identify which specific constraint is causing the block.
3. Solve the task *without* that constraint.
4. Re-apply the constraint to the relaxed solution: does it still hold?
5. If the relaxed constraint was optional: present relaxed solution with a note. If required: report the task is unsolvable as stated and present closest feasible alternative.

**Confidence:** If relaxed constraint was truly optional: 4/5. If required but violated: ≤ 3/5, explain trade-off explicitly.

### Strategy 4: Analogical Reasoning
**Best for:** Confidence gap. Strong intuition but can't verify directly.

1. Identify the *structure* of the problem, not the domain details.
2. Find a domain where this structure is well-understood.
3. Solve in the familiar domain.
4. Translate the solution back, substituting domain-specific terms.
5. Check: does the translation hold? Any domain-specific constraints that break it?

**Confidence:** If the analogy holds cleanly: 4/5. If any part is approximate: 3/5. Never 5/5 — analogies are always approximations.

### Strategy 5: Incremental Commitment
**Best for:** Any gap type when other strategies have failed (attempt 2 or 3). Or when full answer needs more info than available.

1. Identify what you can answer with ≥ 4/5 confidence right now.
2. Commit to that partial answer — state it clearly.
3. Identify what remains open and why.
4. If the remaining part is critical: state it as an explicit unknown in the output.
5. If non-critical: complete with best-effort estimate, flagged as such.

**Confidence:** Partial answer at 4/5 is better than full answer at 2/5. Present committed part and estimated part at their respective confidence levels.

### Quick Strategy Selector

| Situation | Start with |
|-----------|-----------|
| Interpretation gap | Strategy 2 (Interpretation Enumeration) |
| Capability gap | Strategy 1 (Decomposition), then Strategy 3 if decomposition hits a wall |
| Confidence gap | Strategy 4 (Analogical Reasoning), then Strategy 5 if analogy doesn't hold |
| Information gap | Fallback strategies rarely help — you need data. Commit with Strategy 5 and flag the missing info. |
| Attempt 3 (last resort) | Always Strategy 5 (Incremental Commitment) |

## Interaction with Other Skills

| Skill | Relationship |
|-------|-------------|
| **doubt-driven-development** | Complementary. DDD is an *external* adversarial review (fresh-context reviewer). Adaptive solver is an *internal* structured search. Use DDD for decisions that need a second set of eyes; use adaptive solver for personal uncertainty. |
| **spec-driven-development** | SDD writes specs to prevent ambiguity. If adaptive solver detects an interpretation gap, the fix may be to clarify the spec — not guess. |
| **test-driven-development** | TDD's RED step is doubt made concrete. When adaptive solver identifies a capability gap, a failing test can act as the concrete commitment point. |
| **system-analyst** | When system-analyst encounters architectural uncertainty (two valid approaches with different trade-offs), run adaptive solver to inventory and evaluate before committing to a plan. |
| **writing-plans** | If adaptive solver hits ambiguity about which approach to plan for, write a minimal spec first (SDD), then plan. The plan's risk assessment section documents the interpretation gap. |
| **executing-plans** | During execution, if a step produces unexpected results, adaptive solver replaces blind retries with structured strategy switching. |

## Red Flags

- Running the loop for mechanical operations (renaming, formatting, one-line fixes)
- Skipping Phase 1 (naming the gap) — without a named gap, hypotheses are random
- Looping more than 3 times — commit to best-available, don't grind
- Treating a retry as failure — it's the loop working correctly
- Asking the user to resolve ambiguity when you have strategies left
- Forgetting to build on partial progress — attempt 2 should be smarter than attempt 1
- Surface the loop to the user ("I tried X, then Y, then Z...") — show only the result

## Verification

After applying the adaptive solver:

- [ ] The trigger was correctly identified (ambiguous input / low confidence / failed attempt)
- [ ] Phase 1 named the specific gap before attempting any strategy
- [ ] Phase 2 ranked at most 3 candidates by Relevance × Feasibility
- [ ] Phase 3 stated *why* the selected strategy might resolve the gap
- [ ] Phase 5 scored the result against the Confidence Rubric (1–5)
- [ ] The loop terminated by a stop condition (resolved, retries exhausted, or user intervention)
- [ ] The COMMIT phase followed confidence display rules (don't show for 5/5, always show for ≤ 3/5)
- [ ] The user received a complete answer and a confidence assessment — not loop mechanics