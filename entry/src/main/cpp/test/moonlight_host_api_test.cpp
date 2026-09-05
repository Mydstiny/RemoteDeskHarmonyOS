#include "moonlight/core/MoonlightHostApi.h"
#include "common/network_generation_fence.h"
#include "test_runner.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>

namespace {

using namespace remotedesk::moonlight;
using namespace std::chrono_literals;

struct CapturedRequest final {
    MoonlightHostRequestKey key{};
    MoonlightHostOperation operation = MoonlightHostOperation::ServerInfo;
    MoonlightHostScheme scheme = MoonlightHostScheme::Http;
    MoonlightHostAddressFamily family = MoonlightHostAddressFamily::Unspecified;
    std::string connectAddress;
    std::string serverName;
    std::uint16_t port = 0;
    std::string method;
    std::string path;
    std::string url;
    std::string redacted;
    bool requiresClientIdentity = false;
    bool requiresServerPin = false;
    bool redirectsAllowed = true;
    bool proxyAllowed = true;
    std::size_t responseBudget = 0;
    std::chrono::steady_clock::time_point deadline;
};

class ScriptedTransport final : public MoonlightHostTransport {
public:
    using Handler = std::function<MoonlightTransportOutcome(const MoonlightTransportRequest&,
                                                            std::chrono::steady_clock::time_point,
                                                            const CancellationProbe&)>;

    MoonlightTransportOutcome execute(const MoonlightTransportRequest& request,
                                      std::chrono::steady_clock::time_point absoluteDeadline,
                                      const CancellationProbe& cancellationProbe) override {
        Handler handler;
        MoonlightTransportOutcome outcome;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            captures_.push_back({
                request.key(),
                request.operation(),
                request.scheme(),
                request.family(),
                request.connectAddress(),
                request.serverName(),
                request.port(),
                request.method(),
                request.path(),
                request.url(),
                request.redactedDebugString(),
                request.requiresClientIdentity(),
                request.requiresServerPin(),
                request.redirectsAllowed(),
                request.proxyAllowed(),
                request.responseBudget(),
                absoluteDeadline,
            });
            handler = handler_;
            if (!outcomes_.empty()) {
                outcome = std::move(outcomes_.front());
                outcomes_.pop_front();
            } else {
                outcome.error = MoonlightTransportError::ProtocolFailure;
                outcome.stage = MoonlightTransportStage::Http;
            }
        }
        if (handler) {
            return handler(request, absoluteDeadline, cancellationProbe);
        }
        if (outcome.error == MoonlightTransportError::None &&
            outcome.resolvedAddress.empty()) {
            // The production transport always returns the numeric socket
            // winner. Scripted success fixtures mirror that invariant unless
            // a dedicated malformed-transport fixture is used.
            outcome.resolvedAddress = request.connectAddress();
            outcome.resolvedFamily = request.family();
        }
        return outcome;
    }

    void push(MoonlightTransportOutcome outcome) {
        std::lock_guard<std::mutex> lock(mutex_);
        outcomes_.push_back(std::move(outcome));
    }

    void setHandler(Handler handler) {
        std::lock_guard<std::mutex> lock(mutex_);
        handler_ = std::move(handler);
    }

    std::vector<CapturedRequest> captures() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return captures_;
    }

private:
    mutable std::mutex mutex_;
    std::deque<MoonlightTransportOutcome> outcomes_;
    Handler handler_;
    std::vector<CapturedRequest> captures_;
};

class NonRetainingPairingTransport final : public MoonlightHostTransport {
public:
    MoonlightTransportOutcome execute(const MoonlightTransportRequest& request,
                                      std::chrono::steady_clock::time_point,
                                      const CancellationProbe&) override {
        sawSensitiveRequest_ = containsRaw(request.url(), "A1B2C3D4") &&
                               containsRaw(request.url(), "0011223344556677");
        redacted_ = request.redactedDebugString();
        auto outcome = xmlResponseBody();
        outcome.resolvedAddress = request.connectAddress();
        outcome.resolvedFamily = request.family();
        return outcome;
    }

    bool sawSensitiveRequest() const noexcept { return sawSensitiveRequest_; }
    const std::string& redacted() const noexcept { return redacted_; }

private:
    static bool containsRaw(const std::string& value, const std::string& needle) {
        return value.find(needle) != std::string::npos;
    }

    static MoonlightTransportOutcome xmlResponseBody() {
        MoonlightTransportOutcome outcome;
        outcome.stage = MoonlightTransportStage::Body;
        outcome.sendState = MoonlightTransportSendState::ConfirmedResponse;
        outcome.httpStatus = 200;
        outcome.body = "<root status_code=\"200\"><paired>1</paired>"
                       "<plaincert>AABBCCDD</plaincert></root>";
        outcome.receivedBodyBytes = outcome.body.size();
        return outcome;
    }

    bool sawSensitiveRequest_ = false;
    std::string redacted_;
};

class MissingWinnerTransport final : public MoonlightHostTransport {
public:
    MoonlightTransportOutcome execute(
        const MoonlightTransportRequest&,
        std::chrono::steady_clock::time_point,
        const CancellationProbe&) override {
        return xmlResponseBody();
    }

private:
    static MoonlightTransportOutcome xmlResponseBody() {
        MoonlightTransportOutcome outcome;
        outcome.stage = MoonlightTransportStage::Body;
        outcome.sendState = MoonlightTransportSendState::ConfirmedResponse;
        outcome.httpStatus = 200;
        outcome.body =
            "<root status_code=\"200\"><hostname>Gaming PC</hostname>"
            "<uniqueid>host-001</uniqueid><appversion>7.1.431.-1</appversion>"
            "<state>SUNSHINE_SERVER_READY</state><PairStatus>1</PairStatus>"
            "<currentgame>0</currentgame></root>";
        outcome.receivedBodyBytes = outcome.body.size();
        return outcome;
    }
};

class BlockingGate final {
public:
    void entered() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            entered_ = true;
        }
        cv_.notify_all();
    }

    bool waitEntered() {
        std::unique_lock<std::mutex> lock(mutex_);
        return cv_.wait_for(lock, 1s, [&]() { return entered_; });
    }

    void release() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            released_ = true;
        }
        cv_.notify_all();
    }

    void waitReleased() {
        std::unique_lock<std::mutex> lock(mutex_);
        cv_.wait(lock, [&]() { return released_; });
    }

private:
    std::mutex mutex_;
    std::condition_variable cv_;
    bool entered_ = false;
    bool released_ = false;
};

MoonlightTransportOutcome xmlResponse(const std::string& body, int httpStatus = 200) {
    MoonlightTransportOutcome outcome;
    outcome.stage = MoonlightTransportStage::Body;
    outcome.sendState = MoonlightTransportSendState::ConfirmedResponse;
    outcome.httpStatus = httpStatus;
    outcome.body = body;
    outcome.receivedBodyBytes = body.size();
    return outcome;
}

MoonlightTransportOutcome
transportFailure(MoonlightTransportError error, MoonlightTransportStage stage,
                 MoonlightTransportSendState sendState = MoonlightTransportSendState::NotSent) {
    MoonlightTransportOutcome outcome;
    outcome.error = error;
    outcome.stage = stage;
    outcome.sendState = sendState;
    return outcome;
}

std::string serverInfoXml(const std::string& extra = {}) {
    return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
           "<root status_code=\"200\" status_message=\"OK\">"
           "<hostname>Gaming PC</hostname>"
           "<uniqueid>host-001</uniqueid>"
           "<appversion>7.1.431.-1</appversion>"
           "<state>SUNSHINE_SERVER_BUSY</state>"
           "<PairStatus>1</PairStatus>"
           "<currentgame>42</currentgame>"
           "<HttpsPort>47984</HttpsPort>"
           "<ExternalPort>48000</ExternalPort>"
           "<LocalIP>192.0.2.10</LocalIP>"
           "<ExternalIP>198.51.100.20</ExternalIP>"
           "<GfeVersion>3.27.0.120</GfeVersion>"
           "<gputype>Test GPU</gputype>"
           "<MaxLumaPixelsH264>2073600</MaxLumaPixelsH264>"
           "<MaxLumaPixelsHEVC>8294400</MaxLumaPixelsHEVC>"
           "<ServerCodecModeSupport>769</ServerCodecModeSupport>" +
           extra + "</root>";
}

std::string idleServerInfoXml() {
    auto value = serverInfoXml();
    const auto state = value.find("SUNSHINE_SERVER_BUSY");
    value.replace(state, std::string("SUNSHINE_SERVER_BUSY").size(), "SUNSHINE_SERVER_READY");
    const auto game = value.find("<currentgame>42</currentgame>");
    value.replace(game, std::string("<currentgame>42</currentgame>").size(),
                  "<currentgame>0</currentgame>");
    return value;
}

MoonlightHostEndpoint endpoint(bool pinned = false) {
    MoonlightHostEndpoint value;
    value.serverName = "gaming.example";
    value.addresses = {{"192.0.2.10", MoonlightHostAddressFamily::Ipv4}};
    value.pinnedTrustAvailable = pinned;
    return value;
}

MoonlightHostCall callFor(MoonlightHostOperation operation, bool pinned = false,
                          MoonlightHostRequestKey key = {1, 1, 1}) {
    MoonlightHostCall call;
    call.key = key;
    call.operation = operation;
    call.endpoint = endpoint(pinned);
    return call;
}

std::vector<MoonlightHostQueryParameter> launchQuery() {
    return {
        {"appid", "42"},
        {"mode", "1920x1080x60"},
        {"additionalStates", "1"},
        {"sops", "1"},
        {"rikey", "00112233445566778899AABBCCDDEEFF"},
        {"rikeyid", "-2147483648"},
        {"localAudioPlayMode", "0"},
        {"surroundAudioInfo", "196610"},
        {"remoteControllersBitmap", "3"},
        {"gcmap", "3"},
        {"gcpersist", "0"},
    };
}

MoonlightHostApi::UuidGenerator uuidGenerator() {
    auto sequence = std::make_shared<std::atomic<unsigned>>(1U);
    return [sequence]() {
        char value[37]{};
        std::snprintf(value, sizeof(value), "00000000-0000-4000-8000-%012u",
                      sequence->fetch_add(1U));
        return std::string(value);
    };
}

bool contains(const std::string& value, const std::string& needle) {
    return value.find(needle) != std::string::npos;
}

MoonlightHostResult executeOnce(const MoonlightHostCall& call, MoonlightTransportOutcome outcome,
                                std::vector<CapturedRequest>* captures = nullptr) {
    auto transport = std::make_shared<ScriptedTransport>();
    transport->push(std::move(outcome));
    MoonlightHostApi api(transport, uuidGenerator());
    auto result = api.execute(call);
    if (captures != nullptr) {
        *captures = transport->captures();
    }
    return result;
}

} // namespace

RDP_TEST_CASE(moonlight_host_api_rejects_invalid_keys_endpoints_ports_and_queries) {
    auto transport = std::make_shared<ScriptedTransport>();
    MoonlightHostApi api(transport, uuidGenerator());

    auto call = callFor(MoonlightHostOperation::ServerInfo);
    call.key = {};
    RDP_ASSERT_EQ(api.execute(call).error, MoonlightHostError::InvalidRequest);

    call = callFor(MoonlightHostOperation::ServerInfo);
    call.timeout = 99ms;
    RDP_ASSERT_EQ(api.execute(call).error, MoonlightHostError::InvalidRequest);
    call.timeout = 30001ms;
    RDP_ASSERT_EQ(api.execute(call).error, MoonlightHostError::InvalidRequest);

    call = callFor(MoonlightHostOperation::ServerInfo);
    call.endpoint.serverName = "user@host.example";
    RDP_ASSERT_EQ(api.execute(call).error, MoonlightHostError::InvalidEndpoint);
    call = callFor(MoonlightHostOperation::ServerInfo);
    call.endpoint.addresses[0].value = "192.0.2.10\r\nInjected: yes";
    RDP_ASSERT_EQ(api.execute(call).error, MoonlightHostError::InvalidEndpoint);
    call = callFor(MoonlightHostOperation::ServerInfo);
    call.endpoint.httpPort = 0;
    RDP_ASSERT_EQ(api.execute(call).error, MoonlightHostError::InvalidPort);

    call = callFor(MoonlightHostOperation::AppList, false);
    RDP_ASSERT_EQ(api.execute(call).error, MoonlightHostError::InvalidEndpoint);
    call = callFor(MoonlightHostOperation::ServerInfo);
    call.query = {{"uuid", "attacker"}};
    RDP_ASSERT_EQ(api.execute(call).error, MoonlightHostError::InvalidQuery);

    call = callFor(MoonlightHostOperation::AppAsset, true);
    call.query = {{"appid", "0"}};
    RDP_ASSERT_EQ(api.execute(call).error, MoonlightHostError::InvalidQuery);

    call = callFor(MoonlightHostOperation::Pair);
    call.query = {{"phrase", "getservercert"},
                  {"salt", "00112233445566778899AABBCCDDEEFF"},
                  {"clientcert", "AABBCCDD"}};
    call.timeout = 120001ms;
    RDP_ASSERT_EQ(api.execute(call).error, MoonlightHostError::InvalidRequest);
    call.timeout = 120s;
    call.query[2].value.assign(MoonlightHostLimits::kMaxUrlBytes + 1U, 'A');
    RDP_ASSERT_EQ(api.validate(call), MoonlightHostError::UrlTooLong);
    RDP_ASSERT_EQ(api.execute(call).error, MoonlightHostError::UrlTooLong);
    RDP_ASSERT(transport->captures().empty());

    call.query[2].value = "AABBCCDD";
    RDP_ASSERT_EQ(api.validate(call), MoonlightHostError::None);
    RDP_ASSERT(transport->captures().empty());
}

RDP_TEST_CASE(moonlight_host_api_parses_bounded_serverinfo_and_official_status_cast) {
    auto call = callFor(MoonlightHostOperation::ServerInfo);
    const auto result = executeOnce(call, xmlResponse(serverInfoXml("<Unknown>x</Unknown>")));
    RDP_ASSERT(result.ok());
    RDP_ASSERT(result.serverInfo.has_value());
    RDP_ASSERT_EQ(result.serverInfo->appVersionParts[0], static_cast<std::int32_t>(7));
    RDP_ASSERT_EQ(result.serverInfo->appVersionParts[3], static_cast<std::int32_t>(-1));
    RDP_ASSERT(result.serverInfo->paired);
    RDP_ASSERT_EQ(result.serverInfo->currentGame, static_cast<std::uint32_t>(42));
    RDP_ASSERT(result.serverInfo->hostName.has_value());
    RDP_ASSERT_EQ(*result.serverInfo->httpsPort, static_cast<std::uint16_t>(47984));
    RDP_ASSERT_EQ(*result.serverInfo->codecModeSupport, static_cast<std::uint64_t>(769));
    RDP_ASSERT_EQ(result.xmlStatus.value_or(0), 200);

    auto idleWithStaleGame = serverInfoXml();
    const auto idleState = idleWithStaleGame.find("SUNSHINE_SERVER_BUSY");
    idleWithStaleGame.replace(idleState, std::string("SUNSHINE_SERVER_BUSY").size(),
                              "SUNSHINE_SERVER_READY");
    const auto idle = executeOnce(call, xmlResponse(idleWithStaleGame));
    RDP_ASSERT(idle.ok());
    RDP_ASSERT(idle.serverInfo.has_value());
    RDP_ASSERT_EQ(idle.serverInfo->currentGame, static_cast<std::uint32_t>(0));

    const auto rejected = executeOnce(
        call, xmlResponse("<root status_code=\"4294967295\" status_message=\"Invalid\"/>"));
    RDP_ASSERT_EQ(rejected.error, MoonlightHostError::XmlStatusRejected);
    RDP_ASSERT_EQ(rejected.xmlStatus.value_or(0), -1);

    const auto busy =
        executeOnce(call, xmlResponse("<root status_code=\"503\" status_message=\"Busy\"/>"));
    RDP_ASSERT_EQ(busy.error, MoonlightHostError::HostBusy);

    auto invalidPortXml = serverInfoXml();
    const auto port = invalidPortXml.find("<HttpsPort>47984</HttpsPort>");
    invalidPortXml.replace(port, std::string("<HttpsPort>47984</HttpsPort>").size(),
                           "<HttpsPort>0</HttpsPort>");
    RDP_ASSERT_EQ(executeOnce(call, xmlResponse(invalidPortXml)).error,
                  MoonlightHostError::InvalidField);

    auto invalidVersionXml = serverInfoXml();
    const auto version = invalidVersionXml.find("<appversion>7.1.431.-1</appversion>");
    invalidVersionXml.replace(
        version, std::string("<appversion>7.1.431.-1</appversion>").size(),
        "<appversion>7.1.431.--1</appversion>");
    RDP_ASSERT_EQ(executeOnce(call, xmlResponse(invalidVersionXml)).error,
                  MoonlightHostError::InvalidField);
}

RDP_TEST_CASE(moonlight_host_api_learns_custom_https_port_from_serverinfo) {
    auto transport = std::make_shared<ScriptedTransport>();
    auto customPortInfo = serverInfoXml();
    const auto port = customPortInfo.find("<HttpsPort>47984</HttpsPort>");
    customPortInfo.replace(port, std::string("<HttpsPort>47984</HttpsPort>").size(),
                           "<HttpsPort>48984</HttpsPort>");
    transport->push(xmlResponse(customPortInfo));
    transport->push(xmlResponse(customPortInfo));
    transport->push(xmlResponse("<root status_code=\"200\"></root>"));

    MoonlightHostApi api(transport, uuidGenerator());
    auto serverInfoCall = callFor(MoonlightHostOperation::ServerInfo, true, {1, 1, 1});
    serverInfoCall.endpoint.httpPort = 48989;
    const auto serverInfo = api.execute(serverInfoCall);
    RDP_ASSERT(serverInfo.ok());

    auto appListCall = callFor(MoonlightHostOperation::AppList, true, {2, 1, 1});
    appListCall.endpoint.httpPort = 48989;
    const auto appList = api.execute(appListCall);
    RDP_ASSERT(appList.ok());

    const auto captures = transport->captures();
    RDP_ASSERT_EQ(captures.size(), static_cast<std::size_t>(3));
    RDP_ASSERT_EQ(captures[0].scheme, MoonlightHostScheme::Http);
    RDP_ASSERT_EQ(captures[0].port, static_cast<std::uint16_t>(48989));
    RDP_ASSERT_EQ(captures[1].scheme, MoonlightHostScheme::Https);
    RDP_ASSERT_EQ(captures[1].port, static_cast<std::uint16_t>(48984));
    RDP_ASSERT_EQ(captures[2].scheme, MoonlightHostScheme::Https);
    RDP_ASSERT_EQ(captures[2].port, static_cast<std::uint16_t>(48984));
}

RDP_TEST_CASE(moonlight_host_api_does_not_cache_untrusted_custom_https_port) {
    auto transport = std::make_shared<ScriptedTransport>();
    auto customPortInfo = serverInfoXml();
    const auto port = customPortInfo.find("<HttpsPort>47984</HttpsPort>");
    customPortInfo.replace(port, std::string("<HttpsPort>47984</HttpsPort>").size(),
                           "<HttpsPort>48984</HttpsPort>");
    for (int attempt = 0; attempt < 2; ++attempt) {
        transport->push(xmlResponse(customPortInfo));
        transport->push(transportFailure(
            MoonlightTransportError::TrustConflict, MoonlightTransportStage::Tls));
    }

    MoonlightHostApi api(transport, uuidGenerator());
    for (std::uint64_t requestId = 1; requestId <= 2; ++requestId) {
        auto call = callFor(MoonlightHostOperation::ServerInfo, true,
                            {requestId, 1, 1});
        call.endpoint.httpPort = 48989;
        RDP_ASSERT_EQ(api.execute(call).error, MoonlightHostError::TrustConflict);
    }

    const auto captures = transport->captures();
    RDP_ASSERT_EQ(captures.size(), static_cast<std::size_t>(4));
    RDP_ASSERT_EQ(captures[0].scheme, MoonlightHostScheme::Http);
    RDP_ASSERT_EQ(captures[1].scheme, MoonlightHostScheme::Https);
    RDP_ASSERT_EQ(captures[2].scheme, MoonlightHostScheme::Http);
    RDP_ASSERT_EQ(captures[3].scheme, MoonlightHostScheme::Https);
}

RDP_TEST_CASE(moonlight_host_api_parses_apps_partial_entries_entities_and_rejects_duplicates) {
    auto call = callFor(MoonlightHostOperation::AppList, true);
    const std::string body =
        "<root status_code=\"200\">"
        "<App><AppTitle>Game &amp; One</AppTitle><ID>1</ID><IsHdrSupported>1</IsHdrSupported></App>"
        "<App><AppTitle>Missing id</AppTitle></App>"
        "<Unknown><Nested>ignored</Nested></Unknown>"
        "<App><AppTitle>&#x6E38;&#25103;</AppTitle><ID>2</ID></App>"
        "<App><AppTitle/><ID>3</ID></App>"
        "</root>";
    const auto result = executeOnce(call, xmlResponse(body));
    RDP_ASSERT(result.ok());
    RDP_ASSERT_EQ(result.apps.size(), static_cast<std::size_t>(3));
    RDP_ASSERT_EQ(result.partialAppCount, static_cast<std::size_t>(1));
    RDP_ASSERT(result.apps[0].title == "Game & One");
    RDP_ASSERT(result.apps[0].hdrSupported.value_or(false));
    RDP_ASSERT(result.apps[1].title == "游戏");
    RDP_ASSERT(result.apps[2].title == "Application 3");

    const auto duplicate =
        executeOnce(call, xmlResponse("<root status_code=\"200\">"
                                      "<App><AppTitle>A</AppTitle><ID>7</ID></App>"
                                      "<App><AppTitle>B</AppTitle><ID>7</ID></App>"
                                      "</root>"));
    RDP_ASSERT_EQ(duplicate.error, MoonlightHostError::DuplicateApp);
    RDP_ASSERT(duplicate.apps.empty());

    const std::string oversizedTitle(MoonlightHostLimits::kMaxAppTitleBytes + 1U, 'x');
    const auto titleBudget =
        executeOnce(call, xmlResponse("<root status_code=\"200\"><App><AppTitle>" + oversizedTitle +
                                      "</AppTitle><ID>8</ID></App></root>"));
    RDP_ASSERT_EQ(titleBudget.error, MoonlightHostError::XmlBudgetExceeded);
    RDP_ASSERT(titleBudget.apps.empty());
}

RDP_TEST_CASE(moonlight_host_api_builds_official_pair_asset_and_action_shapes) {
    {
        auto call = callFor(MoonlightHostOperation::Pair);
        call.query = {
            {"phrase", "getservercert"},
            {"salt", "00112233445566778899AABBCCDDEEFF"},
            {"clientcert", "AABBCCDD"},
        };
        call.timeout = 120s;
        std::vector<CapturedRequest> captures;
        const auto result = executeOnce(call,
                                        xmlResponse("<root status_code=\"200\"><paired>1</paired>"
                                                    "<plaincert>AABBCC</plaincert></root>"),
                                        &captures);
        RDP_ASSERT(result.ok());
        RDP_ASSERT(result.pairing->paired.value_or(false));
        RDP_ASSERT_EQ(captures.size(), static_cast<std::size_t>(1));
        RDP_ASSERT_EQ(captures[0].scheme, MoonlightHostScheme::Http);
        RDP_ASSERT(contains(captures[0].url, "/pair?devicename=roth&updateState=1"));
        RDP_ASSERT(contains(captures[0].url, "uniqueid=0123456789ABCDEF"));
        RDP_ASSERT(contains(captures[0].url, "uuid=00000000-0000-4000-8000-000000000001"));
        RDP_ASSERT(!contains(captures[0].redacted, "00112233445566778899AABBCCDDEEFF"));
        RDP_ASSERT(!contains(captures[0].redacted, "AABBCCDD"));
        RDP_ASSERT(contains(captures[0].redacted, "clientcert=<redacted>"));
    }
    {
        auto call = callFor(MoonlightHostOperation::PairChallenge, true);
        std::vector<CapturedRequest> captures;
        const auto result = executeOnce(
            call, xmlResponse("<root status_code=\"200\"><paired>1</paired></root>"), &captures);
        RDP_ASSERT(result.ok());
        RDP_ASSERT(captures[0].requiresClientIdentity);
        RDP_ASSERT(captures[0].requiresServerPin);
        RDP_ASSERT(contains(captures[0].url, "phrase=pairchallenge"));
    }
    {
        auto call = callFor(MoonlightHostOperation::AppAsset, true);
        call.query = {{"appid", "42"}};
        std::vector<CapturedRequest> captures;
        const auto result = executeOnce(call, xmlResponse("\x89PNG\r\n"), &captures);
        RDP_ASSERT(result.ok());
        RDP_ASSERT_EQ(result.asset.size(), static_cast<std::size_t>(6));
        RDP_ASSERT(contains(captures[0].url, "appid=42&AssetType=2&AssetIdx=0"));
    }
}

RDP_TEST_CASE(moonlight_host_api_cleanses_ephemeral_pairing_wire_scratch) {
    MoonlightHostApi::resetSecureCleanseCountForTesting();
    auto transport = std::make_shared<NonRetainingPairingTransport>();
    MoonlightHostApi api(transport, uuidGenerator());
    auto call = callFor(MoonlightHostOperation::Pair);
    call.query = {
        {"phrase", "getservercert"},
        {"salt", "00112233445566778899AABBCCDDEEFF"},
        {"clientcert", "A1B2C3D4"},
    };
    call.timeout = 120s;

    const auto result = api.execute(call);
    RDP_ASSERT(result.ok());
    RDP_ASSERT(transport->sawSensitiveRequest());
    RDP_ASSERT(!contains(transport->redacted(), "0011223344556677"));
    RDP_ASSERT(!contains(transport->redacted(), "A1B2C3D4"));
    RDP_ASSERT(contains(transport->redacted(), "salt=<redacted>"));
    RDP_ASSERT(MoonlightHostApi::secureCleanseCountForTesting() >= 8U);
}

RDP_TEST_CASE(moonlight_host_api_builds_launch_resume_cancel_and_redacts_every_value) {
    for (const auto operation : {MoonlightHostOperation::Launch, MoonlightHostOperation::Resume}) {
        auto call = callFor(operation, true);
        call.query = launchQuery();
        const std::string response = operation == MoonlightHostOperation::Launch
                                         ? "<root status_code=\"200\"><gamesession>1</gamesession>"
                                           "<sessionUrl0>rtspenc://session</sessionUrl0></root>"
                                         : "<root status_code=\"200\"><resume>1</resume></root>";
        std::vector<CapturedRequest> captures;
        const auto result = executeOnce(call, xmlResponse(response), &captures);
        RDP_ASSERT(result.ok());
        RDP_ASSERT(result.action.has_value());
        RDP_ASSERT(result.action->accepted);
        RDP_ASSERT(captures[0].method == "GET");
        RDP_ASSERT(!captures[0].redirectsAllowed);
        RDP_ASSERT(!captures[0].proxyAllowed);
        RDP_ASSERT_EQ(captures[0].responseBudget, MoonlightHostLimits::kMaxBodyBytes);
        RDP_ASSERT(!contains(captures[0].redacted, "gaming.example"));
        RDP_ASSERT(!contains(captures[0].redacted, "00112233445566778899AABBCCDDEEFF"));
        RDP_ASSERT(!contains(captures[0].redacted, "00000000-0000-4000-8000-000000000001"));
        RDP_ASSERT(contains(captures[0].redacted, "uuid=<redacted>"));
        RDP_ASSERT(contains(captures[0].url, "corever=1"));
    }

    auto invalidUrlCall = callFor(MoonlightHostOperation::Launch, true);
    invalidUrlCall.query = launchQuery();
    const auto invalidUrl = executeOnce(
        invalidUrlCall, xmlResponse("<root status_code=\"200\"><gamesession>1</gamesession>"
                                    "<sessionUrl0>https://not-rtsp</sessionUrl0></root>"));
    RDP_ASSERT_EQ(invalidUrl.error, MoonlightHostError::InvalidField);
    RDP_ASSERT(invalidUrl.mutationOutcomeUnknown);
}

RDP_TEST_CASE(moonlight_host_api_cancel_requires_authenticated_idle_confirmation) {
    auto transport = std::make_shared<ScriptedTransport>();
    transport->push(xmlResponse("<root status_code=\"200\"><cancel>1</cancel></root>"));
    transport->push(xmlResponse(idleServerInfoXml()));
    MoonlightHostApi api(transport, uuidGenerator());
    const auto result = api.execute(callFor(MoonlightHostOperation::Cancel, true));
    RDP_ASSERT(result.ok());
    RDP_ASSERT(result.action.has_value());
    RDP_ASSERT(result.action->accepted);
    const auto captures = transport->captures();
    RDP_ASSERT_EQ(captures.size(), static_cast<std::size_t>(2));
    RDP_ASSERT_EQ(captures[0].operation, MoonlightHostOperation::Cancel);
    RDP_ASSERT_EQ(captures[1].operation, MoonlightHostOperation::ServerInfo);
    RDP_ASSERT_EQ(captures[1].scheme, MoonlightHostScheme::Https);
    RDP_ASSERT(captures[1].requiresClientIdentity);
    RDP_ASSERT(captures[1].requiresServerPin);

    auto busyTransport = std::make_shared<ScriptedTransport>();
    busyTransport->push(xmlResponse("<root status_code=\"200\"><cancel>1</cancel></root>"));
    busyTransport->push(xmlResponse(serverInfoXml()));
    MoonlightHostApi busyApi(busyTransport, uuidGenerator());
    const auto busy = busyApi.execute(callFor(MoonlightHostOperation::Cancel, true));
    RDP_ASSERT_EQ(busy.error, MoonlightHostError::HostBusy);
    RDP_ASSERT(!busy.action->accepted);
}

RDP_TEST_CASE(moonlight_host_api_percent_encodes_utf8_and_rejects_control_values) {
    const auto encoded =
        MoonlightHostApi::percentEncodeQueryValueForTesting("hello world/游戏&value");
    RDP_ASSERT(encoded.has_value());
    RDP_ASSERT(*encoded == "hello%20world%2F%E6%B8%B8%E6%88%8F%26value");
    RDP_ASSERT(
        !MoonlightHostApi::percentEncodeQueryValueForTesting("safe\r\nInjected: yes").has_value());
}

RDP_TEST_CASE(moonlight_host_api_formats_ipv6_and_uses_one_absolute_deadline_across_fallback) {
    auto transport = std::make_shared<ScriptedTransport>();
    transport->push(transportFailure(MoonlightTransportError::ConnectFailure,
                                     MoonlightTransportStage::Connect));
    transport->push(xmlResponse(serverInfoXml()));
    MoonlightHostApi api(transport, uuidGenerator());
    auto call = callFor(MoonlightHostOperation::ServerInfo);
    call.endpoint.addresses = {
        {"2001:db8::10", MoonlightHostAddressFamily::Ipv6},
        {"192.0.2.10", MoonlightHostAddressFamily::Ipv4},
    };
    const auto result = api.execute(call);
    RDP_ASSERT(result.ok());
    const auto captures = transport->captures();
    RDP_ASSERT_EQ(captures.size(), static_cast<std::size_t>(2));
    RDP_ASSERT(contains(captures[0].url, "http://[2001:db8::10]:47989/serverinfo"));
    RDP_ASSERT(contains(captures[1].url, "http://192.0.2.10:47989/serverinfo"));
    RDP_ASSERT(captures[0].deadline == captures[1].deadline);
    RDP_ASSERT(captures[0].serverName == "gaming.example");
    RDP_ASSERT(captures[0].url != captures[1].url);
}

RDP_TEST_CASE(moonlight_host_api_keeps_link_local_scope_typed_across_control_request) {
    std::vector<CapturedRequest> captures;
    auto call = callFor(MoonlightHostOperation::ServerInfo);
    call.endpoint.serverName = "fe80::20";
    call.endpoint.addresses = {
        {"fe80::20", MoonlightHostAddressFamily::Ipv6, "wlan0"},
    };

    const auto result = executeOnce(call, xmlResponse(serverInfoXml()), &captures);
    RDP_ASSERT(result.ok());
    RDP_ASSERT_EQ(captures.size(), static_cast<std::size_t>(1));
    RDP_ASSERT(captures[0].connectAddress == "fe80::20%wlan0");
    RDP_ASSERT(contains(captures[0].url,
                        "http://[fe80::20%25wlan0]:47989/serverinfo"));
    RDP_ASSERT(result.resolvedAddress.has_value());
    RDP_ASSERT(*result.resolvedAddress == "fe80::20%wlan0");
    RDP_ASSERT_EQ(result.resolvedFamily, MoonlightHostAddressFamily::Ipv6);
}

RDP_TEST_CASE(moonlight_host_api_rejects_success_without_numeric_transport_winner) {
    auto transport = std::make_shared<MissingWinnerTransport>();
    MoonlightHostApi api(transport, uuidGenerator());

    const auto result = api.execute(callFor(MoonlightHostOperation::ServerInfo));

    RDP_ASSERT_EQ(result.error, MoonlightHostError::TransportFailure);
    RDP_ASSERT(!result.resolvedAddress.has_value());
    RDP_ASSERT(!result.serverInfo.has_value());
    RDP_ASSERT(!result.diagnostics.empty());
    RDP_ASSERT_EQ(result.diagnostics.back().stage, MoonlightTransportStage::Commit);
}

RDP_TEST_CASE(moonlight_host_api_returns_http_tls_body_and_xml_failures_without_collapsing_codes) {
    auto httpCall = callFor(MoonlightHostOperation::ServerInfo);
    RDP_ASSERT_EQ(executeOnce(httpCall, xmlResponse("not used", 401)).error,
                  MoonlightHostError::HttpUnauthorized);
    RDP_ASSERT_EQ(executeOnce(httpCall, xmlResponse("not used", 404)).error,
                  MoonlightHostError::HttpNotFound);
    RDP_ASSERT_EQ(executeOnce(httpCall, transportFailure(MoonlightTransportError::TlsVersionFailure,
                                                         MoonlightTransportStage::Tls))
                      .error,
                  MoonlightHostError::TlsVersionFailure);
    auto oversized = xmlResponse("x");
    oversized.receivedBodyBytes = MoonlightHostLimits::kMaxBodyBytes + 1U;
    RDP_ASSERT_EQ(executeOnce(httpCall, std::move(oversized)).error,
                  MoonlightHostError::BodyTooLarge);
    RDP_ASSERT_EQ(executeOnce(httpCall, xmlResponse("<root status_code=\"200\">")).error,
                  MoonlightHostError::MalformedXml);
    RDP_ASSERT_EQ(
        executeOnce(httpCall,
                    xmlResponse("<root status_code=\"200\"><uniqueid>x</uniqueid></root>"))
            .error,
        MoonlightHostError::MissingRequiredField);
}

RDP_TEST_CASE(moonlight_host_api_rejects_xml_entities_pi_utf8_depth_and_size_attacks) {
    auto call = callFor(MoonlightHostOperation::ServerInfo);
    const std::vector<std::string> malformed{
        "<!DOCTYPE root [<!ENTITY x \"boom\">]><root status_code=\"200\">&x;</root>",
        "<root status_code=\"200\"><x>&custom;</x></root>",
        "<root status_code=\"200\"><?attack x?></root>",
        "<?xml-stylesheet href=\"x\"?><root status_code=\"200\"/>",
        "<root status_code=\"200\"><a></root>",
        "<root status_code=\"200\" status_code=\"200\"/>",
        "<root status_code=\"200\"/><root status_code=\"200\"/>",
        "<root status_code=\"200\"/>junk",
        std::string("<root status_code=\"200\"><x>") + static_cast<char>(0xC0) +
            static_cast<char>(0xAF) + "</x></root>",
    };
    for (const auto& body : malformed) {
        const auto rejected = executeOnce(call, xmlResponse(body));
        RDP_ASSERT_EQ(rejected.error, MoonlightHostError::MalformedXml);
        RDP_ASSERT(!rejected.xmlStatus.has_value());
    }

    std::string deep = "<root status_code=\"200\">";
    for (int index = 0; index < 32; ++index)
        deep += "<a>";
    for (int index = 0; index < 32; ++index)
        deep += "</a>";
    deep += "</root>";
    RDP_ASSERT_EQ(executeOnce(call, xmlResponse(deep)).error,
                  MoonlightHostError::XmlBudgetExceeded);

    std::string longText(MoonlightHostLimits::kMaxTextNodeBytes + 1U, 'x');
    RDP_ASSERT_EQ(
        executeOnce(call, xmlResponse("<root status_code=\"200\"><x>" + longText + "</x></root>"))
            .error,
        MoonlightHostError::XmlBudgetExceeded);

    auto tooLarge = xmlResponse("x");
    tooLarge.body.assign(MoonlightHostLimits::kMaxBodyBytes + 1U, 'x');
    tooLarge.receivedBodyBytes = tooLarge.body.size();
    RDP_ASSERT_EQ(executeOnce(call, std::move(tooLarge)).error, MoonlightHostError::BodyTooLarge);

    std::string tooManyAttributes = "<root status_code=\"200\"";
    for (int index = 0; index < 16; ++index) {
        tooManyAttributes += " a" + std::to_string(index) + "=\"x\"";
    }
    tooManyAttributes += "/>";
    RDP_ASSERT_EQ(executeOnce(call, xmlResponse(tooManyAttributes)).error,
                  MoonlightHostError::XmlBudgetExceeded);

    const std::string longName(MoonlightHostLimits::kMaxXmlNameBytes + 1U, 'a');
    RDP_ASSERT_EQ(
        executeOnce(call, xmlResponse("<root status_code=\"200\"><" + longName + "/></root>"))
            .error,
        MoonlightHostError::XmlBudgetExceeded);

    std::string tooManyElements = "<root status_code=\"200\">";
    for (std::size_t index = 0; index < MoonlightHostLimits::kMaxXmlElements; ++index) {
        tooManyElements += "<a/>";
    }
    tooManyElements += "</root>";
    RDP_ASSERT_EQ(executeOnce(call, xmlResponse(tooManyElements)).error,
                  MoonlightHostError::XmlBudgetExceeded);

    auto appCall = callFor(MoonlightHostOperation::AppList, true);
    std::string tooManyApps = "<root status_code=\"200\">";
    for (std::size_t index = 1; index <= MoonlightHostLimits::kMaxApps + 1U; ++index) {
        tooManyApps += "<App><AppTitle>A</AppTitle><ID>" + std::to_string(index) + "</ID></App>";
    }
    tooManyApps += "</root>";
    RDP_ASSERT_EQ(executeOnce(appCall, xmlResponse(tooManyApps)).error,
                  MoonlightHostError::XmlBudgetExceeded);
}

RDP_TEST_CASE(moonlight_host_api_deterministic_xml_fuzz_corpus_fails_closed) {
    const auto call = callFor(MoonlightHostOperation::ServerInfo);
    std::uint32_t state = 0xC0DEC0DEU;
    for (std::size_t caseIndex = 0; caseIndex < 512U; ++caseIndex) {
        state = state * 1664525U + 1013904223U;
        const std::size_t length = state % 1024U;
        std::string body;
        body.reserve(length);
        for (std::size_t byteIndex = 0; byteIndex < length; ++byteIndex) {
            state = state * 1664525U + 1013904223U;
            body.push_back(static_cast<char>((state >> 16U) & 0xFFU));
        }
        const auto result = executeOnce(call, xmlResponse(body));
        RDP_ASSERT(!result.ok());
        RDP_ASSERT(result.key == call.key);
        RDP_ASSERT(result.diagnostics.size() <= static_cast<std::size_t>(1));
    }

    const auto valid = serverInfoXml();
    for (std::size_t cut = 0; cut < valid.size(); cut += 17U) {
        const auto result = executeOnce(call, xmlResponse(valid.substr(0, cut)));
        RDP_ASSERT(!result.ok());
        RDP_ASSERT(!result.serverInfo.has_value());
    }
}

RDP_TEST_CASE(moonlight_host_api_allows_read_only_fallback_but_never_replays_unknown_mutation) {
    {
        auto transport = std::make_shared<ScriptedTransport>();
        transport->push(
            transportFailure(MoonlightTransportError::DnsFailure, MoonlightTransportStage::Dns));
        transport->push(xmlResponse(serverInfoXml()));
        MoonlightHostApi api(transport, uuidGenerator());
        auto call = callFor(MoonlightHostOperation::ServerInfo);
        call.endpoint.addresses.push_back({"192.0.2.11", MoonlightHostAddressFamily::Ipv4});
        const auto result = api.execute(call);
        RDP_ASSERT(result.ok());
        RDP_ASSERT_EQ(transport->captures().size(), static_cast<std::size_t>(2));
        RDP_ASSERT(result.resolvedAddress.has_value());
        RDP_ASSERT(*result.resolvedAddress == "192.0.2.11");
        RDP_ASSERT_EQ(result.resolvedFamily, MoonlightHostAddressFamily::Ipv4);
    }
    {
        auto transport = std::make_shared<ScriptedTransport>();
        transport->push(transportFailure(MoonlightTransportError::Timeout,
                                         MoonlightTransportStage::Body,
                                         MoonlightTransportSendState::SentResponseUnknown));
        transport->push(
            xmlResponse("<root status_code=\"200\"><gamesession>1</gamesession></root>"));
        MoonlightHostApi api(transport, uuidGenerator());
        auto call = callFor(MoonlightHostOperation::Launch, true);
        call.query = launchQuery();
        call.endpoint.addresses.push_back({"192.0.2.11", MoonlightHostAddressFamily::Ipv4});
        const auto result = api.execute(call);
        RDP_ASSERT_EQ(result.error, MoonlightHostError::ActionUnknown);
        RDP_ASSERT(result.action->outcomeUnknown);
        RDP_ASSERT(result.mutationOutcomeUnknown);
        RDP_ASSERT_EQ(transport->captures().size(), static_cast<std::size_t>(1));
    }
    {
        auto transport = std::make_shared<ScriptedTransport>();
        transport->push(transportFailure(MoonlightTransportError::ConnectFailure,
                                         MoonlightTransportStage::Connect,
                                         MoonlightTransportSendState::NotSent));
        transport->push(xmlResponse("<root status_code=\"200\"><cancel>1</cancel></root>"));
        transport->push(xmlResponse(idleServerInfoXml()));
        MoonlightHostApi api(transport, uuidGenerator());
        auto call = callFor(MoonlightHostOperation::Cancel, true);
        call.endpoint.addresses.push_back({"192.0.2.11", MoonlightHostAddressFamily::Ipv4});
        const auto result = api.execute(call);
        RDP_ASSERT(result.ok());
        RDP_ASSERT_EQ(transport->captures().size(), static_cast<std::size_t>(3));
    }
    {
        auto call = callFor(MoonlightHostOperation::Launch, true);
        call.query = launchQuery();
        const auto malformed = executeOnce(
            call, xmlResponse("<root status_code=\"200\"><unexpected>1</unexpected></root>"));
        RDP_ASSERT_EQ(malformed.error, MoonlightHostError::MissingRequiredField);
        RDP_ASSERT(malformed.mutationOutcomeUnknown);
    }
}

RDP_TEST_CASE(moonlight_host_api_preserves_trust_conflict_and_only_exposes_http_candidate) {
    auto transport = std::make_shared<ScriptedTransport>();
    transport->push(
        transportFailure(MoonlightTransportError::TrustConflict, MoonlightTransportStage::Tls));
    transport->push(xmlResponse(serverInfoXml()));
    MoonlightHostApi api(transport, uuidGenerator());
    auto call = callFor(MoonlightHostOperation::ServerInfo, true);
    call.endpoint.allowHttpPairingCandidate = true;
    const auto result = api.execute(call);
    RDP_ASSERT_EQ(result.error, MoonlightHostError::TrustConflict);
    RDP_ASSERT(result.candidateOnly);
    RDP_ASSERT(result.serverInfo.has_value());
    const auto captures = transport->captures();
    RDP_ASSERT_EQ(captures.size(), static_cast<std::size_t>(2));
    RDP_ASSERT_EQ(captures[0].scheme, MoonlightHostScheme::Https);
    RDP_ASSERT_EQ(captures[1].scheme, MoonlightHostScheme::Http);
    RDP_ASSERT(!captures[1].requiresClientIdentity);
    RDP_ASSERT(!captures[1].requiresServerPin);
}

RDP_TEST_CASE(moonlight_host_api_pairing_lane_recovers_from_remote_unpair_via_http_candidate) {
    auto transport = std::make_shared<ScriptedTransport>();
    transport->push(xmlResponse("not used", 401));
    auto unpaired = serverInfoXml();
    const auto pairStatus = unpaired.find("<PairStatus>1</PairStatus>");
    unpaired.replace(pairStatus, std::string("<PairStatus>1</PairStatus>").size(),
                     "<PairStatus>0</PairStatus>");
    transport->push(xmlResponse(unpaired));

    MoonlightHostApi api(transport, uuidGenerator());
    auto call = callFor(MoonlightHostOperation::ServerInfo, true);
    call.endpoint.allowHttpPairingCandidate = true;
    const auto result = api.execute(call);

    RDP_ASSERT(result.ok());
    RDP_ASSERT(result.candidateOnly);
    RDP_ASSERT(result.serverInfo.has_value());
    RDP_ASSERT(!result.serverInfo->paired);
    const auto captures = transport->captures();
    RDP_ASSERT_EQ(captures.size(), static_cast<std::size_t>(2));
    RDP_ASSERT_EQ(captures[0].scheme, MoonlightHostScheme::Https);
    RDP_ASSERT(captures[0].requiresClientIdentity);
    RDP_ASSERT(captures[0].requiresServerPin);
    RDP_ASSERT_EQ(captures[1].scheme, MoonlightHostScheme::Http);
    RDP_ASSERT(!captures[1].requiresClientIdentity);
    RDP_ASSERT(!captures[1].requiresServerPin);
}

RDP_TEST_CASE(moonlight_host_api_never_downgrades_unauthorized_control_serverinfo) {
    auto transport = std::make_shared<ScriptedTransport>();
    transport->push(xmlResponse("not used", 401));
    MoonlightHostApi api(transport, uuidGenerator());
    auto call = callFor(MoonlightHostOperation::ServerInfo, true);

    const auto result = api.execute(call);

    RDP_ASSERT_EQ(result.error, MoonlightHostError::HttpUnauthorized);
    const auto captures = transport->captures();
    RDP_ASSERT_EQ(captures.size(), static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(captures[0].scheme, MoonlightHostScheme::Https);
}

RDP_TEST_CASE(moonlight_host_api_exact_cancel_stale_and_duplicate_request_fences) {
    for (const bool stale : {false, true}) {
        auto transport = std::make_shared<ScriptedTransport>();
        BlockingGate gate;
        transport->setHandler([&](const MoonlightTransportRequest&,
                                  std::chrono::steady_clock::time_point,
                                  const MoonlightHostTransport::CancellationProbe& probe) {
            gate.entered();
            gate.waitReleased();
            return transportFailure(probe() ? MoonlightTransportError::Cancelled
                                            : MoonlightTransportError::ProtocolFailure,
                                    MoonlightTransportStage::Body,
                                    MoonlightTransportSendState::ConfirmedResponse);
        });
        MoonlightHostApi api(transport, uuidGenerator());
        const auto call =
            callFor(MoonlightHostOperation::ServerInfo, false,
                    stale ? MoonlightHostRequestKey{91, 8, 7} : MoonlightHostRequestKey{90, 8, 7});
        MoonlightHostResult result;
        std::thread worker([&]() { result = api.execute(call); });
        RDP_ASSERT(gate.waitEntered());
        auto wrong = call.key;
        ++wrong.generation;
        RDP_ASSERT(!api.cancel(wrong));
        RDP_ASSERT_EQ(api.execute(call).error, MoonlightHostError::RequestBusy);
        RDP_ASSERT(stale ? api.markStale(call.key) : api.cancel(call.key));
        gate.release();
        worker.join();
        RDP_ASSERT_EQ(result.error,
                      stale ? MoonlightHostError::StaleRequest : MoonlightHostError::Cancelled);
        RDP_ASSERT(!result.serverInfo.has_value());
    }
}

RDP_TEST_CASE(moonlight_host_api_retires_inflight_and_expected_generation_before_transport) {
    remotedesk::net::NetworkGenerationFence fence(41U, true);
    auto transport = std::make_shared<ScriptedTransport>();
    std::atomic<bool> cancellationObserved {false};
    transport->setHandler(
        [&](const MoonlightTransportRequest&,
            std::chrono::steady_clock::time_point,
            const MoonlightHostTransport::CancellationProbe& probe) {
            RDP_ASSERT(fence.update(true, 42U));
            cancellationObserved.store(probe(), std::memory_order_release);
            return transportFailure(
                MoonlightTransportError::Cancelled,
                MoonlightTransportStage::Connect,
                MoonlightTransportSendState::NotSent);
        });
    MoonlightHostApi api(transport, uuidGenerator(), &fence);
    auto call = callFor(MoonlightHostOperation::ServerInfo, false,
                        {191U, 8U, 7U});

    const auto retired = api.execute(call);
    RDP_ASSERT(cancellationObserved.load(std::memory_order_acquire));
    RDP_ASSERT_EQ(retired.error, MoonlightHostError::StaleRequest);
    RDP_ASSERT_EQ(retired.networkGeneration, static_cast<std::uint64_t>(41U));

    call.key.requestId = 192U;
    call.expectedNetworkGeneration = 41U;
    const auto rejected = api.execute(call);
    RDP_ASSERT_EQ(rejected.error, MoonlightHostError::StaleRequest);
    RDP_ASSERT_EQ(rejected.networkGeneration, static_cast<std::uint64_t>(42U));
    RDP_ASSERT_EQ(transport->captures().size(), static_cast<std::size_t>(1U));

    transport->setHandler(
        [&](const MoonlightTransportRequest& request,
            std::chrono::steady_clock::time_point,
            const MoonlightHostTransport::CancellationProbe&) {
            RDP_ASSERT(fence.update(true, 43U));
            auto outcome = xmlResponse(
                "<root status_code=\"200\"><gamesession>1</gamesession></root>");
            outcome.resolvedAddress = request.connectAddress();
            outcome.resolvedFamily = request.family();
            return outcome;
        });
    call = callFor(MoonlightHostOperation::Launch, true,
                   {193U, 8U, 7U});
    call.query = launchQuery();
    call.expectedNetworkGeneration = 42U;
    const auto mutation = api.execute(call);
    RDP_ASSERT_EQ(mutation.error, MoonlightHostError::ActionUnknown);
    RDP_ASSERT(mutation.action.has_value());
    RDP_ASSERT(mutation.action->outcomeUnknown);
    RDP_ASSERT(mutation.mutationOutcomeUnknown);
    RDP_ASSERT_EQ(mutation.networkGeneration, static_cast<std::uint64_t>(42U));
    RDP_ASSERT_EQ(transport->captures().size(), static_cast<std::size_t>(2U));
}

RDP_TEST_CASE(moonlight_host_api_destructor_cancels_and_drains_inflight_transport) {
    auto transport = std::make_shared<ScriptedTransport>();
    BlockingGate gate;
    std::atomic<bool> sawCancellation{false};
    transport->setHandler([&](const MoonlightTransportRequest&,
                              std::chrono::steady_clock::time_point,
                              const MoonlightHostTransport::CancellationProbe& probe) {
        gate.entered();
        gate.waitReleased();
        const auto deadline = std::chrono::steady_clock::now() + 1s;
        while (!probe() && std::chrono::steady_clock::now() < deadline) {
            std::this_thread::yield();
        }
        sawCancellation.store(probe());
        return transportFailure(MoonlightTransportError::Cancelled, MoonlightTransportStage::Body,
                                MoonlightTransportSendState::ConfirmedResponse);
    });
    auto api = std::make_unique<MoonlightHostApi>(transport, uuidGenerator());
    MoonlightHostResult result;
    std::thread worker(
        [&]() { result = api->execute(callFor(MoonlightHostOperation::ServerInfo)); });
    RDP_ASSERT(gate.waitEntered());
    std::thread destroyer([&]() { api.reset(); });
    gate.release();
    worker.join();
    destroyer.join();
    RDP_ASSERT(sawCancellation.load());
    RDP_ASSERT_EQ(result.error, MoonlightHostError::Cancelled);
}
