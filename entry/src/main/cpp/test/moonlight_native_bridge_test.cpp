#include "moonlight/bridge/MoonlightNativeBridge.h"
#include "test_runner.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <functional>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

using namespace remotedesk::moonlight;
using namespace std::chrono_literals;

const std::string OWNER_A(64U, 'a');
const std::string OWNER_B(64U, 'b');

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

MoonlightBridgeResult successFor(const MoonlightBridgeRequest& request) {
    MoonlightBridgeResult result;
    result.operation = request.operation;
    result.key = request.key;
    result.code = MoonlightBridgeCode::Ok;
    result.terminalStage = MoonlightBridgeTerminalStage::Complete;
    result.preflightTruth = MoonlightBridgeTruth::Confirmed;
    result.actionTruth = request.operation == MoonlightBridgeOperation::Catalog
                             ? MoonlightBridgeTruth::NotAttempted
                             : MoonlightBridgeTruth::Confirmed;
    result.postconditionTruth = result.actionTruth;
    result.observedAtMs = 1780000000000ULL;
    if (request.operation == MoonlightBridgeOperation::DeleteIdentity) {
        result.identityExistingCount = 2U;
        result.identityDeletedCount = 2U;
        result.identityRemainingCount = 0U;
    }
    return result;
}

class FakeRuntime final : public MoonlightNativeRuntimePort {
public:
    using Handler = std::function<MoonlightBridgeResult(
        MoonlightBridgeRequest&, const CancellationProbe&)>;

    MoonlightBridgeCapabilities capabilities() const noexcept override {
        capabilityCount_.fetch_add(1U, std::memory_order_relaxed);
        return capabilities_;
    }

    MoonlightBridgeResult execute(
        MoonlightBridgeRequest request,
        const CancellationProbe& cancellationProbe) override {
        executeCount_.fetch_add(1U, std::memory_order_relaxed);
        Handler handler;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            lastOperation_ = request.operation;
            lastKey_ = request.key;
            sawPin_ = sawPin_ || !request.pin.empty();
            sawRiKey_ = sawRiKey_ || !request.riKey.empty();
            handler = handler_;
        }
        if (handler) {
            return handler(request, cancellationProbe);
        }
        return successFor(request);
    }

    void cancel(const MoonlightBridgeRequestKey& key) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        cancelled_.push_back(key);
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

    std::size_t cancelCount() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return cancelled_.size();
    }

    bool wasCancelled(const MoonlightBridgeRequestKey& key) const {
        std::lock_guard<std::mutex> lock(mutex_);
        return std::find(cancelled_.begin(), cancelled_.end(), key) !=
            cancelled_.end();
    }

    MoonlightBridgeCapabilities capabilities_ {
        true, true, true, true, true, true, true, true, ""
    };
    mutable std::atomic<std::size_t> capabilityCount_ {0U};
    std::atomic<std::size_t> executeCount_ {0U};
    bool sawPin_ = false;
    bool sawRiKey_ = false;

private:
    mutable std::mutex mutex_;
    Handler handler_;
    std::function<void()> cancelCallback_;
    std::vector<MoonlightBridgeRequestKey> cancelled_;
    MoonlightBridgeOperation lastOperation_ = MoonlightBridgeOperation::Catalog;
    MoonlightBridgeRequestKey lastKey_ {};
};

MoonlightBridgeRequest requestFor(
    std::uint64_t requestId = 1U, std::uint64_t generation = 1U,
    std::uint64_t ownerToken = 1001U, std::string owner = OWNER_A,
    std::string hostId = "host-a", std::string serverUuid = "SERVER-A") {
    MoonlightBridgeRequest request;
    request.operation = MoonlightBridgeOperation::Catalog;
    request.key = {requestId, generation, ownerToken};
    request.ownerScopeFingerprint = std::move(owner);
    request.hostId = std::move(hostId);
    request.serverUuid = std::move(serverUuid);
    request.endpoint.serverName = "sunshine.local";
    request.endpoint.addresses = {{"192.0.2.10", MoonlightHostAddressFamily::Ipv4}};
    request.endpoint.pinnedTrustAvailable = true;
    request.timeout = 7s;
    return request;
}

MoonlightBridgeRequest pairRequest() {
    auto request = requestFor();
    request.operation = MoonlightBridgeOperation::Pair;
    request.installationId = "install-a";
    request.endpoint.pinnedTrustAvailable = false;
    request.endpoint.allowHttpPairingCandidate = true;
    request.timeout = 120s;
    request.pin = {'1', '2', '3', '4'};
    return request;
}

MoonlightBridgeRequest launchRequest(std::uint64_t requestId = 1U,
                                     std::uint64_t generation = 1U) {
    auto request = requestFor(requestId, generation);
    request.operation = MoonlightBridgeOperation::Launch;
    request.appId = 42U;
    request.catalogGeneration = generation;
    return request;
}

MoonlightBridgeRequest unpairRequest(std::uint64_t requestId = 1U,
                                     std::uint64_t generation = 1U) {
    auto request = requestFor(requestId, generation);
    request.operation = MoonlightBridgeOperation::Unpair;
    request.installationId = "install-a";
    request.pinnedCertificateSha256 = std::string(64U, 'c');
    return request;
}

MoonlightBridgeRequest identityDeleteRequest(
    std::uint64_t requestId = 1U, std::uint64_t generation = 1U,
    std::uint64_t ownerToken = 1001U, std::string owner = OWNER_A) {
    MoonlightBridgeRequest request;
    request.operation = MoonlightBridgeOperation::DeleteIdentity;
    request.key = {requestId, generation, ownerToken};
    request.ownerScopeFingerprint = std::move(owner);
    request.timeout = 30s;
    return request;
}

} // namespace

RDP_TEST_CASE(moonlight_native_bridge_construction_does_not_initialize_runtime) {
    auto runtime = std::make_shared<FakeRuntime>();
    {
        MoonlightNativeBridge bridge(runtime);
        RDP_ASSERT_EQ(runtime->capabilityCount_.load(),
                      static_cast<std::size_t>(0));
    }
    RDP_ASSERT_EQ(runtime->capabilityCount_.load(),
                  static_cast<std::size_t>(0));
}

RDP_TEST_CASE(moonlight_native_bridge_product_runtime_is_packet_free_unavailable) {
    auto runtime = std::make_shared<MoonlightUnavailableRuntimePort>();
    MoonlightNativeBridge bridge(runtime);
    const auto capabilities = bridge.capabilities();
    RDP_ASSERT(capabilities.bridgeCompiled);
    RDP_ASSERT(!capabilities.identityReady);
    RDP_ASSERT(!capabilities.identityDeletionReady);
    RDP_ASSERT(!capabilities.transportReady);
    RDP_ASSERT(!capabilities.pairingReady);
    RDP_ASSERT(!capabilities.hostControlReady);
    RDP_ASSERT(capabilities.blocker == "runtime_proof_required");
    const auto result = bridge.execute(requestFor());
    RDP_ASSERT_EQ(result.code, MoonlightBridgeCode::RuntimeProofRequired);
    RDP_ASSERT_EQ(result.preflightTruth, MoonlightBridgeTruth::Failed);
}

RDP_TEST_CASE(moonlight_native_bridge_identity_delete_is_owner_only_and_count_only) {
    auto runtime = std::make_shared<FakeRuntime>();
    MoonlightNativeBridge bridge(runtime);
    const auto result = bridge.execute(identityDeleteRequest());
    RDP_ASSERT(result.ok());
    RDP_ASSERT_EQ(result.identityExistingCount, static_cast<std::size_t>(2));
    RDP_ASSERT_EQ(result.identityDeletedCount, static_cast<std::size_t>(2));
    RDP_ASSERT_EQ(result.identityRemainingCount, static_cast<std::size_t>(0));
    RDP_ASSERT(result.apps.empty());
    RDP_ASSERT(result.asset.empty());
    RDP_ASSERT(result.certificateSha256.empty());
    RDP_ASSERT(!result.rtspSessionUrl.has_value());

    auto injectedHost = identityDeleteRequest(2U);
    injectedHost.hostId = "must-not-be-accepted";
    RDP_ASSERT_EQ(bridge.execute(std::move(injectedHost)).code,
                  MoonlightBridgeCode::InvalidArgument);
    RDP_ASSERT_EQ(runtime->executeCount_.load(), static_cast<std::size_t>(1));
}

RDP_TEST_CASE(moonlight_native_bridge_identity_delete_has_distinct_capability) {
    auto runtime = std::make_shared<FakeRuntime>();
    runtime->capabilities_.identityReady = true;
    runtime->capabilities_.identityDeletionReady = false;
    MoonlightNativeBridge bridge(runtime);
    const auto result = bridge.execute(identityDeleteRequest());
    RDP_ASSERT_EQ(result.code, MoonlightBridgeCode::RuntimeProofRequired);
    RDP_ASSERT_EQ(runtime->executeCount_.load(), static_cast<std::size_t>(0));
}

RDP_TEST_CASE(moonlight_native_bridge_rejects_identity_count_leakage) {
    auto runtime = std::make_shared<FakeRuntime>();
    runtime->setHandler([](MoonlightBridgeRequest& request, const auto&) {
        auto result = successFor(request);
        result.identityExistingCount = 1U;
        return result;
    });
    MoonlightNativeBridge bridge(runtime);
    RDP_ASSERT_EQ(bridge.execute(requestFor()).code,
                  MoonlightBridgeCode::ProtocolFailure);
}

RDP_TEST_CASE(moonlight_native_bridge_rejects_invalid_exact_dto_before_runtime) {
    auto runtime = std::make_shared<FakeRuntime>();
    MoonlightNativeBridge bridge(runtime);
    auto invalidOwner = requestFor();
    invalidOwner.ownerScopeFingerprint = "owner-a";
    RDP_ASSERT_EQ(bridge.execute(std::move(invalidOwner)).code,
                  MoonlightBridgeCode::InvalidArgument);
    auto invalidAsset = requestFor(2U);
    invalidAsset.operation = MoonlightBridgeOperation::Asset;
    invalidAsset.appId = 42U;
    invalidAsset.catalogGeneration = 2U;
    RDP_ASSERT_EQ(bridge.execute(std::move(invalidAsset)).code,
                  MoonlightBridgeCode::InvalidArgument);
    auto invalidPin = pairRequest();
    invalidPin.pin = {'1', '2', 'x', '4'};
    RDP_ASSERT_EQ(bridge.execute(std::move(invalidPin)).code,
                  MoonlightBridgeCode::InvalidArgument);
    auto unpairWithoutTrust = unpairRequest(3U);
    unpairWithoutTrust.pinnedCertificateSha256.clear();
    RDP_ASSERT_EQ(bridge.execute(std::move(unpairWithoutTrust)).code,
                  MoonlightBridgeCode::InvalidArgument);
    RDP_ASSERT_EQ(runtime->executeCount_.load(), static_cast<std::size_t>(0));
}

RDP_TEST_CASE(moonlight_native_bridge_unpair_needs_transport_not_host_control) {
    auto runtime = std::make_shared<FakeRuntime>();
    runtime->capabilities_.identityReady = false;
    runtime->capabilities_.pairingReady = false;
    runtime->capabilities_.hostControlReady = false;
    runtime->capabilities_.transportReady = true;
    MoonlightNativeBridge bridge(runtime);
    const auto result = bridge.execute(unpairRequest());
    RDP_ASSERT(result.ok());
    RDP_ASSERT_EQ(runtime->executeCount_.load(), static_cast<std::size_t>(1));
}

RDP_TEST_CASE(moonlight_native_bridge_cancelled_unpair_still_reaches_local_revoke_lane) {
    auto runtime = std::make_shared<FakeRuntime>();
    MoonlightNativeBridge bridge(runtime);
    const auto result = bridge.execute(unpairRequest(), []() { return true; });
    RDP_ASSERT_EQ(result.code, MoonlightBridgeCode::Cancelled);
    RDP_ASSERT_EQ(runtime->executeCount_.load(), static_cast<std::size_t>(1));
}

RDP_TEST_CASE(moonlight_native_bridge_returns_typed_result_and_owner_event) {
    auto runtime = std::make_shared<FakeRuntime>();
    runtime->setHandler([](MoonlightBridgeRequest& request, const auto&) {
        auto result = successFor(request);
        result.apps.push_back({42U, "Desktop", true});
        result.apps.push_back({77U, "Steam", std::nullopt});
        return result;
    });
    auto tick = std::make_shared<std::atomic<std::int64_t>>(1000);
    MoonlightNativeBridge bridge(runtime, [tick]() {
        return std::chrono::steady_clock::time_point(
            std::chrono::milliseconds(tick->fetch_add(1)));
    });
    const auto result = bridge.execute(requestFor());
    RDP_ASSERT(result.ok());
    RDP_ASSERT_EQ(result.apps.size(), static_cast<std::size_t>(2));
    const auto events = bridge.pollEvents(1001U, 0U);
    RDP_ASSERT_EQ(events.size(), static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(events[0].operation, MoonlightBridgeOperation::Catalog);
    RDP_ASSERT_EQ(events[0].code, MoonlightBridgeCode::Ok);
    RDP_ASSERT_EQ(events[0].monotonicTimestampMs, static_cast<std::uint64_t>(1000U));
    RDP_ASSERT(bridge.pollEvents(2002U, 0U).empty());
    RDP_ASSERT(bridge.pollEvents(1001U, events[0].sequence).empty());
}

RDP_TEST_CASE(moonlight_native_bridge_rejects_runtime_identity_mismatch) {
    auto runtime = std::make_shared<FakeRuntime>();
    runtime->setHandler([](MoonlightBridgeRequest& request, const auto&) {
        auto result = successFor(request);
        result.key.generation++;
        return result;
    });
    MoonlightNativeBridge bridge(runtime);
    const auto result = bridge.execute(requestFor());
    RDP_ASSERT_EQ(result.code, MoonlightBridgeCode::ProtocolFailure);
    RDP_ASSERT_EQ(result.key.generation, static_cast<std::uint64_t>(1U));
}

RDP_TEST_CASE(moonlight_native_bridge_duplicate_exact_key_is_busy) {
    auto runtime = std::make_shared<FakeRuntime>();
    auto barrier = std::make_shared<Barrier>();
    runtime->setHandler([barrier](MoonlightBridgeRequest& request, const auto& probe) {
        barrier->enter();
        barrier->waitReleased();
        return probe() ? MoonlightBridgeResult {} : successFor(request);
    });
    MoonlightNativeBridge bridge(runtime);
    MoonlightBridgeResult first;
    std::thread worker([&]() { first = bridge.execute(requestFor()); });
    RDP_ASSERT(barrier->waitEntered());
    const auto duplicate = bridge.execute(requestFor());
    RDP_ASSERT_EQ(duplicate.code, MoonlightBridgeCode::Busy);
    barrier->release();
    worker.join();
    RDP_ASSERT(first.ok());
    const auto retiredDuplicate = bridge.execute(requestFor());
    RDP_ASSERT_EQ(retiredDuplicate.code, MoonlightBridgeCode::Busy);
}

RDP_TEST_CASE(moonlight_native_bridge_external_cancel_before_runtime_is_packet_free) {
    auto runtime = std::make_shared<FakeRuntime>();
    MoonlightNativeBridge bridge(runtime);
    const auto result = bridge.execute(requestFor(), []() { return true; });
    RDP_ASSERT_EQ(result.code, MoonlightBridgeCode::Cancelled);
    RDP_ASSERT_EQ(runtime->executeCount_.load(), static_cast<std::size_t>(0));
}

RDP_TEST_CASE(moonlight_native_bridge_rejects_unbounded_runtime_result) {
    auto runtime = std::make_shared<FakeRuntime>();
    runtime->setHandler([](MoonlightBridgeRequest& request, const auto&) {
        auto result = successFor(request);
        result.asset.resize(MoonlightHostLimits::kMaxBodyBytes + 1U);
        return result;
    });
    MoonlightNativeBridge bridge(runtime);
    const auto result = bridge.execute(requestFor());
    RDP_ASSERT_EQ(result.code, MoonlightBridgeCode::ProtocolFailure);
    RDP_ASSERT(result.asset.empty());
}

RDP_TEST_CASE(moonlight_native_bridge_rejects_malformed_local_certificate_pin) {
    auto runtime = std::make_shared<FakeRuntime>();
    MoonlightNativeBridge bridge(runtime);
    auto request = requestFor();
    request.installationId = "install-a";
    request.pinnedCertificateSha256 = std::string(64U, 'A');
    const auto result = bridge.execute(std::move(request));
    RDP_ASSERT_EQ(result.code, MoonlightBridgeCode::InvalidArgument);
    RDP_ASSERT_EQ(runtime->executeCount_.load(), static_cast<std::size_t>(0));
}

RDP_TEST_CASE(moonlight_native_bridge_accepts_bounded_local_certificate_pin) {
    auto runtime = std::make_shared<FakeRuntime>();
    MoonlightNativeBridge bridge(runtime);
    auto request = requestFor();
    request.installationId = "install-a";
    request.pinnedCertificateSha256 = std::string(64U, 'a');
    const auto result = bridge.execute(std::move(request));
    RDP_ASSERT(result.ok());
    RDP_ASSERT_EQ(runtime->executeCount_.load(), static_cast<std::size_t>(1));
}

RDP_TEST_CASE(moonlight_native_bridge_rejects_malformed_pair_fingerprint_result) {
    auto runtime = std::make_shared<FakeRuntime>();
    runtime->setHandler([](MoonlightBridgeRequest& request, const auto&) {
        auto result = successFor(request);
        result.certificateSha256 = std::string(64U, 'G');
        return result;
    });
    MoonlightNativeBridge bridge(runtime);
    const auto result = bridge.execute(pairRequest());
    RDP_ASSERT_EQ(result.code, MoonlightBridgeCode::ProtocolFailure);
    RDP_ASSERT(result.certificateSha256.empty());
}

RDP_TEST_CASE(moonlight_native_bridge_new_generation_discards_late_result) {
    auto runtime = std::make_shared<FakeRuntime>();
    auto barrier = std::make_shared<Barrier>();
    std::atomic<unsigned> calls {0U};
    runtime->setHandler([barrier, &calls](MoonlightBridgeRequest& request, const auto&) {
        if (calls.fetch_add(1U) == 0U) {
            barrier->enter();
            barrier->waitReleased();
        }
        return successFor(request);
    });
    runtime->setCancelCallback([barrier]() { barrier->release(); });
    MoonlightNativeBridge bridge(runtime);
    MoonlightBridgeResult oldResult;
    std::thread worker([&]() { oldResult = bridge.execute(requestFor(1U, 1U)); });
    RDP_ASSERT(barrier->waitEntered());
    const auto newResult = bridge.execute(requestFor(2U, 2U));
    RDP_ASSERT(newResult.ok());
    worker.join();
    RDP_ASSERT_EQ(oldResult.code, MoonlightBridgeCode::Cancelled);
    RDP_ASSERT_EQ(runtime->cancelCount(), static_cast<std::size_t>(1));
    RDP_ASSERT(runtime->wasCancelled({1U, 1U, 1001U}));
    RDP_ASSERT_EQ(bridge.execute(requestFor(3U, 1U)).code,
                  MoonlightBridgeCode::Stale);
}

RDP_TEST_CASE(moonlight_native_bridge_generation_cancel_is_lane_isolated) {
    auto runtime = std::make_shared<FakeRuntime>();
    auto barrier = std::make_shared<Barrier>();
    std::atomic<unsigned> calls {0U};
    runtime->setHandler([barrier, &calls](MoonlightBridgeRequest& request,
                                          const auto&) {
        if (calls.fetch_add(1U) == 0U) {
            barrier->enter();
            barrier->waitReleased();
        }
        return successFor(request);
    });
    MoonlightNativeBridge bridge(runtime);
    MoonlightBridgeResult first;
    std::thread worker([&]() { first = bridge.execute(requestFor()); });
    RDP_ASSERT(barrier->waitEntered());
    const auto otherLane = bridge.execute(
        requestFor(2U, 2U, 1001U, OWNER_A, "host-b", "SERVER-B"));
    RDP_ASSERT(otherLane.ok());
    RDP_ASSERT_EQ(runtime->cancelCount(), static_cast<std::size_t>(0));
    barrier->release();
    worker.join();
    RDP_ASSERT(first.ok());
}

RDP_TEST_CASE(moonlight_native_bridge_generation_is_owner_scoped_on_same_host) {
    auto runtime = std::make_shared<FakeRuntime>();
    MoonlightNativeBridge bridge(runtime);

    const auto catalogOwner = bridge.execute(
        requestFor(1U, 2U, 1001U, OWNER_A, "host-a", "SERVER-A"));
    const auto launchOwner = bridge.execute(
        requestFor(2U, 1U, 2002U, OWNER_A, "host-a", "SERVER-A"));

    RDP_ASSERT(catalogOwner.ok());
    RDP_ASSERT(launchOwner.ok());
    RDP_ASSERT_EQ(runtime->cancelCount(), static_cast<std::size_t>(0));
}

RDP_TEST_CASE(moonlight_native_bridge_owner_cancel_releases_generation_lane) {
    auto runtime = std::make_shared<FakeRuntime>();
    MoonlightNativeBridge bridge(runtime);

    RDP_ASSERT(bridge.execute(
        requestFor(1U, 2U, 1001U, OWNER_A, "host-a", "SERVER-A")).ok());
    RDP_ASSERT_EQ(bridge.cancelOwner(1001U), static_cast<std::size_t>(0));
    RDP_ASSERT(bridge.execute(
        requestFor(2U, 1U, 1001U, OWNER_A, "host-a", "SERVER-A")).ok());
}

RDP_TEST_CASE(moonlight_native_bridge_exact_cancel_is_idempotent_and_drains) {
    auto runtime = std::make_shared<FakeRuntime>();
    auto barrier = std::make_shared<Barrier>();
    runtime->setHandler([barrier](MoonlightBridgeRequest& request, const auto& probe) {
        barrier->enter();
        barrier->waitReleased();
        return probe()
                   ? MoonlightBridgeResult {}
                   : successFor(request);
    });
    runtime->setCancelCallback([barrier]() { barrier->release(); });
    MoonlightNativeBridge bridge(runtime);
    MoonlightBridgeResult result;
    std::thread worker([&]() { result = bridge.execute(requestFor()); });
    RDP_ASSERT(barrier->waitEntered());
    RDP_ASSERT(!bridge.cancel({1U, 2U, 1001U}));
    RDP_ASSERT(bridge.cancel({1U, 1U, 1001U}));
    RDP_ASSERT(!bridge.cancel({1U, 1U, 1001U}));
    worker.join();
    RDP_ASSERT_EQ(result.code, MoonlightBridgeCode::Cancelled);
    RDP_ASSERT_EQ(runtime->cancelCount(), static_cast<std::size_t>(1));
}

RDP_TEST_CASE(moonlight_native_bridge_cancel_owner_does_not_cross_owner) {
    auto runtime = std::make_shared<FakeRuntime>();
    auto barrier = std::make_shared<Barrier>();
    std::atomic<unsigned> entered {0U};
    runtime->setHandler([barrier, &entered](MoonlightBridgeRequest& request, const auto& probe) {
        if (entered.fetch_add(1U) == 0U) {
            barrier->enter();
        }
        barrier->waitReleased();
        return probe() ? MoonlightBridgeResult {} : successFor(request);
    });
    MoonlightNativeBridge bridge(runtime);
    MoonlightBridgeResult first;
    MoonlightBridgeResult second;
    std::thread firstWorker([&]() { first = bridge.execute(requestFor()); });
    RDP_ASSERT(barrier->waitEntered());
    std::thread secondWorker([&]() {
        second = bridge.execute(requestFor(2U, 1U, 2002U, OWNER_B, "host-b", "SERVER-B"));
    });
    while (entered.load(std::memory_order_acquire) < 2U) {
        std::this_thread::yield();
    }
    RDP_ASSERT_EQ(bridge.cancelOwner(1001U), static_cast<std::size_t>(1));
    RDP_ASSERT_EQ(bridge.cancelOwner(1001U), static_cast<std::size_t>(0));
    barrier->release();
    firstWorker.join();
    secondWorker.join();
    RDP_ASSERT_EQ(first.code, MoonlightBridgeCode::Cancelled);
    RDP_ASSERT(second.ok());
}

RDP_TEST_CASE(moonlight_native_bridge_pair_is_ephemeral_and_launch_has_no_ri_key) {
    MoonlightNativeBridge::resetSecureCleanseCountForTesting();
    auto runtime = std::make_shared<FakeRuntime>();
    MoonlightNativeBridge bridge(runtime);
    RDP_ASSERT(bridge.execute(pairRequest()).ok());
    auto launch = launchRequest(2U, 2U);
    RDP_ASSERT(bridge.execute(std::move(launch)).ok());
    RDP_ASSERT(runtime->sawPin_);
    RDP_ASSERT(!runtime->sawRiKey_);
    RDP_ASSERT(MoonlightNativeBridge::secureCleanseCountForTesting() >= 1U);
    RDP_ASSERT(std::string(moonlightBridgeOperationName(
                   MoonlightBridgeOperation::Resume)) == "resume");
    RDP_ASSERT(std::string(moonlightBridgeOperationName(
                   MoonlightBridgeOperation::Unpair)) == "unpair");
    RDP_ASSERT(std::string(moonlightBridgeOperationName(
                   MoonlightBridgeOperation::DeleteIdentity)) ==
               "delete_identity");
    RDP_ASSERT(std::string(moonlightBridgeCodeName(
                   MoonlightBridgeCode::OutcomeUnknown)) == "outcome_unknown");
}

RDP_TEST_CASE(moonlight_native_bridge_runtime_exception_is_stable_failure) {
    auto runtime = std::make_shared<FakeRuntime>();
    runtime->setHandler([](MoonlightBridgeRequest&, const auto&) -> MoonlightBridgeResult {
        throw std::runtime_error("secret-canary-must-not-escape");
    });
    MoonlightNativeBridge bridge(runtime);
    const auto result = bridge.execute(requestFor());
    RDP_ASSERT_EQ(result.code, MoonlightBridgeCode::ProtocolFailure);
    RDP_ASSERT_EQ(result.diagnostics.size(), static_cast<std::size_t>(0));
}

RDP_TEST_CASE(moonlight_native_bridge_event_queue_is_bounded_and_ordered) {
    auto runtime = std::make_shared<FakeRuntime>();
    MoonlightNativeBridge bridge(runtime);
    for (std::uint64_t index = 1U; index <= 300U; ++index) {
        RDP_ASSERT(bridge.execute(requestFor(index, index)).ok());
    }
    const auto first = bridge.pollEvents(1001U, 0U, 128U);
    RDP_ASSERT_EQ(first.size(), static_cast<std::size_t>(128));
    RDP_ASSERT(first.front().sequence > 1U);
    for (std::size_t index = 1U; index < first.size(); ++index) {
        RDP_ASSERT(first[index].sequence > first[index - 1U].sequence);
    }
}

RDP_TEST_CASE(moonlight_native_bridge_destructor_cancels_and_drains_runtime) {
    auto runtime = std::make_shared<FakeRuntime>();
    auto barrier = std::make_shared<Barrier>();
    runtime->setHandler([barrier](MoonlightBridgeRequest& request, const auto& probe) {
        barrier->enter();
        barrier->waitReleased();
        return probe() ? MoonlightBridgeResult {} : successFor(request);
    });
    runtime->setCancelCallback([barrier]() { barrier->release(); });
    auto bridge = std::make_unique<MoonlightNativeBridge>(runtime);
    MoonlightNativeBridge* raw = bridge.get();
    MoonlightBridgeResult result;
    std::thread worker([&]() { result = raw->execute(requestFor()); });
    RDP_ASSERT(barrier->waitEntered());
    bridge.reset();
    worker.join();
    RDP_ASSERT_EQ(result.code, MoonlightBridgeCode::Cancelled);
    RDP_ASSERT_EQ(runtime->cancelCount(), static_cast<std::size_t>(1));
}
