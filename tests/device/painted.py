#!/usr/bin/env python3
"""How much of the page area a screenshot actually drew.

A blank page is the failure this catches, and "blank" has to mean the page area
only: the browser's own chrome is always painted, so a screenshot is never
uniformly white and a whole-image measure would call every failure a success.
"""
import sys

try:
    from PIL import Image
except ImportError:
    print("no PIL")
    sys.exit(0)

# The page sits between the address bar and the toolbar on a 640x960 capture.
PAGE_AREA = (0, 150, 640, 880)

try:
    image = Image.open(sys.argv[1]).convert("L").crop(PAGE_AREA)
except Exception:
    print("no shot")
    sys.exit(0)

pixels = list(image.getdata())
inked = sum(1 for value in pixels if value < 200)
percent = inked * 100 // len(pixels)
print("blank" if percent < 1 else "%d%%" % percent)
