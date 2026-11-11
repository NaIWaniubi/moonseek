#!/usr/bin/env python3
"""Render docs/proposal.md to a one-page A4 PDF.

The contest form wants exactly one page. Rather than eyeball it, this renders the
markdown through headless Chrome and then asserts the PDF has one page, failing
loudly if a paragraph grew past the margin. Run it after any edit to proposal.md.

Usage: build-proposal.py [--browser PATH] [--keep-html]
"""

import argparse
import html
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "docs", "proposal.md")
TARGET = os.path.join(ROOT, "docs", "proposal.pdf")

BROWSERS = [
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
    "google-chrome",
    "chromium",
]

# A4 with the body scaled so the whole proposal fits one page. The font stack
# puts Microsoft YaHei first: the text is Chinese and the default serif has no
# CJK coverage in a headless render.
CSS = """
@page { size: A4; margin: 9mm 11mm 8mm 11mm; }
* { box-sizing: border-box; }
body { font-family: "Microsoft YaHei", "MS YaHei", SimHei, sans-serif;
       font-size: 7.9pt; line-height: 1.31; color: #111; margin: 0; }
h1 { font-size: 11.5pt; margin: 0 0 5px 0; text-align: center; letter-spacing: .5px; }
p { margin: 0 0 3.2px 0; text-align: justify; }
p.blank { margin: 0; height: 2px; }
strong { font-weight: 700; color: #000; }
code { font-family: Consolas, "Courier New", monospace; font-size: 7.2pt;
       background: #f2f4f7; padding: 0 2px; border-radius: 2px; }
ul { margin: 0 0 3.2px 0; padding-left: 13px; }
li { margin: 0 0 2.2px 0; text-align: justify; }
a { color: #1a4fb4; text-decoration: none; }
"""


def find_browser(explicit):
    if explicit:
        return explicit
    for candidate in BROWSERS:
        if os.path.isabs(candidate):
            if os.path.exists(candidate):
                return candidate
        else:
            found = shutil.which(candidate)
            if found:
                return found
    raise SystemExit("no headless browser found; pass --browser PATH")


def inline(text):
    """Escape HTML, then apply the two inline forms the proposal uses."""
    out = html.escape(text, quote=False)
    out = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", out)
    out = re.sub(r"`(.+?)`", r"<code>\1</code>", out)
    return out


def to_html(markdown):
    parts = []
    in_list = False
    for raw in markdown.splitlines():
        line = raw.rstrip()
        if not line.strip():
            if in_list:
                parts.append("</ul>")
                in_list = False
            parts.append('<p class="blank"></p>')
            continue
        if line.startswith("# "):
            if in_list:
                parts.append("</ul>")
                in_list = False
            parts.append("<h1>%s</h1>" % inline(line[2:]))
            continue
        if line.startswith("- "):
            if not in_list:
                parts.append("<ul>")
                in_list = True
            parts.append("<li>%s</li>" % inline(line[2:]))
            continue
        if in_list:
            parts.append("</ul>")
            in_list = False
        parts.append("<p>%s</p>" % inline(line))
    if in_list:
        parts.append("</ul>")
    body = "\n".join(parts)
    return (
        "<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\">"
        "<title>moonseek 项目申报书</title><style>%s</style></head><body>\n%s\n"
        "</body></html>\n" % (CSS, body)
    )


def page_count(pdf_bytes):
    return len(re.findall(rb"/Type\s*/Page[^s]", pdf_bytes))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--browser")
    parser.add_argument("--keep-html", action="store_true")
    args = parser.parse_args()

    browser = find_browser(args.browser)
    with open(SOURCE, encoding="utf-8") as handle:
        markdown = handle.read()
    document = to_html(markdown)

    workdir = tempfile.mkdtemp(prefix="moonseek-proposal-")
    html_path = os.path.join(workdir, "proposal.html")
    pdf_path = os.path.join(workdir, "proposal.pdf")
    with open(html_path, "w", encoding="utf-8") as handle:
        handle.write(document)

    command = [
        browser,
        "--headless=new",
        "--disable-gpu",
        "--no-sandbox",
        "--no-pdf-header-footer",
        "--print-to-pdf=" + pdf_path,
        "file:///" + html_path.replace("\\", "/"),
    ]
    result = subprocess.run(command, capture_output=True, timeout=180)
    if not os.path.exists(pdf_path):
        sys.stderr.write(result.stderr.decode("utf-8", "replace")[-2000:])
        raise SystemExit("browser did not produce a PDF")

    with open(pdf_path, "rb") as handle:
        pdf = handle.read()
    pages = page_count(pdf)
    print("rendered %d bytes, %d page(s)" % (len(pdf), pages))
    if pages != 1:
        if args.keep_html:
            kept = os.path.join(ROOT, "docs", "proposal.html")
            shutil.copy(html_path, kept)
            print("html kept at %s" % kept)
        raise SystemExit(
            "proposal is %d pages; the form wants one. Shorten the text or the "
            "CSS font size in tools/build-proposal.py." % pages
        )

    shutil.copy(pdf_path, TARGET)
    print("wrote %s" % TARGET)
    if args.keep_html:
        shutil.copy(html_path, os.path.join(ROOT, "docs", "proposal.html"))
    if not args.keep_html:
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    main()
