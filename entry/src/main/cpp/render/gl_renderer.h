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

#include "rdp/rdp_presentation_metrics.h"
#include "native_image_context_policy.h"
#include "video_perf_counters.h"

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>

// OpenGL ES 3.0
#include <GLES3/gl3.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>

#if defined(__GNUC__) || defined(__clang__)
#define REMOTEDESK_RENDER_INTERNAL __attribute__((visibility("hidden")))
#else
#define REMOTEDESK_RENDER_INTERNAL
#endif

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
    void RenderFrame(GLuint textureId,
                     const Render::NativeImageTransform& textureTransform);
    /** Present one OES frame and return the actual EGL swap result. */
    REMOTEDESK_RENDER_INTERNAL RdpPresentMetrics PresentFrame(
        GLuint textureId,
        const Render::NativeImageTransform& textureTransform);

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
    RdpPresentMetrics PresentRawBGRA(const uint8_t* bgraData, int width, int height,
                                     int stride, uint64_t generation);
    RdpPresentMetrics PresentRawBGRARect(const uint8_t* bgraData, int width, int height,
                                         int stride, int dirtyX, int dirtyY,
                                         int dirtyWidth, int dirtyHeight, uint64_t generation);
    // Present a compact dirty rectangle whose pixel buffer contains only the
    // rectangle rows, while width/height still describe the full desktop.
    RdpPresentMetrics PresentRawBGRARectCompact(const uint8_t* bgraData, size_t size,
                                                int width, int height, int stride,
                                                int dirtyX, int dirtyY, int dirtyWidth,
                                                int dirtyHeight, uint64_t generation);
    /** Enable the GLES3 pixel-unpack upload path after the RDP latency gate
     * has collected a direct-upload baseline. */
    void SetPboUploadEnabled(bool enabled);

    /**
     * 调整渲染区域大小
     */
    void Resize(int width, int height);
    void SetSourceSize(int width, int height);
    void SetOesSourceSize(int width, int height);
    /** Apply a local canvas transform. Pan uses a top-left surface origin.
     *  Returns the published transform version, or zero for invalid input. */
    uint64_t SetCanvasTransform(double scale, double panX, double panY,
                                int rotationQuarterTurns = 0);
    /** Register the decoder-owner wake callback; it must not touch EGL/GL. */
    void SetRedrawCallback(std::function<void()> callback);
    /** Register the active RDP session wake callback independently of decoder ownership. */
    void SetSessionRedrawCallback(std::function<void()> callback);
    /** Redraw the retained raw frame on the caller's renderer-owner thread. */
    void RenderRetainedFrame(uint64_t expectedGeneration = 0);
    /** Same retained redraw with a generation-safe presentation result. */
    RdpPresentMetrics PresentRetainedFrame(uint64_t expectedGeneration = 0);

    /** 最近一秒的实际 swap/presentation 统计；读取不会清零计数。 */
    RdpPresentationMetricsSnapshot GetPresentationStats();

    /** 销毁渲染器，释放所有 GL 资源 */
    void Destroy();

    /** Bind the opaque registry handle used to protect shared surface state. */
    void SetRendererHandle(int64_t handle);

    /** 是否已初始化 */
    bool IsInitialized() const { return initialized_; }
    bool IsPresentationReady();

    /** 获取当前宽度 */
    int GetWidth() const { return snapshotSurfaceWidth_.load(std::memory_order_acquire); }

    /** 获取当前高度 */
    int GetHeight() const { return snapshotSurfaceHeight_.load(std::memory_order_acquire); }

    /** 获取视频源宽高 */
    int GetSourceWidth() const { return snapshotSourceWidth_.load(std::memory_order_acquire); }
    int GetSourceHeight() const { return snapshotSourceHeight_.load(std::memory_order_acquire); }

    /** 获取上次渲染的视口 */
    void GetLastViewport(int& vpX, int& vpY, int& vpW, int& vpH) const {
        int sourceWidth = 0, sourceHeight = 0, surfaceWidth = 0, surfaceHeight = 0;
        uint64_t transformVersion = 0;
        GetViewportSnapshot(vpX, vpY, vpW, vpH,
            sourceWidth, sourceHeight, surfaceWidth, surfaceHeight, transformVersion);
    }
    void GetViewportSnapshot(int& vpX, int& vpY, int& vpW, int& vpH,
                             int& sourceWidth, int& sourceHeight,
                             int& surfaceWidth, int& surfaceHeight,
                             uint64_t& transformVersion) const;

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
    bool eglDisplayLeaseHeld_;

    // GL 资源 (外部 OES 纹理路径)
    GLuint shaderProgram_;   // NV12→RGB 着色器程序
    GLint  samplerLocation_; // uniform samplerExternalOES 位置
    GLint  oesTransformLocation_; // NativeImage presentation transform
    GLint  canvasRotationLocation_; // uniform uCanvasRotation 位置

    // GL 资源 (原始 BGRA 像素路径 — RDP GDI)
    GLuint rawShaderProgram_;   // BGRA→RGB 着色器程序
    GLuint rawTexture_;         // BGRA 像素纹理 (GL_TEXTURE_2D)
    GLint  rawSamplerLocation_; // uniform sampler2D 位置
    GLint  rawCanvasRotationLocation_; // uniform uCanvasRotation 位置
    GLuint uploadPbo_[2];        // double-buffered pixel-unpack staging
    size_t uploadPboCapacity_[2];
    int uploadPboIndex_;
    bool pboUploadEnabled_;
    bool pboUploadFailedLogged_;
    int rawTextureWidth_;
    int rawTextureHeight_;
    // The current RAW callback dimensions are presentation state, not GL
    // allocation metadata. They are cleared with the renderer/session path
    // so a previous software frame cannot size a later session.
    int rawPresentationWidth_;
    int rawPresentationHeight_;

    // 共享 GL 几何体
    GLuint vbo_;             // 全屏四边形顶点缓冲
    GLuint vao_;             // 顶点数组对象 (GLES3)

    // 渲染状态
    int  width_;
    int  height_;
    // sourceWidth_/sourceHeight_ are the logical stream dimensions used for
    // input mapping. The active viewport keeps RAW BGRA texture geometry and
    // OES logical geometry separate; delayed hardware callbacks must never
    // rewrite the software path.
    int  sourceWidth_;
    int  sourceHeight_;
    int  oesSourceWidth_;
    int  oesSourceHeight_;
    enum class PresentationPath : uint8_t {
        UNKNOWN = 0,
        OES = 1,
        RAW_BGRA = 2,
    } presentationPath_;
    int  lastVpX_;
    int  lastVpY_;
    int  lastVpW_;
    int  lastVpH_;
    double canvasScale_;
    double canvasPanX_;
    double canvasPanY_;
    int canvasRotationQuarterTurns_;
    std::mutex transformPublishMutex_;
    std::atomic<uint64_t> canvasTransformVersion_;
    std::atomic<double> pendingCanvasScale_;
    std::atomic<double> pendingCanvasPanX_;
    std::atomic<double> pendingCanvasPanY_;
    std::atomic<int> pendingCanvasRotationQuarterTurns_;
    uint64_t appliedCanvasTransformVersion_;
    // Lock-free viewport snapshot for ArkTS/NAPI coordinate mapping. The
    // render lifecycle mutex may be held across eglSwapBuffers(), so readers
    // must never wait on it from the UI thread.
    std::atomic<uint64_t> viewportSnapshotVersion_;
    std::atomic<int> snapshotVpX_;
    std::atomic<int> snapshotVpY_;
    std::atomic<int> snapshotVpW_;
    std::atomic<int> snapshotVpH_;
    std::atomic<int> snapshotSourceWidth_;
    std::atomic<int> snapshotSourceHeight_;
    std::atomic<int> snapshotSurfaceWidth_;
    std::atomic<int> snapshotSurfaceHeight_;
    std::atomic<uint64_t> snapshotTransformVersion_;
    int  rawFrameCount_;
    int  oesFrameCount_;
    int64_t rendererHandle_;
    void* explicitNativeWindow_;
    bool usesProcessSurface_;
    bool initialized_;
    bool destroying_;
    std::mutex lifecycleMutex_;
    std::mutex redrawCallbackMutex_;
    std::function<void()> redrawCallback_;
    std::function<void()> sessionRedrawCallback_;
    RdpPresentationMetrics presentationMetrics_;

    // 内部方法
    bool InitEGL(const std::string& xcomponentId);
    bool InitGL();
    GLuint CompileShader(GLenum type, const char* source);
    GLuint CreateShaderProgram();
    GLuint CreateRawShaderProgram();
    void   CreateQuadGeometry();
    void   SetupRawTexture(int width, int height);
    bool   UploadRawPixelsWithPbo(const uint8_t* uploadData, int uploadW, int uploadH,
                                  int sourceStride, int uploadX, int uploadY);
    void   DestroyUploadPbosLocked();
    void   ApplyPendingCanvasTransformLocked();
    void   RequestRedraw();
    void   CalculateViewport(int sourceWidth, int sourceHeight,
                             int& vpX, int& vpY, int& vpW, int& vpH) const;
    void   CalculateActiveViewport(int& vpX, int& vpY, int& vpW, int& vpH) const;
    void   PublishViewportSnapshot(int vpX, int vpY, int vpW, int vpH);
    RdpPresentMetrics RenderRawBGRAInternal(const uint8_t* bgraData, int width, int height,
                                            int stride, bool useDirtyRect, int dirtyX,
                                            int dirtyY, int dirtyWidth, int dirtyHeight,
                                            uint64_t generation, size_t dataSize = 0,
                                            bool compactDirtyBuffer = false);
    RdpPresentMetrics RenderRetainedFrameLocked(uint64_t expectedGeneration);
};

// ============================================================
// NAPI 包装 (定义在 gl_renderer.cpp)
// ============================================================

namespace RendererNapi {
    struct OwnedRendererCreationResult {
        bool ok = false;
        int64_t rendererHandle = 0;
        uint64_t rendererGeneration = 0;
    };
    napi_value Init(napi_env env, napi_value exports);
    void MakeCurrent(int64_t handle);
    void MakeCurrent(int64_t handle, const Render::DecoderSessionIdentity& owner);
    void ReleaseCurrent(int64_t handle);
    void ReleaseCurrent(int64_t handle, const Render::DecoderSessionIdentity& owner);
    void SetRendererSourceSize(int64_t handle, int width, int height);
    void SetRendererSourceSize(int64_t handle, const Render::DecoderSessionIdentity& owner,
                               int width, int height);
    void RenderNative(int64_t handle, GLuint textureId);
    void RenderNative(int64_t handle, const Render::DecoderSessionIdentity& owner,
                      GLuint textureId);
    void RenderNative(int64_t handle, const Render::DecoderSessionIdentity& owner,
                      GLuint textureId,
                      const Render::NativeImageTransform& textureTransform);
    REMOTEDESK_RENDER_INTERNAL RdpPresentMetrics PresentNative(
        int64_t handle, const Render::DecoderSessionIdentity& owner,
        GLuint textureId,
        const Render::NativeImageTransform& textureTransform);
    void SetActiveSourceSize(int width, int height);
    void SetActiveSourceSize(const Render::DecoderSessionIdentity& owner, int width, int height);
    RdpPresentationTarget GetActivePresentationTarget();
    RdpPresentationTarget GetActivePresentationTarget(const Render::DecoderSessionIdentity& owner);
    // The caller must already hold the shared session sink lease. This is used
    // by callbacks that keep one lease across source read, staging, and queue
    // submission; it intentionally does not acquire the lease again.
    RdpPresentationTarget GetActivePresentationTargetUnderOwnerLease(
        const Render::DecoderSessionIdentity& owner);
    bool HasReadyActiveRenderer(uint64_t* generation = nullptr);
    RdpPresentMetrics PresentRawBgraActive(const uint8_t* data, size_t size, int width,
                                           int height, int stride, uint64_t generation);
    RdpPresentMetrics PresentRawBgraActive(const Render::DecoderSessionIdentity& owner,
                                           const uint8_t* data, size_t size, int width,
                                           int height, int stride, uint64_t generation);
    RdpPresentMetrics PresentRawBgraRectActive(const uint8_t* data, size_t size, int width,
                                               int height, int stride, int dirtyX, int dirtyY,
                                               int dirtyWidth, int dirtyHeight,
                                               uint64_t generation);
    RdpPresentMetrics PresentRawBgraRectActive(const Render::DecoderSessionIdentity& owner,
                                               const uint8_t* data, size_t size, int width,
                                               int height, int stride, int dirtyX, int dirtyY,
                                               int dirtyWidth, int dirtyHeight,
                                               uint64_t generation);
    RdpPresentMetrics PresentRawBgraRectCompactActive(
        const uint8_t* data, size_t size, int width, int height, int stride,
        int dirtyX, int dirtyY, int dirtyWidth, int dirtyHeight, uint64_t generation);
    RdpPresentMetrics PresentRawBgraRectCompactActive(
        const Render::DecoderSessionIdentity& owner, const uint8_t* data, size_t size,
        int width, int height, int stride, int dirtyX, int dirtyY, int dirtyWidth,
        int dirtyHeight, uint64_t generation);
    RdpPresentMetrics PresentRetainedActive(uint64_t generation);
    RdpPresentMetrics PresentRetainedActive(const Render::DecoderSessionIdentity& owner,
                                            uint64_t generation);
    int RenderRawBgraActive(const uint8_t* data, size_t size, int width, int height, int stride);
    int RenderRawBgraRectActive(const uint8_t* data, size_t size, int width, int height, int stride,
                                int dirtyX, int dirtyY, int dirtyWidth, int dirtyHeight);
    int RenderRawBgraActive(const Render::DecoderSessionIdentity& owner,
                            const uint8_t* data, size_t size, int width, int height, int stride);
    void RenderRetained(int64_t handle, const Render::DecoderSessionIdentity& owner);
    bool SetActiveRenderer(int64_t handle, const Render::DecoderSessionIdentity& owner);
    void SetActiveRenderer(int64_t handle);
    // The caller must already hold the shared session sink lease. This is a
    // validation-only boundary for two-phase bind/init paths which cannot
    // reacquire the non-reentrant shared lease.
    bool IsActiveRendererForOwnerUnderLease(
        int64_t handle, const Render::DecoderSessionIdentity& owner);
    /** Exact-owner renderer lookup that also admits auxiliary RustDesk canvases. */
    REMOTEDESK_RENDER_INTERNAL bool IsRendererForOwnerUnderLease(
        int64_t handle, const Render::DecoderSessionIdentity& owner);
    REMOTEDESK_RENDER_INTERNAL uint64_t GetRendererGenerationUnderOwnerLease(
        int64_t handle, const Render::DecoderSessionIdentity& owner);
    REMOTEDESK_RENDER_INTERNAL uint64_t GetRendererGeneration(
        int64_t handle, const Render::DecoderSessionIdentity& owner);
    REMOTEDESK_RENDER_INTERNAL OwnedRendererCreationResult CreateOwnedAuxRenderer(
        const std::string& surfaceId, int width, int height,
        const Render::DecoderSessionIdentity& owner);
    REMOTEDESK_RENDER_INTERNAL uint64_t GetActiveRendererGenerationUnderOwnerLease(
        int64_t handle, const Render::DecoderSessionIdentity& owner);
    REMOTEDESK_RENDER_INTERNAL uint64_t GetActiveRendererGeneration(
        int64_t handle, const Render::DecoderSessionIdentity& owner);
    /** Return the live renderer token for an exact session owner, or zero. */
    int64_t GetActiveRendererHandle(const Render::DecoderSessionIdentity& owner);
    void SetActiveSessionOwner(const Render::DecoderSessionIdentity& owner);
    void ClearActiveSessionOwner(const Render::DecoderSessionIdentity& owner);
    void SetRendererRedrawCallback(int64_t handle, std::function<void()> callback);
    void SetRendererRedrawCallback(int64_t handle, const Render::DecoderSessionIdentity& owner,
                                   std::function<void()> callback);
    uint64_t RegisterActiveRedrawCallback(std::function<void()> callback);
    void UnregisterActiveRedrawCallback(uint64_t token);
    void RenderRetained(int64_t handle);
    RdpPresentationMetricsSnapshot GetActivePresentationStats();
    RdpPresentationMetricsSnapshot GetActivePresentationStats(
        const Render::DecoderSessionIdentity& owner);
    bool SetActivePboUpload(bool enabled);
    bool SetActivePboUpload(const Render::DecoderSessionIdentity& owner, bool enabled);
    void InvalidateActivePresentation();
    void InvalidateActivePresentation(const Render::DecoderSessionIdentity& owner);
    bool ReenableActivePresentation();
    bool ReenableActivePresentation(const Render::DecoderSessionIdentity& owner);
    void DeactivateRenderer(int64_t handle);
    void DeactivateRenderer(int64_t handle, const Render::DecoderSessionIdentity& owner);
    void DestroyRendererHandle(int64_t handle);
    void DestroyRendererHandle(int64_t handle, const Render::DecoderSessionIdentity& owner);
}

#undef REMOTEDESK_RENDER_INTERNAL

#endif // GL_RENDERER_H
