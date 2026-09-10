// gles-npot-cube-probe — will this driver sample a non-power-of-two cube map?
//
// Khronos' conformance test conformance/textures/misc/texture-npot.html fails
// two checks here, both of them "NPOT cubemap with TEXTURE_MIN_FILTER set to
// LINEAR should draw"; the NPOT 2D cases pass. OpenGL ES 2.0 allows a
// non-power-of-two texture as long as it is not mipmapped and wraps with
// CLAMP_TO_EDGE, and says nothing that exempts cube maps - so either this
// driver disagrees or something above it does. The driver reports no npot
// extension at all, which is a hint but not an answer, because the allowance is
// in the core specification rather than an extension.
//
// Build (armv7, iOS 6):
//   clang -target armv7-apple-ios6.0 -isysroot "$IOS_SDK" -O2 -fno-objc-arc \
//       -framework Foundation -framework OpenGLES \
//       tools/gles-npot-cube-probe.m -o dist/gles-npot-cube-probe
#import <Foundation/Foundation.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#include <stdio.h>
#include <string.h>

static GLuint compile(GLenum type, const char *source)
{
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    GLint compiled = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (!compiled)
    {
        char log[512] = {0};
        glGetShaderInfoLog(shader, sizeof(log), NULL, log);
        printf("shader failed                   %s\n", log);
    }
    return shader;
}

// A cube map whose faces are `size` by `size`, every texel green.
static GLuint makeCubeMap(int size)
{
    GLubyte *pixels = malloc(size * size * 4);
    for (int i = 0; i < size * size; i++)
    {
        pixels[i * 4 + 0] = 0;
        pixels[i * 4 + 1] = 255;
        pixels[i * 4 + 2] = 0;
        pixels[i * 4 + 3] = 255;
    }

    GLuint texture = 0;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_CUBE_MAP, texture);
    for (GLenum face = GL_TEXTURE_CUBE_MAP_POSITIVE_X; face <= GL_TEXTURE_CUBE_MAP_NEGATIVE_Z; face++)
        glTexImage2D(face, 0, GL_RGBA, size, size, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    free(pixels);
    return texture;
}

static const char *sampleCube(GLuint program, int size)
{
    static char text[48];
    GLuint texture = makeCubeMap(size);
    glClearColor(1, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_CUBE_MAP, texture);
    glUniform1i(glGetUniformLocation(program, "cube"), 0);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

    GLubyte pixel[4];
    glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    glDeleteTextures(1, &texture);
    snprintf(text, sizeof(text), "%d,%d,%d err=0x%x", pixel[0], pixel[1], pixel[2], glGetError());
    return text;
}

int main(void)
{
    @autoreleasepool {
        EAGLContext *context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
        [EAGLContext setCurrentContext:context];

        GLuint framebuffer = 0, target = 0;
        glGenFramebuffers(1, &framebuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
        glGenTextures(1, &target);
        glBindTexture(GL_TEXTURE_2D, target);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 16, 16, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, target, 0);
        glViewport(0, 0, 16, 16);
        printf("renderer                        %s\n", glGetString(GL_RENDERER));

        GLuint program = glCreateProgram();
        glAttachShader(program, compile(GL_VERTEX_SHADER,
            "attribute vec2 pos; varying vec3 dir;"
            "void main(){ dir = vec3(pos, 1.0); gl_Position = vec4(pos, 0.0, 1.0); }"));
        glAttachShader(program, compile(GL_FRAGMENT_SHADER,
            "precision mediump float; uniform samplerCube cube; varying vec3 dir;"
            "void main(){ gl_FragColor = textureCube(cube, dir); }"));
        glBindAttribLocation(program, 0, "pos");
        glLinkProgram(program);
        GLint linked = 0;
        glGetProgramiv(program, GL_LINK_STATUS, &linked);
        printf("program                         %s\n", linked ? "linked" : "failed to link");
        glUseProgram(program);

        static const GLfloat quad[] = { -1, 1, -1, -1, 1, 1, 1, -1 };
        GLuint buffer = 0;
        glGenBuffers(1, &buffer);
        glBindBuffer(GL_ARRAY_BUFFER, buffer);
        glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, 0);

        printf("power-of-two cube map, 8x8      %s (want 0,255,0)\n", sampleCube(program, 8));
        printf("non-power-of-two cube map, 5x5  %s (want 0,255,0)\n", sampleCube(program, 5));
        printf("non-power-of-two cube map, 7x7  %s (want 0,255,0)\n", sampleCube(program, 7));
    }
    return 0;
}
