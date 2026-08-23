#include "moonlight/control/MoonlightHostControl.h"
#include "test_runner.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

using namespace remotedesk::moonlight;
using namespace std::chrono_literals;

const std::string OWNER_A(64U, 'a');
const std::string OWNER_B(64U, 'b');
constexpr std::uint64_t NOW_MS = 1780000000000ULL;

class Barrier final {
public:
    void enter() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            entered_ = true;
        }
        cv_.notify_all();
    }

    bool waitEntered() {
        std::unique_lock<std::mutex> lock(mutex_);
        return cv_.wait_for(lock, 2s, [&]() { return entered_; });
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

struct CapturedRequest final {
    MoonlightHostOperation operation = MoonlightHostOperation::ServerInfo;
    MoonlightHostScheme scheme = MoonlightHostScheme::Http;
    bool requiresIdentity = false;
    bool requiresPin = false;
    std::string redacted;
    std::chrono::steady_clock::time_point deadline {};
};

class ControlTransport final : public MoonlightHostTransport {
public:
    using Handler = std::function<MoonlightTransportOutcome(
        const MoonlightTransportRequest&, std::chrono::steady_clock::time_point,
        const CancellationProbe&)>;

    MoonlightTransportOutcome execute(
        const MoonlightTransportRequest& request,
        std::chrono::steady_clock::time_point absoluteDeadline,
        const CancellationProbe& cancellationProbe) override {
        Handler handler;
        MoonlightTransportOutcome outcome;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            captures_.push_back({request.operation(), request.scheme(),
                                 request.requiresClientIdentity(), request.requiresServerPin(),
                                 request.redactedDebugString(), absoluteDeadline});
            if (request.operation() == MoonlightHostOperation::Launch ||
                request.operation() == MoonlightHostOperation::Resume) {
                sawLaunchCanary_ = request.url().find("A0A1A2A3A4A5A6A7") !=
                                   std::string::npos;
                redactedContainsCanary_ =
                    request.redactedDebugString().find("A0A1A2A3A4A5A6A7") !=
                    std::string::npos;
            }
            handler = handler_;
            if (!outcomes_.empty()) {
                outcome = std::move(outcomes_.front());
                outcomes_.pop_front();
            } else {
                outcome.error = MoonlightTransportError::ProtocolFailure;
                outcome.stage = MoonlightTransportStage::Http;
                outcome.sendState = MoonlightTransportSendState::NotSent;
            }
        }
        if (handler) {
            return handler(request, absoluteDeadline, cancellationProbe);
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

    std::size_t count(MoonlightHostOperation operation) const {
        const auto values = captures();
        return static_cast<std::size_t>(
            std::count_if(values.begin(), values.end(), [&](const auto& item) {
                return item.operation == operation;
            }));
    }

    bool sawLaunchCanary() const noexcept { return sawLaunchCanary_.load(); }
    bool redactedContainsCanary() const noexcept { return redactedContainsCanary_.load(); }

private:
    mutable std::mutex mutex_;
    std::deque<MoonlightTransportOutcome> outcomes_;
    std::vector<CapturedRequest> captures_;
    Handler handler_;
    std::atomic<bool> sawLaunchCanary_ {false};
    std::atomic<bool> redactedContainsCanary_ {false};
};

class ControlAccessPort final : public MoonlightHostControlAccessPort {
public:
    using Handler = std::function<MoonlightHostControlAccessCode(
        const MoonlightHostControlContext&, std::chrono::steady_clock::time_point,
        const CancellationProbe&)>;

    bool available() const noexcept override { return available_.load(); }

    MoonlightHostControlAccessCode authorize(
        const MoonlightHostControlContext& context,
        std::chrono::steady_clock::time_point absoluteDeadline,
        const CancellationProbe& cancellationProbe) override {
        Handler handler;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            ++authorizeCount_;
            lastKey_ = context.key;
            handler = handler_;
        }
        if (handler) {
            return handler(context, absoluteDeadline, cancellationProbe);
        }
        return code_.load();
    }

    void cancel(const MoonlightHostControlOperationKey& key) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        ++cancelCount_;
        lastCancelledKey_ = key;
        if (cancelCallback_) {
            cancelCallback_();
        }
    }

    void setHandler(Handler handler) {
        std::lock_guard<std::mutex> lock(mutex_);
        handler_ = std::move(handler);
    }

    void setCancelCallback(std::function<void()> callback) {
        std::lock_guard<std::mutex> lock(mutex_);
        cancelCallback_ = std::move(callback);
    }

    std::size_t authorizeCount() const noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        return authorizeCount_;
    }

    std::size_t cancelCount() const noexcept {
        std::lock_guard<std::mutex> lock(mutex_);
        return cancelCount_;
    }

    std::atomic<bool> available_ {true};
    std::atomic<MoonlightHostControlAccessCode> code_ {MoonlightHostControlAccessCode::Ready};

private:
    mutable std::mutex mutex_;
    Handler handler_;
    std::function<void()> cancelCallback_;
    std::size_t authorizeCount_ = 0;
    std::size_t cancelCount_ = 0;
    MoonlightHostControlOperationKey lastKey_ {};
    MoonlightHostControlOperationKey lastCancelledKey_ {};
};

MoonlightTransportOutcome xmlResponse(std::string body) {
    MoonlightTransportOutcome outcome;
    outcome.stage = MoonlightTransportStage::Body;
    outcome.sendState = MoonlightTransportSendState::ConfirmedResponse;
    outcome.httpStatus = 200;
    outcome.receivedBodyBytes = body.size();
    outcome.body = std::move(body);
    return outcome;
}

MoonlightTransportOutcome assetResponse(std::string body) {
    return xmlResponse(std::move(body));
}

MoonlightTransportOutcome transportFailure(
    MoonlightTransportError error, MoonlightTransportSendState sendState) {
    MoonlightTransportOutcome outcome;
    outcome.error = error;
    outcome.stage = MoonlightTransportStage::Http;
    outcome.sendState = sendState;
    return outcome;
}

std::string serverInfoXml(std::uint32_t currentGame = 0U, bool paired = true,
                          std::string uuid = "SERVER-UUID") {
    return "<root status_code=\"200\"><uniqueid>" + uuid +
           "</uniqueid><appversion>7.1.431.-1</appversion><state>" +
           (currentGame == 0U ? "SUNSHINE_SERVER_READY" : "SUNSHINE_SERVER_BUSY") +
           "</state><PairStatus>" + (paired ? "1" : "0") +
           "</PairStatus><currentgame>" + std::to_string(currentGame) +
           "</currentgame></root>";
}

std::string catalogXml(const std::vector<std::pair<std::uint32_t, std::string>>& apps) {
    std::string xml = "<root status_code=\"200\">";
    for (const auto& app : apps) {
        xml += "<App><AppTitle>" + app.second + "</AppTitle><ID>" +
               std::to_string(app.first) + "</ID><IsHdrSupported>1</IsHdrSupported></App>";
    }
    xml += "</root>";
    return xml;
}

MoonlightHostApi::UuidGenerator uuidGenerator() {
    auto sequence = std::make_shared<std::atomic<unsigned>>(1U);
    return [sequence]() {
        char value[37] {};
        std::snprintf(value, sizeof(value), "00000000-0000-4000-8000-%012u",
                      sequence->fetch_add(1U));
        return std::string(value);
    };
}

MoonlightHostControlContext contextFor(
    std::uint64_t requestId, std::uint64_t generation = 1U,
    const std::string& owner = OWNER_A, const std::string& hostId = "host-a",
    const std::string& serverUuid = "SERVER-UUID") {
    MoonlightHostControlContext context;
    context.key = {requestId, generation, owner == OWNER_A ? 1001U : 2002U};
    context.ownerScopeFingerprint = owner;
    context.hostId = hostId;
    context.serverUuid = serverUuid;
    context.endpoint.serverName = hostId + ".example";
    context.endpoint.addresses = {{"192.0.2.10", MoonlightHostAddressFamily::Ipv4}};
    context.endpoint.pinnedTrustAvailable = true;
    context.endpoint.allowHttpPairingCandidate = false;
    context.timeout = 5s;
    return context;
}

MoonlightLaunchRequest launchRequest(std::uint64_t requestId, std::uint32_t appId = 42U,
                                     std::uint64_t generation = 1U) {
    MoonlightLaunchRequest request;
    request.context = contextFor(requestId, generation);
    request.appId = appId;
    std::vector<std::uint8_t> key(16U);
    for (std::size_t index = 0; index < key.size(); ++index) {
        key[index] = static_cast<std::uint8_t>(0xa0U + index);
    }
    MoonlightLaunchConfiguration configuration;
    configuration.remoteControllersBitmap = 3U;
    configuration.gamepadMask = 3U;
    request.material = MoonlightLaunchMaterial(std::move(key), -2147483647, configuration);
    return request;
}

struct Fixture final {
    explicit Fixture(MoonlightHostControl::MonotonicClock monotonicClock = {},
                     MoonlightHostControl::WallClock wallClock = {})
        : transport(std::make_shared<ControlTransport>()),
          access(std::make_shared<ControlAccessPort>()),
          api(std::make_shared<MoonlightHostApi>(transport, uuidGenerator())),
          control(std::make_unique<MoonlightHostControl>(
              api, access, std::move(monotonicClock),
              wallClock ? std::move(wallClock) : []() { return NOW_MS; })) {}

    MoonlightHostControlResult primeCatalog(std::uint64_t requestId = 1U,
                                            std::uint64_t generation = 1U,
                                            std::vector<std::pair<std::uint32_t, std::string>> apps =
                                                {{42U, "Desktop"}, {7U, "Game"}}) {
        transport->push(xmlResponse(catalogXml(apps)));
        return control->catalog({contextFor(requestId, generation)});
    }

    std::shared_ptr<ControlTransport> transport;
    std::shared_ptr<ControlAccessPort> access;
    std::shared_ptr<MoonlightHostApi> api;
    std::unique_ptr<MoonlightHostControl> control;
};

} // namespace

RDP_TEST_CASE(moonlight_host_control_rejects_invalid_or_unavailable_access_before_network) {
    Fixture fixture;
    auto invalid = contextFor(1U);
    invalid.endpoint.pinnedTrustAvailable = false;
    const auto invalidResult = fixture.control->catalog({invalid});
    RDP_ASSERT_EQ(invalidResult.code, MoonlightHostControlCode::InvalidArgument);
    RDP_ASSERT(fixture.transport->captures().empty());
    RDP_ASSERT_EQ(fixture.access->authorizeCount(), static_cast<std::size_t>(0));

    fixture.access->available_.store(false);
    const auto unavailable = fixture.control->catalog({contextFor(2U)});
    RDP_ASSERT_EQ(unavailable.code, MoonlightHostControlCode::Unavailable);
    RDP_ASSERT(fixture.transport->captures().empty());
}

RDP_TEST_CASE(moonlight_host_control_catalog_is_authenticated_transactional_and_allows_empty) {
    Fixture fixture;
    const auto complete = fixture.primeCatalog();
    RDP_ASSERT(complete.ok());
    RDP_ASSERT_EQ(complete.apps.size(), static_cast<std::size_t>(2));
    RDP_ASSERT_EQ(complete.generation, static_cast<std::uint64_t>(1));
    RDP_ASSERT_EQ(complete.observedAtMs, NOW_MS);
    RDP_ASSERT_EQ(complete.preflightTruth, MoonlightHostControlTruth::Confirmed);
    const auto captures = fixture.transport->captures();
    RDP_ASSERT_EQ(captures.size(), static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(captures[0].scheme, MoonlightHostScheme::Https);
    RDP_ASSERT(captures[0].requiresIdentity);
    RDP_ASSERT(captures[0].requiresPin);

    fixture.transport->push(xmlResponse(catalogXml({})));
    const auto empty = fixture.control->catalog({contextFor(2U)});
    RDP_ASSERT(empty.ok());
    RDP_ASSERT(empty.apps.empty());
}

RDP_TEST_CASE(moonlight_host_control_catalog_rejects_partial_and_duplicate_batches) {
    Fixture partialFixture;
    partialFixture.transport->push(xmlResponse(
        "<root status_code=\"200\"><App><AppTitle>Good</AppTitle><ID>42</ID></App>"
        "<App><AppTitle>Bad</AppTitle><ID>0</ID></App></root>"));
    const auto partial = partialFixture.control->catalog({contextFor(1U)});
    RDP_ASSERT_EQ(partial.code, MoonlightHostControlCode::InvalidCatalog);
    RDP_ASSERT_EQ(partial.partialAppCount, static_cast<std::size_t>(1));
    RDP_ASSERT(partial.apps.empty());

    Fixture duplicateFixture;
    duplicateFixture.transport->push(xmlResponse(
        "<root status_code=\"200\"><App><AppTitle>A</AppTitle><ID>42</ID></App>"
        "<App><AppTitle>B</AppTitle><ID>42</ID></App></root>"));
    const auto duplicate = duplicateFixture.control->catalog({contextFor(1U)});
    RDP_ASSERT_EQ(duplicate.code, MoonlightHostControlCode::InvalidCatalog);
    RDP_ASSERT(duplicate.apps.empty());
}

RDP_TEST_CASE(moonlight_host_control_catalog_retains_sunshine_nameless_app) {
    Fixture fixture;
    fixture.transport->push(xmlResponse(
        "<root status_code=\"200\"><App><AppTitle/><ID>42</ID></App></root>"));
    const auto catalog = fixture.control->catalog({contextFor(1U)});
    RDP_ASSERT(catalog.ok());
    RDP_ASSERT_EQ(catalog.partialAppCount, static_cast<std::size_t>(0));
    RDP_ASSERT_EQ(catalog.apps.size(), static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(catalog.apps[0].id, static_cast<std::uint32_t>(42));
    RDP_ASSERT(catalog.apps[0].title == "Application 42");
}

RDP_TEST_CASE(moonlight_host_control_asset_requires_matching_catalog_and_known_app) {
    Fixture fixture;
    RDP_ASSERT(fixture.primeCatalog().ok());
    const auto before = fixture.transport->captures().size();

    MoonlightAssetRequest stale {contextFor(2U), 42U, 9U};
    RDP_ASSERT_EQ(fixture.control->asset(stale).code, MoonlightHostControlCode::Stale);
    MoonlightAssetRequest unknown {contextFor(3U), 99U, 1U};
    RDP_ASSERT_EQ(fixture.control->asset(unknown).code, MoonlightHostControlCode::AppNotFound);
    RDP_ASSERT_EQ(fixture.transport->captures().size(), before);

    fixture.transport->push(assetResponse("cover-bytes"));
    MoonlightAssetRequest valid {contextFor(4U), 42U, 1U};
    const auto result = fixture.control->asset(valid);
    RDP_ASSERT(result.ok());
    RDP_ASSERT(std::string(result.asset.begin(), result.asset.end()) == "cover-bytes");
}

RDP_TEST_CASE(moonlight_host_control_asset_failure_does_not_poison_catalog) {
    Fixture fixture;
    RDP_ASSERT(fixture.primeCatalog().ok());
    fixture.transport->push(transportFailure(MoonlightTransportError::ConnectFailure,
                                             MoonlightTransportSendState::NotSent));
    MoonlightAssetRequest first {contextFor(2U), 42U, 1U};
    RDP_ASSERT_EQ(fixture.control->asset(first).code, MoonlightHostControlCode::TransportFailure);

    fixture.transport->push(assetResponse("retry-cover"));
    MoonlightAssetRequest second {contextFor(3U), 42U, 1U};
    const auto recovered = fixture.control->asset(second);
    RDP_ASSERT(recovered.ok());
}

RDP_TEST_CASE(moonlight_host_control_asset_body_budget_fails_closed) {
    Fixture fixture;
    RDP_ASSERT(fixture.primeCatalog().ok());
    auto oversized = assetResponse("truncated");
    oversized.receivedBodyBytes = MoonlightHostLimits::kMaxBodyBytes + 1U;
    fixture.transport->push(std::move(oversized));
    MoonlightAssetRequest request {contextFor(2U), 42U, 1U};
    const auto result = fixture.control->asset(request);
    RDP_ASSERT_EQ(result.code, MoonlightHostControlCode::ProtocolFailure);
    RDP_ASSERT(result.asset.empty());
}

RDP_TEST_CASE(moonlight_host_control_launch_uses_authenticated_idle_snapshot_without_rtsp_deadlock) {
    Fixture fixture;
    RDP_ASSERT(fixture.primeCatalog().ok());
    fixture.transport->push(xmlResponse(serverInfoXml(0U)));
    fixture.transport->push(xmlResponse(
        "<root status_code=\"200\"><gamesession>1</gamesession>"
        "<sessionUrl0>rtspenc://session-token</sessionUrl0></root>"));
    MoonlightHostControl::resetSecureCleanseCountForTesting();
    const auto result = fixture.control->launch(launchRequest(2U));
    RDP_ASSERT(result.ok());
    RDP_ASSERT_EQ(result.preflightTruth, MoonlightHostControlTruth::Confirmed);
    RDP_ASSERT_EQ(result.actionTruth, MoonlightHostControlTruth::Confirmed);
    RDP_ASSERT_EQ(result.postconditionTruth, MoonlightHostControlTruth::Unknown);
    RDP_ASSERT(result.rtspSessionUrl.has_value());
    RDP_ASSERT(*result.rtspSessionUrl == "rtspenc://session-token");
    RDP_ASSERT(result.sessionAddress.has_value());
    RDP_ASSERT(*result.sessionAddress == "192.0.2.10");
    RDP_ASSERT(result.sessionServerInfo.has_value());
    RDP_ASSERT_EQ(result.sessionServerInfo->currentGame, 42U);
    RDP_ASSERT(fixture.transport->sawLaunchCanary());
    RDP_ASSERT(!fixture.transport->redactedContainsCanary());
    RDP_ASSERT(MoonlightHostControl::secureCleanseCountForTesting() >= 12U);
    RDP_ASSERT_EQ(fixture.transport->count(MoonlightHostOperation::Launch),
                  static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(fixture.transport->count(MoonlightHostOperation::ServerInfo),
                  static_cast<std::size_t>(1));
    RDP_ASSERT(!result.diagnostics.empty());
    for (const auto& diagnostic : result.diagnostics) {
        RDP_ASSERT(diagnostic.appIdFingerprint <= 0x1fffffffffffffULL);
    }
}

RDP_TEST_CASE(moonlight_host_control_launch_never_auto_resumes_or_quits) {
    Fixture sameApp;
    RDP_ASSERT(sameApp.primeCatalog().ok());
    sameApp.transport->push(xmlResponse(serverInfoXml(42U)));
    const auto resumeRequired = sameApp.control->launch(launchRequest(2U));
    RDP_ASSERT_EQ(resumeRequired.code, MoonlightHostControlCode::ResumeRequired);
    RDP_ASSERT_EQ(sameApp.transport->count(MoonlightHostOperation::Launch),
                  static_cast<std::size_t>(0));
    RDP_ASSERT_EQ(sameApp.transport->count(MoonlightHostOperation::Cancel),
                  static_cast<std::size_t>(0));

    Fixture otherApp;
    RDP_ASSERT(otherApp.primeCatalog().ok());
    otherApp.transport->push(xmlResponse(serverInfoXml(7U)));
    const auto busy = otherApp.control->launch(launchRequest(2U));
    RDP_ASSERT_EQ(busy.code, MoonlightHostControlCode::HostBusy);
    RDP_ASSERT_EQ(otherApp.transport->count(MoonlightHostOperation::Launch),
                  static_cast<std::size_t>(0));
    RDP_ASSERT_EQ(otherApp.transport->count(MoonlightHostOperation::Cancel),
                  static_cast<std::size_t>(0));
}

RDP_TEST_CASE(moonlight_host_control_invalid_app_never_reaches_host_mutation) {
    Fixture fixture;
    RDP_ASSERT(fixture.primeCatalog().ok());
    const auto result = fixture.control->launch(launchRequest(2U, 99U));
    RDP_ASSERT_EQ(result.code, MoonlightHostControlCode::AppNotFound);
    RDP_ASSERT_EQ(fixture.transport->count(MoonlightHostOperation::ServerInfo),
                  static_cast<std::size_t>(0));
    RDP_ASSERT_EQ(fixture.transport->count(MoonlightHostOperation::Launch),
                  static_cast<std::size_t>(0));
}

RDP_TEST_CASE(moonlight_host_control_unpaired_uuid_change_and_pin_conflict_fail_closed) {
    Fixture unpaired;
    RDP_ASSERT(unpaired.primeCatalog().ok());
    unpaired.transport->push(xmlResponse(serverInfoXml(0U, false)));
    RDP_ASSERT_EQ(unpaired.control->launch(launchRequest(2U)).code,
                  MoonlightHostControlCode::Unpaired);
    RDP_ASSERT_EQ(unpaired.transport->count(MoonlightHostOperation::Launch),
                  static_cast<std::size_t>(0));

    Fixture changed;
    RDP_ASSERT(changed.primeCatalog().ok());
    changed.transport->push(xmlResponse(serverInfoXml(0U, true, "CHANGED-UUID")));
    RDP_ASSERT_EQ(changed.control->launch(launchRequest(2U)).code,
                  MoonlightHostControlCode::Stale);

    Fixture pinConflict;
    RDP_ASSERT(pinConflict.primeCatalog().ok());
    pinConflict.transport->push(transportFailure(MoonlightTransportError::TrustConflict,
                                                 MoonlightTransportSendState::NotSent));
    RDP_ASSERT_EQ(pinConflict.control->launch(launchRequest(2U)).code,
                  MoonlightHostControlCode::Stale);
}

RDP_TEST_CASE(moonlight_host_control_resume_only_targets_the_exact_running_app) {
    Fixture success;
    RDP_ASSERT(success.primeCatalog().ok());
    success.transport->push(xmlResponse(serverInfoXml(42U)));
    success.transport->push(xmlResponse(
        "<root status_code=\"200\"><resume>1</resume>"
        "<sessionUrl0>rtsp://resume</sessionUrl0></root>"));
    success.transport->push(xmlResponse(serverInfoXml(42U)));
    RDP_ASSERT(success.control->resume(launchRequest(2U)).ok());

    Fixture idle;
    RDP_ASSERT(idle.primeCatalog().ok());
    idle.transport->push(xmlResponse(serverInfoXml(0U)));
    RDP_ASSERT_EQ(idle.control->resume(launchRequest(2U)).code,
                  MoonlightHostControlCode::ActionRejected);

    Fixture other;
    RDP_ASSERT(other.primeCatalog().ok());
    other.transport->push(xmlResponse(serverInfoXml(7U)));
    RDP_ASSERT_EQ(other.control->resume(launchRequest(2U)).code,
                  MoonlightHostControlCode::HostBusy);
}

RDP_TEST_CASE(moonlight_host_control_action_reject_and_missing_rtsp_are_not_success) {
    Fixture rejected;
    RDP_ASSERT(rejected.primeCatalog().ok());
    rejected.transport->push(xmlResponse(serverInfoXml(0U)));
    rejected.transport->push(xmlResponse(
        "<root status_code=\"200\"><gamesession>0</gamesession></root>"));
    const auto rejectedResult = rejected.control->launch(launchRequest(2U));
    RDP_ASSERT_EQ(rejectedResult.code, MoonlightHostControlCode::ActionRejected);
    RDP_ASSERT_EQ(rejectedResult.actionTruth, MoonlightHostControlTruth::Failed);

    Fixture missingRtsp;
    RDP_ASSERT(missingRtsp.primeCatalog().ok());
    missingRtsp.transport->push(xmlResponse(serverInfoXml(0U)));
    missingRtsp.transport->push(xmlResponse(
        "<root status_code=\"200\"><gamesession>1</gamesession></root>"));
    const auto unknown = missingRtsp.control->launch(launchRequest(2U));
    RDP_ASSERT_EQ(unknown.code, MoonlightHostControlCode::OutcomeUnknown);
    RDP_ASSERT_EQ(unknown.postconditionTruth, MoonlightHostControlTruth::Unknown);
    RDP_ASSERT(!unknown.rtspSessionUrl.has_value());
}

RDP_TEST_CASE(moonlight_host_control_explicit_xml_rejection_is_known_failure) {
    Fixture fixture;
    RDP_ASSERT(fixture.primeCatalog().ok());
    fixture.transport->push(xmlResponse(serverInfoXml(0U)));
    fixture.transport->push(xmlResponse(
        "<root status_code=\"470\" status_message=\"not owner\"></root>"));
    const auto result = fixture.control->launch(launchRequest(2U));
    RDP_ASSERT_EQ(result.code, MoonlightHostControlCode::ActionRejected);
    RDP_ASSERT_EQ(result.actionTruth, MoonlightHostControlTruth::Failed);
    RDP_ASSERT(result.mutationMayHaveBeenSent);
    RDP_ASSERT_EQ(fixture.transport->count(MoonlightHostOperation::Launch),
                  static_cast<std::size_t>(1));
}

RDP_TEST_CASE(moonlight_host_control_launch_does_not_wait_for_postcondition_or_replay) {
    Fixture fixture;
    RDP_ASSERT(fixture.primeCatalog().ok());
    fixture.transport->push(xmlResponse(serverInfoXml(0U)));
    fixture.transport->push(xmlResponse(
        "<root status_code=\"200\"><gamesession>1</gamesession>"
        "<sessionUrl0>rtsp://candidate</sessionUrl0></root>"));
    const auto result = fixture.control->launch(launchRequest(2U));
    RDP_ASSERT_EQ(result.code, MoonlightHostControlCode::Ok);
    RDP_ASSERT_EQ(result.postconditionTruth, MoonlightHostControlTruth::Unknown);
    RDP_ASSERT(result.rtspSessionUrl.has_value());
    RDP_ASSERT(result.sessionServerInfo.has_value());
    RDP_ASSERT_EQ(result.sessionServerInfo->currentGame, 42U);
    RDP_ASSERT_EQ(fixture.transport->count(MoonlightHostOperation::Launch),
                  static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(fixture.transport->count(MoonlightHostOperation::ServerInfo),
                  static_cast<std::size_t>(1));
}

RDP_TEST_CASE(moonlight_host_control_maybe_sent_action_is_never_replayed) {
    Fixture fixture;
    RDP_ASSERT(fixture.primeCatalog().ok());
    fixture.transport->push(xmlResponse(serverInfoXml(0U)));
    fixture.transport->push(transportFailure(MoonlightTransportError::Timeout,
                                             MoonlightTransportSendState::SentResponseUnknown));
    const auto result = fixture.control->launch(launchRequest(2U));
    RDP_ASSERT_EQ(result.code, MoonlightHostControlCode::OutcomeUnknown);
    RDP_ASSERT(result.mutationMayHaveBeenSent);
    RDP_ASSERT_EQ(fixture.transport->count(MoonlightHostOperation::Launch),
                  static_cast<std::size_t>(1));
}

RDP_TEST_CASE(moonlight_host_control_host_api_may_retry_only_a_not_sent_address) {
    Fixture fixture;
    RDP_ASSERT(fixture.primeCatalog().ok());
    auto request = launchRequest(2U);
    request.context.endpoint.addresses.push_back(
        {"192.0.2.11", MoonlightHostAddressFamily::Ipv4});
    fixture.transport->push(xmlResponse(serverInfoXml(0U)));
    fixture.transport->push(transportFailure(MoonlightTransportError::ConnectFailure,
                                             MoonlightTransportSendState::NotSent));
    fixture.transport->push(xmlResponse(
        "<root status_code=\"200\"><gamesession>1</gamesession>"
        "<sessionUrl0>rtsp://fallback</sessionUrl0></root>"));
    fixture.transport->push(xmlResponse(serverInfoXml(42U)));
    const auto result = fixture.control->launch(std::move(request));
    RDP_ASSERT(result.ok());
    RDP_ASSERT_EQ(fixture.transport->count(MoonlightHostOperation::Launch),
                  static_cast<std::size_t>(2));
}

RDP_TEST_CASE(moonlight_host_control_quit_is_explicit_confirmed_and_idle_idempotent) {
    Fixture idle;
    idle.transport->push(xmlResponse(serverInfoXml(0U)));
    MoonlightQuitRequest idleRequest {contextFor(1U), 0U, false};
    const auto idleResult = idle.control->quit(idleRequest);
    RDP_ASSERT(idleResult.ok());
    RDP_ASSERT(idleResult.idempotent);
    RDP_ASSERT_EQ(idle.transport->count(MoonlightHostOperation::Cancel),
                  static_cast<std::size_t>(0));

    Fixture confirmation;
    confirmation.transport->push(xmlResponse(serverInfoXml(42U)));
    MoonlightQuitRequest confirmationRequest {contextFor(1U), 42U, false};
    const auto confirmationResult = confirmation.control->quit(confirmationRequest);
    RDP_ASSERT_EQ(confirmationResult.code, MoonlightHostControlCode::ConfirmationRequired);
    RDP_ASSERT_EQ(confirmation.transport->count(MoonlightHostOperation::Cancel),
                  static_cast<std::size_t>(0));
}

RDP_TEST_CASE(moonlight_host_control_quit_reuses_authenticated_cancel_verification) {
    Fixture success;
    success.transport->push(xmlResponse(serverInfoXml(42U)));
    success.transport->push(xmlResponse(
        "<root status_code=\"200\"><cancel>1</cancel></root>"));
    success.transport->push(xmlResponse(serverInfoXml(0U)));
    MoonlightQuitRequest request {contextFor(1U), 42U, true};
    const auto result = success.control->quit(request);
    RDP_ASSERT(result.ok());
    RDP_ASSERT_EQ(result.actionTruth, MoonlightHostControlTruth::Confirmed);
    RDP_ASSERT_EQ(result.postconditionTruth, MoonlightHostControlTruth::Confirmed);
    RDP_ASSERT_EQ(success.transport->count(MoonlightHostOperation::Cancel),
                  static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(success.transport->count(MoonlightHostOperation::ServerInfo),
                  static_cast<std::size_t>(2));

    Fixture busy;
    busy.transport->push(xmlResponse(serverInfoXml(42U)));
    busy.transport->push(xmlResponse(
        "<root status_code=\"200\"><cancel>1</cancel></root>"));
    busy.transport->push(xmlResponse(serverInfoXml(42U)));
    const auto busyResult = busy.control->quit(request);
    RDP_ASSERT_EQ(busyResult.code, MoonlightHostControlCode::HostBusy);
}

RDP_TEST_CASE(moonlight_host_control_quit_unknown_is_never_replayed) {
    Fixture fixture;
    fixture.transport->push(xmlResponse(serverInfoXml(42U)));
    fixture.transport->push(transportFailure(MoonlightTransportError::Timeout,
                                             MoonlightTransportSendState::SentResponseUnknown));
    MoonlightQuitRequest request {contextFor(1U), 42U, true};
    const auto result = fixture.control->quit(request);
    RDP_ASSERT_EQ(result.code, MoonlightHostControlCode::OutcomeUnknown);
    RDP_ASSERT_EQ(result.actionTruth, MoonlightHostControlTruth::Unknown);
    RDP_ASSERT_EQ(fixture.transport->count(MoonlightHostOperation::Cancel),
                  static_cast<std::size_t>(1));
}

RDP_TEST_CASE(moonlight_host_control_budget_below_host_minimum_sends_no_packet) {
    const auto start = std::chrono::steady_clock::now();
    auto now = std::make_shared<std::atomic<std::int64_t>>(0);
    Fixture fixture([start, now]() { return start + std::chrono::milliseconds(now->load()); });
    fixture.access->setHandler([now](const auto&, auto, const auto&) {
        now->store(151);
        return MoonlightHostControlAccessCode::Ready;
    });
    auto context = contextFor(1U);
    context.timeout = 200ms;
    const auto result = fixture.control->catalog({context});
    RDP_ASSERT_EQ(result.code, MoonlightHostControlCode::DeadlineExceeded);
    RDP_ASSERT(fixture.transport->captures().empty());
}

RDP_TEST_CASE(moonlight_host_control_exact_cancel_drains_authorization) {
    Fixture fixture;
    auto barrier = std::make_shared<Barrier>();
    fixture.access->setHandler([barrier](const auto&, auto, const auto& probe) {
        barrier->enter();
        barrier->waitReleased();
        return probe() ? MoonlightHostControlAccessCode::Cancelled
                       : MoonlightHostControlAccessCode::Ready;
    });
    MoonlightHostControlResult result;
    std::thread worker([&]() { result = fixture.control->catalog({contextFor(10U)}); });
    RDP_ASSERT(barrier->waitEntered());
    RDP_ASSERT(!fixture.control->cancel({10U, 2U, 1001U}));
    RDP_ASSERT(fixture.control->cancel({10U, 1U, 1001U}));
    barrier->release();
    worker.join();
    RDP_ASSERT_EQ(result.code, MoonlightHostControlCode::Cancelled);
    RDP_ASSERT_EQ(fixture.access->cancelCount(), static_cast<std::size_t>(1));
    RDP_ASSERT(fixture.transport->captures().empty());
}

RDP_TEST_CASE(moonlight_host_control_lane_blocks_mutation_but_other_host_read_can_progress) {
    Fixture fixture;
    auto barrier = std::make_shared<Barrier>();
    std::atomic<unsigned> calls {0U};
    fixture.transport->setHandler([barrier, &calls](const auto& request, auto, const auto&) {
        const unsigned call = calls.fetch_add(1U);
        if (call == 0U) {
            barrier->enter();
            barrier->waitReleased();
        }
        return xmlResponse(catalogXml({{42U, request.serverName()}}));
    });
    MoonlightHostControlResult first;
    std::thread worker([&]() { first = fixture.control->catalog({contextFor(1U)}); });
    RDP_ASSERT(barrier->waitEntered());

    MoonlightQuitRequest blocked {contextFor(2U), 0U, true};
    RDP_ASSERT_EQ(fixture.control->quit(blocked).code, MoonlightHostControlCode::Busy);

    auto otherContext = contextFor(3U, 1U, OWNER_A, "host-b", "SERVER-B");
    const auto other = fixture.control->catalog({otherContext});
    RDP_ASSERT(other.ok());
    barrier->release();
    worker.join();
    RDP_ASSERT(first.ok());
}

RDP_TEST_CASE(moonlight_host_control_allows_only_one_process_wide_mutation) {
    Fixture fixture;
    auto barrier = std::make_shared<Barrier>();
    fixture.access->setHandler([barrier](const auto&, auto, const auto& probe) {
        barrier->enter();
        barrier->waitReleased();
        return probe() ? MoonlightHostControlAccessCode::Cancelled
                       : MoonlightHostControlAccessCode::Ready;
    });
    MoonlightHostControlResult first;
    MoonlightQuitRequest firstRequest {contextFor(10U), 0U, true};
    std::thread worker([&]() { first = fixture.control->quit(firstRequest); });
    RDP_ASSERT(barrier->waitEntered());

    MoonlightQuitRequest secondRequest {
        contextFor(11U, 1U, OWNER_A, "host-b", "SERVER-B"), 0U, true};
    const auto second = fixture.control->quit(secondRequest);
    RDP_ASSERT_EQ(second.code, MoonlightHostControlCode::Busy);
    RDP_ASSERT_EQ(fixture.access->authorizeCount(), static_cast<std::size_t>(1));

    RDP_ASSERT(fixture.control->cancel({10U, 1U, 1001U}));
    barrier->release();
    worker.join();
    RDP_ASSERT_EQ(first.code, MoonlightHostControlCode::Cancelled);
}

RDP_TEST_CASE(moonlight_host_control_new_generation_discards_late_catalog) {
    Fixture fixture;
    auto barrier = std::make_shared<Barrier>();
    std::atomic<unsigned> calls {0U};
    fixture.transport->setHandler([barrier, &calls](const auto&, auto, const auto&) {
        const unsigned call = calls.fetch_add(1U);
        if (call == 0U) {
            barrier->enter();
            barrier->waitReleased();
            return xmlResponse(catalogXml({{7U, "Old"}}));
        }
        return xmlResponse(catalogXml({{42U, "New"}}));
    });
    MoonlightHostControlResult oldResult;
    std::thread oldWorker(
        [&]() { oldResult = fixture.control->catalog({contextFor(1U, 1U)}); });
    RDP_ASSERT(barrier->waitEntered());
    const auto newResult = fixture.control->catalog({contextFor(2U, 2U)});
    RDP_ASSERT(newResult.ok());
    barrier->release();
    oldWorker.join();
    RDP_ASSERT_EQ(oldResult.code, MoonlightHostControlCode::Stale);

    fixture.transport->setHandler({});
    fixture.transport->push(assetResponse("new-cover"));
    MoonlightAssetRequest asset {contextFor(3U, 2U), 42U, 2U};
    RDP_ASSERT(fixture.control->asset(asset).ok());
}

RDP_TEST_CASE(moonlight_host_control_generation_watermark_is_scoped_to_owner_lifecycle) {
    Fixture fixture;
    RDP_ASSERT(fixture.primeCatalog(1U, 9U).ok());

    auto nextOwner = contextFor(2U, 1U);
    nextOwner.key.ownerToken = 2002U;
    fixture.transport->push(xmlResponse(catalogXml({{42U, "New owner"}})));
    const auto refreshed = fixture.control->catalog({nextOwner});
    RDP_ASSERT(refreshed.ok());

    fixture.transport->push(assetResponse("new-owner-cover"));
    MoonlightAssetRequest asset {nextOwner, 42U, 1U};
    asset.context.key.requestId = 3U;
    const auto loaded = fixture.control->asset(asset);
    RDP_ASSERT(loaded.ok());
}

RDP_TEST_CASE(moonlight_host_control_access_outcomes_are_stable_and_packet_free) {
    for (const auto item : {
             std::pair {MoonlightHostControlAccessCode::Unavailable,
                        MoonlightHostControlCode::Unavailable},
             std::pair {MoonlightHostControlAccessCode::Stale, MoonlightHostControlCode::Stale},
             std::pair {MoonlightHostControlAccessCode::DeadlineExceeded,
                        MoonlightHostControlCode::DeadlineExceeded},
         }) {
        Fixture fixture;
        fixture.access->code_.store(item.first);
        const auto result = fixture.control->catalog({contextFor(1U)});
        RDP_ASSERT_EQ(result.code, item.second);
        RDP_ASSERT(fixture.transport->captures().empty());
    }
}

RDP_TEST_CASE(moonlight_host_control_destructor_cancels_and_drains_access_port) {
    Fixture fixture;
    auto barrier = std::make_shared<Barrier>();
    fixture.access->setHandler([barrier](const auto&, auto, const auto& probe) {
        barrier->enter();
        barrier->waitReleased();
        return probe() ? MoonlightHostControlAccessCode::Cancelled
                       : MoonlightHostControlAccessCode::Ready;
    });
    fixture.access->setCancelCallback([barrier]() { barrier->release(); });
    MoonlightHostControlResult result;
    MoonlightHostControl* raw = fixture.control.get();
    std::thread worker([&]() { result = raw->catalog({contextFor(1U)}); });
    RDP_ASSERT(barrier->waitEntered());
    fixture.control.reset();
    worker.join();
    RDP_ASSERT_EQ(result.code, MoonlightHostControlCode::Cancelled);
    RDP_ASSERT_EQ(fixture.access->cancelCount(), static_cast<std::size_t>(1));
}
