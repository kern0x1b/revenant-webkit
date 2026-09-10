// gles-cull-probe — which colour attachments does this driver cull into?
//
// Khronos' conformance/rendering/culling.html fails four checks on this device.
// ANGLE sends glCullFace and glEnable(GL_CULL_FACE), and the driver reports the
// mode back correctly at the moment of the draw, so the state was never the
// problem. This probe takes ANGLE and WebKit out of the picture and asks the
// driver the same question against one attachment after another, because the
// attachment turned out to be what decides it.
//
// Build (armv7, iOS 6):
//   clang -target armv7-apple-ios6.0 -isysroot "$IOS_SDK" -O2 -fno-objc-arc \
//       -framework Foundation -framework CoreVideo -framework OpenGLES \
//       tools/gles-cull-probe.m -o dist/gles-cull-probe
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

static const int kSize = 16;

typedef CFTypeRef (*IOSurfaceCreateFunction)(CFDictionaryRef);

static CFTypeRef makeSurface(uint32_t pixelFormat)
{
    void *library = dlopen("/System/Library/PrivateFrameworks/IOSurface.framework/IOSurface", RTLD_LAZY);
    if (!library)
        return NULL;
    IOSurfaceCreateFunction createSurface = (IOSurfaceCreateFunction)dlsym(library, "IOSurfaceCreate");
    CFStringRef *widthKey = (CFStringRef *)dlsym(library, "kIOSurfaceWidth");
    CFStringRef *heightKey = (CFStringRef *)dlsym(library, "kIOSurfaceHeight");
    CFStringRef *bytesPerElementKey = (CFStringRef *)dlsym(library, "kIOSurfaceBytesPerElement");
    CFStringRef *pixelFormatKey = (CFStringRef *)dlsym(library, "kIOSurfacePixelFormat");
    if (!createSurface || !widthKey || !heightKey || !bytesPerElementKey || !pixelFormatKey)
        return NULL;
    NSDictionary *properties = @{
        (__bridge NSString *)*widthKey: @(kSize),
        (__bridge NSString *)*heightKey: @(kSize),
        (__bridge NSString *)*bytesPerElementKey: @4,
        (__bridge NSString *)*pixelFormatKey: @(pixelFormat),
    };
    return createSurface((__bridge CFDictionaryRef)properties);
}

static GLuint surfaceTexture(EAGLContext *context, uint32_t pixelFormat,
                             GLenum internalFormat, GLenum format)
{
    CFTypeRef surface = makeSurface(pixelFormat);
    if (!surface)
        return 0;
    CVPixelBufferRef pixelBuffer = NULL;
    if (CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, (IOSurfaceRef)surface, NULL, &pixelBuffer) != kCVReturnSuccess)
        return 0;
    CVOpenGLESTextureCacheRef cache = NULL;
    if (CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, context, NULL, &cache) != kCVReturnSuccess)
        return 0;
    CVOpenGLESTextureRef texture = NULL;
    if (CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, NULL,
            GL_TEXTURE_2D, internalFormat, kSize, kSize, format, GL_UNSIGNED_BYTE, 0, &texture) != kCVReturnSuccess)
        return 0;
    return CVOpenGLESTextureGetName(texture);
}

static GLuint plainTexture(GLenum internalFormat, GLenum format)
{
    GLuint texture = 0;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexImage2D(GL_TEXTURE_2D, 0, internalFormat, kSize, kSize, 0, format, GL_UNSIGNED_BYTE, NULL);
    return texture;
}

static GLuint compile(GLenum type, const char *source)
{
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    return shader;
}

// Draws a front-facing triangle with FRONT culled, so a driver that culls
// leaves the red clear behind and one that does not paints it green.
// Four things that might make the driver notice a state change before the draw
// instead of one draw later.
typedef enum { NoNudge, FlushNudge, FinishNudge, RebindNudge, RedundantEnableNudge } Nudge;
static Nudge gNudge = NoNudge;
static GLuint gFramebuffer = 0;

static void applyNudge(void)
{
    switch (gNudge)
    {
        case FlushNudge: glFlush(); break;
        case FinishNudge: glFinish(); break;
        case RebindNudge: glBindFramebuffer(GL_FRAMEBUFFER, gFramebuffer); break;
        case RedundantEnableNudge: glEnable(GL_CULL_FACE); break;
        case NoNudge: break;
    }
}

static const char *cullVerdict(GLint colourLocation)
{
    static char text[64];
    static const GLfloat frontFacing[] = { -1, 1, -1, -1, 1, 1, 1, -1 };
    static const GLfloat green[] = { 0, 1, 0, 1 };

    glEnable(GL_CULL_FACE);
    glFrontFace(GL_CCW);
    glClearColor(1, 0, 0, 1);

    const GLenum modes[] = { GL_BACK, GL_FRONT, GL_FRONT_AND_BACK };
    const char *names[] = { "BACK", "FRONT", "FRONT_AND_BACK" };
    const bool shouldDraw[] = { true, false, false };
    char *cursor = text;

    for (int i = 0; i < 3; i++)
    {
        glCullFace(modes[i]);
        applyNudge();
        glClear(GL_COLOR_BUFFER_BIT);
        glUniform4fv(colourLocation, 1, green);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, frontFacing);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

        GLubyte pixel[4];
        glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
        // Green sits in the middle byte whichever order the driver hands back,
        // so it is the only channel worth deciding on.
        bool drawn = pixel[1] > 128;
        cursor += snprintf(cursor, sizeof(text) - (cursor - text), "%s%s:%s[%d,%d,%d]",
                           i ? " " : "", names[i], drawn == shouldDraw[i] ? "ok" : "WRONG",
                           pixel[0], pixel[1], pixel[2]);
    }
    return text;
}

// Culling is not the only rasterizer state worth asking about: if a whole class
// of it is dropped for this attachment, the port needs to know the blast radius.
static const char *rasterizerVerdict(GLint colourLocation)
{
    static char text[128];
    static const GLfloat quad[] = { -1, 1, -1, -1, 1, 1, 1, -1 };
    static const GLfloat green[] = { 0, 1, 0, 1 };
    static const GLfloat half[] = { 0, 0.5, 0, 0.5 };
    GLubyte pixel[4];
    char *cursor = text;

    glDisable(GL_CULL_FACE);
    glUniform4fv(colourLocation, 1, green);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, quad);

    // Scissor: the pixel read back sits outside the box, so it must stay red.
    glClearColor(1, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glEnable(GL_SCISSOR_TEST);
    glScissor(kSize / 2, kSize / 2, kSize / 2, kSize / 2);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glDisable(GL_SCISSOR_TEST);
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    cursor += snprintf(cursor, sizeof(text) - (cursor - text), "scissor:%s", pixel[1] > 128 ? "IGNORED" : "ok");

    // Colour mask: green is masked off, so the pixel must stay red.
    glClear(GL_COLOR_BUFFER_BIT);
    glColorMask(GL_TRUE, GL_FALSE, GL_TRUE, GL_TRUE);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    cursor += snprintf(cursor, sizeof(text) - (cursor - text), " colormask:%s", pixel[1] > 128 ? "IGNORED" : "ok");

    // Blend: half green added to a black clear should land near 128, not 0 or 255.
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE);
    glUniform4fv(colourLocation, 1, half);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glDisable(GL_BLEND);
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    cursor += snprintf(cursor, sizeof(text) - (cursor - text), " blend:%s[%d]",
                       (pixel[1] > 100 && pixel[1] < 160) ? "ok" : "WRONG", pixel[1]);
    return text;
}

int main(void)
{
    @autoreleasepool {
        EAGLContext *context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
        [EAGLContext setCurrentContext:context];
        printf("renderer  %s\n\n", glGetString(GL_RENDERER));

        GLuint program = glCreateProgram();
        glAttachShader(program, compile(GL_VERTEX_SHADER,
            "attribute vec2 pos; void main(){ gl_Position = vec4(pos, 0.0, 1.0); }"));
        glAttachShader(program, compile(GL_FRAGMENT_SHADER,
            "precision mediump float; uniform vec4 col; void main(){ gl_FragColor = col; }"));
        glBindAttribLocation(program, 0, "pos");
        glLinkProgram(program);
        glUseProgram(program);
        glEnableVertexAttribArray(0);
        GLint colourLocation = glGetUniformLocation(program, "col");
        glViewport(0, 0, kSize, kSize);

        // Each case gets a framebuffer of its own, because swapping attachments
        // on one framebuffer gave answers that moved between runs - the stand
        // was measuring itself.
        for (int which = 0; which < 3; which++)
        {
            const char *name = "";
            GLuint framebuffer = 0;
            glGenFramebuffers(1, &framebuffer);
            glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);

            if (which == 0)
            {
                name = "renderbuffer RGBA8         ";
                GLuint renderbuffer = 0;
                glGenRenderbuffers(1, &renderbuffer);
                glBindRenderbuffer(GL_RENDERBUFFER, renderbuffer);
                glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8_OES, kSize, kSize);
                glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, renderbuffer);
            }
            else if (which == 1)
            {
                name = "plain texture RGBA         ";
                glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                                       plainTexture(GL_RGBA, GL_RGBA), 0);
            }
            else
            {
                name = "texture from an IOSurface  ";
                GLuint texture = surfaceTexture(context, 'BGRA', GL_RGBA, GL_BGRA_EXT);
                if (!texture)
                {
                    printf("%s  could not be made\n", name);
                    continue;
                }
                glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
            }

            if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
            {
                printf("%s  framebuffer incomplete\n", name);
                continue;
            }

            // Three passes, because a driver that only mishandles the first draw
            // into a fresh target looks exactly like one that never culls.
            gFramebuffer = framebuffer;
            const char *nudgeNames[] = { "no nudge     ", "glFlush      ", "glFinish     ",
                                         "rebind fbo   ", "redundant on " };
            for (int nudge = NoNudge; nudge <= RedundantEnableNudge; nudge++)
            {
                gNudge = (Nudge)nudge;
                const char *first = cullVerdict(colourLocation);
                char firstCopy[128];
                snprintf(firstCopy, sizeof(firstCopy), "%s", first);
                printf("%s  %s  %s | again %s\n", name, nudgeNames[nudge], firstCopy,
                       cullVerdict(colourLocation));
            }
            gNudge = NoNudge;
            printf("\n");
        }
        printf("glGetError 0x%x\n", glGetError());
    }
    return 0;
}
