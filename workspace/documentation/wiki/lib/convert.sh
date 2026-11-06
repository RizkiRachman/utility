#!/usr/bin/env bash
# lib/convert.sh — markdown → Confluence storage XHTML converter.
#
# Zero external dependencies: bash + python3 stdlib only (json/escaping), no pip.
# Reads a markdown file argument (or markdown on stdin), writes Confluence
# storage XHTML to stdout, conversion warnings to stderr.
#
# Supported constructs: headings h1-h6, bold/italic/strikethrough, inline code,
# fenced code blocks (code macro with language), bullet/ordered lists (nested
# up to 3 levels), GFM tables, blockquotes, links, autolinks, horizontal rules,
# paragraphs, hard line breaks, HTML entity escaping in text nodes.
# Images are skipped with a warning comment (attachments out of scope).
# HTML comments in the source are stripped (authoring instructions).
# Unknown constructs are rendered as escaped plain text plus an HTML comment note.
set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required by lib/convert.sh (stdlib only, no pip install)." >&2
  exit 127
fi

exec python3 -c "$(cat <<'PYCONVERT'
import re, sys

MAX_LIST_DEPTH = 3

LANG_ALIASES = {
    "sh": "bash", "shell": "bash", "zsh": "bash", "console": "bash",
    "yml": "yaml", "py": "python", "js": "javascript", "ts": "typescript",
    "rb": "ruby", "golang": "go", "c++": "cpp", "cs": "csharp", "c#": "csharp",
    "text": "none", "txt": "none", "": "",
}


def esc(t):
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def esc_attr(t):
    return esc(t).replace('"', "&quot;")


def cdata(body):
    return "<![CDATA[" + body.replace("]]>", "]]]]><![CDATA[>") + "]]>"


def normalize_lang(info):
    toks = info.split()
    tok = toks[0].lower() if toks else ""
    return LANG_ALIASES.get(tok, tok)


def code_macro(body, lang):
    param = f'<ac:parameter ac:name="language">{esc(lang)}</ac:parameter>' if lang else ""
    return (
        '<ac:structured-macro ac:name="code" ac:schema-version="1">'
        + param
        + f"<ac:plain-text-body>{cdata(body)}</ac:plain-text-body>"
        + "</ac:structured-macro>"
    )


INLINE_RE = re.compile(
    r"(?P<code>`+)(?P<codeinner>[^`\n]+?)(?P=code)"
    r"|\\(?P<escchar>[\\`*_{}\[\]()#+\-.!|~<>])"
    r'|!\[(?P<alt>[^\]]*)\]\((?P<imgsrc>[^)\s]+)(?:\s+"[^"]*")?\)'
    r"|<(?P<autourl>https?://[^>\s]+)>"
    r'|\[(?P<ltext>[^\]]+)\]\((?P<lurl>[^)\s]+)(?:\s+"[^"]*")?\)'
    r"|\*\*(?P<btext>\S(?:[^*]*?\S)?)\*\*"
    r"|__(?P<b2text>\S(?:[^_]*?\S)?)__"
    r"|~~(?P<stext>\S(?:.*?\S)?)~~"
    r"|\*(?P<etext>\S(?:[^*]*?\S)?)\*"
    r"|(?<![\w\\])_(?P<e2text>\S(?:[^_]*?\S)?)_(?!\w)"
)

FENCE_RE = re.compile(r"^ {0,3}(?P<fence>```+|~~~+)[ \t]*(?P<info>[^`]*)$")
HEADING_RE = re.compile(r"^ {0,3}(?P<level>#{1,6})[ \t]+(?P<text>.*?)[ \t]*#*[ \t]*$")
HR_RE = re.compile(r"^ {0,3}(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$")
QUOTE_RE = re.compile(r"^ {0,3}>")
TABLE_SEP_RE = re.compile(r"^[ \t]*\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)+\|?[ \t]*$")
LIST_ITEM_RE = re.compile(r"^(?P<indent>[ \t]*)(?P<marker>[-*+]|\d{1,9}[.)])[ \t]+(?P<text>.*)$")


def inline(text, warns, notes):
    out, pos = [], 0
    for m in INLINE_RE.finditer(text):
        if m.start() > pos:
            out.append(esc(text[pos:m.start()]))
        pos = m.end()
        if m.group("code") is not None:
            out.append("<code>" + esc(m.group("codeinner")) + "</code>")
        elif m.group("escchar") is not None:
            out.append(esc(m.group("escchar")))
        elif m.group("imgsrc") is not None:
            label = m.group("alt") or m.group("imgsrc")
            warns.append("image skipped (attachments out of scope): " + label)
            notes.append("image skipped (attachments out of scope): " + label)
        elif m.group("autourl") is not None:
            url = m.group("autourl")
            out.append('<a href="' + esc_attr(url) + '">' + esc(url) + "</a>")
        elif m.group("lurl") is not None:
            out.append('<a href="' + esc_attr(m.group("lurl")) + '">' + inline(m.group("ltext"), warns, notes) + "</a>")
        elif m.group("btext") is not None:
            out.append("<strong>" + inline(m.group("btext"), warns, notes) + "</strong>")
        elif m.group("b2text") is not None:
            out.append("<strong>" + inline(m.group("b2text"), warns, notes) + "</strong>")
        elif m.group("stext") is not None:
            out.append("<s>" + inline(m.group("stext"), warns, notes) + "</s>")
        elif m.group("etext") is not None:
            out.append("<em>" + inline(m.group("etext"), warns, notes) + "</em>")
        elif m.group("e2text") is not None:
            out.append("<em>" + inline(m.group("e2text"), warns, notes) + "</em>")
    if pos < len(text):
        out.append(esc(text[pos:]))
    return "".join(out)


def notes_html(notes):
    return "".join("<!-- " + note + " -->" for note in notes)


def split_row(line):
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|") and not s.endswith("\\|"):
        s = s[:-1]
    cells = re.split(r"(?<!\\)\|", s)
    return [c.replace("\\|", "|").strip() for c in cells]


def parse_aligns(sep_line):
    aligns = []
    for c in split_row(sep_line):
        left, right = c.startswith(":"), c.endswith(":")
        if left and right:
            aligns.append("center")
        elif left:
            aligns.append("left")
        elif right:
            aligns.append("right")
        else:
            aligns.append("")
    return aligns


def render_table(header, aligns, rows, warns, notes):
    def cell(tag, text, align):
        style = f' style="text-align: {align};"' if align else ""
        return f"<{tag}{style}>{inline(text, warns, notes)}</{tag}>"

    parts = ["<table><tbody>"]
    parts.append(
        "<tr>"
        + "".join(cell("th", h, aligns[j] if j < len(aligns) else "") for j, h in enumerate(header))
        + "</tr>"
    )
    for row in rows:
        parts.append(
            "<tr>"
            + "".join(cell("td", c, aligns[j] if j < len(aligns) else "") for j, c in enumerate(row))
            + "</tr>"
        )
    parts.append("</tbody></table>")
    return "".join(parts)


def parse_list(lines, i, warns, notes):
    n = len(lines)
    items = []
    task_noted = False
    while i < n:
        line = lines[i]
        m = LIST_ITEM_RE.match(line)
        if m:
            text = m.group("text")
            if not task_noted and (text.startswith("[ ] ") or text.lower().startswith("[x] ")):
                warns.append("task list checkboxes rendered as literal text")
                task_noted = True
            indent = len(m.group("indent").replace("\t", "  "))
            items.append([indent, m.group("marker")[0].isdigit(), text])
            i += 1
        elif line.strip() and items and line[0] in " \t":
            items[-1][2] += "\x01" + line.strip()
            i += 1
        else:
            break
    stack, leveled = [], []
    for indent, ordered, text in items:
        if not stack or indent > stack[-1]:
            stack.append(indent)
        else:
            while len(stack) > 1 and indent < stack[-1]:
                stack.pop()
            if indent != stack[-1]:
                stack[-1] = indent
        level = len(stack) - 1
        if level >= MAX_LIST_DEPTH:
            warns.append("list nested deeper than 3 levels; clamped to 3")
            level = MAX_LIST_DEPTH - 1
        leveled.append((level, ordered, text))

    def build(idx, level):
        tag = "ol" if leveled[idx][1] else "ul"
        parts = [f"<{tag}>"]
        while idx < len(leveled):
            lvl, ordered, text = leveled[idx]
            if lvl < level:
                break
            if lvl == level:
                parts.append("<li>" + inline(text, warns, notes).replace("\x01", "<br/>"))
                if idx + 1 < len(leveled) and leveled[idx + 1][0] > level:
                    sub, idx = build(idx + 1, level + 1)
                    parts.append(sub)
                else:
                    idx += 1
                parts.append("</li>")
            else:
                break
        parts.append(f"</{tag}>")
        return "".join(parts), idx

    html, _ = build(0, 0)
    return html, i


def unknown_notes(text):
    notes = []
    if re.search(r"\[\^[^\]]+\]", text):
        notes.append("markdown footnote rendered as plain text (not supported)")
    if re.search(r"\[[^\]]+\][ \t]*\[[^\]]*\]", text):
        notes.append("reference-style link rendered as plain text (not supported)")
    if re.search(r"</?[A-Za-z][^>]*>", text):
        notes.append("raw HTML escaped as plain text")
    return notes


def is_block_start(line):
    if re.match(r"^ {0,3}(?:```+|~~~+)", line):
        return True
    if re.match(r"^ {0,3}#{1,6}[ \t]", line):
        return True
    if HR_RE.match(line):
        return True
    if QUOTE_RE.match(line):
        return True
    if LIST_ITEM_RE.match(line):
        return True
    return False


def parse_blocks(md, warns):
    lines = md.split("\n")
    n, i = len(lines), 0
    out = []
    while i < n:
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        m = FENCE_RE.match(line)
        if m:
            fence_char, flen = m.group("fence")[0], len(m.group("fence"))
            closer = re.compile(r"^ {0,3}" + re.escape(fence_char) + "{" + str(flen) + r",}[ \t]*$")
            j = i + 1
            buf = []
            while j < n and not closer.match(lines[j]):
                buf.append(lines[j])
                j += 1
            if j >= n:
                warns.append("unclosed fenced code block (converted to end of document)")
            out.append(code_macro("\n".join(buf), normalize_lang(m.group("info").strip())))
            i = min(j + 1, n)
            continue
        m = HEADING_RE.match(line)
        if m:
            text = m.group("text").strip()
            if text:
                lvl = len(m.group("level"))
                inotes = []
                out.append(f"<h{lvl}>{inline(text, warns, inotes)}</h{lvl}>" + notes_html(inotes))
            else:
                warns.append("empty heading skipped")
            i += 1
            continue
        if HR_RE.match(line):
            out.append("<hr/>")
            i += 1
            continue
        if QUOTE_RE.match(line):
            buf = []
            while i < n:
                cur = lines[i]
                if QUOTE_RE.match(cur):
                    buf.append(re.sub(r"^ {0,3}>[ ]?", "", cur))
                    i += 1
                elif cur.strip() and not is_block_start(cur):
                    buf.append(cur)
                    i += 1
                else:
                    break
            inner = parse_blocks("\n".join(buf), warns)
            out.append("<blockquote>" + "".join(x for x in inner if x) + "</blockquote>")
            continue
        if "|" in line and i + 1 < n and TABLE_SEP_RE.match(lines[i + 1]):
            header = split_row(line)
            aligns = parse_aligns(lines[i + 1])
            i += 2
            rows = []
            while i < n and lines[i].strip() and "|" in lines[i]:
                rows.append(split_row(lines[i]))
                i += 1
            inotes = []
            out.append(render_table(header, aligns, rows, warns, inotes) + notes_html(inotes))
            continue
        if LIST_ITEM_RE.match(line):
            inotes = []
            block, i = parse_list(lines, i, warns, inotes)
            out.append(block + notes_html(inotes))
            continue
        buf = [line]
        i += 1
        while i < n and lines[i].strip() and not is_block_start(lines[i]):
            if "|" in lines[i] and i + 1 < n and TABLE_SEP_RE.match(lines[i + 1]):
                break
            buf.append(lines[i])
            i += 1
        notes = unknown_notes("\n".join(buf))
        inotes = []
        para = "<p>" + "<br/>".join(inline(l.rstrip(), warns, inotes) for l in buf if l.strip()) + "</p>"
        out.append(para + notes_html(notes + inotes))
    return out


def convert(src, warns):
    src = re.sub(r"<!--.*?-->", "", src, flags=re.S)
    blocks = parse_blocks(src, warns)
    return "\n".join(b for b in blocks if b)


def main():
    args = sys.argv[1:]
    if args:
        with open(args[0], encoding="utf-8") as f:
            src = f.read()
    else:
        src = sys.stdin.read()
    warns = []
    sys.stdout.write(convert(src, warns) + "\n")
    for w in warns:
        sys.stderr.write("convert: warning: " + w + "\n")


if __name__ == "__main__":
    main()
PYCONVERT
)" "$@"
