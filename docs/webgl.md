# WebGL on a 2011 GPU

WebGL works on this phone. `canvas.getContext("webgl")` returns a context,
shaders compile, and a triangle drawn by the GPU reads back with the colour it
was given, on a PowerVR SGX543MP2 that Apple stopped shipping software for three
major releases ago.

```
webgl-context           WebGL 1.0
webgl-clears            16,64,192,255
webgl-links-a-program
webgl-draws-a-triangle  255,89,0,255
webgl-without-errors    0x0
```

Those are five of the checks in `tests/device/web-platform.html`, run on the
device by `tests/device/run.sh`, so a regression is a failing test rather than a
discovery.

WebGL **2.0** is not here and will not be: it needs OpenGL ES 3.0 and this
silicon is an ES 2.0 part. That is a ceiling, not a milestone.

## Why it took a backend

`ENABLE_WEBGL` was off because the only GL backend in the tree,
`GraphicsContextGLCocoa`, goes through ANGLE's Metal renderer, and Metal needs an
A7. ANGLE has backends on CGL for macOS, EGL for Linux and Android, WGL for
Windows - and nothing for a device whose only GL API is EAGL.

The WebCore side of WebGL needed none of that work: all 3535 lines of
`GraphicsContextGLANGLE.cpp`, with every piece of WebGL validation and security
in it, is already platform independent.

## What was written

**`src/libANGLE/renderer/gl/eagl/`** - the backend, modelled on `cgl/`:

- `DisplayEAGL` creates an `EAGLContext` for ES2, makes it current, and opens
  `OpenGLES.framework` with `dlopen` because EAGL has no `getProcAddress`.
  Everything macOS-specific in the CGL version - pixel formats, virtual screens,
  the dual-GPU dance - has no counterpart here and is gone rather than stubbed.
- `PbufferSurfaceEAGL` is the CGL surface with the names changed: renderbuffer
  and framebuffer code with nothing platform-specific in it.
- `IOSurfaceSurfaceEAGL` is the one that had no model. `EGL_ANGLE_iosurface_client_buffer`
  is how a canvas leaves the GPU for the compositor; the CGL backend implements it
  with `CGLTexImageIOSurface2D`, which points an existing texture object at
  another texture's storage. GLES has no such call. What it has is
  `CVOpenGLESTextureCache`, which makes a texture of its own out of the surface,
  so this surface creates that texture and hands the name over:
  `attachToFramebuffer` gives it to the framebuffer, and `EGL_BindTexImage` gives
  it to the texture object the caller named, which uses it in place of its own
  until the image is released. That last step needed one seam in ANGLE proper:
  `SurfaceGL::getBindTexImageTextureID`, which every other backend answers with
  zero, and a texture that knows the name it is holding is not its own to delete.
- `DeviceEAGL` answers nothing, because EAGL has no device object to name.
- `Display.cpp` selects the backend in the three places that decide a display.

**The build.** ANGLE had never been compiled for armv7. Three things were in the
way, all inert for other platforms: `OpenGL::GLES` had no definition here
(the finder looks for a pkg-config `glesv2`, which is a Linux install, and GLES
is a framework here); ANGLE refuses to build against an SDK older than iOS 17,
which is the Metal backend's floor and does not apply to a GLES build; and the
Metal renderer had to go, since it cannot compile against this SDK and could
never run on this GPU. `common/system_utils_ios.cpp` was added, because the file
the port removes - `system_utils_mac.cpp` - was the only definition of
`GetSharedLibraryExtension`.

**The WebCore side.** `GraphicsContextGLCocoa` asks for the GLES platform rather
than Metal, leaves the Metal feature overrides alone, drops the power preference
(one GPU, no extension to choose between them - and a display attribute the
backend does not advertise is rejected outright), and replaces the Metal
shared-event completion signal, which has no fence equivalent in GLES 2.0, with
a finish and a direct call.

**IOSurface support.** WebGL's whole presentation path is built on WebCore's
`IOSurface`, and `HAVE(IOSURFACE)` was off for this port. Turning it on cost four
small things: the IOKit types WTF needs are declared locally, since the iOS SDK
has no public IOKit headers; `IOSurfaceAccelerator` is unlinked, because it is an
iOS 8 framework and linking it stops the engine loading at all; two symbols this
release lacks - `kIOSurfaceName` and `CGIOSurfaceContextCreateImageReference` -
are supplied by the compatibility library, the second by calling the copying form
this release does have; and ownership identity is turned off with the task
identity token it depends on.

Of the 44 IOSurface symbols WebCore imports, exactly two were missing on this
device. The rest have been there since 2012.

**One regression, found by the suite and fixed.** With IOSurface support on,
canvas image buffers moved to the IOSurface backend - the request had always been
`RenderingMode::Accelerated`, and the missing backend had been silently falling
through to a bitmap. A CoreGraphics context over an IOSurface drops the four
non-separable blend modes, and the suite caught all four. Canvas keeps the bitmap
backend on this port; WebGL makes its own IOSurfaces and does not go through
there.

## Getting the canvas onto the screen

Everything above can be true while the canvas is a white rectangle, and for a
while it was: a context, a clear, a triangle, all of it read back correctly with
`readPixels`, and nothing on the display. Reading back and presenting are
different paths, and only one of them was working. Two things were in the way.

**The order of the two schedulers.** A canvas hands the compositor its finished
surface in the rendering update's preparation step, and the compositor picks it
up when layers are flushed. In WebKit2 those are the same pass. In WebKit1 the
layer flush is driven by the layer-flush scheduler and the rendering update by
its own, and here the flush went first every time: the layer was displayed
before the canvas had been prepared, saw no surface, and cleared itself. Nothing
marks the layer again afterwards, so on a page that draws once - which is most
WebGL demos and every screenshot test - the frame never arrived at all.
`-[WebView _flushCompositingChanges]` now prepares the page's canvases before it
hands the layers over, through a `Page` entry point that the rendering update
uses as well.

**What CoreAnimation will accept as layer contents.** Upstream gives the layer
the IOSurface itself, which this release's CoreAnimation takes without
complaining and never draws. It is given a `CGImage` over the same surface
instead - `IOSurface::createNativeImage`, which is the path `toDataURL` was
already proving correct on this device.

`tests/device/gl-present.sh` is the check that would have caught this: a canvas
cleared to red, a screenshot, and the share of the page area that is actually
red. It reads 97%.

## The tools that proved each step

- `tools/gles-iosurface-probe.m` - can this GPU bind an IOSurface as a texture at
  all? Answered before a line of the backend was written.
- `tools/angle-eagl-probe.mm` - does ANGLE initialise, make a context and render,
  outside WebKit? A binary that links the ANGLE archives has to be pointed at the
  engine's C++ runtime (`install_name_tool -change
  @executable_path/Frameworks/libc++.1.dylib /usr/lib/librev-c++.1.dylib`) or it
  traps at load with nothing printed.

## What is left

- **Conformance.** A triangle is not a test suite. The known risks are this
  driver's own: framebuffer completeness for formats other than RGBA8, and the
  texture formats SGX543 handles differently from the specification.
- **The `GL_Finish` per frame.** Metal signals frame completion through a shared
  event; GLES 2.0 has no fence, so the frame is waited for instead. It is the
  same guarantee and a worse way to get it.
- **Performance.** Nothing here has been measured for speed, only for
  correctness. The presentation path costs one `CGImage` over the surface per
  displayed frame, which is the part to measure first.
