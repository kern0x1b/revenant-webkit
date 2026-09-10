#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#include <dlfcn.h>
#include <stdio.h>

typedef CFTypeRef (*IOSurfaceCreateFunction)(CFDictionaryRef);
typedef void *(*IOSurfaceGetBaseAddressFunction)(CFTypeRef);
typedef size_t (*IOSurfaceGetBytesPerRowFunction)(CFTypeRef);
typedef int32_t (*IOSurfaceLockFunction)(CFTypeRef, uint32_t, uint32_t *);
typedef int32_t (*IOSurfaceUnlockFunction)(CFTypeRef, uint32_t, uint32_t *);

static const int surfaceWidth = 64;
static const int surfaceHeight = 64;

int main(void)
{
    @autoreleasepool {
        void *iosurface = dlopen("/System/Library/PrivateFrameworks/IOSurface.framework/IOSurface", RTLD_LAZY);
        printf("IOSurface framework            %s\n", iosurface ? "loaded" : dlerror());
        if (!iosurface)
            return 1;

        IOSurfaceCreateFunction create = (IOSurfaceCreateFunction)dlsym(iosurface, "IOSurfaceCreate");
        IOSurfaceGetBaseAddressFunction baseAddress = (IOSurfaceGetBaseAddressFunction)dlsym(iosurface, "IOSurfaceGetBaseAddress");
        IOSurfaceGetBytesPerRowFunction bytesPerRow = (IOSurfaceGetBytesPerRowFunction)dlsym(iosurface, "IOSurfaceGetBytesPerRow");
        IOSurfaceLockFunction lock = (IOSurfaceLockFunction)dlsym(iosurface, "IOSurfaceLock");
        IOSurfaceUnlockFunction unlock = (IOSurfaceUnlockFunction)dlsym(iosurface, "IOSurfaceUnlock");
        CFStringRef *widthKey = (CFStringRef *)dlsym(iosurface, "kIOSurfaceWidth");
        CFStringRef *heightKey = (CFStringRef *)dlsym(iosurface, "kIOSurfaceHeight");
        CFStringRef *bytesPerElementKey = (CFStringRef *)dlsym(iosurface, "kIOSurfaceBytesPerElement");
        CFStringRef *pixelFormatKey = (CFStringRef *)dlsym(iosurface, "kIOSurfacePixelFormat");
        printf("IOSurface symbols              %s\n",
            (create && baseAddress && bytesPerRow && lock && unlock && widthKey && heightKey && bytesPerElementKey && pixelFormatKey)
                ? "all present" : "MISSING");
        if (!create || !widthKey)
            return 1;

        int32_t bgra = 'BGRA';
        NSDictionary *properties = @{
            (__bridge NSString *)*widthKey: @(surfaceWidth),
            (__bridge NSString *)*heightKey: @(surfaceHeight),
            (__bridge NSString *)*bytesPerElementKey: @4,
            (__bridge NSString *)*pixelFormatKey: @(bgra),
        };
        CFTypeRef surface = create((__bridge CFDictionaryRef)properties);
        printf("IOSurfaceCreate BGRA %dx%d     %s\n", surfaceWidth, surfaceHeight, surface ? "ok" : "FAILED");
        if (!surface)
            return 1;

        EAGLContext *context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
        printf("EAGLContext ES2                %s\n", context ? "created" : "FAILED");
        if (!context || ![EAGLContext setCurrentContext:context])
            return 1;
        printf("GL_RENDERER                    %s\n", (const char *)glGetString(GL_RENDERER));
        printf("GL_VERSION                     %s\n", (const char *)glGetString(GL_VERSION));
        const char *extensions = (const char *)glGetString(GL_EXTENSIONS);
        printf("GL_EXT_texture_format_BGRA8888 %s\n", strstr(extensions, "GL_APPLE_texture_format_BGRA8888") || strstr(extensions, "GL_EXT_texture_format_BGRA8888") ? "yes" : "no");

        CVPixelBufferRef pixelBuffer = NULL;
        CVReturn status = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, (IOSurfaceRef)surface, NULL, &pixelBuffer);
        printf("CVPixelBufferWithIOSurface     %s (%d)\n", status == kCVReturnSuccess ? "ok" : "FAILED", (int)status);
        if (status != kCVReturnSuccess)
            return 1;

        CVOpenGLESTextureCacheRef textureCache = NULL;
        status = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, context, NULL, &textureCache);
        printf("CVOpenGLESTextureCacheCreate   %s (%d)\n", status == kCVReturnSuccess ? "ok" : "FAILED", (int)status);
        if (status != kCVReturnSuccess)
            return 1;

        CVOpenGLESTextureRef texture = NULL;
        status = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, NULL,
            GL_TEXTURE_2D, GL_RGBA, surfaceWidth, surfaceHeight, GL_BGRA_EXT, GL_UNSIGNED_BYTE, 0, &texture);
        printf("texture from IOSurface         %s (%d)\n", status == kCVReturnSuccess ? "ok" : "FAILED", (int)status);
        if (status != kCVReturnSuccess)
            return 1;

        GLuint name = CVOpenGLESTextureGetName(texture);
        glBindTexture(GL_TEXTURE_2D, name);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

        GLuint framebuffer = 0;
        glGenFramebuffers(1, &framebuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, name, 0);
        GLenum completeness = glCheckFramebufferStatus(GL_FRAMEBUFFER);
        printf("framebuffer completeness       %s (0x%x)\n", completeness == GL_FRAMEBUFFER_COMPLETE ? "complete" : "INCOMPLETE", completeness);
        if (completeness != GL_FRAMEBUFFER_COMPLETE)
            return 1;

        glViewport(0, 0, surfaceWidth, surfaceHeight);
        glClearColor(16 / 255.0f, 64 / 255.0f, 192 / 255.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
        glFinish();

        uint8_t readBack[4] = { 0, 0, 0, 0 };
        glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, readBack);
        printf("glReadPixels RGBA              %d %d %d %d  (expected 16 64 192 255)\n",
            readBack[0], readBack[1], readBack[2], readBack[3]);

        lock(surface, 0, NULL);
        const uint8_t *pixels = (const uint8_t *)baseAddress(surface);
        printf("IOSurface bytes BGRA           %d %d %d %d  (expected 192 64 16 255)\n",
            pixels[0], pixels[1], pixels[2], pixels[3]);
        printf("bytes per row                  %zu\n", bytesPerRow(surface));
        bool matches = pixels[0] == 192 && pixels[1] == 64 && pixels[2] == 16;
        unlock(surface, 0, NULL);

        printf("\nVERDICT                        %s\n", matches
            ? "the GPU renders into an IOSurface the CPU can read - the WebGL plan holds"
            : "the surface did not receive what the GPU drew");
        return matches ? 0 : 1;
    }
}
