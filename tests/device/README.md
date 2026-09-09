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

Each page gets a fresh browser: asking a busy Safari to open another URL is
unreliable here, and that made a flaky runner look like a flaky engine.

| Page | What it pins down |
| --- | --- |
| `text-and-emoji.html` | joined emoji compose into one glyph, skin tones compose, emoji newer than this system have glyphs, ICU's grapheme rules agree, the system font and `sans-serif` both answer `font-weight` |
| `gradients-and-blends.html` | a gradient fading to transparent keeps its hue; every blend mode, including the four non-separable ones, is implemented by this CoreGraphics - measured through a canvas |
| `image-draw-cost.html` | what six hundred cropped draws of one decoded image cost, in milliseconds - the price of purgeable decoded images |
| `svg-image-filters.html` | a filter inside an SVG loaded through `<img>`: saturate in linear light, saturate in sRGB, and three exactness checks |

Today: **24 pass, 0 fail**, twice in a row.

Memory is measured separately, over repeated cold runs, by the harness in the
session notes rather than from here: dirty pages are a property of a process's
whole life, not of one page.

## Known limitations, as of 2026-09-09

`mix-blend-mode: hue | saturation | color | luminosity` on an **element** is
drawn unblended, while the identical blend through a canvas is correct (hue of
64,128,192 over 224,160,32 gives 105,180,255). So CoreGraphics implements them
and the element path does not reach it - the four names are expressed to a layer
as CoreAnimation filter types this QuartzCore does not have. Keeping such layers
off the compositor was tried at `canBeComposited` and is the wrong place: the
page went blank and the browser crashed thirteen times. The right place is
somewhere in `GraphicsLayerCA` / `RenderLayerBacking`, and it is still open. It
is not in this suite because a page cannot read it.

## The filter brightness, and how it was closed

An SVG filter that reads pixels used to come out one gamma encode too bright
through `<img>`: `192,64,64` read back as `225,137,137`, and `64/255` encoded as
sRGB is `137.6`. The engine already had the answer under `USE(CAIRO)`: where the
graphics library cannot convert while painting, the filter's source buffer is
made in sRGB and the engine converts it into the operating space itself. This
CoreGraphics matches colour spaces by primaries and ignores transfer functions,
so linearRGB and sRGB are the same `CGColorSpace` here and it belongs on that
path. It now takes it, and the three checks read 109, 92 and 192,64,64 exactly.

What has been ruled out, so nobody pays for it twice:

- **The linear-light conversion.** Compiled out, both symptoms were unchanged -
  which was true and misleading: the conversion was not wrong, it was never
  reached, because the source buffer was already tagged with the space it was
  being asked to convert to.
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
