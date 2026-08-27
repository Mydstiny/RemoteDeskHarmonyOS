/**
 * vnc_rfb_protocol.h - pure byte-level contracts shared by the VNC runtime
 * and the host-side native tests.
 */
#ifndef VNC_RFB_PROTOCOL_H
#define VNC_RFB_PROTOCOL_H

#include "vnc_pixel_format.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace VncRfbProtocol {

constexpr size_t kProtocolVersionBytes = 12;
constexpr size_t kUltraVncRepeaterFieldBytes = 250;
constexpr int kDesktopSizeEncoding = -223;
constexpr int kLastRectEncoding = -224;
constexpr int kRawEncoding = 0;
constexpr int kCopyRectEncoding = 1;
constexpr int kZrleEncoding = 16;
constexpr size_t kMaxTextInputCodepoints = 4096;
// UI-normalized VNC wheel input can emit up to 80 clicks after the device-
// accepted 10x gain. Keep a bounded margin for direct native callers without
// truncating the supported ArkTS path.
constexpr int kMaxWheelBurstSteps = 128;

/** Accept only the RFB 3.x banner versions supported by the engine. */
bool protocolBannerIsSupported(const uint8_t* data, size_t size);
/** The RFB ClientInit shared flag. A viewer always sends one byte. */
uint8_t clientInitSharedFlag();

/**
 * Normalize an advertised RFB 3.x minor version to a published wire
 * dialect. RFC 6143 defines 3.3, 3.7 and 3.8; other 3.x values are handled
 * as 3.3 rather than being silently upgraded to a newer dialect.
 */
int normalizeRfbMinor(int advertisedMinor);

/**
 * Legacy RFB 3.3 peers include macOS Screen Sharing, which can defer its
 * first Cursor pseudo-rectangle. Keep a local pointer during that bootstrap;
 * modern peers without a Cursor rectangle are treated as framebuffer-cursor
 * servers (for example UltraVNC with cursor-shape updates disabled).
 */
bool keepsLocalCursorDuringBootstrap(int negotiatedMinor);

/**
 * Whether the negotiated security type is followed by SecurityResult.
 * RFB 3.3/3.7 None proceed directly to ClientInit; RFB 3.8 None and VNC
 * Authentication use SecurityResult.
 */
bool securityResultExpected(int negotiatedMinor, uint8_t selectedSecurityType);

/**
 * Build an RFB FramebufferUpdateRequest. The wire message is exactly
 * message-type, incremental, x, y, width and height (10 bytes total); unlike
 * SetPixelFormat and SetEncodings it has no padding byte.
 */
std::vector<uint8_t> buildFramebufferUpdateRequest(bool incremental,
                                                   uint16_t width,
                                                   uint16_t height);

/**
 * Build a bounded RFB PointerEvent wheel burst. Each logical step is one
 * button-4/5 down/up pair, preserving held primary buttons and clamping the
 * coordinates to the negotiated framebuffer.
 */
std::vector<uint8_t> buildPointerWheelBurst(int buttonMask, int x, int y,
                                            int delta, int framebufferWidth,
                                            int framebufferHeight);

/**
 * Resolve the requested true-colour depth. Explicit 8/16/32-bit choices win;
 * auto uses 8-bit for the speed preset or Retina-sized desktops and 32-bit
 * otherwise. RFB 3.3 is conservatively clamped to 16-bit because macOS Screen
 * Sharing closes the connection immediately after an RGB332 request. The
 * quality preset keeps 32-bit unless depth is explicit.
 */
int effectiveTrueColorDepth(const std::string& requestedDepth,
                            const std::string& qualityPreset,
                            uint64_t desktopPixels,
                            int negotiatedMinor = 8);

/** Build the exact 20-byte SetPixelFormat packet for 8/16/32-bit true colour. */
std::vector<uint8_t> buildSetPixelFormat(int colorDepth);

/**
 * Build the SetEncodings packet. ZRLE is preferred for auto/zrle and omitted
 * for an explicit raw request; Raw remains the mandatory fallback. Cursor,
 * DesktopSize and LastRect are always advertised.
 */
std::vector<uint8_t> buildSetEncodings(const std::string& preferredEncoding);

/**
 * Whether soft-keyboard text may be sent for the current session. Clipboard
 * policy is intentionally not an input gate: text uses RFB KeyEvent while
 * clipboard synchronization uses ClientCutText.
 */
bool canSendTextInput(bool viewOnly, bool clipboardEnabled, bool connected);

/**
 * Strictly decode UTF-8 and build one RFB KeyEvent down/up pair per Unicode
 * code point. Latin-1 uses its legacy X11 keysym; other printable Unicode
 * values use the X11 0x01000000 Unicode keysym namespace.
 */
bool buildTextKeyEvents(const std::string& text, std::vector<uint8_t>& packet,
                        std::string& error);

/** Normalize the only supported VNC frame-rate limits. Zero means unbounded. */
int normalizeFrameRateLimit(int frameRateLimit);

/** Minimum interval between framebuffer update requests for the rate limit. */
uint64_t framebufferRequestIntervalMs(int frameRateLimit);

/** UltraVNC mode12 sends this exact repeater banner to a viewer. */
bool isUltraVncRepeaterBanner(const uint8_t* data, size_t size);

/**
 * Build the fixed-width display/proxy field consumed by the official
 * UltraVNC repeater listeners. The field is "ID:<target>" followed by NUL
 * padding and is exactly 250 bytes; it does not contain a newline.
 */
bool buildRepeaterTargetField(const std::string& target,
                              std::array<uint8_t, kUltraVncRepeaterFieldBytes>& field,
                              std::string& error);

/** Parse the same fixed-width field and return the target without the ID:. */
bool parseRepeaterTargetField(const uint8_t* data, size_t size, std::string& target,
                              std::string& error);

/** Number of bytes in a ZRLE CPIXEL for the negotiated true-colour format. */
size_t compactPixelBytes(const PixelFormat& format);

/** Maximum valid decompressed byte count for one bounded ZRLE rectangle. */
bool maxZrleDecodedBytes(int width, int height, const PixelFormat& format,
                         size_t& maxBytes);

/**
 * Decode the uncompressed tile stream for one ZRLE rectangle into tightly
 * packed RGBA bytes. The output contains exactly width*height*4 bytes.
 */
bool decodeZrleTiles(const PixelFormat& format, int width, int height,
                     const uint8_t* data, size_t size,
                     std::vector<uint8_t>& rgba, std::string& error);

/**
 * Decode one uncompressed ZRLE rectangle directly into a BGRA framebuffer.
 * destinationStride may be wider than the rectangle, allowing the decoder to
 * write a dirty rectangle in-place without allocating an intermediate frame.
 * On failure the destination may contain partial pixels but no bytes outside
 * the validated rectangle are written; callers must not present the frame.
 */
bool decodeZrleTilesToBgra(const PixelFormat& format, int width, int height,
                           const uint8_t* data, size_t size,
                           uint8_t* destination, size_t destinationSize,
                           size_t destinationStride, std::string& error);

/**
 * Connection-scoped RFC 6143 ZRLE inflater. One instance must be retained for
 * the entire RFB connection because successive rectangles share one zlib
 * stream.
 */
class ZrleInflater {
public:
    ZrleInflater();
    ~ZrleInflater();
    ZrleInflater(const ZrleInflater&) = delete;
    ZrleInflater& operator=(const ZrleInflater&) = delete;

    bool inflateChunk(const uint8_t* compressed, size_t compressedSize,
                      size_t maxOutputBytes, std::vector<uint8_t>& output,
                      std::string& error);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace VncRfbProtocol

#endif // VNC_RFB_PROTOCOL_H
