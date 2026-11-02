---
name: business-analyst
description: Business analysis — requirements gathering, process modeling, stakeholder communication, and value-driven prioritization
license: MIT
compatibility: opencode
tags:
  - requirements
  - stakeholder
  - process-modeling
  - prioritization
file_patterns:
  - "**/*.md"
metadata:
  role: analyst
  domain: business
triggers:
  - "requirements"
  - "stakeholder"
  - "process model"
  - "prioritization"
---

# Business Analyst

## Core Practices

- **Requirements**: start with the problem, not the solution. Ask "why?" five times. Distinguish functional vs non-functional. Document: actors, triggers, preconditions, expected outcomes, failure handling.

- **Stakeholders**: executives need cost/value/risk; developers need behavior/edge cases; users need workflow changes. Validate understanding back.

- **Process modeling**: map as-is before to-be. Identify handoffs, wait states, decision points, failure paths.

- **Prioritization**: value vs effort. Consider user impact, business value, tech debt, risk reduction.

- **Writing**: one requirement per sentence. Testable and unambiguous. Always include failure paths.

## Stakeholder Communication Patterns

### Explaining Tradeoffs (Cost / Time / Quality Triangle)

Frame every tradeoff conversation around the three constraints. Rarely can you maximize all three at once.

| Stakeholder | Language | Tradeoff Frame |
|-------------|----------|----------------|
| **Executive / Sponsor** | Cost, risk, time-to-value, competitive advantage | "Faster delivery means narrower scope: which slice delivers the most value first?" |
| **Product Manager** | Feature set, user impact, release cadence | "Full OCR in sprint 1 cuts receipt coverage but buys us time for price history. Is breadth or depth the priority?" |
| **Developer** | Technical debt, complexity, maintainability | "This approach adds 2 weeks but eliminates a future rewrite. Is the schedule or code health more critical right now?" |
| **End User** | Workflow changes, learning curve, reliability | "You'll get results faster, but the search filters will look different. Is speed or familiarity more important?" |

### Asking Clarifying Questions

When requirements are ambiguous, use structured probes:

- **Boundary probe**: "When you say 'recent receipts' — do you mean last 7 days, last 30, or something else?"
- **Priority probe**: "If we can only deliver one of those two features, which one should we protect?"
- **Failure probe**: "What should happen if the OCR service is down? Should receipts queue, or should we show an error?"
- **Scope probe**: "Does 'all stores' include international locations, or only domestic ones?"
- **Completeness probe**: "Who else depends on this data changing? Should we notify them?"

### Validation Patterns

- **Show, don't ask**: Instead of "Is this right?", present a concrete example: "So if I search 'milk' and Store A has it for $4.50 and Store B for $4.99, you'd expect both shown sorted cheapest first. Is that correct?"
- **Walk the failure path**: "What happens when a store removes a product — should the price history remain, or should the listing disappear?"
- **Quantify the vague**: Replace "fast" with "under 500ms", replace "frequently" with "more than 5x/day".

## Conflict Resolution

### Scope Disagreement

Use the **Minimum Viable Scope (MVS)** technique:

1. List every requested feature on separate cards
2. Ask: "If we shipped *only* this card next week, would it deliver user value?"
3. Separate **must-have** from **nice-to-have** — any feature that doesn't pass the MVS test is deferred
4. Deferred items go into a **parking lot** with a documented reason and a trigger condition for re-evaluation

**Example**: A stakeholder wants receipt OCR to auto-suggest store names. The core value is extracting items/prices. Auto-suggestion is deferred with trigger: "after 1000 receipts processed, re-evaluate based on OCR accuracy stats."

### Priority Disagreement

Use **weighted scoring** to depersonalize decisions:

| Criterion | Weight (1-5) | Feature A | Feature B |
|-----------|-------------|-----------|-----------|
| User impact (# users affected) | 5 | 4 (20) | 2 (10) |
| Business value (revenue/cost) | 4 | 3 (12) | 5 (20) |
| Implementation cost (inverse) | 3 | 2 (6) | 4 (12) |
| Risk reduction | 2 | 1 (2) | 3 (6) |
| **Total** | | **40** | **48** |

The framework objectifies the decision. If a stakeholder still disagrees, ask: "Which weight or score doesn't reflect reality for you?" — this pinpoints the actual disagreement.

### Resource Constraints

When the team cannot do everything:

1. **Slice vertically**, not horizontally: deliver one complete flow end-to-end instead of half-implementing three flows
2. **Trade scope for quality**: narrower scope at higher quality beats broad scope with defects
3. **Call the tradeoff explicitly**: "If we add this, we must drop or delay [specific other item]. Are you OK with that?"

## Value Prioritization Framework

### Impact / Effort Matrix

Plot every requirement on two axes and categorize:

| Quadrant | Action | Example |
|----------|--------|---------|
| **High Impact, Low Effort** | Do first (quick wins) | Adding sort-by-unit-price to comparison results |
| **High Impact, High Effort** | Schedule strategically | Full OCR pipeline with receipt image processing |
| **Low Impact, Low Effort** | Do as filler / tech debt | Store address format normalization |
| **Low Impact, High Effort** | Drop or deprioritize | Custom receipt template designer |

### WSJF (Weighted Shortest Job First) — SAFe-aligned

```
WSJF = (User-Business Value + Time Criticality + Risk Reduction) / Job Size
```

Score each factor 1-10, then divide by estimated effort (story points or ideal days). Highest WSJF is next.

**Project-specific example** — Price Comparison Service:

| Feature | Value | Criticality | Risk Red'n | Total | Effort (days) | WSJF |
|---------|-------|-------------|------------|-------|---------------|------|
| Sort by unit price | 8 | 5 | 3 | 16 | 2 | 8.0 |
| Store locator map | 6 | 3 | 1 | 10 | 5 | 2.0 |
| Barcode scan | 9 | 7 | 4 | 20 | 8 | 2.5 |
| Price alert push | 7 | 6 | 5 | 18 | 6 | 3.0 |

Results: sort-by-unit-price first (highest WSJF). Barcode scan would wait despite higher total value.

### Risk-Adjusted Prioritization

Add a **risk reduction multiplier** for features that:

- **Reduce uncertainty**: "We don't know if OCR can handle handwritten receipts — let's prototype that path first"
- **Unblock downstream**: "Price comparison depends on normalized units — do unit standardization before aggregation"
- **Prevent rework**: "Get the data model right before building the UI"

Rule: if a feature unblocks 3+ other features, it automatically moves to the top of the backlog regardless of WSJF score.

## Deepened Project-Specific Examples

### Price Comparison

**Probes**: Executive → "Real-time or hourly refresh? Budget for data acquisition?" / User → "Search by name or barcode? Rank stores or just lowest price?" / Data → "API, scrape, or manual entry?"

**Decisions**: Prices fetched on search (freshness over cache). Stale data (>24h) gets a badge. No multi-currency in v1. Missing stores degrade gracefully with gap notes.

### Receipt Processing

**Probes**: Compliance → "Image retention policy? PII handling?" / Product → "Item-level or just store/total/date?" / Engineering → "Accuracy threshold: 90% or 95%?"

**Decisions**: Images encrypted + deleted after 30 days. Extracted data retained for price history. Item-level parsing best-effort; totals/dates required. Rejected receipts show clear reason (blurry, missing total). Manual corrections feed model training.

### Product Catalog

**Probes**: Admin → "Centralized or store-submitted?" / Data quality → "How to match 'Organic Whole Milk 1gal' with 'Milk, Organic, Gallon'?" / Operations → "Discontinued: vanish or stay with label?"

**Decisions**: Central catalog with moderated submissions. Matching via name normalization + optional barcode. Discontinued products hidden from search but kept in price history. Hierarchical categories (Dairy > Milk > Whole Milk). 30-day grace before archival.

### Domain Summary

| Domain | Core Flow | Edge Cases |
|--------|-----------|------------|
| **Price Comparison** | Compare product prices across stores; sort by unit price, date, promo status | Missing store prices, stale data, currency mismatches |
| **Receipt Processing** | Extract items, totals, dates, store from uploaded receipts | Blurry scans, missing items, partial OCR failures |
| **Product Catalog** | Manage products with categories/brands/units; search by name or barcode | Renames without breaking price history, inactive products |
| **Store Management** | Manage stores with locations/status; store-specific pricing rules | Closures, address changes, regional availability |

## Acceptance Criteria (Given/When/Then)

```text
Given product "Organic Milk" exists at Store A ($4.50) and Store B ($4.99)

When the user searches for "Organic Milk"

Then both prices shown, sorted cheapest first; Store A marked lowest

Given a receipt hash matches an existing record

When the user uploads the same receipt again

Then system rejects with error code RECEIPT_DUPLICATE; original data preserved

```
## Token Optimization

```bash
/skill token-optimize

```
## lean-ctx Conventions

When using this skill:

- Use `lean-ctx ctx_read` for reading files (cached, compressed, ~13 tok for unchanged files)

- Use `lean-ctx ctx_edit` for edits needing context persistence

- Use `lean-ctx ctx_shell` for all shell commands (NOT the `bash` tool — it's denied in opencode.json)

- After completing work, persist any new patterns/gotchas discovered: `lean-ctx ctx_knowledge remember category <cat> key <key> value <value>`

