/**
 * gl_renderer.h — OpenGL ES 3.0 渲染器
 *
 * 零拷贝渲染管线：
 *   硬解 → NativeImage (GL 纹理) → NV12→RGB Shader → XComponent Surface
 *
 * 全程无 CPU memcpy，GPU 直接采样 NativeImage 的外部纹理。
 */

#include <napi/native_api.h>
#ifndef GL_RENDERER_H
#define GL_RENDERER_H

#include <cstdint>
#include <mutex>
#include <string>

// OpenGL ES 3.0
#include <GLES3/gl3.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>

/**
 * GLRenderer — OpenGL ES 3.0 渲染器
 *
 * 管理 EGL 上下文和渲染管线。
 * 每个远程桌面连接创建一个实例。
 */
class GLRenderer {
public:
    GLRenderer();
    ~GLRenderer();

    /**
     * 初始化渲染器
     * @param xcomponentId  XComponent 原生窗口 ID (从 ArkTS 传入)
     * @param width         初始宽度
     * @param height        初始高度
     * @return 0=成功, 负数=错误码
     */
    int Init(const std::string& xcomponentId, int width, int height);

    /**
     * 渲染一帧 (OES 外部纹理路径 — 硬解输出)
     * @param textureId  NativeImage 外部纹理 ID (OES texture)
     *                   由 HardwareDecoder::GetTextureId() 提供
     */
    void RenderFrame(GLuint textureId);

    /**
     * 渲染原始 BGRA 像素帧 (RDP GDI 直出路径 — 无需硬解)
     * @param bgraData    BGRA 像素数据
     * @param width       帧宽度 (像素)
     * @param height      帧高度 (像素)
     * @param stride      行跨距 (bytes), 0=width*4
     */
    void RenderRawBGRA(const uint8_t* bgraData, int width, int height, int stride = 0);
    void RenderRawBGRARect(const uint8_t* bgraData, int width, int height, int stride,
                           int dirtyX, int dirtyY, int dirtyWidth, int dirtyHeight);

    /**
     * 调整渲染区域大小
     */
    void Resize(int width, int height);
    void SetSourceSize(int width, int height);

    /** 销毁渲染器，释放所有 GL 资源 */
    void Destroy();

    /** 是否已初始化 */
    bool IsInitialized() const { return initialized_; }

    /** 获取当前宽度 */
    int GetWidth() const { return width_; }

    /** 获取当前高度 */
    int GetHeight() const { return height_; }

    /** 获取视频源宽高 */
    int GetSourceWidth() const { return sourceWidth_; }
    int GetSourceHeight() const { return sourceHeight_; }

    /** 获取上次渲染的视口 */
    void GetLastViewport(int& vpX, int& vpY, int& vpW, int& vpH) const {
        vpX = lastVpX_; vpY = lastVpY_; vpW = lastVpW_; vpH = lastVpH_;
    }

    // R1: NapiTestRender 使用的 accessor
    bool MakeCurrent();
    void ReleaseCurrent();
    EGLDisplay GetDisplay() const { return eglDisplay_; }
    EGLSurface GetSurface() const { return eglSurface_; }

private:
    // EGL 资源
    EGLDisplay eglDisplay_;
    EGLContext eglContext_;
    EGLSurface eglSurface_;
    EGLConfig  eglConfig_;

    // GL 资源 (外部 OES 纹理路径)
    GLuint shaderProgram_;   // NV12→RGB 着色器程序
    GLuint samplerLocation_; // uniform samplerExternalOES 位置

    // GL 资源 (原始 BGRA 像素路径 — RDP GDI)
    GLuint rawShaderProgram_;   // BGRA→RGB 着色器程序
    GLuint rawTexture_;         // BGRA 像素纹理 (GL_TEXTURE_2D)
    GLuint rawSamplerLocation_; // uniform sampler2D 位置
    int rawTextureWidth_;
    int rawTextureHeight_;

    // 共享 GL 几何体
    GLuint vbo_;             // 全屏四边形顶点缓冲
    GLuint vao_;             // 顶点数组对象 (GLES3)

    // 渲染状态
    int  width_;
    int  height_;
    int  sourceWidth_;
    int  sourceHeight_;
    int  lastVpX_;
    int  lastVpY_;
    int  lastVpW_;
    int  lastVpH_;
    int  rawFrameCount_;
    bool initialized_;
    bool destroying_;
    std::mutex lifecycleMutex_;

    // 内部方法
    bool InitEGL(const std::string& xcomponentId);
    bool InitGL();
    GLuint CompileShader(GLenum type, const char* source);
    GLuint CreateShaderProgram();
    GLuint CreateRawShaderProgram();
    void   CreateQuadGeometry();
    void   SetupRawTexture(int width, int height);
    void   RenderRawBGRAInternal(const uint8_t* bgraData, int width, int height, int stride,
                                 bool useDirtyRect, int dirtyX, int dirtyY,
                                 int dirtyWidth, int dirtyHeight);
};

// ============================================================
// NAPI 包装 (定义在 gl_renderer.cpp)
// ============================================================

namespace RendererNapi {
    napi_value Init(napi_env env, napi_value exports);
    void MakeCurrent(int64_t handle);
    void ReleaseCurrent(int64_t handle);
    void RenderNative(int64_t handle, GLuint textureId);
    void SetActiveSourceSize(int width, int height);
    int RenderRawBgraActive(const uint8_t* data, size_t size, int width, int height, int stride);
    int RenderRawBgraRectActive(const uint8_t* data, size_t size, int width, int height, int stride,
                                int dirtyX, int dirtyY, int dirtyWidth, int dirtyHeight);
    void SetActiveRenderer(int64_t handle);
}

#endif // GL_RENDERER_H
