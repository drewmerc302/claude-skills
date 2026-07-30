---
name: md2pdf
description: Convert a Markdown file to a print-ready PDF with visual layout verification and a second-opinion review pass. Use this skill whenever the user asks to convert .md to PDF, "make a PDF of this markdown", "print this doc", "export to PDF", generate a print-friendly version of notes, knowledge files, or reference docs — especially when the markdown contains tables, code blocks, or ASCII diagrams that need careful layout. Also trigger when the user wants to "package" or "share" a markdown doc as a polished PDF artifact. Don't skip the verification + advisor steps — they're the whole point of the skill.
---

# md2pdf

Convert one or more Markdown files to print-ready PDFs, verify the layout visually, fix any rendering problems found, then hand off to an advisor for a second-opinion approval before reporting completion to the user.

The script lives at `scripts/md2pdf.py` (next to this file). It uses python-markdown → styled HTML → headless Chrome to produce a Letter-size PDF with page numbers, well-behaved tables, monospace code, and a tuned set of `page-break` rules. Don't rewrite it from scratch — invoke it.

## Workflow

Follow the steps in order. The verification and advisor steps exist because Chrome's PDF rendering hides issues that look fine in plain markdown — orphaned headings, tables clipped at a page break, lists collapsed into a paragraph because the source forgot a blank line, ASCII diagrams wrapping ugly. Skipping them defeats the skill.

### 1. Resolve the input file

The user usually says something like "convert X to PDF" or "find Y_knowledge.md and turn it into a PDF". Locate the file:

- If they gave a full path, use it.
- If they gave a pattern (e.g. "Foo_knowledge.md in the Foo dir"), `find` it.
- If multiple files are requested in one turn, process each one in sequence using the same workflow.

Decide the output path: same directory as the input, same basename, `.pdf` extension. Don't write to `/tmp` unless the user asked you to.

### 2. Ensure dependencies

The script depends on:

- `python3` with the `markdown` package (`uv pip install --system markdown` if missing — check with `python3 -c "import markdown"` first).
- Google Chrome or Chromium installed in a standard location. The script auto-detects.

If `markdown` is missing, install it before running the script — don't try a different rendering path. The CSS in the script is tuned for python-markdown's specific HTML output (tables, fenced_code, sane_lists extensions). Substituting another renderer breaks the layout assumptions.

### 3. Generate the PDF

Run the bundled script:

```bash
python3 ~/.claude/skills/md2pdf/scripts/md2pdf.py <input.md> <output.pdf>
```

The script handles the rest: preprocesses the markdown to add blank lines before lists that follow paragraph text (a common source-formatting issue), renders to HTML with print-tuned CSS, calls Chrome headless with `--print-to-pdf`, and cleans up the intermediate `.html` file.

### 4. Verify visually — required

Get the page count, then read the PDF as images and inspect each page. The Read tool can extract PDF pages as visual content:

```bash
/usr/bin/mdls -name kMDItemNumberOfPages <output.pdf>
```

Then use the Read tool with the `pages` parameter to view the rendered output (the tool supports up to 20 pages per request — split larger PDFs into ranges).

Things to look for:

- **Overlapping text** — usually a sign that a code block or wide table overflowed the page width.
- **Headings stranded at the bottom of a page** with their content on the next page. The CSS uses `page-break-after: avoid` on h1–h4 but Chrome doesn't always honor it for very tight pages.
- **Tables clipped at a page break** without the header row repeating, or a single row split across two pages. `thead` is set to `display: table-header-group` and `tr` has `page-break-inside: avoid`, so this should be rare — but verify.
- **Lists rendered as run-on paragraphs**. The preprocessor handles the common case (a list following a non-blank, non-list line at top level), but indented lists or weird author formatting can still collapse.
- **Mostly empty pages** in the middle of the document. Acceptable for the last page; a red flag mid-document.
- **ASCII diagrams wrapping or breaking columns.** They render inside `<pre>` so the monospace + `white-space: pre-wrap` should hold them together, but long lines can still wrap.
- **Code or token strings broken across lines** in narrow table cells (e.g. `V100524797` / `8)`). Usually cosmetic and acceptable; only worth fixing if it's a critical identifier.

If you find a real issue, fix it in the most appropriate place (script CSS, preprocessor, or — last resort — the source markdown if the author left out structural cues), regenerate, and re-verify. Don't ship a PDF with a layout regression just because the first attempt almost worked.

### 5. Second-opinion review — required

Once your own verification passes, get an independent read before handing off.
Dispatch a subagent (`Agent`, `subagent_type: "general-purpose"`, `model: "sonnet"`)
pointed at the output PDF, told to read the pages as images and judge only one
question: **is this print-ready?** Give it the checklist from step 4 and nothing
about how the PDF was produced — the point is a reviewer without the bias of
having just chosen the rendering parameters.

If it flags blocking issues, fix them and re-verify before handing off. Non-blocking
notes (e.g. "you could also delete the intermediate HTML") should be addressed if
cheap but don't require another review round.

### 6. Hand off

Report the output path(s), page count, and file size in a short summary. Don't restate the workflow you ran — the user already knows. Just tell them what's ready.

## Why this is structured this way

The verification + advisor pattern exists because PDF rendering is a one-shot batch operation that produces output the user will physically print or share. There's no live preview, no edit-on-the-fly. A misrendered table is a misrendered table forever, unless someone notices before the file leaves the machine.

The advisor isn't a rubber stamp — they look at the same rendered pages you do, but without the bias of having just chosen the rendering parameters. That's worth one extra tool call per document.

## Failure modes to avoid

- **Don't substitute pandoc, weasyprint, or wkhtmltopdf** if the user has Chrome installed. The bundled CSS is tuned for the Chrome `--print-to-pdf` rendering pipeline; other renderers produce visibly different layout.
- **Don't skip verification** because "the script worked last time" or "the file is small". Layout issues are content-dependent, not size-dependent — a 2-page doc with one wide table is more likely to break than a 20-page doc of plain prose.
- **Don't auto-fix the source markdown** without telling the user. The preprocessor handles structural omissions in memory only; if you find an issue that requires editing `*.md` itself (e.g., a malformed table), surface it instead of silently rewriting their file.
- **Don't loop on minor cosmetic issues** (a hyphenated identifier in a narrow column, a 1-line orphan at the bottom of an otherwise full page). Note them, ship, and let the user decide.
