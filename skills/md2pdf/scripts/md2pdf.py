#!/usr/bin/env python3
"""Markdown -> styled HTML -> print-ready PDF via headless Chrome.

Usage: python md2pdf.py <input.md> <output.pdf>

Renders Letter-size PDF tuned for technical docs with tables, code blocks,
and ASCII diagrams. Cleans up intermediate HTML when done.
"""

import argparse
import subprocess
import sys
from pathlib import Path

import markdown

CSS = """
@page {
  size: Letter;
  margin: 0.6in 0.55in 0.7in 0.55in;
  @bottom-center { content: counter(page) " / " counter(pages); font-size: 9pt; color: #666; }
}
html { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
body {
  font-family: -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif;
  font-size: 9.5pt;
  line-height: 1.38;
  color: #1a1a1a;
  margin: 0;
  padding: 0;
}
h1 { font-size: 18pt; margin: 0 0 0.2em; border-bottom: 2px solid #333; padding-bottom: 4px; page-break-after: avoid; }
h2 { font-size: 13.5pt; margin: 1.1em 0 0.35em; border-bottom: 1px solid #bbb; padding-bottom: 2px; page-break-after: avoid; }
h3 { font-size: 11.5pt; margin: 0.9em 0 0.3em; page-break-after: avoid; }
h4 { font-size: 10.5pt; margin: 0.7em 0 0.25em; page-break-after: avoid; }
p { margin: 0.35em 0 0.5em; orphans: 3; widows: 3; }
ul, ol { margin: 0.3em 0 0.55em; padding-left: 1.4em; }
li { margin: 0.1em 0; }
blockquote {
  margin: 0.5em 0;
  padding: 0.3em 0.8em;
  border-left: 3px solid #999;
  color: #444;
  background: #f6f6f6;
  font-style: italic;
  page-break-inside: avoid;
}
code {
  font-family: "SF Mono", Menlo, Consolas, monospace;
  font-size: 0.86em;
  background: #f1f1f1;
  padding: 0 3px;
  border-radius: 2px;
  word-break: break-word;
}
pre {
  font-family: "SF Mono", Menlo, Consolas, monospace;
  font-size: 7.8pt;
  line-height: 1.25;
  background: #f6f8fa;
  border: 1px solid #ddd;
  border-radius: 4px;
  padding: 8px 10px;
  overflow-x: hidden;
  white-space: pre-wrap;
  word-break: break-word;
  page-break-inside: avoid;
}
pre code { background: none; padding: 0; font-size: inherit; }
table {
  border-collapse: collapse;
  width: 100%;
  margin: 0.5em 0 0.7em;
  font-size: 8.8pt;
  page-break-inside: auto;
  table-layout: auto;
}
thead { display: table-header-group; }
tr { page-break-inside: avoid; }
th, td {
  border: 1px solid #c8c8c8;
  padding: 4px 6px;
  vertical-align: top;
  text-align: left;
  word-break: normal;
  overflow-wrap: break-word;
}
th { background: #ececec; font-weight: 600; }
hr { border: 0; border-top: 1px solid #ccc; margin: 1em 0; }
a { color: #1a4ea0; text-decoration: none; word-break: break-word; }
strong { font-weight: 700; }
em { font-style: italic; }
"""


def preprocess(text: str) -> str:
    """Insert blank line before list items that follow a text paragraph.

    python-markdown's `sane_lists` requires a blank line before a list, otherwise
    the bullet/number is treated as inline text and the whole list collapses into
    a paragraph. Authors routinely forget. Auto-inserting the blank line keeps
    the rendered output faithful to authorial intent.
    """
    out: list[str] = []
    lines = text.splitlines()
    for ln in lines:
        stripped = ln.lstrip()
        is_list = stripped.startswith(("- ", "* ", "+ ")) or (
            len(stripped) > 2
            and stripped[0].isdigit()
            and stripped[1:3] in (". ", ") ")
        )
        if is_list and out:
            prev = out[-1]
            prev_stripped = prev.lstrip()
            prev_is_list = prev_stripped.startswith(("- ", "* ", "+ "))
            prev_is_blank = prev.strip() == ""
            prev_is_indented = prev.startswith(("    ", "\t"))
            if not (prev_is_list or prev_is_blank or prev_is_indented):
                out.append("")
        out.append(ln)
    return "\n".join(out)


def find_chrome() -> str:
    for path in (
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
        "/usr/bin/google-chrome",
        "/usr/bin/chromium",
        "/usr/bin/chromium-browser",
    ):
        if Path(path).exists():
            return path
    sys.exit(
        "error: no Chrome/Chromium binary found. Install Chrome or set CHROME env var."
    )


def render(md_path: Path, pdf_path: Path) -> None:
    text = preprocess(md_path.read_text())
    html_body = markdown.markdown(
        text,
        extensions=["tables", "fenced_code", "sane_lists", "attr_list", "toc"],
        output_format="html5",
    )
    full_html = (
        f'<!doctype html><html><head><meta charset="utf-8"><title>{md_path.stem}</title>'
        f"<style>{CSS}</style></head><body>{html_body}</body></html>"
    )
    html_path = pdf_path.with_suffix(".html")
    html_path.write_text(full_html)
    try:
        chrome = find_chrome()
        cmd = [
            chrome,
            "--headless=new",
            "--disable-gpu",
            "--no-pdf-header-footer",
            "--no-sandbox",
            f"--print-to-pdf={pdf_path}",
            f"file://{html_path.resolve()}",
        ]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
        if r.returncode != 0:
            sys.stderr.write(r.stderr)
            sys.exit(r.returncode)
    finally:
        html_path.unlink(missing_ok=True)
    print(f"wrote {pdf_path} ({pdf_path.stat().st_size} bytes)")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("md", help="Input markdown file")
    ap.add_argument("pdf", help="Output PDF path")
    a = ap.parse_args()
    render(Path(a.md), Path(a.pdf))
