# Device checks

Numbers, on the phone, repeatable - because a screenshot is not a measurement
and one run is not evidence.

```sh
tests/device/run.sh            # every page, verdict per check
TEST_PORT=8898 tests/device/run.sh   # if 8899 is busy
```

The device cannot be asked for its DOM, so each page reports itself: the runner
serves these pages over plain HTTP and reads the verdicts out of that server's
own request log. A page that reports nothing is a failure, not an absence.

| Page | What it pins down |
| --- | --- |
| `text-and-emoji.html` | joined emoji compose into one glyph, skin tones compose, emoji newer than this system have glyphs, ICU's grapheme rules agree, the system font and `sans-serif` both answer `font-weight` |
| `colour-and-filters.html` | `saturate 0` in linearRGB and in sRGB give their specified greys, an identity colour matrix changes nothing, blend modes the NEON applier never implemented still paint, a gradient fading to transparent keeps its hue |
| `image-draw-cost.html` | what six hundred cropped draws of one decoded image cost, in milliseconds - the price of purgeable decoded images |

Memory is measured separately, over repeated cold runs, by the harness in the
session notes rather than from here: dirty pages are a property of a process's
whole life, not of one page.

## Known failures, as of 2026-09-09

`colour-and-filters.html` fails three checks and takes the browser down with it,
and **both are the same defect**: an SVG that carries a filter, loaded through
`<img>` and drawn to a canvas. Filtered colours come out one gamma encode too
bright (`92` reads as `156`, `192,64,64` as `225,137,137`), and the page ends in
a SIGSEGV in the image decode path.

It is not the linear-light work: with that path compiled out the crash and the
brightening are both still there, unchanged. The same filters measured on a real
page - not through `<img>` - give the specified numbers exactly.

What has been ruled out, so nobody pays for it twice:

- **The linear-light conversion.** Compiled out, both symptoms unchanged. Beacons
  in `FilterImage::transformToColorSpace` and in the backend's transfer show
  neither is called at all on this path.
- **Colour space tags.** Beaconed at the effect: source, result and buffer are
  all linearRGB, and no conversion runs anywhere in between.
- **CoreGraphics matching.** linearRGB and sRGB resolve to the same
  `CGColorSpace` on this port, so CG has nothing to convert between.
- **Filters in general.** A plain `<svg>` rect through `<img>` reads
  192,64,64 exactly, and so does one carrying `feOffset`. Only the effects that
  read and write pixels - `feColorMatrix` and its kin - come out bright.
- **Two repair attempts that crashed**: copying the borrowed source buffer with
  the filter's allocator (wrong resolution scale) and with `ImageBuffer::clone()`.
  Restoring the source buffer's colour space after the filter chain changed no
  measured number.

What is left to look at: the one gamma encode that happens between the buffer an
SVG image is rasterised into and the canvas it is drawn onto, on the pixel-reading
effect path only.
