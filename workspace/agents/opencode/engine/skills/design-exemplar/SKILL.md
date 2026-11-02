---
name: design-exemplar
description: >-
  Reference library of 84 DESIGN.md files extracted from real production websites — Linear, Stripe,
  Vercel, Apple, Notion, Cursor, Claude, Figma and more. Use when the user references a known brand
  aesthetic ("make it look like X"), wants exemplar-driven design grounded in a proven design
  language, or needs a real design system as the starting point for a new UI. Each DESIGN.md is a
  plain-markdown design system document that AI agents read natively. Source:
  https://github.com/VoltAgent/awesome-design-md (MIT). This skill is the Exemplar layer of the
  mandatory 4-layer UI pipeline (Exemplar > Generator > Taste > Gate).
---

# design-exemplar — Exemplar Layer of the UI Pipeline

## What is DESIGN.md?

DESIGN.md is a Google Stitch concept: a **plain-markdown design system document** that AI agents
read natively — no parsing, no tooling, just markdown. The relationship:

- `AGENTS.md` = how to **build** (conventions, workflow, tooling rules)
- `DESIGN.md` = how to **look** (visual language, palette, type, components)

Each file was extracted from a real, publicly deployed website — production CSS distilled into an
agent-readable design language. Handing a DESIGN.md to an agent is equivalent to handing it the
actual design system of that brand.

## The 9 sections every DESIGN.md contains

1. **Visual theme** — overall mood, personality, aesthetic direction
2. **Color palette + roles** — full palette with semantic roles (surface, primary, accent, danger…)
3. **Typography rules** — typefaces, scale, weights, line-height, usage per element
4. **Component stylings** — buttons, inputs, cards, nav, modals, tables, etc.
5. **Layout principles** — grid, spacing rhythm, container widths, section structure
6. **Depth & elevation** — shadows, borders, blur, layering rules
7. **Do's & don'ts** — the brand's explicit design prohibitions and requirements
8. **Responsive behavior** — breakpoints, mobile adaptations, density changes
9. **Agent prompt guide** — ready-made instructions for AI agents consuming the design

Each entry ships alongside `preview.html` / `preview-dark.html` — rendered references of the design
in light and dark modes.

## Brand index highlights

**AI & LLM:** Claude, Mistral, Ollama, OpenCode AI, Runway, xAI
**Dev tools:** Cursor, Vercel, Raycast, Warp, Expo, Lovable
**Backend / DB:** Supabase, MongoDB, Sentry, PostHog, ClickHouse
**SaaS:** Linear, Notion, Cal.com, Resend, Zapier
**Fintech:** Stripe, Coinbase, Mercury, Revolut, Wise, Mastercard
**E-commerce:** Airbnb, Nike, Shopify, Starbucks
**Media:** Apple, Spotify, NVIDIA, SpaceX, Uber
**Automotive:** Tesla, Ferrari, Lamborghini, BMW
**Retro:** Dell 1996, Nintendo 2001

Full index: the [GitHub repo README](https://github.com/VoltAgent/awesome-design-md).

## Fetch workflow

1. Fetch `https://getdesign.md/<site>/design-md` (or the raw file from the GitHub repo) with the
   fetch/webfetch tool.
2. Save the result as `DESIGN.md` at the **project root**.
3. Follow it: the agent consumes DESIGN.md as its design language for the task.
4. Persist the full index lookup to the repo README when the brand is not in the highlights above.

## Usage rules

- **Never mix** exemplar + generated design system on the same page. Pick one source of truth.
- **Cite the source brand** in the final summary (e.g. "design based on the Linear DESIGN.md").
- The taste-skill (`design-taste-frontend`) should **push beyond** the copied language — use the
  exemplar as grounding, not a ceiling, to avoid derivative output.
- This skill is the **Exemplar layer** of the mandatory 4-layer UI pipeline:
  **Exemplar (design-exemplar) > Generator (ui-ux-pro-max) > Taste (design-taste-frontend) > Gate
  (impeccable)**. Order is mandatory. No UI task is done without the impeccable gate.

## Licensing

MIT licensed. Design data was extracted from publicly visible CSS of live websites, provided
as-is, with no ownership claims over the referenced brands or their trademarks. Use as reference
material; do not claim the design as your own original work.
