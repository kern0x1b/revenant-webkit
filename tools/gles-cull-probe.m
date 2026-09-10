// gles-cull-probe — does this driver honour glCullFace(GL_FRONT_AND_BACK)?
//
// Khronos' conformance test conformance/rendering/culling.html fails four
// checks on this device, all of them the FRONT_AND_BACK ones: a triangle that
// should be culled is drawn. ANGLE translates the mode correctly, so the
// question is whether the driver underneath honours it at all. This asks the
// driver directly, with no ANGLE and no WebKit in the way.
//
// Build (armv7, iOS 6):
//   clang -target armv7-apple-ios6.0 -isysroot "$IOS_SDK" -O2 -fno-objc-arc \
//       -framework Foundation -framework OpenGLES \
//       tools/gles-cull-probe.m -o dist/gles-cull-probe
#import <Foundation/Foundation.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#include <stdio.h>

static GLuint compile(GLenum type, const char *source)
{
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    return shader;
}

static void drawTriangle(GLint colourLocation, const GLfloat *vertices, const GLfloat *colour)
{
    glClearColor(1, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glUniform4fv(colourLocation, 1, colour);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, vertices);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

static const char *readBack(void)
{
    static char text[32];
    GLubyte pixel[4];
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    snprintf(text, sizeof(text), "%d,%d,%d", pixel[0], pixel[1], pixel[2]);
    return text;
}

int main(void)
{
    @autoreleasepool {
        EAGLContext *context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
        [EAGLContext setCurrentContext:context];

        // A texture attachment, which is what WebKit draws a canvas into, rather
        // than the renderbuffer this probe used at first.
        GLuint framebuffer = 0, texture = 0;
        glGenFramebuffers(1, &framebuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
        glGenTextures(1, &texture);
        glBindTexture(GL_TEXTURE_2D, texture);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 16, 16, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
        printf("framebuffer (texture)          %s\n",
               glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE ? "complete" : "incomplete");
        glViewport(0, 0, 16, 16);

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

        const GLfloat ccw[] = { -1, 1, -1, -1, 1, 1, 1, -1 };
        const GLfloat green[] = { 0, 1, 0, 1 };

        drawTriangle(colourLocation, ccw, green);
        printf("cull off, front face drawn     %s (want 0,255,0)\n", readBack());

        glEnable(GL_CULL_FACE);
        glCullFace(GL_BACK);
        glFrontFace(GL_CCW);
        drawTriangle(colourLocation, ccw, green);
        printf("cull BACK, front face drawn    %s (want 0,255,0)\n", readBack());

        glCullFace(GL_FRONT);
        drawTriangle(colourLocation, ccw, green);
        printf("cull FRONT, front face culled  %s (want 255,0,0)\n", readBack());

        glCullFace(GL_FRONT_AND_BACK);
        printf("cull mode the driver reports   0x%x (want 0x408)\n", ({ GLint mode = 0; glGetIntegerv(GL_CULL_FACE_MODE, &mode); mode; }));
        drawTriangle(colourLocation, ccw, green);
        printf("cull FRONT_AND_BACK, culled    %s (want 255,0,0)\n", readBack());
        printf("glGetError                     0x%x\n", glGetError());
    }
    return 0;
}
