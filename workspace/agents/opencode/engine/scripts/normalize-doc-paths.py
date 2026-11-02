#!/usr/bin/env python3
"""Rewrite relative engine references in shipped docs to absolute paths.

The engine is deployed to /opt/engine and its entry points are symlinked into
~/.config/opencode, so docs that talk about sibling directories must point at
the deployed tree rather than at a path relative to the reader.

Only references that resolve to a real file are rewritten:

  * resolved relative to the document (skill-local scripts stay skill-local)
  * otherwise resolved relative to the engine root (shared scripts)

Anything else — including plain directory names in ASCII trees — is left
untouched, so the pass cannot invent paths that do not exist.

Usage: normalize-doc-paths.py [ENGINE_ROOT] [DEPLOY_ROOT]
"""

from __future__ import annotations

import os
import re
import sys

DEPLOY_ROOT = "/opt/engine"
DIRS = r"(?:scripts|contract|rules|agents|usage|skills|doc|templates)"
TOKEN_RE = re.compile(
    r"(?P<prefix>`|\]\(|(?<=\s))"
    r"(?P<path>(?:\.\./)*\.?/?" + DIRS + r"/[A-Za-z0-9._/-]*)"
)
TRAILING_RE = re.compile(r"[._/-]+$")


def candidate_paths(doc_dir: str, engine_root: str, ref: str) -> list[str]:
    """Paths the reference may denote, document-relative first."""
    out = [os.path.normpath(os.path.join(doc_dir, ref))]
    out.append(os.path.normpath(os.path.join(engine_root, ref)))
    return out


def rewrite_document(path: str, engine_root: str, deploy_root: str) -> bool:
    with open(path, "r", encoding="utf-8", newline="") as handle:
        original = handle.read()

    doc_dir = os.path.dirname(path)
    cache: dict[str, str | None] = {}

    def resolve(ref: str) -> str | None:
        if ref in cache:
            return cache[ref]
        target = None
        for candidate in candidate_paths(doc_dir, engine_root, ref):
            if not candidate.startswith(engine_root + os.sep):
                continue
            if os.path.isfile(candidate):
                target = os.path.relpath(candidate, engine_root)
                break
        replacement = None
        if target is not None:
            replacement = os.path.join(deploy_root, target)
        cache[ref] = replacement
        return replacement

    def substitute(match: re.Match[str]) -> str:
        ref = match.group("path")
        stem = TRAILING_RE.sub("", ref)
        replacement = resolve(stem)
        if replacement is None:
            return match.group(0)
        return match.group("prefix") + replacement + ref[len(stem):]

    updated = TOKEN_RE.sub(substitute, original)
    if updated == original:
        return False

    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(updated)
    return True


def iter_docs(engine_root: str):
    skip = {os.path.join(engine_root, "plugins"), os.path.join(engine_root, "node_modules")}
    for base, dirs, files in os.walk(engine_root):
        dirs[:] = [d for d in dirs if os.path.join(base, d) not in skip and d != "node_modules"]
        for name in files:
            if name.endswith(".md"):
                yield os.path.join(base, name)


def main(argv: list[str]) -> int:
    engine_root = os.path.abspath(argv[1] if len(argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    deploy_root = argv[2] if len(argv) > 2 else DEPLOY_ROOT
    changed = 0
    for doc in iter_docs(engine_root):
        if rewrite_document(doc, engine_root, deploy_root):
            changed += 1
    print(f"normalize-doc-paths: {changed} file(s) updated under {engine_root}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
