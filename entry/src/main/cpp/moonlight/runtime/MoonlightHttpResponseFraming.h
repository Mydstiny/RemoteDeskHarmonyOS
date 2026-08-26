#ifndef REMOTEDESK_MOONLIGHT_HTTP_RESPONSE_FRAMING_H
#define REMOTEDESK_MOONLIGHT_HTTP_RESPONSE_FRAMING_H

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>

namespace remotedesk::moonlight {

enum class MoonlightHttpFramingState : std::uint8_t {
    NeedMore,
    Complete,
    ProtocolError,
    BodyTooLarge,
};

struct MoonlightHttpFramingResult final {
    MoonlightHttpFramingState state = MoonlightHttpFramingState::NeedMore;
    bool headersComplete = false;
    int httpStatus = 0;
    std::size_t consumedBytes = 0U;
    std::string body;

    bool complete() const noexcept {
        return state == MoonlightHttpFramingState::Complete;
    }
};

// Parses exactly one HTTP/1.x response. Content-Length, connection-close, and
// strict final-chunked framing are supported. Ambiguous framing is rejected.
MoonlightHttpFramingResult inspectMoonlightHttpResponse(
    std::string_view wire, bool endOfStream, std::size_t maxHeaderBytes,
    std::size_t maxBodyBytes) noexcept;

} // namespace remotedesk::moonlight

#endif // REMOTEDESK_MOONLIGHT_HTTP_RESPONSE_FRAMING_H
