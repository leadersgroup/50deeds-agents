#!/usr/bin/env python3
"""Turn a downloaded case folder into text you can read and page images you can look at.

    python3 extract_case.py <case_dir> [--out <dir>] [--dpi 150] [--all-pages]

For every PDF, Word file and image under <case_dir> (recursively):
  * PDF  -> text of each page. Pages with little or no text (scans, signed or
            recorded copies) are also rendered to PNG for vision.
  * DOCX -> paragraphs and tables as text.
  * PNG/JPG/TIFF -> listed for vision as they are.

Output (default <case_dir>/_extracted):
  <name>.txt        one text file per document, pages marked "=== page N ==="
  renders/<name>/p001.png ...
  manifest.json     every document, its text file and its page images

Only files that really exist are listed. Names are made filesystem-safe (no
spaces), so paths can be passed straight to other tools. Uses the
preinstalled pymupdf and python-docx; installs nothing.
"""
import argparse
import json
import re
import sys
from pathlib import Path

MIN_TEXT_CHARS = 40          # less than this on a page = treat as a scan
PDF = {".pdf"}
DOCX = {".docx"}
IMAGES = {".png", ".jpg", ".jpeg", ".tif", ".tiff", ".webp"}


def safe(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", name).strip("_") or "file"


def unique(base: str, used: set) -> str:
    name, n = base, 2
    while name in used:
        name, n = f"{base}_{n}", n + 1
    used.add(name)
    return name


def do_pdf(path: Path, out: Path, key: str, dpi: int, all_pages: bool) -> dict:
    import pymupdf
    rec = {"source": str(path), "type": "pdf", "pages": 0, "text_file": None,
           "scanned_pages": [], "images": [], "error": None}
    try:
        doc = pymupdf.open(path)
    except Exception as e:  # encrypted, corrupt, not really a PDF
        rec["error"] = f"cannot open: {type(e).__name__}: {e}"
        return rec
    rec["pages"] = doc.page_count
    parts = []
    for i, page in enumerate(doc, start=1):
        text = page.get_text("text").strip()
        parts.append(f"=== page {i} ===\n{text or '[no text layer]'}")
        if all_pages or len(text) < MIN_TEXT_CHARS:
            if len(text) < MIN_TEXT_CHARS:
                rec["scanned_pages"].append(i)
            img_dir = out / "renders" / key
            img_dir.mkdir(parents=True, exist_ok=True)
            img = img_dir / f"p{i:03d}.png"
            try:
                page.get_pixmap(dpi=dpi).save(img)
            except Exception as e:
                rec["error"] = f"page {i} render failed: {type(e).__name__}: {e}"
                continue
            if img.is_file() and img.stat().st_size > 0:
                rec["images"].append(str(img.resolve()))
    if doc.page_count == 0:
        rec["error"] = "PDF has no pages"
    txt = out / f"{key}.txt"
    txt.write_text("\n\n".join(parts), encoding="utf-8")
    rec["text_file"] = str(txt.resolve())
    return rec


def do_docx(path: Path, out: Path, key: str) -> dict:
    import docx
    rec = {"source": str(path), "type": "docx", "text_file": None, "images": [], "error": None}
    try:
        d = docx.Document(str(path))
    except Exception as e:
        rec["error"] = f"cannot open: {type(e).__name__}: {e}"
        return rec
    lines = [p.text for p in d.paragraphs]
    for t_i, table in enumerate(d.tables, start=1):
        lines.append(f"\n=== table {t_i} ===")
        for row in table.rows:
            lines.append(" | ".join(c.text.strip() for c in row.cells))
    for s_i, section in enumerate(d.sections, start=1):
        for label, part in (("header", section.header), ("footer", section.footer)):
            text = "\n".join(p.text for p in part.paragraphs if p.text.strip())
            if text:
                lines.append(f"\n=== section {s_i} {label} ===\n{text}")
    txt = out / f"{key}.txt"
    txt.write_text("\n".join(lines), encoding="utf-8")
    rec["text_file"] = str(txt.resolve())
    return rec


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("case_dir")
    ap.add_argument("--out", default="")
    ap.add_argument("--dpi", type=int, default=150)
    ap.add_argument("--all-pages", action="store_true", help="render every PDF page, not only scans")
    a = ap.parse_args()

    case = Path(a.case_dir).expanduser().resolve()
    if not case.is_dir():
        print(f"ERROR: not a folder: {case}", file=sys.stderr)
        return 2
    out = Path(a.out).expanduser().resolve() if a.out else case / "_extracted"
    out.mkdir(parents=True, exist_ok=True)

    used: set = set()
    docs = []
    for path in sorted(p for p in case.rglob("*") if p.is_file()):
        if out in path.parents:
            continue
        ext = path.suffix.lower()
        key = unique(safe(str(path.relative_to(case).with_suffix(""))), used)
        if ext in PDF:
            docs.append(do_pdf(path, out, key, a.dpi, a.all_pages))
        elif ext in DOCX:
            docs.append(do_docx(path, out, key))
        elif ext in IMAGES:
            docs.append({"source": str(path), "type": "image", "text_file": None,
                         "images": [str(path)], "error": None})
        # anything else (.doc, .txt, .json) is left for the agent to read directly

    (out / "manifest.json").write_text(json.dumps({"case_dir": str(case), "documents": docs}, indent=2))

    print(f"Extracted {len(docs)} document(s) from {case}")
    print(f"Manifest: {out / 'manifest.json'}\n")
    for d in docs:
        line = f"- {Path(d['source']).name} [{d['type']}]"
        if d.get("pages"):
            line += f" {d['pages']} page(s)"
        if d.get("scanned_pages"):
            line += f", scanned pages {d['scanned_pages']}"
        print(line)
        if d.get("text_file"):
            print(f"    text:   {d['text_file']}")
        for img in d.get("images", []):
            print(f"    image:  {img}")
        if d.get("error"):
            print(f"    ERROR:  {d['error']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
