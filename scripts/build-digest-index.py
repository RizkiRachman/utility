#!/usr/bin/env python3
"""Build an agent-friendly digest from a repomix plain output.

Information architecture (daily self-learning on enforcement workflow):
  FOCUS buckets are minified and sharded; digest-full.txt holds the
  whole focus corpus in one file, budget-capped (default 1 MB) so a
  web agent can fetch everything in a single request.
  Everything else (agents optionally, skills, configs, vendored tools)
  is HIDDEN from shards but still fetchable: raw per-file copy under
  files/ + manifest map.

Outputs into --out:
  digest-full.txt   entire focus corpus, minified, <= --budget bytes
  shards/<b>[-N|-pN].md  focus shards, each <= --cap bytes
  files/<source-path>    raw per-file copies
  llms.txt, manifest.json, index.html

Exit 2: multi-file shard over cap. Exit 3: digest-full over budget.
"""
import argparse, json, os, re, shutil, sys, time

FHDR = re.compile(r"^=+\nFile: (.+?)\n=+\n", re.M)
VALID_REL = re.compile(r"^[\w][\w./+-]*$")
DESC_RE = re.compile(r"^description:\s*(.+?)(?:\n[a-z-]+:|\n---)",
                     re.M | re.S)

# Focus = daily-learning corpus on the enforcement workflow + rules.
FOCUS = [
    ("workflow-core", ("engine/agent.md", "engine/rules/", "engine/contract/",
                       "engine/doc/workflow")),
    ("enforcement-scripts", ("engine/scripts/",)),
    ("engine-docs", ("engine/doc/",)),
]

NL = chr(10)


def bucket_of(rel):
    for name, prefixes in FOCUS:
        for p in prefixes:
            if rel.startswith(p):
                return name
    return None  # hidden: per-file fetch only


def parse(text):
    """Split repomix plain output into (rel_path, body) pairs.

    Blocks whose path fails the path-name check are treated as content
    of the previous file (guards against the File: marker appearing
    inside file content).
    """
    ms = list(FHDR.finditer(text))
    out = []
    for i, m in enumerate(ms):
        rel = m.group(1).strip()
        end = ms[i + 1].start() if i + 1 < len(ms) else len(text)
        body = text[m.end():end].rstrip("\n") + "\n"
        if VALID_REL.match(rel) and ".." not in rel.split("/"):
            out.append([rel, body])
        elif out:
            out[-1][1] += text[m.start():end]
    return [(r, b) for r, b in out if b.strip()]


def minify(rel, body):
    """Compact: JSON without whitespace; strip comments/blank lines in
    code+yaml; collapse blank runs and decorative rules in markdown.
    Raw content always stays at files/<path>."""
    ext = rel.rsplit(".", 1)[-1].lower() if "." in rel else ""
    if ext == "json":
        try:
            return json.dumps(json.loads(body), separators=(",", ":"),
                              ensure_ascii=False) + NL
        except Exception:
            return body
    if ext in ("sh", "bash", "py", "js", "ts", "yaml", "yml"):
        out = []
        for ln in body.splitlines():
            s = ln.strip()
            if not s:
                continue
            if ext in ("yaml", "yml") and s.startswith("#"):
                continue
            if ext in ("sh", "bash", "py") and s.startswith("#"):
                if not s.startswith("#!"):
                    continue
            if ext in ("js", "ts") and (s.startswith("//")
                                        or s.startswith("/*")
                                        or s.startswith("*")):
                continue
            out.append(ln.rstrip())
        return NL.join(out) + NL
    if ext == "md":
        res, fm = [], body.splitlines()[:1] == ["---"]
        for i, ln in enumerate(body.splitlines()):
            t = ln.strip()
            if t == "---" and not (fm and i < 12):
                continue  # decorative rule; frontmatter zone kept
            if t.startswith("<!--") and t.endswith("-->"):
                continue
            if not t:
                if res and not res[-1].strip():
                    continue  # collapse blank runs
                res.append("")
                continue
            res.append(ln.rstrip())
        return NL.join(res) + NL
    return body


def split_items(items, cap):
    """Greedy fill at file boundaries; sorted for stable shards."""
    parts, cur, size = [], [], 0
    for it in sorted(items):
        n = len(it[1]) + len(it[0]) + 48
        if cur and size + n > cap:
            parts.append(cur)
            cur, size = [], 0
        cur.append(it)
        size += n
    if cur:
        parts.append(cur)
    return parts


def chunk_text(txt, cap):
    """Split text at line boundaries into chunks each <= cap bytes."""
    lines = txt.splitlines(keepends=True)
    chunks, cur, size = [], [], 0
    for ln in lines:
        if cur and size + len(ln) > cap:
            chunks.append("".join(cur))
            cur, size = [], 0
        cur.append(ln)
        size += len(ln)
    if cur:
        chunks.append("".join(cur))
    return chunks


def safe(root, *rel):
    p = os.path.abspath(os.path.join(root, *rel))
    if not p.startswith(os.path.abspath(root) + os.sep):
        raise ValueError("unsafe path: %r" % (rel,))
    return p


def w(root, rel, data):
    p = safe(root, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8") as fh:
        fh.write(data)


def skill_desc(body, limit=110):
    m = DESC_RE.search(body[:4000])
    if not m:
        return ""
    d = " ".join(m.group(1).split())
    return d if len(d) <= limit else d[:limit - 1] + "..."


def emit_shard(out, args, name, blocks, paths, shards):
    """Write one shard; line-split parts (-pN) if oversize."""
    data = ("# %s\nscope: %s\nfiles: %d\n\n" %
            (name, args.scope, len(paths))) + "\n".join(blocks)
    if len(data) <= args.cap:
        relp = "shards/%s.md" % name
        w(out, relp, data)
        shards.append({"name": name, "file": relp, "bytes": len(data),
                       "file_count": len(paths), "paths": paths})
        return
    chunks = chunk_text("\n".join(blocks), args.cap)
    tot = len(chunks)
    for j, ch in enumerate(chunks, 1):
        nm = "%s-p%d" % (name, j)
        head = "# %s (part %d/%d)\nscope: %s\n\n" % (nm, j, tot, args.scope)
        relp = "shards/%s.md" % nm
        w(out, relp, head + ch)
        shards.append({"name": nm, "file": relp,
                       "bytes": len(head) + len(ch),
                       "file_count": len(paths), "paths": paths,
                       "split_of": name})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True, help="repomix plain output")
    ap.add_argument("--out", required=True, help="output dir (e.g. public)")
    ap.add_argument("--cap", type=int, default=90 * 1024)
    ap.add_argument("--budget", type=int, default=1024 * 1024,
                    help="max digest-full.txt bytes (default 1 MB)")
    ap.add_argument("--max-file", type=int, default=256 * 1024)
    ap.add_argument("--scope", default="workspace/agents/opencode")
    args = ap.parse_args()

    text = open(args.input, encoding="utf-8", errors="replace").read()
    files = parse(text)
    if not files:
        print("ERROR: no File: blocks parsed", file=sys.stderr)
        return 2
    pre = args.scope.strip("/") + "/"
    files = [(r[len(pre):] if r.startswith(pre) else r, b)
             for r, b in files]

    bulky = {r: len(b) for r, b in files if len(b) > args.max_file}
    core = [(r, b) for r, b in files if len(b) <= args.max_file]

    out = args.out
    for sub in ("shards", "files"):
        shutil.rmtree(os.path.join(out, sub), ignore_errors=True)
        os.makedirs(os.path.join(out, sub), exist_ok=True)

    groups, sdesc, hidden_n, focus_items = {}, {}, 0, []
    for rel, body in core:
        b = bucket_of(rel)
        if b is None:
            hidden_n += 1
            if rel.startswith("engine/skills/") and rel.endswith("SKILL.md"):
                parts = rel.split("/")
                if len(parts) > 2:
                    sdesc.setdefault(parts[2], skill_desc(body))
            continue
        mini = minify(rel, body)
        focus_items.append((rel, mini))
        groups.setdefault(b, []).append((rel, mini))

    shards = []
    for grp in sorted(groups):
        for i, part in enumerate(split_items(groups[grp], args.cap), 1):
            nparts = len(split_items(groups[grp], args.cap))
            name = grp if nparts == 1 else "%s-%02d" % (grp, i)
            blocks, paths = [], []
            for rel, body in part:
                blocks.append("================\nFile: %s\n================"
                              "\n%s" % (rel, body))
                paths.append(rel)
            emit_shard(out, args, name, blocks, paths, shards)

    # digest-full.txt: whole focus corpus, one file, budget-capped
    full = ["# utility digest - focus corpus (enforcement workflow + rules)",
            "# minified; paths as emitted; ~4 chars per token", ""]
    for rel, body in sorted(focus_items):
        full.append("================\nFile: %s\n================" % rel)
        full.append(body.rstrip("\n"))
    full_data = NL.join(full) + NL
    w(out, "digest-full.txt", full_data)
    if len(full_data) > args.budget:
        print("ERROR: digest-full.txt %d bytes > budget %d - shrink focus "
              "scope or raise --budget" % (len(full_data), args.budget),
              file=sys.stderr)
        return 3

    fmeta = {}
    for rel, body in sorted(files):
        w(out, "files/" + rel, body)
        fmeta[rel] = len(body)

    focus_kb = sum(s["bytes"] for s in shards) // 1024
    manifest = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "scope": args.scope, "cap_bytes": args.cap,
        "budget_bytes": args.budget, "max_file_bytes": args.max_file,
        "source_files": len(fmeta), "hidden_files": hidden_n,
        "total_source_bytes": sum(fmeta.values()),
        "focus_bytes": sum(s["bytes"] for s in shards),
        "digest_full_bytes": len(full_data),
        "shards": shards, "files": fmeta,
        "bulky": [{"path": r, "bytes": n, "url": "files/" + r}
                  for r, n in sorted(bulky.items())],
        "agents": {"policy": "optional",
                   "url": "files/engine/agents/<name>.md"},
        "skills": [{"name": k, "desc": v,
                    "url": "files/engine/skills/%s/SKILL.md" % k}
                   for k, v in sorted(sdesc.items())],
    }
    w(out, "manifest.json", json.dumps(manifest, indent=1) + "\n")

    L = ["# Utility repo - agents/opencode digest",
         "focus: enforcement workflow + rules", "",
         "> %d source files (%d KB). Focus corpus (minified) = %d KB: "
         "fetch digest-full.txt (%d KB, budget %d KB) for everything at "
         "once, or single shards below (<= ~%d KB each). Agents optional; "
         "skills hidden; all raw files at /files/<path>."
         % (len(fmeta), sum(fmeta.values()) // 1024, focus_kb,
            len(full_data) // 1024, args.budget // 1024, args.cap // 1024),
         "", "## One fetch - whole focus corpus",
         "- [digest-full.txt](digest-full.txt) (%d KB, minified)"
         % (len(full_data) // 1024),
         "", "## Focus shards (incremental)"]
    for s in shards:
        d = "%d files: %s" % (s["file_count"], s["paths"][0])
        if s["file_count"] > 1:
            d += " .. " + s["paths"][-1]
        L.append("- [%s](%s) (%d KB): %s" % (s["name"], s["file"],
                                             s["bytes"] // 1024, d))
    L += ["", "## Suggested daily path",
          "1. workflow-core (state machine, scoring, contract schema)",
          "2. enforcement-scripts (guard/gate/validate scripts)",
          "3. engine-docs (workflow guides, thresholds)",
          "", "## Hidden (per-file fetch only)",
          "- Agent contracts (optional): /files/engine/agents/<name>.md",
          "- Skills: %d (catalog in manifest 'skills'; raw at "
          "/files/engine/skills/<name>/SKILL.md)" % len(sdesc),
          "- Other hidden files: %d (manifest 'files' map)" % hidden_n,
          "- Bulky (>%d KB): %d - fetch at files/<path>"
          % (args.max_file // 1024, len(bulky)),
          "- Complete corpus incl. hidden: repomix-output.txt (%d KB)"
          % (len(text) // 1024),
          "", "## Conventions",
          "- Focus content is minified (comments/blanks stripped, JSON "
          "compacted); raw per-file at /files/<path>.",
          "- manifest.json 'files' maps any path to raw size; shard "
          "membership for focus files is derivable from shard 'paths'.",
          "- Byte sizes exact; assume ~4 chars per token."]
    w(out, "llms.txt", "\n".join(L) + "\n")

    rows = "".join(
        "<tr><td><a href='%s'>%s</a></td><td>%d KB</td><td>%d</td>"
        "<td>%s</td></tr>"
        % (s["file"], s["name"], s["bytes"] // 1024, s["file_count"],
           s["paths"][0] + (" ..." if s["file_count"] > 1 else ""))
        for s in shards)
    html = ("<!doctype html><meta charset='utf-8'>"
            "<title>utility digest - enforcement focus</title>"
            "<h1>Utility digest (focus: enforcement workflow + rules)</h1>"
            "<p>AI agents: <a href='llms.txt'>llms.txt</a> first. One "
            "fetch: <a href='digest-full.txt'>digest-full.txt</a> "
            "(%d KB). Index: <a href='manifest.json'>manifest.json</a>. "
            "Per-file: /files/&lt;path&gt;.</p>" % (len(full_data) // 1024)
            + "<table border=1><tr><th>shard</th><th>size</th>"
              "<th>files</th><th>contents</th></tr>" + rows + "</table>"
            "<p><a href='repomix-output.txt'>complete corpus incl. "
            "hidden</a> (large-context agents only)</p>")
    w(out, "index.html", html)

    oversize = [(s["name"], s["bytes"]) for s in shards
                if s["bytes"] > args.cap and s["file_count"] > 1]
    print("files=%d hidden=%d shards=%d focus_kb=%d full_kb=%d budget=%d "
          "cap=%d bulky=%d oversize=%s"
          % (len(fmeta), hidden_n, len(shards), focus_kb,
             len(full_data) // 1024, args.budget // 1024, args.cap,
             len(bulky), oversize))
    return 2 if oversize else 0


if __name__ == "__main__":
    sys.exit(main())
