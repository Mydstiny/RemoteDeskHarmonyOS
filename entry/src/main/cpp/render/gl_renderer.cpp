/**
 * gl_renderer.cpp — OpenGL ES 3.0 渲染器 + NAPI 包装
 *
 * 零拷贝渲染：NativeImage 外部 OES 纹理 → NV12→RGB Shader → 屏幕
 */

#include "gl_renderer.h"
#include "gl_surface_lifecycle_policy.h"
#include <napi/native_api.h>
#include <hilog/log.h>
#include <cstring>
#include <cstdlib>
#include <chrono>
#include <atomic>
#include <algorithm>
#include <cmath>
#include <memory>
#include <unordered_map>
#include <GLES2/gl2ext.h>
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <native_window/external_window.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0003
#define LOG_TAG "GL_RENDERER"

// ============================================================
// R1: XComponent 全局状态与生命周期回调
// ============================================================

static OH_NativeXComponent* g_xc = nullptr;
static EGLNativeWindowType g_nativeWindow = 0;
static uint64_t g_surfaceId = 0;
static std::atomic<bool> g_surfaceReady {false};
static uint64_t g_surfaceWidth = 1920;
static uint64_t g_surfaceHeight = 1080;
static napi_ref g_exportsRef = nullptr;  // exports 持久引用, 用于延迟 XComponent 查询
static bool g_surfaceIdWindowOwned = false;
// SurfaceId/native-window state is process-wide while renderer instances are
// per-session. Serialize compound replacement/ownership operations so a late
// renderer destructor cannot observe half of a new PIP surface binding.
static std::mutex g_surfaceStateMutex;
// A renderer context can outlive the active renderer during a fast PIP
// transfer. Only the context that currently owns this token may clear the
// process-wide SurfaceId window when it is destroyed.
static std::atomic<int64_t> g_surfaceOwnerHandle {0};
static std::atomic<bool> g_surfaceDetached {false};
static std::atomic<uint64_t> g_rendererGeneration {1};

static uint64_t AdvanceRendererGeneration() {
    return g_rendererGeneration.fetch_add(1, std::memory_order_acq_rel) + 1;
}

static void OnSurfaceCreatedCB(OH_NativeXComponent* component, void* window);
static void OnSurfaceChangedCB(OH_NativeXComponent* component, void* window);
static void OnSurfaceDestroyedCB(OH_NativeXComponent* component, void* window);
static void DispatchTouchEventStub(OH_NativeXComponent* component, void* window);

static bool TryLoadNativeXComponent(napi_env env, napi_value exports, const char* source) {
    if (g_xc != nullptr) {
        return true;
    }

    napi_value xcObj = nullptr;
    napi_status status = napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &xcObj);
    if (status != napi_ok || xcObj == nullptr) {
        OH_LOG_INFO(LOG_APP, "[GL-DIAG] %{public}s: 未找到 %{public}s", source, OH_NATIVE_XCOMPONENT_OBJ);
        return false;
    }

    // API 23 中 OH_NATIVE_XCOMPONENT_OBJ 是 napi_object, 官方示例要求用 napi_unwrap 提取。
    status = napi_unwrap(env, xcObj, reinterpret_cast<void**>(&g_xc));
    if (status != napi_ok || g_xc == nullptr) {
        napi_valuetype type;
        napi_typeof(env, xcObj, &type);
        OH_LOG_WARN(LOG_APP, "[GL-DIAG] %{public}s: napi_unwrap XComponent 失败 status=%{public}d type=%{public}d",
                    source, status, type);
        return false;
    }

    char idStr[OH_XCOMPONENT_ID_LEN_MAX + 1] = {0};
    uint64_t idSize = OH_XCOMPONENT_ID_LEN_MAX + 1;
    int32_t ret = OH_NativeXComponent_GetXComponentId(g_xc, idStr, &idSize);
    if (ret != OH_NATIVEXCOMPONENT_RESULT_SUCCESS) {
        OH_LOG_WARN(LOG_APP, "[GL-DIAG] %{public}s: GetXComponentId 失败 ret=%{public}d", source, ret);
    } else {
        OH_LOG_INFO(LOG_APP, "[GL-DIAG] %{public}s: GetXComponentId=%{public}s", source, idStr);
    }
    return true;
}

static bool RegisterXComponentCallbacks(const char* source) {
    if (g_xc == nullptr) {
        return false;
    }

    // ⚠ 不注册 OH_NativeXComponent_RegisterCallback。
    // 原因:
    //   1. 框架在 libraryname 触发 RendererNapi::Init 之前就已派发 OnSurfaceCreated,
    //      回调永远晚 1ms (竞态不可修复)
    //   2. 注册后 OnSurfaceDestroyed 触发框架内部 SIGSEGV@0x0 崩溃
    //      (XComponentPattern::OnSurfaceDestroyed+632, 框架 bug, 非我们回调导致)
    //   3. ArkTS XComponentController.onSurfaceCreated 在 API 23 设备不触发
    //
    // 替代方案: ArkTS onLoad → pollSurfaceId() → getXComponentSurfaceId() 轮询获取 surfaceId,
    //          然后通过 setXComponentSurfaceId NAPI 创建 NativeWindow
    OH_LOG_INFO(LOG_APP, "[GL] %{public}s: XComponent 已获取 (id=rdpSurface),"
                " 窗口生命周期由 ArkTS SurfaceId 轮询驱动", source);
    OH_LOG_INFO(LOG_APP, "[GL-DIAG] g_surfaceReady=%{public}d g_nativeWindow=%{public}p",
                g_surfaceReady.load(std::memory_order_acquire) ? 1 : 0,
                reinterpret_cast<void*>(g_nativeWindow));
    return true;
}

static bool SetNativeWindowFromSurfaceId(const char* surfaceId, int width, int height) {
    if (surfaceId == nullptr || surfaceId[0] == '\0') {
        OH_LOG_WARN(LOG_APP, "[GL] setXComponentSurfaceId: surfaceId 为空");
        return false;
    }
    std::lock_guard<std::mutex> surfaceLock(g_surfaceStateMutex);
    uint64_t id = strtoull(surfaceId, nullptr, 10);
    const bool hasNativeWindow = g_nativeWindow != 0;
    const bool replaceWindow = Render::ShouldReplaceSurfaceWindow(
        hasNativeWindow, g_surfaceId, id,
        g_surfaceDetached.load(std::memory_order_acquire));
    if (!replaceWindow) {
        g_surfaceReady.store(true, std::memory_order_release);
        if (width > 0) { g_surfaceWidth = static_cast<uint64_t>(width); }
        if (height > 0) { g_surfaceHeight = static_cast<uint64_t>(height); }
        OH_LOG_INFO(LOG_APP, "[GL] setXComponentSurfaceId: reuse surfaceId=%{public}s win=%{public}p size=%{public}llux%{public}llu",
                    surfaceId,
                    reinterpret_cast<void*>(g_nativeWindow),
                    g_surfaceWidth,
                    g_surfaceHeight);
        return true;
    }

    if (hasNativeWindow) {
        // ArkUI 托管 SurfaceId 创建的 NativeWindow 生命周期；后台 detach 后只丢弃裸指针，
        // 重新从当前 SurfaceId 获取可用于 eglCreateWindowSurface 的窗口。
        OH_LOG_WARN(LOG_APP,
                    "[GL] setXComponentSurfaceId: replace stale window oldSurfaceId=%{public}llu newSurfaceId=%{public}s detached=%{public}d win=%{public}p",
                    static_cast<unsigned long long>(g_surfaceId),
                    surfaceId,
                    g_surfaceDetached.load(std::memory_order_acquire) ? 1 : 0,
                    reinterpret_cast<void*>(g_nativeWindow));
        g_nativeWindow = 0;
        g_surfaceReady.store(false, std::memory_order_release);
        g_surfaceIdWindowOwned = false;
        g_surfaceOwnerHandle.store(0, std::memory_order_release);
        g_surfaceDetached.store(true, std::memory_order_release);
        AdvanceRendererGeneration();
    }

    OHNativeWindow* window = nullptr;
    int32_t ret = OH_NativeWindow_CreateNativeWindowFromSurfaceId(id, &window);
    if (ret != 0 || window == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[GL] setXComponentSurfaceId: surfaceId=%{public}s 创建 NativeWindow 失败 ret=%{public}d",
                     surfaceId, ret);
        return false;
    }

    g_nativeWindow = reinterpret_cast<EGLNativeWindowType>(window);
    g_surfaceId = id;
    g_surfaceReady.store(true, std::memory_order_release);
    g_surfaceIdWindowOwned = true;
    g_surfaceOwnerHandle.store(0, std::memory_order_release);
    g_surfaceDetached.store(false, std::memory_order_release);
    AdvanceRendererGeneration();
    if (width > 0) { g_surfaceWidth = static_cast<uint64_t>(width); }
    if (height > 0) { g_surfaceHeight = static_cast<uint64_t>(height); }
    OH_LOG_INFO(LOG_APP, "[GL] setXComponentSurfaceId: surfaceId=%{public}s win=%{public}p size=%{public}llux%{public}llu",
                surfaceId, window, g_surfaceWidth, g_surfaceHeight);
    return true;
}

static void OnSurfaceCreatedCB(OH_NativeXComponent* component, void* window) {
    (void)component;
    std::lock_guard<std::mutex> surfaceLock(g_surfaceStateMutex);
    if (g_surfaceIdWindowOwned && g_nativeWindow != 0) {
        OH_LOG_INFO(LOG_APP, "[GL] XComponent SurfaceCreated: 保留 SurfaceId window=%{public}p callbackWin=%{public}p size=%{public}llux%{public}llu",
                    reinterpret_cast<void*>(g_nativeWindow), window, g_surfaceWidth, g_surfaceHeight);
        const bool wasDetached = g_surfaceDetached.exchange(false, std::memory_order_acq_rel);
        g_surfaceReady.store(true, std::memory_order_release);
        if (wasDetached) {
            AdvanceRendererGeneration();
        }
        return;
    }
    if (window == nullptr) {
        OH_LOG_WARN(LOG_APP, "[GL] XComponent SurfaceCreated: window 为空, 等待 SurfaceId 回调");
        return;
    }
    g_nativeWindow = reinterpret_cast<EGLNativeWindowType>(window);
    g_surfaceId = 0;
    g_surfaceReady.store(true, std::memory_order_release);
    g_surfaceDetached.store(false, std::memory_order_release);
    AdvanceRendererGeneration();
    OH_LOG_INFO(LOG_APP, "[GL] XComponent SurfaceCreated: win=%{public}p size deferred %{public}llux%{public}llu",
                window, g_surfaceWidth, g_surfaceHeight);
}

static void OnSurfaceChangedCB(OH_NativeXComponent* component, void* window) {
    (void)component;
    std::lock_guard<std::mutex> surfaceLock(g_surfaceStateMutex);
    OH_LOG_INFO(LOG_APP, "[GL] XComponent SurfaceChanged: win=%{public}p size deferred %{public}llux%{public}llu",
                window, g_surfaceWidth, g_surfaceHeight);
}

// 空实现 stub — 防止 DispatchTouchEvent=NULL 导致框架 OnSurfaceDestroyed 中调用 NULL 指针崩溃
static void DispatchTouchEventStub(OH_NativeXComponent* component, void* window) {
    (void)component;
    (void)window;
}

static void OnSurfaceDestroyedCB(OH_NativeXComponent* component, void* window) {
    (void)component;
    (void)window;
    std::lock_guard<std::mutex> surfaceLock(g_surfaceStateMutex);
    // 仅重置 flag — 不调用任何框架 API 避免触发框架内部崩溃路径
    OH_LOG_INFO(LOG_APP, "[GL] XComponent SurfaceDestroyed (win=%{public}p owned=%{public}d)",
                window, g_surfaceIdWindowOwned ? 1 : 0);
    g_surfaceReady.store(false, std::memory_order_release);
    g_surfaceDetached.store(true, std::memory_order_release);
    g_surfaceOwnerHandle.store(0, std::memory_order_release);
    AdvanceRendererGeneration();
    // 注意: 不在这里销毁 NativeWindow — 框架会在 detach 后自行清理。
    // 如果 SurfaceId 创建的 window 需要销毁, 由 ArkTS 侧 onSurfaceDestroyed 触发。
}

static void MarkXComponentSurfaceDestroyed(const char* source) {
    std::lock_guard<std::mutex> surfaceLock(g_surfaceStateMutex);
    OH_LOG_INFO(LOG_APP, "[GL] %{public}s: mark surface destroyed win=%{public}p owned=%{public}d",
                source,
                reinterpret_cast<void*>(g_nativeWindow),
                g_surfaceIdWindowOwned ? 1 : 0);
    g_surfaceReady.store(false, std::memory_order_release);
    g_surfaceDetached.store(true, std::memory_order_release);
    g_surfaceOwnerHandle.store(0, std::memory_order_release);
    AdvanceRendererGeneration();
    // API 23 上 SurfaceId/native window 由 ArkUI XComponent 生命周期托管。
    // detach 后继续持有这个裸指针容易在 egl/native window 释放路径触发 vendor double free。
    g_nativeWindow = 0;
    g_surfaceId = 0;
    g_surfaceIdWindowOwned = false;
}

// ============================================================
// 着色器源码
// ============================================================

/** 顶点着色器 — 全屏四边形直通 */
static const char* VERTEX_SHADER = R"(#version 300 es
precision mediump float;
layout(location = 0) in vec2 aPosition;
layout(location = 1) in vec2 aTexCoord;
out vec2 vTexCoord;

void main() {
    gl_Position = vec4(aPosition, 0.0, 1.0);
    vTexCoord = aTexCoord;
}
)";

/**
 * 片段着色器 — NV12→RGB 转换 + 外部纹理采样
 *
 * NV12 格式：Y 平面全分辨率 + UV 交错平面半分辨率
 * 此着色器假设输入为单纹理的亮度和色度数据
 *
 * 简化版：直接采样外部 OES 纹理 (用于非 NV12 或已预转换的纹理)
 * 完整 NV12 版本需要两个纹理采样器和 YUV→RGB 矩阵
 */
static const char* FRAGMENT_SHADER_SIMPLE = R"(#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision mediump float;
in vec2 vTexCoord;
out vec4 fragColor;
uniform samplerExternalOES uTexture;

void main() {
    fragColor = texture(uTexture, vTexCoord);
}
)";

/** BGRA→RGB 片段着色器 (RDP GDI 原始像素直出) */
static const char* FRAGMENT_SHADER_BGRA = R"(#version 300 es
precision mediump float;
in vec2 vTexCoord;
out vec4 fragColor;
uniform sampler2D uTexture;

void main() {
    vec4 bgra = texture(uTexture, vTexCoord);
    fragColor = vec4(bgra.b, bgra.g, bgra.r, bgra.a);
}
)";

/** NV12→RGB 片段着色器 (双平面) */
static const char* FRAGMENT_SHADER_NV12 =R"(#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision mediump float;

in vec2 vTexCoord;
out vec4 fragColor;

uniform samplerExternalOES uTextureY;   // Y 平面 (全分辨率)
uniform samplerExternalOES uTextureUV;  // UV 平面 (半分辨率)

// YUV→RGB 转换矩阵 (BT.601)
const mat3 YUV2RGB = mat3(
    1.0,       1.0,      1.0,
    0.0,      -0.34413,  1.772,
    1.402,    -0.71414,  0.0
);

void main() {
    float y  = texture(uTextureY, vTexCoord).r;
    float u  = texture(uTextureUV, vTexCoord).r - 0.5;
    float v  = texture(uTextureUV, vTexCoord).a - 0.5;

    vec3 yuv = vec3(y, u, v);
    vec3 rgb = YUV2RGB * yuv;

    fragColor = vec4(rgb, 1.0);
}
)";

// ============================================================
// 全屏四边形顶点数据
// ============================================================

// 位置 (x, y) + 纹理坐标 (u, v)
static const float QUAD_VERTICES[] = {
    // 位置         纹理坐标
    -1.0f,  1.0f,   0.0f, 0.0f,  // 左上
    -1.0f, -1.0f,   0.0f, 1.0f,  // 左下
     1.0f,  1.0f,   1.0f, 0.0f,  // 右上
     1.0f, -1.0f,   1.0f, 1.0f,  // 右下
};

// ============================================================
// GLRenderer 实现
// ============================================================

GLRenderer::GLRenderer()
    : eglDisplay_(EGL_NO_DISPLAY), eglContext_(EGL_NO_CONTEXT),
      eglSurface_(EGL_NO_SURFACE), eglConfig_(nullptr),
      shaderProgram_(0), samplerLocation_(0),
      rawShaderProgram_(0), rawTexture_(0), rawSamplerLocation_(0),
      rawTextureWidth_(0), rawTextureHeight_(0),
      vbo_(0), vao_(0),
      width_(0), height_(0), sourceWidth_(0), sourceHeight_(0),
      lastVpX_(0), lastVpY_(0), lastVpW_(0), lastVpH_(0),
      canvasScale_(1.0), canvasPanX_(0.0), canvasPanY_(0.0),
      viewportSnapshotVersion_(0), snapshotVpX_(0), snapshotVpY_(0),
      snapshotVpW_(0), snapshotVpH_(0), snapshotSourceWidth_(0),
      snapshotSourceHeight_(0), snapshotSurfaceWidth_(0), snapshotSurfaceHeight_(0),
      rawFrameCount_(0), rendererHandle_(0), initialized_(false), destroying_(false) {}

GLRenderer::~GLRenderer() {
    Destroy();
}

void GLRenderer::SetRendererHandle(int64_t handle) {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    rendererHandle_ = handle > 0 ? handle : 0;
}

bool GLRenderer::MakeCurrent() {
    if (eglDisplay_ == EGL_NO_DISPLAY || eglSurface_ == EGL_NO_SURFACE ||
        eglContext_ == EGL_NO_CONTEXT) {
        OH_LOG_WARN(LOG_APP, "[GL] eglMakeCurrent skipped: EGL not ready");
        return false;
    }
    if (g_surfaceDetached.load(std::memory_order_acquire)) {
        OH_LOG_WARN(LOG_APP, "[GL] eglMakeCurrent skipped: XComponent surface already detached");
        return false;
    }
    if (!eglMakeCurrent(eglDisplay_, eglSurface_, eglSurface_, eglContext_)) {
        OH_LOG_WARN(LOG_APP, "[GL] eglMakeCurrent failed: %{public}x", eglGetError());
        return false;
    }
    return true;
}

void GLRenderer::ReleaseCurrent() {
    if (eglDisplay_ != EGL_NO_DISPLAY) {
        eglMakeCurrent(eglDisplay_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }
}

int GLRenderer::Init(const std::string& xcomponentId, int width, int height) {
    OH_LOG_INFO(LOG_APP, "[GL] 初始化渲染器: %{public}s, %{public}dx%{public}d",
                xcomponentId.c_str(), width, height);

    width_ = width;
    height_ = height;
    sourceWidth_ = width;
    sourceHeight_ = height;
    PublishViewportSnapshot(0, 0, width, height);

    if (!InitEGL(xcomponentId)) {
        OH_LOG_ERROR(LOG_APP, "[GL] EGL 初始化失败");
        return -1;
    }

    if (!InitGL()) {
        OH_LOG_ERROR(LOG_APP, "[GL] OpenGL 初始化失败");
        return -2;
    }

    initialized_ = true;
    // 初始化在 UI/NAPI 线程完成；释放上下文，后续由实际渲染线程按帧绑定。
    ReleaseCurrent();
    OH_LOG_INFO(LOG_APP, "[GL] 渲染器初始化成功");
    return 0;
}

bool GLRenderer::InitEGL(const std::string& xcomponentId) {
    // 获取默认显示
    eglDisplay_ = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (eglDisplay_ == EGL_NO_DISPLAY) {
        OH_LOG_ERROR(LOG_APP, "[GL] eglGetDisplay 失败: %{public}x", eglGetError());
        return false;
    }

    // 初始化 EGL
    EGLint major, minor;
    if (!eglInitialize(eglDisplay_, &major, &minor)) {
        OH_LOG_ERROR(LOG_APP, "[GL] eglInitialize 失败: %{public}x", eglGetError());
        return false;
    }
    OH_LOG_INFO(LOG_APP, "[GL] EGL 版本 %{public}d.%{public}d", major, minor);

    // 选择 EGL 配置
    EGLint configAttribs[] = {
        EGL_SURFACE_TYPE,    EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE,        8,
        EGL_GREEN_SIZE,      8,
        EGL_BLUE_SIZE,       8,
        EGL_ALPHA_SIZE,      8,
        EGL_DEPTH_SIZE,      0,
        EGL_STENCIL_SIZE,    0,
        EGL_NONE
    };

    EGLint numConfigs;
    if (!eglChooseConfig(eglDisplay_, configAttribs, &eglConfig_, 1, &numConfigs) ||
        numConfigs < 1) {
        OH_LOG_ERROR(LOG_APP, "[GL] eglChooseConfig 失败: %{public}x", eglGetError());
        return false;
    }

    // 创建 EGL 上下文 (OpenGL ES 3.0)
    EGLint contextAttribs[] = {
        EGL_CONTEXT_CLIENT_VERSION, 3,
        EGL_NONE
    };
    eglContext_ = eglCreateContext(eglDisplay_, eglConfig_,
                                    EGL_NO_CONTEXT, contextAttribs);
    if (eglContext_ == EGL_NO_CONTEXT) {
        OH_LOG_ERROR(LOG_APP, "[GL] eglCreateContext 失败: %{public}x", eglGetError());
        return false;
    }

    // R1: 优先使用 XComponent 窗口表面, 不可用时回退 Pbuffer
    bool surfaceReady = false;
    EGLNativeWindowType nativeWindow = 0;
    uint64_t surfaceWidth = 0;
    uint64_t surfaceHeight = 0;
    {
        std::lock_guard<std::mutex> surfaceLock(g_surfaceStateMutex);
        surfaceReady = g_surfaceReady.load(std::memory_order_acquire);
        nativeWindow = g_nativeWindow;
        surfaceWidth = g_surfaceWidth;
        surfaceHeight = g_surfaceHeight;
        OH_LOG_INFO(LOG_APP, "[GL-DIAG] InitEGL: g_surfaceReady=%{public}d g_nativeWindow=%{public}p",
                    surfaceReady ? 1 : 0,
                    reinterpret_cast<void*>(nativeWindow));
    }
    bool windowSurfaceCreated = false;
    if (surfaceReady && nativeWindow != 0) {
        eglSurface_ = eglCreateWindowSurface(eglDisplay_, eglConfig_, nativeWindow, nullptr);
        if (eglSurface_ == EGL_NO_SURFACE) {
            OH_LOG_WARN(LOG_APP, "[GL] eglCreateWindowSurface 失败(%{public}x), 回退 Pbuffer", eglGetError());
        } else {
            windowSurfaceCreated = true;
            OH_LOG_INFO(LOG_APP, "[GL] ✓ XComponent window surface, %{public}llux%{public}llu",
                        surfaceWidth, surfaceHeight);
            width_ = static_cast<int>(surfaceWidth);
            height_ = static_cast<int>(surfaceHeight);
        }
    } else {
        OH_LOG_WARN(LOG_APP, "[GL] XComponent surface 未就绪 (ready=%{public}d win=%{public}p), 回退 Pbuffer",
                    surfaceReady ? 1 : 0,
                    reinterpret_cast<void*>(nativeWindow));
    }
    if (eglSurface_ == EGL_NO_SURFACE) {
        // 回退: Pbuffer 离屏 (无 XComponent 或窗口创建失败时使用)
        EGLint surfaceAttribs[] = {
            EGL_WIDTH,  width_,
            EGL_HEIGHT, height_,
            EGL_NONE
        };
        eglSurface_ = eglCreatePbufferSurface(eglDisplay_, eglConfig_, surfaceAttribs);
        if (eglSurface_ == EGL_NO_SURFACE) {
            OH_LOG_ERROR(LOG_APP, "[GL] eglCreatePbufferSurface 失败: %{public}x", eglGetError());
            return false;
        }
        OH_LOG_INFO(LOG_APP, "[GL] Pbuffer 离屏渲染 %{public}dx%{public}d", width_, height_);
    }

    // 绑定上下文
    if (!eglMakeCurrent(eglDisplay_, eglSurface_, eglSurface_, eglContext_)) {
        OH_LOG_ERROR(LOG_APP, "[GL] eglMakeCurrent 失败: %{public}x", eglGetError());
        return false;
    }

    const char* surfType = windowSurfaceCreated ? "window surface" : "Pbuffer";
    OH_LOG_INFO(LOG_APP, "[GL] EGL 初始化完成 (%{public}s %{public}dx%{public}d)", surfType, width_, height_);
    return true;
}

bool GLRenderer::InitGL() {
    // 创建 NV12/OES 着色器程序 (硬解路径)
    shaderProgram_ = CreateShaderProgram();
    if (shaderProgram_ == 0) {
        return false;
    }
    samplerLocation_ = glGetUniformLocation(shaderProgram_, "uTexture");

    // 创建 BGRA 着色器程序 (RDP GDI 路径)
    rawShaderProgram_ = CreateRawShaderProgram();
    rawSamplerLocation_ = rawShaderProgram_ > 0
        ? glGetUniformLocation(rawShaderProgram_, "uTexture") : 0;

    // 创建全屏四边形几何体
    CreateQuadGeometry();

    // 设置视口
    glViewport(0, 0, width_, height_);

    // 禁用深度测试 (2D 渲染不需要)
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_CULL_FACE);

    // 检查错误
    GLenum err = glGetError();
    if (err != GL_NO_ERROR) {
        OH_LOG_WARN(LOG_APP, "[GL] OpenGL 初始化后有未处理错误: %{public}x", err);
    }

    OH_LOG_INFO(LOG_APP, "[GL] OpenGL ES 初始化完成, shader=%{public}u", shaderProgram_);
    return true;
}

GLuint GLRenderer::CompileShader(GLenum type, const char* source) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);

    GLint compiled;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (!compiled) {
        GLint infoLen = 0;
        glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &infoLen);
        if (infoLen > 1) {
            char* infoLog = new char[infoLen];
            glGetShaderInfoLog(shader, infoLen, nullptr, infoLog);
            OH_LOG_ERROR(LOG_APP, "[GL] 着色器编译失败: %{public}s", infoLog);
            delete[] infoLog;
        }
        glDeleteShader(shader);
        return 0;
    }

    return shader;
}

GLuint GLRenderer::CreateShaderProgram() {
    // 当前使用简化版着色器 (单纹理外部 OES)
    GLuint vertShader = CompileShader(GL_VERTEX_SHADER, VERTEX_SHADER);
    GLuint fragShader = CompileShader(GL_FRAGMENT_SHADER, FRAGMENT_SHADER_SIMPLE);
    // 后续替换为 FRAGMENT_SHADER_NV12 以支持真实 NV12 解码数据

    if (vertShader == 0 || fragShader == 0) {
        if (vertShader) glDeleteShader(vertShader);
        if (fragShader) glDeleteShader(fragShader);
        return 0;
    }

    GLuint program = glCreateProgram();
    glAttachShader(program, vertShader);
    glAttachShader(program, fragShader);
    glLinkProgram(program);

    GLint linked;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked) {
        GLint infoLen = 0;
        glGetProgramiv(program, GL_INFO_LOG_LENGTH, &infoLen);
        if (infoLen > 1) {
            char* infoLog = new char[infoLen];
            glGetProgramInfoLog(program, infoLen, nullptr, infoLog);
            OH_LOG_ERROR(LOG_APP, "[GL] 着色器链接失败: %{public}s", infoLog);
            delete[] infoLog;
        }
        glDeleteProgram(program);
        program = 0;
    }

    // 着色器对象在链接后可以删除
    glDetachShader(program, vertShader);
    glDetachShader(program, fragShader);
    glDeleteShader(vertShader);
    glDeleteShader(fragShader);

    return program;
}

GLuint GLRenderer::CreateRawShaderProgram() {
    GLuint vertShader = CompileShader(GL_VERTEX_SHADER, VERTEX_SHADER);
    GLuint fragShader = CompileShader(GL_FRAGMENT_SHADER, FRAGMENT_SHADER_BGRA);

    if (vertShader == 0 || fragShader == 0) {
        if (vertShader) glDeleteShader(vertShader);
        if (fragShader) glDeleteShader(fragShader);
        return 0;
    }

    GLuint program = glCreateProgram();
    glAttachShader(program, vertShader);
    glAttachShader(program, fragShader);
    glLinkProgram(program);

    GLint linked;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (!linked) {
        GLint infoLen = 0;
        glGetProgramiv(program, GL_INFO_LOG_LENGTH, &infoLen);
        if (infoLen > 1) {
            char* infoLog = new char[infoLen];
            glGetProgramInfoLog(program, infoLen, nullptr, infoLog);
            OH_LOG_ERROR(LOG_APP, "[GL] BGRA 着色器链接失败: %{public}s", infoLog);
            delete[] infoLog;
        }
        glDeleteProgram(program);
        program = 0;
    }

    glDetachShader(program, vertShader);
    glDetachShader(program, fragShader);
    glDeleteShader(vertShader);
    glDeleteShader(fragShader);

    return program;
}

void GLRenderer::SetupRawTexture(int width, int height) {
    if (rawTexture_ != 0) {
        glDeleteTextures(1, &rawTexture_);
        rawTexture_ = 0;
    }
    glGenTextures(1, &rawTexture_);
    glBindTexture(GL_TEXTURE_2D, rawTexture_);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    // 预分配 BGRA 纹理存储
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    GLenum err = glGetError();
    if (err != GL_NO_ERROR) {
        OH_LOG_WARN(LOG_APP, "[GL] BGRA texture setup: %{public}dx%{public}d err=%{public}x",
                    width, height, err);
    }
}

void GLRenderer::RenderRawBGRA(const uint8_t* bgraData, int width, int height, int stride) {
    (void)PresentRawBGRA(bgraData, width, height, stride, 0);
}

void GLRenderer::RenderRawBGRARect(const uint8_t* bgraData, int width, int height, int stride,
                                   int dirtyX, int dirtyY, int dirtyWidth, int dirtyHeight) {
    (void)PresentRawBGRARect(bgraData, width, height, stride,
                            dirtyX, dirtyY, dirtyWidth, dirtyHeight, 0);
}

RdpPresentMetrics GLRenderer::PresentRawBGRA(const uint8_t* bgraData, int width, int height,
                                             int stride, uint64_t generation) {
    return RenderRawBGRAInternal(bgraData, width, height, stride,
                                 false, 0, 0, 0, 0, generation);
}

RdpPresentMetrics GLRenderer::PresentRawBGRARect(
    const uint8_t* bgraData, int width, int height, int stride,
    int dirtyX, int dirtyY, int dirtyWidth, int dirtyHeight, uint64_t generation) {
    return RenderRawBGRAInternal(bgraData, width, height, stride, true,
                                 dirtyX, dirtyY, dirtyWidth, dirtyHeight, generation);
}

bool GLRenderer::IsPresentationReady() {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    return !destroying_ && initialized_ && rawShaderProgram_ != 0 &&
        g_surfaceReady.load(std::memory_order_acquire) &&
        !g_surfaceDetached.load(std::memory_order_acquire);
}

RdpPresentMetrics GLRenderer::RenderRawBGRAInternal(
    const uint8_t* bgraData, int width, int height, int stride, bool useDirtyRect,
    int dirtyX, int dirtyY, int dirtyWidth, int dirtyHeight, uint64_t generation) {
    RdpPresentMetrics metrics;
    metrics.generation = generation;
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    using clock = std::chrono::steady_clock;
    if (generation != 0 &&
        generation != g_rendererGeneration.load(std::memory_order_acquire)) {
        metrics.result = RdpPresentResult::GenerationMismatch;
        return metrics;
    }
    if (g_surfaceDetached.load(std::memory_order_acquire) ||
        !g_surfaceReady.load(std::memory_order_acquire)) {
        metrics.result = RdpPresentResult::SurfaceDetached;
        return metrics;
    }
    if (destroying_ || !initialized_ || rawShaderProgram_ == 0) {
        metrics.result = RdpPresentResult::RendererNotReady;
        return metrics;
    }
    if (!bgraData || width <= 0 || height <= 0) {
        metrics.result = RdpPresentResult::InvalidFrame;
        return metrics;
    }
    if (!MakeCurrent()) {
        metrics.result = RdpPresentResult::MakeCurrentFailed;
        return metrics;
    }

    const auto uploadBeginAt = clock::now();
    int rowStride = stride > 0 ? stride : width * 4;
    const bool textureWouldChange =
        rawTexture_ == 0 || width != rawTextureWidth_ || height != rawTextureHeight_;
    if (useDirtyRect && textureWouldChange) {
        ReleaseCurrent();
        OH_LOG_WARN(LOG_APP,
                    "[GL] RenderRawBGRA dirty skipped: texture not initialized for %{public}dx%{public}d",
                    width, height);
        metrics.result = RdpPresentResult::RendererNotReady;
        return metrics;
    }

    // 首次或软解输出尺寸变化时重建纹理；sourceWidth_/sourceHeight_ 保持远端真实尺寸用于坐标映射。
    if (textureWouldChange) {
        rawTextureWidth_ = width;
        rawTextureHeight_ = height;
        SetupRawTexture(width, height);
    }

    const bool dirtyInBounds = useDirtyRect &&
        dirtyX >= 0 && dirtyY >= 0 && dirtyWidth > 0 && dirtyHeight > 0 &&
        dirtyX < width && dirtyY < height &&
        dirtyWidth <= width - dirtyX && dirtyHeight <= height - dirtyY;
    const bool partialUpload = dirtyInBounds &&
        (dirtyX != 0 || dirtyY != 0 || dirtyWidth != width || dirtyHeight != height);
    const int uploadX = partialUpload ? dirtyX : 0;
    const int uploadY = partialUpload ? dirtyY : 0;
    const int uploadW = partialUpload ? dirtyWidth : width;
    const int uploadH = partialUpload ? dirtyHeight : height;
    const uint8_t* uploadData = bgraData;

    // 上传 BGRA 像素数据到 GL 纹理；局部上传时保留原始 row length，避免行尾错位。
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, rawTexture_);
    if (partialUpload || rowStride != width * 4) {
        glPixelStorei(GL_UNPACK_ROW_LENGTH, rowStride / 4);
    }
    glTexSubImage2D(GL_TEXTURE_2D, 0, uploadX, uploadY, uploadW, uploadH,
                    GL_RGBA, GL_UNSIGNED_BYTE, uploadData);
    if (partialUpload || rowStride != width * 4) {
        glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    }
    const auto uploadAt = clock::now();

    // Renderer snapshots use top-left coordinates so ArkTS hit testing and
    // cursor projection share the same canvas contract as the gesture layer.
    int vpX = 0, vpY = 0, vpW = width_, vpH = height_;
    CalculateViewport(width, height, vpX, vpY, vpW, vpH);

    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glViewport(vpX, height_ - vpY - vpH, vpW, vpH);

    // 缓存视口信息供 ArkTS 查询坐标映射
    lastVpX_ = vpX;
    lastVpY_ = vpY;
    lastVpW_ = vpW;
    lastVpH_ = vpH;
    PublishViewportSnapshot(vpX, vpY, vpW, vpH);

    glUseProgram(rawShaderProgram_);
    glUniform1i(rawSamplerLocation_, 0);

    glBindVertexArray(vao_);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindVertexArray(0);
    const auto drawAt = clock::now();

    const bool swapped = eglSwapBuffers(eglDisplay_, eglSurface_) == EGL_TRUE;
    const auto swapAt = clock::now();

    GLenum err = glGetError();
    if (err != GL_NO_ERROR) {
        OH_LOG_WARN(LOG_APP, "[GL] RenderRawBGRA 后 GL 错误: %{public}x", err);
    }
    ReleaseCurrent();
    rawFrameCount_++;
    metrics.uploadUs = std::chrono::duration_cast<std::chrono::microseconds>(
        uploadAt - uploadBeginAt).count();
    metrics.drawUs = std::chrono::duration_cast<std::chrono::microseconds>(
        drawAt - uploadAt).count();
    metrics.swapUs = std::chrono::duration_cast<std::chrono::microseconds>(
        swapAt - drawAt).count();
    metrics.result = swapped ? RdpPresentResult::Presented : RdpPresentResult::SwapFailed;
    const auto nowUs = std::chrono::duration_cast<std::chrono::microseconds>(
        swapAt.time_since_epoch()).count();
    presentationMetrics_.recordPresent(nowUs, metrics);
    return metrics;
}

void GLRenderer::CreateQuadGeometry() {
    // VAO (GLES3)
    glGenVertexArrays(1, &vao_);
    glBindVertexArray(vao_);

    // VBO
    glGenBuffers(1, &vbo_);
    glBindBuffer(GL_ARRAY_BUFFER, vbo_);
    glBufferData(GL_ARRAY_BUFFER, sizeof(QUAD_VERTICES), QUAD_VERTICES, GL_STATIC_DRAW);

    // 位置属性 (location=0)
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float),
                          reinterpret_cast<void*>(0));
    glEnableVertexAttribArray(0);

    // 纹理坐标属性 (location=1)
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float),
                          reinterpret_cast<void*>(2 * sizeof(float)));
    glEnableVertexAttribArray(1);

    glBindVertexArray(0);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
}

void GLRenderer::RenderFrame(GLuint textureId) {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    using clock = std::chrono::steady_clock;
    const auto drawBeginAt = clock::now();
    if (destroying_ || g_surfaceDetached.load(std::memory_order_acquire) || !initialized_) {
        OH_LOG_WARN(LOG_APP, "[GL] 渲染器未初始化, 跳过渲染");
        return;
    }

    // 绑定上下文
    // 清屏
    if (!MakeCurrent()) {
        return;
    }

    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    // 使用着色器程序
    int viewportX = 0;
    int viewportY = 0;
    int viewportW = width_;
    int viewportH = height_;
    CalculateViewport(sourceWidth_, sourceHeight_, viewportX, viewportY, viewportW, viewportH);
    glViewport(viewportX, height_ - viewportY - viewportH, viewportW, viewportH);

    // 缓存视口信息供 ArkTS 查询坐标映射
    lastVpX_ = viewportX;
    lastVpY_ = viewportY;
    lastVpW_ = viewportW;
    lastVpH_ = viewportH;
    PublishViewportSnapshot(viewportX, viewportY, viewportW, viewportH);

    glUseProgram(shaderProgram_);

    // 绑定外部纹理
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, textureId);
    glUniform1i(samplerLocation_, 0);

    // 绘制全屏四边形
    glBindVertexArray(vao_);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindVertexArray(0);

    const auto drawAt = clock::now();
    // 交换缓冲区
    const bool swapped = eglSwapBuffers(eglDisplay_, eglSurface_) == EGL_TRUE;
    const auto swapAt = clock::now();

    GLenum err = glGetError();
    if (err != GL_NO_ERROR) {
        OH_LOG_WARN(LOG_APP, "[GL] 渲染后 GL 错误: %{public}x", err);
    }

    RdpPresentMetrics metrics;
    metrics.result = swapped ? RdpPresentResult::Presented : RdpPresentResult::SwapFailed;
    metrics.drawUs = std::chrono::duration_cast<std::chrono::microseconds>(
        drawAt - drawBeginAt).count();
    metrics.swapUs = std::chrono::duration_cast<std::chrono::microseconds>(
        swapAt - drawAt).count();
    const auto nowUs = std::chrono::duration_cast<std::chrono::microseconds>(
        swapAt.time_since_epoch()).count();
    presentationMetrics_.recordPresent(nowUs, metrics);
}

void GLRenderer::Resize(int width, int height) {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    width_ = width;
    height_ = height;
    CalculateViewport(sourceWidth_, sourceHeight_, lastVpX_, lastVpY_, lastVpW_, lastVpH_);
    PublishViewportSnapshot(lastVpX_, lastVpY_, lastVpW_, lastVpH_);
    OH_LOG_INFO(LOG_APP, "[GL] 渲染区域大小改为 %{public}dx%{public}d", width, height);
}

void GLRenderer::SetSourceSize(int width, int height) {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    if (width <= 0 || height <= 0) {
        return;
    }
    if (sourceWidth_ == width && sourceHeight_ == height) {
        return;
    }
    sourceWidth_ = width;
    sourceHeight_ = height;
    CalculateViewport(sourceWidth_, sourceHeight_, lastVpX_, lastVpY_, lastVpW_, lastVpH_);
    PublishViewportSnapshot(lastVpX_, lastVpY_, lastVpW_, lastVpH_);
    OH_LOG_INFO(LOG_APP, "[GL] 视频源尺寸更新为 %{public}dx%{public}d", width, height);
}

void GLRenderer::SetCanvasTransform(double scale, double panX, double panY) {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    if (!std::isfinite(scale) || scale <= 0.0 || !std::isfinite(panX) || !std::isfinite(panY)) {
        OH_LOG_WARN(LOG_APP, "[GL] ignored invalid canvas transform");
        return;
    }
    canvasScale_ = std::clamp(scale, 0.05, 12.0);
    canvasPanX_ = panX;
    canvasPanY_ = panY;
    CalculateViewport(sourceWidth_, sourceHeight_, lastVpX_, lastVpY_, lastVpW_, lastVpH_);
    PublishViewportSnapshot(lastVpX_, lastVpY_, lastVpW_, lastVpH_);
}

void GLRenderer::CalculateViewport(int sourceWidth, int sourceHeight,
                                   int& vpX, int& vpY, int& vpW, int& vpH) const {
    vpX = 0;
    vpY = 0;
    vpW = width_;
    vpH = height_;
    if (width_ <= 0 || height_ <= 0 || sourceWidth <= 0 || sourceHeight <= 0) {
        return;
    }
    const double scaleW = static_cast<double>(width_) / static_cast<double>(sourceWidth);
    const double scaleH = static_cast<double>(height_) / static_cast<double>(sourceHeight);
    const double contain = std::min(scaleW, scaleH);
    const double scale = contain * canvasScale_;
    vpW = std::max(1, static_cast<int>(std::lround(static_cast<double>(sourceWidth) * scale)));
    vpH = std::max(1, static_cast<int>(std::lround(static_cast<double>(sourceHeight) * scale)));
    vpX = static_cast<int>(std::lround(static_cast<double>(width_ - vpW) / 2.0 + canvasPanX_));
    vpY = static_cast<int>(std::lround(static_cast<double>(height_ - vpH) / 2.0 + canvasPanY_));
}

void GLRenderer::GetViewportSnapshot(int& vpX, int& vpY, int& vpW, int& vpH,
                                     int& sourceWidth, int& sourceHeight,
                                     int& surfaceWidth, int& surfaceHeight) const {
    for (;;) {
        const uint64_t before = viewportSnapshotVersion_.load(std::memory_order_acquire);
        if ((before & 1U) != 0U) {
            continue;
        }
        vpX = snapshotVpX_.load(std::memory_order_relaxed);
        vpY = snapshotVpY_.load(std::memory_order_relaxed);
        vpW = snapshotVpW_.load(std::memory_order_relaxed);
        vpH = snapshotVpH_.load(std::memory_order_relaxed);
        sourceWidth = snapshotSourceWidth_.load(std::memory_order_relaxed);
        sourceHeight = snapshotSourceHeight_.load(std::memory_order_relaxed);
        surfaceWidth = snapshotSurfaceWidth_.load(std::memory_order_relaxed);
        surfaceHeight = snapshotSurfaceHeight_.load(std::memory_order_relaxed);
        const uint64_t after = viewportSnapshotVersion_.load(std::memory_order_acquire);
        if (before == after) {
            return;
        }
    }
}

void GLRenderer::PublishViewportSnapshot(int vpX, int vpY, int vpW, int vpH) {
    viewportSnapshotVersion_.fetch_add(1, std::memory_order_acq_rel);
    snapshotVpX_.store(vpX, std::memory_order_relaxed);
    snapshotVpY_.store(vpY, std::memory_order_relaxed);
    snapshotVpW_.store(vpW, std::memory_order_relaxed);
    snapshotVpH_.store(vpH, std::memory_order_relaxed);
    snapshotSourceWidth_.store(sourceWidth_, std::memory_order_relaxed);
    snapshotSourceHeight_.store(sourceHeight_, std::memory_order_relaxed);
    snapshotSurfaceWidth_.store(width_, std::memory_order_relaxed);
    snapshotSurfaceHeight_.store(height_, std::memory_order_relaxed);
    viewportSnapshotVersion_.fetch_add(1, std::memory_order_release);
}

RdpPresentationMetricsSnapshot GLRenderer::GetPresentationStats() {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    const auto nowUs = std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    return presentationMetrics_.snapshot(nowUs);
}

void GLRenderer::Destroy() {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    if (destroying_) {
        OH_LOG_INFO(LOG_APP, "[GL] Destroy skipped: already destroying");
        return;
    }
    destroying_ = true;
    const bool detachedWindowSurface =
        g_surfaceDetached.load(std::memory_order_acquire) && eglSurface_ != EGL_NO_SURFACE;
    EGLNativeWindowType surfaceWindow = 0;
    bool surfaceWindowOwned = false;
    {
        std::lock_guard<std::mutex> surfaceLock(g_surfaceStateMutex);
        surfaceWindow = g_nativeWindow;
        surfaceWindowOwned = g_surfaceIdWindowOwned;
    }
    OH_LOG_INFO(LOG_APP,
                "[GL] Destroy begin init=%{public}d display=%{public}p surface=%{public}p context=%{public}p detached=%{public}d win=%{public}p owned=%{public}d",
                initialized_ ? 1 : 0,
                reinterpret_cast<void*>(eglDisplay_),
                reinterpret_cast<void*>(eglSurface_),
                reinterpret_cast<void*>(eglContext_),
                detachedWindowSurface ? 1 : 0,
                reinterpret_cast<void*>(surfaceWindow),
                surfaceWindowOwned ? 1 : 0);
    bool hasCurrent = false;
    if (initialized_ && !detachedWindowSurface) {
        hasCurrent = MakeCurrent();
    } else if (detachedWindowSurface) {
        OH_LOG_WARN(LOG_APP, "[GL] Destroy: skip eglMakeCurrent because surface is detached");
    }
    if (hasCurrent && shaderProgram_) {
        glDeleteProgram(shaderProgram_);
        shaderProgram_ = 0;
    }
    if (hasCurrent && rawShaderProgram_) {
        glDeleteProgram(rawShaderProgram_);
        rawShaderProgram_ = 0;
    }
    if (hasCurrent && rawTexture_) {
        glDeleteTextures(1, &rawTexture_);
        rawTexture_ = 0;
        rawTextureWidth_ = 0;
        rawTextureHeight_ = 0;
    }
    if (hasCurrent && vbo_) {
        glDeleteBuffers(1, &vbo_);
        vbo_ = 0;
    }
    if (hasCurrent && vao_) {
        glDeleteVertexArrays(1, &vao_);
        vao_ = 0;
    }
    if (eglDisplay_ != EGL_NO_DISPLAY) {
        if (hasCurrent) {
            eglMakeCurrent(eglDisplay_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        }
        if (detachedWindowSurface) {
            OH_LOG_WARN(LOG_APP, "[GL] Destroy: surface already detached, skip EGL/window teardown to avoid double free");
            shaderProgram_ = 0;
            rawShaderProgram_ = 0;
            rawTexture_ = 0;
            rawTextureWidth_ = 0;
            rawTextureHeight_ = 0;
            vbo_ = 0;
            vao_ = 0;
            eglSurface_ = EGL_NO_SURFACE;
            eglContext_ = EGL_NO_CONTEXT;
            eglDisplay_ = EGL_NO_DISPLAY;
        } else if (eglSurface_ != EGL_NO_SURFACE) {
            eglDestroySurface(eglDisplay_, eglSurface_);
            eglSurface_ = EGL_NO_SURFACE;
            if (eglContext_ != EGL_NO_CONTEXT) {
                eglDestroyContext(eglDisplay_, eglContext_);
                eglContext_ = EGL_NO_CONTEXT;
            }
            eglTerminate(eglDisplay_);
            eglDisplay_ = EGL_NO_DISPLAY;
        } else {
            if (eglContext_ != EGL_NO_CONTEXT) {
                eglDestroyContext(eglDisplay_, eglContext_);
                eglContext_ = EGL_NO_CONTEXT;
            }
            eglTerminate(eglDisplay_);
            eglDisplay_ = EGL_NO_DISPLAY;
        }
    }
    {
        std::lock_guard<std::mutex> surfaceLock(g_surfaceStateMutex);
        const bool ownsSurfaceWindow = g_surfaceIdWindowOwned && g_nativeWindow != 0 &&
            rendererHandle_ > 0 &&
            g_surfaceOwnerHandle.load(std::memory_order_acquire) == rendererHandle_;
        if (ownsSurfaceWindow) {
            OH_LOG_INFO(LOG_APP, "[GL] Destroy: clear renderer-owned XComponent NativeWindow state win=%{public}p",
                        reinterpret_cast<void*>(g_nativeWindow));
            g_nativeWindow = 0;
            g_surfaceId = 0;
            g_surfaceReady.store(false, std::memory_order_release);
            g_surfaceIdWindowOwned = false;
            g_surfaceOwnerHandle.store(0, std::memory_order_release);
        }
    }
    initialized_ = false;
    destroying_ = false;
    OH_LOG_INFO(LOG_APP, "[GL] 渲染器已销毁");
}

// ============================================================
// NAPI 包装
// ============================================================

namespace {

// 存储活跃的渲染器实例 (NAPI 层传回的用户数据中)
struct RendererContext {
    std::shared_ptr<GLRenderer> renderer;
    uint64_t generation = 0;
};

// 活跃渲染器句柄 — 供 RenderRawBgraActive 零参数调用
static std::atomic<int64_t> g_activeRendererHandle {0};
static std::mutex g_activeRendererMutex;
// Decoder callbacks can outlive the UI-side numeric handle. Handles must not
// be raw addresses: a destroyed context can be allocated at the same address
// during a fast PIP surface transfer, making an old callback target a new
// renderer. Keep monotonically increasing opaque IDs in the same registry
// mutex so stale callbacks are rejected before any context is dereferenced.
static std::atomic<int64_t> g_nextRendererHandle {1};
static std::unordered_map<int64_t, std::unique_ptr<RendererContext>> g_rendererContexts;

static RendererContext* FindRendererContextLocked(int64_t handle) {
    if (handle <= 0) {
        return nullptr;
    }
    const auto it = g_rendererContexts.find(handle);
    return it == g_rendererContexts.end() ? nullptr : it->second.get();
}

static bool IsActiveRendererHandleLocked(int64_t handle) {
    return handle > 0 && g_activeRendererHandle.load(std::memory_order_acquire) == handle;
}

/**
 * NAPI: initRenderer(xcomponentId: string, width: number, height: number): number
 * 返回渲染器句柄 (指针地址转 int64)
 */
napi_value NapiInitRenderer(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    // 解析参数
    char xcomponentId[256] = {0};
    size_t strLen;
    napi_get_value_string_utf8(env, args[0], xcomponentId, sizeof(xcomponentId), &strLen);

    int32_t width, height;
    napi_get_value_int32(env, args[1], &width);
    napi_get_value_int32(env, args[2], &height);

    // 创建渲染器
    auto renderer = std::shared_ptr<GLRenderer>(new GLRenderer());
    int result = renderer->Init(xcomponentId, width, height);

    if (result != 0) {
        napi_value errVal;
        napi_create_int32(env, result, &errVal);
        return errVal;
    }

    // Return a process-local opaque ID instead of exposing a context address.
    // The decoder can retain this value while the UI tears down and rebuilds
    // the renderer during a PIP transfer.
    auto ctx = std::make_unique<RendererContext>();
    ctx->renderer = renderer;
    int64_t handleVal = g_nextRendererHandle.fetch_add(1, std::memory_order_relaxed);
    if (handleVal <= 0) {
        // Extremely defensive overflow handling; zero and negative values are
        // reserved for "no renderer" throughout the NAPI/decoder boundary.
        handleVal = g_nextRendererHandle.fetch_add(1, std::memory_order_relaxed);
    }
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        g_rendererContexts.emplace(handleVal, std::move(ctx));
    }
    renderer->SetRendererHandle(handleVal);
    napi_value handle;
    napi_create_int64(env, handleVal, &handle);

    // 设置为活跃渲染器 — 供 RenderRawBgraActive 等内部调用使用
    RendererNapi::SetActiveRenderer(handleVal);

    OH_LOG_INFO(LOG_APP, "[GL] NAPI initRenderer 成功, active renderer=%{public}lld",
                static_cast<long long>(handleVal));
    return handle;
}

/**
 * NAPI: renderFrame(handle: number, textureId: number): void
 */
napi_value NapiRenderFrame(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t handleVal;
    napi_get_value_int64(env, args[0], &handleVal);
    int32_t textureId;
    napi_get_value_int32(env, args[1], &textureId);

    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    auto* ctx = FindRendererContextLocked(handleVal);
    if (IsActiveRendererHandleLocked(handleVal) && ctx && ctx->renderer) {
        ctx->renderer->RenderFrame(static_cast<GLuint>(textureId));
    }

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

/**
 * NAPI: resizeRenderer(handle: number, width: number, height: number): void
 */
napi_value NapiResizeRenderer(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t handleVal;
    napi_get_value_int64(env, args[0], &handleVal);

    int32_t width, height;
    napi_get_value_int32(env, args[1], &width);
    napi_get_value_int32(env, args[2], &height);

    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    auto* ctx = FindRendererContextLocked(handleVal);
    if (IsActiveRendererHandleLocked(handleVal) && ctx && ctx->renderer) {
        ctx->generation = AdvanceRendererGeneration();
        ctx->renderer->Resize(width, height);
    }

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

/** NAPI: setRendererCanvasTransform(handle, scale, panX, panY): void */
napi_value NapiSetRendererCanvasTransform(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t handleVal = 0;
    double scale = 1.0;
    double panX = 0.0;
    double panY = 0.0;
    if (argc > 0) napi_get_value_int64(env, args[0], &handleVal);
    if (argc > 1) napi_get_value_double(env, args[1], &scale);
    if (argc > 2) napi_get_value_double(env, args[2], &panX);
    if (argc > 3) napi_get_value_double(env, args[3], &panY);
    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    auto* ctx = FindRendererContextLocked(handleVal);
    if (IsActiveRendererHandleLocked(handleVal) && ctx && ctx->renderer) {
        ctx->renderer->SetCanvasTransform(scale, panX, panY);
    }
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

/**
 * NAPI: destroyRenderer(handle: number): void
 */
napi_value NapiDestroyRenderer(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t handleVal;
    napi_get_value_int64(env, args[0], &handleVal);
    RendererNapi::DeactivateRenderer(handleVal);
    RendererNapi::DestroyRendererHandle(handleVal);

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

/**
 * NAPI: renderRawBGRA(handle: number, data: ArrayBuffer, width: number, height: number, stride: number): void
 * RDP GDI 直出路径 — 将 BGRA 像素直接上传 GL 纹理并渲染
 */
napi_value NapiRenderRawBGRA(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t handleVal;
    napi_get_value_int64(env, args[0], &handleVal);

    void* data = nullptr;
    size_t size = 0;
    napi_get_arraybuffer_info(env, args[1], &data, &size);

    int32_t width = 0, height = 0, stride = 0;
    napi_get_value_int32(env, args[2], &width);
    napi_get_value_int32(env, args[3], &height);
    if (argc > 4) napi_get_value_int32(env, args[4], &stride);

    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    auto* ctx = FindRendererContextLocked(handleVal);
    if (IsActiveRendererHandleLocked(handleVal) && ctx && ctx->renderer) {
        ctx->renderer->RenderRawBGRA(static_cast<const uint8_t*>(data), width, height, stride);
    }

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

/**
 * R1: testRender(handle: number): void
 * 清屏蓝色 + eglSwapBuffers — 证明 XComponent 真实上屏
 */
napi_value NapiTestRender(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t handleVal;
    napi_get_value_int64(env, args[0], &handleVal);

    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    auto* ctx = FindRendererContextLocked(handleVal);
    if (IsActiveRendererHandleLocked(handleVal) && ctx && ctx->renderer) {
        // 直接清屏蓝色并 swap — 不依赖解码器纹理
        GLRenderer* r = ctx->renderer.get();
        if (r->MakeCurrent()) {
            glClearColor(0.0f, 0.2f, 0.8f, 1.0f); // 华为蓝 #0033CC
            glClear(GL_COLOR_BUFFER_BIT);
            eglSwapBuffers(r->GetDisplay(), r->GetSurface());
            r->ReleaseCurrent();
            OH_LOG_INFO(LOG_APP, "[GL] testRender: 蓝色清屏已上屏");
        }
    } else {
        OH_LOG_WARN(LOG_APP, "[GL] testRender: 渲染器未就绪");
    }

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

/**
 * R1: registerNativeXComponent(): boolean
 * 延迟查询 exports 中的 OH_NativeXComponent (框架在 XComponent mount 后注入),
 * 注册 surface 生命周期回调。ArkTS 在 XComponent.onLoad 中调用。
 */
napi_value NapiRegisterNativeXComponent(napi_env env, napi_callback_info info) {
    if (g_xc != nullptr) {
        napi_value r; napi_get_boolean(env, true, &r); return r;
    }

    // 通过持久引用获取 exports, 查询框架注入的 XComponent
    if (g_exportsRef != nullptr) {
        napi_value exp;
        napi_get_reference_value(env, g_exportsRef, &exp);
        TryLoadNativeXComponent(env, exp, "registerNativeXComponent");
    }

    if (g_xc != nullptr) {
        bool ok = RegisterXComponentCallbacks("registerNativeXComponent");
        napi_value r; napi_get_boolean(env, ok, &r); return r;
    }

    OH_LOG_WARN(LOG_APP, "[GL] registerNativeXComponent: XComponent 不可用, 使用 Pbuffer 回退");
    napi_value r; napi_get_boolean(env, false, &r); return r;
}

/**
 * NAPI: setXComponentSurfaceId(surfaceId: string, width: number, height: number): boolean
 * ArkTS XComponentController 的 onSurfaceCreated 回调比 Native 注册回调更稳定。
 */
napi_value NapiSetXComponentSurfaceId(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char surfaceId[64] = {0};
    size_t strLen = 0;
    napi_get_value_string_utf8(env, args[0], surfaceId, sizeof(surfaceId), &strLen);
    int32_t width = 0;
    int32_t height = 0;
    if (argc > 1) { napi_get_value_int32(env, args[1], &width); }
    if (argc > 2) { napi_get_value_int32(env, args[2], &height); }

    bool ok = SetNativeWindowFromSurfaceId(surfaceId, width, height);
    napi_value r;
    napi_get_boolean(env, ok, &r);
    return r;
}

/**
 * NAPI: markXComponentSurfaceDestroyed(): void
 * ArkTS XComponent.onDestroy 触发时调用，避免之后 native 再释放已 detach 的 window surface。
 */
napi_value NapiMarkXComponentSurfaceDestroyed(napi_env env, napi_callback_info info) {
    (void)info;
    MarkXComponentSurfaceDestroyed("NapiMarkXComponentSurfaceDestroyed");
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

/**
 * NAPI: getRendererViewport(handle: number): RendererViewport | null
 *
 * 返回 GL 渲染器当前视口元数据，供 ArkTS 坐标映射使用。
 * 返回 null 表示渲染器未初始化或无可用视口数据。
 */
napi_value NapiGetRendererViewport(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t handle = 0;
    if (argc > 0) {
        napi_get_value_int64(env, args[0], &handle);
    }

    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    auto* ctx = FindRendererContextLocked(handle);
    if (!IsActiveRendererHandleLocked(handle) || !ctx || !ctx->renderer) {
        napi_value nullVal;
        napi_get_null(env, &nullVal);
        return nullVal;
    }

    int vpX = 0, vpY = 0, vpW = 0, vpH = 0;
    int srcW = 0, srcH = 0, surfW = 0, surfH = 0;
    ctx->renderer->GetViewportSnapshot(vpX, vpY, vpW, vpH,
                                       srcW, srcH, surfW, surfH);

    napi_value result;
    napi_create_object(env, &result);

    napi_value val;
    napi_create_int32(env, srcW, &val);
    napi_set_named_property(env, result, "sourceWidth", val);
    napi_create_int32(env, srcH, &val);
    napi_set_named_property(env, result, "sourceHeight", val);
    napi_create_int32(env, surfW, &val);
    napi_set_named_property(env, result, "surfaceWidth", val);
    napi_create_int32(env, surfH, &val);
    napi_set_named_property(env, result, "surfaceHeight", val);
    napi_create_int32(env, vpX, &val);
    napi_set_named_property(env, result, "viewportX", val);
    napi_create_int32(env, vpY, &val);
    napi_set_named_property(env, result, "viewportY", val);
    napi_create_int32(env, vpW, &val);
    napi_set_named_property(env, result, "viewportW", val);
    napi_create_int32(env, vpH, &val);
    napi_set_named_property(env, result, "viewportH", val);

    return result;
}

} // anonymous namespace

void RendererNapi::SetActiveRenderer(int64_t handle) {
    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    auto* ctx = FindRendererContextLocked(handle);
    if (!ctx || !ctx->renderer) {
        OH_LOG_WARN(LOG_APP, "[GL] active renderer rejected stale handle=%{public}lld",
                    static_cast<long long>(handle));
        return;
    }
    const uint64_t generation = AdvanceRendererGeneration();
    ctx->generation = generation;
    g_activeRendererHandle.store(handle, std::memory_order_release);
    {
        std::lock_guard<std::mutex> surfaceLock(g_surfaceStateMutex);
        g_surfaceOwnerHandle.store(handle, std::memory_order_release);
    }
    OH_LOG_INFO(LOG_APP, "[GL] active renderer set handle=%{public}lld",
                static_cast<long long>(handle));
}

RdpPresentationMetricsSnapshot RendererNapi::GetActivePresentationStats() {
    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
    auto* ctx = FindRendererContextLocked(handle);
    if (!ctx || !ctx->renderer) {
        return RdpPresentationMetricsSnapshot();
    }
    return ctx->renderer->GetPresentationStats();
}

void RendererNapi::InvalidateActivePresentation() {
    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    if (g_activeRendererHandle.load(std::memory_order_acquire) > 0) {
        AdvanceRendererGeneration();
    }
}

bool RendererNapi::ReenableActivePresentation() {
    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
    if (handle <= 0 || g_surfaceDetached.load(std::memory_order_acquire) ||
        !g_surfaceReady.load(std::memory_order_acquire)) {
        return false;
    }
    auto* ctx = FindRendererContextLocked(handle);
    if (!ctx || !ctx->renderer) {
        return false;
    }
    ctx->generation = AdvanceRendererGeneration();
    return true;
}

void RendererNapi::DeactivateRenderer(int64_t handle) {
    if (handle <= 0) {
        return;
    }
    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    if (g_activeRendererHandle.load(std::memory_order_acquire) == handle) {
        g_activeRendererHandle.store(0, std::memory_order_release);
        AdvanceRendererGeneration();
    }
}

void RendererNapi::DestroyRendererHandle(int64_t handle) {
    if (handle <= 0) {
        return;
    }
    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    auto* ctx = FindRendererContextLocked(handle);
    if (!ctx) {
        return;
    }
    if (g_activeRendererHandle.load(std::memory_order_acquire) == handle) {
        g_activeRendererHandle.store(0, std::memory_order_release);
        AdvanceRendererGeneration();
    }
    std::shared_ptr<GLRenderer> renderer = std::move(ctx->renderer);
    // Keep the registry mutex held through renderer destruction. Any decoder
    // callback that was already queued either finishes before this point or
    // observes the cleared active handle and returns without touching ctx.
    if (renderer) {
        renderer->Destroy();
    }
    g_rendererContexts.erase(handle);
}

RdpPresentationTarget RendererNapi::GetActivePresentationTarget() {
    RdpPresentationTarget target;
    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    target.generation = g_rendererGeneration.load(std::memory_order_acquire);
    if (g_surfaceDetached.load(std::memory_order_acquire) ||
        !g_surfaceReady.load(std::memory_order_acquire)) {
        target.rejection = RdpPresentResult::SurfaceDetached;
        return target;
    }
    const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
    if (handle <= 0) {
        target.rejection = RdpPresentResult::NoActiveRenderer;
        return target;
    }
    auto* ctx = FindRendererContextLocked(handle);
    if (!ctx || !ctx->renderer) {
        target.rejection = RdpPresentResult::RendererNotReady;
        return target;
    }
    if (ctx->generation != target.generation) {
        target.rejection = RdpPresentResult::GenerationMismatch;
        return target;
    }
    if (!ctx->renderer->IsPresentationReady()) {
        target.rejection = g_surfaceDetached.load(std::memory_order_acquire) ?
            RdpPresentResult::SurfaceDetached : RdpPresentResult::RendererNotReady;
        return target;
    }
    target.rejection = RdpPresentResult::Presented;
    return target;
}

bool RendererNapi::HasReadyActiveRenderer(uint64_t* generation) {
    const RdpPresentationTarget target = GetActivePresentationTarget();
    if (generation) {
        *generation = target.generation;
    }
    return target.ready();
}

RdpPresentMetrics RendererNapi::PresentRawBgraActive(
    const uint8_t* data, size_t size, int width, int height, int stride,
    uint64_t generation) {
    RdpPresentMetrics metrics;
    metrics.generation = generation;
    if (!data || size == 0 || width <= 0 || height <= 0 || stride <= 0) {
        metrics.result = RdpPresentResult::InvalidFrame;
        return metrics;
    }
    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    if (generation == 0 ||
        generation != g_rendererGeneration.load(std::memory_order_acquire)) {
        metrics.result = RdpPresentResult::GenerationMismatch;
        return metrics;
    }
    if (g_surfaceDetached.load(std::memory_order_acquire) ||
        !g_surfaceReady.load(std::memory_order_acquire)) {
        metrics.result = RdpPresentResult::SurfaceDetached;
        return metrics;
    }
    const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
    auto* ctx = FindRendererContextLocked(handle);
    if (handle <= 0) {
        metrics.result = RdpPresentResult::NoActiveRenderer;
        return metrics;
    }
    if (!ctx || !ctx->renderer) {
        metrics.result = RdpPresentResult::RendererNotReady;
        return metrics;
    }
    if (ctx->generation != generation) {
        metrics.result = RdpPresentResult::GenerationMismatch;
        return metrics;
    }
    return ctx->renderer->PresentRawBGRA(data, width, height, stride, generation);
}

RdpPresentMetrics RendererNapi::PresentRawBgraRectActive(
    const uint8_t* data, size_t size, int width, int height, int stride,
    int dirtyX, int dirtyY, int dirtyWidth, int dirtyHeight, uint64_t generation) {
    RdpPresentMetrics metrics;
    metrics.generation = generation;
    if (!data || size == 0 || width <= 0 || height <= 0 || stride <= 0 ||
        dirtyX < 0 || dirtyY < 0 || dirtyWidth <= 0 || dirtyHeight <= 0) {
        metrics.result = RdpPresentResult::InvalidFrame;
        return metrics;
    }
    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    if (generation == 0 ||
        generation != g_rendererGeneration.load(std::memory_order_acquire)) {
        metrics.result = RdpPresentResult::GenerationMismatch;
        return metrics;
    }
    if (g_surfaceDetached.load(std::memory_order_acquire) ||
        !g_surfaceReady.load(std::memory_order_acquire)) {
        metrics.result = RdpPresentResult::SurfaceDetached;
        return metrics;
    }
    const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
    auto* ctx = FindRendererContextLocked(handle);
    if (handle <= 0) {
        metrics.result = RdpPresentResult::NoActiveRenderer;
        return metrics;
    }
    if (!ctx || !ctx->renderer) {
        metrics.result = RdpPresentResult::RendererNotReady;
        return metrics;
    }
    if (ctx->generation != generation) {
        metrics.result = RdpPresentResult::GenerationMismatch;
        return metrics;
    }
    return ctx->renderer->PresentRawBGRARect(data, width, height, stride,
                                             dirtyX, dirtyY, dirtyWidth, dirtyHeight, generation);
}

int RendererNapi::RenderRawBgraActive(
    const uint8_t* data, size_t size, int width, int height, int stride) {
    const RdpPresentationTarget target = GetActivePresentationTarget();
    if (!target.ready()) {
        return static_cast<int>(target.rejection);
    }
    return static_cast<int>(PresentRawBgraActive(
        data, size, width, height, stride, target.generation).result);
}

int RendererNapi::RenderRawBgraRectActive(
    const uint8_t* data, size_t size, int width, int height, int stride,
    int dirtyX, int dirtyY, int dirtyWidth, int dirtyHeight) {
    const RdpPresentationTarget target = GetActivePresentationTarget();
    if (!target.ready()) {
        return static_cast<int>(target.rejection);
    }
    return static_cast<int>(PresentRawBgraRectActive(
        data, size, width, height, stride, dirtyX, dirtyY,
        dirtyWidth, dirtyHeight, target.generation).result);
}

void RendererNapi::MakeCurrent(int64_t handle) {
    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    auto* ctx = FindRendererContextLocked(handle);
    if (IsActiveRendererHandleLocked(handle) && ctx && ctx->renderer) {
        ctx->renderer->MakeCurrent();
    }
}

void RendererNapi::ReleaseCurrent(int64_t handle) {
    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    auto* ctx = FindRendererContextLocked(handle);
    if (IsActiveRendererHandleLocked(handle) && ctx && ctx->renderer) {
        ctx->renderer->ReleaseCurrent();
    }
}

void RendererNapi::SetRendererSourceSize(int64_t handle, int width, int height) {
    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    auto* ctx = FindRendererContextLocked(handle);
    if (IsActiveRendererHandleLocked(handle) && ctx && ctx->renderer) {
        ctx->renderer->SetSourceSize(width, height);
    }
}

void RendererNapi::RenderNative(int64_t handle, GLuint textureId) {
    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    auto* ctx = FindRendererContextLocked(handle);
    if (IsActiveRendererHandleLocked(handle) && ctx && ctx->renderer) {
        ctx->renderer->RenderFrame(textureId);
    }
}

void RendererNapi::SetActiveSourceSize(int width, int height) {
    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
    auto* ctx = FindRendererContextLocked(handle);
    if (ctx && ctx->renderer) {
        ctx->renderer->SetSourceSize(width, height);
    }
}

// ============================================================
// RendererNapi::Init
// ============================================================

napi_value RendererNapi::Init(napi_env env, napi_value exports) {
    napi_value fn;

    // R1: 存 exports 持久引用, 供延迟 XComponent 注册使用
    napi_create_reference(env, exports, 1, &g_exportsRef);

    // 尝试立即提取 XComponent (普通 import 时没有; XComponent libraryname 加载时会注入)
    TryLoadNativeXComponent(env, exports, "RendererNapi::Init");

    if (g_xc != nullptr) {
        RegisterXComponentCallbacks("RendererNapi::Init");
    } else {
        OH_LOG_INFO(LOG_APP, "[GL] XComponent 暂不可用, 等待 registerNativeXComponent 延迟注册 (Pbuffer 回退生效)");
    }

    napi_create_function(env, "initRenderer", NAPI_AUTO_LENGTH,
                         NapiInitRenderer, nullptr, &fn);
    napi_set_named_property(env, exports, "initRenderer", fn);

    napi_create_function(env, "renderFrame", NAPI_AUTO_LENGTH,
                         NapiRenderFrame, nullptr, &fn);
    napi_set_named_property(env, exports, "renderFrame", fn);

    napi_create_function(env, "resizeRenderer", NAPI_AUTO_LENGTH,
                         NapiResizeRenderer, nullptr, &fn);
    napi_set_named_property(env, exports, "resizeRenderer", fn);

    napi_create_function(env, "setRendererCanvasTransform", NAPI_AUTO_LENGTH,
                         NapiSetRendererCanvasTransform, nullptr, &fn);
    napi_set_named_property(env, exports, "setRendererCanvasTransform", fn);

    napi_create_function(env, "destroyRenderer", NAPI_AUTO_LENGTH,
                         NapiDestroyRenderer, nullptr, &fn);
    napi_set_named_property(env, exports, "destroyRenderer", fn);

    napi_create_function(env, "testRender", NAPI_AUTO_LENGTH,
                         NapiTestRender, nullptr, &fn);
    napi_set_named_property(env, exports, "testRender", fn);

    napi_create_function(env, "renderRawBGRA", NAPI_AUTO_LENGTH,
                         NapiRenderRawBGRA, nullptr, &fn);
    napi_set_named_property(env, exports, "renderRawBGRA", fn);

    napi_create_function(env, "registerNativeXComponent", NAPI_AUTO_LENGTH,
                         NapiRegisterNativeXComponent, nullptr, &fn);
    napi_set_named_property(env, exports, "registerNativeXComponent", fn);

    napi_create_function(env, "setXComponentSurfaceId", NAPI_AUTO_LENGTH,
                         NapiSetXComponentSurfaceId, nullptr, &fn);
    napi_set_named_property(env, exports, "setXComponentSurfaceId", fn);

    napi_create_function(env, "markXComponentSurfaceDestroyed", NAPI_AUTO_LENGTH,
                         NapiMarkXComponentSurfaceDestroyed, nullptr, &fn);
    napi_set_named_property(env, exports, "markXComponentSurfaceDestroyed", fn);

    napi_create_function(env, "getRendererViewport", NAPI_AUTO_LENGTH,
                         NapiGetRendererViewport, nullptr, &fn);
    napi_set_named_property(env, exports, "getRendererViewport", fn);

    return exports;
}
