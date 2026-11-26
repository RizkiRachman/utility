#!/usr/bin/env python3
"""apply-patch.py — safe, atomic exact-text edits from a JSON spec.

Replaces printf/sed patch chains (paren escapes, backrefs, >> vs >, 8KB
splits, trailing commas). The spec is a JSON file, so no shell interpolation
ever touches the replacement text. All files are validated before any write;
writes are atomic (temp + rename) and preserve mode and EOF-newline state.

Usage:
  python3 apply-patch.py spec.json [--dry-run] [--diff]

Spec format:
[
  {
    "file": "workspace/agents/opencode/engine/agent.md",
    "ops": [
      {"type": "replace", "find": "old text", "with": "new text", "count": 1},
      {"type": "insert_before", "anchor": "## Heading", "text": "line\\n"},
      {"type": "insert_after", "anchor": "## Heading", "text": "line\\n"},
      {"type": "append", "text": "line\\n"}
    ]
  }
]
Exit: 0 applied, 1 validation failure (nothing written), 2 bad spec.
"""
import argparse, difflib, json, os, stat, sys, tempfile

def fail(msg):
    print("apply-patch: " + msg, file=sys.stderr)
    raise SystemExit(1)

def apply_ops(text, ops, label):
    work = text
    for i, op in enumerate(ops, 1):
        t = op.get("type")
        if t == "replace":
            find, repl = op.get("find"), op.get("with")
            if find is None or repl is None:
                fail(f"{label} op {i}: replace needs find + with")
            n = work.count(find)
            want = op.get("count", 1)
            if n != want:
                fail(f"{label} op {i}: find matched {n}x, expected {want}: {find[:70]!r}")
            work = work.replace(find, repl, want if want > 0 else -1)
        elif t in ("insert_before", "insert_after"):
            anchor, ins = op.get("anchor"), op.get("text", "")
            if anchor is None:
                fail(f"{label} op {i}: {t} needs anchor")
            n = work.count(anchor)
            if n != 1:
                fail(f"{label} op {i}: anchor matched {n}x, expected 1: {anchor[:70]!r}")
            pos = work.index(anchor)
            work = work[:pos] + ins + work[pos:] if t == "insert_before" else work[:pos + len(anchor)] + ins + work[pos + len(anchor):]
        elif t == "append":
            work += op.get("text", "")
        else:
            fail(f"{label} op {i}: unknown type {t!r}")
    eof_nl = text.endswith("\n")
    if eof_nl and not work.endswith("\n"):
        work += "\n"
    if not eof_nl and work.endswith("\n"):
        work = work[:-1]
    return work

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("spec")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--diff", action="store_true")
    args = ap.parse_args()
    try:
        spec = json.load(open(args.spec, encoding="utf-8"))
    except Exception as e:
        print(f"apply-patch: bad spec: {e}", file=sys.stderr)
        raise SystemExit(2)
    if not isinstance(spec, list):
        print("apply-patch: spec must be a JSON array", file=sys.stderr)
        raise SystemExit(2)

    prepared = []
    for entry in spec:
        path = entry.get("file")
        ops = entry.get("ops", [])
        if not path or not os.path.isfile(path):
            fail(f"file not found: {path}")
        original = open(path, encoding="utf-8").read()
        try:
            updated = apply_ops(original, ops, path)
        except SystemExit:
            raise
        prepared.append((path, original, updated))

    for path, original, updated in prepared:
        if original == updated:
            print(f"unchanged: {path}")
            continue
        if args.diff:
            sys.stdout.writelines(difflib.unified_diff(
                original.splitlines(True), updated.splitlines(True),
                fromfile=path + " (before)", tofile=path + " (after)"))
        if not args.dry_run:
            d = os.path.dirname(os.path.abspath(path))
            mode = stat.S_IMODE(os.stat(path).st_mode)
            fd, tmp = tempfile.mkstemp(dir=d, prefix=".apply-patch-")
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(updated)
            os.chmod(tmp, mode)
            os.replace(tmp, path)
        print(f"{'would patch' if args.dry_run else 'patched'}: {path}")

if __name__ == "__main__":
    main()
