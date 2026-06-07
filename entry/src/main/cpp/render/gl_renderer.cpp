#include <cstdint>
#include <cstring>
#include <string>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES3/gl32.h>
#include <hilog/log.h>

#include "extensions/protocol_adapter.h"

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3201
#define LOG_TAG "GlRenderer"

// NV12 → RGB 转换顶点着色器
static const char* VERTEX_SHADER_SRC = R"(
    #version 300 es
    layout(location = 0) in vec4 aPosition;
    layout(location = 1) in vec2 aTexCoord;
    out vec2 vTexCoord;
    void main() {
        gl_Position = aPosition;
        vTexCoord = aTexCoord;
    }
)";

// NV12 → RGB 片段着色器
// NV12 布局：Y 平面（全分辨率），UV 平面交错（半分辨率）
static const char* NV12_FRAGMENT_SHADER_SRC = R"(
    #version 300 es
    precision mediump float;
    in vec2 vTexCoord;
    out vec4 fragColor;
    uniform sampler2D uTextureY;
    uniform sampler2D uTextureUV;
    void main() {
        vec3 yuv;
        yuv.x = texture(uTextureY, vTexCoord).r;
        yuv.yz = texture(uTextureUV, vTexCoord).rg - vec2(0.5, 0.5);
        // BT.709 色彩空间转换
        vec3 rgb;
        rgb.r = yuv.x + 1.5748 * yuv.z;
        rgb.g = yuv.x - 0.1873 * yuv.y - 0.4681 * yuv.z;
        rgb.b = yuv.x + 1.8556 * yuv.y;
        fragColor = vec4(rgb, 1.0);
    }
)";

// 全屏四边形顶点数据（归一化坐标）
static const float FULLSCREEN_QUAD[] = {
    // 位置 (x, y, z)      // 纹理坐标 (u, v)
    -1.0f, -1.0f, 0.0f,    0.0f, 0.0f,
     1.0f, -1.0f, 0.0f,    1.0f, 0.0f,
    -1.0f,  1.0f, 0.0f,    0.0f, 1.0f,
     1.0f,  1.0f, 0.0f,    1.0f, 1.0f,
};

// GlRenderer — 基于 OpenGL ES 3.0 的 NV12→RGB 渲染器
// 与 HardwareDecoder 的 NativeImage 零拷贝纹理配合使用
class GlRenderer {
public:
    GlRenderer() = default;
    ~GlRenderer() { Release(); }

    // 初始化 EGL 上下文和渲染资源
    // nativeWindow: 鸿蒙 NativeWindow（来自 XComponent）
    // w, h: 目标表面宽高
    bool Init(void* nativeWindow, int w, int h) {
        if (!nativeWindow || w <= 0 || h <= 0) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "Invalid params: window=%p, %dx%d", nativeWindow, w, h);
            return false;
        }

        displayWidth_ = w;
        displayHeight_ = h;

        if (!InitEGL(nativeWindow)) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, "EGL init failed");
            return false;
        }

        if (!InitShaders()) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, "Shader init failed");
            return false;
        }

        if (!InitGeometry()) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, "Geometry init failed");
            return false;
        }

        // 创建 Y 和 UV 纹理对象
        glGenTextures(2, textures_);
        for (int i = 0; i < 2; i++) {
            glBindTexture(GL_TEXTURE_2D, textures_[i]);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        }
        glBindTexture(GL_TEXTURE_2D, 0);

        // 创建帧缓冲区用于离屏渲染（可选，用于截屏/滤镜等）
        glGenFramebuffers(1, &framebuffer_);

        isInitialized_ = true;
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                     "GlRenderer initialized: %dx%d", w, h);
        return true;
    }

    // 渲染一帧：将解码后的纹理绘制到目标表面
    // textureId: 来自 NativeImage 的 GL 纹理 ID
    // x, y, w, h: 目标渲染区域（像素坐标，相对表面左上角）
    void RenderFrame(GLuint textureId, int x, int y, int w, int h) {
        if (!isInitialized_) return;

        // 设置视口为指定区域
        glViewport(x, displayHeight_ - y - h, w, h);

        // 绑定 Shader 程序
        glUseProgram(shaderProgram_);

        // 将传入的纹理 ID 视为 Y 纹理
        // 对于 NativeImage 输出的纹理，它是解码器写入的完整帧
        // 注意：NativeImage 纹理可能已经是 RGB 格式，此处按 NV12 分平面处理
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, textureId);
        glUniform1i(glGetUniformLocation(shaderProgram_, "uTextureY"), 0);

        // UV 纹理：同一个纹理，片段着色器中取 .rg 作为 UV
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_2D, textureId);
        glUniform1i(glGetUniformLocation(shaderProgram_, "uTextureUV"), 1);

        // 绑定 VAO 并绘制
        glBindVertexArray(vao_);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        glBindVertexArray(0);

        // 交换缓冲区
        eglSwapBuffers(eglDisplay_, eglSurface_);
    }

    // 获取帧缓冲对象（用于离屏渲染）
    GLuint GetFramebuffer() const { return framebuffer_; }

    // 调整表面大小
    void Resize(int w, int h) {
        displayWidth_ = w;
        displayHeight_ = h;
        glViewport(0, 0, w, h);
    }

private:
    // 初始化 EGL 显示和上下文
    bool InitEGL(void* nativeWindow) {
        eglDisplay_ = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        if (eglDisplay_ == EGL_NO_DISPLAY) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "eglGetDisplay failed: 0x%x", eglGetError());
            return false;
        }

        EGLint major, minor;
        if (!eglInitialize(eglDisplay_, &major, &minor)) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "eglInitialize failed: 0x%x", eglGetError());
            return false;
        }

        // 选择 EGL 配置
        const EGLint attribs[] = {
            EGL_SURFACE_TYPE,    EGL_WINDOW_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
            EGL_RED_SIZE,        8,
            EGL_GREEN_SIZE,      8,
            EGL_BLUE_SIZE,       8,
            EGL_ALPHA_SIZE,      8,
            EGL_DEPTH_SIZE,      16,
            EGL_STENCIL_SIZE,    8,
            EGL_NONE
        };
        EGLint numConfigs;
        EGLConfig eglConfig;
        if (!eglChooseConfig(eglDisplay_, attribs, &eglConfig, 1, &numConfigs)) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "eglChooseConfig failed: 0x%x", eglGetError());
            return false;
        }

        // 创建 EGL 窗口表面
        eglSurface_ = eglCreateWindowSurface(eglDisplay_, eglConfig,
                                             nativeWindow, nullptr);
        if (eglSurface_ == EGL_NO_SURFACE) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "eglCreateWindowSurface failed: 0x%x", eglGetError());
            return false;
        }

        // 创建 EGL 上下文（OpenGL ES 3.0）
        const EGLint ctxAttribs[] = {
            EGL_CONTEXT_CLIENT_VERSION, 3,
            EGL_NONE
        };
        eglContext_ = eglCreateContext(eglDisplay_, eglConfig,
                                       EGL_NO_CONTEXT, ctxAttribs);
        if (eglContext_ == EGL_NO_CONTEXT) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "eglCreateContext failed: 0x%x", eglGetError());
            return false;
        }

        if (!eglMakeCurrent(eglDisplay_, eglSurface_, eglSurface_, eglContext_)) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "eglMakeCurrent failed: 0x%x", eglGetError());
            return false;
        }

        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG,
                     "EGL initialized: GL %s, vendor %s",
                     glGetString(GL_VERSION), glGetString(GL_VENDOR));
        return true;
    }

    // 编译着色器并链接程序
    bool InitShaders() {
        GLuint vertShader = CompileShader(GL_VERTEX_SHADER, VERTEX_SHADER_SRC);
        if (!vertShader) return false;

        GLuint fragShader = CompileShader(GL_FRAGMENT_SHADER, NV12_FRAGMENT_SHADER_SRC);
        if (!fragShader) {
            glDeleteShader(vertShader);
            return false;
        }

        shaderProgram_ = glCreateProgram();
        glAttachShader(shaderProgram_, vertShader);
        glAttachShader(shaderProgram_, fragShader);
        glLinkProgram(shaderProgram_);

        GLint linked;
        glGetProgramiv(shaderProgram_, GL_LINK_STATUS, &linked);
        if (!linked) {
            GLchar infoLog[512];
            glGetProgramInfoLog(shaderProgram_, sizeof(infoLog), nullptr, infoLog);
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "Shader link failed: %s", infoLog);
            glDeleteShader(vertShader);
            glDeleteShader(fragShader);
            glDeleteProgram(shaderProgram_);
            shaderProgram_ = 0;
            return false;
        }

        glDeleteShader(vertShader);
        glDeleteShader(fragShader);
        return true;
    }

    // 编译单个着色器
    GLuint CompileShader(GLenum type, const char* source) {
        GLuint shader = glCreateShader(type);
        if (!shader) return 0;

        glShaderSource(shader, 1, &source, nullptr);
        glCompileShader(shader);

        GLint compiled;
        glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
        if (!compiled) {
            GLchar infoLog[512];
            glGetShaderInfoLog(shader, sizeof(infoLog), nullptr, infoLog);
            const char* typeStr = (type == GL_VERTEX_SHADER) ? "vertex" : "fragment";
            OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG,
                         "%s shader compile error: %s", typeStr, infoLog);
            glDeleteShader(shader);
            return 0;
        }

        return shader;
    }

    // 初始化顶点属性和 VAO
    bool InitGeometry() {
        // 生成 VAO 和 VBO
        glGenVertexArrays(1, &vao_);
        glGenBuffers(1, &vbo_);

        glBindVertexArray(vao_);
        glBindBuffer(GL_ARRAY_BUFFER, vbo_);
        glBufferData(GL_ARRAY_BUFFER, sizeof(FULLSCREEN_QUAD),
                     FULLSCREEN_QUAD, GL_STATIC_DRAW);

        // 位置属性 (location = 0)
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 5 * sizeof(float),
                              (void*)0);
        glEnableVertexAttribArray(0);

        // 纹理坐标属性 (location = 1)
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 5 * sizeof(float),
                              (void*)(3 * sizeof(float)));
        glEnableVertexAttribArray(1);

        glBindBuffer(GL_ARRAY_BUFFER, 0);
        glBindVertexArray(0);

        return true;
    }

    // 释放所有 EGL 和 GL 资源
    void Release() {
        if (shaderProgram_) {
            glDeleteProgram(shaderProgram_);
            shaderProgram_ = 0;
        }
        if (vao_) {
            glDeleteVertexArrays(1, &vao_);
            vao_ = 0;
        }
        if (vbo_) {
            glDeleteBuffers(1, &vbo_);
            vbo_ = 0;
        }
        if (textures_[0] || textures_[1]) {
            glDeleteTextures(2, textures_);
            textures_[0] = 0;
            textures_[1] = 0;
        }
        if (framebuffer_) {
            glDeleteFramebuffers(1, &framebuffer_);
            framebuffer_ = 0;
        }

        if (eglDisplay_ != EGL_NO_DISPLAY) {
            eglMakeCurrent(eglDisplay_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
            if (eglContext_ != EGL_NO_CONTEXT) {
                eglDestroyContext(eglDisplay_, eglContext_);
                eglContext_ = EGL_NO_CONTEXT;
            }
            if (eglSurface_ != EGL_NO_SURFACE) {
                eglDestroySurface(eglDisplay_, eglSurface_);
                eglSurface_ = EGL_NO_SURFACE;
            }
            eglTerminate(eglDisplay_);
            eglDisplay_ = EGL_NO_DISPLAY;
        }

        isInitialized_ = false;
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, "GlRenderer released");
    }

private:
    // EGL 资源
    EGLDisplay eglDisplay_ = EGL_NO_DISPLAY;
    EGLContext eglContext_ = EGL_NO_CONTEXT;
    EGLSurface eglSurface_ = EGL_NO_SURFACE;

    // GL 资源
    GLuint shaderProgram_ = 0;  // NV12→RGB 着色器程序
    GLuint vao_ = 0;             // 顶点数组对象
    GLuint vbo_ = 0;             // 顶点缓冲对象
    GLuint textures_[2] = {0};   // [0]: Y 纹理, [1]: UV 纹理
    GLuint framebuffer_ = 0;     // 帧缓冲对象（离屏渲染）

    // 显示参数
    int displayWidth_ = 0;
    int displayHeight_ = 0;
    bool isInitialized_ = false;
};
