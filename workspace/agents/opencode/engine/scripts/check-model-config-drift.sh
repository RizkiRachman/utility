#!/usr/bin/env bash
# check-model-config-drift.sh — enforce the canonical model-config node (models.json).
# Works in two layouts: the source repo (workspace/agents/opencode/engine/...) and
# the deployed engine (/opt/engine). Mirrors not shipped to a given layout are
# skipped with a [SKIP] note; present mirrors are validated. Exit 1 on real drift.
set -uo pipefail

ENGINE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANON="$ENGINE_ROOT/models.json"
FAIL=0

fail() { echo "[DRIFT] $1"; FAIL=$((FAIL + 1)); }
pass() { echo "[OK]    $1"; }

[ -f "$CANON" ] || { echo "[DRIFT] canonical node missing: $CANON"; exit 1; }

python3 - "$CANON" "$ENGINE_ROOT" <<'PY' || FAIL=$((FAIL + 1))
import json, os, re, sys

canon_path, engine_root = sys.argv[1], sys.argv[2]
with open(canon_path, encoding="utf-8") as f:
    cfg = json.load(f)

models = cfg["models"]
allowed = set(cfg["allowed_ids"])
providers = {m.split("/", 1)[0] for m in allowed}

# Detect source-repo layout by walking up for the engine directory.
repo_root = None
d = engine_root
for _ in range(6):
    if os.path.isfile(os.path.join(d, "workspace/agents/opencode/engine/models.json")):
        repo_root = d
        break
    d = os.path.dirname(d)

def resolve(path):
    cands = []
    if repo_root:
        cands.append(os.path.join(repo_root, path))
    if path.startswith("workspace/agents/opencode/engine/"):
        cands.append(os.path.join(engine_root, path.split("/", 4)[-1]))
    elif path.startswith("workspace/agents/opencode/config/"):
        cands.append(os.path.join("/home/node/.config/opencode", os.path.basename(path)))
        cands.append(os.path.join(engine_root, "config", os.path.basename(path)))
    elif path.startswith("workspace/agents/openui/") or path in ("README.md", "docker-compose.example.yaml"):
        cands.append(None)  # not shipped to the engine runtime
    else:
        cands.append(os.path.join(engine_root, os.path.basename(path)))
    for c in cands:
        if c and os.path.isfile(c):
            return c
    return None

def read(path):
    p = resolve(path)
    if p is None:
        return None
    with open(p, encoding="utf-8", errors="replace") as fh:
        return fh.read()

token_re = re.compile(r"(?<![A-Za-z0-9_.\-@])([a-z][a-z0-9_.-]*)/([a-z][a-z0-9_.-]*)(?![A-Za-z0-9_.-])")
ctx_kw = ('"model"', "model_tiers", "require_reviewer_model",
          "degraded_reviewer_model", "glm", "hy4",
          "reviewer", "judge", "MODEL", "model =")

for path in cfg["mirrors"]:
    text = read(path)
    if text is None:
        print(f"[SKIP] mirror not present in this layout: {path}")
        continue
    clean = re.sub(r"https?://", " ", text)
    seen = set()
    for line in clean.splitlines():
        if not any(k in line for k in ctx_kw):
            continue
        for prov, name in token_re.findall(line):
            full = f"{prov}/{name}"
            if prov not in providers:
                continue
            seen.add(full)
            if full not in allowed:
                print(f"[DRIFT] {path}: non-canonical model id '{full}'")
                sys.exit(1)
    if seen:
        print(f"[OK]    {path}: {len(seen)} canonical id(s)")

rules = read("workspace/agents/opencode/engine/rules/rules.json")
if rules:
    r = json.loads(rules)
    cmr = r.get("cross_model_review") or r["enforcement"]["cross_model_review"]
    tiers = cmr["model_tiers"]
    for key in ("light", "executor", "default", "fallback"):
        if tiers[key][0] != models[key]:
            print(f"[DRIFT] rules.json model_tiers.{key} mismatch")
            sys.exit(1)
    if tiers["reviewer"][0] != models["reviewer"]:
        print("[DRIFT] rules.json reviewer tier mismatch")
        sys.exit(1)
    if cmr.get("degraded_mode", {}).get("require_reviewer_model") != models["reviewer"]:
        print("[DRIFT] rules.json require_reviewer_model mismatch")
        sys.exit(1)
    print("[OK]    rules.json model tiers match canonical node")
else:
    print("[SKIP] rules.json not present in this layout")

oc = read("workspace/agents/opencode/config/opencode.json")
if oc:
    oc_models = set()
    def walk(o):
        if isinstance(o, dict):
            for k, v in o.items():
                if k == "model" and isinstance(v, str): oc_models.add(v)
                else: walk(v)
        elif isinstance(o, list):
            for v in o: walk(v)
    walk(json.loads(oc))
    if oc_models != allowed:
        print(f"[DRIFT] opencode.json model set {sorted(oc_models)} != canonical")
        sys.exit(1)
    print("[OK]    opencode.json model set matches canonical node")
else:
    print("[SKIP] opencode.json not present in this layout")

al = read(cfg["allowlist_canonical"])
if al:
    for entry in cfg["allowlist_required_entries"]:
        if f'"{entry}"' not in al:
            print(f"[DRIFT] allowlist missing required entry: {entry}")
            sys.exit(1)
    print("[OK]    allowlist template retains required entries")
else:
    print("[SKIP] allowlist template not present in this layout")
PY

if [ "$FAIL" -eq 0 ]; then
    echo "Model-config drift check: PASS"
    exit 0
fi
echo "Model-config drift check: FAIL ($FAIL)"
exit 1
