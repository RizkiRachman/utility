---
name: audit-observability
description: Monitors and audits state contract transitions, orchestration observability, score analytics, and cross-service consistency enforcement. Stepping stone toward multi-repo / multi-agent / multi-model orchestration.
---

# Audit Observability

## Overview

Audit Observability is a **vercel-labs/skills** compatible skill that enforces governance through state contract audit trails, orchestration transition observability, score analytics, and cross-service consistency checks. It is a **stepping stone** toward multi-repo / multi-agent / multi-model orchestration.

This skill codifies the audit and observability patterns that the orchestrator (orchestrator) uses to track state machine transitions, detect anomalies, and ensure contract integrity across sessions and services.

### Relationship to vercel-labs/skills Ecosystem

Follows the standard packaging convention:
- `SKILL.md` - instruction file with YAML frontmatter
- `package.json` - npm metadata for skills.sh publishing

---

## State Contract Audit Trail

Every state transition **MUST** append an audit entry to `contract.audit_log[]`. The orchestrator appends entries on every state change.

### Entry Format

```json
{
  "timestamp": "2026-06-17T10:00:00Z",
  "prev_state": "PLAN_SCORED",
  "new_state": "EXECUTE",
  "triggered_by": "orchestrator",
  "transition_reason": "Spec score ≥ 70 - proceeding to execution",
  "scoring_snapshot": {
    "combined": 82,
    "rules_subtotal": 85,
    "judge_score": 78,
    "verdict": "PASS"
  }
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `timestamp` | Always | ISO-8601 UTC timestamp of the transition |
| `prev_state` | Always | Previous state or `null` for INIT→PLAN |
| `new_state` | Always | The state being transitioned to |
| `triggered_by` | Always | Agent name (e.g., `orchestrator`, `system-analyst`) |
| `transition_reason` | Always | Why the transition occurred |
| `scoring_snapshot` | Optional | Present only when scoring was computed for this transition |

### Retention Policy

- Keep the **most recent 500 entries** in `contract.audit_log[]`
- When the log exceeds 500 entries, **archive the oldest 100** to lean-ctx knowledge:
  ```
  lean-ctx ctx_knowledge remember category architecture key audit-log-archive-<date> value <JSON array of archived entries>
  ```
- After archiving, trim to 500: `contract.audit_log = contract.audit_log.slice(-500)`
- **Safety**: If archiving fails (network issue, key collision), retain the full audit_log and retry on the next transition. NEVER trim without confirmation of successful archive - entries are lost otherwise.

### Where to Append

The `orchestrator` orchestrator appends audit entries in its post-transition hook, immediately after the contract state field is updated and before persistence:

```
1. Update contract.state to new state
2. Append audit_log entry
3. Run scoring pipeline (if applicable)
4. Persist contract: lean-ctx ctx_knowledge remember ...
5. Update STATE.md
```

---

## Orchestration Observability

### Querying Transitions

Use lean-ctx to inspect the full transition history:

```bash
# Load the current contract
lean-ctx ctx_knowledge recall --key "orchestration-contract:<task_id>" --mode "exact"

# Query archived audit logs
lean-ctx ctx_knowledge recall --query "audit-log-archive" --mode "semantic"

# Search for transitions from a specific state
lean-ctx ctx_search --pattern "\"prev_state\": \"EXECUTE\"" --ext ".json" --path template
```

### Stalled Phase Detection

A phase is **stalled** when the state machine has completed >5 transitions without a state change (i.e., repeated scoring cycles in the same phase).

Detection logic:
```
if (audit_log.length >= 2) {
    let recent = audit_log.slice(-6);  // last 6 transitions
    let uniqueStates = new Set(recent.map(e => e.new_state));
    if (uniqueStates.size === 1) {
        // STALLED: advisory warning
        emit("STALLED_PHASE", { state: uniqueStates[0], transitions: recent.length });
    }
}
```

When stalled:
1. Log advisory warning (no score deduction)
2. Optionally notify the orchestrator to investigate
3. The orchestrator may choose to escalate to BLOCKED if the stall persists

### Visualizing the Transition Graph

Export the audit log for external visualization:

```bash
# Export current audit_log as JSONL
lean-ctx ctx_shell 'node -e "console.log(JSON.stringify(require(\"./session/contract.json\").audit_log, null, 2))"'

# Feed into graphviz for a transition diagram (requires graphviz CLI)
# Each entry: prev_state -> new_state [label="triggered_by: reason"]
```

### Exporting the Audit Trail

For reporting or analysis:

```bash
# Full export
lean-ctx ctx_knowledge recall --key "orchestration-contract:<task_id>" --mode "exact" | jq '.audit_log'

# Filter by agent
lean-ctx ctx_knowledge recall --key "orchestration-contract:<task_id>" --mode "exact" | jq '.audit_log[] | select(.triggered_by == "orchestrator")'
```

---

## Score Analytics

### Average Score Per Phase

For each unique phase in the audit log, compute:

```
for each entry with scoring_snapshot:
    group by new_state
    average = sum(combined) / count
```

Formula: `avg(entry.scoring_snapshot.combined)` grouped by `entry.new_state`.

### Regression Detection (>30pt Drop)

Compare adjacent audit entries in the **same phase**:

```
for i = 1 to audit_log.length - 1:
    prev = audit_log[i - 1].scoring_snapshot?.combined
    curr = audit_log[i].scoring_snapshot?.combined
    if prev != null and curr != null and (prev - curr) > 30:
        emit("SCORE_REGRESSION", { from: prev, to: curr, drop: prev - curr, phase: audit_log[i].new_state })
        apply_deduction = 15  // per AUDIT_003
```

> Note: Only compare entries in the same phase (same `new_state`). A score change across different phases is expected.

### High-Failure Phases

Track which phases produce the most RETRY or BLOCKED verdicts:

```json
{
  "EXECUTE_SCORED": { "total": 5, "retry": 2, "blocked": 0, "failure_rate": 0.4 },
  "REVIEW_SCORED":  { "total": 3, "retry": 1, "blocked": 0, "failure_rate": 0.33 }
}
```

### Trend Reports

Produce trend data for orchestrator decision-making:

```bash
# Count transitions per state
lean-ctx ctx_knowledge recall --key "orchestration-contract:<task_id>" --mode "exact" | jq '[.audit_log[].new_state] | group_by(.) | map({state: .[0], count: length})'
```

### Score-Agent Correlations

Identify which agents produce the highest/lowest scores:

```
group by triggered_by:
    average score across all entries where scoring_snapshot exists
```

This helps identify if certain agents consistently underperform or if scoring calibration is needed.

---

## Cross-Service Consistency

When multiple repositories use the same orchestration toolkit, audit logs can be compared for consistency.

### What to Compare

| Field | Consistency Check |
|-------|------------------|
| `contract_version` | All repos should use the same version |
| State machine definitions | Same states and transitions across all contracts |
| Audit log schema | All entries follow the same field format |
| Scoring thresholds | Same pass/retry/escalation values |

### Drift Detection

To detect drift between repos:

```bash
# Load each repo's contract
REPO1_CONTRACT=$(cd /path/to/repo1 && lean-ctx ctx_knowledge recall --key "orchestration-contract:<task_id>" --mode "exact")
REPO2_CONTRACT=$(cd /path/to/repo2 && lean-ctx ctx_knowledge recall --key "orchestration-contract:<task_id>" --mode "exact")

# Compare versions
echo $REPO1_CONTRACT | jq '.contract_version'
echo $REPO2_CONTRACT | jq '.contract_version'

# Compare state machine rules
echo $REPO1_CONTRACT | jq '.validation'
echo $REPO2_CONTRACT | jq '.validation'
```

When drift is detected:
1. Flag the inconsistency
2. Determine which repo is the source of truth
3. Align the diverging repo

---

## Multi-Repo Readiness (Future-Ready)

This section defines patterns that will become active when multi-repo orchestration is enabled. Not yet enforced.

### Unique Session IDs

Each repo SHOULD generate a unique `session.task_id` using the format:

```
<repo-slug>-<YYYYMMDD>-<sequence>
```

Example: `workflow-state-engine-20260617-001`, `price-comparison-service-20260617-001`

### repo_id in Audit Log

Future audit entries SHOULD include a `repo_id` field:

```json
{
  "repo_id": "workflow-state-engine",
  "timestamp": "...",
  "prev_state": "...",
  "new_state": "...",
  "triggered_by": "...",
  "transition_reason": "..."
}
```

### Cross-Repo Sync via Knowledge Federation

When a transition occurs in one repo, the orchestrator MAY propagate the audit entry to other repos via:

```bash
# Push audit entry to federation
lean-ctx ctx_knowledge remember category architecture key federation-audit-<repo_id>-<timestamp> value <entry>
```

Federation consumers can then discover cross-repo audit trails:

```bash
lean-ctx ctx_knowledge recall --query "federation-audit" --mode "semantic"
```

---

## Multi-Agent Coordination (Future-Ready)

This section defines patterns that will become active when multi-agent parallel execution is enabled. Not yet enforced.

### Per-Agent Delegation Events

Each delegation to a subagent SHOULD produce an audit entry:

```json
{
  "timestamp": "...",
  "event_type": "delegation_start",
  "delegated_to": "developer",
  "task": "Implement StateService",
  "parallel_with": ["fixer"],
  "expected_duration_ms": 120000
}
```

### Handoff Timing

Track time between handoffs to identify bottlenecks:

```
for i = 1 to audit_log.length - 1:
    time_between = audit_log[i].timestamp - audit_log[i-1].timestamp
    emit("HANDOFF_DURATION", { from: audit_log[i-1].new_state, to: audit_log[i].new_state, duration_ms: time_between })
```

### Parallel vs Serial Tracking

Flag whether transitions occurred in serial or parallel:

- **Serial**: Each delegation completes before the next starts
- **Parallel**: Multiple agents active simultaneously (tracked via `parallel_with` field)

---

## Multi-Model Routing (Future-Ready)

This section defines patterns that will become active when multi-model execution is enabled. Not yet enforced.

### Per-Model Logging

Each scoring pass or LLM call SHOULD log the model used:

```json
{
  "model": "deepseek-flash",
  "fallback_chain": ["deepseek-flash", "glm-5.3-flash"],
  "attempt": 1,
  "latency_ms": 2340,
  "tokens_used": 15200
}
```

### Fallback Chain

Log every fallback attempt for observability:

```
attempt 1: deepseek-flash → rate limit
attempt 2: glm-5.3-flash → success (2340ms, 15200 tok)
```

### Latency/Token Tracking

Track per-model latency and token consumption:

| Model | Avg Latency | Avg Tokens | Success Rate |
|-------|------------|-----------|-------------|
| deepseek-flash | 1200ms | 8000 | 95% |
| glm-5.3-flash | 1800ms | 12000 | 97% |

---

## Edge Cases

### No audit_log (Initial State)

When the contract is first created, `audit_log` starts as an empty array `[]`. The first entry is appended on the INIT→PLAN transition with `prev_state: null`.

**Handler**: The orchestrator's post-transition hook checks if `audit_log` is empty and handles the sentinel first entry.

### Unbounded Growth

The 500-entry retention policy prevents unbounded growth. Archive logic runs after every append:

```javascript
if (contract.audit_log.length > 500) {
    const toArchive = contract.audit_log.slice(0, contract.audit_log.length - 500);
    // persist toArchived to lean-ctx
    contract.audit_log = contract.audit_log.slice(-500);
}
```

### Concurrent Writes

All contract modifications are **serialized through the orchestrator** (orchestrator). No two agents write to the contract simultaneously. This prevents audit_log ordering issues.

- During parallel execution, agents submit results to the orchestrator
- The orchestrator appends audit entries in a deterministic order
- No agent other than orchestrator modifies `audit_log` directly

### Null prev_state (INIT→PLAN)

The INIT→PLAN transition is the first state change. Since there is no previous state, `prev_state` is `null`:

```json
{
  "timestamp": "2026-06-17T10:00:00Z",
  "prev_state": null,
  "new_state": "PLAN",
  "triggered_by": "orchestrator",
  "transition_reason": "Session created - delegating to system-analyst",
  "scoring_snapshot": {}
}
```

This is the only case where `prev_state` is `null`. All subsequent transitions have a string value.

### Missing scoring_snapshot

Transitions that don't run the scoring pipeline (e.g., INIT→PLAN, EXECUTE→EXECUTE_SCORED) omit `scoring_snapshot` or set it to an empty object `{}`. Score analytics queries should filter for entries where `scoring_snapshot` is non-empty and contains `combined`.

```
query: audit_log.filter(e => e.scoring_snapshot?.combined != null)
```

### Archived Log Integrity

When audit entries are archived to lean-ctx, the archived chunk retains the exact schema. Reconstructing the full log:

```
archived_entries = recall("audit-log-archive-*")
current_entries = contract.audit_log
full_log = [...archived_entries.flat(), ...current_entries]
```

Each archive key includes a date prefix for chronological ordering.