#include "moonlight/core/MoonlightHostApi.h"

#include "common/endpoint_address_policy.h"

#include <algorithm>
#include <atomic>
#include <charconv>
#include <condition_variable>
#include <limits>
#include <mutex>
#include <set>
#include <sstream>
#include <type_traits>
#include <unordered_map>
#include <unordered_set>
#include <utility>

namespace remotedesk::moonlight {
namespace {

constexpr const char* kProtocolUniqueId = "0123456789ABCDEF";
constexpr std::size_t kMaxServerFieldBytes = 1024U;
constexpr std::size_t kMaxPairingFieldBytes = 256U * 1024U;
constexpr std::uint16_t kDefaultHttpPort = 47989U;
constexpr std::size_t kMaxLearnedHttpsPorts = 64U;

#if defined(RDP_NATIVE_CALLBACK_TESTING)
std::atomic<std::uint64_t> gSecureCleanseCount{0};
#endif

void secureWipe(void* pointer, std::size_t size) noexcept {
    auto* bytes = static_cast<volatile unsigned char*>(pointer);
    while (size > 0U) {
        *bytes = 0U;
        ++bytes;
        --size;
    }
    std::atomic_signal_fence(std::memory_order_seq_cst);
}

void secureWipeString(std::string& value) noexcept {
    if (!value.empty()) {
        secureWipe(value.data(), value.size());
#if defined(RDP_NATIVE_CALLBACK_TESTING)
        gSecureCleanseCount.fetch_add(1U, std::memory_order_relaxed);
#endif
    }
    value.clear();
}

class StringWiper final {
public:
    explicit StringWiper(std::string& value) noexcept : value_(value) {}
    ~StringWiper() { secureWipeString(value_); }

    StringWiper(const StringWiper&) = delete;
    StringWiper& operator=(const StringWiper&) = delete;

private:
    std::string& value_;
};

struct RequestKeyHash final {
    std::size_t operator()(const MoonlightHostRequestKey& key) const noexcept {
        const auto mix = [](std::size_t seed, std::uint64_t value) {
            return seed ^
                   (static_cast<std::size_t>(value) +
                    static_cast<std::size_t>(0x9e3779b97f4a7c15ULL) + (seed << 6U) + (seed >> 2U));
        };
        std::size_t result = 0;
        result = mix(result, key.requestId);
        result = mix(result, key.generation);
        return mix(result, key.ownerToken);
    }
};

enum class RequestDisposition : std::uint8_t {
    Active = 0,
    Cancelled,
    Stale,
};

struct ActiveRequest final {
    explicit ActiveRequest(MoonlightHostRequestKey valueKey) : key(valueKey) {}

    const MoonlightHostRequestKey key;
    std::atomic<RequestDisposition> disposition{RequestDisposition::Active};
};

bool isAsciiWhitespace(char value) noexcept {
    return value == ' ' || value == '\t' || value == '\r' || value == '\n';
}

std::string trimAscii(const std::string& value) {
    std::size_t begin = 0;
    while (begin < value.size() && isAsciiWhitespace(value[begin])) {
        ++begin;
    }
    std::size_t end = value.size();
    while (end > begin && isAsciiWhitespace(value[end - 1U])) {
        --end;
    }
    return value.substr(begin, end - begin);
}

bool containsForbiddenUrlText(const std::string& value) noexcept {
    return value.find('\0') != std::string::npos || value.find('\r') != std::string::npos ||
           value.find('\n') != std::string::npos || value.find('@') != std::string::npos ||
           value.find('/') != std::string::npos || value.find('?') != std::string::npos ||
           value.find('#') != std::string::npos;
}

bool isSafeAuthorityText(const std::string& value, MoonlightHostAddressFamily family) noexcept {
    if (value.empty() || containsForbiddenUrlText(value)) {
        return false;
    }
    if (family == MoonlightHostAddressFamily::Unspecified && value.find(':') != std::string::npos) {
        family = MoonlightHostAddressFamily::Ipv6;
    }
    for (const char raw : value) {
        const auto ch = static_cast<unsigned char>(raw);
        const bool decimal = ch >= '0' && ch <= '9';
        const bool alpha = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z');
        const bool common = decimal || alpha || ch == '.' || ch == '-';
        if (family == MoonlightHostAddressFamily::Ipv4) {
            if (!(decimal || ch == '.'))
                return false;
        } else if (family == MoonlightHostAddressFamily::Ipv6) {
            const bool hexAlpha = (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F');
            if (!(decimal || hexAlpha || ch == ':' || ch == '.'))
                return false;
        } else if (!(common || ch == ':')) {
            return false;
        }
    }
    return true;
}

std::string transportHostFor(const MoonlightHostAddress& address) {
    return address.scope.empty() ? address.value : address.value + "%" + address.scope;
}

bool isValidUuid(const std::string& value) noexcept {
    if (value.size() != 36U) {
        return false;
    }
    for (std::size_t i = 0; i < value.size(); ++i) {
        if (i == 8U || i == 13U || i == 18U || i == 23U) {
            if (value[i] != '-') {
                return false;
            }
            continue;
        }
        const char ch = value[i];
        const bool hex =
            (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F');
        if (!hex) {
            return false;
        }
    }
    return true;
}

bool isQueryName(const std::string& value) noexcept {
    if (value.empty() || value.size() > 64U) {
        return false;
    }
    for (const char ch : value) {
        if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') ||
              ch == '_')) {
            return false;
        }
    }
    return true;
}

bool isHex(const std::string& value, bool allowEmpty = false) noexcept {
    if (value.empty()) {
        return allowEmpty;
    }
    if ((value.size() % 2U) != 0U) {
        return false;
    }
    for (const char ch : value) {
        if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F'))) {
            return false;
        }
    }
    return true;
}

template <typename Unsigned>
bool parseUnsigned(const std::string& value, Unsigned& output) noexcept {
    static_assert(std::is_unsigned<Unsigned>::value, "Unsigned type required");
    if (value.empty()) {
        return false;
    }
    Unsigned result = 0;
    for (const char ch : value) {
        if (ch < '0' || ch > '9') {
            return false;
        }
        const Unsigned digit = static_cast<Unsigned>(ch - '0');
        if (result > (std::numeric_limits<Unsigned>::max() - digit) / 10U) {
            return false;
        }
        result = static_cast<Unsigned>(result * 10U + digit);
    }
    output = result;
    return true;
}

bool isXmlCodePoint(std::uint32_t codePoint) noexcept {
    return codePoint == 0x9U || codePoint == 0xAU || codePoint == 0xDU ||
           (codePoint >= 0x20U && codePoint <= 0xD7FFU) ||
           (codePoint >= 0xE000U && codePoint <= 0xFFFDU) ||
           (codePoint >= 0x10000U && codePoint <= 0x10FFFFU);
}

bool appendUtf8(std::uint32_t codePoint, std::string& output) {
    if (!isXmlCodePoint(codePoint)) {
        return false;
    }
    if (codePoint <= 0x7FU) {
        output.push_back(static_cast<char>(codePoint));
    } else if (codePoint <= 0x7FFU) {
        output.push_back(static_cast<char>(0xC0U | (codePoint >> 6U)));
        output.push_back(static_cast<char>(0x80U | (codePoint & 0x3FU)));
    } else if (codePoint <= 0xFFFFU) {
        output.push_back(static_cast<char>(0xE0U | (codePoint >> 12U)));
        output.push_back(static_cast<char>(0x80U | ((codePoint >> 6U) & 0x3FU)));
        output.push_back(static_cast<char>(0x80U | (codePoint & 0x3FU)));
    } else {
        output.push_back(static_cast<char>(0xF0U | (codePoint >> 18U)));
        output.push_back(static_cast<char>(0x80U | ((codePoint >> 12U) & 0x3FU)));
        output.push_back(static_cast<char>(0x80U | ((codePoint >> 6U) & 0x3FU)));
        output.push_back(static_cast<char>(0x80U | (codePoint & 0x3FU)));
    }
    return true;
}

bool validateUtf8Xml(const std::string& value) noexcept {
    std::size_t offset = 0;
    while (offset < value.size()) {
        const auto first = static_cast<unsigned char>(value[offset]);
        std::uint32_t codePoint = 0;
        std::size_t length = 0;
        if (first <= 0x7FU) {
            codePoint = first;
            length = 1;
        } else if ((first & 0xE0U) == 0xC0U) {
            codePoint = first & 0x1FU;
            length = 2;
            if (codePoint == 0U) {
                return false;
            }
        } else if ((first & 0xF0U) == 0xE0U) {
            codePoint = first & 0x0FU;
            length = 3;
        } else if ((first & 0xF8U) == 0xF0U) {
            codePoint = first & 0x07U;
            length = 4;
        } else {
            return false;
        }
        if (offset + length > value.size()) {
            return false;
        }
        for (std::size_t index = 1; index < length; ++index) {
            const auto next = static_cast<unsigned char>(value[offset + index]);
            if ((next & 0xC0U) != 0x80U) {
                return false;
            }
            codePoint = (codePoint << 6U) | (next & 0x3FU);
        }
        if ((length == 2U && codePoint < 0x80U) || (length == 3U && codePoint < 0x800U) ||
            (length == 4U && codePoint < 0x10000U) ||
            (codePoint >= 0xD800U && codePoint <= 0xDFFFU) || codePoint > 0x10FFFFU ||
            !isXmlCodePoint(codePoint)) {
            return false;
        }
        offset += length;
    }
    return true;
}

bool percentEncode(const std::string& input, std::string& output) {
    static constexpr char kHex[] = "0123456789ABCDEF";
    if (input.find('\0') != std::string::npos || input.find('\r') != std::string::npos ||
        input.find('\n') != std::string::npos) {
        return false;
    }
    for (const char raw : input) {
        const auto ch = static_cast<unsigned char>(raw);
        const bool unreserved = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
                                (ch >= '0' && ch <= '9') || ch == '-' || ch == '.' || ch == '_' ||
                                ch == '~';
        if (unreserved) {
            output.push_back(static_cast<char>(ch));
        } else {
            output.push_back('%');
            output.push_back(kHex[(ch >> 4U) & 0xFU]);
            output.push_back(kHex[ch & 0xFU]);
        }
        if (output.size() > MoonlightHostLimits::kMaxUrlBytes) {
            return false;
        }
    }
    return true;
}

std::string lowerAscii(std::string value) {
    for (char& ch : value) {
        if (ch >= 'A' && ch <= 'Z') {
            ch = static_cast<char>(ch - 'A' + 'a');
        }
    }
    return value;
}

bool queryContains(const std::vector<MoonlightHostQueryParameter>& query, const std::string& name,
                   std::string* value = nullptr) {
    const auto it = std::find_if(query.begin(), query.end(),
                                 [&](const auto& item) { return item.name == name; });
    if (it == query.end()) {
        return false;
    }
    if (value != nullptr) {
        *value = it->value;
    }
    return true;
}

bool parsePositive32(const std::string& value) noexcept {
    std::uint32_t parsed = 0;
    return parseUnsigned(value, parsed) && parsed != 0U;
}

bool parseSigned32(const std::string& value) noexcept {
    if (value.empty())
        return false;
    const bool negative = value.front() == '-';
    const std::string magnitudeText = negative ? value.substr(1U) : value;
    std::uint64_t magnitude = 0;
    if (magnitudeText.empty() || !parseUnsigned(magnitudeText, magnitude)) {
        return false;
    }
    const std::uint64_t limit = negative ? 2147483648ULL : 2147483647ULL;
    return magnitude <= limit;
}

bool parseFlag(const std::string& value) noexcept { return value == "0" || value == "1"; }

bool validMode(const std::string& value) noexcept {
    const auto first = value.find('x');
    const auto second =
        first == std::string::npos ? std::string::npos : value.find('x', first + 1U);
    if (first == std::string::npos || second == std::string::npos ||
        value.find('x', second + 1U) != std::string::npos) {
        return false;
    }
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    std::uint32_t fps = 0;
    return parseUnsigned(value.substr(0, first), width) && width >= 320U && width <= 16384U &&
           parseUnsigned(value.substr(first + 1U, second - first - 1U), height) && height >= 200U &&
           height <= 16384U && parseUnsigned(value.substr(second + 1U), fps) && fps <= 1000U;
}

struct QueryShape final {
    MoonlightHostError error = MoonlightHostError::None;
    std::string path;
    std::vector<MoonlightHostQueryParameter> parameters;
    MoonlightHostScheme scheme = MoonlightHostScheme::Http;
    bool requiresClientIdentity = false;
    bool requiresServerPin = false;
    bool readOnly = false;
    bool xmlResponse = true;

    QueryShape() = default;
    QueryShape(const QueryShape&) = default;
    QueryShape& operator=(const QueryShape&) = default;
    QueryShape(QueryShape&&) noexcept = default;
    QueryShape& operator=(QueryShape&&) noexcept = default;
    ~QueryShape() {
        for (auto& parameter : parameters) {
            secureWipeString(parameter.value);
        }
    }
};

bool exactNames(const std::vector<MoonlightHostQueryParameter>& query,
                const std::set<std::string>& allowed) {
    return std::all_of(query.begin(), query.end(),
                       [&](const auto& item) { return allowed.find(item.name) != allowed.end(); });
}

QueryShape makeQueryShape(const MoonlightHostCall& call) {
    QueryShape shape;
    if (call.query.size() > MoonlightHostLimits::kMaxQueryParameters) {
        shape.error = MoonlightHostError::InvalidQuery;
        return shape;
    }
    std::size_t queryBytes = 0;
    for (const auto& parameter : call.query) {
        if (parameter.name.size() > MoonlightHostLimits::kMaxUrlBytes - queryBytes) {
            shape.error = MoonlightHostError::UrlTooLong;
            return shape;
        }
        queryBytes += parameter.name.size();
        if (parameter.value.size() > MoonlightHostLimits::kMaxUrlBytes - queryBytes) {
            shape.error = MoonlightHostError::UrlTooLong;
            return shape;
        }
        queryBytes += parameter.value.size();
    }
    switch (call.operation) {
    case MoonlightHostOperation::ServerInfo:
        shape.path = "/serverinfo";
        shape.readOnly = true;
        if (!call.query.empty()) {
            shape.error = MoonlightHostError::InvalidQuery;
        }
        break;
    case MoonlightHostOperation::AppList:
        shape.path = "/applist";
        shape.scheme = MoonlightHostScheme::Https;
        shape.requiresClientIdentity = true;
        shape.requiresServerPin = true;
        shape.readOnly = true;
        if (!call.query.empty()) {
            shape.error = MoonlightHostError::InvalidQuery;
        }
        break;
    case MoonlightHostOperation::AppAsset: {
        shape.path = "/appasset";
        shape.scheme = MoonlightHostScheme::Https;
        shape.requiresClientIdentity = true;
        shape.requiresServerPin = true;
        shape.readOnly = true;
        shape.xmlResponse = false;
        std::string appId;
        if (call.query.size() != 1U || !queryContains(call.query, "appid", &appId) ||
            !parsePositive32(appId)) {
            shape.error = MoonlightHostError::InvalidQuery;
            break;
        }
        shape.parameters = call.query;
        shape.parameters.push_back({"AssetType", "2"});
        shape.parameters.push_back({"AssetIdx", "0"});
        break;
    }
    case MoonlightHostOperation::Pair: {
        shape.path = "/pair";
        const std::set<std::string> allowed{
            "phrase",
            "salt",
            "clientcert",
            "clientchallenge",
            "serverchallengeresp",
            "clientpairingsecret",
        };
        if (!exactNames(call.query, allowed)) {
            shape.error = MoonlightHostError::InvalidQuery;
            break;
        }
        const bool getCert = queryContains(call.query, "phrase");
        const bool challenge = queryContains(call.query, "clientchallenge");
        const bool challengeResponse = queryContains(call.query, "serverchallengeresp");
        const bool secret = queryContains(call.query, "clientpairingsecret");
        const int stages = static_cast<int>(getCert) + static_cast<int>(challenge) +
                           static_cast<int>(challengeResponse) + static_cast<int>(secret);
        std::string phrase;
        StringWiper phraseWiper(phrase);
        std::string salt;
        StringWiper saltWiper(salt);
        std::string clientCert;
        StringWiper clientCertWiper(clientCert);
        if (stages != 1 ||
            (getCert &&
             (!queryContains(call.query, "phrase", &phrase) || phrase != "getservercert" ||
              !queryContains(call.query, "salt", &salt) ||
              !queryContains(call.query, "clientcert", &clientCert) || call.query.size() != 3U ||
              salt.size() != 32U || !isHex(salt) || !isHex(clientCert)))) {
            shape.error = MoonlightHostError::InvalidQuery;
            break;
        }
        if (!getCert && call.query.size() != 1U) {
            shape.error = MoonlightHostError::InvalidQuery;
            break;
        }
        for (const auto& item : call.query) {
            if (item.name != "phrase" && !isHex(item.value)) {
                shape.error = MoonlightHostError::InvalidQuery;
                break;
            }
        }
        shape.parameters = {{"devicename", "roth"}, {"updateState", "1"}};
        shape.parameters.insert(shape.parameters.end(), call.query.begin(), call.query.end());
        break;
    }
    case MoonlightHostOperation::PairChallenge:
        shape.path = "/pair";
        shape.scheme = MoonlightHostScheme::Https;
        shape.requiresClientIdentity = true;
        shape.requiresServerPin = true;
        if (!call.query.empty()) {
            shape.error = MoonlightHostError::InvalidQuery;
            break;
        }
        shape.parameters = {
            {"devicename", "roth"},
            {"updateState", "1"},
            {"phrase", "pairchallenge"},
        };
        break;
    case MoonlightHostOperation::Unpair:
        shape.path = "/unpair";
        if (!call.query.empty()) {
            shape.error = MoonlightHostError::InvalidQuery;
        }
        break;
    case MoonlightHostOperation::Launch:
    case MoonlightHostOperation::Resume: {
        shape.path = call.operation == MoonlightHostOperation::Launch ? "/launch" : "/resume";
        shape.scheme = MoonlightHostScheme::Https;
        shape.requiresClientIdentity = true;
        shape.requiresServerPin = true;
        const std::set<std::string> required{
            "appid",
            "mode",
            "additionalStates",
            "sops",
            "rikey",
            "rikeyid",
            "localAudioPlayMode",
            "surroundAudioInfo",
            "remoteControllersBitmap",
            "gcmap",
            "gcpersist",
        };
        const std::set<std::string> hdr{
            "hdrMode",
            "clientHdrCapVersion",
            "clientHdrCapSupportedFlagsInUint32",
            "clientHdrCapMetaDataId",
            "clientHdrCapDisplayData",
        };
        std::set<std::string> allowed = required;
        allowed.insert(hdr.begin(), hdr.end());
        if (!exactNames(call.query, allowed)) {
            shape.error = MoonlightHostError::InvalidQuery;
            break;
        }
        for (const auto& name : required) {
            if (!queryContains(call.query, name)) {
                shape.error = MoonlightHostError::InvalidQuery;
                break;
            }
        }
        if (shape.error != MoonlightHostError::None) {
            break;
        }
        const std::size_t hdrCount = static_cast<std::size_t>(
            std::count_if(call.query.begin(), call.query.end(),
                          [&](const auto& item) { return hdr.find(item.name) != hdr.end(); }));
        if (hdrCount != 0U && hdrCount != hdr.size()) {
            shape.error = MoonlightHostError::InvalidQuery;
            break;
        }
        std::string value;
        StringWiper valueWiper(value);
        if (!queryContains(call.query, "appid", &value) || !parsePositive32(value) ||
            !queryContains(call.query, "mode", &value) || !validMode(value) ||
            !queryContains(call.query, "rikey", &value) || value.size() != 32U || !isHex(value) ||
            !queryContains(call.query, "rikeyid", &value) || !parseSigned32(value)) {
            shape.error = MoonlightHostError::InvalidQuery;
            break;
        }
        for (const auto& name : {"additionalStates", "sops", "localAudioPlayMode", "gcpersist"}) {
            if (!queryContains(call.query, name, &value) || !parseFlag(value)) {
                shape.error = MoonlightHostError::InvalidQuery;
                break;
            }
        }
        for (const auto& name : {"surroundAudioInfo", "remoteControllersBitmap", "gcmap"}) {
            std::uint32_t parsed = 0;
            if (!queryContains(call.query, name, &value) || !parseUnsigned(value, parsed)) {
                shape.error = MoonlightHostError::InvalidQuery;
                break;
            }
        }
        if (shape.error != MoonlightHostError::None) {
            break;
        }
        if (hdrCount != 0U) {
            if (!queryContains(call.query, "hdrMode", &value) || value != "1" ||
                !queryContains(call.query, "clientHdrCapVersion", &value) || value != "0" ||
                !queryContains(call.query, "clientHdrCapSupportedFlagsInUint32", &value) ||
                value != "0" || !queryContains(call.query, "clientHdrCapMetaDataId", &value) ||
                value != "NV_STATIC_METADATA_TYPE_1" ||
                !queryContains(call.query, "clientHdrCapDisplayData", &value) ||
                value != "0x0x0x0x0x0x0x0x0x0x0") {
                shape.error = MoonlightHostError::InvalidQuery;
                break;
            }
        }
        shape.parameters = call.query;
        shape.parameters.push_back({"corever", "1"});
        break;
    }
    case MoonlightHostOperation::Cancel:
        shape.path = "/cancel";
        shape.scheme = MoonlightHostScheme::Https;
        shape.requiresClientIdentity = true;
        shape.requiresServerPin = true;
        if (!call.query.empty()) {
            shape.error = MoonlightHostError::InvalidQuery;
        }
        break;
    }
    if (shape.parameters.empty() && shape.error == MoonlightHostError::None) {
        shape.parameters = call.query;
    }
    return shape;
}

MoonlightHostError validateCall(const MoonlightHostCall& call, const QueryShape& shape) {
    if (!call.key.valid()) {
        return MoonlightHostError::InvalidRequest;
    }
    std::string pairPhrase;
    const bool waitsForPairingUser = call.operation == MoonlightHostOperation::Pair &&
                                     queryContains(call.query, "phrase", &pairPhrase) &&
                                     pairPhrase == "getservercert";
    const auto maximumTimeout = waitsForPairingUser ? MoonlightHostLimits::kMaxTimeout
                                                    : MoonlightHostLimits::kMaxStandardTimeout;
    if (call.timeout < MoonlightHostLimits::kMinTimeout || call.timeout > maximumTimeout) {
        return MoonlightHostError::InvalidRequest;
    }
    if (shape.error != MoonlightHostError::None) {
        return shape.error;
    }
    if (call.endpoint.httpPort == 0U || call.endpoint.httpsPort == 0U) {
        return MoonlightHostError::InvalidPort;
    }
    if (call.endpoint.serverName.empty() || call.endpoint.serverName.size() > 255U ||
        !isSafeAuthorityText(call.endpoint.serverName,
                             call.endpoint.serverName.find(':') == std::string::npos
                                 ? MoonlightHostAddressFamily::Unspecified
                                 : MoonlightHostAddressFamily::Ipv6) ||
        call.endpoint.serverName.front() == '[' || call.endpoint.serverName.back() == ']') {
        return MoonlightHostError::InvalidEndpoint;
    }
    if (call.endpoint.addresses.empty() ||
        call.endpoint.addresses.size() > MoonlightHostLimits::kMaxAddresses) {
        return MoonlightHostError::InvalidEndpoint;
    }
    std::unordered_set<std::string> addresses;
    for (const auto& address : call.endpoint.addresses) {
        const auto parsed = remotedesk::endpoint::ParseHost(
            transportHostFor(address), remotedesk::endpoint::ParseMode::Persisted);
        if (address.value.empty() || address.value.size() > 255U ||
            !isSafeAuthorityText(address.value, address.family) || address.value.front() == '[' ||
            address.value.back() == ']' ||
            (address.family == MoonlightHostAddressFamily::Ipv6 &&
             address.value.find(':') == std::string::npos) ||
            (address.family == MoonlightHostAddressFamily::Ipv4 &&
             address.value.find(':') != std::string::npos) || !parsed.ok ||
            parsed.endpoint.canonicalHost() != address.value ||
            parsed.endpoint.scope() != address.scope ||
            (address.family == MoonlightHostAddressFamily::Ipv6 &&
             parsed.endpoint.family() != remotedesk::endpoint::AddressFamily::Ipv6) ||
            (address.family == MoonlightHostAddressFamily::Ipv4 &&
             parsed.endpoint.family() != remotedesk::endpoint::AddressFamily::Ipv4)) {
            return MoonlightHostError::InvalidEndpoint;
        }
        const auto identity = std::to_string(static_cast<unsigned>(address.family)) + ":" +
            lowerAscii(address.value) + "%" + address.scope;
        if (!addresses.insert(identity).second) {
            return MoonlightHostError::InvalidEndpoint;
        }
    }
    if ((shape.requiresClientIdentity || shape.requiresServerPin) &&
        !call.endpoint.pinnedTrustAvailable) {
        return MoonlightHostError::InvalidEndpoint;
    }
    if (shape.parameters.size() > MoonlightHostLimits::kMaxQueryParameters) {
        return MoonlightHostError::InvalidQuery;
    }
    std::unordered_set<std::string> names;
    for (const auto& parameter : shape.parameters) {
        if (!isQueryName(parameter.name) || parameter.value.size() > 6144U ||
            parameter.value.find('\0') != std::string::npos ||
            parameter.value.find('\r') != std::string::npos ||
            parameter.value.find('\n') != std::string::npos) {
            return MoonlightHostError::InvalidQuery;
        }
        const auto lowered = lowerAscii(parameter.name);
        if (lowered == "uniqueid" || lowered == "uuid" || !names.insert(parameter.name).second) {
            return MoonlightHostError::InvalidQuery;
        }
    }
    return MoonlightHostError::None;
}

std::string authorityFor(const MoonlightHostAddress& address) {
    if (address.family == MoonlightHostAddressFamily::Ipv6 ||
        address.value.find(':') != std::string::npos) {
        return "[" + address.value +
            (address.scope.empty() ? std::string() : "%25" + address.scope) + "]";
    }
    return address.value;
}

MoonlightHostError buildUrl(const MoonlightHostAddress& address, MoonlightHostScheme scheme,
                            std::uint16_t port, const QueryShape& shape, const std::string& uuid,
                            std::string& output) {
    if (!isValidUuid(uuid)) {
        return MoonlightHostError::InvalidRequest;
    }
    output = scheme == MoonlightHostScheme::Https ? "https://" : "http://";
    output += authorityFor(address);
    output += ":" + std::to_string(port) + shape.path;
    std::vector<MoonlightHostQueryParameter> parameters = shape.parameters;
    struct ParameterWiper final {
        std::vector<MoonlightHostQueryParameter>& values;
        ~ParameterWiper() {
            for (auto& parameter : values) {
                secureWipeString(parameter.value);
            }
        }
    } parameterWiper{parameters};
    parameters.push_back({"uniqueid", kProtocolUniqueId});
    parameters.push_back({"uuid", uuid});
    for (std::size_t index = 0; index < parameters.size(); ++index) {
        output.push_back(index == 0U ? '?' : '&');
        output += parameters[index].name;
        output.push_back('=');
        if (!percentEncode(parameters[index].value, output)) {
            return MoonlightHostError::UrlTooLong;
        }
        if (output.size() > MoonlightHostLimits::kMaxUrlBytes) {
            return MoonlightHostError::UrlTooLong;
        }
    }
    return MoonlightHostError::None;
}

std::string maskedEndpoint(MoonlightHostScheme scheme, std::uint16_t port,
                           const std::string& path) {
    return std::string(scheme == MoonlightHostScheme::Https ? "https" : "http") +
           "://<host>:" + std::to_string(port) + path;
}

enum class XmlIssue : std::uint8_t {
    None = 0,
    Malformed,
    Budget,
};

struct XmlAttribute final {
    std::string name;
    std::string value;

    XmlAttribute() = default;
    XmlAttribute(const XmlAttribute&) = default;
    XmlAttribute& operator=(const XmlAttribute&) = default;
    XmlAttribute(XmlAttribute&&) noexcept = default;
    XmlAttribute& operator=(XmlAttribute&&) noexcept = default;
    ~XmlAttribute() {
        secureWipeString(name);
        secureWipeString(value);
    }
};

struct XmlNode final {
    std::string name;
    std::vector<XmlAttribute> attributes;
    std::string text;
    std::vector<XmlNode> children;

    XmlNode() = default;
    XmlNode(const XmlNode&) = default;
    XmlNode& operator=(const XmlNode&) = default;
    XmlNode(XmlNode&&) noexcept = default;
    XmlNode& operator=(XmlNode&&) noexcept = default;
    ~XmlNode() {
        secureWipeString(name);
        secureWipeString(text);
    }
};

class StrictXmlParser final {
public:
    explicit StrictXmlParser(const std::string& input) : input_(input) {}

    XmlIssue parse(XmlNode& root) {
        if (input_.size() > MoonlightHostLimits::kMaxBodyBytes) {
            return XmlIssue::Budget;
        }
        if (!validateUtf8Xml(input_)) {
            return XmlIssue::Malformed;
        }
        if (input_.size() >= 3U && static_cast<unsigned char>(input_[0]) == 0xEFU &&
            static_cast<unsigned char>(input_[1]) == 0xBBU &&
            static_cast<unsigned char>(input_[2]) == 0xBFU) {
            offset_ = 3U;
        }
        skipWhitespace();
        // One bounded XML declaration is permitted for real Sunshine/GFE
        // responses. Every other processing instruction remains forbidden.
        if (startsWith("<?xml") && offset_ + 5U < input_.size() &&
            isAsciiWhitespace(input_[offset_ + 5U])) {
            const auto end = input_.find("?>", offset_ + 5U);
            if (end == std::string::npos || end - offset_ > 1024U) {
                return XmlIssue::Malformed;
            }
            offset_ = end + 2U;
            skipWhitespace();
        }
        const auto issue = parseElement(1U, root);
        if (issue != XmlIssue::None) {
            return issue;
        }
        skipWhitespace();
        return offset_ == input_.size() ? XmlIssue::None : XmlIssue::Malformed;
    }

private:
    bool startsWith(const char* value) const {
        const std::string needle(value);
        return offset_ + needle.size() <= input_.size() &&
               input_.compare(offset_, needle.size(), needle) == 0;
    }

    void skipWhitespace() {
        while (offset_ < input_.size() && isAsciiWhitespace(input_[offset_])) {
            ++offset_;
        }
    }

    bool parseName(std::string& output) {
        const std::size_t begin = offset_;
        if (offset_ >= input_.size()) {
            return false;
        }
        const auto validFirst = [](char ch) {
            return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_' || ch == ':';
        };
        const auto validRest = [&](char ch) {
            return validFirst(ch) || (ch >= '0' && ch <= '9') || ch == '-' || ch == '.';
        };
        if (!validFirst(input_[offset_])) {
            return false;
        }
        ++offset_;
        while (offset_ < input_.size() && validRest(input_[offset_])) {
            ++offset_;
        }
        if (offset_ - begin > MoonlightHostLimits::kMaxXmlNameBytes) {
            issue_ = XmlIssue::Budget;
            return false;
        }
        output = input_.substr(begin, offset_ - begin);
        return true;
    }

    bool decodeEntities(const std::string& raw, std::string& output) {
        for (std::size_t index = 0; index < raw.size();) {
            if (raw[index] != '&') {
                output.push_back(raw[index++]);
                continue;
            }
            const auto end = raw.find(';', index + 1U);
            if (end == std::string::npos || end - index > 16U) {
                return false;
            }
            auto entity = raw.substr(index + 1U, end - index - 1U);
            StringWiper entityWiper(entity);
            if (entity == "amp") {
                output.push_back('&');
            } else if (entity == "lt") {
                output.push_back('<');
            } else if (entity == "gt") {
                output.push_back('>');
            } else if (entity == "apos") {
                output.push_back('\'');
            } else if (entity == "quot") {
                output.push_back('"');
            } else if (!entity.empty() && entity[0] == '#') {
                std::uint32_t codePoint = 0;
                const bool hexadecimal =
                    entity.size() > 1U && (entity[1] == 'x' || entity[1] == 'X');
                const std::size_t begin = hexadecimal ? 2U : 1U;
                if (begin == entity.size()) {
                    return false;
                }
                for (std::size_t digitIndex = begin; digitIndex < entity.size(); ++digitIndex) {
                    const char ch = entity[digitIndex];
                    std::uint32_t digit = 0;
                    if (ch >= '0' && ch <= '9') {
                        digit = static_cast<std::uint32_t>(ch - '0');
                    } else if (hexadecimal && ch >= 'a' && ch <= 'f') {
                        digit = static_cast<std::uint32_t>(ch - 'a' + 10);
                    } else if (hexadecimal && ch >= 'A' && ch <= 'F') {
                        digit = static_cast<std::uint32_t>(ch - 'A' + 10);
                    } else {
                        return false;
                    }
                    const std::uint32_t base = hexadecimal ? 16U : 10U;
                    if (codePoint > (0x10FFFFU - digit) / base) {
                        return false;
                    }
                    codePoint = codePoint * base + digit;
                }
                if (!appendUtf8(codePoint, output)) {
                    return false;
                }
            } else {
                return false;
            }
            index = end + 1U;
        }
        return true;
    }

    XmlIssue parseElement(std::size_t depth, XmlNode& node) {
        if (depth > MoonlightHostLimits::kMaxXmlDepth) {
            return XmlIssue::Budget;
        }
        if (offset_ >= input_.size() || input_[offset_] != '<' || startsWith("</") ||
            startsWith("<!") || startsWith("<?")) {
            return XmlIssue::Malformed;
        }
        ++offset_;
        if (!parseName(node.name)) {
            return issue_ == XmlIssue::None ? XmlIssue::Malformed : issue_;
        }
        if (++elements_ > MoonlightHostLimits::kMaxXmlElements) {
            return XmlIssue::Budget;
        }

        std::unordered_set<std::string> attributeNames;
        while (true) {
            const bool hadWhitespace =
                offset_ < input_.size() && isAsciiWhitespace(input_[offset_]);
            skipWhitespace();
            if (offset_ >= input_.size()) {
                return XmlIssue::Malformed;
            }
            if (startsWith("/>")) {
                offset_ += 2U;
                return XmlIssue::None;
            }
            if (input_[offset_] == '>') {
                ++offset_;
                break;
            }
            if (!hadWhitespace ||
                node.attributes.size() >= MoonlightHostLimits::kMaxAttributesPerElement) {
                return node.attributes.size() >= MoonlightHostLimits::kMaxAttributesPerElement
                           ? XmlIssue::Budget
                           : XmlIssue::Malformed;
            }
            XmlAttribute attribute;
            if (!parseName(attribute.name) || !attributeNames.insert(attribute.name).second) {
                return issue_ == XmlIssue::None ? XmlIssue::Malformed : issue_;
            }
            skipWhitespace();
            if (offset_ >= input_.size() || input_[offset_] != '=') {
                return XmlIssue::Malformed;
            }
            ++offset_;
            skipWhitespace();
            if (offset_ >= input_.size() || (input_[offset_] != '\'' && input_[offset_] != '"')) {
                return XmlIssue::Malformed;
            }
            const char quote = input_[offset_++];
            const auto end = input_.find(quote, offset_);
            if (end == std::string::npos ||
                end - offset_ > MoonlightHostLimits::kMaxAttributeBytes) {
                return end == std::string::npos ? XmlIssue::Malformed : XmlIssue::Budget;
            }
            auto raw = input_.substr(offset_, end - offset_);
            StringWiper rawWiper(raw);
            if (raw.find('<') != std::string::npos || !decodeEntities(raw, attribute.value) ||
                attribute.value.size() > MoonlightHostLimits::kMaxAttributeBytes) {
                return attribute.value.size() > MoonlightHostLimits::kMaxAttributeBytes
                           ? XmlIssue::Budget
                           : XmlIssue::Malformed;
            }
            node.attributes.push_back(std::move(attribute));
            offset_ = end + 1U;
        }

        while (offset_ < input_.size()) {
            if (startsWith("</")) {
                offset_ += 2U;
                std::string closingName;
                if (!parseName(closingName)) {
                    return issue_ == XmlIssue::None ? XmlIssue::Malformed : issue_;
                }
                skipWhitespace();
                if (closingName != node.name || offset_ >= input_.size() ||
                    input_[offset_] != '>') {
                    return XmlIssue::Malformed;
                }
                ++offset_;
                return XmlIssue::None;
            }
            if (startsWith("<!--")) {
                const auto end = input_.find("-->", offset_ + 4U);
                if (end == std::string::npos || input_.find("--", offset_ + 4U) < end) {
                    return XmlIssue::Malformed;
                }
                offset_ = end + 3U;
                continue;
            }
            if (startsWith("<!") || startsWith("<?")) {
                return XmlIssue::Malformed;
            }
            if (input_[offset_] == '<') {
                XmlNode child;
                const auto childIssue = parseElement(depth + 1U, child);
                if (childIssue != XmlIssue::None) {
                    return childIssue;
                }
                node.children.push_back(std::move(child));
                continue;
            }
            const auto end = input_.find('<', offset_);
            if (end == std::string::npos) {
                return XmlIssue::Malformed;
            }
            if (end - offset_ > MoonlightHostLimits::kMaxTextNodeBytes) {
                return XmlIssue::Budget;
            }
            auto raw = input_.substr(offset_, end - offset_);
            StringWiper rawWiper(raw);
            std::string decoded;
            StringWiper decodedWiper(decoded);
            if (!decodeEntities(raw, decoded) ||
                decoded.size() > MoonlightHostLimits::kMaxTextNodeBytes) {
                return decoded.size() > MoonlightHostLimits::kMaxTextNodeBytes
                           ? XmlIssue::Budget
                           : XmlIssue::Malformed;
            }
            node.text += decoded;
            if (node.text.size() > MoonlightHostLimits::kMaxBodyBytes) {
                return XmlIssue::Budget;
            }
            offset_ = end;
        }
        return XmlIssue::Malformed;
    }

    const std::string& input_;
    std::size_t offset_ = 0;
    std::size_t elements_ = 0;
    XmlIssue issue_ = XmlIssue::None;
};

const XmlAttribute* findAttribute(const XmlNode& node, const std::string& name) {
    const auto it = std::find_if(node.attributes.begin(), node.attributes.end(),
                                 [&](const auto& item) { return item.name == name; });
    return it == node.attributes.end() ? nullptr : &*it;
}

const XmlNode* findUniqueChild(const XmlNode& root, const std::string& name, bool& duplicate) {
    const XmlNode* found = nullptr;
    for (const auto& child : root.children) {
        if (child.name != name) {
            continue;
        }
        if (found != nullptr) {
            duplicate = true;
            return nullptr;
        }
        found = &child;
    }
    return found;
}

bool scalarText(const XmlNode* node, std::string& output, std::size_t budget) {
    if (node == nullptr || !node->children.empty()) {
        return false;
    }
    output = trimAscii(node->text);
    return output.size() <= budget;
}

MoonlightHostError parseRoot(const std::string& body, XmlNode& root,
                             std::optional<std::int32_t>& status) {
    const auto issue = StrictXmlParser(body).parse(root);
    if (issue == XmlIssue::Budget) {
        return MoonlightHostError::XmlBudgetExceeded;
    }
    if (issue != XmlIssue::None || root.name != "root") {
        return MoonlightHostError::MalformedXml;
    }
    const auto* attribute = findAttribute(root, "status_code");
    if (attribute == nullptr) {
        return MoonlightHostError::MissingRequiredField;
    }
    std::uint32_t unsignedStatus = 0;
    if (!parseUnsigned(attribute->value, unsignedStatus)) {
        return MoonlightHostError::InvalidField;
    }
    const std::int64_t signedValue =
        unsignedStatus <= static_cast<std::uint32_t>(std::numeric_limits<std::int32_t>::max())
            ? static_cast<std::int64_t>(unsignedStatus)
            : static_cast<std::int64_t>(unsignedStatus) - 0x100000000LL;
    status = static_cast<std::int32_t>(signedValue);
    if (*status == 503 || *status == 599) {
        return MoonlightHostError::HostBusy;
    }
    return *status == 200 ? MoonlightHostError::None : MoonlightHostError::XmlStatusRejected;
}

MoonlightHostError requiredText(const XmlNode& root, const std::string& name, std::string& output,
                                std::size_t budget = kMaxServerFieldBytes) {
    bool duplicate = false;
    const auto* node = findUniqueChild(root, name, duplicate);
    if (duplicate) {
        return MoonlightHostError::InvalidField;
    }
    if (node == nullptr) {
        return MoonlightHostError::MissingRequiredField;
    }
    if (!scalarText(node, output, budget) || output.empty()) {
        return MoonlightHostError::InvalidField;
    }
    return MoonlightHostError::None;
}

MoonlightHostError optionalText(const XmlNode& root, const std::string& name,
                                std::optional<std::string>& output,
                                std::size_t budget = kMaxServerFieldBytes) {
    bool duplicate = false;
    const auto* node = findUniqueChild(root, name, duplicate);
    if (duplicate) {
        return MoonlightHostError::InvalidField;
    }
    if (node == nullptr) {
        output.reset();
        return MoonlightHostError::None;
    }
    std::string value;
    if (!scalarText(node, value, budget) || value.empty()) {
        return MoonlightHostError::InvalidField;
    }
    output = std::move(value);
    return MoonlightHostError::None;
}

template <typename Unsigned>
MoonlightHostError optionalUnsigned(const XmlNode& root, const std::string& name,
                                    std::optional<Unsigned>& output) {
    std::optional<std::string> text;
    const auto error = optionalText(root, name, text);
    if (error != MoonlightHostError::None || !text.has_value()) {
        return error;
    }
    Unsigned parsed = 0;
    if (!parseUnsigned(*text, parsed)) {
        return MoonlightHostError::InvalidField;
    }
    output = parsed;
    return MoonlightHostError::None;
}

MoonlightHostError parseVersion(const std::string& value,
                                std::array<std::int32_t, 4>& parts) {
    std::size_t begin = 0;
    for (std::size_t index = 0; index < parts.size(); ++index) {
        const auto end = index + 1U == parts.size() ? value.size() : value.find('.', begin);
        if (end == std::string::npos || end == begin) {
            return MoonlightHostError::InvalidField;
        }
        const bool negative = value[begin] == '-';
        if (negative && index + 1U != parts.size()) {
            return MoonlightHostError::InvalidField;
        }
        const std::size_t digitsBegin = negative ? begin + 1U : begin;
        if (digitsBegin == end || end - digitsBegin > 6U) {
            return MoonlightHostError::InvalidField;
        }
        std::int32_t magnitude = 0;
        for (std::size_t cursor = digitsBegin; cursor < end; ++cursor) {
            const unsigned char character =
                static_cast<unsigned char>(value[cursor]);
            if (character < '0' || character > '9') {
                return MoonlightHostError::InvalidField;
            }
            magnitude = magnitude * 10 + static_cast<std::int32_t>(character - '0');
        }
        parts[index] = negative ? -magnitude : magnitude;
        begin = end + 1U;
    }
    return begin == value.size() + 1U ? MoonlightHostError::None : MoonlightHostError::InvalidField;
}

MoonlightHostError parseServerInfo(const XmlNode& root, MoonlightServerInfo& info) {
    MoonlightHostError error = requiredText(root, "uniqueid", info.uniqueId, 256U);
    if (error != MoonlightHostError::None)
        return error;
    error = requiredText(root, "appversion", info.appVersion, 64U);
    if (error != MoonlightHostError::None)
        return error;
    error = parseVersion(info.appVersion, info.appVersionParts);
    if (error != MoonlightHostError::None)
        return error;
    error = requiredText(root, "state", info.state, 256U);
    if (error != MoonlightHostError::None)
        return error;

    std::string pairStatus;
    error = requiredText(root, "PairStatus", pairStatus, 8U);
    if (error != MoonlightHostError::None)
        return error;
    if (pairStatus != "0" && pairStatus != "1") {
        return MoonlightHostError::InvalidField;
    }
    info.paired = pairStatus == "1";

    std::string currentGame;
    error = requiredText(root, "currentgame", currentGame, 16U);
    if (error != MoonlightHostError::None || !parseUnsigned(currentGame, info.currentGame)) {
        return error == MoonlightHostError::None ? MoonlightHostError::InvalidField : error;
    }
    // Since GFE 2.8, currentgame may retain the last launched app while the
    // server is idle. Match official Moonlight semantics and only treat it as
    // authoritative while the server state explicitly reports BUSY.
    constexpr const char* kBusySuffix = "_SERVER_BUSY";
    constexpr std::size_t kBusySuffixLength = 12U;
    if (info.state.size() < kBusySuffixLength ||
        info.state.compare(info.state.size() - kBusySuffixLength,
                           kBusySuffixLength, kBusySuffix) != 0) {
        info.currentGame = 0U;
    }

    if ((error = optionalText(root, "hostname", info.hostName)) != MoonlightHostError::None ||
        (error = optionalText(root, "GfeVersion", info.gfeVersion)) != MoonlightHostError::None ||
        (error = optionalText(root, "gputype", info.gpuType)) != MoonlightHostError::None ||
        (error = optionalText(root, "LocalIP", info.localAddress, 255U)) !=
            MoonlightHostError::None ||
        (error = optionalText(root, "ExternalIP", info.externalAddress, 255U)) !=
            MoonlightHostError::None ||
        (error = optionalUnsigned(root, "HttpsPort", info.httpsPort)) != MoonlightHostError::None ||
        (error = optionalUnsigned(root, "ExternalPort", info.externalPort)) !=
            MoonlightHostError::None ||
        (error = optionalUnsigned(root, "MaxLumaPixelsH264", info.maxLumaPixelsH264)) !=
            MoonlightHostError::None ||
        (error = optionalUnsigned(root, "MaxLumaPixelsHEVC", info.maxLumaPixelsHevc)) !=
            MoonlightHostError::None ||
        (error = optionalUnsigned(root, "ServerCodecModeSupport", info.codecModeSupport)) !=
            MoonlightHostError::None) {
        return error;
    }
    if ((info.httpsPort.has_value() && *info.httpsPort == 0U) ||
        (info.externalPort.has_value() && *info.externalPort == 0U)) {
        return MoonlightHostError::InvalidField;
    }
    return MoonlightHostError::None;
}

MoonlightHostError parseApps(const XmlNode& root, std::vector<MoonlightAppEntry>& apps,
                             std::size_t& partialCount) {
    std::unordered_set<std::uint32_t> ids;
    for (const auto& child : root.children) {
        if (child.name != "App") {
            continue;
        }
        if (apps.size() + partialCount >= MoonlightHostLimits::kMaxApps) {
            return MoonlightHostError::XmlBudgetExceeded;
        }
        bool duplicate = false;
        const auto* idNode = findUniqueChild(child, "ID", duplicate);
        if (duplicate)
            return MoonlightHostError::InvalidField;
        const auto* titleNode = findUniqueChild(child, "AppTitle", duplicate);
        if (duplicate)
            return MoonlightHostError::InvalidField;
        std::string idText;
        std::string title;
        std::uint32_t id = 0;
        const bool validId =
            scalarText(idNode, idText, 16U) && parseUnsigned(idText, id) && id != 0U;
        if (validId && !ids.insert(id).second) {
            return MoonlightHostError::DuplicateApp;
        }
        if (titleNode != nullptr &&
            trimAscii(titleNode->text).size() > MoonlightHostLimits::kMaxAppTitleBytes) {
            return MoonlightHostError::XmlBudgetExceeded;
        }
        const bool validTitle =
            scalarText(titleNode, title, MoonlightHostLimits::kMaxAppTitleBytes);
        // Sunshine may intentionally publish a nameless application as
        // <AppTitle/>. Official Moonlight clients retain that entry because
        // the numeric ID remains launchable. Keep our non-empty model
        // invariant with a deterministic, local-only display fallback rather
        // than invalidating the complete authenticated catalog.
        if (validId && validTitle && title.empty()) {
            title = "Application " + std::to_string(id);
        }
        if (!validId || !validTitle) {
            ++partialCount;
            continue;
        }
        MoonlightAppEntry app;
        app.id = id;
        app.title = std::move(title);
        const auto* hdrNode = findUniqueChild(child, "IsHdrSupported", duplicate);
        if (duplicate)
            return MoonlightHostError::InvalidField;
        if (hdrNode != nullptr) {
            std::string hdr;
            if (!scalarText(hdrNode, hdr, 8U) || (hdr != "0" && hdr != "1")) {
                return MoonlightHostError::InvalidField;
            }
            app.hdrSupported = hdr == "1";
        }
        apps.push_back(std::move(app));
    }
    return MoonlightHostError::None;
}

MoonlightHostError parsePairing(const XmlNode& root, MoonlightPairingPayload& payload) {
    std::optional<std::string> paired;
    auto error = optionalText(root, "paired", paired, 8U);
    if (error != MoonlightHostError::None)
        return error;
    if (!paired.has_value() || (*paired != "0" && *paired != "1")) {
        return paired.has_value() ? MoonlightHostError::InvalidField
                                  : MoonlightHostError::MissingRequiredField;
    }
    payload.paired = *paired == "1";
    if ((error = optionalText(root, "plaincert", payload.plainCertificateHex,
                              kMaxPairingFieldBytes)) != MoonlightHostError::None ||
        (error = optionalText(root, "challengeresponse", payload.challengeResponseHex,
                              kMaxPairingFieldBytes)) != MoonlightHostError::None ||
        (error = optionalText(root, "pairingsecret", payload.pairingSecretHex,
                              kMaxPairingFieldBytes)) != MoonlightHostError::None) {
        return error;
    }
    for (const auto* value :
         {&payload.plainCertificateHex, &payload.challengeResponseHex, &payload.pairingSecretHex}) {
        if (value->has_value() && !isHex(**value, true)) {
            return MoonlightHostError::InvalidField;
        }
    }
    return MoonlightHostError::None;
}

MoonlightHostError parseAction(const XmlNode& root, MoonlightHostOperation operation,
                               MoonlightActionResult& action) {
    if (operation == MoonlightHostOperation::Unpair) {
        action.accepted = true;
        return MoonlightHostError::None;
    }
    const char* field = operation == MoonlightHostOperation::Launch   ? "gamesession"
                        : operation == MoonlightHostOperation::Resume ? "resume"
                                                                      : "cancel";
    std::string value;
    auto error = requiredText(root, field, value, 16U);
    std::uint32_t parsed = 0;
    if (error != MoonlightHostError::None || !parseUnsigned(value, parsed)) {
        return error == MoonlightHostError::None ? MoonlightHostError::InvalidField : error;
    }
    action.accepted = parsed != 0U;
    if (operation == MoonlightHostOperation::Launch ||
        operation == MoonlightHostOperation::Resume) {
        error = optionalText(root, "sessionUrl0", action.rtspSessionUrl, 4096U);
        if (error != MoonlightHostError::None)
            return error;
        if (action.rtspSessionUrl.has_value() &&
            action.rtspSessionUrl->compare(0, 7U, "rtsp://") != 0 &&
            action.rtspSessionUrl->compare(0, 10U, "rtspenc://") != 0) {
            return MoonlightHostError::InvalidField;
        }
    }
    return MoonlightHostError::None;
}

MoonlightHostError mapTransportError(MoonlightTransportError error) noexcept {
    switch (error) {
    case MoonlightTransportError::None:
        return MoonlightHostError::None;
    case MoonlightTransportError::DnsFailure:
        return MoonlightHostError::DnsFailure;
    case MoonlightTransportError::ConnectFailure:
        return MoonlightHostError::ConnectFailure;
    case MoonlightTransportError::TlsVersionFailure:
        return MoonlightHostError::TlsVersionFailure;
    case MoonlightTransportError::TlsChainFailure:
        return MoonlightHostError::TlsChainFailure;
    case MoonlightTransportError::TrustConflict:
        return MoonlightHostError::TrustConflict;
    case MoonlightTransportError::Timeout:
        return MoonlightHostError::DeadlineExceeded;
    case MoonlightTransportError::Cancelled:
        return MoonlightHostError::Cancelled;
    case MoonlightTransportError::BodyTooLarge:
        return MoonlightHostError::BodyTooLarge;
    case MoonlightTransportError::ProtocolFailure:
        return MoonlightHostError::TransportFailure;
    }
    return MoonlightHostError::TransportFailure;
}

MoonlightHostError dispositionError(const std::shared_ptr<ActiveRequest>& state) noexcept {
    switch (state->disposition.load(std::memory_order_acquire)) {
    case RequestDisposition::Active:
        return MoonlightHostError::None;
    case RequestDisposition::Cancelled:
        return MoonlightHostError::Cancelled;
    case RequestDisposition::Stale:
        return MoonlightHostError::StaleRequest;
    }
    return MoonlightHostError::StaleRequest;
}

std::string endpointPortCacheKey(const MoonlightHostEndpoint& endpoint) {
    std::string key = lowerAscii(endpoint.serverName) + ":" +
        std::to_string(endpoint.httpPort);
    for (const auto& address : endpoint.addresses) {
        key.push_back('|');
        key += std::to_string(static_cast<unsigned>(address.family));
        key.push_back(':');
        key += lowerAscii(address.value);
        key.push_back('%');
        key += address.scope;
    }
    return key;
}

struct HostApiState {
    HostApiState(std::shared_ptr<MoonlightHostTransport> valueTransport,
                 MoonlightHostApi::UuidGenerator valueUuidGenerator)
        : transport(std::move(valueTransport)), uuidGenerator(std::move(valueUuidGenerator)) {}

    std::mutex mutex;
    std::condition_variable cv;
    std::unordered_map<MoonlightHostRequestKey, std::shared_ptr<ActiveRequest>, RequestKeyHash>
        active;
    std::unordered_map<std::string, std::uint16_t> learnedHttpsPorts;
    std::shared_ptr<MoonlightHostTransport> transport;
    MoonlightHostApi::UuidGenerator uuidGenerator;
    bool shuttingDown = false;

    std::optional<std::uint16_t> learnedHttpsPort(
        const MoonlightHostEndpoint& endpoint) {
        std::lock_guard<std::mutex> lock(mutex);
        const auto iterator = learnedHttpsPorts.find(endpointPortCacheKey(endpoint));
        return iterator == learnedHttpsPorts.end() ? std::nullopt :
            std::optional<std::uint16_t>(iterator->second);
    }

    void rememberHttpsPort(const MoonlightHostEndpoint& endpoint,
                           std::uint16_t port) {
        if (port == 0U) {
            return;
        }
        std::lock_guard<std::mutex> lock(mutex);
        const auto key = endpointPortCacheKey(endpoint);
        if (learnedHttpsPorts.size() >= kMaxLearnedHttpsPorts &&
            learnedHttpsPorts.find(key) == learnedHttpsPorts.end()) {
            learnedHttpsPorts.erase(learnedHttpsPorts.begin());
        }
        learnedHttpsPorts[key] = port;
    }
};

} // namespace

struct MoonlightHostApi::Impl final : HostApiState {
    using HostApiState::HostApiState;
};

MoonlightTransportRequest::MoonlightTransportRequest(
    MoonlightHostRequestKey key, MoonlightHostOperation operation, MoonlightHostScheme scheme,
    MoonlightHostAddressFamily family, std::string connectAddress, std::string serverName,
    std::uint16_t port, std::string path, std::string url, bool requiresClientIdentity,
    bool requiresServerPin, std::size_t responseBudget)
    : key_(key), operation_(operation), scheme_(scheme), family_(family),
      connectAddress_(std::move(connectAddress)), serverName_(std::move(serverName)), port_(port),
      path_(std::move(path)), url_(std::move(url)), requiresClientIdentity_(requiresClientIdentity),
      requiresServerPin_(requiresServerPin), responseBudget_(responseBudget) {}

MoonlightTransportRequest::~MoonlightTransportRequest() { secureWipeString(url_); }

const MoonlightHostRequestKey& MoonlightTransportRequest::key() const noexcept { return key_; }
MoonlightHostOperation MoonlightTransportRequest::operation() const noexcept { return operation_; }
MoonlightHostScheme MoonlightTransportRequest::scheme() const noexcept { return scheme_; }
MoonlightHostAddressFamily MoonlightTransportRequest::family() const noexcept { return family_; }
const std::string& MoonlightTransportRequest::connectAddress() const noexcept {
    return connectAddress_;
}
const std::string& MoonlightTransportRequest::serverName() const noexcept { return serverName_; }
std::uint16_t MoonlightTransportRequest::port() const noexcept { return port_; }
const std::string& MoonlightTransportRequest::method() const noexcept { return method_; }
const std::string& MoonlightTransportRequest::path() const noexcept { return path_; }
const std::string& MoonlightTransportRequest::url() const noexcept { return url_; }
bool MoonlightTransportRequest::requiresClientIdentity() const noexcept {
    return requiresClientIdentity_;
}
bool MoonlightTransportRequest::requiresServerPin() const noexcept { return requiresServerPin_; }
bool MoonlightTransportRequest::redirectsAllowed() const noexcept { return false; }
bool MoonlightTransportRequest::proxyAllowed() const noexcept { return false; }
std::size_t MoonlightTransportRequest::responseBudget() const noexcept { return responseBudget_; }

std::string MoonlightTransportRequest::redactedDebugString() const {
    std::ostringstream stream;
    stream << method_ << ' ' << (scheme_ == MoonlightHostScheme::Https ? "https" : "http")
           << "://<host>:" << port_ << path_;
    const auto query = url_.find('?');
    if (query == std::string::npos) {
        return stream.str();
    }
    stream << '?';
    std::size_t begin = query + 1U;
    bool first = true;
    while (begin < url_.size()) {
        const auto equals = url_.find('=', begin);
        if (equals == std::string::npos) {
            break;
        }
        const auto end = url_.find('&', equals + 1U);
        if (!first)
            stream << '&';
        stream << url_.substr(begin, equals - begin) << "=<redacted>";
        first = false;
        if (end == std::string::npos)
            break;
        begin = end + 1U;
    }
    return stream.str();
}

MoonlightHostApi::MoonlightHostApi(std::shared_ptr<MoonlightHostTransport> transport,
                                   UuidGenerator uuidGenerator)
    : impl_(std::make_shared<Impl>(std::move(transport), std::move(uuidGenerator))) {}

MoonlightHostApi::~MoonlightHostApi() {
    auto impl =
        std::atomic_exchange_explicit(&impl_, std::shared_ptr<Impl>{}, std::memory_order_acq_rel);
    if (impl == nullptr) {
        return;
    }
    std::unique_lock<std::mutex> lock(impl->mutex);
    impl->shuttingDown = true;
    for (auto& item : impl->active) {
        item.second->disposition.store(RequestDisposition::Cancelled, std::memory_order_release);
    }
    impl->cv.wait(lock, [&]() { return impl->active.empty(); });
}

namespace {

class RequestLease final {
public:
    RequestLease(std::shared_ptr<HostApiState> impl, std::shared_ptr<ActiveRequest> state)
        : impl_(std::move(impl)), state_(std::move(state)) {}

    ~RequestLease() {
        if (impl_ == nullptr || state_ == nullptr)
            return;
        std::lock_guard<std::mutex> lock(impl_->mutex);
        const auto it = impl_->active.find(state_->key);
        if (it != impl_->active.end() && it->second == state_) {
            impl_->active.erase(it);
        }
        impl_->cv.notify_all();
    }

private:
    std::shared_ptr<HostApiState> impl_;
    std::shared_ptr<ActiveRequest> state_;
};

MoonlightHostResult executeRegistered(const std::shared_ptr<HostApiState>& impl,
                                      const std::shared_ptr<ActiveRequest>& state,
                                      const MoonlightHostCall& call,
                                      const QueryShape& initialShape) {
    MoonlightHostResult invalid;
    invalid.key = call.key;
    invalid.error = validateCall(call, initialShape);
    if (invalid.error != MoonlightHostError::None) {
        return invalid;
    }

    const auto started = std::chrono::steady_clock::now();
    const auto deadline = started + call.timeout;
    const auto runScheme = [&](MoonlightHostScheme scheme, MoonlightHostOperation requestOperation,
                               QueryShape shape,
                               std::optional<std::uint16_t> candidateHttpsPort) {
        MoonlightHostResult result;
        result.key = call.key;
        result.error = MoonlightHostError::TransportFailure;
        shape.scheme = scheme;
        const std::uint16_t port = scheme == MoonlightHostScheme::Https ?
            candidateHttpsPort.value_or(
                impl->learnedHttpsPort(call.endpoint).value_or(call.endpoint.httpsPort)) :
            call.endpoint.httpPort;
        if (requestOperation == MoonlightHostOperation::ServerInfo) {
            shape.requiresClientIdentity = scheme == MoonlightHostScheme::Https;
            shape.requiresServerPin = scheme == MoonlightHostScheme::Https;
        }

        for (std::size_t attempt = 0; attempt < call.endpoint.addresses.size(); ++attempt) {
            MoonlightHostDiagnostic diagnostic;
            diagnostic.operation = requestOperation;
            diagnostic.attemptIndex = attempt;
            diagnostic.family = call.endpoint.addresses[attempt].family;
            diagnostic.port = port;
            diagnostic.maskedEndpoint = maskedEndpoint(scheme, port, shape.path);
            const auto attemptStarted = std::chrono::steady_clock::now();

            auto stateError = dispositionError(state);
            if (stateError != MoonlightHostError::None || attemptStarted >= deadline) {
                diagnostic.code = stateError != MoonlightHostError::None
                                      ? stateError
                                      : MoonlightHostError::DeadlineExceeded;
                diagnostic.stage = MoonlightTransportStage::None;
                diagnostic.duration = std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::steady_clock::now() - attemptStarted);
                result.diagnostics.push_back(std::move(diagnostic));
                result.error = result.diagnostics.back().code;
                return result;
            }

            std::string uuid;
            try {
                uuid = impl->uuidGenerator();
            } catch (...) {
                diagnostic.code = MoonlightHostError::InternalFailure;
                result.diagnostics.push_back(std::move(diagnostic));
                result.error = MoonlightHostError::InternalFailure;
                return result;
            }
            std::string url;
            StringWiper urlWiper(url);
            const auto urlError =
                buildUrl(call.endpoint.addresses[attempt], scheme, port, shape, uuid, url);
            if (urlError != MoonlightHostError::None) {
                diagnostic.code = urlError;
                result.diagnostics.push_back(std::move(diagnostic));
                result.error = urlError;
                return result;
            }

            MoonlightTransportRequest request(
                call.key, requestOperation, scheme, call.endpoint.addresses[attempt].family,
                transportHostFor(call.endpoint.addresses[attempt]), call.endpoint.serverName,
                port, shape.path,
                std::move(url), shape.requiresClientIdentity, shape.requiresServerPin,
                MoonlightHostLimits::kMaxBodyBytes);
            MoonlightTransportOutcome outcome;
            StringWiper outcomeBodyWiper(outcome.body);
            try {
                outcome = impl->transport->execute(request, deadline, [state]() {
                    return dispositionError(state) != MoonlightHostError::None;
                });
            } catch (...) {
                outcome.error = MoonlightTransportError::ProtocolFailure;
                outcome.stage = MoonlightTransportStage::Http;
                outcome.sendState = MoonlightTransportSendState::SentResponseUnknown;
            }

            diagnostic.stage = outcome.stage;
            diagnostic.sendState = outcome.sendState;
            diagnostic.httpStatus = outcome.httpStatus;
            diagnostic.byteCount = std::max(outcome.receivedBodyBytes, outcome.body.size());
            diagnostic.duration = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - attemptStarted);
            result.httpStatus = outcome.httpStatus;

            stateError = dispositionError(state);
            if (stateError != MoonlightHostError::None ||
                std::chrono::steady_clock::now() >= deadline) {
                diagnostic.code = stateError != MoonlightHostError::None
                                      ? stateError
                                      : MoonlightHostError::DeadlineExceeded;
                result.diagnostics.push_back(std::move(diagnostic));
                result.error = result.diagnostics.back().code;
                return result;
            }

            if (outcome.receivedBodyBytes > MoonlightHostLimits::kMaxBodyBytes ||
                outcome.body.size() > MoonlightHostLimits::kMaxBodyBytes) {
                outcome.error = MoonlightTransportError::BodyTooLarge;
                outcome.stage = MoonlightTransportStage::Body;
                diagnostic.stage = outcome.stage;
            }
            if (outcome.error != MoonlightTransportError::None) {
                auto error = mapTransportError(outcome.error);
                if (!shape.readOnly && outcome.sendState != MoonlightTransportSendState::NotSent) {
                    error = MoonlightHostError::ActionUnknown;
                }
                diagnostic.code = error;
                result.diagnostics.push_back(std::move(diagnostic));
                result.error = error;
                const bool canRetry =
                    attempt + 1U < call.endpoint.addresses.size() &&
                    (shape.readOnly || outcome.sendState == MoonlightTransportSendState::NotSent) &&
                    error != MoonlightHostError::TrustConflict &&
                    error != MoonlightHostError::Cancelled &&
                    error != MoonlightHostError::StaleRequest &&
                    error != MoonlightHostError::DeadlineExceeded &&
                    error != MoonlightHostError::BodyTooLarge;
                if (canRetry) {
                    continue;
                }
                if (error == MoonlightHostError::ActionUnknown) {
                    MoonlightActionResult action;
                    action.outcomeUnknown = true;
                    result.action = action;
                    result.mutationOutcomeUnknown = true;
                }
                return result;
            }

            if (outcome.httpStatus < 200 || outcome.httpStatus >= 300) {
                const auto error = outcome.httpStatus == 401 ? MoonlightHostError::HttpUnauthorized
                                   : outcome.httpStatus == 404 ? MoonlightHostError::HttpNotFound
                                                               : MoonlightHostError::HttpFailure;
                diagnostic.code = error;
                result.diagnostics.push_back(std::move(diagnostic));
                result.error = error;
                return result;
            }

            if (!shape.xmlResponse) {
                stateError = dispositionError(state);
                if (stateError != MoonlightHostError::None ||
                    std::chrono::steady_clock::now() >= deadline) {
                    diagnostic.code = stateError != MoonlightHostError::None
                                          ? stateError
                                          : MoonlightHostError::DeadlineExceeded;
                    diagnostic.stage = MoonlightTransportStage::Commit;
                    result.diagnostics.push_back(std::move(diagnostic));
                    result.error = result.diagnostics.back().code;
                    return result;
                }
                result.asset.assign(outcome.body.begin(), outcome.body.end());
                result.resolvedAddress = outcome.resolvedAddress.empty()
                    ? transportHostFor(call.endpoint.addresses[attempt]) : outcome.resolvedAddress;
                result.resolvedFamily = outcome.resolvedFamily ==
                    MoonlightHostAddressFamily::Unspecified
                    ? call.endpoint.addresses[attempt].family : outcome.resolvedFamily;
                diagnostic.code = MoonlightHostError::None;
                diagnostic.stage = MoonlightTransportStage::Complete;
                result.diagnostics.push_back(std::move(diagnostic));
                result.error = MoonlightHostError::None;
                return result;
            }

            XmlNode root;
            std::optional<std::int32_t> xmlStatus;
            auto error = parseRoot(outcome.body, root, xmlStatus);
            result.xmlStatus = xmlStatus;
            diagnostic.xmlStatus = xmlStatus;
            diagnostic.stage = MoonlightTransportStage::Parse;
            if (error == MoonlightHostError::None) {
                switch (requestOperation) {
                case MoonlightHostOperation::ServerInfo: {
                    MoonlightServerInfo info;
                    error = parseServerInfo(root, info);
                    if (error == MoonlightHostError::None)
                        result.serverInfo = std::move(info);
                    break;
                }
                case MoonlightHostOperation::AppList:
                    error = parseApps(root, result.apps, result.partialAppCount);
                    break;
                case MoonlightHostOperation::Pair:
                case MoonlightHostOperation::PairChallenge: {
                    MoonlightPairingPayload pairing;
                    error = parsePairing(root, pairing);
                    if (error == MoonlightHostError::None)
                        result.pairing = std::move(pairing);
                    break;
                }
                case MoonlightHostOperation::Unpair:
                case MoonlightHostOperation::Launch:
                case MoonlightHostOperation::Resume:
                case MoonlightHostOperation::Cancel: {
                    MoonlightActionResult action;
                    error = parseAction(root, requestOperation, action);
                    if (error == MoonlightHostError::None)
                        result.action = std::move(action);
                    break;
                }
                case MoonlightHostOperation::AppAsset:
                    error = MoonlightHostError::InternalFailure;
                    break;
                }
            }
            if (error != MoonlightHostError::None) {
                // Business parsing is transactional. A late duplicate or
                // malformed field invalidates the entire response rather than
                // leaking an apparently usable prefix to the caller.
                result.serverInfo.reset();
                result.apps.clear();
                result.partialAppCount = 0;
                result.pairing.reset();
                result.action.reset();
                if (!shape.readOnly && error != MoonlightHostError::XmlStatusRejected &&
                    error != MoonlightHostError::HostBusy) {
                    result.mutationOutcomeUnknown = true;
                }
                diagnostic.code = error;
                result.diagnostics.push_back(std::move(diagnostic));
                result.error = error;
                return result;
            }

            stateError = dispositionError(state);
            if (stateError != MoonlightHostError::None ||
                std::chrono::steady_clock::now() >= deadline) {
                diagnostic.code = stateError != MoonlightHostError::None
                                      ? stateError
                                      : MoonlightHostError::DeadlineExceeded;
                diagnostic.stage = MoonlightTransportStage::Commit;
                result.serverInfo.reset();
                result.apps.clear();
                result.pairing.reset();
                result.action.reset();
                result.diagnostics.push_back(std::move(diagnostic));
                result.error = result.diagnostics.back().code;
                return result;
            }

            diagnostic.code = MoonlightHostError::None;
            diagnostic.stage = MoonlightTransportStage::Complete;
            result.resolvedAddress = outcome.resolvedAddress.empty()
                ? transportHostFor(call.endpoint.addresses[attempt]) : outcome.resolvedAddress;
            result.resolvedFamily = outcome.resolvedFamily ==
                MoonlightHostAddressFamily::Unspecified
                ? call.endpoint.addresses[attempt].family : outcome.resolvedFamily;
            result.diagnostics.push_back(std::move(diagnostic));
            result.error = MoonlightHostError::None;
            if (requestOperation == MoonlightHostOperation::ServerInfo &&
                result.serverInfo.has_value() && result.serverInfo->httpsPort.has_value() &&
                (scheme == MoonlightHostScheme::Https ||
                 !call.endpoint.pinnedTrustAvailable)) {
                impl->rememberHttpsPort(call.endpoint, *result.serverInfo->httpsPort);
            }
            return result;
        }
        return result;
    };

    if (call.operation == MoonlightHostOperation::ServerInfo) {
        if (!call.endpoint.pinnedTrustAvailable) {
            return runScheme(MoonlightHostScheme::Http, call.operation, initialShape,
                             std::nullopt);
        }
        if (call.endpoint.httpPort != kDefaultHttpPort &&
            !impl->learnedHttpsPort(call.endpoint).has_value()) {
            auto candidate = runScheme(MoonlightHostScheme::Http, call.operation, initialShape,
                                       std::nullopt);
            if (candidate.ok() && candidate.serverInfo.has_value()) {
                const auto candidatePort = candidate.serverInfo->httpsPort.value_or(
                    call.endpoint.httpsPort);
                auto secure = runScheme(MoonlightHostScheme::Https, call.operation, initialShape,
                                        candidatePort);
                secure.diagnostics.insert(secure.diagnostics.begin(),
                                          candidate.diagnostics.begin(),
                                          candidate.diagnostics.end());
                if (secure.error == MoonlightHostError::HttpUnauthorized &&
                    call.endpoint.allowHttpPairingCandidate) {
                    // The host still presents the pinned certificate but no
                    // longer accepts this client identity. Reuse the already
                    // parsed HTTP serverinfo only for the explicit pairing
                    // lane so repair can restart without treating plaintext
                    // metadata as authenticated Host Control state.
                    candidate.candidateOnly = true;
                    candidate.diagnostics = std::move(secure.diagnostics);
                    return candidate;
                }
                if (secure.error == MoonlightHostError::TrustConflict &&
                    call.endpoint.allowHttpPairingCandidate) {
                    secure.serverInfo = std::move(candidate.serverInfo);
                    secure.httpStatus = candidate.httpStatus;
                    secure.xmlStatus = candidate.xmlStatus;
                    secure.resolvedAddress = std::move(candidate.resolvedAddress);
                    secure.resolvedFamily = candidate.resolvedFamily;
                    secure.candidateOnly = true;
                }
                return secure;
            }
        }
        auto secure = runScheme(MoonlightHostScheme::Https, call.operation, initialShape,
                                std::nullopt);
        if (secure.error == MoonlightHostError::HttpUnauthorized &&
            call.endpoint.allowHttpPairingCandidate) {
            auto candidate = runScheme(MoonlightHostScheme::Http, call.operation,
                                       initialShape, std::nullopt);
            candidate.diagnostics.insert(candidate.diagnostics.begin(),
                                         secure.diagnostics.begin(),
                                         secure.diagnostics.end());
            if (candidate.ok() && candidate.serverInfo.has_value()) {
                candidate.candidateOnly = true;
                return candidate;
            }
            return candidate;
        }
        if (secure.error != MoonlightHostError::TrustConflict ||
            !call.endpoint.allowHttpPairingCandidate) {
            return secure;
        }
        auto candidate = runScheme(MoonlightHostScheme::Http, call.operation, initialShape,
                                   std::nullopt);
        secure.diagnostics.insert(secure.diagnostics.end(), candidate.diagnostics.begin(),
                                  candidate.diagnostics.end());
        if (candidate.ok() && candidate.serverInfo.has_value()) {
            secure.serverInfo = std::move(candidate.serverInfo);
            secure.httpStatus = candidate.httpStatus;
            secure.xmlStatus = candidate.xmlStatus;
            secure.resolvedAddress = std::move(candidate.resolvedAddress);
            secure.resolvedFamily = candidate.resolvedFamily;
            secure.candidateOnly = true;
        }
        secure.error = MoonlightHostError::TrustConflict;
        return secure;
    }
    auto primary = runScheme(initialShape.scheme, call.operation, initialShape, std::nullopt);
    if (call.operation != MoonlightHostOperation::Cancel || !primary.ok() ||
        !primary.action.has_value() || !primary.action->accepted) {
        return primary;
    }

    // NvHTTP verifies quit/cancel with an authenticated serverinfo request.
    // Sunshine can acknowledge /cancel even when another client's session is
    // still active; exposing success before this check would be false truth.
    QueryShape verificationShape;
    verificationShape.path = "/serverinfo";
    verificationShape.scheme = MoonlightHostScheme::Https;
    verificationShape.requiresClientIdentity = true;
    verificationShape.requiresServerPin = true;
    verificationShape.readOnly = true;
    auto verification = runScheme(MoonlightHostScheme::Https, MoonlightHostOperation::ServerInfo,
                                  verificationShape, std::nullopt);
    primary.diagnostics.insert(primary.diagnostics.end(), verification.diagnostics.begin(),
                               verification.diagnostics.end());
    if (!verification.ok() || !verification.serverInfo.has_value()) {
        const auto verificationError = verification.error;
        if (verificationError == MoonlightHostError::Cancelled ||
            verificationError == MoonlightHostError::StaleRequest ||
            verificationError == MoonlightHostError::TrustConflict) {
            primary.error = verificationError;
        } else {
            primary.error = MoonlightHostError::ActionUnknown;
        }
        primary.action->accepted = false;
        primary.action->outcomeUnknown = true;
        primary.mutationOutcomeUnknown = true;
        return primary;
    }
    const auto& info = *verification.serverInfo;
    constexpr const char* kBusySuffix = "_SERVER_BUSY";
    const bool reportsBusy =
        info.state.size() >= std::char_traits<char>::length(kBusySuffix) &&
        info.state.compare(info.state.size() - std::char_traits<char>::length(kBusySuffix),
                           std::char_traits<char>::length(kBusySuffix), kBusySuffix) == 0;
    if (reportsBusy && info.currentGame != 0U) {
        primary.error = MoonlightHostError::HostBusy;
        primary.action->accepted = false;
    }
    return primary;
}

} // namespace

MoonlightHostError MoonlightHostApi::validate(const MoonlightHostCall& call) const noexcept {
    try {
        const auto impl = std::atomic_load_explicit(&impl_, std::memory_order_acquire);
        if (impl == nullptr) {
            return MoonlightHostError::ShuttingDown;
        }
        const auto shape = makeQueryShape(call);
        const auto error = validateCall(call, shape);
        if (error != MoonlightHostError::None) {
            return error;
        }
        return impl->transport != nullptr && impl->uuidGenerator
                   ? MoonlightHostError::None
                   : MoonlightHostError::InvalidRequest;
    } catch (...) {
        return MoonlightHostError::InternalFailure;
    }
}

MoonlightHostResult MoonlightHostApi::execute(const MoonlightHostCall& call) noexcept {
    MoonlightHostResult result;
    result.key = call.key;
    try {
        auto impl = std::atomic_load_explicit(&impl_, std::memory_order_acquire);
        if (impl == nullptr) {
            result.error = MoonlightHostError::ShuttingDown;
            return result;
        }
        const auto shape = makeQueryShape(call);
        const auto validationError = validateCall(call, shape);
        if (validationError != MoonlightHostError::None) {
            result.error = validationError;
            return result;
        }
        if (impl->transport == nullptr || !impl->uuidGenerator) {
            result.error = MoonlightHostError::InvalidRequest;
            return result;
        }
        auto state = std::make_shared<ActiveRequest>(call.key);
        {
            std::lock_guard<std::mutex> lock(impl->mutex);
            if (impl->shuttingDown) {
                result.error = MoonlightHostError::ShuttingDown;
                return result;
            }
            if (!impl->active.emplace(call.key, state).second) {
                result.error = MoonlightHostError::RequestBusy;
                return result;
            }
        }
        RequestLease lease(impl, state);
        return executeRegistered(impl, state, call, shape);
    } catch (...) {
        result.error = MoonlightHostError::InternalFailure;
        return result;
    }
}

bool MoonlightHostApi::cancel(const MoonlightHostRequestKey& key) noexcept {
    if (!key.valid())
        return false;
    try {
        auto impl = std::atomic_load_explicit(&impl_, std::memory_order_acquire);
        if (impl == nullptr)
            return false;
        std::lock_guard<std::mutex> lock(impl->mutex);
        const auto it = impl->active.find(key);
        if (it == impl->active.end())
            return false;
        RequestDisposition expected = RequestDisposition::Active;
        return it->second->disposition.compare_exchange_strong(
            expected, RequestDisposition::Cancelled, std::memory_order_acq_rel);
    } catch (...) {
        return false;
    }
}

bool MoonlightHostApi::markStale(const MoonlightHostRequestKey& key) noexcept {
    if (!key.valid())
        return false;
    try {
        auto impl = std::atomic_load_explicit(&impl_, std::memory_order_acquire);
        if (impl == nullptr)
            return false;
        std::lock_guard<std::mutex> lock(impl->mutex);
        const auto it = impl->active.find(key);
        if (it == impl->active.end())
            return false;
        RequestDisposition expected = RequestDisposition::Active;
        return it->second->disposition.compare_exchange_strong(expected, RequestDisposition::Stale,
                                                               std::memory_order_acq_rel);
    } catch (...) {
        return false;
    }
}

#if defined(RDP_NATIVE_CALLBACK_TESTING)
std::optional<std::string>
MoonlightHostApi::percentEncodeQueryValueForTesting(const std::string& value) {
    std::string encoded;
    if (!percentEncode(value, encoded)) {
        return std::nullopt;
    }
    return encoded;
}

std::uint64_t MoonlightHostApi::secureCleanseCountForTesting() noexcept {
    return gSecureCleanseCount.load(std::memory_order_relaxed);
}

void MoonlightHostApi::resetSecureCleanseCountForTesting() noexcept {
    gSecureCleanseCount.store(0U, std::memory_order_relaxed);
}
#endif

} // namespace remotedesk::moonlight
