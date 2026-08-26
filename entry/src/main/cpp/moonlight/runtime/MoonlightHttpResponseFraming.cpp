#include "moonlight/runtime/MoonlightHttpResponseFraming.h"

#include <algorithm>
#include <limits>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace remotedesk::moonlight {
namespace {

constexpr std::size_t kMaximumChunkLineBytes = 1024U;

enum class BodyMode : std::uint8_t {
    None,
    ContentLength,
    Chunked,
    UntilClose,
};

struct HeaderProjection final {
    MoonlightHttpFramingState state = MoonlightHttpFramingState::NeedMore;
    bool complete = false;
    int status = 0;
    std::size_t bodyOffset = 0U;
    BodyMode mode = BodyMode::UntilClose;
    std::size_t contentLength = 0U;
};

struct ChunkProjection final {
    MoonlightHttpFramingState state = MoonlightHttpFramingState::NeedMore;
    std::size_t consumedBytes = 0U;
    std::size_t decodedBytes = 0U;
};

MoonlightHttpFramingResult resultFor(
    MoonlightHttpFramingState state, bool headersComplete = false,
    int status = 0) {
    MoonlightHttpFramingResult result;
    result.state = state;
    result.headersComplete = headersComplete;
    result.httpStatus = status;
    return result;
}

bool isOws(char value) noexcept {
    return value == ' ' || value == '\t';
}

std::string_view trimOws(std::string_view value) noexcept {
    while (!value.empty() && isOws(value.front())) {
        value.remove_prefix(1U);
    }
    while (!value.empty() && isOws(value.back())) {
        value.remove_suffix(1U);
    }
    return value;
}

bool validHeaderName(std::string_view value) noexcept {
    if (value.empty()) { return false; }
    return std::all_of(value.begin(), value.end(), [](unsigned char character) {
        if ((character >= '0' && character <= '9') ||
            (character >= 'A' && character <= 'Z') ||
            (character >= 'a' && character <= 'z')) {
            return true;
        }
        switch (character) {
            case '!': case '#': case '$': case '%': case '&': case '\'':
            case '*': case '+': case '-': case '.': case '^': case '_':
            case '`': case '|': case '~':
                return true;
            default:
                return false;
        }
    });
}

bool validHeaderValue(std::string_view value) noexcept {
    return std::all_of(value.begin(), value.end(), [](unsigned char character) {
        return character == '\t' || (character >= 0x20U && character != 0x7fU);
    });
}

std::string lowerAscii(std::string_view value) {
    std::string result(value);
    std::transform(result.begin(), result.end(), result.begin(),
        [](unsigned char character) {
            return static_cast<char>(character >= 'A' && character <= 'Z'
                ? character - 'A' + 'a' : character);
        });
    return result;
}

bool parseDecimal(std::string_view value, std::size_t& output) noexcept {
    value = trimOws(value);
    if (value.empty()) { return false; }
    std::size_t parsed = 0U;
    for (const unsigned char character : value) {
        if (character < '0' || character > '9') { return false; }
        const std::size_t digit = static_cast<std::size_t>(character - '0');
        if (parsed > (std::numeric_limits<std::size_t>::max() - digit) / 10U) {
            return false;
        }
        parsed = parsed * 10U + digit;
    }
    output = parsed;
    return true;
}

bool mergeContentLength(std::string_view value,
                        std::optional<std::size_t>& contentLength) noexcept {
    std::size_t cursor = 0U;
    bool sawValue = false;
    while (cursor <= value.size()) {
        const std::size_t comma = value.find(',', cursor);
        const std::size_t end = comma == std::string_view::npos ? value.size() : comma;
        std::size_t parsed = 0U;
        if (!parseDecimal(value.substr(cursor, end - cursor), parsed) ||
            (contentLength.has_value() && *contentLength != parsed)) {
            return false;
        }
        contentLength = parsed;
        sawValue = true;
        if (comma == std::string_view::npos) { break; }
        cursor = comma + 1U;
    }
    return sawValue;
}

bool appendTransferCodings(std::string_view value,
                           std::vector<std::string>& codings) {
    std::size_t cursor = 0U;
    while (cursor <= value.size()) {
        const std::size_t comma = value.find(',', cursor);
        const std::size_t end = comma == std::string_view::npos ? value.size() : comma;
        const std::string_view token = trimOws(value.substr(cursor, end - cursor));
        if (token.empty()) { return false; }
        codings.push_back(lowerAscii(token));
        if (comma == std::string_view::npos) { break; }
        cursor = comma + 1U;
    }
    return true;
}

bool parseStatusLine(std::string_view line, int& status) noexcept {
    if (line.size() < 12U ||
        (line.substr(0U, 8U) != "HTTP/1.0" && line.substr(0U, 8U) != "HTTP/1.1") ||
        line[8U] != ' ' || line[9U] < '0' || line[9U] > '9' ||
        line[10U] < '0' || line[10U] > '9' ||
        line[11U] < '0' || line[11U] > '9' ||
        (line.size() > 12U && line[12U] != ' ')) {
        return false;
    }
    if (!validHeaderValue(line)) { return false; }
    status = (line[9U] - '0') * 100 + (line[10U] - '0') * 10 +
        (line[11U] - '0');
    return status >= 100 && status <= 599;
}

HeaderProjection parseHeaders(std::string_view wire, bool endOfStream,
                              std::size_t maxHeaderBytes,
                              std::size_t maxBodyBytes) {
    HeaderProjection result;
    const std::size_t marker = wire.find("\r\n\r\n");
    if (marker == std::string_view::npos) {
        result.state = wire.size() > maxHeaderBytes
            ? MoonlightHttpFramingState::BodyTooLarge
            : endOfStream ? MoonlightHttpFramingState::ProtocolError
                          : MoonlightHttpFramingState::NeedMore;
        return result;
    }
    result.bodyOffset = marker + 4U;
    if (result.bodyOffset > maxHeaderBytes) {
        result.state = MoonlightHttpFramingState::BodyTooLarge;
        return result;
    }

    const std::size_t statusEnd = wire.find("\r\n");
    if (statusEnd == std::string_view::npos || statusEnd > marker ||
        !parseStatusLine(wire.substr(0U, statusEnd), result.status)) {
        result.state = MoonlightHttpFramingState::ProtocolError;
        return result;
    }

    std::optional<std::size_t> contentLength;
    std::vector<std::string> transferCodings;
    std::size_t cursor = statusEnd + 2U;
    while (cursor < marker) {
        const std::size_t lineEnd = wire.find("\r\n", cursor);
        if (lineEnd == std::string_view::npos || lineEnd > marker) {
            result.state = MoonlightHttpFramingState::ProtocolError;
            return result;
        }
        const std::string_view line = wire.substr(cursor, lineEnd - cursor);
        if (line.empty() || isOws(line.front())) {
            result.state = MoonlightHttpFramingState::ProtocolError;
            return result;
        }
        const std::size_t colon = line.find(':');
        if (colon == std::string_view::npos ||
            !validHeaderName(line.substr(0U, colon)) ||
            !validHeaderValue(line.substr(colon + 1U))) {
            result.state = MoonlightHttpFramingState::ProtocolError;
            return result;
        }
        const std::string name = lowerAscii(line.substr(0U, colon));
        const std::string_view value = trimOws(line.substr(colon + 1U));
        if (name == "content-length") {
            if (!mergeContentLength(value, contentLength)) {
                result.state = MoonlightHttpFramingState::ProtocolError;
                return result;
            }
        } else if (name == "transfer-encoding") {
            if (!appendTransferCodings(value, transferCodings)) {
                result.state = MoonlightHttpFramingState::ProtocolError;
                return result;
            }
        }
        cursor = lineEnd + 2U;
    }

    if (contentLength.has_value() && !transferCodings.empty()) {
        result.state = MoonlightHttpFramingState::ProtocolError;
        return result;
    }
    if (!transferCodings.empty() &&
        (transferCodings.size() != 1U || transferCodings.front() != "chunked")) {
        result.state = MoonlightHttpFramingState::ProtocolError;
        return result;
    }

    result.complete = true;
    result.state = MoonlightHttpFramingState::NeedMore;
    if ((result.status >= 100 && result.status < 200) ||
        result.status == 204 || result.status == 304) {
        result.mode = BodyMode::None;
    } else if (!transferCodings.empty()) {
        result.mode = BodyMode::Chunked;
    } else if (contentLength.has_value()) {
        result.mode = BodyMode::ContentLength;
        result.contentLength = *contentLength;
        if (result.contentLength > maxBodyBytes) {
            result.state = MoonlightHttpFramingState::BodyTooLarge;
        }
    } else {
        result.mode = BodyMode::UntilClose;
    }
    return result;
}

bool parseHex(std::string_view value, std::size_t& output) noexcept {
    if (value.empty()) { return false; }
    std::size_t parsed = 0U;
    for (const unsigned char character : value) {
        std::size_t digit = 0U;
        if (character >= '0' && character <= '9') {
            digit = static_cast<std::size_t>(character - '0');
        } else if (character >= 'a' && character <= 'f') {
            digit = static_cast<std::size_t>(character - 'a' + 10U);
        } else if (character >= 'A' && character <= 'F') {
            digit = static_cast<std::size_t>(character - 'A' + 10U);
        } else {
            return false;
        }
        if (parsed > (std::numeric_limits<std::size_t>::max() - digit) / 16U) {
            return false;
        }
        parsed = parsed * 16U + digit;
    }
    output = parsed;
    return true;
}

ChunkProjection scanChunked(std::string_view wire, std::size_t bodyOffset,
                            bool endOfStream, std::size_t maxHeaderBytes,
                            std::size_t maxBodyBytes) {
    ChunkProjection result;
    std::size_t cursor = bodyOffset;
    std::size_t decoded = 0U;
    std::size_t framingBytes = 0U;
    for (;;) {
        const std::size_t lineEnd = wire.find("\r\n", cursor);
        if (lineEnd == std::string_view::npos) {
            if (wire.size() - cursor > kMaximumChunkLineBytes) {
                result.state = MoonlightHttpFramingState::BodyTooLarge;
            } else if (endOfStream) {
                result.state = MoonlightHttpFramingState::ProtocolError;
            }
            return result;
        }
        const std::size_t lineBytes = lineEnd - cursor;
        if (lineBytes == 0U || lineBytes > kMaximumChunkLineBytes) {
            result.state = lineBytes > kMaximumChunkLineBytes
                ? MoonlightHttpFramingState::BodyTooLarge
                : MoonlightHttpFramingState::ProtocolError;
            return result;
        }
        const std::string_view line = wire.substr(cursor, lineBytes);
        const std::size_t extension = line.find(';');
        const std::string_view sizeToken = trimOws(line.substr(0U, extension));
        std::size_t chunkBytes = 0U;
        if (!parseHex(sizeToken, chunkBytes)) {
            result.state = MoonlightHttpFramingState::ProtocolError;
            return result;
        }
        framingBytes += lineBytes + 2U;
        if (framingBytes > maxHeaderBytes || chunkBytes > maxBodyBytes - decoded) {
            result.state = MoonlightHttpFramingState::BodyTooLarge;
            return result;
        }
        cursor = lineEnd + 2U;
        if (chunkBytes == 0U) {
            const std::size_t trailerStart = cursor;
            for (;;) {
                const std::size_t trailerEnd = wire.find("\r\n", cursor);
                if (trailerEnd == std::string_view::npos) {
                    if (wire.size() - trailerStart > maxHeaderBytes) {
                        result.state = MoonlightHttpFramingState::BodyTooLarge;
                    } else if (endOfStream) {
                        result.state = MoonlightHttpFramingState::ProtocolError;
                    }
                    return result;
                }
                if (trailerEnd - trailerStart > maxHeaderBytes) {
                    result.state = MoonlightHttpFramingState::BodyTooLarge;
                    return result;
                }
                if (trailerEnd == cursor) {
                    result.consumedBytes = trailerEnd + 2U;
                    result.decodedBytes = decoded;
                    result.state = result.consumedBytes == wire.size()
                        ? MoonlightHttpFramingState::Complete
                        : MoonlightHttpFramingState::ProtocolError;
                    return result;
                }
                const std::string_view trailer = wire.substr(cursor, trailerEnd - cursor);
                const std::size_t colon = trailer.find(':');
                const std::string trailerName = colon == std::string_view::npos
                    ? std::string() : lowerAscii(trailer.substr(0U, colon));
                if (isOws(trailer.front()) || colon == std::string_view::npos ||
                    !validHeaderName(trailer.substr(0U, colon)) ||
                    !validHeaderValue(trailer.substr(colon + 1U)) ||
                    trailerName == "content-length" ||
                    trailerName == "transfer-encoding") {
                    result.state = MoonlightHttpFramingState::ProtocolError;
                    return result;
                }
                cursor = trailerEnd + 2U;
            }
        }
        if (wire.size() - cursor < chunkBytes + 2U) {
            if (endOfStream) {
                result.state = MoonlightHttpFramingState::ProtocolError;
            }
            return result;
        }
        if (wire.substr(cursor + chunkBytes, 2U) != "\r\n") {
            result.state = MoonlightHttpFramingState::ProtocolError;
            return result;
        }
        decoded += chunkBytes;
        framingBytes += 2U;
        if (framingBytes > maxHeaderBytes) {
            result.state = MoonlightHttpFramingState::BodyTooLarge;
            return result;
        }
        cursor += chunkBytes + 2U;
    }
}

std::string decodeChunked(std::string_view wire, std::size_t bodyOffset,
                          std::size_t decodedBytes) {
    std::string body;
    body.reserve(decodedBytes);
    std::size_t cursor = bodyOffset;
    while (body.size() < decodedBytes) {
        const std::size_t lineEnd = wire.find("\r\n", cursor);
        const std::string_view line = wire.substr(cursor, lineEnd - cursor);
        const std::size_t extension = line.find(';');
        std::size_t chunkBytes = 0U;
        (void)parseHex(trimOws(line.substr(0U, extension)), chunkBytes);
        cursor = lineEnd + 2U;
        body.append(wire.substr(cursor, chunkBytes));
        cursor += chunkBytes + 2U;
    }
    return body;
}

} // namespace

MoonlightHttpFramingResult inspectMoonlightHttpResponse(
    std::string_view wire, bool endOfStream, std::size_t maxHeaderBytes,
    std::size_t maxBodyBytes) noexcept {
    try {
        const HeaderProjection header = parseHeaders(
            wire, endOfStream, maxHeaderBytes, maxBodyBytes);
        if (!header.complete || header.state != MoonlightHttpFramingState::NeedMore) {
            return resultFor(header.state, header.complete, header.status);
        }

        const std::size_t wireBodyBytes = wire.size() - header.bodyOffset;
        if (header.mode == BodyMode::None) {
            if (wireBodyBytes != 0U) {
                return resultFor(MoonlightHttpFramingState::ProtocolError, true,
                                 header.status);
            }
            auto result = resultFor(MoonlightHttpFramingState::Complete, true,
                                    header.status);
            result.consumedBytes = header.bodyOffset;
            return result;
        }

        if (header.mode == BodyMode::ContentLength) {
            if (wireBodyBytes > header.contentLength) {
                return resultFor(MoonlightHttpFramingState::ProtocolError, true,
                                 header.status);
            }
            if (wireBodyBytes < header.contentLength) {
                return resultFor(endOfStream ? MoonlightHttpFramingState::ProtocolError
                                             : MoonlightHttpFramingState::NeedMore,
                                 true, header.status);
            }
            auto result = resultFor(MoonlightHttpFramingState::Complete, true,
                                    header.status);
            result.consumedBytes = wire.size();
            result.body.assign(wire.substr(header.bodyOffset, header.contentLength));
            return result;
        }

        if (header.mode == BodyMode::UntilClose) {
            if (wireBodyBytes > maxBodyBytes) {
                return resultFor(MoonlightHttpFramingState::BodyTooLarge, true,
                                 header.status);
            }
            if (!endOfStream) {
                return resultFor(MoonlightHttpFramingState::NeedMore, true,
                                 header.status);
            }
            auto result = resultFor(MoonlightHttpFramingState::Complete, true,
                                    header.status);
            result.consumedBytes = wire.size();
            result.body.assign(wire.substr(header.bodyOffset));
            return result;
        }

        const ChunkProjection chunked = scanChunked(
            wire, header.bodyOffset, endOfStream, maxHeaderBytes, maxBodyBytes);
        auto result = resultFor(chunked.state, true, header.status);
        result.consumedBytes = chunked.consumedBytes;
        if (chunked.state == MoonlightHttpFramingState::Complete) {
            result.body = decodeChunked(wire, header.bodyOffset, chunked.decodedBytes);
        }
        return result;
    } catch (...) {
        return resultFor(MoonlightHttpFramingState::ProtocolError);
    }
}

} // namespace remotedesk::moonlight
