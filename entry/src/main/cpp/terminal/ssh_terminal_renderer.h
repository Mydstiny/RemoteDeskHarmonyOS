/**
 * Native SSH terminal renderer.
 *
 * The VT state remains in terminal_core (Alacritty by default). This class
 * owns only the XComponent/EGL/Native Drawing surface and paints snapshots
 * without converting every cell into ArkUI Canvas objects.
 */
#ifndef SSH_TERMINAL_RENDERER_H
#define SSH_TERMINAL_RENDERER_H

#include "terminal/terminal_core_napi.h"

#include <EGL/egl.h>
#include <native_window/external_window.h>

#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

struct OH_Drawing_Brush;
struct OH_Drawing_Canvas;
struct OH_Drawing_Font;
struct OH_Drawing_GpuContext;
struct OH_Drawing_Pen;
struct OH_Drawing_Rect;
struct OH_Drawing_Surface;
struct OH_Drawing_Typeface;

class SshTerminalRenderer {
public:
    SshTerminalRenderer() = default;
    ~SshTerminalRenderer();

    SshTerminalRenderer(const SshTerminalRenderer&) = delete;
    SshTerminalRenderer& operator=(const SshTerminalRenderer&) = delete;

    int Init(const std::string& surfaceId, int widthPx, int heightPx,
             std::size_t cols, std::size_t rows, float cellWpx, float cellHpx,
             float fontSizePx, uint32_t foreground, uint32_t background,
             float viewportHeightPx, float visibleHeightPx, bool bottomAlign);
    int RebindSurface(const std::string& surfaceId, int widthPx, int heightPx);
    /** Release only the native surface; keep the VT core and its scrollback. */
    void DetachSurface();
    void Destroy();

    bool IsReady() const;
    void WriteBytes(const uint8_t* data, std::size_t length);
    /** Repaint the retained VT snapshot after a surface or EGL context rebind. */
    bool Refresh();
    void Resize(std::size_t cols, std::size_t rows, float cellWpx, float cellHpx,
                float fontSizePx);
    void SetAppearance(float fontSizePx, uint32_t foreground, uint32_t background);
    void SetViewport(float viewportHeightPx, float visibleHeightPx, bool bottomAlign);
    void ScrollView(int64_t deltaLines);
    void ScrollToBottom();
    std::string Content() const;

    struct Mode {
        bool bracketedPaste = false;
        uint16_t mouseTracking = 0;
        bool sgrMouse = false;
        bool applicationCursorKeys = false;
        bool applicationKeypad = false;
        bool autoWrap = true;
    };
    Mode CurrentMode() const;

private:
    bool InitGraphics(const std::string& surfaceId, int widthPx, int heightPx);
    void DestroyGraphics();
    bool EnsureGraphicsCurrent();
    bool CanDraw();
    bool RenderFull();
    void RenderDirty();
    bool DrawSnapshot(const FfiTerminalSnapshot* snapshot, bool fullFrame);
    float GridTop(const FfiTerminalSnapshot* snapshot) const;
    OH_Drawing_Font* FontForCell(bool bold, bool italic) const;
    void RecreateFonts();
    void SetBrushColor(uint32_t color);
    static std::string CodePointToUtf8(uint32_t codePoint);

    mutable std::mutex mutex_;
    void* terminal_ = nullptr;
    bool ready_ = false;

    EGLDisplay eglDisplay_ = EGL_NO_DISPLAY;
    EGLContext eglContext_ = EGL_NO_CONTEXT;
    EGLSurface eglSurface_ = EGL_NO_SURFACE;
    EGLConfig eglConfig_ = nullptr;
    OHNativeWindow* nativeWindow_ = nullptr;

    OH_Drawing_GpuContext* gpuContext_ = nullptr;
    OH_Drawing_Surface* drawingSurface_ = nullptr;
    OH_Drawing_Canvas* canvas_ = nullptr;
    OH_Drawing_Typeface* typeface_ = nullptr;
    OH_Drawing_Font* fonts_[4] = {nullptr, nullptr, nullptr, nullptr};
    OH_Drawing_Brush* brush_ = nullptr;
    OH_Drawing_Pen* pen_ = nullptr;
    OH_Drawing_Rect* rect_ = nullptr;

    std::size_t cols_ = 80;
    std::size_t rows_ = 24;
    float cellWpx_ = 9.0F;
    float cellHpx_ = 20.0F;
    float fontSizePx_ = 18.0F;
    float viewportHeightPx_ = 0.0F;
    float visibleHeightPx_ = 0.0F;
    bool bottomAlign_ = false;
    uint32_t foreground_ = 0xFFE8EAED;
    uint32_t background_ = 0xFF0D0D0D;
    Mode mode_;
    bool hasRenderedFrame_ = false;
    float lastGridTop_ = 0.0F;
    int lastCursorRow_ = -1;
    int lastCursorColumn_ = -1;
    bool lastCursorVisible_ = false;
};

namespace SshTerminalRendererNapi {
napi_value Init(napi_env env, napi_value exports);
}

#endif // SSH_TERMINAL_RENDERER_H
