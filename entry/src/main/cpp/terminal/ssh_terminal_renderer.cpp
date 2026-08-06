#include "terminal/ssh_terminal_renderer.h"

#include <native_drawing/drawing_brush.h>
#include <native_drawing/drawing_canvas.h>
#include <native_drawing/drawing_font.h>
#include <native_drawing/drawing_gpu_context.h>
#include <native_drawing/drawing_rect.h>
#include <native_drawing/drawing_surface.h>
#include <native_drawing/drawing_types.h>
#include <native_drawing/drawing_typeface.h>
#include <native_drawing/drawing_pen.h>

#include <hilog/log.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <limits>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0004
#define LOG_TAG "SSH_TERM_RENDER"

namespace {
// API 23 can abort the process from OH_Drawing_SurfaceFlush after a stale
// XComponent BufferQueue error. Keep this backend opt-in until that path is
// replaced by a surface implementation with a non-aborting failure contract.
constexpr bool kNativeDrawingSurfaceEnabled = false;

constexpr uint32_t kDefaultBackground = 0xFF0D0D0D;
constexpr float kMinimumCellWidth = 2.0F;
constexpr float kMinimumCellHeight = 2.0F;

uint64_t ParseSurfaceId(const std::string& surfaceId) {
    if (surfaceId.empty()) {
        return 0;
    }
    char* end = nullptr;
    const unsigned long long value = std::strtoull(surfaceId.c_str(), &end, 10);
    return end != surfaceId.c_str() && end != nullptr && *end == '\0'
        ? static_cast<uint64_t>(value) : 0;
}

bool IsFinitePositive(float value) {
    return std::isfinite(value) && value > 0.0F;
}
}

SshTerminalRenderer::~SshTerminalRenderer() {
    Destroy();
}

int SshTerminalRenderer::Init(const std::string& surfaceId, int widthPx, int heightPx,
                              std::size_t cols, std::size_t rows, float cellWpx,
                              float cellHpx, float fontSizePx, uint32_t foreground,
                              uint32_t background, float viewportHeightPx,
                              float visibleHeightPx, bool bottomAlign) {
    if (!kNativeDrawingSurfaceEnabled) {
        return kBackendDisabled;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (terminal_ != nullptr) {
        return -1;
    }
    cols_ = std::max<std::size_t>(1, cols);
    rows_ = std::max<std::size_t>(1, rows);
    cellWpx_ = std::max(kMinimumCellWidth, cellWpx);
    cellHpx_ = std::max(kMinimumCellHeight, cellHpx);
    fontSizePx_ = IsFinitePositive(fontSizePx) ? fontSizePx : cellHpx_ * 0.78F;
    foreground_ = foreground;
    background_ = background == 0 ? kDefaultBackground : background;
    viewportHeightPx_ = std::max(0.0F, viewportHeightPx);
    visibleHeightPx_ = std::max(0.0F, visibleHeightPx);
    bottomAlign_ = bottomAlign;
    surfaceFlushFailed_ = false;

    terminal_ = terminal_core_create(cols_, rows_);
    if (terminal_ == nullptr) {
        return -2;
    }
    terminal_core_set_default_foreground(terminal_, foreground_);
    if (!InitGraphics(surfaceId, widthPx, heightPx)) {
        terminal_core_destroy(terminal_);
        terminal_ = nullptr;
        return -3;
    }
    ready_ = true;
    hasRenderedFrame_ = false;
    if (!RenderFull()) {
        const bool flushFailed = surfaceFlushFailed_;
        ready_ = false;
        DestroyGraphics();
        terminal_core_destroy(terminal_);
        terminal_ = nullptr;
        return flushFailed ? kSurfaceFlushFailure : -4;
    }
    OH_LOG_INFO(LOG_APP, "[SSH] Native Drawing renderer initialized %{public}zux%{public}zu",
                cols_, rows_);
    return 0;
}

int SshTerminalRenderer::RebindSurface(const std::string& surfaceId, int widthPx, int heightPx) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (terminal_ == nullptr) {
        return -1;
    }
    if (surfaceFlushFailed_) {
        return kSurfaceFlushFailure;
    }
    DestroyGraphics();
    if (!InitGraphics(surfaceId, widthPx, heightPx)) {
        ready_ = false;
        return -2;
    }
    ready_ = true;
    hasRenderedFrame_ = false;
    if (!RenderFull()) {
        const bool flushFailed = surfaceFlushFailed_;
        ready_ = false;
        DestroyGraphics();
        return flushFailed ? kSurfaceFlushFailure : -3;
    }
    return 0;
}

void SshTerminalRenderer::DetachSurface() {
    std::lock_guard<std::mutex> lock(mutex_);
    ready_ = false;
    hasRenderedFrame_ = false;
    // The terminal core deliberately survives this call. A hidden SSH tab
    // must continue parsing output while its XComponent surface is gone.
    DestroyGraphics();
}

void SshTerminalRenderer::Destroy() {
    std::lock_guard<std::mutex> lock(mutex_);
    ready_ = false;
    DestroyGraphics();
    if (terminal_ != nullptr) {
        terminal_core_destroy(terminal_);
        terminal_ = nullptr;
    }
}

bool SshTerminalRenderer::IsReady() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return ready_ && terminal_ != nullptr && canvas_ != nullptr;
}

bool SshTerminalRenderer::HasSurfaceFlushFailure() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return surfaceFlushFailed_;
}

void SshTerminalRenderer::WriteBytes(const uint8_t* data, std::size_t length) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (terminal_ == nullptr || data == nullptr || length == 0) {
        return;
    }
    terminal_core_write(terminal_, data, length);
    if (ready_) {
        RenderDirty();
    }
}

bool SshTerminalRenderer::Refresh() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (terminal_ != nullptr && ready_) {
        return RenderFull();
    }
    return false;
}

void SshTerminalRenderer::Resize(std::size_t cols, std::size_t rows, float cellWpx,
                                 float cellHpx, float fontSizePx) {
    std::lock_guard<std::mutex> lock(mutex_);
    const std::size_t nextCols = std::max<std::size_t>(1, cols);
    const std::size_t nextRows = std::max<std::size_t>(1, rows);
    const bool terminalDimensionsChanged = nextCols != cols_ || nextRows != rows_;
    cols_ = nextCols;
    rows_ = nextRows;
    cellWpx_ = std::max(kMinimumCellWidth, cellWpx);
    cellHpx_ = std::max(kMinimumCellHeight, cellHpx);
    fontSizePx_ = IsFinitePositive(fontSizePx) ? fontSizePx : cellHpx_ * 0.78F;
    // A font/line-spacing update changes only the native metrics and glyph
    // cache. Do not turn a visual preference change into a VT resize/reflow;
    // resize the terminal core only when the actual grid dimensions changed.
    if (terminal_ != nullptr && terminalDimensionsChanged) {
        terminal_core_resize(terminal_, cols_, rows_);
    }
    RecreateFonts();
    if (ready_) {
        RenderFull();
    }
}

void SshTerminalRenderer::SetAppearance(float fontSizePx, uint32_t foreground,
                                        uint32_t background) {
    std::lock_guard<std::mutex> lock(mutex_);
    fontSizePx_ = IsFinitePositive(fontSizePx) ? fontSizePx : fontSizePx_;
    foreground_ = foreground;
    if (background != 0) {
        background_ = background;
    }
    if (terminal_ != nullptr) {
        terminal_core_set_default_foreground(terminal_, foreground_);
    }
    RecreateFonts();
    if (ready_) {
        RenderFull();
    }
}

void SshTerminalRenderer::SetViewport(float viewportHeightPx, float visibleHeightPx,
                                      bool bottomAlign) {
    std::lock_guard<std::mutex> lock(mutex_);
    viewportHeightPx_ = std::max(0.0F, viewportHeightPx);
    visibleHeightPx_ = std::max(0.0F, visibleHeightPx);
    bottomAlign_ = bottomAlign;
    if (ready_) {
        RenderFull();
    }
}

void SshTerminalRenderer::ScrollView(int64_t deltaLines) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (terminal_ == nullptr) {
        return;
    }
    terminal_core_scroll_view(terminal_, deltaLines);
    if (ready_) {
        RenderFull();
    }
}

void SshTerminalRenderer::ScrollToBottom() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (terminal_ == nullptr) {
        return;
    }
    terminal_core_scroll_to_bottom(terminal_);
    if (ready_) {
        RenderFull();
    }
}

std::string SshTerminalRenderer::Content() const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (terminal_ == nullptr) {
        return {};
    }
    FfiTerminalSnapshot* snapshot = terminal_core_snapshot(terminal_);
    if (snapshot == nullptr) {
        return {};
    }
    std::string result;
    result.reserve(snapshot->cells_len);
    for (std::size_t row = 0; row < snapshot->rows; ++row) {
        std::size_t lineEnd = row * snapshot->cols;
        for (std::size_t col = 0; col < snapshot->cols; ++col) {
            const std::size_t index = row * snapshot->cols + col;
            if (index >= snapshot->cells_len) {
                break;
            }
            const uint32_t codePoint = snapshot->cells_ptr[index].ch;
            if (codePoint != 0 && codePoint != static_cast<uint32_t>(' ')) {
                lineEnd = index + 1;
            }
        }
        for (std::size_t index = row * snapshot->cols; index < lineEnd; ++index) {
            result += CodePointToUtf8(snapshot->cells_ptr[index].ch);
        }
        if (row + 1 < snapshot->rows) {
            result.push_back('\n');
        }
    }
    terminal_core_free_snapshot(snapshot);
    return result;
}

bool SshTerminalRenderer::InitGraphics(const std::string& surfaceId, int widthPx, int heightPx) {
    const uint64_t id = ParseSurfaceId(surfaceId);
    if (id == 0) {
        OH_LOG_WARN(LOG_APP, "[SSH] Native Drawing surface id is invalid");
        return false;
    }

    if (OH_NativeWindow_CreateNativeWindowFromSurfaceId(id, &nativeWindow_) != 0 ||
        nativeWindow_ == nullptr) {
        OH_LOG_WARN(LOG_APP, "[SSH] Native Drawing window creation failed");
        nativeWindow_ = nullptr;
        return false;
    }

    eglDisplay_ = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (eglDisplay_ == EGL_NO_DISPLAY) {
        DestroyGraphics();
        return false;
    }
    EGLint major = 0;
    EGLint minor = 0;
    if (!eglInitialize(eglDisplay_, &major, &minor)) {
        DestroyGraphics();
        return false;
    }
    const EGLint configAttributes[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 0, EGL_STENCIL_SIZE, 0, EGL_NONE
    };
    EGLint configCount = 0;
    if (!eglChooseConfig(eglDisplay_, configAttributes, &eglConfig_, 1, &configCount) ||
        configCount < 1) {
        DestroyGraphics();
        return false;
    }
    const EGLint contextAttributes[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    eglContext_ = eglCreateContext(eglDisplay_, eglConfig_, EGL_NO_CONTEXT, contextAttributes);
    if (eglContext_ == EGL_NO_CONTEXT) {
        DestroyGraphics();
        return false;
    }
    eglSurface_ = eglCreateWindowSurface(eglDisplay_, eglConfig_,
        reinterpret_cast<EGLNativeWindowType>(nativeWindow_), nullptr);
    if (eglSurface_ == EGL_NO_SURFACE ||
        !eglMakeCurrent(eglDisplay_, eglSurface_, eglSurface_, eglContext_)) {
        DestroyGraphics();
        return false;
    }

    OH_Drawing_GpuContextOptions options { false };
    gpuContext_ = OH_Drawing_GpuContextCreateFromGL(options);
    if (gpuContext_ == nullptr) {
        DestroyGraphics();
        return false;
    }
    OH_Drawing_Image_Info imageInfo {
        widthPx > 0 ? widthPx : 1,
        heightPx > 0 ? heightPx : 1,
        COLOR_FORMAT_RGBA_8888,
        ALPHA_FORMAT_PREMUL
    };
    drawingSurface_ = OH_Drawing_SurfaceCreateOnScreen(gpuContext_, imageInfo, nativeWindow_);
    if (drawingSurface_ == nullptr) {
        DestroyGraphics();
        return false;
    }
    canvas_ = OH_Drawing_SurfaceGetCanvas(drawingSurface_);
    brush_ = OH_Drawing_BrushCreate();
    pen_ = OH_Drawing_PenCreate();
    rect_ = OH_Drawing_RectCreate(0.0F, 0.0F, 1.0F, 1.0F);
    typeface_ = OH_Drawing_TypefaceCreateDefault();
    if (canvas_ == nullptr || brush_ == nullptr || pen_ == nullptr || rect_ == nullptr ||
        typeface_ == nullptr) {
        DestroyGraphics();
        return false;
    }
    OH_Drawing_BrushSetAntiAlias(brush_, true);
    OH_Drawing_PenSetAntiAlias(pen_, true);
    OH_Drawing_PenSetWidth(pen_, 1.0F);
    RecreateFonts();
    return fonts_[0] != nullptr;
}

void SshTerminalRenderer::DestroyGraphics() {
    if (eglDisplay_ != EGL_NO_DISPLAY && eglContext_ != EGL_NO_CONTEXT) {
        eglMakeCurrent(eglDisplay_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    }
    for (OH_Drawing_Font*& font : fonts_) {
        if (font != nullptr) {
            OH_Drawing_FontDestroy(font);
            font = nullptr;
        }
    }
    if (typeface_ != nullptr) {
        OH_Drawing_TypefaceDestroy(typeface_);
        typeface_ = nullptr;
    }
    if (rect_ != nullptr) {
        OH_Drawing_RectDestroy(rect_);
        rect_ = nullptr;
    }
    if (pen_ != nullptr) {
        OH_Drawing_PenDestroy(pen_);
        pen_ = nullptr;
    }
    if (brush_ != nullptr) {
        OH_Drawing_BrushDestroy(brush_);
        brush_ = nullptr;
    }
    canvas_ = nullptr;
    if (drawingSurface_ != nullptr) {
        OH_Drawing_SurfaceDestroy(drawingSurface_);
        drawingSurface_ = nullptr;
    }
    if (gpuContext_ != nullptr) {
        OH_Drawing_GpuContextDestroy(gpuContext_);
        gpuContext_ = nullptr;
    }
    if (eglDisplay_ != EGL_NO_DISPLAY) {
        if (eglSurface_ != EGL_NO_SURFACE) {
            eglDestroySurface(eglDisplay_, eglSurface_);
            eglSurface_ = EGL_NO_SURFACE;
        }
        if (eglContext_ != EGL_NO_CONTEXT) {
            eglDestroyContext(eglDisplay_, eglContext_);
            eglContext_ = EGL_NO_CONTEXT;
        }
        eglTerminate(eglDisplay_);
        eglDisplay_ = EGL_NO_DISPLAY;
    }
    eglConfig_ = nullptr;
    if (nativeWindow_ != nullptr) {
        OH_NativeWindow_DestroyNativeWindow(nativeWindow_);
        nativeWindow_ = nullptr;
    }
}

bool SshTerminalRenderer::EnsureGraphicsCurrent() {
    if (!ready_ || terminal_ == nullptr || canvas_ == nullptr || drawingSurface_ == nullptr ||
        eglDisplay_ == EGL_NO_DISPLAY || eglContext_ == EGL_NO_CONTEXT ||
        eglSurface_ == EGL_NO_SURFACE) {
        return false;
    }
    const EGLContext currentContext = eglGetCurrentContext();
    const EGLSurface currentSurface = eglGetCurrentSurface(EGL_DRAW);
    if (currentContext == eglContext_ && currentSurface == eglSurface_) {
        return true;
    }
    // NAPI callbacks and ArkUI drawing can run on different turns while the
    // native renderer retains the same XComponent surface. EGL current state
    // is thread-local, so a valid surface can otherwise look detached and
    // every later frame is silently skipped.
    if (!eglMakeCurrent(eglDisplay_, eglSurface_, eglSurface_, eglContext_)) {
        OH_LOG_WARN(LOG_APP, "[SSH] failed to restore EGL current surface");
        return false;
    }
    return eglGetCurrentContext() == eglContext_ &&
        eglGetCurrentSurface(EGL_DRAW) == eglSurface_;
}

bool SshTerminalRenderer::CanDraw() {
    if (surfaceFlushFailed_) {
        return false;
    }
    // OH_Drawing_SurfaceFlush can abort when an XComponent surface has already
    // lost its EGL binding. Restore the binding when the surface is still
    // valid; only treat it as detached when that recovery fails.
    return EnsureGraphicsCurrent();
}

bool SshTerminalRenderer::RenderFull() {
    if (!CanDraw()) {
        return false;
    }
    FfiTerminalSnapshot* snapshot = terminal_core_snapshot(terminal_);
    if (snapshot == nullptr) {
        return false;
    }
    mode_.bracketedPaste = snapshot->bracketed_paste;
    mode_.mouseTracking = snapshot->mouse_tracking;
    mode_.sgrMouse = snapshot->sgr_mouse;
    mode_.applicationCursorKeys = snapshot->application_cursor_keys;
    mode_.applicationKeypad = snapshot->application_keypad;
    mode_.autoWrap = snapshot->auto_wrap;
    const bool rendered = DrawSnapshot(snapshot, true);
    terminal_core_free_snapshot(snapshot);
    return rendered;
}

bool SshTerminalRenderer::RenderDirty() {
    bool rendered = false;
    FfiTerminalSnapshot* snapshot = nullptr;
    if (CanDraw()) {
        snapshot = terminal_core_dirty_snapshot(terminal_);
        if (snapshot != nullptr) {
            mode_.bracketedPaste = snapshot->bracketed_paste;
            mode_.mouseTracking = snapshot->mouse_tracking;
            mode_.sgrMouse = snapshot->sgr_mouse;
            mode_.applicationCursorKeys = snapshot->application_cursor_keys;
            mode_.applicationKeypad = snapshot->application_keypad;
            mode_.autoWrap = snapshot->auto_wrap;
            rendered = DrawSnapshot(snapshot, false);
            terminal_core_free_snapshot(snapshot);
        }
    }
    if (rendered) {
        return true;
    }
    // dirty_snapshot() consumes the dirty rows. If drawing or the EGL state
    // failed after that point, redraw the retained full snapshot immediately
    // so the next SSH chunk cannot leave the surface permanently stale.
    OH_LOG_WARN(LOG_APP, "[SSH] dirty terminal frame failed; retrying full frame");
    return RenderFull();
}

SshTerminalRenderer::Mode SshTerminalRenderer::CurrentMode() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return mode_;
}

bool SshTerminalRenderer::DrawSnapshot(const FfiTerminalSnapshot* snapshot, bool fullFrame) {
    if (snapshot == nullptr || !CanDraw() || brush_ == nullptr || rect_ == nullptr ||
        fonts_[0] == nullptr || snapshot->rows == 0 || snapshot->cols == 0) {
        return false;
    }
    const float top = GridTop(snapshot);
    const bool gridMoved = !hasRenderedFrame_ || std::fabs(top - lastGridTop_) > 0.5F;
    const bool repaintFull = fullFrame || gridMoved || snapshot->cols != cols_ || snapshot->rows != rows_;

    const int currentCursorRow = snapshot->cursor_visible &&
        snapshot->cursor_x < snapshot->cols && snapshot->cursor_y < snapshot->rows
        ? static_cast<int>(snapshot->screen_top + snapshot->cursor_y) -
            static_cast<int>(snapshot->view_top)
        : -1;
    const int currentCursorColumn = snapshot->cursor_visible &&
        snapshot->cursor_x < snapshot->cols ? static_cast<int>(snapshot->cursor_x) : -1;
    const bool cursorChanged = currentCursorRow != lastCursorRow_ ||
        currentCursorColumn != lastCursorColumn_ ||
        snapshot->cursor_visible != lastCursorVisible_;

    std::vector<std::size_t> rowsToDraw;
    rowsToDraw.reserve(repaintFull ? snapshot->rows : snapshot->dirty_rows_len + 2);
    const auto appendRow = [&rowsToDraw, snapshot](int row) {
        if (row < 0 || static_cast<std::size_t>(row) >= snapshot->rows) {
            return;
        }
        const std::size_t normalized = static_cast<std::size_t>(row);
        if (std::find(rowsToDraw.begin(), rowsToDraw.end(), normalized) == rowsToDraw.end()) {
            rowsToDraw.push_back(normalized);
        }
    };
    if (repaintFull) {
        for (std::size_t row = 0; row < snapshot->rows; ++row) {
            rowsToDraw.push_back(row);
        }
        OH_Drawing_CanvasClear(canvas_, background_);
    } else {
        for (std::size_t index = 0; index < snapshot->dirty_rows_len; ++index) {
            if (snapshot->dirty_rows_ptr != nullptr) {
                appendRow(static_cast<int>(snapshot->dirty_rows_ptr[index]));
            }
        }
        if (cursorChanged) {
            appendRow(lastCursorRow_);
            appendRow(currentCursorRow);
        }
        if (rowsToDraw.empty()) {
            lastGridTop_ = top;
            return true;
        }
    }

    OH_Drawing_Font_Metrics metrics {};
    OH_Drawing_FontGetMetrics(fonts_[0], &metrics);
    const float baselineOffset = (cellHpx_ - (metrics.descent - metrics.ascent)) * 0.5F - metrics.ascent;
    for (const std::size_t row : rowsToDraw) {
        const float y = top + static_cast<float>(row) * cellHpx_;
        if (!repaintFull) {
            SetBrushColor(background_);
            OH_Drawing_RectSetLeft(rect_, 0.0F);
            OH_Drawing_RectSetTop(rect_, y);
            OH_Drawing_RectSetRight(rect_, static_cast<float>(snapshot->cols) * cellWpx_);
            OH_Drawing_RectSetBottom(rect_, y + cellHpx_);
            OH_Drawing_CanvasDrawRect(canvas_, rect_);
        }
        for (std::size_t col = 0; col < snapshot->cols; ++col) {
            const std::size_t index = row * snapshot->cols + col;
            if (index >= snapshot->cells_len) {
                continue;
            }
            const FfiSnapshotCell& cell = snapshot->cells_ptr[index];
            if (cell.wide_continuation) {
                continue;
            }
            uint32_t foreground = cell.fg;
            uint32_t background = cell.bg;
            if (cell.inverse) {
                std::swap(foreground, background);
            }
            const float width = cell.wide ? cellWpx_ * 2.0F : cellWpx_;
            const float x = static_cast<float>(col) * cellWpx_;
            if (background != 0) {
                SetBrushColor(background);
                OH_Drawing_RectSetLeft(rect_, x);
                OH_Drawing_RectSetTop(rect_, y);
                OH_Drawing_RectSetRight(rect_, x + width);
                OH_Drawing_RectSetBottom(rect_, y + cellHpx_);
                OH_Drawing_CanvasDrawRect(canvas_, rect_);
            }
            if (cell.ch == 0 || cell.ch == static_cast<uint32_t>(' ')) {
                continue;
            }
            OH_Drawing_Font* font = FontForCell(cell.bold, cell.italic);
            if (font == nullptr) {
                continue;
            }
            SetBrushColor(foreground == 0 ? foreground_ : foreground);
            OH_Drawing_CanvasAttachBrush(canvas_, brush_);
            const std::string text = CodePointToUtf8(cell.ch);
            OH_Drawing_CanvasDrawSingleCharacter(canvas_, text.c_str(), font, x, y + baselineOffset);
            if (cell.underline) {
                OH_Drawing_PenSetColor(pen_, foreground == 0 ? foreground_ : foreground);
                OH_Drawing_PenSetWidth(pen_, std::max(1.0F, cellHpx_ * 0.06F));
                OH_Drawing_CanvasAttachPen(canvas_, pen_);
                OH_Drawing_CanvasDrawLine(canvas_, x, y + cellHpx_ - 2.0F,
                                          x + width, y + cellHpx_ - 2.0F);
            }
        }
    }
    if (currentCursorRow >= 0 && currentCursorRow < static_cast<int>(snapshot->rows)) {
        const float cursorY = static_cast<float>(currentCursorRow);
        if (snapshot->cursor_visible) {
            SetBrushColor(foreground_);
            const float cursorX = static_cast<float>(snapshot->cursor_x) * cellWpx_;
            OH_Drawing_RectSetLeft(rect_, cursorX + 1.0F);
            OH_Drawing_RectSetTop(rect_, top + cursorY * cellHpx_ + cellHpx_ -
                                  std::max(2.0F, cellHpx_ * 0.18F) - 1.0F);
            OH_Drawing_RectSetRight(rect_, cursorX + std::max(4.0F, cellWpx_ - 2.0F));
            OH_Drawing_RectSetBottom(rect_, top + cursorY * cellHpx_ + cellHpx_ - 1.0F);
            OH_Drawing_CanvasDrawRect(canvas_, rect_);
        }
    }
    if (drawingSurface_ == nullptr || !EnsureGraphicsCurrent()) {
        return false;
    }
    const OH_Drawing_ErrorCode flushStatus = OH_Drawing_SurfaceFlush(drawingSurface_);
    if (flushStatus != OH_DRAWING_SUCCESS) {
        // Do not retry or call scroll/repaint after this point. On the target
        // device the first BufferQueue failure is followed by a DDGR device
        // lost panic if the same surface is flushed again. ArkTS observes this
        // latched state through the NAPI bridge and preserves the VT core in
        // the xterm fallback instead.
        surfaceFlushFailed_ = true;
        ready_ = false;
        OH_LOG_WARN(LOG_APP, "[SSH] terminal surface flush failed: %{public}d",
                    static_cast<int>(flushStatus));
        return false;
    }
    lastGridTop_ = top;
    lastCursorRow_ = currentCursorRow;
    lastCursorColumn_ = currentCursorColumn;
    lastCursorVisible_ = snapshot->cursor_visible;
    hasRenderedFrame_ = true;
    return true;
}

float SshTerminalRenderer::GridTop(const FfiTerminalSnapshot* snapshot) const {
    if (!bottomAlign_ || snapshot == nullptr || visibleHeightPx_ <= 0.0F) {
        return 0.0F;
    }
    int bottomRow = static_cast<int>(snapshot->cursor_y);
    for (int row = static_cast<int>(snapshot->rows) - 1; row >= 0; --row) {
        bool nonEmpty = false;
        for (std::size_t col = 0; col < snapshot->cols; ++col) {
            const std::size_t index = static_cast<std::size_t>(row) * snapshot->cols + col;
            if (index < snapshot->cells_len && snapshot->cells_ptr[index].ch != 0 &&
                snapshot->cells_ptr[index].ch != static_cast<uint32_t>(' ')) {
                nonEmpty = true;
                break;
            }
        }
        if (nonEmpty) {
            bottomRow = std::max(bottomRow, row);
            break;
        }
    }
    const float contentHeight = static_cast<float>(bottomRow + 1) * cellHpx_;
    const float topInset = std::max(0.0F, viewportHeightPx_ - visibleHeightPx_);
    const bool browsingHistory = snapshot->view_top < snapshot->screen_top;
    const float sparseLimit = std::min(visibleHeightPx_ * 0.35F, cellHpx_ * 8.0F);
    if (browsingHistory || contentHeight >= visibleHeightPx_ - sparseLimit) {
        return topInset;
    }
    return topInset + std::max(0.0F, visibleHeightPx_ - contentHeight);
}

OH_Drawing_Font* SshTerminalRenderer::FontForCell(bool bold, bool italic) const {
    const int index = (bold ? 1 : 0) | (italic ? 2 : 0);
    return fonts_[index];
}

void SshTerminalRenderer::RecreateFonts() {
    for (OH_Drawing_Font*& font : fonts_) {
        if (font != nullptr) {
            OH_Drawing_FontDestroy(font);
            font = nullptr;
        }
    }
    if (typeface_ == nullptr) {
        return;
    }
    for (int index = 0; index < 4; ++index) {
        OH_Drawing_Font* font = OH_Drawing_FontCreate();
        if (font == nullptr) {
            continue;
        }
        OH_Drawing_FontSetTypeface(font, typeface_);
        OH_Drawing_FontSetTextSize(font, fontSizePx_);
        OH_Drawing_FontSetSubpixel(font, false);
        OH_Drawing_FontSetBaselineSnap(font, true);
        OH_Drawing_FontSetFakeBoldText(font, (index & 1) != 0);
        OH_Drawing_FontSetTextSkewX(font, (index & 2) != 0 ? -0.18F : 0.0F);
        fonts_[index] = font;
    }
}

void SshTerminalRenderer::SetBrushColor(uint32_t color) {
    if (brush_ != nullptr) {
        OH_Drawing_BrushSetColor(brush_, color);
        OH_Drawing_CanvasAttachBrush(canvas_, brush_);
    }
}

std::string SshTerminalRenderer::CodePointToUtf8(uint32_t codePoint) {
    if (codePoint > 0x10FFFF || (codePoint >= 0xD800 && codePoint <= 0xDFFF)) {
        codePoint = 0xFFFD;
    }
    std::string result;
    if (codePoint <= 0x7F) {
        result.push_back(static_cast<char>(codePoint));
    } else if (codePoint <= 0x7FF) {
        result.push_back(static_cast<char>(0xC0 | (codePoint >> 6)));
        result.push_back(static_cast<char>(0x80 | (codePoint & 0x3F)));
    } else if (codePoint <= 0xFFFF) {
        result.push_back(static_cast<char>(0xE0 | (codePoint >> 12)));
        result.push_back(static_cast<char>(0x80 | ((codePoint >> 6) & 0x3F)));
        result.push_back(static_cast<char>(0x80 | (codePoint & 0x3F)));
    } else {
        result.push_back(static_cast<char>(0xF0 | (codePoint >> 18)));
        result.push_back(static_cast<char>(0x80 | ((codePoint >> 12) & 0x3F)));
        result.push_back(static_cast<char>(0x80 | ((codePoint >> 6) & 0x3F)));
        result.push_back(static_cast<char>(0x80 | (codePoint & 0x3F)));
    }
    return result;
}
