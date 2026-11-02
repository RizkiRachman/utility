# Service Type Rules Thresholds

## Threshold Matrix

|---|---|---|---|---|---|
| **Core** | service, api | high | 75 | 3 | always |
| **UI** | dashboard | medium | 70 | 5 | >3 files |
| **Support** | automation, agent-helper, claude-service, properties | low | 65 | 8 | never |
| **Infrastructure** | deployer | high | 80 | 2 | always |

## Gate Definitions

- **high** — no unsolicited abstractions, no unvalidated input, strict YAGNI enforcement
- **medium** — UI components can tolerate some flexibility, but no production shortcuts
- **low** — simple scripts, minimal risk of abstraction bloat

### Score Threshold
Minimum `score.combined` from the three-tier scoring pipeline (Tier 1 rule checks + Tier 2 LLM-as-judge) to pass a phase gate. Lower threshold for support services reflects their simpler codebase and lower risk profile.

### Max Debt Items

### SDD Gate
Spec-Driven Development gate (GWT-format specs) required before implementation:
- **always** — spec review before every implementation task
- **>3 files** — only when the change touches more than 3 files
- **never** — support tasks are small enough that specs add overhead
