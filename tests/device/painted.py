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

PAGE_AREA = (0, 150, 640, 880)

WANTED = None
if len(sys.argv) > 2:
    WANTED = tuple(int(part) for part in sys.argv[2].split(","))

try:
    image = Image.open(sys.argv[1]).crop(PAGE_AREA)
except Exception:
    print("no shot")
    sys.exit(0)

if WANTED is None:
    pixels = list(image.convert("L").getdata())
    inked = sum(1 for value in pixels if value < 200)
    percent = inked * 100 // len(pixels)
    print("blank" if percent < 1 else "%d%%" % percent)
    sys.exit(0)

pixels = list(image.convert("RGB").getdata())
matched = sum(1 for pixel in pixels
              if all(abs(pixel[band] - WANTED[band]) < 40 for band in range(3)))
percent = matched * 100 // len(pixels)
print("absent" if percent < 1 else "%d%%" % percent)
