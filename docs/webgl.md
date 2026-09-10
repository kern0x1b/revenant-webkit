# WebGL on this hardware: what has been established

`ENABLE_WEBGL` is off, and the reason is not the GPU. The PowerVR SGX543MP2 in
this phone is an honest OpenGL ES 2.0 part, which is what WebGL 1.0 needs. What
is missing is a path from WebKit's GL abstraction to that GPU: the only backend
in the tree, `GraphicsContextGLCocoa.mm`, goes through ANGLE's Metal renderer,
and Metal needs an A7. WebGL 2.0 is out permanently - that wants ES 3.0, which
this silicon does not have. It is a ceiling, not a milestone.

The port would need an ANGLE backend on EAGL, the way macOS has one on CGL and
the GTK and WPE ports have one on EGL. The WebCore side of WebGL - all 3535
lines of `GraphicsContextGLANGLE.cpp`, and every piece of WebGL validation and
security with it - is already platform independent and needs nothing.

## Stage 0 is done: the surface works

The one part of that plan with no precedent was the surface. ANGLE's
`EGL_IOSURFACE_ANGLE` path binds an IOSurface as a texture, and GLES2 has no
`CGLTexImageIOSurface2D` to do it with; the route that should work here is
`CVOpenGLESTextureCache` over a `CVPixelBuffer` backed by the IOSurface, with
the pixel format ANGLE expects. Nothing about that was certain, and everything
else in the plan depends on it.

`tools/gles-iosurface-probe.m` answers it on the device, outside WebKit. It
creates a BGRA IOSurface, binds it as a `GL_TEXTURE_2D` through the texture
cache, attaches it to a framebuffer, clears to a colour with a different value
in every channel, and then reads the bytes back out of the surface itself:

```
IOSurface framework            loaded
IOSurface symbols              all present
IOSurfaceCreate BGRA 64x64     ok
EAGLContext ES2                created
GL_RENDERER                    PowerVR SGX 543
GL_VERSION                     OpenGL ES 2.0 IMGSGX543-73.16.1
GL_EXT_texture_format_BGRA8888 yes
CVPixelBufferWithIOSurface     ok (0)
CVOpenGLESTextureCacheCreate   ok (0)
texture from IOSurface         ok (0)
framebuffer completeness       complete (0x8cd5)
glReadPixels RGBA              16 64 192 255  (expected 16 64 192 255)
IOSurface bytes BGRA           192 64 16 255  (expected 192 64 16 255)
bytes per row                  256
```

Every step passes, including the two that were most likely to fail: framebuffer
completeness on this driver, and the component order in the shared surface. The
GPU renders into an IOSurface that the CPU reads back in the byte order ANGLE
expects. IOSurface is a private framework on this release, so the probe reaches
it through `dlsym` rather than a link that would not load.

## Stage 1, in part: ANGLE itself builds for armv7

The other thing nobody had checked is whether ANGLE - 134 MB of translator,
common code and renderers - compiles for a 32-bit ARM target at all with this
toolchain. It does, and three things had to be settled first. Each is in the
tree now and costs nothing while `ENABLE_WEBGL` is off:

- **`OpenGL::GLES` had no definition here.** WebCore links that imported target
  when WebGL is on, and the finder that defines it looks for a pkg-config
  `glesv2` and a `GLES2/gl2.h`, which is a Linux install. On this platform GLES
  is a framework. `Source/cmake/OptionsIOS.cmake` defines the target from it.
- **ANGLE refuses to build against an SDK older than iOS 17.** That floor is the
  Metal backend's, which calls API only the iOS 17 SDK declares. This port
  builds against the newest SDK that still emits armv7 and will never run Metal,
  so the guard in `src/common/platform.h` excludes it.
- **The Metal renderer is dropped, and the null renderer stands in.**
  `PlatformIOS.cmake` removes the Metal sources and definition; ANGLE will not
  compile with no renderer at all, so the null one is the floor until the GLES
  backend exists. It draws nothing, and a browser must never ship it.

The result is `libANGLE.a` (18 MB, armv7, 261 objects) and `libGLESv2.a`, built
in a separate `build-254-angle` tree so the shipping build is untouched.

### The three lines where the backend plugs in

`src/libANGLE/Display.cpp` selects a display implementation in three places,
each keyed on the same platform macros:

| Line | What it does | What EAGL adds |
| --- | --- | --- |
| ~62 | includes the display header for the platform | `renderer/gl/eagl/DisplayEAGL.h` |
| ~346 | picks the default `EGL_PLATFORM_ANGLE_TYPE_*` | `EGL_PLATFORM_ANGLE_TYPE_OPENGLES_ANGLE` |
| ~441 | constructs the display | `new rx::DisplayEAGL(state)` |

That is where stage 1 ends and the port becomes real work: the files behind
those three lines - `DisplayEAGL`, `ContextEAGL`, `DeviceEAGL` and the surface -
do not exist and have to be written, using `cgl/` as the model and the texture
path that stage 0 proved.

## Stage 1 is done: ANGLE runs on this GPU

`src/libANGLE/renderer/gl/eagl/` now exists - `DisplayEAGL`, `PbufferSurfaceEAGL`,
`DeviceEAGL` - modelled on the CGL backend and wired into the three places in
`Display.cpp` that choose a display. `tools/angle-eagl-probe.mm` drives it
through the same `EGL_`/`GL_` entry points WebCore uses, on the device:

```
EGL_GetPlatformDisplay      ok
EGL_Initialize              EGL 1.5
EGL_QueryString VENDOR      Google Inc. (Imagination Technologies)
EGL_ChooseConfig            1 config
EGL_CreatePbufferSurface    ok
EGL_CreateContext           ok
EGL_MakeCurrent             ok
GL_RENDERER                 ANGLE (Imagination Technologies, PowerVR SGX 543,
                            OpenGL ES 2.0 IMGSGX543-73.16.1)
glReadPixels RGBA           16 64 192 255  (expected 16 64 192 255)
glGetError                  0x0
```

One detail worth keeping: a binary that links the ANGLE archives must be pointed
at the engine's own C++ runtime (`install_name_tool -change
@executable_path/Frameworks/libc++.1.dylib /usr/lib/librev-c++.1.dylib`), or it
traps at load with nothing printed.

## Stage 2 is done: the pixels reach an IOSurface

`IOSurfaceSurfaceEAGL` implements `EGL_ANGLE_iosurface_client_buffer`, which is
how a canvas leaves the GPU for the compositor. GLES cannot repoint an existing
texture object at a surface the way `CGLTexImageIOSurface2D` does, so the surface
owns the texture the cache gives it: `attachToFramebuffer` hands that texture
straight to the framebuffer with nothing copied, and `bindTexImage` - where the
caller brings its own texture - copies in and out, two blits per bind.

Measured on the device:

```
EGL_ANGLE_iosurface_client_buffer advertised
EGL_CreatePbufferFromClientBuffer ok
EGL_BindTexImage                  ok
framebuffer completeness          complete
IOSurface bytes BGRA              160 96 32 255  (expected 160 96 32 255)
```

## Stage 3 is where it stops, and why

`GraphicsContextGLCocoa` now asks for the GLES platform rather than Metal, skips
the Metal feature overrides and the shared-event assert, and replaces the
Metal shared-event completion signal - which does not exist without Metal, and
has no fence equivalent in GLES 2.0 - with a finish and a direct call. Those
changes are in, and inert while `ENABLE_WEBGL` is off.

What blocks the rest is not the GPU: **`HAVE(IOSURFACE)` is off for this port**,
and WebGL's whole Cocoa presentation path is built on WebCore's own `IOSurface`
class - `IOSurfacePbuffer`, the display buffer, `displayBufferSurface`. With the
flag off the header does not even compile with WebGL on.

Two ways forward, and they are different projects:

- **Turn `HAVE(IOSURFACE)` on for this port.** Architecturally right, and the GL
  half is already proven - the EAGL backend reaches IOSurface through `dlsym`
  because the framework is private here, and WebCore's `IOSurface.mm` would need
  the same treatment. The risk is reach: image buffers, video and compositing
  all branch on that flag, so it changes far more than WebGL in a browser that
  currently works.
- **Give WebGL a presentation path that does not need it**: render into an ANGLE
  pbuffer and read back into an ImageBuffer on prepare. No effect on anything
  else, slower per frame, and a rewrite of the part of GraphicsContextGLCocoa
  that is built around IOSurface.

## What is left, and what it costs

| Stage | Work | Estimate |
| --- | --- | --- |
| 0 | IOSurface as a GL texture, proven on the device | **done** |
| 1 | the CMake wiring and an ANGLE that builds for armv7 | **done** |
| 1b | `DisplayEAGL` / `DeviceEAGL` / `PbufferSurfaceEAGL`; a headless context that clears and reads back, with no WebKit involved | **done** |
| 2 | `IOSurfaceSurfaceEAGL` | **done** |
| 3 | `GraphicsContextGLCocoa.mm`: the backend choice and the completion signal are done; the presentation path needs `HAVE(IOSURFACE)` for this port, or a readback path instead | the decision above, then days |
| 4 | WebGL 1.0 conformance, and the SGX543 driver's own bugs | a week and open |

One risk is recorded and not yet tested: an `EAGLContext` is thread-affine like
any GL context, and this browser's UIKit takes the web lock on every frame.
Where the context lives, and which thread may touch it, has to be settled early
in stage 1 rather than discovered in stage 4.
