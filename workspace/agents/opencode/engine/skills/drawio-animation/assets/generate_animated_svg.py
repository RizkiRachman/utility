#!/usr/bin/env python3
"""Generate a self-contained animated SVG (infinite seamless dot flow) from a layered layout.

Usage:
  python3 generate_animated_svg.py                # renders the built-in example below
  python3 generate_animated_svg.py my_layout.py   # loads NODES/LANES/EDGES from your file
  python3 generate_animated_svg.py my_layout.py out.svg

Edit the EXAMPLE_* data blocks for your diagram (see SKILL.md conventions),
or point the script at a layout module defining NODES, LANES, EDGES.
"""
import sys

# ---------------------------------------------------------------- example data
FILL = {"svc": "#dae8fc", "dom": "#d5e8d4", "ker": "#ffe6cc", "lib": "#e1d5e7"}
STRK = {"svc": "#6c8ebf", "dom": "#82b366", "ker": "#d79b00", "lib": "#9673a6"}
FLOWC = {"svc": "#2D6CB5", "dom": "#4F8A44", "ker": "#D07A1F", "lib": "#7E5FA4"}

# id, layer, label (with emoji), number, x, y, w, h  (absolute coords)
NODES = [
    ("cms", "svc", "\U0001F9FE cms", "1", 70, 95, 190, 50),
    ("report", "svc", "\U0001F4CA report-service", "2", 285, 95, 190, 50),
    ("token", "svc", "\U0001F511 token-service", "3", 500, 95, 190, 50),
    ("pay", "svc", "\U0001F4B3 payment-service", "4", 715, 95, 190, 50),
    ("settle", "svc", "\U0001F9EE settlement-service", "5", 930, 95, 190, 50),
    ("sim", "svc", "\U0001F9EA simulator", "6", 1145, 95, 190, 50),
    ("notify", "svc", "\U0001F514 notification-service (standalone)", "7", 1360, 95, 190, 50),
    ("pb", "dom", "\U0001F9E9 payment-baseline", "8", 820, 330, 220, 50),
    ("ba", "dom", "\U0001F309 bank-adapter", "9", 1090, 330, 190, 50),
    ("ah", "ker", "\u2699\uFE0F ah-baseline", "10", 320, 330, 220, 50),
    ("mail", "lib", "\U0001F4E7 inf-email-sdk", "11", 100, 555, 190, 50),
    ("boot", "lib", "\U0001F9F1 inf-bootstrap", "12", 330, 555, 190, 50),
    ("jce", "lib", "\U0001F510 inf-jce", "13", 600, 555, 190, 50),
    ("bsim", "lib", "\U0001F3AB bank-simulator", "14", 830, 555, 190, 50),
    ("iso", "lib", "\U0001F4E1 bank-iso8583-base", "15", 1130, 555, 190, 50),
]
LANES = [
    ("Service layer (deployable)", "#f5f9fd", STRK["svc"], 40, 40, 1520, 140),
    ("Payment domain layer", "#f5faf5", STRK["dom"], 760, 280, 560, 120),
    ("Platform kernel", "#fdf7f0", STRK["ker"], 240, 280, 400, 120),
    ("Internal libraries (no gitea repo)", "#faf5fb", STRK["lib"], 40, 500, 1520, 140),
]
# id, source layer (colors the dots), polyline points source-border -> target-border
EDGES = [
    ("e1", "svc", [(165, 145), (165, 210), (375, 210), (375, 330)]),
    ("e2", "svc", [(165, 145), (165, 480), (195, 480), (195, 555)]),
    ("e3", "svc", [(380, 145), (380, 230), (430, 230), (430, 330)]),
    ("e4", "svc", [(380, 145), (380, 230), (195, 230), (195, 555)]),
    ("e5", "svc", [(595, 145), (595, 250), (485, 250), (485, 330)]),
    ("e6", "svc", [(810, 145), (810, 210), (875, 210), (875, 330)]),
    ("e7", "svc", [(1025, 145), (1025, 250), (985, 250), (985, 330)]),
    ("e8", "svc", [(810, 145), (810, 230), (1345, 230), (1345, 470), (925, 470), (925, 555)]),
    ("e9", "dom", [(820, 355), (540, 355)]),
    ("e10", "dom", [(1040, 355), (1090, 355)]),
    ("e11", "dom", [(930, 380), (930, 460), (195, 460), (195, 555)]),
    ("e12", "dom", [(1185, 380), (1185, 555)]),
    ("e13", "ker", [(427, 380), (427, 555)]),
    ("e14", "ker", [(430, 380), (430, 490), (695, 490), (695, 555)]),
    ("e15", "svc", [(1240, 145), (1240, 230), (695, 230), (695, 555)]),
]
# ------------------------------------------------------------------ rendering
DELAY_STEP = 0.7          # seconds between edge starts (negative delays)
DURATION = 11             # s; 990px / 11s = 90 px/s constant dot speed
OFFSET_TARGET = 990       # px; must be a multiple of the dash period (22)
W, H = 1650, 710


def render(path):
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
        'font-family="Segoe UI, Helvetica, Arial, sans-serif">',
        "<title>Animated architecture diagram</title>",
        f"""<defs><marker id="arr" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="#5c5c5c"/></marker></defs>
<style>
  .lane {{ stroke-width: 1.2; }}
  .laneTitle {{ font-size: 13px; font-weight: bold; }}
  .edge {{ fill: none; stroke: #5c5c5c; stroke-width: 1.5; }}
  .flow {{ fill: none; stroke-width: 3; stroke-linecap: round; stroke-dasharray: 0.5 21.5;
          animation: flow {DURATION}s linear infinite; }}
  @keyframes flow {{ from {{ stroke-dashoffset: 0; }} to {{ stroke-dashoffset: -{OFFSET_TARGET}px; }} }}
  .node {{ stroke-width: 1.2; }}
  .nlabel {{ font-size: 12px; fill: #1a1a1a; text-anchor: middle; }}
  .badge {{ fill: #1B4F72; stroke: #ffffff; stroke-width: 1.2; }}
  .bnum {{ font-size: 12px; font-weight: bold; fill: #ffffff; text-anchor: middle; }}
  .foot {{ font-size: 11px; fill: #666666; }}
  @media (prefers-reduced-motion: reduce) {{ .flow {{ animation: none; }} }}
</style>""",
    ]
    for title, fill, stroke, x, y, w, h in LANES:
        parts.append(f'<rect class="lane" x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="{fill}" stroke="{stroke}"/>')
        parts.append(f'<text class="laneTitle" x="{x+12}" y="{y+20}" fill="{stroke}">{title}</text>')
    for i, (eid, layer, pts) in enumerate(EDGES):
        p = " ".join(f"{x},{y}" for x, y in pts)
        parts.append(f'<polyline class="edge" points="{p}" marker-end="url(#arr)"/>')
        parts.append(f'<polyline class="flow" points="{p}" stroke="{FLOWC[layer]}" style="animation-delay:{-i * DELAY_STEP}s;"/>')
    for nid, layer, label, num, x, y, w, h in NODES:
        dashed = ' stroke-dasharray="6 4"' if nid == "notify" else ""
        parts.append(f'<rect class="node" x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{FILL[layer]}" stroke="{STRK[layer]}"{dashed}/>')
        parts.append(f'<circle class="badge" cx="{x-2}" cy="{y-2}" r="12"/>')
        parts.append(f'<text class="bnum" x="{x-2}" y="{y+3}">{num}</text>')
        parts.append(f'<text class="nlabel" x="{x+w/2}" y="{y+h/2+4}">{label}</text>')
    parts.append(f'<text class="foot" x="{LANES[0][3]}" y="{H-40}">Animated view: colored dots flow from consumer to dependency, forever loop. Static source of truth: the .drawio file next to this SVG.</text>')
    parts.append("</svg>")
    svg = "\n".join(parts)
    open(path, "w", encoding="utf-8").write(svg)
    return svg


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] != "-":
        src = sys.argv[1]
        ns: dict = {}
        exec(compile(open(src, encoding="utf-8").read(), src, "exec"), ns)  # layout module
        NODES, LANES, EDGES = ns["NODES"], ns["LANES"], ns["EDGES"]
        FILL, STRK, FLOWC = ns.get("FILL", FILL), ns.get("STRK", STRK), ns.get("FLOWC", FLOWC)
    out = sys.argv[2] if len(sys.argv) > 2 else "animated-diagram.svg"
    svg = render(out)
    # sanity: the loop is seamless iff the offset target is an exact multiple
    # of the dash period (22); polyline length is irrelevant to seamlessness.
    period_ok = OFFSET_TARGET % 22 == 0
    print(f"wrote {out} ({len(svg)} bytes) | nodes {len(NODES)} | edges {len(EDGES)} "
          f"| seamless-offset {period_ok} ({OFFSET_TARGET} = {OFFSET_TARGET // 22} x 22) "
          f"| speed {OFFSET_TARGET / DURATION:.0f} px/s")
