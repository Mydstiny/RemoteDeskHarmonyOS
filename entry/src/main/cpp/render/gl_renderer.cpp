/**
 * gl_renderer.cpp — OpenGL ES 3.0 渲染器 + NAPI 包装
 *
 * 零拷贝渲染：NativeImage 外部 OES 纹理 → NV12→RGB Shader → 屏幕
 */

#include "gl_renderer.h"
#include "renderer_resize_redraw_policy.h"
#include "presentation_geometry_policy.h"
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
#include <utility>
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
// Auxiliary canvases are exact-handle resources and must never invalidate the
// process-global interactive renderer generation merely by being created.
static std::atomic<uint64_t> g_auxRendererGeneration {1};
static constexpr double kMaxCanvasScale = 12.0;

// EGL_DEFAULT_DISPLAY is a process connection even though contexts and
// window surfaces are renderer-local. Keep a single initialize/terminate
// owner so destroying an auxiliary canvas cannot terminate the interactive
// canvas's live contexts. A detached ArkUI window leaves EGL-owned objects in
// an implementation-defined state; in that case retain the process display
// until process exit, matching the previous fail-safe that skipped terminate.
static std::mutex g_eglDisplayMutex;
static EGLDisplay g_sharedEglDisplay = EGL_NO_DISPLAY;
static size_t g_sharedEglDisplayRefs = 0;
static bool g_sharedEglDisplayTerminateDeferred = false;
static EGLint g_sharedEglMajor = 0;
static EGLint g_sharedEglMinor = 0;

static bool AcquireSharedEglDisplay(
    EGLDisplay& display, EGLint& major, EGLint& minor) {
    std::lock_guard<std::mutex> lock(g_eglDisplayMutex);
    if (g_sharedEglDisplay == EGL_NO_DISPLAY) {
        const EGLDisplay candidate = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        if (candidate == EGL_NO_DISPLAY) {
            return false;
        }
        EGLint initializedMajor = 0;
        EGLint initializedMinor = 0;
        if (!eglInitialize(candidate, &initializedMajor, &initializedMinor)) {
            return false;
        }
        g_sharedEglDisplay = candidate;
        g_sharedEglMajor = initializedMajor;
        g_sharedEglMinor = initializedMinor;
        g_sharedEglDisplayTerminateDeferred = false;
    }
    ++g_sharedEglDisplayRefs;
    display = g_sharedEglDisplay;
    major = g_sharedEglMajor;
    minor = g_sharedEglMinor;
    OH_LOG_INFO(LOG_APP,
        "[GL] acquire shared EGLDisplay refs=%{public}zu deferred=%{public}d",
        g_sharedEglDisplayRefs,
        g_sharedEglDisplayTerminateDeferred ? 1 : 0);
    return true;
}

static void ReleaseSharedEglDisplay(EGLDisplay display, bool safeToTerminate) {
    if (display == EGL_NO_DISPLAY) {
        return;
    }
    std::lock_guard<std::mutex> lock(g_eglDisplayMutex);
    if (display != g_sharedEglDisplay || g_sharedEglDisplayRefs == 0) {
        OH_LOG_WARN(LOG_APP,
            "[GL] reject mismatched shared EGLDisplay release display=%{public}p shared=%{public}p refs=%{public}zu",
            reinterpret_cast<void*>(display),
            reinterpret_cast<void*>(g_sharedEglDisplay),
            g_sharedEglDisplayRefs);
        return;
    }
    if (!safeToTerminate) {
        g_sharedEglDisplayTerminateDeferred = true;
    }
    --g_sharedEglDisplayRefs;
    OH_LOG_INFO(LOG_APP,
        "[GL] release shared EGLDisplay refs=%{public}zu deferred=%{public}d",
        g_sharedEglDisplayRefs,
        g_sharedEglDisplayTerminateDeferred ? 1 : 0);
    if (g_sharedEglDisplayRefs == 0 &&
        !g_sharedEglDisplayTerminateDeferred) {
        if (eglTerminate(g_sharedEglDisplay)) {
            g_sharedEglDisplay = EGL_NO_DISPLAY;
            g_sharedEglMajor = 0;
            g_sharedEglMinor = 0;
        } else {
            g_sharedEglDisplayTerminateDeferred = true;
            OH_LOG_WARN(LOG_APP,
                "[GL] shared eglTerminate failed, retaining process display error=%{public}x",
                eglGetError());
        }
    }
}

static uint64_t AdvanceRendererGeneration() {
    return g_rendererGeneration.fetch_add(1, std::memory_order_acq_rel) + 1;
}

static uint64_t NextAuxRendererGeneration() {
    uint64_t generation =
        g_auxRendererGeneration.fetch_add(1, std::memory_order_relaxed) + 1;
    if (generation == 0U) {
        generation =
            g_auxRendererGeneration.fetch_add(1, std::memory_order_relaxed) + 1;
    }
    return generation;
}

[[maybe_unused]] static void OnSurfaceCreatedCB(OH_NativeXComponent* component, void* window);
[[maybe_unused]] static void OnSurfaceChangedCB(OH_NativeXComponent* component, void* window);
[[maybe_unused]] static void OnSurfaceDestroyedCB(OH_NativeXComponent* component, void* window);
[[maybe_unused]] static void DispatchTouchEventStub(OH_NativeXComponent* component, void* window);

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
                    static_cast<unsigned long long>(g_surfaceWidth),
                    static_cast<unsigned long long>(g_surfaceHeight));
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
                surfaceId, window,
                static_cast<unsigned long long>(g_surfaceWidth),
                static_cast<unsigned long long>(g_surfaceHeight));
    return true;
}

[[maybe_unused]] static void OnSurfaceCreatedCB(OH_NativeXComponent* component, void* window) {
    (void)component;
    std::lock_guard<std::mutex> surfaceLock(g_surfaceStateMutex);
    if (g_surfaceIdWindowOwned && g_nativeWindow != 0) {
        OH_LOG_INFO(LOG_APP, "[GL] XComponent SurfaceCreated: 保留 SurfaceId window=%{public}p callbackWin=%{public}p size=%{public}llux%{public}llu",
                    reinterpret_cast<void*>(g_nativeWindow), window,
                    static_cast<unsigned long long>(g_surfaceWidth),
                    static_cast<unsigned long long>(g_surfaceHeight));
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
                window,
                static_cast<unsigned long long>(g_surfaceWidth),
                static_cast<unsigned long long>(g_surfaceHeight));
}

[[maybe_unused]] static void OnSurfaceChangedCB(OH_NativeXComponent* component, void* window) {
    (void)component;
    std::lock_guard<std::mutex> surfaceLock(g_surfaceStateMutex);
    OH_LOG_INFO(LOG_APP, "[GL] XComponent SurfaceChanged: win=%{public}p size deferred %{public}llux%{public}llu",
                window,
                static_cast<unsigned long long>(g_surfaceWidth),
                static_cast<unsigned long long>(g_surfaceHeight));
}

// 空实现 stub — 防止 DispatchTouchEvent=NULL 导致框架 OnSurfaceDestroyed 中调用 NULL 指针崩溃
[[maybe_unused]] static void DispatchTouchEventStub(OH_NativeXComponent* component, void* window) {
    (void)component;
    (void)window;
}

[[maybe_unused]] static void OnSurfaceDestroyedCB(OH_NativeXComponent* component, void* window) {
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
uniform int uCanvasRotation;
uniform int uCanvasFlipX;
uniform int uCanvasFlipY;

vec2 canvasTexCoord(vec2 coord) {
    vec2 rotated = coord;
    if (uCanvasRotation == 1) {
        rotated = vec2(coord.y, 1.0 - coord.x);
    } else if (uCanvasRotation == 2) {
        rotated = vec2(1.0 - coord.x, 1.0 - coord.y);
    } else if (uCanvasRotation == 3) {
        rotated = vec2(1.0 - coord.y, coord.x);
    }
    if (uCanvasFlipX != 0) {
        rotated.x = 1.0 - rotated.x;
    }
    if (uCanvasFlipY != 0) {
        rotated.y = 1.0 - rotated.y;
    }
    return rotated;
}

void main() {
    gl_Position = vec4(aPosition, 0.0, 1.0);
    vTexCoord = canvasTexCoord(aTexCoord);
}
)";

/** NativeImage OES vertex shader — applies an explicit presentation transform. */
static const char* VERTEX_SHADER_OES = R"(#version 300 es
precision mediump float;
layout(location = 0) in vec2 aPosition;
layout(location = 1) in vec2 aTexCoord;
out vec2 vTexCoord;
uniform mat4 uTexTransform;
uniform int uCanvasRotation;
uniform int uCanvasFlipX;
uniform int uCanvasFlipY;

vec2 canvasTexCoord(vec2 coord) {
    vec2 rotated = coord;
    if (uCanvasRotation == 1) {
        rotated = vec2(coord.y, 1.0 - coord.x);
    } else if (uCanvasRotation == 2) {
        rotated = vec2(1.0 - coord.x, 1.0 - coord.y);
    } else if (uCanvasRotation == 3) {
        rotated = vec2(1.0 - coord.y, coord.x);
    }
    if (uCanvasFlipX != 0) {
        rotated.x = 1.0 - rotated.x;
    }
    if (uCanvasFlipY != 0) {
        rotated.y = 1.0 - rotated.y;
    }
    return rotated;
}

void main() {
    gl_Position = vec4(aPosition, 0.0, 1.0);
    vTexCoord = (uTexTransform * vec4(canvasTexCoord(aTexCoord), 0.0, 1.0)).xy;
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
[[maybe_unused]] static const char* FRAGMENT_SHADER_NV12 =R"(#version 300 es
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
      eglDisplayLeaseHeld_(false),
      shaderProgram_(0), samplerLocation_(0), oesTransformLocation_(-1),
      canvasRotationLocation_(-1), canvasFlipXLocation_(-1), canvasFlipYLocation_(-1),
      rawShaderProgram_(0), rawTexture_(0), rawSamplerLocation_(0),
      rawCanvasRotationLocation_(-1), rawCanvasFlipXLocation_(-1),
      rawCanvasFlipYLocation_(-1),
      uploadPbo_{0, 0}, uploadPboCapacity_{0, 0}, uploadPboIndex_(0),
      pboUploadEnabled_(false), pboUploadFailedLogged_(false),
      rawTextureWidth_(0), rawTextureHeight_(0),
      rawPresentationWidth_(0), rawPresentationHeight_(0),
      vbo_(0), vao_(0),
      width_(0), height_(0), sourceWidth_(0), sourceHeight_(0),
      oesSourceWidth_(0), oesSourceHeight_(0),
      presentationPath_(PresentationPath::UNKNOWN),
      lastVpX_(0), lastVpY_(0), lastVpW_(0), lastVpH_(0),
      canvasScale_(1.0), canvasPanX_(0.0), canvasPanY_(0.0),
      canvasRotationQuarterTurns_(0), canvasFlipX_(false), canvasFlipY_(false),
      canvasTransformVersion_(0), pendingCanvasScale_(1.0),
      pendingCanvasPanX_(0.0), pendingCanvasPanY_(0.0),
      pendingCanvasRotationQuarterTurns_(0), pendingCanvasFlipX_(false),
      pendingCanvasFlipY_(false),
      appliedCanvasTransformVersion_(0),
      viewportSnapshotVersion_(0), snapshotVpX_(0), snapshotVpY_(0),
      snapshotVpW_(0), snapshotVpH_(0), snapshotSourceWidth_(0),
      snapshotSourceHeight_(0), snapshotSurfaceWidth_(0), snapshotSurfaceHeight_(0),
      snapshotTransformVersion_(0), snapshotRotationQuarterTurns_(0),
      snapshotFlipX_(false), snapshotFlipY_(false),
      rawFrameCount_(0), oesFrameCount_(0), rendererHandle_(0),
      explicitNativeWindow_(nullptr), usesProcessSurface_(true),
      initialized_(false), destroying_(false) {}

GLRenderer::~GLRenderer() {
    Destroy();
}

void GLRenderer::SetRendererHandle(int64_t handle) {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    rendererHandle_ = handle > 0 ? handle : 0;
}

void GLRenderer::SetRedrawCallback(std::function<void()> callback) {
    std::lock_guard<std::mutex> lock(redrawCallbackMutex_);
    redrawCallback_ = std::move(callback);
}

void GLRenderer::SetSessionRedrawCallback(std::function<void()> callback) {
    std::lock_guard<std::mutex> lock(redrawCallbackMutex_);
    sessionRedrawCallback_ = std::move(callback);
}

void GLRenderer::RequestRedraw() {
    std::function<void()> decoderCallback;
    std::function<void()> sessionCallback;
    {
        std::lock_guard<std::mutex> lock(redrawCallbackMutex_);
        decoderCallback = redrawCallback_;
        sessionCallback = sessionRedrawCallback_;
    }
    if (decoderCallback) {
        decoderCallback();
    }
    if (sessionCallback) {
        sessionCallback();
    }
}

void GLRenderer::ApplyPendingCanvasTransformLocked() {
    for (;;) {
        const uint64_t before = canvasTransformVersion_.load(std::memory_order_acquire);
        if ((before & 1U) != 0U || before == appliedCanvasTransformVersion_) {
            return;
        }
        const double scale = pendingCanvasScale_.load(std::memory_order_relaxed);
        const double panX = pendingCanvasPanX_.load(std::memory_order_relaxed);
        const double panY = pendingCanvasPanY_.load(std::memory_order_relaxed);
        const int rotation = pendingCanvasRotationQuarterTurns_.load(std::memory_order_relaxed);
        const bool flipX = pendingCanvasFlipX_.load(std::memory_order_relaxed);
        const bool flipY = pendingCanvasFlipY_.load(std::memory_order_relaxed);
        const uint64_t after = canvasTransformVersion_.load(std::memory_order_acquire);
        if (before != after || (after & 1U) != 0U) {
            continue;
        }
        canvasScale_ = scale;
        canvasPanX_ = panX;
        canvasPanY_ = panY;
        canvasRotationQuarterTurns_ = rotation;
        canvasFlipX_ = flipX;
        canvasFlipY_ = flipY;
        appliedCanvasTransformVersion_ = after;
        return;
    }
}

bool GLRenderer::MakeCurrent() {
    if (eglDisplay_ == EGL_NO_DISPLAY || eglSurface_ == EGL_NO_SURFACE ||
        eglContext_ == EGL_NO_CONTEXT) {
        OH_LOG_WARN(LOG_APP, "[GL] eglMakeCurrent skipped: EGL not ready");
        return false;
    }
    if (usesProcessSurface_ && g_surfaceDetached.load(std::memory_order_acquire)) {
        OH_LOG_WARN(LOG_APP, "[GL] eglMakeCurrent skipped: XComponent surface already detached");
        return false;
    }
    // The hardware decoder render thread intentionally retains this context
    // between NativeImage frames. Rebinding an already-current context for
    // both UpdateSurfaceImage and RenderFrame creates redundant native-fence
    // work on the PC graphics stack and can turn a quiet 2 fps stream into a
    // visible half-second delay. RAW/software callers release after each draw
    // and therefore keep their existing behavior.
    if (eglGetCurrentDisplay() == eglDisplay_ &&
        eglGetCurrentContext() == eglContext_ &&
        eglGetCurrentSurface(EGL_DRAW) == eglSurface_ &&
        eglGetCurrentSurface(EGL_READ) == eglSurface_) {
        return true;
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
    // Do not publish the local surface as remote source geometry. ArkTS uses
    // this snapshot for RustDesk display synchronization; before the first
    // frame the source is intentionally unknown and the page uses its own
    // protocol geometry fallback.
    sourceWidth_ = 0;
    sourceHeight_ = 0;
    rawPresentationWidth_ = 0;
    rawPresentationHeight_ = 0;
    oesSourceWidth_ = 0;
    oesSourceHeight_ = 0;
    presentationPath_ = PresentationPath::UNKNOWN;
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
    EGLint major = 0;
    EGLint minor = 0;
    if (!AcquireSharedEglDisplay(eglDisplay_, major, minor)) {
        OH_LOG_ERROR(LOG_APP,
            "[GL] acquire/initialize shared EGLDisplay 失败: %{public}x",
            eglGetError());
        return false;
    }
    eglDisplayLeaseHeld_ = true;
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

    // A numeric XComponent SurfaceId owns a renderer-local NativeWindow. This
    // is the multi-canvas path: no second renderer may overwrite the legacy
    // process-wide page/PIP surface binding.
    bool surfaceReady = false;
    EGLNativeWindowType nativeWindow = 0;
    uint64_t surfaceWidth = 0;
    uint64_t surfaceHeight = 0;
    char* surfaceEnd = nullptr;
    const unsigned long long parsedSurfaceId = xcomponentId.empty() ? 0ULL :
        std::strtoull(xcomponentId.c_str(), &surfaceEnd, 10);
    const bool explicitSurface = parsedSurfaceId > 0ULL && surfaceEnd != nullptr &&
        *surfaceEnd == '\0';
    if (explicitSurface) {
        OHNativeWindow* window = nullptr;
        const int32_t createResult = OH_NativeWindow_CreateNativeWindowFromSurfaceId(
            static_cast<uint64_t>(parsedSurfaceId), &window);
        if (createResult != 0 || window == nullptr) {
            OH_LOG_ERROR(LOG_APP,
                "[GL] explicit SurfaceId window creation failed id=%{public}s result=%{public}d",
                xcomponentId.c_str(), createResult);
            return false;
        }
        explicitNativeWindow_ = window;
        usesProcessSurface_ = false;
        nativeWindow = reinterpret_cast<EGLNativeWindowType>(window);
        surfaceReady = true;
        surfaceWidth = static_cast<uint64_t>(std::max(width_, 1));
        surfaceHeight = static_cast<uint64_t>(std::max(height_, 1));
    } else {
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
                        static_cast<unsigned long long>(surfaceWidth),
                        static_cast<unsigned long long>(surfaceHeight));
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
    oesTransformLocation_ = glGetUniformLocation(shaderProgram_, "uTexTransform");
    canvasRotationLocation_ = glGetUniformLocation(shaderProgram_, "uCanvasRotation");
    canvasFlipXLocation_ = glGetUniformLocation(shaderProgram_, "uCanvasFlipX");
    canvasFlipYLocation_ = glGetUniformLocation(shaderProgram_, "uCanvasFlipY");
    if (samplerLocation_ < 0 || oesTransformLocation_ < 0 || canvasRotationLocation_ < 0 ||
        canvasFlipXLocation_ < 0 || canvasFlipYLocation_ < 0) {
        OH_LOG_ERROR(LOG_APP,
                     "[GL] OES shader uniforms missing sampler=%{public}d transform=%{public}d rotation=%{public}d flipX=%{public}d flipY=%{public}d",
                     samplerLocation_, oesTransformLocation_, canvasRotationLocation_,
                     canvasFlipXLocation_, canvasFlipYLocation_);
        return false;
    }

    // 创建 BGRA 着色器程序 (RDP GDI 路径)
    rawShaderProgram_ = CreateRawShaderProgram();
    rawSamplerLocation_ = rawShaderProgram_ > 0
        ? glGetUniformLocation(rawShaderProgram_, "uTexture") : 0;
    rawCanvasRotationLocation_ = rawShaderProgram_ > 0
        ? glGetUniformLocation(rawShaderProgram_, "uCanvasRotation") : -1;
    rawCanvasFlipXLocation_ = rawShaderProgram_ > 0
        ? glGetUniformLocation(rawShaderProgram_, "uCanvasFlipX") : -1;
    rawCanvasFlipYLocation_ = rawShaderProgram_ > 0
        ? glGetUniformLocation(rawShaderProgram_, "uCanvasFlipY") : -1;

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

    // PBO objects are tied to this EGL context. A surface/context rebind must
    // always start with direct uploads until the new session has a baseline.
    pboUploadEnabled_ = false;
    pboUploadFailedLogged_ = false;
    uploadPboIndex_ = 0;
    uploadPboCapacity_[0] = 0;
    uploadPboCapacity_[1] = 0;

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
    GLuint vertShader = CompileShader(GL_VERTEX_SHADER, VERTEX_SHADER_OES);
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

void GLRenderer::SetPboUploadEnabled(bool enabled) {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    if (!initialized_ || destroying_) {
        return;
    }
    pboUploadEnabled_ = enabled;
    if (!enabled) {
        pboUploadFailedLogged_ = false;
    }
}

bool GLRenderer::UploadRawPixelsWithPbo(const uint8_t* uploadData, int uploadW,
                                        int uploadH, int sourceStride,
                                        int uploadX, int uploadY) {
    if (!pboUploadEnabled_ || !uploadData || uploadW <= 0 || uploadH <= 0 ||
        sourceStride < uploadW * 4) {
        return false;
    }

    const size_t rowBytes = static_cast<size_t>(uploadW) * 4U;
    const size_t requiredBytes = rowBytes * static_cast<size_t>(uploadH);
    const int index = uploadPboIndex_;
    if (uploadPbo_[index] == 0) {
        glGenBuffers(1, &uploadPbo_[index]);
    }
    if (uploadPbo_[index] == 0) {
        return false;
    }

    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, uploadPbo_[index]);
    // Orphan the previous store before mapping. This avoids a CPU wait for
    // the GPU when the previous swap is still sampling the same PBO.
    glBufferData(GL_PIXEL_UNPACK_BUFFER, static_cast<GLsizeiptr>(requiredBytes),
                 nullptr, GL_STREAM_DRAW);
    void* mapped = glMapBufferRange(GL_PIXEL_UNPACK_BUFFER, 0,
                                    static_cast<GLsizeiptr>(requiredBytes),
                                    GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT);
    if (!mapped) {
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
        if (!pboUploadFailedLogged_) {
            OH_LOG_WARN(LOG_APP, "[GL] PBO map failed; falling back to direct upload");
            pboUploadFailedLogged_ = true;
        }
        pboUploadEnabled_ = false;
        return false;
    }
    auto* destination = static_cast<uint8_t*>(mapped);
    for (int row = 0; row < uploadH; ++row) {
        std::memcpy(destination + static_cast<size_t>(row) * rowBytes,
                    uploadData + static_cast<size_t>(row) *
                        static_cast<size_t>(sourceStride), rowBytes);
    }
    if (glUnmapBuffer(GL_PIXEL_UNPACK_BUFFER) != GL_TRUE) {
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
        if (!pboUploadFailedLogged_) {
            OH_LOG_WARN(LOG_APP, "[GL] PBO unmap failed; falling back to direct upload");
            pboUploadFailedLogged_ = true;
        }
        pboUploadEnabled_ = false;
        return false;
    }
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    glTexSubImage2D(GL_TEXTURE_2D, 0, uploadX, uploadY, uploadW, uploadH,
                    GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    uploadPboCapacity_[index] = requiredBytes;
    uploadPboIndex_ = (uploadPboIndex_ + 1) % 2;
    return true;
}

void GLRenderer::DestroyUploadPbosLocked() {
    if (uploadPbo_[0] != 0) {
        glDeleteBuffers(1, &uploadPbo_[0]);
        uploadPbo_[0] = 0;
    }
    if (uploadPbo_[1] != 0) {
        glDeleteBuffers(1, &uploadPbo_[1]);
        uploadPbo_[1] = 0;
    }
    uploadPboCapacity_[0] = 0;
    uploadPboCapacity_[1] = 0;
    uploadPboIndex_ = 0;
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

RdpPresentMetrics GLRenderer::PresentRawBGRARectCompact(
    const uint8_t* bgraData, size_t size, int width, int height, int stride,
    int dirtyX, int dirtyY, int dirtyWidth, int dirtyHeight, uint64_t generation) {
    return RenderRawBGRAInternal(bgraData, width, height, stride, true,
                                 dirtyX, dirtyY, dirtyWidth, dirtyHeight, generation,
                                 size, true);
}

bool GLRenderer::IsPresentationReady() {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    return !destroying_ && initialized_ && rawShaderProgram_ != 0 &&
        g_surfaceReady.load(std::memory_order_acquire) &&
        !g_surfaceDetached.load(std::memory_order_acquire);
}

RdpPresentMetrics GLRenderer::RenderRawBGRAInternal(
    const uint8_t* bgraData, int width, int height, int stride, bool useDirtyRect,
    int dirtyX, int dirtyY, int dirtyWidth, int dirtyHeight, uint64_t generation,
    size_t dataSize, bool compactDirtyBuffer) {
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
    // The callback is the ownership boundary for the raw path. Clear only
    // staged OES geometry; raw texture dimensions remain upload metadata and a
    // pre-first-frame fallback, never a replacement for logical geometry.
    if (presentationPath_ != PresentationPath::RAW_BGRA) {
        presentationPath_ = PresentationPath::RAW_BGRA;
        oesSourceWidth_ = 0;
        oesSourceHeight_ = 0;
    }
    ApplyPendingCanvasTransformLocked();

    const auto uploadBeginAt = clock::now();
    int rowStride = stride > 0 ? stride : width * 4;
    const bool compactDirty = compactDirtyBuffer && useDirtyRect;
    const bool dirtyInBounds = useDirtyRect &&
        dirtyX >= 0 && dirtyY >= 0 && dirtyWidth > 0 && dirtyHeight > 0 &&
        dirtyX < width && dirtyY < height &&
        dirtyWidth <= width - dirtyX && dirtyHeight <= height - dirtyY;
    if (compactDirty && !dirtyInBounds) {
        ReleaseCurrent();
        metrics.result = RdpPresentResult::InvalidFrame;
        return metrics;
    }
    const int minimumRowBytes = compactDirty ? dirtyWidth * 4 : width * 4;
    if (rowStride < minimumRowBytes || rowStride % 4 != 0) {
        ReleaseCurrent();
        metrics.result = RdpPresentResult::InvalidFrame;
        return metrics;
    }
    if (compactDirty) {
        const size_t requiredBytes = static_cast<size_t>(dirtyHeight - 1) *
            static_cast<size_t>(rowStride) + static_cast<size_t>(dirtyWidth) * 4U;
        if (dataSize == 0 || requiredBytes > dataSize) {
            ReleaseCurrent();
            metrics.result = RdpPresentResult::InvalidFrame;
            return metrics;
        }
    }
    const bool textureWouldChange =
        rawTexture_ == 0 || width != rawTextureWidth_ || height != rawTextureHeight_;

    // A compact rectangle cannot initialize a new desktop texture. The
    // producer will retry after the next full-frame resync.
    if (compactDirty && textureWouldChange) {
        ReleaseCurrent();
        metrics.result = RdpPresentResult::InvalidFrame;
        return metrics;
    }

    // Both raw callers provide the complete framebuffer and use the dirty
    // rectangle only to reduce the steady-state upload. A new or resized
    // texture must therefore be initialized from the full buffer; rejecting
    // the first dirty rectangle would leave the texture uninitialized forever.
    if (textureWouldChange) {
        rawTextureWidth_ = width;
        rawTextureHeight_ = height;
        SetupRawTexture(width, height);
    }
    // The callback frame is the only authoritative geometry for the software
    // presentation. Keep it separate from rawTextureWidth_/Height_, which may
    // still describe an allocated texture during a reconfigure or retained
    // redraw.
    rawPresentationWidth_ = width;
    rawPresentationHeight_ = height;
    const bool partialUpload = compactDirty || (!textureWouldChange && dirtyInBounds &&
        (dirtyX != 0 || dirtyY != 0 || dirtyWidth != width || dirtyHeight != height));
    const int uploadX = partialUpload ? dirtyX : 0;
    // QUAD_VERTICES deliberately maps v=0 to the visual top, so the texture
    // row index uses the same top-left contract as FreeRDP/GDI dirty rects.
    // Do not invert dirtyY here unless the vertex contract changes as well.
    const int uploadY = partialUpload ? dirtyY : 0;
    const int uploadW = partialUpload ? dirtyWidth : width;
    const int uploadH = partialUpload ? dirtyHeight : height;
    // The VNC/RDP raw callback owns the complete framebuffer.  When a dirty
    // rectangle is uploaded, GL must start at that rectangle's first pixel;
    // using the framebuffer base makes every later update overwrite the
    // wrong texture region and leaves the visible image looking frozen.
    const uint8_t* uploadData = compactDirty ? bgraData : (partialUpload ?
        bgraData + static_cast<size_t>(dirtyY) * static_cast<size_t>(rowStride) +
        static_cast<size_t>(dirtyX) * 4 : bgraData);

    // Use the adaptive PBO path once the RDP gate has proved that direct
    // upload+swap dominates the worker. The helper packs padded rows into a
    // compact buffer and leaves the texture update asynchronous.
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, rawTexture_);
    const bool uploadedWithPbo = UploadRawPixelsWithPbo(
        uploadData, uploadW, uploadH, rowStride, uploadX, uploadY);
    metrics.pboUpload = uploadedWithPbo;
    if (!uploadedWithPbo) {
        if (partialUpload || rowStride != width * 4) {
            glPixelStorei(GL_UNPACK_ROW_LENGTH, rowStride / 4);
        }
        glTexSubImage2D(GL_TEXTURE_2D, 0, uploadX, uploadY, uploadW, uploadH,
                        GL_RGBA, GL_UNSIGNED_BYTE, uploadData);
        if (partialUpload || rowStride != width * 4) {
            glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
        }
    }
    const auto uploadAt = clock::now();

    // Renderer snapshots use top-left coordinates so ArkTS hit testing and
    // cursor projection share the same canvas contract as the gesture layer.
    // Preserve the established RAW BGRA texture-size viewport. Software
    // decoding may downscale the uploaded texture; using the logical encoded
    // size here would enlarge/crop VP8/VP9/AV1 when the aspect ratios differ.
    presentationPath_ = PresentationPath::RAW_BGRA;
    const int logicalSourceWidth = sourceWidth_ > 0 ? sourceWidth_ : width;
    const int logicalSourceHeight = sourceHeight_ > 0 ? sourceHeight_ : height;
    int vpX = 0, vpY = 0, vpW = width_, vpH = height_;
    CalculateActiveViewport(vpX, vpY, vpW, vpH);

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
    if (rawCanvasRotationLocation_ >= 0) {
        glUniform1i(rawCanvasRotationLocation_, canvasRotationQuarterTurns_);
    }
    if (rawCanvasFlipXLocation_ >= 0) {
        glUniform1i(rawCanvasFlipXLocation_, canvasFlipX_ ? 1 : 0);
    }
    if (rawCanvasFlipYLocation_ >= 0) {
        glUniform1i(rawCanvasFlipYLocation_, canvasFlipY_ ? 1 : 0);
    }

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
    if (rawFrameCount_ <= 3 || rawFrameCount_ % 120 == 0) {
        OH_LOG_INFO(LOG_APP,
                    "[GL] raw present path=raw logical=%{public}dx%{public}d texture=%{public}dx%{public}d surface=%{public}dx%{public}d viewport=%{public}d,%{public}d %{public}dx%{public}d scale=%{public}f",
                    logicalSourceWidth, logicalSourceHeight, width, height,
                    width_, height_, vpX, vpY, vpW, vpH, canvasScale_);
    }
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
    (void)PresentFrame(textureId, Render::IdentityNativeImageTransform());
}

void GLRenderer::RenderFrame(
    GLuint textureId, const Render::NativeImageTransform& textureTransform) {
    (void)PresentFrame(textureId, textureTransform);
}

RdpPresentMetrics GLRenderer::PresentFrame(
    GLuint textureId, const Render::NativeImageTransform& textureTransform) {
    RdpPresentMetrics metrics;
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    using clock = std::chrono::steady_clock;
    const auto drawBeginAt = clock::now();
    const bool surfaceDetached = usesProcessSurface_ &&
        g_surfaceDetached.load(std::memory_order_acquire);
    if (destroying_ || surfaceDetached || !initialized_) {
        OH_LOG_WARN(LOG_APP, "[GL] 渲染器未初始化, 跳过渲染");
        metrics.result = surfaceDetached
            ? RdpPresentResult::SurfaceDetached
            : RdpPresentResult::RendererNotReady;
        return metrics;
    }
    const int oesWidth = oesSourceWidth_ > 0 ? oesSourceWidth_ : sourceWidth_;
    const int oesHeight = oesSourceHeight_ > 0 ? oesSourceHeight_ : sourceHeight_;
    const int logicalSourceWidth = sourceWidth_ > 0 ? sourceWidth_ : oesWidth;
    const int logicalSourceHeight = sourceHeight_ > 0 ? sourceHeight_ : oesHeight;

    // 绑定上下文
    // 清屏
    if (!MakeCurrent()) {
        metrics.result = RdpPresentResult::MakeCurrentFailed;
        return metrics;
    }
    // SetRendererSourceSize() stages the current OES output dimensions
    // immediately before this callback. Do not clear them on a raw->OES
    // transition: that would make the first hardware frame fall back to a
    // stale logical size.
    presentationPath_ = PresentationPath::OES;
    ApplyPendingCanvasTransformLocked();

    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    // 使用着色器程序
    int viewportX = 0;
    int viewportY = 0;
    int viewportW = width_;
    int viewportH = height_;
    // OES dimensions are a fallback for the interval before the protocol
    // supplies logical geometry. Once available, logical dimensions win so a
    // decoder crop/reconfigure cannot resize the remote canvas unexpectedly.
    CalculateActiveViewport(viewportX, viewportY, viewportW, viewportH);
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
    glUniform1i(canvasRotationLocation_, canvasRotationQuarterTurns_);
    glUniform1i(canvasFlipXLocation_, canvasFlipX_ ? 1 : 0);
    glUniform1i(canvasFlipYLocation_, canvasFlipY_ ? 1 : 0);
    glUniformMatrix4fv(oesTransformLocation_, 1, GL_FALSE,
                       textureTransform.data());

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

    metrics.result = swapped ? RdpPresentResult::Presented : RdpPresentResult::SwapFailed;
    metrics.drawUs = std::chrono::duration_cast<std::chrono::microseconds>(
        drawAt - drawBeginAt).count();
    metrics.swapUs = std::chrono::duration_cast<std::chrono::microseconds>(
        swapAt - drawAt).count();
    const auto nowUs = std::chrono::duration_cast<std::chrono::microseconds>(
        swapAt.time_since_epoch()).count();
    presentationMetrics_.recordPresent(nowUs, metrics);
    oesFrameCount_++;
    if (oesFrameCount_ <= 3 || oesFrameCount_ % 120 == 0) {
        OH_LOG_INFO(LOG_APP,
                    "[GL] OES present path=oes logical=%{public}dx%{public}d texture=%{public}dx%{public}d surface=%{public}dx%{public}d viewport=%{public}d,%{public}d %{public}dx%{public}d scale=%{public}f",
                    logicalSourceWidth, logicalSourceHeight, oesWidth, oesHeight,
                    width_, height_, viewportX, viewportY, viewportW, viewportH,
                    canvasScale_);
    }
    return metrics;
}

void GLRenderer::Resize(int width, int height) {
    Render::CommitRendererResizeAndRedraw(
        [this, width, height]() {
            std::lock_guard<std::mutex> lock(lifecycleMutex_);
            if (!Render::CommitRendererResizeGeometry(
                    width_, height_, width, height)) {
                return false;
            }
            ApplyPendingCanvasTransformLocked();
            // Resize recalculates the logical remote viewport. Decoder dimensions are
            // only fallbacks while the first logical frame is still unavailable.
            CalculateActiveViewport(lastVpX_, lastVpY_, lastVpW_, lastVpH_);
            PublishViewportSnapshot(lastVpX_, lastVpY_, lastVpW_, lastVpH_);
            return true;
        },
        [this, width, height]() {
            OH_LOG_INFO(LOG_APP, "[GL] 渲染区域大小改为 %{public}dx%{public}d", width, height);
            // A quiet desktop may not deliver another encoded frame for several
            // seconds. Wake the current OES/raw owner after publishing the new
            // viewport so the retained texture is fitted to the resized window in
            // the same display interval instead of leaving WindowManager to stretch
            // the previous swap until the next network frame arrives.
            RequestRedraw();
        });
}

void GLRenderer::SetSourceSize(int width, int height) {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    ApplyPendingCanvasTransformLocked();
    if (width <= 0 || height <= 0) {
        return;
    }
    if (sourceWidth_ == width && sourceHeight_ == height) {
        return;
    }
    sourceWidth_ = width;
    sourceHeight_ = height;
    // The logical size arrives before the next decoded frame. An OES decoder
    // may still have the previous output dimensions staged, so do not let
    // that old output determine the pre-frame snapshot.
    if (presentationPath_ == PresentationPath::OES) {
        oesSourceWidth_ = 0;
        oesSourceHeight_ = 0;
    }
    // This setter updates both logical/input geometry and the display aspect
    // ratio. RAW/OES decoder dimensions remain path-local fallbacks only.
    CalculateActiveViewport(lastVpX_, lastVpY_, lastVpW_, lastVpH_);
    PublishViewportSnapshot(lastVpX_, lastVpY_, lastVpW_, lastVpH_);
    OH_LOG_INFO(LOG_APP, "[GL] 视频源尺寸更新为 %{public}dx%{public}d", width, height);
}

void GLRenderer::SetOesSourceSize(int width, int height) {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    if (width <= 0 || height <= 0) {
        return;
    }
    if (oesSourceWidth_ == width && oesSourceHeight_ == height) {
        return;
    }
    oesSourceWidth_ = width;
    oesSourceHeight_ = height;
    // Do not publish or switch the active path here. Hardware callbacks can
    // arrive after a decoder rebind; only RenderFrame may make OES the visible
    // presentation path after it has acquired the current EGL surface.
    OH_LOG_DEBUG(LOG_APP, "[GL] OES texture size staged %{public}dx%{public}d", width, height);
}

uint64_t GLRenderer::SetCanvasTransform(double scale, double panX, double panY,
                                        int rotationQuarterTurns, bool flipX, bool flipY) {
    if (!std::isfinite(scale) || scale <= 0.0 || !std::isfinite(panX) || !std::isfinite(panY)) {
        OH_LOG_WARN(LOG_APP, "[GL] ignored invalid canvas transform");
        return 0;
    }
    const double clampedScale = std::clamp(scale, 0.05, kMaxCanvasScale);
    const int normalizedRotation = ((rotationQuarterTurns % 4) + 4) % 4;
    uint64_t publishedVersion = 0;
    // Publish a complete transform with a tiny seqlock. The UI thread never
    // waits for the EGL owner; the owner consumes the newest stable tuple.
    {
        std::lock_guard<std::mutex> publishLock(transformPublishMutex_);
        canvasTransformVersion_.fetch_add(1, std::memory_order_acq_rel);
        pendingCanvasScale_.store(clampedScale, std::memory_order_relaxed);
        pendingCanvasPanX_.store(panX, std::memory_order_relaxed);
        pendingCanvasPanY_.store(panY, std::memory_order_relaxed);
        pendingCanvasRotationQuarterTurns_.store(normalizedRotation, std::memory_order_relaxed);
        pendingCanvasFlipX_.store(flipX, std::memory_order_relaxed);
        pendingCanvasFlipY_.store(flipY, std::memory_order_relaxed);
        publishedVersion = canvasTransformVersion_.fetch_add(1, std::memory_order_release) + 1;
    }
    RequestRedraw();
    return publishedVersion;
}

void GLRenderer::RenderRetainedFrame(uint64_t expectedGeneration) {
    (void)PresentRetainedFrame(expectedGeneration);
}

RdpPresentMetrics GLRenderer::PresentRetainedFrame(uint64_t expectedGeneration) {
    std::lock_guard<std::mutex> lock(lifecycleMutex_);
    return RenderRetainedFrameLocked(expectedGeneration);
}

RdpPresentMetrics GLRenderer::RenderRetainedFrameLocked(uint64_t expectedGeneration) {
    using clock = std::chrono::steady_clock;
    RdpPresentMetrics metrics;
    metrics.generation = expectedGeneration;
    metrics.retainedFrame = true;
    if ((expectedGeneration != 0 && expectedGeneration !=
            g_rendererGeneration.load(std::memory_order_acquire)) ||
        destroying_ || !initialized_ || rawShaderProgram_ == 0 || rawTexture_ == 0 ||
        rawTextureWidth_ <= 0 || rawTextureHeight_ <= 0 ||
        g_surfaceDetached.load(std::memory_order_acquire) ||
        !g_surfaceReady.load(std::memory_order_acquire)) {
        metrics.result = (expectedGeneration != 0 && expectedGeneration !=
            g_rendererGeneration.load(std::memory_order_acquire)) ?
            RdpPresentResult::GenerationMismatch :
            (g_surfaceDetached.load(std::memory_order_acquire) ||
             !g_surfaceReady.load(std::memory_order_acquire)) ?
            RdpPresentResult::SurfaceDetached : RdpPresentResult::RendererNotReady;
        return metrics;
    }
    if (!MakeCurrent()) {
        metrics.result = RdpPresentResult::MakeCurrentFailed;
        return metrics;
    }
    if (expectedGeneration != 0 && expectedGeneration !=
            g_rendererGeneration.load(std::memory_order_acquire)) {
        ReleaseCurrent();
        metrics.result = RdpPresentResult::GenerationMismatch;
        return metrics;
    }
    ApplyPendingCanvasTransformLocked();
    const auto drawBeginAt = clock::now();
    int vpX = 0, vpY = 0, vpW = width_, vpH = height_;
    presentationPath_ = PresentationPath::RAW_BGRA;
    oesSourceWidth_ = 0;
    oesSourceHeight_ = 0;
    CalculateActiveViewport(vpX, vpY, vpW, vpH);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glViewport(vpX, height_ - vpY - vpH, vpW, vpH);
    lastVpX_ = vpX;
    lastVpY_ = vpY;
    lastVpW_ = vpW;
    lastVpH_ = vpH;
    PublishViewportSnapshot(vpX, vpY, vpW, vpH);
    glUseProgram(rawShaderProgram_);
    glUniform1i(rawSamplerLocation_, 0);
    if (rawCanvasRotationLocation_ >= 0) {
        glUniform1i(rawCanvasRotationLocation_, canvasRotationQuarterTurns_);
    }
    if (rawCanvasFlipXLocation_ >= 0) {
        glUniform1i(rawCanvasFlipXLocation_, canvasFlipX_ ? 1 : 0);
    }
    if (rawCanvasFlipYLocation_ >= 0) {
        glUniform1i(rawCanvasFlipYLocation_, canvasFlipY_ ? 1 : 0);
    }
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, rawTexture_);
    glBindVertexArray(vao_);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindVertexArray(0);
    const auto drawAt = clock::now();
    const bool swapped = eglSwapBuffers(eglDisplay_, eglSurface_) == EGL_TRUE;
    const auto swapAt = clock::now();
    ReleaseCurrent();
    metrics.result = swapped ? RdpPresentResult::Presented : RdpPresentResult::SwapFailed;
    metrics.drawUs = std::chrono::duration_cast<std::chrono::microseconds>(
        drawAt - drawBeginAt).count();
    metrics.swapUs = std::chrono::duration_cast<std::chrono::microseconds>(
        swapAt - drawAt).count();
    const auto nowUs = std::chrono::duration_cast<std::chrono::microseconds>(
        swapAt.time_since_epoch()).count();
    presentationMetrics_.recordPresent(nowUs, metrics);
    return metrics;
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
    const bool swapSourceAxes = (canvasRotationQuarterTurns_ % 2) != 0;
    const int displaySourceWidth = swapSourceAxes ? sourceHeight : sourceWidth;
    const int displaySourceHeight = swapSourceAxes ? sourceWidth : sourceHeight;
    const double scaleW = static_cast<double>(width_) / static_cast<double>(displaySourceWidth);
    const double scaleH = static_cast<double>(height_) / static_cast<double>(displaySourceHeight);
    const double contain = std::min(scaleW, scaleH);
    const double scale = contain * canvasScale_;
    vpW = std::max(1, static_cast<int>(std::lround(static_cast<double>(displaySourceWidth) * scale)));
    vpH = std::max(1, static_cast<int>(std::lround(static_cast<double>(displaySourceHeight) * scale)));
    vpX = static_cast<int>(std::lround(static_cast<double>(width_ - vpW) / 2.0 + canvasPanX_));
    vpY = static_cast<int>(std::lround(static_cast<double>(height_ - vpH) / 2.0 + canvasPanY_));
}

void GLRenderer::CalculateActiveViewport(int& vpX, int& vpY, int& vpW, int& vpH) const {
    Render::PresentationPathKind path = Render::PresentationPathKind::Unknown;
    if (presentationPath_ == PresentationPath::RAW_BGRA) {
        path = Render::PresentationPathKind::RawBgra;
    } else if (presentationPath_ == PresentationPath::OES) {
        path = Render::PresentationPathKind::Oes;
    }
    const auto source = Render::SelectPresentationGeometry(
        path, sourceWidth_, sourceHeight_, rawPresentationWidth_,
        rawPresentationHeight_, rawTextureWidth_, rawTextureHeight_,
        oesSourceWidth_, oesSourceHeight_);
    CalculateViewport(source.width, source.height, vpX, vpY, vpW, vpH);
}

void GLRenderer::GetViewportSnapshot(int& vpX, int& vpY, int& vpW, int& vpH,
                                     int& sourceWidth, int& sourceHeight,
                                     int& surfaceWidth, int& surfaceHeight,
                                     uint64_t& transformVersion) const {
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
        transformVersion = snapshotTransformVersion_.load(std::memory_order_relaxed);
        const uint64_t after = viewportSnapshotVersion_.load(std::memory_order_acquire);
        if (before == after) {
            return;
        }
    }
}

RendererCanvasTransformSnapshot GLRenderer::GetCanvasTransformSnapshot() const {
    RendererCanvasTransformSnapshot snapshot;
    for (;;) {
        const uint64_t before = viewportSnapshotVersion_.load(std::memory_order_acquire);
        if ((before & 1U) != 0U) {
            continue;
        }
        snapshot.version = snapshotTransformVersion_.load(std::memory_order_relaxed);
        snapshot.rotationQuarterTurns =
            snapshotRotationQuarterTurns_.load(std::memory_order_relaxed);
        snapshot.flipX = snapshotFlipX_.load(std::memory_order_relaxed);
        snapshot.flipY = snapshotFlipY_.load(std::memory_order_relaxed);
        const uint64_t after = viewportSnapshotVersion_.load(std::memory_order_acquire);
        if (before == after) {
            snapshot.valid = snapshot.version != 0U;
            return snapshot;
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
    snapshotTransformVersion_.store(appliedCanvasTransformVersion_, std::memory_order_relaxed);
    snapshotRotationQuarterTurns_.store(
        canvasRotationQuarterTurns_, std::memory_order_relaxed);
    snapshotFlipX_.store(canvasFlipX_, std::memory_order_relaxed);
    snapshotFlipY_.store(canvasFlipY_, std::memory_order_relaxed);
    viewportSnapshotVersion_.fetch_add(1, std::memory_order_release);
}

RdpPresentationMetricsSnapshot GLRenderer::GetPresentationStats() {
    // presentationMetrics_ has its own mutex.  Do not take the EGL lifecycle
    // lock here: RenderFrame/PresentRawBGRA hold it across eglSwapBuffers(),
    // and diagnostics is polled from the UI timer thread.
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
    {
        std::lock_guard<std::mutex> callbackLock(redrawCallbackMutex_);
        redrawCallback_ = nullptr;
        sessionRedrawCallback_ = nullptr;
    }
    const bool detachedWindowSurface = usesProcessSurface_ &&
        g_surfaceDetached.load(std::memory_order_acquire) && eglSurface_ != EGL_NO_SURFACE;
    EGLNativeWindowType surfaceWindow = 0;
    bool surfaceWindowOwned = false;
    if (usesProcessSurface_) {
        std::lock_guard<std::mutex> surfaceLock(g_surfaceStateMutex);
        surfaceWindow = g_nativeWindow;
        surfaceWindowOwned = g_surfaceIdWindowOwned;
    } else {
        surfaceWindow = reinterpret_cast<EGLNativeWindowType>(explicitNativeWindow_);
        surfaceWindowOwned = explicitNativeWindow_ != nullptr;
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
    rawPresentationWidth_ = 0;
    rawPresentationHeight_ = 0;
    if (hasCurrent) {
        DestroyUploadPbosLocked();
    } else {
        // The EGL context is already gone; the names cannot be deleted safely.
        uploadPbo_[0] = 0;
        uploadPbo_[1] = 0;
        uploadPboCapacity_[0] = 0;
        uploadPboCapacity_[1] = 0;
        uploadPboIndex_ = 0;
    }
    pboUploadEnabled_ = false;
    if (hasCurrent && vbo_) {
        glDeleteBuffers(1, &vbo_);
        vbo_ = 0;
    }
    if (hasCurrent && vao_) {
        glDeleteVertexArrays(1, &vao_);
        vao_ = 0;
    }
    const EGLDisplay displayLease = eglDisplay_;
    const bool releaseDisplayLease = eglDisplayLeaseHeld_;
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
            eglDisplay_ = EGL_NO_DISPLAY;
        } else {
            if (eglContext_ != EGL_NO_CONTEXT) {
                eglDestroyContext(eglDisplay_, eglContext_);
                eglContext_ = EGL_NO_CONTEXT;
            }
            eglDisplay_ = EGL_NO_DISPLAY;
        }
    }
    eglDisplayLeaseHeld_ = false;
    if (releaseDisplayLease) {
        ReleaseSharedEglDisplay(displayLease, !detachedWindowSurface);
    }
    rawPresentationWidth_ = 0;
    rawPresentationHeight_ = 0;
    if (usesProcessSurface_) {
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
    if (!usesProcessSurface_ && explicitNativeWindow_ != nullptr) {
        OH_NativeWindow_DestroyNativeWindow(
            static_cast<OHNativeWindow*>(explicitNativeWindow_));
        explicitNativeWindow_ = nullptr;
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
    Render::DecoderSessionIdentity owner;
    Render::DecoderSessionIdentity boundOwner;
    bool active = false;
    bool detached = true;
    bool destroying = false;
};

// 活跃渲染器句柄 — 供 RenderRawBgraActive 零参数调用
static std::atomic<int64_t> g_activeRendererHandle {0};
static std::mutex g_activeRendererMutex;
static Render::DecoderSessionIdentity g_activeRendererOwner;
// Decoder callbacks can outlive the UI-side numeric handle. Handles must not
// be raw addresses: a destroyed context can be allocated at the same address
// during a fast PIP surface transfer, making an old callback target a new
// renderer. Keep monotonically increasing opaque IDs in the same registry
// mutex so stale callbacks are rejected before any context is dereferenced.
static std::atomic<int64_t> g_nextRendererHandle {1};
static std::unordered_map<int64_t, std::shared_ptr<RendererContext>> g_rendererContexts;
static std::function<void()> g_activeRedrawCallback;
static uint64_t g_nextRedrawCallbackToken = 1;
static uint64_t g_activeRedrawCallbackToken = 0;

static std::shared_ptr<RendererContext> FindRendererContextLocked(int64_t handle) {
    if (handle <= 0) {
        return nullptr;
    }
    const auto it = g_rendererContexts.find(handle);
    return it == g_rendererContexts.end() ? nullptr : it->second;
}

static bool IsActiveRendererHandleLocked(int64_t handle) {
    const auto ctx = FindRendererContextLocked(handle);
    return handle > 0 && g_activeRendererHandle.load(std::memory_order_acquire) == handle &&
        ctx != nullptr && ctx->active && !ctx->detached && !ctx->destroying;
}

static bool IsActiveRendererOwnerLocked(const Render::DecoderSessionIdentity& owner) {
    return Render::SessionOwnerMatches(g_activeRendererOwner, owner);
}

static bool IsActiveRendererOwnerAndHandleLocked(
    int64_t handle, const Render::DecoderSessionIdentity& owner) {
    const auto ctx = FindRendererContextLocked(handle);
    return IsActiveRendererHandleLocked(handle) && IsActiveRendererOwnerLocked(owner) &&
        ctx != nullptr && ctx->active && !ctx->detached &&
        Render::SessionOwnerMatches(ctx->boundOwner, owner);
}

static bool IsRendererOwnerAndHandleLocked(
    int64_t handle, const Render::DecoderSessionIdentity& owner) {
    const auto ctx = FindRendererContextLocked(handle);
    return handle > 0 && ctx != nullptr && ctx->renderer != nullptr &&
        ctx->active && !ctx->detached && !ctx->destroying &&
        Render::SessionOwnerMatches(ctx->boundOwner, owner);
}

static std::shared_ptr<GLRenderer> AcquireRendererLocked(int64_t handle,
                                                          bool requireActive,
                                                          uint64_t* generation = nullptr) {
    const auto ctx = FindRendererContextLocked(handle);
    if (!ctx || !ctx->renderer || ctx->destroying ||
        (requireActive && (!IsActiveRendererHandleLocked(handle) || !ctx->active || ctx->detached))) {
        return nullptr;
    }
    if (generation) {
        *generation = ctx->generation;
    }
    return ctx->renderer;
}

// Auxiliary renderers are active for the same exact session owner without
// becoming the process-global interactive renderer. Do not route this access
// through IsActiveRendererHandleLocked(), which intentionally recognizes only
// g_activeRendererHandle and would reject every auxiliary canvas.
static std::shared_ptr<GLRenderer> AcquireRendererForOwnerLocked(
    int64_t handle, const Render::DecoderSessionIdentity& owner,
    uint64_t* generation = nullptr) {
    if (!IsRendererOwnerAndHandleLocked(handle, owner)) {
        return nullptr;
    }
    return AcquireRendererLocked(handle, false, generation);
}

// Public NAPI calls carry only the opaque handle, so pin the current session
// owner for the complete object call. This closes the check-then-use window in
// which S1 could pass the active-map lookup while S2 was being published.
struct PublicRendererAccess {
    Render::SessionSinkOwnerLease::Lease ownerLease;
    std::shared_ptr<GLRenderer> renderer;
    uint64_t generation = 0;
};

static PublicRendererAccess AcquirePublicRenderer(int64_t handle) {
    PublicRendererAccess access;
    const Render::DecoderSessionIdentity owner =
        Render::SharedSessionSinkOwnerLease().snapshot();
    access.ownerLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!access.ownerLease) {
        return access;
    }
    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    if (!IsActiveRendererOwnerAndHandleLocked(handle, owner)) {
        access.ownerLease = {};
        return access;
    }
    access.renderer = AcquireRendererLocked(handle, true, &access.generation);
    if (!access.renderer) {
        access.ownerLease = {};
    }
    return access;
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

    const Render::DecoderSessionIdentity owner =
        Render::SharedSessionSinkOwnerLease().snapshot();
    // doConnect() creates the renderer before connect() publishes the session
    // owner. Keep the shared lease only when an already-active session exists;
    // a cold-start renderer is intentionally owner-pending until the activation
    // transaction binds its exact session identity.
    Render::SessionSinkOwnerLease::Lease ownerLease;
    if (owner.valid()) {
        ownerLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
        if (!ownerLease) {
            napi_value errVal;
            napi_create_int32(env, -1, &errVal);
            return errVal;
        }
    }

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
    auto ctx = std::make_shared<RendererContext>();
    ctx->renderer = renderer;
    ctx->owner = owner;
    ctx->boundOwner = owner;
    ctx->active = false;
    ctx->detached = true;
    int64_t handleVal = g_nextRendererHandle.fetch_add(1, std::memory_order_relaxed);
    if (handleVal <= 0) {
        // Extremely defensive overflow handling; zero and negative values are
        // reserved for "no renderer" throughout the NAPI/decoder boundary.
        handleVal = g_nextRendererHandle.fetch_add(1, std::memory_order_relaxed);
    }
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        g_rendererContexts.emplace(handleVal, ctx);
    }
    renderer->SetRendererHandle(handleVal);
    napi_value handle;
    napi_create_int64(env, handleVal, &handle);

    // The owner lease is intentionally held while the token enters the active
    // map, so an S1->S2 transition cannot publish a half-bound renderer. When
    // restoring an existing session, bind the active owner in the same
    // transaction. The ownerless overload only updates the handle; using it
    // here leaves g_activeRendererOwner empty after PIP/background teardown
    // and the owner check below rejects the renderer immediately.
    bool active = false;
    if (owner.valid()) {
        active = RendererNapi::SetActiveRenderer(handleVal, owner);
        if (active) {
            active = RendererNapi::IsActiveRendererForOwnerUnderLease(handleVal, owner);
        }
    } else {
        RendererNapi::SetActiveRenderer(handleVal);
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        active = IsActiveRendererHandleLocked(handleVal);
    }
    if (!active) {
        RendererNapi::DestroyRendererHandle(handleVal);
        napi_value errVal;
        napi_create_int32(env, -1, &errVal);
        return errVal;
    }

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

    auto access = AcquirePublicRenderer(handleVal);
    if (access.renderer) {
        access.renderer->RenderFrame(static_cast<GLuint>(textureId));
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

    auto access = AcquirePublicRenderer(handleVal);
    if (access.renderer) {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        const auto ctx = FindRendererContextLocked(handleVal);
        if (!ctx || ctx->renderer != access.renderer ||
            !IsActiveRendererHandleLocked(handleVal)) {
            access.renderer.reset();
        }
        // Viewport size is presentation geometry, not renderer ownership.
        // Advancing the ownership generation here invalidates the exact
        // decoder binding on every rotation/PIP resize and strands a healthy
        // hardware pipeline after the first surface-size callback.
    }
    if (access.renderer) {
        access.renderer->Resize(width, height);
    }

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

/** NAPI: setRendererCanvasTransform(handle, scale, panX, panY, rotationQuarterTurns, flipX, flipY): number */
napi_value NapiSetRendererCanvasTransform(napi_env env, napi_callback_info info) {
    size_t argc = 7;
    napi_value args[7];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t handleVal = 0;
    double scale = 1.0;
    double panX = 0.0;
    double panY = 0.0;
    int32_t rotationQuarterTurns = 0;
    bool flipX = false;
    bool flipY = false;
    if (argc > 0) napi_get_value_int64(env, args[0], &handleVal);
    if (argc > 1) napi_get_value_double(env, args[1], &scale);
    if (argc > 2) napi_get_value_double(env, args[2], &panX);
    if (argc > 3) napi_get_value_double(env, args[3], &panY);
    if (argc > 4) napi_get_value_int32(env, args[4], &rotationQuarterTurns);
    if (argc > 5) napi_get_value_bool(env, args[5], &flipX);
    if (argc > 6) napi_get_value_bool(env, args[6], &flipY);
    auto access = AcquirePublicRenderer(handleVal);
    uint64_t version = 0;
    if (access.renderer) {
        version = access.renderer->SetCanvasTransform(
            scale, panX, panY, rotationQuarterTurns, flipX, flipY);
    }
    napi_value result;
    napi_create_double(env, static_cast<double>(version), &result);
    return result;
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
    const Render::DecoderSessionIdentity owner = Render::SharedSessionSinkOwnerLease().snapshot();
    if (owner.valid()) {
        RendererNapi::DeactivateRenderer(handleVal, owner);
        RendererNapi::DestroyRendererHandle(handleVal, owner);
    } else {
        // A renderer can exist between initRenderer() and connect(). In that
        // window there is no session owner to pass to the owner-aware teardown;
        // the opaque handle is still exact, so use the unbound cleanup path.
        RendererNapi::DeactivateRenderer(handleVal);
        RendererNapi::DestroyRendererHandle(handleVal);
    }

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

    auto access = AcquirePublicRenderer(handleVal);
    if (access.renderer) {
        access.renderer->RenderRawBGRA(static_cast<const uint8_t*>(data), width, height, stride);
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

    auto access = AcquirePublicRenderer(handleVal);
    if (access.renderer) {
        // 直接清屏蓝色并 swap — 不依赖解码器纹理
        GLRenderer* r = access.renderer.get();
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
    (void)info;
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

    auto access = AcquirePublicRenderer(handle);
    if (!access.renderer) {
        napi_value nullVal;
        napi_get_null(env, &nullVal);
        return nullVal;
    }

    int vpX = 0, vpY = 0, vpW = 0, vpH = 0;
    int srcW = 0, srcH = 0, surfW = 0, surfH = 0;
    uint64_t transformVersion = 0;
    access.renderer->GetViewportSnapshot(vpX, vpY, vpW, vpH, srcW, srcH, surfW, surfH,
                                         transformVersion);

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
    napi_create_double(env, static_cast<double>(transformVersion), &val);
    napi_set_named_property(env, result, "transformVersion", val);

    return result;
}

} // anonymous namespace

void RendererNapi::SetActiveRenderer(int64_t handle) {
    std::shared_ptr<GLRenderer> renderer;
    std::shared_ptr<GLRenderer> previousRenderer;
    std::function<void()> redrawCallback;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        const auto ctx = FindRendererContextLocked(handle);
        if (!ctx || !ctx->renderer || ctx->destroying ||
            (g_activeRendererOwner.valid() && ctx->boundOwner.valid() &&
             g_activeRendererOwner != ctx->boundOwner)) {
            OH_LOG_WARN(LOG_APP, "[GL] active renderer rejected stale handle=%{public}lld",
                        static_cast<long long>(handle));
            return;
        }
        const int64_t previousHandle = g_activeRendererHandle.load(std::memory_order_acquire);
        std::shared_ptr<GLRenderer> previousRenderer;
        if (previousHandle != handle) {
            previousRenderer = AcquireRendererLocked(previousHandle, false);
        }
        const bool ownerMatches =
            (!g_activeRendererOwner.valid() && !ctx->boundOwner.valid()) ||
            (g_activeRendererOwner.valid() &&
             ctx->boundOwner == g_activeRendererOwner &&
             ctx->owner == g_activeRendererOwner);
        if (Render::ShouldAdvanceRendererGeneration(
                previousHandle, handle, ctx->active, ctx->detached,
                ownerMatches, ctx->generation)) {
            ctx->generation = AdvanceRendererGeneration();
        }
        // An ownerless renderer is a pending token for the next activation;
        // never bind it to the previous session merely because that session's
        // component state is still being retired.
        ctx->owner = ctx->boundOwner;
        ctx->active = true;
        ctx->detached = false;
        g_activeRendererHandle.store(handle, std::memory_order_release);
        {
            std::lock_guard<std::mutex> surfaceLock(g_surfaceStateMutex);
            g_surfaceOwnerHandle.store(handle, std::memory_order_release);
        }
        renderer = ctx->renderer;
        redrawCallback = g_activeRedrawCallback;
    }
    if (previousRenderer && previousRenderer != renderer) {
        previousRenderer->SetSessionRedrawCallback(nullptr);
    }
    if (renderer) {
        renderer->SetSessionRedrawCallback(std::move(redrawCallback));
    }
    OH_LOG_INFO(LOG_APP, "[GL] active renderer set handle=%{public}lld",
                static_cast<long long>(handle));
}

bool RendererNapi::SetActiveRenderer(
    int64_t handle, const Render::DecoderSessionIdentity& owner) {
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        return false;
    }
    std::shared_ptr<GLRenderer> renderer;
    std::shared_ptr<GLRenderer> previousRenderer;
    std::function<void()> redrawCallback;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        const auto ctx = FindRendererContextLocked(handle);
        if (!ctx || !ctx->renderer ||
            (g_activeRendererOwner.valid() && g_activeRendererOwner != owner) ||
            (ctx->boundOwner.valid() && ctx->boundOwner != owner) || ctx->destroying) {
            return false;
        }
        const int64_t previousHandle = g_activeRendererHandle.load(std::memory_order_acquire);
        if (previousHandle != handle) {
            previousRenderer = AcquireRendererLocked(previousHandle, false);
        }
        const bool ownerMatches = g_activeRendererOwner == owner &&
            ctx->boundOwner == owner && ctx->owner == owner;
        g_activeRendererOwner = owner;
        if (Render::ShouldAdvanceRendererGeneration(
                previousHandle, handle, ctx->active, ctx->detached,
                ownerMatches, ctx->generation)) {
            ctx->generation = AdvanceRendererGeneration();
        }
        ctx->boundOwner = owner;
        ctx->owner = owner;
        ctx->active = true;
        ctx->detached = false;
        g_activeRendererHandle.store(handle, std::memory_order_release);
        {
            std::lock_guard<std::mutex> surfaceLock(g_surfaceStateMutex);
            g_surfaceOwnerHandle.store(handle, std::memory_order_release);
        }
        renderer = ctx->renderer;
        redrawCallback = g_activeRedrawCallback;
    }
    if (previousRenderer && previousRenderer != renderer) {
        previousRenderer->SetSessionRedrawCallback(nullptr);
    }
    if (renderer) {
        renderer->SetSessionRedrawCallback(std::move(redrawCallback));
    }
    return true;
}

bool RendererNapi::IsActiveRendererForOwnerUnderLease(
    int64_t handle, const Render::DecoderSessionIdentity& owner) {
    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    return IsActiveRendererOwnerAndHandleLocked(handle, owner);
}

bool RendererNapi::IsRendererForOwnerUnderLease(
    int64_t handle, const Render::DecoderSessionIdentity& owner) {
    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    return IsRendererOwnerAndHandleLocked(handle, owner);
}

uint64_t RendererNapi::GetRendererGenerationUnderOwnerLease(
    int64_t handle, const Render::DecoderSessionIdentity& owner) {
    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    const auto context = FindRendererContextLocked(handle);
    return context && IsRendererOwnerAndHandleLocked(handle, owner)
        ? context->generation : 0U;
}

uint64_t RendererNapi::GetRendererGeneration(
    int64_t handle, const Render::DecoderSessionIdentity& owner) {
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        return 0U;
    }
    return GetRendererGenerationUnderOwnerLease(handle, owner);
}

RendererNapi::OwnedRendererCreationResult RendererNapi::CreateOwnedAuxRenderer(
    const std::string& surfaceId, int width, int height,
    const Render::DecoderSessionIdentity& owner) {
    OwnedRendererCreationResult result;
    if (surfaceId.empty() || width <= 0 || height <= 0 || !owner.valid()) {
        return result;
    }
    auto ownerLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!ownerLease) {
        return result;
    }
    auto renderer = std::shared_ptr<GLRenderer>(new GLRenderer());
    if (renderer->Init(surfaceId, width, height) != 0) {
        return result;
    }
    auto context = std::make_shared<RendererContext>();
    context->renderer = renderer;
    context->owner = owner;
    context->boundOwner = owner;
    context->active = true;
    context->detached = false;
    context->generation = NextAuxRendererGeneration();
    int64_t handle = g_nextRendererHandle.fetch_add(1, std::memory_order_relaxed);
    if (handle <= 0) {
        handle = g_nextRendererHandle.fetch_add(1, std::memory_order_relaxed);
    }
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        g_rendererContexts.emplace(handle, context);
    }
    renderer->SetRendererHandle(handle);
    result.ok = true;
    result.rendererHandle = handle;
    result.rendererGeneration = context->generation;
    OH_LOG_INFO(LOG_APP,
        "[GL] auxiliary renderer created handle=%{public}lld generation=%{public}llu surface=%{public}s",
        static_cast<long long>(handle),
        static_cast<unsigned long long>(context->generation),
        surfaceId.c_str());
    return result;
}

uint64_t RendererNapi::SetRendererCanvasTransform(
    int64_t handle, const Render::DecoderSessionIdentity& owner,
    double scale, double panX, double panY, int rotationQuarterTurns,
    bool flipX, bool flipY) {
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        return 0U;
    }
    std::shared_ptr<GLRenderer> renderer;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        renderer = AcquireRendererForOwnerLocked(handle, owner);
    }
    return renderer ? renderer->SetCanvasTransform(
        scale, panX, panY, rotationQuarterTurns, flipX, flipY) : 0U;
}

uint64_t RendererNapi::GetActiveRendererGenerationUnderOwnerLease(
    int64_t handle, const Render::DecoderSessionIdentity& owner) {
    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    const auto context = FindRendererContextLocked(handle);
    return context && IsActiveRendererOwnerAndHandleLocked(handle, owner)
        ? context->generation : 0U;
}

RendererCanvasTransformSnapshot
RendererNapi::GetRendererCanvasTransformUnderOwnerLease(
    int64_t handle, const Render::DecoderSessionIdentity& owner) {
    std::shared_ptr<GLRenderer> renderer;
    uint64_t rendererGeneration = 0;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        renderer = AcquireRendererForOwnerLocked(
            handle, owner, &rendererGeneration);
    }
    if (!renderer) {
        return {};
    }
    RendererCanvasTransformSnapshot snapshot =
        renderer->GetCanvasTransformSnapshot();
    snapshot.rendererGeneration = rendererGeneration;
    return snapshot;
}

uint64_t RendererNapi::GetActiveRendererGeneration(
    int64_t handle, const Render::DecoderSessionIdentity& owner) {
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        return 0U;
    }
    return GetActiveRendererGenerationUnderOwnerLease(handle, owner);
}

int64_t RendererNapi::GetActiveRendererHandle(
    const Render::DecoderSessionIdentity& owner) {
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        return 0;
    }
    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
    return IsActiveRendererOwnerAndHandleLocked(handle, owner) ? handle : 0;
}

void RendererNapi::SetActiveSessionOwner(const Render::DecoderSessionIdentity& owner) {
    std::shared_ptr<GLRenderer> staleRenderer;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
        const auto ctx = FindRendererContextLocked(handle);
        if (ctx && ctx->boundOwner.valid() && ctx->boundOwner != owner) {
            // The old token remains permanently bound to S1. Detach it from
            // the active slot before publishing S2; its later teardown can
            // still destroy only that exact token.
            staleRenderer = ctx->renderer;
            ctx->active = false;
            ctx->detached = true;
            g_activeRendererHandle.store(0, std::memory_order_release);
            g_activeRendererOwner = owner;
            AdvanceRendererGeneration();
        } else {
            g_activeRendererOwner = owner;
            if (ctx) {
                ctx->boundOwner = owner;
                ctx->owner = owner;
            }
        }
    }
    if (staleRenderer) {
        staleRenderer->SetSessionRedrawCallback(nullptr);
    }
}

void RendererNapi::ClearActiveSessionOwner(const Render::DecoderSessionIdentity& owner) {
    std::shared_ptr<GLRenderer> staleRenderer;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        if (!IsActiveRendererOwnerLocked(owner)) {
            return;
        }
        const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
        const auto ctx = FindRendererContextLocked(handle);
        if (ctx && IsActiveRendererOwnerAndHandleLocked(handle, owner)) {
            staleRenderer = ctx->renderer;
            ctx->active = false;
            ctx->detached = true;
            g_activeRendererHandle.store(0, std::memory_order_release);
            AdvanceRendererGeneration();
        }
        g_activeRendererOwner = Render::DecoderSessionIdentity {};
    }
    if (staleRenderer) {
        staleRenderer->SetSessionRedrawCallback(nullptr);
    }
}

RdpPresentationMetricsSnapshot RendererNapi::GetActivePresentationStats() {
    std::shared_ptr<GLRenderer> renderer;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
        renderer = AcquireRendererLocked(handle, true);
    }
    if (!renderer) {
        return RdpPresentationMetricsSnapshot();
    }
    return renderer->GetPresentationStats();
}

RdpPresentationMetricsSnapshot RendererNapi::GetActivePresentationStats(
    const Render::DecoderSessionIdentity& owner) {
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        return RdpPresentationMetricsSnapshot();
    }
    std::shared_ptr<GLRenderer> renderer;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
        if (!IsActiveRendererOwnerAndHandleLocked(handle, owner)) {
            return RdpPresentationMetricsSnapshot();
        }
        renderer = AcquireRendererLocked(handle, true);
    }
    return renderer ? renderer->GetPresentationStats() : RdpPresentationMetricsSnapshot();
}

bool RendererNapi::SetActivePboUpload(bool enabled) {
    std::shared_ptr<GLRenderer> renderer;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
        renderer = AcquireRendererLocked(handle, true);
    }
    if (!renderer) {
        return false;
    }
    renderer->SetPboUploadEnabled(enabled);
    return true;
}

bool RendererNapi::SetActivePboUpload(const Render::DecoderSessionIdentity& owner,
                                      bool enabled) {
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        return false;
    }
    std::shared_ptr<GLRenderer> renderer;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
        if (!IsActiveRendererOwnerAndHandleLocked(handle, owner)) {
            return false;
        }
        renderer = AcquireRendererLocked(handle, true);
    }
    if (!renderer) {
        return false;
    }
    renderer->SetPboUploadEnabled(enabled);
    return true;
}

void RendererNapi::InvalidateActivePresentation() {
    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    if (g_activeRendererHandle.load(std::memory_order_acquire) > 0) {
        AdvanceRendererGeneration();
    }
}

void RendererNapi::InvalidateActivePresentation(const Render::DecoderSessionIdentity& owner) {
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        return;
    }
    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
    if (IsActiveRendererOwnerAndHandleLocked(handle, owner)) {
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
    const auto ctx = FindRendererContextLocked(handle);
    if (!ctx || !ctx->renderer) {
        return false;
    }
    ctx->generation = AdvanceRendererGeneration();
    return true;
}

bool RendererNapi::ReenableActivePresentation(const Render::DecoderSessionIdentity& owner) {
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        return false;
    }
    std::lock_guard<std::mutex> lock(g_activeRendererMutex);
    const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
    if (!IsActiveRendererOwnerAndHandleLocked(handle, owner) ||
        g_surfaceDetached.load(std::memory_order_acquire) ||
        !g_surfaceReady.load(std::memory_order_acquire)) {
        return false;
    }
        const auto ctx = FindRendererContextLocked(handle);
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
    std::shared_ptr<GLRenderer> renderer;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        const auto ctx = FindRendererContextLocked(handle);
        if (ctx && g_activeRendererHandle.load(std::memory_order_acquire) == handle) {
            renderer = ctx->renderer;
            ctx->active = false;
            ctx->detached = true;
            g_activeRendererHandle.store(0, std::memory_order_release);
            AdvanceRendererGeneration();
        }
    }
    if (renderer) {
        renderer->SetSessionRedrawCallback(nullptr);
    }
}

void RendererNapi::DeactivateRenderer(
    int64_t handle, const Render::DecoderSessionIdentity& owner) {
    if (handle <= 0) {
        return;
    }
    std::shared_ptr<GLRenderer> renderer;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        const auto ctx = FindRendererContextLocked(handle);
        if (!ctx || !IsActiveRendererOwnerAndHandleLocked(handle, owner)) {
            return;
        }
        renderer = ctx->renderer;
        ctx->active = false;
        ctx->detached = true;
        g_activeRendererHandle.store(0, std::memory_order_release);
        g_activeRendererOwner = Render::DecoderSessionIdentity {};
        AdvanceRendererGeneration();
    }
    if (renderer) {
        renderer->SetSessionRedrawCallback(nullptr);
    }
}

void RendererNapi::DestroyRendererHandle(int64_t handle) {
    if (handle <= 0) {
        return;
    }
    std::shared_ptr<GLRenderer> renderer;
    bool clearCallback = false;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        const auto ctx = FindRendererContextLocked(handle);
        if (!ctx) {
            return;
        }
        if (g_activeRendererHandle.load(std::memory_order_acquire) == handle) {
            clearCallback = true;
            g_activeRendererHandle.store(0, std::memory_order_release);
            g_activeRendererOwner = Render::DecoderSessionIdentity {};
            AdvanceRendererGeneration();
        }
        ctx->active = false;
        ctx->detached = true;
        ctx->destroying = true;
        renderer = std::move(ctx->renderer);
        g_rendererContexts.erase(handle);
    }
    if (renderer && clearCallback) {
        renderer->SetSessionRedrawCallback(nullptr);
    }
}

void RendererNapi::DestroyRendererHandle(
    int64_t handle, const Render::DecoderSessionIdentity& owner) {
    if (handle <= 0) {
        return;
    }
    std::shared_ptr<GLRenderer> renderer;
    bool clearCallback = false;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        const auto ctx = FindRendererContextLocked(handle);
        if (!ctx || !Render::SessionOwnerMatches(ctx->boundOwner, owner)) {
            return;
        }
        if (g_activeRendererHandle.load(std::memory_order_acquire) == handle) {
            clearCallback = true;
            g_activeRendererHandle.store(0, std::memory_order_release);
            g_activeRendererOwner = Render::DecoderSessionIdentity {};
            AdvanceRendererGeneration();
        }
        ctx->active = false;
        ctx->detached = true;
        ctx->destroying = true;
        renderer = std::move(ctx->renderer);
        g_rendererContexts.erase(handle);
    }
    if (renderer && clearCallback) {
        renderer->SetSessionRedrawCallback(nullptr);
    }
}

RdpPresentationTarget RendererNapi::GetActivePresentationTarget() {
    RdpPresentationTarget target;
    std::shared_ptr<GLRenderer> renderer;
    uint64_t contextGeneration = 0;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        target.generation = g_rendererGeneration.load(std::memory_order_acquire);
        const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
        renderer = AcquireRendererLocked(handle, true, &contextGeneration);
    }
    if (g_surfaceDetached.load(std::memory_order_acquire) ||
        !g_surfaceReady.load(std::memory_order_acquire)) {
        target.rejection = RdpPresentResult::SurfaceDetached;
        return target;
    }
    if (!renderer) {
        target.rejection = RdpPresentResult::NoActiveRenderer;
        return target;
    }
    if (contextGeneration != target.generation) {
        target.rejection = RdpPresentResult::GenerationMismatch;
        return target;
    }
    if (!renderer->IsPresentationReady()) {
        target.rejection = g_surfaceDetached.load(std::memory_order_acquire) ?
            RdpPresentResult::SurfaceDetached : RdpPresentResult::RendererNotReady;
        return target;
    }
    target.rejection = RdpPresentResult::Presented;
    return target;
}

RdpPresentationTarget RendererNapi::GetActivePresentationTarget(
    const Render::DecoderSessionIdentity& owner) {
    RdpPresentationTarget target;
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        target.rejection = RdpPresentResult::NoActiveRenderer;
        return target;
    }
    return GetActivePresentationTargetUnderOwnerLease(owner);
}

RdpPresentationTarget RendererNapi::GetActivePresentationTargetUnderOwnerLease(
    const Render::DecoderSessionIdentity& owner) {
    RdpPresentationTarget target;
    std::shared_ptr<GLRenderer> renderer;
    uint64_t contextGeneration = 0;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        target.generation = g_rendererGeneration.load(std::memory_order_acquire);
        const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
        if (!IsActiveRendererOwnerAndHandleLocked(handle, owner)) {
            target.rejection = RdpPresentResult::NoActiveRenderer;
            return target;
        }
        renderer = AcquireRendererLocked(handle, true, &contextGeneration);
    }
    if (g_surfaceDetached.load(std::memory_order_acquire) ||
        !g_surfaceReady.load(std::memory_order_acquire)) {
        target.rejection = RdpPresentResult::SurfaceDetached;
        return target;
    }
    if (!renderer) {
        target.rejection = RdpPresentResult::NoActiveRenderer;
        return target;
    }
    if (contextGeneration != target.generation) {
        target.rejection = RdpPresentResult::GenerationMismatch;
        return target;
    }
    if (!renderer->IsPresentationReady()) {
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
    std::shared_ptr<GLRenderer> renderer;
    uint64_t contextGeneration = 0;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        if (generation == 0 ||
            generation != g_rendererGeneration.load(std::memory_order_acquire)) {
            metrics.result = RdpPresentResult::GenerationMismatch;
            return metrics;
        }
        const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
        renderer = AcquireRendererLocked(handle, true, &contextGeneration);
    }
    if (generation == 0 || contextGeneration != generation) {
        metrics.result = RdpPresentResult::GenerationMismatch;
        return metrics;
    }
    if (g_surfaceDetached.load(std::memory_order_acquire) ||
        !g_surfaceReady.load(std::memory_order_acquire)) {
        metrics.result = RdpPresentResult::SurfaceDetached;
        return metrics;
    }
    if (!renderer) {
        metrics.result = RdpPresentResult::NoActiveRenderer;
        return metrics;
    }
    return renderer->PresentRawBGRA(data, width, height, stride, generation);
}

RdpPresentMetrics RendererNapi::PresentRawBgraActive(
    const Render::DecoderSessionIdentity& owner, const uint8_t* data, size_t size,
    int width, int height, int stride, uint64_t generation) {
    RdpPresentMetrics metrics;
    metrics.generation = generation;
    if (!data || size == 0 || width <= 0 || height <= 0 || stride <= 0) {
        metrics.result = RdpPresentResult::InvalidFrame;
        return metrics;
    }
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        metrics.result = RdpPresentResult::NoActiveRenderer;
        return metrics;
    }
    std::shared_ptr<GLRenderer> renderer;
    uint64_t contextGeneration = 0;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        if (generation == 0 || generation != g_rendererGeneration.load(std::memory_order_acquire)) {
            metrics.result = RdpPresentResult::GenerationMismatch;
            return metrics;
        }
        const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
        if (!IsActiveRendererOwnerAndHandleLocked(handle, owner)) {
            metrics.result = RdpPresentResult::NoActiveRenderer;
            return metrics;
        }
        renderer = AcquireRendererLocked(handle, true, &contextGeneration);
    }
    if (contextGeneration != generation) {
        metrics.result = RdpPresentResult::GenerationMismatch;
        return metrics;
    }
    if (g_surfaceDetached.load(std::memory_order_acquire) ||
        !g_surfaceReady.load(std::memory_order_acquire)) {
        metrics.result = RdpPresentResult::SurfaceDetached;
        return metrics;
    }
    if (!renderer) {
        metrics.result = RdpPresentResult::NoActiveRenderer;
        return metrics;
    }
    return renderer->PresentRawBGRA(data, width, height, stride, generation);
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
    std::shared_ptr<GLRenderer> renderer;
    uint64_t contextGeneration = 0;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        if (generation == 0 ||
            generation != g_rendererGeneration.load(std::memory_order_acquire)) {
            metrics.result = RdpPresentResult::GenerationMismatch;
            return metrics;
        }
        const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
        renderer = AcquireRendererLocked(handle, true, &contextGeneration);
    }
    if (generation == 0 || contextGeneration != generation) {
        metrics.result = RdpPresentResult::GenerationMismatch;
        return metrics;
    }
    if (g_surfaceDetached.load(std::memory_order_acquire) ||
        !g_surfaceReady.load(std::memory_order_acquire)) {
        metrics.result = RdpPresentResult::SurfaceDetached;
        return metrics;
    }
    if (!renderer) {
        metrics.result = RdpPresentResult::NoActiveRenderer;
        return metrics;
    }
    return renderer->PresentRawBGRARect(data, width, height, stride,
                                        dirtyX, dirtyY, dirtyWidth, dirtyHeight, generation);
}

RdpPresentMetrics RendererNapi::PresentRawBgraRectCompactActive(
    const uint8_t* data, size_t size, int width, int height, int stride,
    int dirtyX, int dirtyY, int dirtyWidth, int dirtyHeight, uint64_t generation) {
    RdpPresentMetrics metrics;
    metrics.generation = generation;
    if (!data || size == 0 || width <= 0 || height <= 0 || stride <= 0 ||
        dirtyX < 0 || dirtyY < 0 || dirtyWidth <= 0 || dirtyHeight <= 0 ||
        dirtyX >= width || dirtyY >= height || dirtyWidth > width - dirtyX ||
        dirtyHeight > height - dirtyY || stride < dirtyWidth * 4 || stride % 4 != 0) {
        metrics.result = RdpPresentResult::InvalidFrame;
        return metrics;
    }
    const size_t requiredBytes = static_cast<size_t>(dirtyHeight - 1) *
        static_cast<size_t>(stride) + static_cast<size_t>(dirtyWidth) * 4U;
    if (requiredBytes > size) {
        metrics.result = RdpPresentResult::InvalidFrame;
        return metrics;
    }
    std::shared_ptr<GLRenderer> renderer;
    uint64_t contextGeneration = 0;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        if (generation == 0 || generation != g_rendererGeneration.load(std::memory_order_acquire)) {
            metrics.result = RdpPresentResult::GenerationMismatch;
            return metrics;
        }
        const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
        renderer = AcquireRendererLocked(handle, true, &contextGeneration);
    }
    if (contextGeneration != generation) {
        metrics.result = RdpPresentResult::GenerationMismatch;
        return metrics;
    }
    if (g_surfaceDetached.load(std::memory_order_acquire) ||
        !g_surfaceReady.load(std::memory_order_acquire)) {
        metrics.result = RdpPresentResult::SurfaceDetached;
        return metrics;
    }
    if (!renderer) {
        metrics.result = RdpPresentResult::NoActiveRenderer;
        return metrics;
    }
    return renderer->PresentRawBGRARectCompact(data, size, width, height, stride,
                                                dirtyX, dirtyY, dirtyWidth, dirtyHeight,
                                                generation);
}

RdpPresentMetrics RendererNapi::PresentRawBgraRectActive(
    const Render::DecoderSessionIdentity& owner, const uint8_t* data, size_t size,
    int width, int height, int stride, int dirtyX, int dirtyY, int dirtyWidth,
    int dirtyHeight, uint64_t generation) {
    RdpPresentMetrics metrics;
    metrics.generation = generation;
    if (!data || size == 0 || width <= 0 || height <= 0 || stride <= 0 ||
        dirtyX < 0 || dirtyY < 0 || dirtyWidth <= 0 || dirtyHeight <= 0) {
        metrics.result = RdpPresentResult::InvalidFrame;
        return metrics;
    }
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        metrics.result = RdpPresentResult::NoActiveRenderer;
        return metrics;
    }
    std::shared_ptr<GLRenderer> renderer;
    uint64_t contextGeneration = 0;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        if (generation == 0 || generation != g_rendererGeneration.load(std::memory_order_acquire)) {
            metrics.result = RdpPresentResult::GenerationMismatch;
            return metrics;
        }
        const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
        if (!IsActiveRendererOwnerAndHandleLocked(handle, owner)) {
            metrics.result = RdpPresentResult::NoActiveRenderer;
            return metrics;
        }
        renderer = AcquireRendererLocked(handle, true, &contextGeneration);
    }
    if (contextGeneration != generation) {
        metrics.result = RdpPresentResult::GenerationMismatch;
        return metrics;
    }
    if (g_surfaceDetached.load(std::memory_order_acquire) ||
        !g_surfaceReady.load(std::memory_order_acquire)) {
        metrics.result = RdpPresentResult::SurfaceDetached;
        return metrics;
    }
    if (!renderer) {
        metrics.result = RdpPresentResult::NoActiveRenderer;
        return metrics;
    }
    return renderer->PresentRawBGRARect(data, width, height, stride,
                                        dirtyX, dirtyY, dirtyWidth, dirtyHeight, generation);
}

RdpPresentMetrics RendererNapi::PresentRawBgraRectCompactActive(
    const Render::DecoderSessionIdentity& owner, const uint8_t* data, size_t size,
    int width, int height, int stride, int dirtyX, int dirtyY, int dirtyWidth,
    int dirtyHeight, uint64_t generation) {
    RdpPresentMetrics metrics;
    metrics.generation = generation;
    if (!data || size == 0 || width <= 0 || height <= 0 || stride <= 0 ||
        dirtyX < 0 || dirtyY < 0 || dirtyWidth <= 0 || dirtyHeight <= 0 ||
        dirtyX >= width || dirtyY >= height || dirtyWidth > width - dirtyX ||
        dirtyHeight > height - dirtyY || stride < dirtyWidth * 4 || stride % 4 != 0) {
        metrics.result = RdpPresentResult::InvalidFrame;
        return metrics;
    }
    const size_t requiredBytes = static_cast<size_t>(dirtyHeight - 1) *
        static_cast<size_t>(stride) + static_cast<size_t>(dirtyWidth) * 4U;
    if (requiredBytes > size) {
        metrics.result = RdpPresentResult::InvalidFrame;
        return metrics;
    }
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        metrics.result = RdpPresentResult::NoActiveRenderer;
        return metrics;
    }
    std::shared_ptr<GLRenderer> renderer;
    uint64_t contextGeneration = 0;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        if (generation == 0 || generation != g_rendererGeneration.load(std::memory_order_acquire)) {
            metrics.result = RdpPresentResult::GenerationMismatch;
            return metrics;
        }
        const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
        if (!IsActiveRendererOwnerAndHandleLocked(handle, owner)) {
            metrics.result = RdpPresentResult::NoActiveRenderer;
            return metrics;
        }
        renderer = AcquireRendererLocked(handle, true, &contextGeneration);
    }
    if (contextGeneration != generation) {
        metrics.result = RdpPresentResult::GenerationMismatch;
        return metrics;
    }
    if (g_surfaceDetached.load(std::memory_order_acquire) ||
        !g_surfaceReady.load(std::memory_order_acquire)) {
        metrics.result = RdpPresentResult::SurfaceDetached;
        return metrics;
    }
    if (!renderer) {
        metrics.result = RdpPresentResult::NoActiveRenderer;
        return metrics;
    }
    return renderer->PresentRawBGRARectCompact(data, size, width, height, stride,
                                                dirtyX, dirtyY, dirtyWidth, dirtyHeight,
                                                generation);
}

RdpPresentMetrics RendererNapi::PresentRetainedActive(uint64_t generation) {
    RdpPresentMetrics metrics;
    metrics.generation = generation;
    metrics.retainedFrame = true;
    std::shared_ptr<GLRenderer> renderer;
    uint64_t contextGeneration = 0;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        if (generation == 0 ||
            generation != g_rendererGeneration.load(std::memory_order_acquire)) {
            metrics.result = RdpPresentResult::GenerationMismatch;
            return metrics;
        }
        const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
        renderer = AcquireRendererLocked(handle, true, &contextGeneration);
    }
    if (contextGeneration != generation) {
        metrics.result = RdpPresentResult::GenerationMismatch;
        return metrics;
    }
    if (g_surfaceDetached.load(std::memory_order_acquire) ||
        !g_surfaceReady.load(std::memory_order_acquire)) {
        metrics.result = RdpPresentResult::SurfaceDetached;
        return metrics;
    }
    if (!renderer) {
        metrics.result = RdpPresentResult::NoActiveRenderer;
        return metrics;
    }
    return renderer->PresentRetainedFrame(generation);
}

RdpPresentMetrics RendererNapi::PresentRetainedActive(
    const Render::DecoderSessionIdentity& owner, uint64_t generation) {
    RdpPresentMetrics metrics;
    metrics.generation = generation;
    metrics.retainedFrame = true;
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        metrics.result = RdpPresentResult::NoActiveRenderer;
        return metrics;
    }
    std::shared_ptr<GLRenderer> renderer;
    uint64_t contextGeneration = 0;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        if (generation == 0 || generation != g_rendererGeneration.load(std::memory_order_acquire)) {
            metrics.result = RdpPresentResult::GenerationMismatch;
            return metrics;
        }
        const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
        if (!IsActiveRendererOwnerAndHandleLocked(handle, owner)) {
            metrics.result = RdpPresentResult::NoActiveRenderer;
            return metrics;
        }
        renderer = AcquireRendererLocked(handle, true, &contextGeneration);
    }
    if (contextGeneration != generation) {
        metrics.result = RdpPresentResult::GenerationMismatch;
        return metrics;
    }
    if (g_surfaceDetached.load(std::memory_order_acquire) ||
        !g_surfaceReady.load(std::memory_order_acquire)) {
        metrics.result = RdpPresentResult::SurfaceDetached;
        return metrics;
    }
    if (!renderer) {
        metrics.result = RdpPresentResult::NoActiveRenderer;
        return metrics;
    }
    return renderer->PresentRetainedFrame(generation);
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

int RendererNapi::RenderRawBgraActive(
    const Render::DecoderSessionIdentity& owner, const uint8_t* data, size_t size,
    int width, int height, int stride) {
    if (!data || size == 0 || width <= 0 || height <= 0 || stride <= 0) {
        return static_cast<int>(RdpPresentResult::InvalidFrame);
    }
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        return static_cast<int>(RdpPresentResult::NoActiveRenderer);
    }
    std::shared_ptr<GLRenderer> renderer;
    uint64_t generation = 0;
    uint64_t contextGeneration = 0;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
        generation = g_rendererGeneration.load(std::memory_order_acquire);
        if (!IsActiveRendererOwnerAndHandleLocked(handle, owner) || generation == 0) {
            return static_cast<int>(RdpPresentResult::NoActiveRenderer);
        }
        renderer = AcquireRendererLocked(handle, true, &contextGeneration);
    }
    if (!renderer || contextGeneration != generation) {
        return static_cast<int>(RdpPresentResult::GenerationMismatch);
    }
    if (g_surfaceDetached.load(std::memory_order_acquire) ||
        !g_surfaceReady.load(std::memory_order_acquire)) {
        return static_cast<int>(RdpPresentResult::SurfaceDetached);
    }
    return static_cast<int>(renderer->PresentRawBGRA(
        data, width, height, stride, generation).result);
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
    std::shared_ptr<GLRenderer> renderer;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        renderer = AcquireRendererLocked(handle, true);
    }
    if (renderer) {
        renderer->MakeCurrent();
    }
}

void RendererNapi::MakeCurrent(
    int64_t handle, const Render::DecoderSessionIdentity& owner) {
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        return;
    }
    std::shared_ptr<GLRenderer> renderer;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        renderer = AcquireRendererForOwnerLocked(handle, owner);
    }
    if (renderer) {
        renderer->MakeCurrent();
    }
}

void RendererNapi::ReleaseCurrent(int64_t handle) {
    std::shared_ptr<GLRenderer> renderer;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        renderer = AcquireRendererLocked(handle, true);
    }
    if (renderer) {
        renderer->ReleaseCurrent();
    }
}

void RendererNapi::ReleaseCurrent(
    int64_t handle, const Render::DecoderSessionIdentity& owner) {
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        return;
    }
    std::shared_ptr<GLRenderer> renderer;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        renderer = AcquireRendererForOwnerLocked(handle, owner);
    }
    if (renderer) {
        renderer->ReleaseCurrent();
    }
}

void RendererNapi::SetRendererSourceSize(int64_t handle, int width, int height) {
    std::shared_ptr<GLRenderer> renderer;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        renderer = AcquireRendererLocked(handle, true);
    }
    if (renderer) {
        renderer->SetOesSourceSize(width, height);
    }
}

void RendererNapi::SetRendererSourceSize(
    int64_t handle, const Render::DecoderSessionIdentity& owner, int width, int height) {
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        return;
    }
    std::shared_ptr<GLRenderer> renderer;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        renderer = AcquireRendererForOwnerLocked(handle, owner);
    }
    if (renderer) {
        renderer->SetOesSourceSize(width, height);
    }
}

void RendererNapi::RenderNative(int64_t handle, GLuint textureId) {
    std::shared_ptr<GLRenderer> renderer;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        renderer = AcquireRendererLocked(handle, true);
    }
    if (renderer) {
        renderer->RenderFrame(textureId);
    }
}

void RendererNapi::RenderNative(
    int64_t handle, const Render::DecoderSessionIdentity& owner, GLuint textureId) {
    RenderNative(handle, owner, textureId,
                 Render::IdentityNativeImageTransform());
}

void RendererNapi::RenderNative(
    int64_t handle, const Render::DecoderSessionIdentity& owner, GLuint textureId,
    const Render::NativeImageTransform& textureTransform) {
    (void)PresentNative(handle, owner, textureId, textureTransform);
}

RdpPresentMetrics RendererNapi::PresentNative(
    int64_t handle, const Render::DecoderSessionIdentity& owner, GLuint textureId,
    const Render::NativeImageTransform& textureTransform) {
    RdpPresentMetrics metrics;
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        metrics.result = RdpPresentResult::NoActiveRenderer;
        return metrics;
    }
    std::shared_ptr<GLRenderer> renderer;
    uint64_t generation = 0U;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        renderer = AcquireRendererForOwnerLocked(handle, owner, &generation);
    }
    if (!renderer || generation == 0U) {
        metrics.result = RdpPresentResult::NoActiveRenderer;
        return metrics;
    }
    metrics = renderer->PresentFrame(textureId, textureTransform);
    metrics.generation = generation;
    if (metrics.presented()) {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        const auto context = FindRendererContextLocked(handle);
        if (!context || context->generation != generation ||
            !IsRendererOwnerAndHandleLocked(handle, owner)) {
            // The swap happened on the retained old renderer, but it is not a
            // presentation acknowledgement for the currently bound Surface.
            // Legacy RenderNative callers still retain the actual draw; only
            // the exact-owner proof is fenced out.
            metrics.result = RdpPresentResult::GenerationMismatch;
        }
    }
    return metrics;
}

void RendererNapi::SetActiveSourceSize(int width, int height) {
    std::shared_ptr<GLRenderer> renderer;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
        renderer = AcquireRendererLocked(handle, true);
    }
    if (renderer) {
        renderer->SetSourceSize(width, height);
    }
}

void RendererNapi::SetActiveSourceSize(
    const Render::DecoderSessionIdentity& owner, int width, int height) {
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        return;
    }
    std::shared_ptr<GLRenderer> renderer;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
        if (!IsActiveRendererOwnerAndHandleLocked(handle, owner)) {
            return;
        }
        renderer = AcquireRendererLocked(handle, true);
    }
    if (renderer) {
        renderer->SetSourceSize(width, height);
    }
}

void RendererNapi::SetRendererRedrawCallback(int64_t handle, std::function<void()> callback) {
    std::shared_ptr<GLRenderer> renderer;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        // Detach/rebind must also be able to clear a callback on the previous
        // renderer after it is no longer the active presentation target.
        renderer = AcquireRendererLocked(handle, true);
    }
    if (renderer) {
        renderer->SetRedrawCallback(std::move(callback));
    }
}

void RendererNapi::SetRendererRedrawCallback(
    int64_t handle, const Render::DecoderSessionIdentity& owner,
    std::function<void()> callback) {
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        return;
    }
    std::shared_ptr<GLRenderer> renderer;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        const auto ctx = FindRendererContextLocked(handle);
        if (!ctx || !Render::SessionOwnerMatches(ctx->boundOwner, owner)) {
            return;
        }
        renderer = ctx->renderer;
    }
    if (renderer) {
        renderer->SetRedrawCallback(std::move(callback));
    }
}

uint64_t RendererNapi::RegisterActiveRedrawCallback(std::function<void()> callback) {
    std::shared_ptr<GLRenderer> renderer;
    std::function<void()> callbackSnapshot;
    uint64_t token = 0;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        token = g_nextRedrawCallbackToken++;
        if (token == 0) {
            token = g_nextRedrawCallbackToken++;
        }
        g_activeRedrawCallback = std::move(callback);
        g_activeRedrawCallbackToken = token;
        const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
        renderer = AcquireRendererLocked(handle, true);
        callbackSnapshot = g_activeRedrawCallback;
    }
    if (renderer) {
        renderer->SetSessionRedrawCallback(std::move(callbackSnapshot));
    }
    return token;
}

void RendererNapi::UnregisterActiveRedrawCallback(uint64_t token) {
    if (token == 0) {
        return;
    }
    std::shared_ptr<GLRenderer> renderer;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        if (token != g_activeRedrawCallbackToken) {
            return;
        }
        g_activeRedrawCallbackToken = 0;
        g_activeRedrawCallback = nullptr;
        const int64_t handle = g_activeRendererHandle.load(std::memory_order_acquire);
        renderer = AcquireRendererLocked(handle, true);
    }
    if (renderer) {
        renderer->SetSessionRedrawCallback(nullptr);
    }
}

void RendererNapi::RenderRetained(int64_t handle) {
    std::shared_ptr<GLRenderer> renderer;
    uint64_t generation = 0;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        renderer = AcquireRendererLocked(handle, true, &generation);
    }
    if (renderer && generation != 0 && generation == g_rendererGeneration.load(std::memory_order_acquire)) {
        renderer->RenderRetainedFrame(generation);
    }
}

void RendererNapi::RenderRetained(
    int64_t handle, const Render::DecoderSessionIdentity& owner) {
    auto sinkLease = Render::SharedSessionSinkOwnerLease().acquire(owner);
    if (!sinkLease) {
        return;
    }
    std::shared_ptr<GLRenderer> renderer;
    uint64_t generation = 0;
    {
        std::lock_guard<std::mutex> lock(g_activeRendererMutex);
        if (!IsActiveRendererOwnerAndHandleLocked(handle, owner)) {
            return;
        }
        renderer = AcquireRendererLocked(handle, true, &generation);
    }
    if (renderer && generation != 0 &&
        generation == g_rendererGeneration.load(std::memory_order_acquire)) {
        renderer->RenderRetainedFrame(generation);
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
