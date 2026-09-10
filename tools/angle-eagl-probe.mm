// angle-eagl-probe — bring ANGLE up on this GPU, through the EAGL backend.
//
// The stage after gles-iosurface-probe: not "can an IOSurface be a texture",
// but "does ANGLE itself initialise, create a context and render on this
// hardware". It links the ANGLE static libraries directly and drives them the
// way WebCore does - through the EGL_/GL_ entry points, with the prototypes
// turned off - so the answer is about the backend and not about WebKit.
//
//   angle-eagl-probe
//
// Build: see docs/webgl.md; the libraries come from build-254-angle.
#define EGL_EGL_PROTOTYPES 0
#define GL_GLES_PROTOTYPES 0
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <ANGLE/entry_points_egl_autogen.h>
#include <ANGLE/entry_points_egl_ext_autogen.h>
#include <ANGLE/entry_points_gles_2_0_autogen.h>
#include <ANGLE/entry_points_gles_ext_autogen.h>
#include <stdio.h>
#import <Foundation/Foundation.h>


// IOSurface is a private framework on this release; the probe reaches it the
// same way the engine does, through dlsym rather than a link.
#include <dlfcn.h>
#include <string.h>

typedef struct __IOSurface *IOSurfaceRef;

static void *iosurfaceLibrary()
{
    static void *library =
        dlopen("/System/Library/PrivateFrameworks/IOSurface.framework/IOSurface", RTLD_LAZY);
    return library;
}

static IOSurfaceRef createBGRAIOSurface(int width, int height)
{
    typedef CFTypeRef (*CreateFunction)(CFDictionaryRef);
    CreateFunction create = (CreateFunction)dlsym(iosurfaceLibrary(), "IOSurfaceCreate");
    CFStringRef *widthKey           = (CFStringRef *)dlsym(iosurfaceLibrary(), "kIOSurfaceWidth");
    CFStringRef *heightKey          = (CFStringRef *)dlsym(iosurfaceLibrary(), "kIOSurfaceHeight");
    CFStringRef *bytesPerElementKey = (CFStringRef *)dlsym(iosurfaceLibrary(), "kIOSurfaceBytesPerElement");
    CFStringRef *pixelFormatKey     = (CFStringRef *)dlsym(iosurfaceLibrary(), "kIOSurfacePixelFormat");
    if (!create || !widthKey || !heightKey || !bytesPerElementKey || !pixelFormatKey)
        return nullptr;

    int32_t bgra = 'BGRA';
    NSDictionary *properties = @{
        (__bridge NSString *)*widthKey: @(width),
        (__bridge NSString *)*heightKey: @(height),
        (__bridge NSString *)*bytesPerElementKey: @4,
        (__bridge NSString *)*pixelFormatKey: @(bgra),
    };
    return (IOSurfaceRef)create((__bridge CFDictionaryRef)properties);
}

static const unsigned char *lockIOSurface(IOSurfaceRef surface)
{
    typedef int32_t (*LockFunction)(CFTypeRef, uint32_t, uint32_t *);
    typedef void *(*BaseAddressFunction)(CFTypeRef);
    LockFunction lock               = (LockFunction)dlsym(iosurfaceLibrary(), "IOSurfaceLock");
    BaseAddressFunction baseAddress = (BaseAddressFunction)dlsym(iosurfaceLibrary(), "IOSurfaceGetBaseAddress");
    if (!lock || !baseAddress)
        return nullptr;
    lock(surface, 0, nullptr);
    return (const unsigned char *)baseAddress(surface);
}

static void unlockIOSurface(IOSurfaceRef surface)
{
    typedef int32_t (*UnlockFunction)(CFTypeRef, uint32_t, uint32_t *);
    UnlockFunction unlock = (UnlockFunction)dlsym(iosurfaceLibrary(), "IOSurfaceUnlock");
    if (unlock)
        unlock(surface, 0, nullptr);
}

static const int kSize = 64;

int main(void)
{
    EGLAttrib displayAttributes[] = {
        EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_OPENGLES_ANGLE,
        EGL_NONE,
    };
    EGLDisplay display = EGL_GetPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE,
                                                reinterpret_cast<void *>(EGL_DEFAULT_DISPLAY),
                                                displayAttributes);
    printf("EGL_GetPlatformDisplay      %s\n", display == EGL_NO_DISPLAY ? "EGL_NO_DISPLAY" : "ok");
    if (display == EGL_NO_DISPLAY)
        return 1;

    EGLint major = 0, minor = 0;
    if (!EGL_Initialize(display, &major, &minor))
    {
        printf("EGL_Initialize              FAILED (0x%x)\n", EGL_GetError());
        return 1;
    }
    printf("EGL_Initialize              EGL %d.%d\n", major, minor);
    printf("EGL_QueryString VENDOR      %s\n", EGL_QueryString(display, EGL_VENDOR));
    printf("EGL_QueryString VERSION     %s\n", EGL_QueryString(display, EGL_VERSION));

    EGLint configAttributes[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_NONE,
    };
    EGLConfig config = nullptr;
    EGLint configCount = 0;
    if (!EGL_ChooseConfig(display, configAttributes, &config, 1, &configCount) || !configCount)
    {
        printf("EGL_ChooseConfig            FAILED (0x%x)\n", EGL_GetError());
        return 1;
    }
    printf("EGL_ChooseConfig            %d config\n", configCount);

    EGLint surfaceAttributes[] = { EGL_WIDTH, kSize, EGL_HEIGHT, kSize, EGL_NONE };
    EGLSurface surface = EGL_CreatePbufferSurface(display, config, surfaceAttributes);
    printf("EGL_CreatePbufferSurface    %s\n", surface == EGL_NO_SURFACE ? "FAILED" : "ok");
    if (surface == EGL_NO_SURFACE)
        return 1;

    EGLint contextAttributes[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    EGLContext context = EGL_CreateContext(display, config, EGL_NO_CONTEXT, contextAttributes);
    printf("EGL_CreateContext           %s\n", context == EGL_NO_CONTEXT ? "FAILED" : "ok");
    if (context == EGL_NO_CONTEXT)
        return 1;

    if (!EGL_MakeCurrent(display, surface, surface, context))
    {
        printf("EGL_MakeCurrent             FAILED (0x%x)\n", EGL_GetError());
        return 1;
    }
    printf("EGL_MakeCurrent             ok\n");
    printf("GL_VENDOR                   %s\n", (const char *)GL_GetString(GL_VENDOR));
    printf("GL_RENDERER                 %s\n", (const char *)GL_GetString(GL_RENDERER));
    printf("GL_VERSION                  %s\n", (const char *)GL_GetString(GL_VERSION));
    printf("GL_SHADING_LANGUAGE_VERSION %s\n", (const char *)GL_GetString(GL_SHADING_LANGUAGE_VERSION));

    // A colour with a different value in every channel, so a swapped component
    // order is a wrong number rather than a plausible one.
    GL_Viewport(0, 0, kSize, kSize);
    GL_ClearColor(16 / 255.0f, 64 / 255.0f, 192 / 255.0f, 1.0f);
    GL_Clear(GL_COLOR_BUFFER_BIT);
    GL_Finish();

    unsigned char pixel[4] = { 0, 0, 0, 0 };
    GL_ReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    printf("glReadPixels RGBA           %d %d %d %d  (expected 16 64 192 255)\n",
        pixel[0], pixel[1], pixel[2], pixel[3]);
    printf("glGetError                  0x%x\n", GL_GetError());

    bool matches = pixel[0] == 16 && pixel[1] == 64 && pixel[2] == 192 && pixel[3] == 255;

    // The surface a browser actually wants: an IOSurface it can hand to the
    // compositor. Render into it through ANGLE, then read the surface's own
    // bytes on the CPU - if they carry what the GPU drew, the canvas has a way
    // out of the GPU and onto the screen.
    bool surfaceMatches = false;
    printf("\n-- IOSurface surface --\n");
    printf("EGL_ANGLE_iosurface_client_buffer %s\n",
        strstr(EGL_QueryString(display, EGL_EXTENSIONS), "EGL_ANGLE_iosurface_client_buffer")
            ? "advertised" : "MISSING");

    IOSurfaceRef ioSurface = createBGRAIOSurface(kSize, kSize);
    printf("IOSurfaceCreate                   %s\n", ioSurface ? "ok" : "FAILED");
    if (ioSurface)
    {
        EGLint surfaceAttributes[] = {
            EGL_WIDTH, kSize,
            EGL_HEIGHT, kSize,
            EGL_IOSURFACE_PLANE_ANGLE, 0,
            EGL_TEXTURE_TARGET, EGL_TEXTURE_2D,
            EGL_TEXTURE_INTERNAL_FORMAT_ANGLE, GL_BGRA_EXT,
            EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA,
            EGL_TEXTURE_TYPE_ANGLE, GL_UNSIGNED_BYTE,
            EGL_NONE,
        };
        EGLSurface ioSurfacePbuffer = EGL_CreatePbufferFromClientBuffer(
            display, EGL_IOSURFACE_ANGLE, ioSurface, config, surfaceAttributes);
        printf("EGL_CreatePbufferFromClientBuffer %s (0x%x)\n",
            ioSurfacePbuffer == EGL_NO_SURFACE ? "FAILED" : "ok", EGL_GetError());

        if (ioSurfacePbuffer != EGL_NO_SURFACE)
        {
            GLuint canvasTexture = 0;
            GL_GenTextures(1, &canvasTexture);
            GL_BindTexture(GL_TEXTURE_2D, canvasTexture);
            EGLBoolean bound = EGL_BindTexImage(display, ioSurfacePbuffer, EGL_BACK_BUFFER);
            printf("EGL_BindTexImage                  %s (0x%x)\n", bound ? "ok" : "FAILED",
                EGL_GetError());

            GLuint framebuffer = 0;
            GL_GenFramebuffers(1, &framebuffer);
            GL_BindFramebuffer(GL_FRAMEBUFFER, framebuffer);
            GL_FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                                    canvasTexture, 0);
            GLenum completeness = GL_CheckFramebufferStatus(GL_FRAMEBUFFER);
            printf("framebuffer completeness          %s (0x%x)\n",
                completeness == GL_FRAMEBUFFER_COMPLETE ? "complete" : "INCOMPLETE", completeness);

            GL_Viewport(0, 0, kSize, kSize);
            GL_ClearColor(32 / 255.0f, 96 / 255.0f, 160 / 255.0f, 1.0f);
            GL_Clear(GL_COLOR_BUFFER_BIT);
            GL_Finish();

            EGL_ReleaseTexImage(display, ioSurfacePbuffer, EGL_BACK_BUFFER);
            GL_Finish();

            const unsigned char *bytes = lockIOSurface(ioSurface);
            if (bytes)
            {
                printf("IOSurface bytes BGRA              %d %d %d %d  (expected 160 96 32 255)\n",
                    bytes[0], bytes[1], bytes[2], bytes[3]);
                surfaceMatches = bytes[0] == 160 && bytes[1] == 96 && bytes[2] == 32;
                unlockIOSurface(ioSurface);
            }
            EGL_DestroySurface(display, ioSurfacePbuffer);
        }
        CFRelease(ioSurface);
    }

    printf("\nVERDICT                     %s\n", matches && surfaceMatches
        ? "ANGLE renders on this GPU through EAGL, into an IOSurface"
        : matches ? "ANGLE renders, but the IOSurface path did not carry the pixels"
                  : "ANGLE came up but did not render what was asked");
    matches = matches && surfaceMatches;

    EGL_MakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    EGL_DestroyContext(display, context);
    EGL_DestroySurface(display, surface);
    EGL_Terminate(display);
    return matches ? 0 : 1;
}
