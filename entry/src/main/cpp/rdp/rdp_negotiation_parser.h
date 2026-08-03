/**
 * rdp_negotiation_parser.h - RDP TPKT/X.224 security negotiation parsing.
 *
 * This helper is deliberately independent from sockets, OpenSSL and OHOS so
 * fragmented network reads and protocol classification can be tested on host.
 */

#ifndef RDP_NEGOTIATION_PARSER_H
#define RDP_NEGOTIATION_PARSER_H

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace RdpNegotiation {

constexpr uint8_t kTpktVersion = 0x03;
constexpr uint8_t kX224ConnectionConfirm = 0xD0;
constexpr uint8_t kRdpNegResponse = 0x02;
constexpr uint8_t kRdpNegFailure = 0x03;

constexpr uint32_t kProtocolRdp = 0x00000000;
constexpr uint32_t kProtocolSsl = 0x00000001;
constexpr uint32_t kProtocolHybrid = 0x00000002;
constexpr uint32_t kProtocolRdsTls = 0x00000004;
constexpr uint32_t kProtocolHybridEx = 0x00000008;
constexpr uint32_t kProtocolRdsAad = 0x00000010;

enum class ParseStatus {
    NeedMoreData,
    Complete,
    Invalid,
};

enum class ResponseKind {
    Invalid,
    NoNegotiationData,
    NegotiationResponse,
    NegotiationFailure,
};

struct ParseResult {
    ParseStatus status = ParseStatus::NeedMoreData;
    ResponseKind kind = ResponseKind::Invalid;
    uint16_t tpktLength = 0;
    uint8_t x224LengthIndicator = 0;
    uint8_t flags = 0;
    uint32_t selectedProtocol = kProtocolRdp;
    uint32_t failureCode = 0;
    std::string error;
};

inline uint16_t readBigEndian16(const uint8_t* data) {
    return static_cast<uint16_t>((static_cast<uint16_t>(data[0]) << 8) |
                                  static_cast<uint16_t>(data[1]));
}

inline uint16_t readLittleEndian16(const uint8_t* data) {
    return static_cast<uint16_t>(static_cast<uint16_t>(data[0]) |
                                  (static_cast<uint16_t>(data[1]) << 8));
}

inline uint32_t readLittleEndian32(const uint8_t* data) {
    return static_cast<uint32_t>(data[0]) |
           (static_cast<uint32_t>(data[1]) << 8) |
           (static_cast<uint32_t>(data[2]) << 16) |
           (static_cast<uint32_t>(data[3]) << 24);
}

inline const char* selectedProtocolName(uint32_t protocol) {
    switch (protocol) {
        case kProtocolRdp:
            return "RDP";
        case kProtocolSsl:
            return "SSL";
        case kProtocolHybrid:
            return "HYBRID";
        case kProtocolRdsTls:
            return "RDSTLS";
        case kProtocolHybridEx:
            return "HYBRID_EX";
        case kProtocolRdsAad:
            return "RDSAAD";
        default:
            return "UNKNOWN";
    }
}

inline bool isTlsProtocol(uint32_t protocol) {
    return protocol == kProtocolSsl || protocol == kProtocolHybrid ||
           protocol == kProtocolRdsTls;
}

inline const char* failureCodeName(uint32_t failureCode) {
    switch (failureCode) {
        case 0x00000001:
            return "SSL_REQUIRED_BY_SERVER";
        case 0x00000002:
            return "SSL_NOT_ALLOWED_BY_SERVER";
        case 0x00000003:
            return "SSL_CERT_NOT_ON_SERVER";
        case 0x00000004:
            return "INCONSISTENT_FLAGS";
        case 0x00000005:
            return "HYBRID_REQUIRED_BY_SERVER";
        case 0x00000006:
            return "SSL_WITH_USER_AUTH_REQUIRED_BY_SERVER";
        default:
            return "UNKNOWN";
    }
}

inline ParseResult invalidResult(const char* error) {
    ParseResult result;
    result.status = ParseStatus::Invalid;
    result.error = error == nullptr ? "invalid RDP negotiation response" : error;
    return result;
}

inline ParseResult parseRdpNegotiationResponse(const std::vector<uint8_t>& data) {
    ParseResult result;
    if (data.size() < 4) {
        result.error = "TPKT header is incomplete";
        return result;
    }

    if (data[0] != kTpktVersion || data[1] != 0x00) {
        return invalidResult("invalid TPKT version or reserved byte");
    }

    const uint16_t tpktLength = readBigEndian16(data.data() + 2);
    result.tpktLength = tpktLength;
    if (tpktLength < 7) {
        return invalidResult("TPKT length is below the protocol minimum");
    }
    if (data.size() < tpktLength) {
        result.error = "TPKT payload is incomplete";
        return result;
    }
    if (data.size() != tpktLength) {
        return invalidResult("TPKT contains trailing bytes");
    }

    // A Connection Confirm has a 7-byte X.224 header including LI. The
    // negotiation data, when present, follows at offset 11.
    if (data.size() < 11 || data[5] != kX224ConnectionConfirm) {
        return invalidResult("RDP response is not an X.224 Connection Confirm");
    }

    const uint8_t li = data[4];
    result.x224LengthIndicator = li;
    if (li < 6 || static_cast<size_t>(li) + 5 != data.size()) {
        return invalidResult("invalid X.224 Connection Confirm length");
    }

    if (li == 6) {
        result.status = ParseStatus::Complete;
        result.kind = ResponseKind::NoNegotiationData;
        return result;
    }

    if (li != 14 || data.size() != 19) {
        return invalidResult("unsupported RDP negotiation data length");
    }

    const uint8_t type = data[11];
    if (type != kRdpNegResponse && type != kRdpNegFailure) {
        return invalidResult("unsupported RDP negotiation PDU type");
    }

    result.flags = data[12];
    if (readLittleEndian16(data.data() + 13) != 8) {
        return invalidResult("RDP negotiation PDU length is not 8");
    }

    if (type == kRdpNegResponse) {
        result.status = ParseStatus::Complete;
        result.kind = ResponseKind::NegotiationResponse;
        result.selectedProtocol = readLittleEndian32(data.data() + 15);
        return result;
    }

    if (result.flags != 0) {
        return invalidResult("RDP_NEG_FAILURE contains unsupported flags");
    }
    result.status = ParseStatus::Complete;
    result.kind = ResponseKind::NegotiationFailure;
    result.failureCode = readLittleEndian32(data.data() + 15);
    return result;
}

class RdpTpktAccumulator final {
public:
    static constexpr size_t kHeaderSize = 4;
    static constexpr size_t kMaxTpktLength = 0xFFFF;

    bool append(const uint8_t* data, size_t size) {
        if (invalid_ || (data == nullptr && size != 0)) {
            invalid_ = true;
            error_ = "invalid TPKT input";
            return false;
        }
        if (size > kMaxTpktLength - bytes_.size()) {
            invalid_ = true;
            error_ = "TPKT input exceeds maximum length";
            return false;
        }
        if (size != 0) {
            bytes_.insert(bytes_.end(), data, data + size);
        }
        const size_t expected = expectedLength();
        if (expected != 0 && bytes_.size() > expected) {
            invalid_ = true;
            error_ = "TPKT input contains trailing bytes";
            return false;
        }
        return true;
    }

    size_t size() const {
        return bytes_.size();
    }

    size_t expectedLength() const {
        if (bytes_.size() < kHeaderSize) {
            return 0;
        }
        return readBigEndian16(bytes_.data() + 2);
    }

    bool complete() const {
        const ParseResult result = parse();
        return result.status == ParseStatus::Complete;
    }

    ParseResult parse() const {
        if (invalid_) {
            return invalidResult(error_.c_str());
        }
        return parseRdpNegotiationResponse(bytes_);
    }

    const std::vector<uint8_t>& bytes() const {
        return bytes_;
    }

private:
    std::vector<uint8_t> bytes_;
    bool invalid_ = false;
    std::string error_;
};

} // namespace RdpNegotiation

#endif // RDP_NEGOTIATION_PARSER_H
