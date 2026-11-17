---
name: drawio-animation
version: 1.0.0
description: Create draw.io diagrams with animated connectors (flowAnimation edges, numbered and icon-labelled nodes) and export them as animated SVG or GIF. Use when the user asks for animated architecture or flow diagrams, moving dots or dashes on lines, service numbers or icons, or GIF exports of draw.io diagrams.
compatibility: claude-code opencode
---

# drawio-animation

## Two native animation methods

### A. Connector flow animation (flowAnimation=1)

Adding `flowAnimation=1;` to any edge style makes marching pulses flow from source to target inside the draw.io editor.

- Export as animation: in draw.io web or Desktop, File > Export as > Animated GIF. Configure speed, loop count (Forever, 1, 3, 5), zoom factor, border width and transparent background.
- Confluence: the draw.io macro renders `flowAnimation=1` natively, so the diagram animates right on the page when embedded that way.
- CLI limitation: `drawio -x` exports static png, svg, pdf and jpg only. Animated GIF export must be triggered through the draw.io UI menu.

### B. Sequenced step animations (built-in Animation.js plugin)

For shapes and nodes that fade in, wipe in or step through a sequence (beyond connector flow):

1. In draw.io go to Extras > Plugins > Add > Animation.js (built-in) and reload.
2. Open Extras > Animations to script step sequences per cell ID: show, hide, fade, flow, wait.
3. Export via File > Export As > URL and append `&p=anim` to the URL query string so playback controls auto-start.

## Agent authoring rules

1. Always include `flowAnimation=1;` in edge style attributes for data and dependency flows. Static decorative edges may omit it.
2. Edge style base: `edgeStyle=orthogonalEdgeStyle;rounded=1;html=1;jettySize=auto;orthogonalLoop=1;flowAnimation=1;strokeColor=#5c5c5c;strokeWidth=1.5;`
3. Use only documented style keys. Unknown keys are silently stripped when a user edits the file in draw.io.
4. Structure layered diagrams as swimlane containers (one per layer), nodes parented to their lane, edges parented to the root with explicit exitX/entryX and waypoint arrays.
5. Label each node with a stable number badge (ellipse cell, 26x26, anchored at node x-9, y-9 in the same parent lane) plus an emoji icon in the label text. Numbers are reference handles for reviews.
6. Color-code layers: container stroke plus tinted children. Suggested pairs: blue #dae8fc/#6c8ebf, green #d5e8d4/#82b366, orange #ffe6cc/#d79b00, purple #e1d5e7/#9673a6.
7. Agents cannot script the draw.io editor. Write `.drawio` XML directly, and generate the animated SVG from the same layout data (see generator below).
8. Remind the user of the GIF export path: File > Export as > Animated GIF in draw.io, or embed the .drawio in the Confluence draw.io macro which animates it natively.

## Official draw.io MCP server and agent skill

JGraph maintains an MCP server and an agent SKILL.md that write valid mxGraphModel XML, run ELK auto-layouts and invoke the draw.io CLI:

- Local MCP: `npx -y @drawio/mcp` (works in OpenCode, Claude Code, Cursor, VS Code):

```json
{
  "mcp": {
    "drawio": {
      "type": "local",
      "command": ["npx", "-y", "@drawio/mcp"]
    }
  }
}
```

- Hosted MCP endpoint for clients supporting remote HTTP MCP: https://mcp.draw.io/mcp
- Official agent skill: `plugins/claude-code/skills/drawio/SKILL.md` in https://github.com/jgraph/drawio-mcp. It teaches mxGraphModel conventions, geometry rules and CLI export commands, and pairs with this skill: install both, keep this skill's `flowAnimation=1` rule on top.

Note: the official skill and MCP focus on static generation and static CLI exports. Animation and GIF export come from the two native methods above.

## Export paths

| Target | How |
|---|---|
| GIF, best quality, native | Open the .drawio in draw.io web or Desktop, File > Export as > Animated GIF, Loops = Forever. Zero extra tooling. |
| Confluence page, animated | Embed the .drawio through the Confluence draw.io macro; flowAnimation edges animate in place. |
| Animated SVG, agent-side headless | Run `assets/generate_animated_svg.py`. Zero dependencies, works in any container. |
| GIF / MP4 / WebM, agent-side headless | Feed the animated SVG to a converter: `npx -y -p @gehdoc/svg-to-video svg-to-video in.svg 60 outdir -d 11 --format gif` or `npx svg-to-gif in.svg out.gif --preset crisp-ui`. First run downloads Chromium (~170 MB); ffmpeg must be on PATH. Do it in the session sandbox folder. |

## Animated SVG generator (assets/generate_animated_svg.py)

Copy the script, edit the NODES / LANES / EDGES data block at the top, run `python3 generate_animated_svg.py`. It emits a self-contained animated SVG with an infinite, seamless dot-flow loop.

- NODES rows: id, layer key, label (with emoji), number badge, absolute x, y, w, h. Flatten lanes to absolute coordinates (lane origin + child offset).
- EDGES rows: id, source layer key (colors the dots), polyline points from source border to target border.
- Seamless loop math: stroke-dasharray period must divide the offset target exactly. Use `stroke-dasharray: 0.5 21.5` (period 22) with `@keyframes flow { to { stroke-dashoffset: -990px; } }` (45 x 22); duration 11s gives a constant 90 px/s.
- Dots inherit the SOURCE layer color; stagger edges with negative animation-delay (-0.7s per edge index) so motion starts immediately and looks organic.
- Round-capped micro-dashes (`stroke-linecap: round`) render as true moving dots, not dashes.
- Seamlessness depends only on the offset target being an exact multiple of the dash period; polyline length does not matter (dots simply flow longer per loop on long edges). Never use an offset target that is not a multiple of 22.
- Always include `@media (prefers-reduced-motion: reduce) { .flow { animation: none; } }`.
- Draw each edge twice: a solid base polyline with an arrow marker, then a `.flow` overlay polyline for the dots.

## References

- Animated GIF export: https://www.drawio.com/docs/manual/export/export-to-animated-gif
- Connector animation styles: https://www.drawio.com/docs/manual/connectors/connector-animate/
- GIF export origin, issue #3739 (closed won't-fix 2023, implemented 2026-02): https://github.com/jgraph/drawio/issues/3739
- Official MCP and skill: https://github.com/jgraph/drawio-mcp
- SVG to GIF/video MCP and skill: https://github.com/GehDoc/svg-to-video
- svg-to-gif CLI: https://github.com/hesreallyhim/svg-to-gif
