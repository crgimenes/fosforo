#!/usr/bin/env python3
"""Gohan for a narrow screen: the banner's art cut at a column and mirrored,
so the head and paws show and the cut sits on the screen's left edge.
usage: tools/gen_banner_narrow.py [IN [OUT [COLUMN]]]
  defaults: assets/banner.ans assets/banner-narrow.ans 30"""
import re
import sys

if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help"):
    print(__doc__)
    sys.exit(0)
src = sys.argv[1] if len(sys.argv) > 1 else "assets/banner.ans"
dst = sys.argv[2] if len(sys.argv) > 2 else "assets/banner-narrow.ans"
cut = int(sys.argv[3]) if len(sys.argv) > 3 else 30
ART_ROWS = 17  # below them, the caption, written anew here

text = open(src, encoding="utf-8").read()
cells = {}
row = col = 0
fg = bg = None
i = 0
while i < len(text):
    ch = text[i]
    if ch == "\x1b":
        m = re.match(r"\x1b\[([0-9;]*)([A-Za-z])", text[i:])
        arg, cmd = m.group(1), m.group(2)
        n = int(arg) if arg.isdigit() else 1
        if cmd == "C":
            col += n
        elif cmd == "D":
            col -= n
        elif cmd == "B":
            row += n
        elif cmd == "m":
            ps = [int(x) if x else 0 for x in arg.split(";")] if arg else [0]
            j = 0
            while j < len(ps):
                p = ps[j]
                if p == 0:
                    fg = bg = None
                elif p == 38:
                    fg = ps[j + 2]
                    j += 2
                elif p == 48:
                    bg = ps[j + 2]
                    j += 2
                elif 30 <= p <= 37:
                    fg = p - 30
                elif 40 <= p <= 47:
                    bg = p - 40
                j += 1
        i += m.end()
        continue
    if ch == "\r":
        col = 0
    elif ch == "\n":
        row += 1
    else:
        if row < ART_ROWS and col < cut:
            cells[(row, cut - 1 - col)] = (ch, fg, bg)
        col += 1
    i += 1


def sgr(fg, bg):
    parts = ["0"]
    if fg is not None:
        parts.append(f"38;5;{fg}")
    if bg is not None:
        parts.append(f"48;5;{bg}")
    return "\x1b[" + ";".join(parts) + "m"


out = []
for r in range(ART_ROWS):
    pen = None
    line = ""
    last = max((c for (rr, c) in cells if rr == r), default=-1)
    for c in range(last + 1):
        ch, f, b = cells.get((r, c), (" ", None, None))
        if (f, b) != pen:
            line += sgr(f, b)
            pen = (f, b)
        line += ch
    out.append(line + "\x1b[0m")
out.append("")
out.append("\x1b[2m  Gohan, asleep on the job \u00b7")  # 38 columns at most
out.append("  ~/.config/fosforo/banner-narrow.ans\x1b[0m")
open(dst, "w", encoding="utf-8").write("\r\n".join(out) + "\r\n")  # as banner.ans ends
