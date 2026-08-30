#ifndef REMOTEDESK_MOONLIGHT_HOST_API_H
#define REMOTEDESK_MOONLIGHT_HOST_API_H

#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#if defined(__GNUC__)
#define REMOTEDESK_MOONLIGHT_HOST_HIDDEN __attribute__((visibility("hidden")))
#else
#define REMOTEDESK_MOONLIGHT_HOST_HIDDEN
#endif

namespace remotedesk::moonlight {

struct REMOTEDESK_MOONLIGHT_HOST_HIDDEN MoonlightHostRequestKey final {
    std::uint64_t requestId = 0;
    std::uint64_t generation = 0;
    std::uint64_t ownerToken = 0;

    constexpr bool valid() const noexcept {
        return requestId != 0 && generation != 0 && ownerToken != 0;
    }
};

REMOTEDESK_MOONLIGHT_HOST_HIDDEN constexpr bool
operator==(const MoonlightHostRequestKey& left, const MoonlightHostRequestKey& right) noexcept {
    return left.requestId == right.requestId && left.generation == right.generation &&
           left.ownerToken == right.ownerToken;
}

REMOTEDESK_MOONLIGHT_HOST_HIDDEN constexpr bool
operator!=(const MoonlightHostRequestKey& left, const MoonlightHostRequestKey& right) noexcept {
    return !(left == right);
}

enum class MoonlightHostOperation : std::uint8_t {
    ServerInfo = 0,
    AppList,
    AppAsset,
    Pair,
    PairChallenge,
    Unpair,
    Launch,
    Resume,
    Cancel,
};

enum class MoonlightHostScheme : std::uint8_t {
    Http = 0,
    Https,
};

enum class MoonlightHostAddressFamily : std::uint8_t {
    Unspecified = 0,
    Ipv4,
    Ipv6,
};

enum class MoonlightTransportStage : std::uint8_t {
    None = 0,
    Dns,
    Connect,
    Tls,
    Http,
    Body,
    Parse,
    Commit,
    Complete,
};

enum class MoonlightTransportSendState : std::uint8_t {
    NotSent = 0,
    SentResponseUnknown,
    ConfirmedResponse,
};

enum class MoonlightTransportError : std::uint8_t {
    None = 0,
    DnsFailure,
    ConnectFailure,
    TlsVersionFailure,
    TlsChainFailure,
    TrustConflict,
    Timeout,
    Cancelled,
    BodyTooLarge,
    ProtocolFailure,
};

enum class MoonlightHostError : std::uint8_t {
    None = 0,
    InvalidRequest,
    InvalidEndpoint,
    InvalidPort,
    InvalidQuery,
    UrlTooLong,
    RequestBusy,
    ShuttingDown,
    Cancelled,
    StaleRequest,
    DeadlineExceeded,
    DnsFailure,
    ConnectFailure,
    TlsVersionFailure,
    TlsChainFailure,
    TrustConflict,
    HttpUnauthorized,
    HttpNotFound,
    HttpFailure,
    BodyTooLarge,
    MalformedXml,
    XmlBudgetExceeded,
    XmlStatusRejected,
    MissingRequiredField,
    InvalidField,
    DuplicateApp,
    HostBusy,
    ActionUnknown,
    TransportFailure,
    InternalFailure,
};

struct REMOTEDESK_MOONLIGHT_HOST_HIDDEN MoonlightHostLimits final {
    static constexpr std::size_t kMaxUrlBytes = 8U * 1024U;
    static constexpr std::size_t kMaxBodyBytes = 4U * 1024U * 1024U;
    static constexpr std::size_t kMaxXmlDepth = 32U;
    static constexpr std::size_t kMaxXmlElements = 16384U;
    static constexpr std::size_t kMaxAttributesPerElement = 16U;
    static constexpr std::size_t kMaxXmlNameBytes = 64U;
    static constexpr std::size_t kMaxAttributeBytes = 1024U;
    static constexpr std::size_t kMaxTextNodeBytes = 256U * 1024U;
    static constexpr std::size_t kMaxApps = 2048U;
    static constexpr std::size_t kMaxAppTitleBytes = 1024U;
    static constexpr std::size_t kMaxAddresses = 8U;
    static constexpr std::size_t kMaxQueryParameters = 48U;
    static constexpr std::chrono::milliseconds kMinTimeout{100};
    static constexpr std::chrono::milliseconds kMaxStandardTimeout{30000};
    static constexpr std::chrono::milliseconds kMaxTimeout{120000};
    static constexpr std::chrono::milliseconds kDefaultTimeout{7000};
};

struct REMOTEDESK_MOONLIGHT_HOST_HIDDEN MoonlightHostAddress final {
    std::string value;
    MoonlightHostAddressFamily family = MoonlightHostAddressFamily::Unspecified;
    // Device-local interface scope for a link-local IPv6 address. Keep it
    // separate so socket and URI formatting cannot be confused.
    std::string scope;
};

struct REMOTEDESK_MOONLIGHT_HOST_HIDDEN MoonlightHostEndpoint final {
    // serverName is used for TLS SNI/HTTP authority semantics. Each address is
    // an already ordered connection candidate and is never copied to logs.
    std::string serverName;
    std::vector<MoonlightHostAddress> addresses;
    std::uint16_t httpPort = 47989;
    std::uint16_t httpsPort = 47984;
    bool pinnedTrustAvailable = false;
    bool allowHttpPairingCandidate = false;
};

struct REMOTEDESK_MOONLIGHT_HOST_HIDDEN MoonlightHostQueryParameter final {
    std::string name;
    std::string value;
};

struct REMOTEDESK_MOONLIGHT_HOST_HIDDEN MoonlightHostCall final {
    MoonlightHostRequestKey key{};
    MoonlightHostOperation operation = MoonlightHostOperation::ServerInfo;
    MoonlightHostEndpoint endpoint;
    std::vector<MoonlightHostQueryParameter> query;
    std::chrono::milliseconds timeout = MoonlightHostLimits::kDefaultTimeout;
};

class REMOTEDESK_MOONLIGHT_HOST_HIDDEN MoonlightTransportRequest final {
public:
    MoonlightTransportRequest(MoonlightHostRequestKey key, MoonlightHostOperation operation,
                              MoonlightHostScheme scheme, MoonlightHostAddressFamily family,
                              std::string connectAddress, std::string serverName,
                              std::uint16_t port, std::string path, std::string url,
                              bool requiresClientIdentity, bool requiresServerPin,
                              std::size_t responseBudget);
    ~MoonlightTransportRequest();

    MoonlightTransportRequest(const MoonlightTransportRequest&) = delete;
    MoonlightTransportRequest& operator=(const MoonlightTransportRequest&) = delete;
    MoonlightTransportRequest(MoonlightTransportRequest&&) = delete;
    MoonlightTransportRequest& operator=(MoonlightTransportRequest&&) = delete;

    const MoonlightHostRequestKey& key() const noexcept;
    MoonlightHostOperation operation() const noexcept;
    MoonlightHostScheme scheme() const noexcept;
    MoonlightHostAddressFamily family() const noexcept;
    const std::string& connectAddress() const noexcept;
    const std::string& serverName() const noexcept;
    std::uint16_t port() const noexcept;
    const std::string& method() const noexcept;
    const std::string& path() const noexcept;
    const std::string& url() const noexcept;
    bool requiresClientIdentity() const noexcept;
    bool requiresServerPin() const noexcept;
    bool redirectsAllowed() const noexcept;
    bool proxyAllowed() const noexcept;
    std::size_t responseBudget() const noexcept;

    // The formatter intentionally masks host/address and every query value.
    std::string redactedDebugString() const;

private:
    const MoonlightHostRequestKey key_;
    const MoonlightHostOperation operation_;
    const MoonlightHostScheme scheme_;
    const MoonlightHostAddressFamily family_;
    const std::string connectAddress_;
    const std::string serverName_;
    const std::uint16_t port_;
    const std::string method_{"GET"};
    const std::string path_;
    std::string url_;
    const bool requiresClientIdentity_;
    const bool requiresServerPin_;
    const std::size_t responseBudget_;
};

struct REMOTEDESK_MOONLIGHT_HOST_HIDDEN MoonlightTransportOutcome final {
    MoonlightTransportError error = MoonlightTransportError::None;
    MoonlightTransportStage stage = MoonlightTransportStage::None;
    MoonlightTransportSendState sendState = MoonlightTransportSendState::NotSent;
    int httpStatus = 0;
    std::string body;
    std::size_t receivedBodyBytes = 0;
    // Numeric winner selected by the transport race. Scoped IPv6 retains its
    // zone suffix so the media handoff cannot silently re-resolve the host.
    std::string resolvedAddress;
    MoonlightHostAddressFamily resolvedFamily = MoonlightHostAddressFamily::Unspecified;
};

class REMOTEDESK_MOONLIGHT_HOST_HIDDEN MoonlightHostTransport {
public:
    using CancellationProbe = std::function<bool()>;

    virtual ~MoonlightHostTransport() = default;
    // Pairing values are carried in the URL by the upstream GameStream
    // protocol. Implementations must treat request.url() and response bodies
    // as ephemeral, must not retain them, and must expose only redacted
    // diagnostics after execute() returns.
    virtual MoonlightTransportOutcome
    execute(const MoonlightTransportRequest& request,
            std::chrono::steady_clock::time_point absoluteDeadline,
            const CancellationProbe& cancellationProbe) = 0;
};

struct REMOTEDESK_MOONLIGHT_HOST_HIDDEN MoonlightServerInfo final {
    std::string uniqueId;
    std::string appVersion;
    // Sunshine's canonical compatibility quad is 7.1.431.-1. Keep the parsed
    // components signed, matching moonlight-common-c's AppVersionQuad.
    std::array<std::int32_t, 4> appVersionParts{};
    std::string state;
    bool paired = false;
    std::uint32_t currentGame = 0;
    std::optional<std::string> hostName;
    std::optional<std::string> gfeVersion;
    std::optional<std::string> gpuType;
    std::optional<std::string> localAddress;
    std::optional<std::string> externalAddress;
    std::optional<std::uint16_t> httpsPort;
    std::optional<std::uint16_t> externalPort;
    std::optional<std::uint64_t> maxLumaPixelsH264;
    std::optional<std::uint64_t> maxLumaPixelsHevc;
    std::optional<std::uint64_t> codecModeSupport;
};

struct REMOTEDESK_MOONLIGHT_HOST_HIDDEN MoonlightAppEntry final {
    std::uint32_t id = 0;
    std::string title;
    std::optional<bool> hdrSupported;
};

struct REMOTEDESK_MOONLIGHT_HOST_HIDDEN MoonlightPairingPayload final {
    std::optional<bool> paired;
    std::optional<std::string> plainCertificateHex;
    std::optional<std::string> challengeResponseHex;
    std::optional<std::string> pairingSecretHex;
};

struct REMOTEDESK_MOONLIGHT_HOST_HIDDEN MoonlightActionResult final {
    bool accepted = false;
    bool outcomeUnknown = false;
    // Bounded RTSP endpoint from sessionUrl0; this is transient launch output,
    // not an authentication/session token and is never copied to diagnostics.
    std::optional<std::string> rtspSessionUrl;
};

struct REMOTEDESK_MOONLIGHT_HOST_HIDDEN MoonlightHostDiagnostic final {
    MoonlightHostOperation operation = MoonlightHostOperation::ServerInfo;
    MoonlightTransportStage stage = MoonlightTransportStage::None;
    MoonlightHostAddressFamily family = MoonlightHostAddressFamily::Unspecified;
    MoonlightTransportSendState sendState = MoonlightTransportSendState::NotSent;
    MoonlightHostError code = MoonlightHostError::None;
    std::size_t attemptIndex = 0;
    std::uint16_t port = 0;
    int httpStatus = 0;
    std::optional<std::int32_t> xmlStatus;
    std::size_t byteCount = 0;
    std::chrono::milliseconds duration{0};
    std::string maskedEndpoint;
};

struct REMOTEDESK_MOONLIGHT_HOST_HIDDEN MoonlightHostResult final {
    MoonlightHostRequestKey key{};
    MoonlightHostError error = MoonlightHostError::InvalidRequest;
    int httpStatus = 0;
    std::optional<std::int32_t> xmlStatus;
    bool candidateOnly = false;
    bool mutationOutcomeUnknown = false;
    std::optional<MoonlightServerInfo> serverInfo;
    std::vector<MoonlightAppEntry> apps;
    std::size_t partialAppCount = 0;
    std::optional<MoonlightPairingPayload> pairing;
    std::optional<MoonlightActionResult> action;
    // The ordered endpoint candidate that produced this response. Product
    // streaming must reuse the successful control-plane address instead of
    // silently falling back to endpoint.addresses.front().
    std::optional<std::string> resolvedAddress;
    MoonlightHostAddressFamily resolvedFamily = MoonlightHostAddressFamily::Unspecified;
    std::vector<std::uint8_t> asset;
    std::vector<MoonlightHostDiagnostic> diagnostics;

    bool ok() const noexcept { return error == MoonlightHostError::None; }
};

class REMOTEDESK_MOONLIGHT_HOST_HIDDEN MoonlightHostApi final {
public:
    using UuidGenerator = std::function<std::string()>;

    MoonlightHostApi(std::shared_ptr<MoonlightHostTransport> transport,
                     UuidGenerator uuidGenerator);
    ~MoonlightHostApi();

    MoonlightHostApi(const MoonlightHostApi&) = delete;
    MoonlightHostApi& operator=(const MoonlightHostApi&) = delete;

    // Pure validation path for higher-level state machines that must prove a
    // request is admissible before performing any local or remote mutation.
    MoonlightHostError validate(const MoonlightHostCall& call) const noexcept;
    MoonlightHostResult execute(const MoonlightHostCall& call) noexcept;
    bool cancel(const MoonlightHostRequestKey& key) noexcept;
    bool markStale(const MoonlightHostRequestKey& key) noexcept;

#if defined(RDP_NATIVE_CALLBACK_TESTING)
    static std::optional<std::string> percentEncodeQueryValueForTesting(const std::string& value);
    static std::uint64_t secureCleanseCountForTesting() noexcept;
    static void resetSecureCleanseCountForTesting() noexcept;
#endif

private:
    struct Impl;
    std::shared_ptr<Impl> impl_;
};

} // namespace remotedesk::moonlight

#undef REMOTEDESK_MOONLIGHT_HOST_HIDDEN

#endif // REMOTEDESK_MOONLIGHT_HOST_API_H
