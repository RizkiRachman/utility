#!/usr/bin/env bash
# tests/run.sh — assert-based offline tests. No framework, no network, no token.
# Covers: converter constructs, frontmatter parser, entity escaping, nested
# lists, tables, humanizer lint thresholds, scope guard, publish dry-run flows.
# Prints PASS/FAIL per case and exits non-zero on the first failure.
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"

PASS_COUNT=0
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# publish.sh reads this at source time; tests must never touch the real registry.
export MAPPINGS_FILE="$TMP_DIR/mappings.json"
cp "$ROOT/mappings.json" "$MAPPINGS_FILE"

unset CONFLUENCE_TOKEN

# shellcheck source=../publish.sh
source "$ROOT/publish.sh"

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; [[ -n "${2:-}" ]] && echo "      $2"; exit 1; }

assert_contains() { # DESC HAYSTACK NEEDLE
  [[ "$2" == *"$3"* ]] || fail "$1" "expected to contain: [$3] — got: [${2:0:400}]"
  pass "$1"
}
assert_not_contains() { # DESC HAYSTACK NEEDLE
  [[ "$2" != *"$3"* ]] || fail "$1" "expected NOT to contain: [$3]"
  pass "$1"
}
assert_equals() { # DESC ACTUAL EXPECTED
  [[ "$2" == "$3" ]] || fail "$1" "expected [$3], got [$2]"
  pass "$1"
}
assert_rc() { # DESC EXPECTED_RC ACTUAL_RC
  [[ "$3" == "$2" ]] || fail "$1" "expected rc=$2, got rc=$3"
  pass "$1"
}

conv() { bash "$ROOT/lib/convert.sh" "$1"; }
fixture() { printf '%s' "$1" >"$TMP_DIR/fixture.md"; echo "$TMP_DIR/fixture.md"; }
word100() { printf 'word %.0s' {1..100}; }

# ---------------- converter: headings ----------------
f="$(fixture '# Alpha
## Beta
### Gamma
#### Delta
##### Epsilon
###### Zeta')"
out="$(conv "$f" 2>/dev/null)"
assert_contains "h1 converted" "$out" "<h1>Alpha</h1>"
assert_contains "h2 converted" "$out" "<h2>Beta</h2>"
assert_contains "h3 converted" "$out" "<h3>Gamma</h3>"
assert_contains "h4 converted" "$out" "<h4>Delta</h4>"
assert_contains "h5 converted" "$out" "<h5>Epsilon</h5>"
assert_contains "h6 converted" "$out" "<h6>Zeta</h6>"

# ---------------- converter: inline styles ----------------
f="$(fixture "This is **bold**, *italic*, ~~gone~~ text.")"
out="$(conv "$f" 2>/dev/null)"
assert_contains "bold converted" "$out" "<strong>bold</strong>"
assert_contains "italic converted" "$out" "<em>italic</em>"
assert_contains "strikethrough converted" "$out" "<s>gone</s>"

f="$(fixture 'my_var_name stays plain.')" 
out="$(conv "$f" 2>/dev/null)"
assert_not_contains "snake_case not italicized" "$out" "<em>"

f="$(fixture 'escaped \* stays literal.')"
out="$(conv "$f" 2>/dev/null)"
assert_not_contains "escaped asterisk not bold" "$out" "<strong>"
assert_contains "escaped asterisk rendered" "$out" "* stays literal."

# ---------------- converter: inline code + escaping ----------------
f="$(fixture 'run `npm ci` first.')"
out="$(conv "$f" 2>/dev/null)"
assert_contains "inline code converted" "$out" "<code>npm ci</code>"

f="$(fixture 'payload: `<script>alert(1)</script>`')"
out="$(conv "$f" 2>/dev/null)"
assert_contains "code span content escaped" "$out" "<code>&lt;script&gt;alert(1)&lt;/script&gt;</code>"

# ---------------- converter: entity escaping ----------------
f="$(fixture 'compare a & b < c > d')"
out="$(conv "$f" 2>/dev/null)"
assert_contains "entities escaped in text" "$out" "a &amp; b &lt; c &gt; d"
assert_not_contains "no raw angle brackets left" "$out" "< c >"

# ---------------- converter: fenced code blocks ----------------
f="$(fixture '```bash
echo hello --flag
```')"
out="$(conv "$f" 2>/dev/null)"
assert_contains "code macro emitted" "$out" '<ac:structured-macro ac:name="code" ac:schema-version="1">'
assert_contains "code macro language param" "$out" '<ac:parameter ac:name="language">bash</ac:parameter>'
assert_contains "code body in CDATA" "$out" "<![CDATA[echo hello --flag]]>"

f="$(fixture '```
a]]>b
```')"
out="$(conv "$f" 2>/dev/null)"
assert_contains "CDATA terminator split" "$out" "]]]]><![CDATA[>"

f="$(fixture '```yml
key: value
```')"
out="$(conv "$f" 2>/dev/null)"
assert_contains "language alias yml→yaml" "$out" '<ac:parameter ac:name="language">yaml</ac:parameter>'

# ---------------- converter: lists ----------------
f="$(fixture '- one
- two')"
out="$(conv "$f" 2>/dev/null)"
assert_contains "bullet list converted" "$out" "<ul><li>one</li><li>two</li></ul>"

f="$(fixture '- a
  - b
    - c')"
out="$(conv "$f" 2>/dev/null)"
assert_contains "bullets nested 3 levels" "$out" "<ul><li>a<ul><li>b<ul><li>c</li></ul></li></ul></li></ul>"

f="$(fixture '1. first
   1. nested')"
out="$(conv "$f" 2>/dev/null)"
assert_contains "ordered list nested" "$out" "<ol><li>first<ol><li>nested</li></ol></li></ol>"

f="$(fixture '- l1
  - l2
    - l3
      - l4')"
out="$(conv "$f" 2>"$TMP_DIR/err")"
assert_contains "4th nesting level clamped to sibling" "$out" "<ul><li>l1<ul><li>l2<ul><li>l3</li><li>l4</li></ul></li></ul></li></ul>"
assert_not_contains "no 4th-level ul emitted" "$out" "</ul></ul></ul></ul>"
grep -q "clamped to 3" "$TMP_DIR/err" || fail "deep nesting warns" "expected clamp warning on stderr"
pass "deep nesting warns on stderr"

f="$(fixture '- [ ] open task')"
out="$(conv "$f" 2>"$TMP_DIR/err")"
assert_contains "task list item rendered literally" "$out" "<li>[ ] open task</li>"
grep -q "task list" "$TMP_DIR/err" || fail "task list warns" "expected task list warning"
pass "task list warns on stderr"

# ---------------- converter: tables ----------------
f="$(fixture '| Left | Center | Right |
| :--- | :---: | ---: |
| a | b | c |')"
out="$(conv "$f" 2>/dev/null)"
assert_contains "table header left-aligned" "$out" '<th style="text-align: left;">Left</th>'
assert_contains "table header center-aligned" "$out" '<th style="text-align: center;">Center</th>'
assert_contains "table cell right-aligned" "$out" '<td style="text-align: right;">c</td>'
assert_contains "table body row present" "$out" '<tr><td style="text-align: left;">a</td><td style="text-align: center;">b</td><td style="text-align: right;">c</td></tr>'

# ---------------- converter: blockquote ----------------
f="$(fixture '> quoted wisdom
> second line')"
out="$(conv "$f" 2>/dev/null)"
assert_contains "blockquote converted" "$out" "<blockquote><p>quoted wisdom<br/>second line</p></blockquote>"

# ---------------- converter: links ----------------
f="$(fixture 'see [the docs](https://example.com/x?q=1) now')"
out="$(conv "$f" 2>/dev/null)"
assert_contains "link converted with escaped attr" "$out" '<a href="https://example.com/x?q=1">the docs</a>'

f="$(fixture 'browse <https://example.com/auto> directly')"
out="$(conv "$f" 2>/dev/null)"
assert_contains "autolink converted" "$out" '<a href="https://example.com/auto">https://example.com/auto</a>'

# ---------------- converter: images skipped ----------------
f="$(fixture 'logo: ![alt text](img/logo.png) end')"
out="$(conv "$f" 2>"$TMP_DIR/err")"
assert_not_contains "no <img> emitted" "$out" "<img"
assert_contains "image skip note present" "$out" "<!-- image skipped (attachments out of scope): alt text -->"
grep -q "image skipped" "$TMP_DIR/err" || fail "image warns on stderr" "expected image warning"
pass "image skip warns on stderr"

# ---------------- converter: hr, paragraphs, breaks ----------------
f="$(fixture 'before

---

after')"
out="$(conv "$f" 2>/dev/null)"
assert_contains "horizontal rule converted" "$out" "<hr/>"

f="$(fixture 'line one
line two')"
out="$(conv "$f" 2>/dev/null)"
assert_contains "soft newline becomes hard break" "$out" "line one<br/>line two"

f="$(fixture 'before<!-- secret authoring note -->after')"
out="$(conv "$f" 2>/dev/null)"
assert_not_contains "HTML comment stripped" "$out" "secret authoring note"
assert_contains "text around comment preserved" "$out" "<p>beforeafter</p>"

# ---------------- converter: unknown constructs kept + noted ----------------
f="$(fixture 'see details [^1] in the appendix')"
out="$(conv "$f" 2>/dev/null)"
assert_contains "footnote kept as text" "$out" "[^1]"
assert_contains "footnote note emitted" "$out" "<!-- markdown footnote rendered as plain text (not supported) -->"

f="$(fixture 'read [the intro][intro-ref] first')"
out="$(conv "$f" 2>/dev/null)"
assert_contains "reference link kept as text" "$out" "[the intro][intro-ref]"
assert_contains "reference link note emitted" "$out" "<!-- reference-style link rendered as plain text (not supported) -->"

f="$(fixture '<div>boxed</div>')"
out="$(conv "$f" 2>/dev/null)"
assert_contains "raw HTML escaped" "$out" "&lt;div&gt;boxed&lt;/div&gt;"
assert_contains "raw HTML note emitted" "$out" "<!-- raw HTML escaped as plain text -->"

# ---------------- frontmatter parser ----------------
f="$TMP_DIR/fm.md"
printf -- '---\ntitle: Docker Setup with Rancher Desktop\nparent: 4125949974\nconfluence-id: 4125949982\n---\n\nBody text here.\n' >"$f"
rc=0; parse_frontmatter "$f" || rc=$?
assert_rc "valid frontmatter parses" 0 "$rc"
assert_equals "title parsed" "$FM_TITLE" "Docker Setup with Rancher Desktop"
assert_equals "parent parsed" "$FM_PARENT" "4125949974"
assert_equals "confluence-id parsed" "$FM_ID" "4125949982"
grep -q "Body text here." "$TMP_BODY" || fail "body extracted" "frontmatter body missing page content"
pass "frontmatter body extracted"

printf -- '---\ntitle: "Quoted Title"\nparent: 4125949974\nconfluence-id:\n---\n\nx\n' >"$f"
rc=0; parse_frontmatter "$f" || rc=$?
assert_rc "empty confluence-id parses" 0 "$rc"
assert_equals "quoted title stripped" "$FM_TITLE" "Quoted Title"
assert_equals "empty confluence-id means CREATE" "$FM_ID" ""

printf -- '---\ntitle: T\nparent: 4125949974\nowner: somebody\nlabels: a,b\n---\n\nx\n' >"$f"
rc=0; parse_frontmatter "$f" || rc=$?
assert_rc "extra fields ignored" 0 "$rc"
assert_equals "title intact with extra fields" "$FM_TITLE" "T"

printf -- '---\nparent: 4125949974\n---\n\nx\n' >"$f"
rc=0; parse_frontmatter "$f" || rc=$?
assert_rc "missing title fails" "$EX_FRONTMATTER" "$rc"

printf -- '---\ntitle: T\n---\n\nx\n' >"$f"
rc=0; parse_frontmatter "$f" || rc=$?
assert_rc "missing parent fails" "$EX_FRONTMATTER" "$rc"

printf -- 'no frontmatter here\n' >"$f"
rc=0; parse_frontmatter "$f" || rc=$?
assert_rc "absent frontmatter fails" "$EX_FRONTMATTER" "$rc"

# ---------------- humanizer lint ----------------
f="$TMP_DIR/lint.md"
printf '%s — x — y — z\n' "$(word100)" >"$f"
out="$(humanizer_lint "$f")"; rc=$?
assert_rc "em dashes over 2/100 words are HARD" 1 "$rc"
assert_contains "em dash report mentions density" "$out" "em dash density"

printf '%s %s — x — y\n' "$(word100)" "$(word100)" >"$f"
rc=0; humanizer_lint "$f" >/dev/null || rc=$?
assert_rc "em dashes at/below 2/100 words pass" 0 "$rc"

printf 'This path is not just faster but safer.\n' >"$f"
out="$(humanizer_lint "$f")"; rc=$?
assert_rc "not-just-but is HARD" 1 "$rc"
assert_contains "not-just-but reported" "$out" "not just X but Y"

printf 'The setup is seamless.\n' >"$f"
rc=0; humanizer_lint "$f" >/dev/null || rc=$?
assert_rc "promo word is HARD" 1 "$rc"

printf 'Use the SDK to leverage the new API.\n' >"$f"
rc=0; humanizer_lint "$f" >/dev/null || rc=$?
assert_rc "leverage as verb is HARD" 1 "$rc"

printf 'The plan gives us the leverage we need.\n' >"$f"
rc=0; humanizer_lint "$f" >/dev/null || rc=$?
assert_rc "leverage as noun passes" 0 "$rc"

printf 'alpha, beta and gamma. one, two and three. red, green and blue. north, south and east.\n' >"$f"
out="$(humanizer_lint "$f")"; rc=$?
assert_rc "4 triples are SOFT only" 0 "$rc"
assert_contains "triple count reported as SOFT" "$out" "SOFT: rule-of-three style: 4"

printf '```bash\nseamless robust leverage --flag\n```\nPlain sentence about tools.\n' >"$f"
rc=0; humanizer_lint "$f" >/dev/null || rc=$?
assert_rc "fenced code excluded from lint" 0 "$rc"

# ---------------- scope guard ----------------
rc=0; (verify_scope 4125949974 dry) >/dev/null 2>&1 || rc=$?
assert_rc "parent = boundary root passes offline" 0 "$rc"

rc=0; (verify_scope 4157603000 dry) >/dev/null 2>&1 || rc=$?
assert_rc "unverified parent fails closed without token" "$EX_SCOPE" "$rc"

python3 - "$MAPPINGS_FILE" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
d["scope_cache"]["4157603900"] = {
    "in_scope": True,
    "ancestors": ["4125949974", "4157603973"],
    "title": "Cached Folder",
    "verified_at": "2000-01-01T00:00:00Z",
}
open(p, "w", encoding="utf-8").write(json.dumps(d, indent=2))
PY
rc=0; (verify_scope 4157603900 dry) >/dev/null 2>&1 || rc=$?
assert_rc "cached in-scope parent passes offline" 0 "$rc"

# ---------------- end-to-end dry-run (no token) ----------------
f="$TMP_DIR/page.md"
printf -- '---\ntitle: Scratch Page\nparent: 4125949974\n---\n\nSimple paragraph about tools.\n' >"$f"
out="$(bash "$ROOT/publish.sh" "$f" 2>/dev/null)"; rc=$?
assert_rc "dry-run with root parent exits 0 offline" 0 "$rc"
assert_contains "plan announces CREATE" "$out" "CREATE page 'Scratch Page' under Local Toolkit Setup (4125949974)"
assert_contains "dry-run confirms no writes" "$out" "DRY-RUN complete — no writes performed"
assert_contains "storage preview shown" "$out" "storage-format preview"

printf -- '---\ntitle: Scratch Update\nparent: 4125949974\nconfluence-id: 4125949982\n---\n\nSimple paragraph about tools.\n' >"$f"
out="$(bash "$ROOT/publish.sh" "$f" 2>/dev/null)"; rc=$?
assert_rc "dry-run UPDATE with no token exits 0 (deferred)" 0 "$rc"
assert_contains "update plan defers version check" "$out" "version check deferred to --publish"

out="$(bash "$ROOT/publish.sh" "$ROOT/NPG/local-toolkit-setup/sample-draft.md" 2>&1)"; rc=$?
assert_rc "sample draft fails closed without token" "$EX_SCOPE" "$rc"
assert_contains "sample draft refusal mentions fail-closed" "$out" "fail-closed"

echo
echo "tests/run.sh: $PASS_COUNT assertions passed"
