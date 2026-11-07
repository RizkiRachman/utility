#!/usr/bin/env python3
"""Generate engine documentation diagrams as standalone SVG files.

Diagrams are code: this script is the single source of truth and the SVG
files under doc/diagrams/ are build artifacts. Regenerate from engine/ with:

    python3 scripts/generate_diagrams.py

Outputs are deterministic (no timestamps, stable layout).
"""
import xml.etree.ElementTree as ET
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "doc" / "diagrams"
FONT = "Arial, Helvetica, sans-serif"
INK = "#1f2328"; MUTED = "#57606a"; LINE = "#6e7781"
BLUE = "#0969DA"; BLUE_BG = "#dbeafe"
GREEN = "#1a7f37"; GREEN_BG = "#d8f5e0"
RED = "#cf222e"; RED_BG = "#ffebe9"
AMBER = "#9a6700"; AMBER_BG = "#fff3c4"
GRAY_BG = "#f6f8fa"; GRAY_STROKE = "#d0d7de"

def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

class Svg:
    def __init__(self, w, h, title):
        self.p = []
        self.p.append("<?xml version='1.0' encoding='UTF-8'?>")
        self.p.append("<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d' viewBox='0 0 %d %d' role='img' font-family='%s'>" % (w, h, w, h, FONT))
        self.p.append("<title>%s</title>" % esc(title))
        self.p.append("<rect width='%d' height='%d' fill='#ffffff'/>" % (w, h))
        self.p.append("<defs><marker id='arr' viewBox='0 0 10 10' refX='9' refY='5' markerWidth='7.5' markerHeight='7.5' orient='auto-start-reverse'><path d='M0,0L10,5L0,10z' fill='%s'/></marker><marker id='arrB' viewBox='0 0 10 10' refX='9' refY='5' markerWidth='7.5' markerHeight='7.5' orient='auto-start-reverse'><path d='M0,0L10,5L0,10z' fill='%s'/></marker></defs>" % (LINE, BLUE))
    def text(self, x, y, s, size=15, weight="normal", color=INK, anchor="middle"):
        self.p.append("<text x='%s' y='%s' font-size='%s' font-weight='%s' fill='%s' text-anchor='%s'>%s</text>" % (x, y, size, weight, color, anchor, esc(s)))
    def box(self, x, y, w, h, fill, stroke, rx=10):
        self.p.append("<rect x='%s' y='%s' width='%s' height='%s' rx='%s' fill='%s' stroke='%s' stroke-width='1.6'/>" % (x, y, w, h, rx, fill, stroke))
    def line(self, x1, y1, x2, y2, color=LINE, width=1.4):
        self.p.append("<line x1='%s' y1='%s' x2='%s' y2='%s' stroke='%s' stroke-width='%s'/>" % (x1, y1, x2, y2, color, width))
    def arrow(self, x1, y1, x2, y2, color=LINE, dash="", marker="arr"):
        d = " stroke-dasharray='%s'" % dash if dash else ""
        self.p.append("<line x1='%s' y1='%s' x2='%s' y2='%s' stroke='%s' stroke-width='2'%s marker-end='url(#%s)'/>" % (x1, y1, x2, y2, color, d, marker))
    def polyarrow(self, pts, color=BLUE):
        self.p.append("<polyline points='%s' fill='none' stroke='%s' stroke-width='2' stroke-dasharray='6,5' marker-end='url(#arrB)'/>" % (pts, color))
    def edge_label(self, mx, my, s, size=13):
        w = int(len(s) * 7.1) + 14
        self.p.append("<rect x='%s' y='%s' width='%d' height='22' rx='4' fill='#ffffff' stroke='#eaeef2'/>" % (mx - w / 2, my - 11, w))
        self.text(mx, my + 5, s, size, "normal", MUTED)
    def save(self, name, title):
        self.p.append("</svg>")
        data = chr(10).join(self.p) + chr(10)
        OUT.mkdir(parents=True, exist_ok=True)
        f = OUT / name
        f.write_text(data, encoding="utf-8")
        ET.fromstring(data)
        print("wrote %s (%d bytes, xml OK)" % (f, len(data)))

pic = Svg(1640, 660, "Workflow State Engine state machine")
pic.text(46, 50, "Workflow State Engine - scoring-gated state machine", 24, "bold", INK, "start")
pic.text(46, 78, "Every delegation is scored; a combined score below the threshold escalates to BLOCKED.", 15, "normal", MUTED, "start")
states = [
    ("INIT", "session created"),
    ("PLAN", "impact + plan"),
    ("PLAN_SCORED", "plan scored"),
    ("EXECUTE", "implement + tests"),
    ("EXECUTE_SCORED", "build scored"),
    ("REVIEW", "quality + security"),
    ("REVIEW_SCORED", "review scored"),
    ("COMPLETE", "shipped")
]
BW = 164; BH = 64; GAP = 34; Y0 = 200
x0 = (1640 - (8 * BW + 7 * GAP)) // 2
centers = []
for i, (name, cap) in enumerate(states):
    x = x0 + i * (BW + GAP)
    last = name == "COMPLETE"
    fill = GREEN_BG if last else BLUE_BG
    stroke = GREEN if last else BLUE
    pic.box(x, Y0, BW, BH, fill, stroke)
    pic.text(x + BW / 2, Y0 + 27, name, 14.5, "bold", stroke)
    pic.text(x + BW / 2, Y0 + 48, cap, 12, "normal", MUTED)
    centers.append(x + BW / 2)
gates = {(2, 3): "score >= 70", (4, 5): "score >= 70", (6, 7): "score >= 70"}
for i in range(7):
    xa = x0 + i * (BW + GAP) + BW
    xb = xa + GAP
    pic.arrow(xa + 2, Y0 + BH / 2, xb - 2, Y0 + BH / 2)
    lbl = gates.get((i, i + 1), "always")
    pic.edge_label((xa + xb) / 2, Y0 + BH / 2 - 16, lbl)
BX = 720; BY = 400
pic.box(BX, BY, 200, BH, RED_BG, RED)
pic.text(BX + 100, BY + 27, "BLOCKED", 15, "bold", RED)
pic.text(BX + 100, BY + 48, "stopped - user decides", 12, "normal", MUTED)
pic.arrow(centers[4], Y0 + BH, BX + 72, BY - 2, color=RED)
pic.arrow(centers[6], Y0 + BH, BX + 128, BY - 2, color=RED)
pic.edge_label(centers[4] + 60, (Y0 + BH + BY) / 2 - 4, "score < 50 or retries >= 3", 12.5)
pic.polyarrow("%d,%d %d,%d %d,%d" % (BX + 40, BY + BH, centers[1], 540, centers[1], Y0 + BH + 4))
pic.text((BX + centers[1]) / 2, 566, "user intervention: retry with guidance (max 3 attempts)", 13.5, "normal", MUTED)
ly = 616
pic.box(46, ly - 13, 26, 16, GREEN_BG, GREEN, rx=4)
pic.text(80, ly, "PASS >= 70", 13.5, "normal", INK, "start")
pic.box(230, ly - 13, 26, 16, AMBER_BG, AMBER, rx=4)
pic.text(264, ly, "RETRY 50-69 (max 3 attempts)", 13.5, "normal", INK, "start")
pic.box(560, ly - 13, 26, 16, RED_BG, RED, rx=4)
pic.text(594, ly, "BLOCKED < 50 or retries exhausted", 13.5, "normal", INK, "start")
pic.text(1594, 634, "regenerate: python3 scripts/generate_diagrams.py", 13, "normal", MUTED, "end")
pic.save("state-machine.svg", "state machine")

pp = Svg(1640, 880, "opencode platform pipeline")
pp.text(46, 50, "opencode platform - from workspace sources to agents in session", 24, "bold", INK, "start")
pp.text(46, 78, "Docs stay canonical and relative in the repo; the build bakes absolute runtime paths. Config is one bind-mounted inode.", 15, "normal", MUTED, "start")
cols = [
    ("Workspace sources", ["engine/ + config/ (canonical)", "relative doc paths in markdown", "CRLF markdown, LF scripts+py", "CI gates run here first"]),
    ("CI - validate.yml", ["JSON validity (jq)", "bash -n syntax sweep", "cross-reference integrity", "doc style gate", "contract score >= 70"]),
    ("docker build", ["COPY engine/ -> /opt/engine", "normalize-doc-paths.py", "(absolutizes doc links)", "offline pre-install store", "version-pinned MCPs"]),
    ("container runtime", ["opencode serve :4096 loopback", "config bind-mount (one inode)", "MCP: lean-ctx context7 memory", "fetch everything rag", "Firecrawl plugin (keyless)"]),
    ("agents in session", ["16 agents, tiered models", "read-only: no write tool", "path gates on opencode.json", "and session/contract.json", "loop-validate before REVIEW"])
]
CW = 298; CGAP = 18; CY = 150; CH = 520
cx0 = (1640 - (5 * CW + 4 * CGAP)) // 2
for i, (title, items) in enumerate(cols):
    x = cx0 + i * (CW + CGAP)
    pp.box(x, CY, CW, CH, GRAY_BG, GRAY_STROKE, rx=12)
    pp.text(x + CW / 2, CY + 36, title, 16.5, "bold", INK)
    pp.line(x + 16, CY + 52, x + CW - 16, CY + 52, GRAY_STROKE)
    for k, it in enumerate(items):
        pp.text(x + 18, CY + 86 + k * 27, it, 14, "normal", INK, "start")
links = ["git push", "image build", "compose up", "session starts"]
for i in range(4):
    xa = cx0 + i * (CW + CGAP) + CW
    xb = xa + CGAP
    pp.arrow(xa + 2, 410, xb - 2, 410, color=BLUE, marker="arrB")
    pp.edge_label((xa + xb) / 2, 380, links[i], 12.5)
pp.text(820, 742, "Executor done-gate: scripts/loop-validate.sh mirrors the CI gates locally before an agent declares a change done.", 14, "normal", MUTED)
pp.text(1594, 856, "regenerate: python3 engine/scripts/generate_diagrams.py", 13, "normal", MUTED, "end")
pp.save("platform-pipeline.svg", "platform pipeline")
print("done")
