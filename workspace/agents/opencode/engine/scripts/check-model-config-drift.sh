#!/usr/bin/env bash
# check-model-config-drift.sh — enforce the canonical model-config node (models.json).
# Verifies every declared mirror carries only canonical model IDs, that rules.json
# and opencode.json agree with the canonical node, and that the allowlist template
# still contains its required entries. Exit 1 on any drift.
set -uo pipefail

ENGINE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ENGINE_ROOT/../../../.." && pwd)"
CANON="$ENGINE_ROOT/models.json"
FAIL=0

fail() { echo "[DRIFT] $1"; FAIL=$((FAIL + 1)); }
pass() { echo "[OK]    $1"; }

[ -f "$CANON" ] || { echo "[DRIFT] canonical node missing: $CANON"; exit 1; }

python3 - "$CANON" "$REPO_ROOT" <<'PY' || FAIL=$((FAIL + 1))
import json, os, re, sys

canon_path, repo_root = sys.argv[1], sys.argv[2]
with open(canon_path, encoding="utf-8") as f:
    cfg = json.load(f)

models = cfg["models"]
allowed = set(cfg["allowed_ids"])
providers = {m.split("/", 1)[0] for m in allowed}
mirrors = cfg["mirrors"]

def read(path):
    p = os.path.join(repo_root, path)
    if not os.path.isfile(p):
        return None
    with open(p, encoding="utf-8", errors="replace") as fh:
        return fh.read()

# 1. Scan every mirror for provider/model tokens that are not canonical.
# Strip URL schemes first so https:// paths do not register as model IDs.
token_re = re.compile(r"(?<![A-Za-z0-9_.\-@])([a-z][a-z0-9_.-]*)/([a-z][a-z0-9_.-]*)(?![A-Za-z0-9_.-])")
for path in mirrors:
    text = read(path)
    if text is None:
        print(f"[DRIFT] mirror missing: {path}")
        sys.exit(1)
    clean = re.sub(r"https?://", " ", text)
    seen = set()
    ctx_kw = ('"model"', "model_tiers", "require_reviewer_model",
              "degraded_reviewer_model", "deepseek", "glm", "hy4",
              "reviewer", "judge", "MODEL", "model =")
    for line in clean.splitlines():
        if not any(k in line for k in ctx_kw):
            continue
        for prov, name in token_re.findall(line):
            full = f"{prov}/{name}"
            if prov not in providers:
                continue  # unrelated slash tokens on a model line
            seen.add(full)
            if full not in allowed:
                print(f"[DRIFT] {path}: non-canonical model id '{full}'")
                sys.exit(1)
    if seen:
        print(f"[OK]    {path}: {len(seen)} canonical id(s)")

# 2. rules.json must mirror the canonical node exactly.
rules = read("workspace/agents/opencode/engine/rules/rules.json")
r = json.loads(rules)
cmr = r["enforcement"]["cross_model_review"] if "enforcement" in r else r["cross_model_review"]
tiers = cmr["model_tiers"]
for key in ("light", "executor", "default", "fallback"):
    got = tiers[key][0]
    if got != models[key]:
        print(f"[DRIFT] rules.json model_tiers.{key} = {got}, expected {models[key]}")
        sys.exit(1)
if tiers["reviewer"][0] != models["reviewer"]:
    print("[DRIFT] rules.json reviewer tier mismatch")
    sys.exit(1)
if cmr["phase_assignment"] and cmr.get("degraded_mode", {}).get("require_reviewer_model") != models["reviewer"]:
    print("[DRIFT] rules.json require_reviewer_model mismatch")
    sys.exit(1)
print("[OK]    rules.json model tiers match canonical node")

# 3. opencode.json distinct model values must be exactly the canonical set.
oc = json.loads(read("workspace/agents/opencode/config/opencode.json"))
oc_models = set()
def walk(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k == "model" and isinstance(v, str):
                oc_models.add(v)
            else:
                walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
walk(oc)
if oc_models != allowed:
    print(f"[DRIFT] opencode.json model set {sorted(oc_models)} != canonical {sorted(allowed)}")
    sys.exit(1)
print("[OK]    opencode.json model set matches canonical node")

# 4. Allowlist template must retain its required entries.
al = read(cfg["allowlist_canonical"])
for entry in cfg["allowlist_required_entries"]:
    if f'"{entry}"' not in al:
        print(f"[DRIFT] allowlist template missing required entry: {entry}")
        sys.exit(1)
print("[OK]    allowlist template retains required entries")
PY

if [ "$FAIL" -eq 0 ]; then
    echo "Model-config drift check: PASS"
    exit 0
fi
echo "Model-config drift check: FAIL ($FAIL)"
exit 1
