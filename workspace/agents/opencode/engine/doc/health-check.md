# Daily Health Check Protocol

> A self-contained protocol for AI agents to evaluate workflow architecture health.
> Run daily to ensure the engine stays consistent, healthy, and improves over time.

## How to Use

Copy the **Daily Prompt** (section 4) and paste it to your AI agent. The agent will:
1. Run all 7 health lenses against the live engine
2. Produce a scored report
3. Flag any regressions or improvements since last check
4. Append the result to `session/health-record.md`

---

## 1. The 7 Health Lenses

Each lens checks one dimension of system health. Results are weighted into a 0-100 score.

| # | Lens | Weight | What It Checks |
|---|------|--------|---------------|
| 1 | **Contract Integrity** | 15% | `scripts/validate-contract.sh --score` passes on template + live contract |
| 2 | **Knowledge vs File Drift** | 15% | `scripts/drift-detect.sh` - lean-ctx knowledge ↔ session file consistency |
| 3 | **Script Syntax** | 15% | `bash -n` on all `scripts/*.sh` - no syntax errors |
| 4 | **Agent Doc References** | 15% | Do `agents/*.md` reference scripts that exist? Any dead references? |
| 5 | **Knowledge Persistence** | 15% | `scripts/verify-knowledge.sh` - coverage of decisions, lessons, gotchas |
| 6 | **Session State Integrity** | 10% | `session/contract.json` + `session/state.md` present and well-formed |
| 7 | **Score Trend** | 15% | Compare today's score against the `session/health-record.md` baseline |

---

## 2. Scoring Rules

```
Total = weighted sum of all 7 lens scores

≥ 90  → ✅ HEALTHY - system is sound
70-89 → ⚠️ WARNING - issues to review
< 70  → 🔴 CRITICAL - immediate attention needed
```

### Trend Detection

Compare today's score against the last 3 entries in `session/health-record.md`:

| Pattern | Trend |
|---------|-------|
| Score >= last 3 entries | improving ↗ |
| Score <= last 3 entries | declining ↘ |
| Mixed / flat | stable → |
| First check ever | baseline set |

---

## 3. Implementation - Each Lens in Detail

### Lens 1: Contract Integrity [15pts]

```bash
# Check template
scripts/validate-contract.sh --file contract/contract.template.json --score
exit_code=$?
# 0=PASS (full points), 1=retry (half), 2=BLOCKED (0pts)

# Check live session contract (if present)
if [[ -f "session/contract.json" ]]; then
    scripts/validate-contract.sh --file "session/contract.json" --score
fi
```

**Scoring**: Template PASS (15pts), template+session both PASS (15pts), template RETRY (7pts), BLOCKED (0pts)

### Lens 2: Knowledge vs File Drift [15pts]

```bash
scripts/drift-detect.sh --session session --verbose
# exit 0 = no drift (15pts), exit 1 = drift detected (0pts)
```

**Scoring**: No drift (15pts), drift (0pts)

### Lens 3: Script Syntax [15pts]

```bash
TOTAL=0; PASS=0
for script in scripts/*.sh; do
    TOTAL=$((TOTAL + 1))
    if bash -n "$script" 2>/dev/null; then
        PASS=$((PASS + 1))
    fi
done
```

**Scoring**: All pass (15pts), each fail deducts 3pts (min 0)

### Lens 4: Agent Doc References [15pts]

```bash
# Extract all script references from agent docs
REFERRED=$(grep -ohP 'scripts/[a-z_-]+' agents/*.md | sort -u | sed 's|scripts/||')

# Check each exists
MISSING=0
for ref in $REFERRED; do
    [[ -f "scripts/$ref" ]] || MISSING=$((MISSING + 1))
done

# Also check scripts not referenced by any agent
ALL_SCRIPTS=$(ls scripts/*.sh | xargs -n1 basename | sed 's/\.sh$//')
UNREFERENCED=0
for s in $ALL_SCRIPTS; do
    grep -q "scripts/$s" agents/*.md || UNREFERENCED=$((UNREFERENCED + 1))
done
```

**Scoring**: 15 base, -3 per missing reference, -2 per unreferenced script (min 0)

> Automated: scripts/health-check.sh --check references (delegates to scripts/check-cross-references.sh).
> Docs mode: scripts/health-check.sh --check docs (delegates to scripts/check-doc-style.sh for the humanizer ship gate).

### Lens 5: Knowledge Persistence [15pts]

```bash
# Run verify-knowledge in dry-run mode
scripts/verify-knowledge.sh --dry-run --all 2>&1

# Extract coverage percentage from output
COVERAGE=$(scripts/verify-knowledge.sh --dry-run --all 2>&1 | grep -oP '[0-9]+%' | tail -1 | tr -d '%')
```

**Scoring**: Coverage ≥ 70% (15pts), 50-69% (8pts), <50% (0pts)

### Lens 6: Session State Integrity [10pts]

```bash
# Live contract present and valid JSON
[[ -f session/contract.json ]] && jq -e . session/contract.json >/dev/null && echo "contract OK"

# Append-only state log present
[[ -f session/state.md ]] && echo "state log OK"
```

**Scoring**: Both present and valid (10pts), one missing (5pts), neither (0pts)

### Lens 7: Score Trend [15pts]

```bash
# Read last score from session/health-record.md
LAST_SCORE=$(grep -oP '\| \d+ \|' session/health-record.md 2>/dev/null | tail -1 | tr -d '| ')

# If no baseline: this run becomes baseline (15pts by default)
# If baseline exists: compare
if [[ -n "$LAST_SCORE" ]]; then
    DROP=$((LAST_SCORE - TODAY_SCORE))
    if [[ DROP -gt 10 ]]; then
        # Regression: 0pts
    elif [[ DROP -gt 5 ]]; then
        # Mild regression: 7pts
    else
        # Stable or improving: 15pts
    fi
fi
```

**Scoring**: No regression >5pts (15pts), 5-10pt drop (7pts), >10pt drop (0pts), first run (15pts)

---

## 4. The Daily Prompt

Copy and paste this entire block to your AI agent for a daily health check:

> ```markdown
> Run daily health check on the Workflow State Engine.
>
> ## Protocol
>
> 1. **Read context**: Load `doc/health-check.md` for the full protocol. Load `session/health-record.md` for trend history.
> 2. **Run all 7 lenses** against the live engine (read-only - no --fix flags):
>    - Lens 1: `scripts/validate-contract.sh --file contract/contract.template.json --score`
>    - Lens 2: `scripts/drift-detect.sh --session session --verbose`
>    - Lens 3: `bash -n` on all `scripts/*.sh`
>    - Lens 4: Cross-reference agent docs vs scripts
>    - Lens 5: `scripts/verify-knowledge.sh --dry-run --all`
>    - Lens 6: Verify `session/contract.json` + `session/state.md` exist and are well-formed
>    - Lens 7: Compare score against `session/health-record.md` baseline
> 3. **Score**: Apply weights, compute total (0-100), determine verdict (HEALTHY/WARNING/CRITICAL)
> 4. **Trend**: Compare against last 3 entries in `session/health-record.md`
> 5. **Report**: Produce a concise report with:
>    - Score and verdict
>    - Any failures or warnings per lens
>    - Trend direction
>    - Top 1-3 recommendations if score < 90 or declining
> 6. **Persist**: Append result to `session/health-record.md` in this format:
>
>    ```markdown
>    | 2026-06-18 | 94 | HEALTHY | ↗ improving | No issues |
>    ```
>
>    Columns: Date | Score | Verdict | Trend | Issues / Notes
>
> ## Key Constraints
> - Read-only unless persisting the result record - do NOT modify scripts or contracts
> - If `drift-detect.sh` fails, do NOT auto-fix - just flag it
> - If any script is missing, note it but continue with remaining checks
> - If score < 80 OR trend is declining: propose a fix plan
> - If score >= 90 with stable/improving trend: confirm health, suggest 1 optimization
> ```

---

## 5. Health Record Format

Stored in `session/health-record.md`. Append-only chronological table:

```markdown
# Health Check Record

> Daily health scores for the Workflow State Engine.
> Updated after each daily health check.

| Date | Score | Verdict | Trend | Issues / Notes |
|------|-------|---------|-------|---------------|
| 2026-06-18 | 94 | ✅ HEALTHY | - (baseline) | No issues |
| 2026-06-19 | 92 | ✅ HEALTHY | → stable | minor drift |
| 2026-06-20 | 88 | ⚠️ WARNING | ↘ declining | validate-contract BLOCKED on session contract - needs investigation |
```

---

## 6. Quick Reference Card

```text
Command: Copy §4 prompt → paste to AI agent
Duration: ~2-3 minutes for AI to run all 7 lenses
Frequency: Daily
Trigger: Any of:
  - "Run daily health check"
  - "/health"
  - "Check system health"

Scoring:  90-100 ✅ HEALTHY
          70-89  ⚠️ WARNING
          < 70   🔴 CRITICAL

         Contract(15) + Drift(15) + Scripts(15) + AgentDocs(15) +
         Knowledge(15) + Session(10) + Trend(15) = 100

Files created/modified: session/health-record.md (appended)
Files read (read-only): All scripts, agents/, session/, contract/
```

---

*Last updated: 2026-06-18. Built on the workflow-state-engine automation scripts.*
