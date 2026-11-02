<!-- omit from toc -->

# Part A — Fundamentals: State Machine & Contract Envelope

> See [doc/workflow/README.md](../workflow/README.md) for index.

This part covers the core orchestration mechanics: state machine transitions, contract envelope structure, and the mandatory read→activity→write protocol that governs every delegation cycle.

## A1. State Machine Diagram + Transitions

```
INIT → PLAN → PLAN_SCORED → EXECUTE → EXECUTE_SCORED → REVIEW → REVIEW_SCORED → COMPLETE
                                                                                       ↓
                                                                                  BLOCKED
```

### Transitions

| Transition | Gate | Description |
|---|---|---|
| INIT → PLAN | Task starts | Envelope created with state=INIT, delegate to system-analyst |
| PLAN → PLAN_SCORED | Scoring pipeline | Score ≥ 70 → PASS, 50-69 → RETRY, <50 → BLOCKED |
| EXECUTE → EXECUTE_SCORED | Scoring pipeline | Same scoring thresholds |
| EXECUTE_SCORED → REVIEW | Score ≥ 70 | Delegate to quality-analyst |
| REVIEW → REVIEW_SCORED | Scoring pipeline | Verdict: PASS/BLOCK/FLAG |
| REVIEW_SCORED → COMPLETE | Score ≥ 70 | All gates passed, ship ready |
| Any → BLOCKED | Score < 50 or attempt ≥ 3 | Escalated to user |

Source of truth: `rules/rules.json` §state_machine.transitions.


## A2. Contract Envelope Structure

The envelope is stored in lean-ctx knowledge as `orchestration-contract`. File: `contract/contract.template.json`. Full schema at `contract/contract.schema.json`.

```json
{
  "state": "PLAN_SCORED",
  "session": {
    "task_id": "task-slug",
    "session_id": "",
    "created_at": "2026-06-16T10:00:00Z"
  },
  "requirements": {
    "goal": "What we're building",
    "scope": {
      "included": ["files in scope"],
      "excluded": ["out of scope"],
      "parallel_eligible": false
    }
  },
  "decisions": {
    "architecture": "key decisions",
    "design": "design choices"
  },
  "governance": {
    "constraints": ["rules to follow"],
    "enforced_by": "agent-type"
  },
  "score": {
    "rules": { "pass": 5, "fail": 0, "deduction": 0, "subtotal": 100 },
    "judge": { "score": 85, "rationale": "...", "missing_items": [] },
    "combined": 85,
    "verdict": "PASS"
  },
  "retry": {
    "attempt": 0,
    "current_phase": "plan",
    "issues": []
  },
  "outputs": {
    "plan": "plan document path",
    "execute": "implementation summary",
    "review": "review findings"
  },
  "metrics": {
    "cost_tokens": 15000,
    "elapsed_ms": 450000,
    "agents_used": ["system-analyst"],
    "phases_completed": ["plan:2026-06-16T10:05:00Z"]
  },
  "lessons_learned": [
    "What went well",
    "What went wrong",
    "What to change next time"
  ]
}
```

## A3. Contract Read/Write Protocol

The contract is the single source of truth. Every delegation starts by reading the contract (lean-ctx ctx_knowledge recall). Every delegation ends by writing back (lean-ctx ctx_knowledge remember). This read→activity→write cycle is mandatory for every phase.

**Pre-flight enforcement**: Before any work begins, the delegating agent (orchestrator) loads the contract via `lean-ctx ctx_knowledge recall --key "orchestration-contract" --mode "exact"`. If found → extract decisions.*, governance.*, retry.issues[]. If not found → create fresh from contract.template.json. This ensures crash recovery and cross-session resumption.

| Phase | Reads from Contract | Activity | Writes to Contract | Delegated To |
|---|---|---|---|---|
| INIT→PLAN | requirements.*, governance.*, retry.issues[] | Refine requirements + system design & plan | state: PLAN, session.*, scope.* | product-manager → system-analyst |
| PLAN→PLAN_SCORED | outputs.plan, scope.* | Score plan (+ SDD spec) | state: PLAN_SCORED, score.*, decisions.* | orchestrator (+ software-architect) |
| EXECUTE→EXECUTE_SCORED | outputs.code_changes[], outputs.test_results | Score implementation | state: EXECUTE_SCORED, score.* | orchestrator |
| EXECUTE_SCORED→REVIEW | score.*, outputs.* | Code quality + security review | state: REVIEW | quality-analyst + security-engineer |
| REVIEW→REVIEW_SCORED | outputs.agent_reports[] | Score review findings | state: REVIEW_SCORED, score.*, outputs.score_summary | orchestrator |
| REVIEW_SCORED→COMPLETE | score.*, outputs.* | Ship, learn, persist (scrum-master DoD gate) | state: COMPLETE, lessons_learned[], metrics.* | learner |
| At BLOCKED | retry.issues[], retry.cur_phase | Escalate, arbitrate, persist | state: BLOCKED, retry.escalation_trace[], retry.attempt+1 | scrum-master |

---

[workflow-shield]: https://img.shields.io/badge/Workflow-Orchestration-blue?style=for-the-badge
