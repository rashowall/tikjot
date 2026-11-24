#!/usr/bin/env python3
"""Release notes for scripts/release.sh — release-notes/<version>.md (English) + <version>.sk.md (Slovak).

  release-notes.py check   <version>               both files exist, no empty section
  release-notes.py html    <file.md>               print the small self-contained HTML Sparkle shows
  release-notes.py github  <version> <out.md>      English notes for the GitHub release body (comments removed)
  release-notes.py appcast <appcast.xml>           put <description xml:lang="en"> + <description xml:lang="sk">
                                                   into every item that has notes in release-notes/

Notes format (short, user-facing): a one-line summary, then "## New" / "## Fixed" with "- " bullets.
Inline: **bold**, *italic*, [text](https://…). HTML comments (<!-- … -->) are dropped.
Only the standard library — runs on the macOS system python3.

The appcast is edited as text, item by item: only <description> elements change, everything else (enclosure,
sparkle:edSignature — which covers the DMG, not the feed) stays byte for byte. Sparkle 2 picks the description whose
xml:lang matches the user's preferred languages (SUAppcast.m bestNodeInNodes); with several, each needs xml:lang.
"""
import html
import os
import re
import sys
import xml.dom.minidom

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOTES_DIR = os.path.join(ROOT, "release-notes")
LANGS = [("en", ""), ("sk", ".sk")]   # (xml:lang, file suffix); English first = the fallback

# Sparkle injects the body font/size and a dark-mode colour sheet; this only adds spacing and tells WebKit both
# schemes are fine. No fixed colours.
CSS = ("html{color-scheme:light dark}"
       "body{font:13px -apple-system,system-ui,sans-serif;line-height:1.4;margin:0 2px}"
       "p{margin:0 0 8px}h3{font-size:13px;font-weight:600;margin:10px 0 4px}"
       "ul{margin:0 0 6px;padding-left:18px}li{margin:2px 0}")


def die(msg):
    sys.stderr.write("error: %s\n" % msg)
    sys.exit(1)


def notes_path(version, suffix):
    return os.path.join(NOTES_DIR, "%s%s.md" % (version, suffix))


def read_markdown(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    return re.sub(r"<!--.*?-->", "", text, flags=re.S)


def inline(text):
    out = html.escape(text, quote=True)
    out = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", r'<a href="\2">\1</a>', out)
    out = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", out)
    out = re.sub(r"(?<![*\w])\*(?!\s)(.+?)(?<!\s)\*(?![*\w])", r"<em>\1</em>", out)
    return out


def blocks(markdown):
    """[(kind, payload)] — ("h", text) / ("p", text) / ("ul", [items])."""
    result, para = [], []

    def flush():
        if para:
            result.append(("p", " ".join(para)))
            para.clear()

    for raw in markdown.splitlines():
        line = raw.strip()
        if not line:
            flush()
        elif line.startswith("#"):
            flush()
            result.append(("h", line.lstrip("#").strip()))
        elif re.match(r"[-*] ", line):
            flush()
            if result and result[-1][0] == "ul":
                result[-1][1].append(line[2:].strip())
            else:
                result.append(("ul", [line[2:].strip()]))
        elif raw.startswith(("  ", "\t")) and result and result[-1][0] == "ul" and not para:
            result[-1][1][-1] += " " + line          # continuation of a bullet
        else:
            para.append(line)
    flush()
    return result


def empty_sections(bl):
    """Headings followed by nothing (another heading or the end)."""
    return [text for i, (kind, text) in enumerate(bl)
            if kind == "h" and (i + 1 == len(bl) or bl[i + 1][0] == "h")]


def to_html(markdown):
    parts = ["<style>%s</style>" % CSS]
    bl = blocks(markdown)
    empty = set(empty_sections(bl))
    for kind, payload in bl:
        if kind == "h" and payload in empty:
            continue                                  # never show a bare heading (check() refuses it anyway)
        if kind == "h":
            parts.append("<h3>%s</h3>" % inline(payload))
        elif kind == "p":
            parts.append("<p>%s</p>" % inline(payload))
        else:
            parts.append("<ul>%s</ul>" % "".join("<li>%s</li>" % inline(i) for i in payload))
    return "\n".join(parts)


def check(version):
    for lang, suffix in LANGS:
        path = notes_path(version, suffix)
        rel = os.path.relpath(path, ROOT)
        if not os.path.isfile(path):
            die("%s missing — every release needs release-notes/%s.md (English) and %s.sk.md (Slovak)"
                % (rel, version, version))
        bl = blocks(read_markdown(path))
        if not bl:
            die("%s is empty" % rel)
        empty = empty_sections(bl)
        if empty:
            die("%s: section \"%s\" has no bullets — fill it or remove the heading" % (rel, empty[0]))


def github(version, out):
    md = read_markdown(notes_path(version, ""))
    md = re.sub(r"\n{3,}", "\n\n", md).strip() + "\n"
    with open(out, "w", encoding="utf-8") as f:
        f.write(md)


def description_xml(lang, version, suffix):
    body = to_html(read_markdown(notes_path(version, suffix)))
    if "]]>" in body:
        die("release notes for %s contain ']]>'" % version)
    return '<description xml:lang="%s"><![CDATA[%s]]></description>' % (lang, body)


ITEM_RE = re.compile(r"(?P<indent>[ \t]*)<item>.*?</item>", re.S)
DESC_RE = re.compile(r"[ \t]*<description\b[^>]*?(?:/>|>.*?</description>)[ \t]*\n?", re.S)


def appcast(path):
    with open(path, encoding="utf-8") as f:
        feed = f.read()
    done = []

    def fix_item(m):
        item, indent = m.group(0), m.group("indent")
        v = re.search(r"<sparkle:shortVersionString>\s*([^<\s]+)\s*</sparkle:shortVersionString>", item)
        if not v or not all(os.path.isfile(notes_path(v.group(1), s)) for _, s in LANGS):
            return item                               # no notes in the repo: leave the item exactly as it is
        version = v.group(1)
        item = DESC_RE.sub("", item)
        child = indent + "    "
        descs = "".join("%s%s\n" % (child, description_xml(lang, version, s)) for lang, s in LANGS)
        # right after <title>…</title> (where generate_appcast puts it); else just before </item>
        t = re.search(r"</title>[ \t]*\n", item)
        if t:
            item = item[:t.end()] + descs + item[t.end():]
        else:
            item = item[:-len("</item>")].rstrip(" \t") + descs + indent + "</item>"
        done.append(version)
        return item

    feed = ITEM_RE.sub(fix_item, feed)
    xml.dom.minidom.parseString(feed.encode("utf-8"))   # still well-formed, or stop here
    with open(path, "w", encoding="utf-8") as f:
        f.write(feed)
    print("    release notes (en, sk) in the appcast for: %s" % (", ".join(done) or "none"))


def main(argv):
    if len(argv) == 3 and argv[1] == "check":
        check(argv[2])
    elif len(argv) == 3 and argv[1] == "html":
        print(to_html(read_markdown(argv[2])))
    elif len(argv) == 4 and argv[1] == "github":
        github(argv[2], argv[3])
    elif len(argv) == 3 and argv[1] == "appcast":
        appcast(argv[2])
    else:
        die("usage: release-notes.py check <ver> | html <file.md> | github <ver> <out.md> | appcast <appcast.xml>")


if __name__ == "__main__":
    main(sys.argv)
