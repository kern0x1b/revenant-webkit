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

## What is left, and what it costs

| Stage | Work | Estimate |
| --- | --- | --- |
| 0 | IOSurface as a GL texture, proven on the device | **done** |
| 1 | `DisplayEAGL` / `ContextEAGL` / `DeviceEAGL` and the CMake wiring; a headless context that clears and reads back, with no WebKit involved | 1-2 weeks |
| 2 | `IOSurfaceSurfaceEAGL`, so a real `<canvas>` clear appears on screen | 1-2 weeks |
| 3 | `GraphicsContextGLCocoa.mm`: choose the GLES backend, GL fences instead of Metal's, WebXR foveation as a no-op | 3-5 days |
| 4 | WebGL 1.0 conformance, and the SGX543 driver's own bugs | a week and open |

One risk is recorded and not yet tested: an `EAGLContext` is thread-affine like
any GL context, and this browser's UIKit takes the web lock on every frame.
Where the context lives, and which thread may touch it, has to be settled early
in stage 1 rather than discovered in stage 4.
