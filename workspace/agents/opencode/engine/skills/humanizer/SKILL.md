---
name: humanizer
version: 2.9.0
description: Remove signs of AI-generated writing from text. Detects and fixes: inflated symbolism, promotional language, -ing analyses, vague attributions, em dash overuse, rule of three, AI vocabulary, passive voice, filler phrases. Use before delivering any user-facing text.
compatibility: claude-code opencode
---

# Humanizer: Remove AI Writing Patterns

1. **Scan for AI patterns** (see below).
2. **Rewrite, don't delete** — replace AI-isms with natural alternatives; preserve full meaning and length.
3. **No em dashes (—) or en dashes (–)** in the final output. Replace with period, comma, colon, or restructure. Hard constraint.
4. **Match the voice**: fit the intended tone (formal, casual, technical). For blog/opinion/personal writing, vary sentence rhythm and avoid sterile neutrality.

## Voice Matching (Optional)

If user provides a writing sample: note sentence length patterns, word choice level, punctuation habits, transitions. Match those in the rewrite. If no sample, default to natural, varied, opinionated voice. For encyclopedic/technical/legal text, neutral is correct — don't inject personality.

## 33 AI Patterns to Fix

### Content Patterns (1-6)

1. **Significance inflation** — cut "stands as a testament", "pivotal moment", "marks a shift", "evolving landscape", "indelible mark". Just say what happened.
2. **Notability padding** — "covered by NYT, BBC, The Hindu" (with no context) → cite specific interview or article if relevant.
3. **-ing superficial analyses** — phrases tacked on with "highlighting/underscoring/symbolizing/reflecting/contributing/fostering/showcasing..." → rewrite as separate concrete statements.
4. **Promotional language** — "boasts a", "vibrant", "rich" (figurative), "nestled", "breathtaking", "must-visit" → neutral description.
5. **Vague attributions** — "Industry reports", "Experts argue", "Several sources" without specific citations → cut or name the source.
6. **Formulaic "Challenges" sections** — "Despite its success, X faces several challenges..." → replace with specific, concrete statements about actual problems.

### Language Patterns (7-19)

7. **Overused AI vocabulary**: actually, align with, crucial, delve, enhance, fostering, garner, highlight (verb), interplay, intricate, key (adj), landscape (abstract), pivotal, showcase, tapestry (abstract), testament, underscore, valuable, vibrant.
8. **Copula avoidance** — "serves as / stands as / marks / boasts / offers" → prefer "is", "has", "are".
9. **Negative parallelisms** — "Not only...but...", "It's not just about..., it's..." — use simple statements. Tailing negations ("no guessing", "no wasted motion") → rewrite as real clauses.
10. **Rule of three** — "keynote sessions, panel discussions, and networking opportunities" → say what matters in 1-2 items.
11. **Synonym cycling** — repetition-penalty driven: "protagonist... main character... central figure... hero" → pick one term and use it.
12. **False ranges** — "from X to Y" where X and Y aren't on a meaningful scale → list items directly.
13. **Passive voice** — "No config file needed" → "You don't need a config file". Prefer active voice.
14. **Em dashes (—) and en dashes (–): zero tolerance** — Hard constraint. Use period, comma, colon, or parentheses instead.
15. **Boldface overuse** — strip mechanical bold from list items; integrate into prose.
16. **Inline-header vertical lists** — "**User Experience:** The UI has been improved..." → rewrite as connected paragraphs.
17. **Title case in headings** — "Strategic Negotiations And Global Partnerships" → "Strategic negotiations and global partnerships".
18. **Emojis in headings/lists** — strip emojis; write the content directly.
19. **Curly quotes** — "..." → "..." (models default to curly; source text likely uses straight).

### Communication Patterns (20-22)

20. **Collaborative artifacts** — "I hope this helps!", "Of course!", "Let me know if...", "Here is a..." → just the content.
21. **Cutoff disclaimers & speculative gap-filling** — "As of [date]", "While specific details are limited...", "likely [grew up/studied]", "maintains a low profile" → state what's actually known or cut it.
22. **Sycophantic tone** — "Great question!", "You're absolutely right", "Excellent point" → acknowledge the point without flattery.

### Filler & Structure (23-33)

23. **Filler phrases**: "In order to" → "To", "Due to the fact that" → "Because", "has the ability to" → "can".
24. **Excessive hedging** — "could potentially possibly argue that it might have some effect" → cut to one qualifier.
25. **Generic positive conclusions** — "The future looks bright", "Exciting times lie ahead" → specific forward-looking statement.
26. **Hyphenated compounds** — drop hyphen in predicate position ("the report is high quality" not "high-quality"). Keep attributive ("a high-quality report").
27. **Persuasive authority tropes** — "The real question is", "At its core", "What really matters", "The heart of the matter" → just make the point.
28. **Signposting** — "Let's dive in", "Here's what you need to know", "Without further ado" → skip the meta-commentary.
29. **Fragmented headers** — heading followed by one-line paragraph restating it → cut the filler sentence.
30. **Diff-anchored writing** — "This function was added to replace..." → describe the function as-is ("This function uses a hash map for O(1) lookups").
31. **Manufactured punchlines** — stacked short declarative fragments for dramatic effect → normal paragraph rhythm.
32. **Aphorism formulas** — "X is the Y of Z", "X is not a tool but a mirror", "the language/currency/architecture of" → concrete claim.
33. **Conversational rhetorical openers** — "Honestly?", "Look,", "Here's the thing", "The thing is" as standalone hooks → just deliver the point.

## Detection Guidance (What NOT to flag)

These are NOT reliable AI tells alone: perfect grammar, mixed casual/formal registers, generic dry prose, formal vocabulary, letter-style openings, common transition words in isolation, curly quotes alone, em dashes alone, one short emphatic sentence, unsourced claims.

**Human signals (preserve these):** specific unusual details, mixed feelings, dated subculture references, first-person editorial choices, genuine asides/self-corrections, edits from before Nov 30, 2022.

When in doubt, look for **clusters** of tells, not isolated ones.

## Output Format

Deliver: (1) draft rewrite, (2) brief "what's still AI" bullets, (3) final rewrite with zero em dashes.

Based on [Wikipedia:Signs of AI writing](https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing), maintained by WikiProject AI Cleanup.
