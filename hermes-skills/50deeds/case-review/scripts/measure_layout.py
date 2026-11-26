#!/usr/bin/env python3
"""Measure the recording layout of a deed PDF: margins, reserved boxes, font sizes.

    python3 measure_layout.py <deed.pdf> [--pages 1-2] [--box W,H]

Recorders reject or surcharge deeds for layout defects that are invisible in
extracted text (e.g. NV NRS 247.110: 1" margins, clear 3"x3" upper-right box,
10-pt minimum; MS § 89-5-24: 3" top margin on page 1). This prints, per page:

  * page size, and the top / bottom / left / right margins in inches
    (distance from the page edge to the nearest text)
  * the smallest font size used and the text spans set below 10 pt
  * any text inside the upper-right box (default 3"x3"; change with --box)

Compare the numbers with the state's rules in references/state-rules.md.
Uses the preinstalled pymupdf; installs nothing. Scanned pages (no text layer)
can't be measured: the script says so.
"""
import argparse
import sys

PT_PER_IN = 72.0


def parse_pages(spec, count):
    if not spec:
        return list(range(count))
    out = []
    for part in spec.split(","):
        if "-" in part:
            a, b = part.split("-", 1)
            out.extend(range(int(a) - 1, min(int(b), count)))
        else:
            out.append(int(part) - 1)
    return [p for p in out if 0 <= p < count]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pdf")
    ap.add_argument("--pages", default="1", help="pages to measure, e.g. 1 or 1-3 (default 1)")
    ap.add_argument("--box", default="3,3", help="upper-right reserved box W,H in inches (default 3,3)")
    a = ap.parse_args()

    import pymupdf
    try:
        doc = pymupdf.open(a.pdf)
    except Exception as e:
        print(f"ERROR cannot open {a.pdf}: {type(e).__name__}: {e}")
        sys.exit(1)
    bw, bh = (float(x) * PT_PER_IN for x in a.box.split(","))

    for pno in parse_pages(a.pages, doc.page_count):
        page = doc[pno]
        W, H = page.rect.width, page.rect.height
        spans = []
        for block in page.get_text("dict")["blocks"]:
            for line in block.get("lines", []):
                for s in line.get("spans", []):
                    if s["text"].strip():
                        spans.append(s)
        print(f"=== page {pno + 1}: {W / PT_PER_IN:.2f}\" x {H / PT_PER_IN:.2f}\" ===")
        if not spans:
            print("  no text layer (scanned page): measure on the rendered image instead")
            continue
        x0 = min(s["bbox"][0] for s in spans)
        y0 = min(s["bbox"][1] for s in spans)
        x1 = max(s["bbox"][2] for s in spans)
        y1 = max(s["bbox"][3] for s in spans)
        print(f"  margins: top {y0 / PT_PER_IN:.2f}\"  bottom {(H - y1) / PT_PER_IN:.2f}\"  "
              f"left {x0 / PT_PER_IN:.2f}\"  right {(W - x1) / PT_PER_IN:.2f}\"")
        sizes = sorted({round(s["size"], 1) for s in spans})
        print(f"  font sizes used: {', '.join(str(x) for x in sizes)} pt")
        small = [s for s in spans if s["size"] < 9.95]
        for s in small[:10]:
            print(f"  under 10 pt ({s['size']:.1f}): {s['text'].strip()[:70]!r}")
        if len(small) > 10:
            print(f"  ... {len(small) - 10} more spans under 10 pt")
        box = pymupdf.Rect(W - bw, 0, W, bh)
        inside = [s for s in spans if pymupdf.Rect(s["bbox"]).intersects(box)]
        if inside:
            print(f"  text inside the upper-right {a.box.replace(',', 'x')}\" box:")
            for s in inside[:8]:
                print(f"    {s['text'].strip()[:70]!r}")
        else:
            print(f"  upper-right {a.box.replace(',', 'x')}\" box: clear")


if __name__ == "__main__":
    main()
