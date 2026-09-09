# A broken image kills the browser

```sh
python3 broken-image-crash.py 8892 missing   # the <img> answers 404
python3 broken-image-crash.py 8892 present   # the same page, the image answers 200
```

Then open `http://<this machine>:8892/page` on the device and wait half a minute.

With the subresource answering **404** the process is gone within about
twenty-five seconds, with one `[REVCRASH] signal 11` in
`/tmp/rev-safari-stderr.log`. With the identical page whose image answers
**200**, the browser is still there. That is the whole difference: one served
byte range versus a not-found.

It is worth having as a script because it explains a class of crash that looked
random for a long time: every test page that reported its results by requesting
a URL the server did not serve was killing the browser a few seconds later, and
the crash was blamed on whatever the page happened to be testing.

## What has been ruled out, by measurement

- **The broken-image icon.** The deployed framework was missing every image the
  engine loads by name, so `missingImage@2x.png` failed and an empty image was
  used instead. The resources are deployed now (that was a real bug of its own,
  see the layout script) and the crash is unchanged.
- **The disk cache monitor**, which waits for a CFNetwork callback this release
  does not have. Gated out on this port: crash unchanged.
- **The periodic footprint monitor** and its os_log line: disabled, then fixed
  separately: crash unchanged.
- **`MemoryCache` pruning and `destroyDecodedData`**: beaconed, never reached
  before the crash.
- **Fonts** - including the installed modern emoji font - **plain HTTP**,
  **HTTP/1.0 versus 1.1**, **Cache-Control**, and **image dimensions**: all
  varied, none of them decides it.
- Beacons in `CachedImage::error` and `CachedImage::brokenImage` do **not** fire
  before the crash, so the fault is upstream of the failed-load handling, in the
  response path itself.

## Where to look next

`SubresourceLoader::didFail` / `ResourceLoader::didFail` and the 404 response
path in `ResourceHandleCFURLConnectionDelegate` - with a beacon at each, on the
repro above, which takes half a minute per run.
