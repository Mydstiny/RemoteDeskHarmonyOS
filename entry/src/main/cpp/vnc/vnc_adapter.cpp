/**
 * vnc_adapter.cpp - VNC protocol adapter
 *
 * VNC 协议：默认端口 5900+N (display N)，支持 bounded ZRLE、Raw、
 * CopyRect、Cursor 和 DesktopSize；Tight/ContinuousUpdates 未启用。
 */

#include "vnc_adapter.h"
#include "common/network_generation_fence.h"
#include "common/safe_log.h"
#include "extensions/extension_registry.h"
#include "extensions/session_teardown_executor.h"
#if defined(RDP_TESTS_ONLY)
#define LOG_APP 0
#define OH_LOG_ERROR(...) ((void)0)
#define OH_LOG_INFO(...) ((void)0)
#else
#include <hilog/log.h>
#endif
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <future>
#include <optional>
#include <thread>
#include <utility>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0008
#define LOG_TAG "VNC_ADAPTER"

namespace {

std::atomic<uint64_t> g_nextVncCursorGeneration {1};

constexpr std::chrono::milliseconds kVncExactRetirementBudget {2000};

void secureClearString(std::string& value) {
    if (!value.empty()) {
        volatile char* data = value.data();
        for (size_t index = 0; index < value.size(); ++index) {
            data[index] = '\0';
        }
    }
    value.clear();
}

void clearVncReconnectConfig(ConnectionConfig& config) {
    secureClearString(config.password);
    secureClearString(config.privateKeyPem);
    secureClearString(config.privateKeyPassphrase);
    config = ConnectionConfig {};
}

class VncReconnectConfigVault final {
public:
    ~VncReconnectConfigVault() {
        clear();
    }

    void replace(uint64_t token, const ConnectionConfig& config) {
        std::lock_guard<std::mutex> lock(mutex_);
        clearLocked();
        config_ = config;
        token_ = token;
    }

    bool rebind(uint64_t token) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (token == 0 || token_ == 0) {
            return false;
        }
        token_ = token;
        return true;
    }

    bool snapshot(uint64_t token, ConnectionConfig& config) const {
        std::lock_guard<std::mutex> lock(mutex_);
        if (token == 0 || token != token_) {
            return false;
        }
        config = config_;
        return true;
    }

    void clearIfOwnedBy(uint64_t token) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (token != 0 && token == token_) {
            clearLocked();
        }
    }

    void clear() {
        std::lock_guard<std::mutex> lock(mutex_);
        clearLocked();
    }

    bool viewOnly() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return token_ != 0 && config_.vncViewOnly;
    }

#ifdef RDP_NATIVE_CALLBACK_TESTING
    bool retainsCredentialMaterial() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return !config_.password.empty() || !config_.privateKeyPem.empty() ||
            !config_.privateKeyPassphrase.empty();
    }
#endif

private:
    void clearLocked() {
        clearVncReconnectConfig(config_);
        token_ = 0;
    }

    mutable std::mutex mutex_;
    ConnectionConfig config_;
    uint64_t token_ = 0;
};

} // namespace

// The RFB engine may outlive VncAdapter after a bounded stop transfers it to
// the deferred owner. Engine callbacks therefore retain only this state
// object, never the adapter/Impl address.
struct VncCallbackState {
    std::atomic<bool> active {true};
    std::atomic<uint64_t> serial {0};
    mutable std::mutex mutex;
    VideoFrameCallback videoCallback;
    AudioDataCallback audioCallback;
    ConnectionStateCallback stateCallback;
    ConnectionState state = ConnectionState::DISCONNECTED;
    std::weak_ptr<VncRfbEngine> activeEngine;
    Render::DecoderSessionIdentity owner;
    RemoteCursorStore cursorStore;
    size_t callbackInFlight = 0;
    std::condition_variable callbackCv;

    void invalidate() {
        active.store(false, std::memory_order_release);
        serial.fetch_add(1, std::memory_order_acq_rel);
        std::lock_guard<std::mutex> lock(mutex);
        activeEngine.reset();
        videoCallback = nullptr;
        audioCallback = nullptr;
        stateCallback = nullptr;
    }

    bool beginCallback(uint64_t expectedSerial,
                       const std::shared_ptr<VncRfbEngine>& expectedEngine) {
        std::lock_guard<std::mutex> lock(mutex);
        if (!active.load(std::memory_order_relaxed) ||
            (expectedSerial != 0 &&
             serial.load(std::memory_order_relaxed) != expectedSerial)) {
            return false;
        }
        const auto activeEngineValue = activeEngine.lock();
        if (expectedEngine && (!activeEngineValue || activeEngineValue != expectedEngine)) {
            return false;
        }
        ++callbackInFlight;
        return true;
    }

    void endCallback() {
        std::lock_guard<std::mutex> lock(mutex);
        if (callbackInFlight > 0) {
            --callbackInFlight;
        }
        if (callbackInFlight == 0) {
            callbackCv.notify_all();
        }
    }

    bool dispatchState(uint64_t expectedSerial, ConnectionState nextState,
                       const std::string& message) {
        if (!beginCallback(expectedSerial, nullptr)) {
            return false;
        }
        ConnectionStateCallback callback;
        {
            std::lock_guard<std::mutex> lock(mutex);
            state = nextState;
            callback = stateCallback;
        }
        if (callback) {
            try {
                callback(nextState, message);
            } catch (...) {
                OH_LOG_ERROR(LOG_APP, "[VNC] carried state callback threw");
            }
        }
        endCallback();
        return static_cast<bool>(callback);
    }

    bool dispatchVideo(const VideoFrame& frame,
                       const Render::DecoderSessionIdentity& capturedOwner,
                       uint64_t expectedSerial = 0,
                       const std::shared_ptr<VncRfbEngine>& expectedEngine = nullptr) {
        if (!active.load(std::memory_order_acquire)) return false;
        // Acquire the shared owner lease before taking the callback snapshot.
        // S1->S2 activation therefore cannot complete between validation and
        // the actual external sink call.
        auto ownerLease = Render::SharedSessionSinkOwnerLease().acquire(capturedOwner);
        if (!ownerLease) return false;
        if (!beginCallback(expectedSerial, expectedEngine)) {
            return false;
        }
        VideoFrameCallback callback;
        {
            std::lock_guard<std::mutex> lock(mutex);
            callback = videoCallback;
        }
        if (callback) callback(frame);
        endCallback();
        return static_cast<bool>(callback);
    }

    void applyProtocolCursor(
        uint64_t generation, const VncCursorProtocol::DecodedCursor& cursor) {
        if (!cursor.visible) {
            cursorStore.setVisibleIfGeneration(generation, false);
            return;
        }
        if (cursorStore.setShapeIfGeneration(
                generation, cursor.shapeId, cursor.width, cursor.height,
                cursor.hotX, cursor.hotY, cursor.rgba)) {
            cursorStore.setVisibleIfGeneration(generation, true);
        }
    }

    void updatePredictedCursorPosition(uint64_t generation, int x, int y) {
        // Local input predicts position only. Protocol visibility is
        // authoritative: a hidden Cursor update must remain hidden until the
        // server sends a new visible shape.
        cursorStore.setPositionIfGeneration(generation, x, y);
    }
};

class VncStateCallbackCarrier final
    : public std::enable_shared_from_this<VncStateCallbackCarrier> {
public:
    explicit VncStateCallbackCarrier(
        std::shared_ptr<VncCallbackState> callbackState)
        : callbackState_(std::move(callbackState)) {}

    bool enqueue(
        const std::shared_ptr<std::recursive_mutex>& operationMutex,
        uint64_t serial, ConnectionState state,
        const std::string& message) {
        if (!operationMutex) {
            return false;
        }
        try {
            std::lock_guard<std::mutex> lock(mutex_);
            pending_ = Notification {
                operationMutex, serial, state, message};
            maxPending_ = std::max(maxPending_, static_cast<size_t>(1));
            if (draining_) {
                return true;
            }
            draining_ = true;
            const auto self = shared_from_this();
            if (executor_.enqueue([self]() { self->drain(); }) == 0) {
                draining_ = false;
                pending_.reset();
                cv_.notify_all();
                return false;
            }
            return true;
        } catch (...) {
            std::lock_guard<std::mutex> lock(mutex_);
            draining_ = false;
            pending_.reset();
            cv_.notify_all();
            return false;
        }
    }

#ifdef RDP_NATIVE_CALLBACK_TESTING
    size_t pendingCount() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return pending_.has_value() ? 1U : 0U;
    }

    size_t maxPendingCount() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return maxPending_;
    }

    void setBeforeOperationLockHook(std::function<void()> hook) {
        std::lock_guard<std::mutex> lock(mutex_);
        beforeOperationLockHook_ = std::move(hook);
    }

    bool waitForIdle(std::chrono::milliseconds timeout) {
        std::unique_lock<std::mutex> lock(mutex_);
        return cv_.wait_for(lock, timeout, [this]() {
            return !draining_ && !pending_.has_value();
        });
    }
#endif

private:
    struct Notification final {
        std::shared_ptr<std::recursive_mutex> operationMutex;
        uint64_t serial = 0;
        ConnectionState state = ConnectionState::DISCONNECTED;
        std::string message;
    };

    void drain() {
        for (;;) {
            std::optional<Notification> notification;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                if (!pending_.has_value()) {
                    draining_ = false;
                    cv_.notify_all();
                    return;
                }
                notification.emplace(std::move(*pending_));
                pending_.reset();
            }
#ifdef RDP_NATIVE_CALLBACK_TESTING
            std::function<void()> beforeOperationLockHook;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                beforeOperationLockHook = beforeOperationLockHook_;
            }
            if (beforeOperationLockHook) {
                beforeOperationLockHook();
            }
#endif
            // Final serial validation and external delivery share the same
            // lane as explicit connect/disconnect and engine state callbacks.
            // A carried S1 notification therefore either finishes before an
            // S2 action begins or observes S2's newer serial and is dropped.
            const auto operationMutex = notification->operationMutex;
            std::lock_guard<std::recursive_mutex> operationLock(
                *operationMutex);
            callbackState_->dispatchState(
                notification->serial, notification->state,
                notification->message);
        }
    }

    std::shared_ptr<VncCallbackState> callbackState_;
    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::optional<Notification> pending_;
    bool draining_ = false;
    size_t maxPending_ = 0;
#ifdef RDP_NATIVE_CALLBACK_TESTING
    std::function<void()> beforeOperationLockHook_;
#endif
    SessionTeardown::Executor executor_;
};

struct VncAdapter::NetworkRecoveryJob {
    VncNetworkRecoveryAction action;
    std::shared_ptr<VncRfbEngine> retiringEngine;
    std::shared_ptr<VncRfbEngine> retiringStartingEngine;
    bool performRecovery = true;
};

struct VncAdapter::Impl {
    ConnectionState state = ConnectionState::DISCONNECTED;
    VideoFrameCallback videoCallback;
    AudioDataCallback audioCallback;
    ConnectionStateCallback stateCallback;
    std::shared_ptr<VncRfbEngine> engine;
    std::shared_ptr<StartingSlot> startingSlot;
#ifdef RDP_NATIVE_CALLBACK_TESTING
    std::function<int(VncRfbEngine&)> engineStartHook;
    std::function<void()> beforeNetworkRetirementWaitHook;
    std::function<void()> afterNetworkDetachHook;
#endif
    std::mutex mutex;
    uint64_t sessionId = 0;
    uint64_t cursorGeneration = 0;
    Render::DecoderSessionIdentity owner;
    RemoteCursorStore cursorStore;
    std::shared_ptr<VncCallbackState> callbackState =
        std::make_shared<VncCallbackState>();
    std::shared_ptr<VncStateCallbackCarrier> stateCallbackCarrier =
        std::make_shared<VncStateCallbackCarrier>(callbackState);
    std::shared_ptr<VncNetworkRecoveryPolicy> networkRecovery =
        std::make_shared<VncNetworkRecoveryPolicy>();
    std::shared_ptr<VncReconnectConfigVault> reconnectConfig =
        std::make_shared<VncReconnectConfigVault>();
    std::shared_ptr<std::recursive_mutex> operationMutex =
        std::make_shared<std::recursive_mutex>();
    std::mutex recoveryMutex;
    std::condition_variable recoveryCv;
    std::optional<NetworkRecoveryJob> pendingRecoveryJob;
    bool recoveryRetirementActive = false;
    bool retirementFenceBroken = false;
    size_t maxPendingRecoveryJobs = 0;
    bool recoveryWorkerStopping = false;
    bool recoveryWorkerReady = false;
    std::thread recoveryWorker;
};

struct VncAdapter::StartingSlot {
    enum class State : uint8_t {
        StartingNotWritable,
        ActiveWritable,
    };

    uint64_t serial = 0;
    std::shared_ptr<VncRfbEngine> engine;
    std::shared_ptr<VncCallbackState> callbackState;
    std::atomic<bool> cancelled {false};
    // `cancelled` also gates frame/state delivery after a sink-owner loss.
    // Lifecycle cleanup needs a separate bit: terminal ERROR/DISCONNECTED
    // must still retire credentials for the exact live owner after frame
    // delivery is cancelled, but a synthetic stop of a never-installed engine
    // must not retire the current recovery action.
    std::atomic<bool> suppressTerminalRetirement {false};
    std::atomic<bool> startFinished {false};
    std::atomic<State> state {State::StartingNotWritable};
};

VncAdapter::VncAdapter() : impl_(std::make_unique<Impl>()) {
    try {
        impl_->recoveryWorker =
            std::thread([this]() { runNetworkRecoveryWorker(); });
        std::lock_guard<std::mutex> lock(impl_->recoveryMutex);
        impl_->recoveryWorkerReady = true;
    } catch (...) {
        std::lock_guard<std::mutex> lock(impl_->recoveryMutex);
        impl_->recoveryWorkerReady = false;
    }
    OH_LOG_INFO(LOG_APP, "[VNC] VncAdapter 已创建");
}
VncAdapter::~VncAdapter() {
    if (impl_ && impl_->callbackState) {
        impl_->callbackState->invalidate();
    }
    if (impl_) {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        // A state callback is allowed to release its adapter owner. Revoke the
        // adapter-side copies before disconnect can publish another callback
        // into the same destruction stack.
        impl_->videoCallback = nullptr;
        impl_->audioCallback = nullptr;
        impl_->stateCallback = nullptr;
#ifdef RDP_NATIVE_CALLBACK_TESTING
        impl_->engineStartHook = nullptr;
        impl_->beforeNetworkRetirementWaitHook = nullptr;
        impl_->afterNetworkDetachHook = nullptr;
#endif
    }
    disconnect();
    stopNetworkRecoveryWorker();
    OH_LOG_INFO(LOG_APP, "[VNC] VncAdapter 已销毁");
}

std::string VncAdapter::protocolName() { return "VNC"; }
int VncAdapter::defaultPort() { return 5900; }
std::string VncAdapter::protocolVersion() { return "RFB 3.3/3.7/3.8"; }

void VncAdapter::setSessionIdentity(uint64_t sessionId) {
    const uint64_t generation =
        g_nextVncCursorGeneration.fetch_add(1, std::memory_order_relaxed);
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->sessionId = sessionId;
    impl_->cursorGeneration = generation;
    impl_->callbackState->cursorStore.reset(sessionId, "vnc", generation);
    impl_->callbackState->cursorStore.setFallbackShape();
    impl_->callbackState->cursorStore.setVisible(true);
}

void VncAdapter::setSessionOwner(const Render::DecoderSessionIdentity& owner) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->owner = owner;
    impl_->callbackState->owner = owner;
}

RemoteCursorSnapshot VncAdapter::getRemoteCursorSnapshot(bool includePixels) {
    RemoteCursorSnapshot snapshot = impl_->callbackState->cursorStore.snapshot(includePixels);
    std::shared_ptr<VncRfbEngine> engine;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        engine = impl_->engine;
    }
    // Fail visible before the asynchronous RFB banner is available. Once the
    // handshake classifies the peer, modern no-Cursor servers transition to
    // framebuffer ownership while legacy macOS-style peers keep bootstrap.
    snapshot.legacyVncCursorBootstrap = engine == nullptr ||
        engine->keepsLocalCursorDuringBootstrap();
    return snapshot;
}

int VncAdapter::connect(const ConnectionConfig& cfg) {
    const auto operationMutex = impl_->operationMutex;
    std::lock_guard<std::recursive_mutex> operationLock(
        *operationMutex);
    const uint64_t ownerToken =
        impl_->networkRecovery->admitConnectionOwner();
    // A user-initiated replacement irrevocably supersedes the prior recovery
    // credential owner, even if exact transport retirement later times out.
    impl_->reconnectConfig->clear();
    impl_->recoveryCv.notify_all();
#ifdef RDP_NATIVE_CALLBACK_TESTING
    std::function<void()> beforeRetirementWaitHook;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        beforeRetirementWaitHook =
            impl_->beforeNetworkRetirementWaitHook;
    }
    if (beforeRetirementWaitHook) {
        beforeRetirementWaitHook();
    }
#endif
    if (!waitForNetworkRetirementWithin(kVncExactRetirementBudget)) {
        const uint64_t retirementToken =
            impl_->networkRecovery->retireConnectionOwner();
        if (impl_->networkRecovery->isRetired(retirementToken)) {
            impl_->reconnectConfig->clearIfOwnedBy(ownerToken);
        }
        return -16;
    }
    const remotedesk::net::NetworkGenerationSnapshot networkSnapshot =
        remotedesk::net::ProcessNetworkGenerationFence().snapshot();
    const int result =
        connectInternal(cfg, ownerToken, networkSnapshot.generation);
    if (result != 0) {
        impl_->recoveryCv.notify_all();
        failNetworkRecoveryIfCurrent(
            ownerToken,
            "VNC connection could not start [E-VNC-CONNECT-START]");
    }
    return result;
}

bool VncAdapter::waitForNetworkRetirementWithin(
    std::chrono::milliseconds timeout) {
    std::unique_lock<std::mutex> lock(impl_->recoveryMutex);
    return impl_->recoveryCv.wait_for(lock, timeout, [this]() {
        return !impl_->retirementFenceBroken &&
            !impl_->recoveryRetirementActive &&
            !impl_->pendingRecoveryJob.has_value();
    });
}

bool VncAdapter::retireEnginesBeforeReplacement(
    std::shared_ptr<VncRfbEngine>& engine,
    std::shared_ptr<VncRfbEngine>& startingEngine) {
    if (!engine && !startingEngine) {
        return true;
    }
    if (engine) engine->requestStop();
    if (startingEngine) startingEngine->requestStop();

    const auto deadline =
        std::chrono::steady_clock::now() + kVncExactRetirementBudget;
    auto retireWithinDeadline = [&deadline](
        std::shared_ptr<VncRfbEngine>& target) {
        if (!target) return;
        if (target->isWorkerThread()) return;
        const auto now = std::chrono::steady_clock::now();
        const auto remaining = now < deadline
            ? std::chrono::duration_cast<std::chrono::milliseconds>(
                  deadline - now)
            : std::chrono::milliseconds(0);
        if (target->stopWithin(remaining)) {
            target.reset();
        }
    };
    retireWithinDeadline(engine);
    retireWithinDeadline(startingEngine);
    if (!engine && !startingEngine) {
        return true;
    }

    NetworkRecoveryJob retirementJob;
    retirementJob.retiringEngine = std::move(engine);
    retirementJob.retiringStartingEngine = std::move(startingEngine);
    retirementJob.performRecovery = false;
    if (enqueueNetworkRecovery(retirementJob)) {
        return false;
    }

    {
        std::lock_guard<std::mutex> lock(impl_->recoveryMutex);
        // No later transport may be admitted after an exact-retirement owner
        // handoff failed. The adapter remains fail-closed until destruction.
        impl_->retirementFenceBroken = true;
    }
    if (retirementJob.retiringEngine) {
        VncRfbEngine::deferStopAndJoin(
            std::move(retirementJob.retiringEngine));
    }
    if (retirementJob.retiringStartingEngine) {
        VncRfbEngine::deferStopAndJoin(
            std::move(retirementJob.retiringStartingEngine));
    }
    impl_->recoveryCv.notify_all();
    return false;
}

int VncAdapter::connectInternal(
    const ConnectionConfig& cfg, uint64_t expectedToken,
    uint64_t expectedNetworkGeneration) {
    if (!impl_->networkRecovery->isCurrent(expectedToken)) {
        return -16;
    }
    const uint64_t connectionSerial = connectionSerial_.fetch_add(
        1, std::memory_order_acq_rel) + 1;
    auto callbackState = impl_->callbackState;
    callbackState->active.store(true, std::memory_order_release);
    callbackState->serial.store(connectionSerial, std::memory_order_release);
    std::shared_ptr<VncRfbEngine> previousEngine;
    std::shared_ptr<VncRfbEngine> previousStartingEngine;
    bool startingBoundaryActive = false;
    {
        std::lock_guard<std::mutex> lifecycleLock(lifecycleMutex_);
        if (impl_->startingSlot) {
            impl_->startingSlot->cancelled.store(true, std::memory_order_release);
            if (impl_->startingSlot->startFinished.load(std::memory_order_acquire)) {
                previousStartingEngine = impl_->startingSlot->engine;
                impl_->startingSlot.reset();
            } else {
                startingBoundaryActive = true;
            }
        }
        if (!startingBoundaryActive) {
            previousEngine = detachEngineLocked(
                nullptr, ConnectionState::CONNECTING);
        }
    }
    if (startingBoundaryActive) {
        return -16;
    }
    {
        std::lock_guard<std::mutex> stateLock(
            impl_->callbackState->mutex);
        impl_->callbackState->activeEngine.reset();
    }
    const bool previousRetired = retireEnginesBeforeReplacement(
        previousEngine, previousStartingEngine);
    if (!previousRetired) {
        return -16;
    }

    uint64_t cursorGeneration = 0;
    ConnectionStateCallback connectingCallback;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->reconnectConfig->replace(expectedToken, cfg);
        impl_->state = ConnectionState::CONNECTING;
        if (impl_->cursorGeneration == 0) {
            impl_->cursorGeneration =
                g_nextVncCursorGeneration.fetch_add(1, std::memory_order_relaxed);
            callbackState->cursorStore.reset(impl_->sessionId, "vnc", impl_->cursorGeneration);
            callbackState->cursorStore.setFallbackShape();
        }
        cursorGeneration = impl_->cursorGeneration;
        callbackState->cursorStore.setVisible(true);
        if (!isNetworkRecoveryWorkerThread()) {
            connectingCallback = impl_->stateCallback;
        }
    }
    {
        std::lock_guard<std::mutex> stateLock(callbackState->mutex);
        callbackState->state = ConnectionState::CONNECTING;
    }
    Render::DecoderSessionIdentity capturedOwner;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        capturedOwner = impl_->owner;
    }

    const auto slot = std::make_shared<StartingSlot>();
    slot->serial = connectionSerial;
    slot->callbackState = callbackState;
    const auto networkRecovery = impl_->networkRecovery;
    const auto reconnectConfig = impl_->reconnectConfig;
    const auto operationMutex = impl_->operationMutex;
    auto frameCallback = [callbackState, slot, capturedOwner](const VideoFrame& frame) {
        if (!callbackState->dispatchVideo(frame, capturedOwner, slot->serial, slot->engine)) {
            slot->cancelled.store(true, std::memory_order_release);
        }
    };
    auto stateCallback = [callbackState, slot, capturedOwner,
                          networkRecovery, reconnectConfig, operationMutex,
                          expectedToken](
                             ConnectionState state,
                             const std::string& message) {
        const auto operationLane = operationMutex;
        std::lock_guard<std::recursive_mutex> operationLock(
            *operationLane);
        if ((state == ConnectionState::ERROR ||
             state == ConnectionState::DISCONNECTED) &&
            !slot->suppressTerminalRetirement.load(
                std::memory_order_acquire) &&
            networkRecovery->retireConnectionOwnerIfCurrent(
                expectedToken)) {
            // Engine start is asynchronous: TLS/auth/session failure can be
            // terminal after connectInternal() has returned success. Retire
            // only the exact owner that created this engine and wipe its
            // reconnect copy before any later default-network callback can
            // replay the credentials.
            reconnectConfig->clearIfOwnedBy(expectedToken);
        }
        if (slot->cancelled.load(std::memory_order_acquire)) {
            return;
        }
        {
            std::lock_guard<std::mutex> lock(callbackState->mutex);
            if (callbackState->active.load(std::memory_order_relaxed) &&
                callbackState->serial.load(std::memory_order_relaxed) ==
                    slot->serial) {
                callbackState->state = state;
            }
        }
        auto ownerLease = Render::SharedSessionSinkOwnerLease().acquire(capturedOwner);
        if (!ownerLease || !callbackState->beginCallback(slot->serial, slot->engine)) {
            return;
        }
        ConnectionStateCallback callback;
        {
            std::lock_guard<std::mutex> lock(callbackState->mutex);
            callbackState->state = state;
            callback = callbackState->stateCallback;
        }
        if (callback) {
            try {
                callback(state, message);
            } catch (...) {
                OH_LOG_ERROR(LOG_APP, "[VNC] engine state callback threw");
            }
        }
        callbackState->endCallback();
    };
    auto cursorCallback = [callbackState, slot, cursorGeneration, capturedOwner](
        const VncCursorProtocol::DecodedCursor& cursor) {
        auto ownerLease = Render::SharedSessionSinkOwnerLease().acquire(capturedOwner);
        if (!ownerLease || !callbackState->beginCallback(slot->serial, slot->engine)) {
            return;
        }
        if (cursorGeneration == 0) {
            callbackState->endCallback();
            return;
        }
        callbackState->applyProtocolCursor(cursorGeneration, cursor);
        callbackState->endCallback();
    };
    slot->engine = std::make_shared<VncRfbEngine>(
        cfg, std::move(frameCallback), std::move(stateCallback),
        std::move(cursorCallback), expectedNetworkGeneration);
    {
        std::lock_guard<std::mutex> lifecycleLock(lifecycleMutex_);
        if (connectionSerial_.load(std::memory_order_acquire) != connectionSerial ||
            !impl_->networkRecovery->isCurrent(expectedToken)) {
            slot->cancelled.store(true, std::memory_order_release);
        } else {
            if (impl_->startingSlot) {
                impl_->startingSlot->cancelled.store(true, std::memory_order_release);
            }
            impl_->startingSlot = slot;
        }
    }
    if (slot->cancelled.load(std::memory_order_acquire)) {
        slot->suppressTerminalRetirement.store(
            true, std::memory_order_release);
        std::shared_ptr<VncRfbEngine> cancelledEngine = slot->engine;
        std::shared_ptr<VncRfbEngine> noStartingEngine;
        (void)retireEnginesBeforeReplacement(
            cancelledEngine, noStartingEngine);
        return -16;
    }

    int result = -12;
#ifdef RDP_NATIVE_CALLBACK_TESTING
    std::function<int(VncRfbEngine&)> startHook;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        startHook = impl_->engineStartHook;
    }
    result = startHook ? startHook(*slot->engine) : slot->engine->start();
#else
    result = slot->engine->start();
#endif
    slot->startFinished.store(true, std::memory_order_release);

    bool install = false;
    std::shared_ptr<VncRfbEngine> staleEngine;
    {
        std::lock_guard<std::mutex> lifecycleLock(lifecycleMutex_);
        if (impl_->startingSlot == slot) {
            impl_->startingSlot.reset();
            if (result == 0 &&
                connectionSerial_.load(std::memory_order_acquire) == connectionSerial &&
                impl_->networkRecovery->isCurrent(expectedToken) &&
                !slot->cancelled.load(std::memory_order_acquire)) {
                std::lock_guard<std::mutex> lock(impl_->mutex);
                if (!impl_->engine) {
                    impl_->engine = slot->engine;
                    {
                        std::lock_guard<std::mutex> stateLock(callbackState->mutex);
                        callbackState->activeEngine = slot->engine;
                    }
                    slot->state.store(StartingSlot::State::ActiveWritable,
                                      std::memory_order_release);
                    install = true;
                }
            }
            if (!install) {
                slot->suppressTerminalRetirement.store(
                    true, std::memory_order_release);
                slot->cancelled.store(true, std::memory_order_release);
                staleEngine = slot->engine;
            }
        } else if (result == 0) {
            slot->suppressTerminalRetirement.store(
                true, std::memory_order_release);
            slot->cancelled.store(true, std::memory_order_release);
            staleEngine = slot->engine;
        }
    }
    if (staleEngine) {
        std::shared_ptr<VncRfbEngine> noStartingEngine;
        if (!retireEnginesBeforeReplacement(
                staleEngine, noStartingEngine)) {
            return -16;
        }
    }
    if (!install) {
        ConnectionState terminalState = ConnectionState::CONNECTING;
        {
            std::lock_guard<std::mutex> stateLock(callbackState->mutex);
            terminalState = callbackState->state;
        }
        if (terminalState == ConnectionState::ERROR ||
            terminalState == ConnectionState::DISCONNECTED ||
            terminalState == ConnectionState::RECONNECTING) {
            std::lock_guard<std::mutex> lock(impl_->mutex);
            impl_->state = terminalState;
        }
        return result == 0 ? -16 : result;
    }
    if (connectingCallback) {
        try {
            connectingCallback(
                ConnectionState::CONNECTING, "VNC 正在连接");
        } catch (...) {
            OH_LOG_ERROR(LOG_APP, "[VNC] connecting callback threw");
        }
    }
    return result;
}

void VncAdapter::disconnect() {
    const auto operationMutex = impl_->operationMutex;
    std::lock_guard<std::recursive_mutex> operationLock(
        *operationMutex);
    const uint64_t retirementToken =
        impl_->networkRecovery->retireConnectionOwner();
    impl_->recoveryCv.notify_all();
    if (impl_->networkRecovery->isRetired(retirementToken)) {
        impl_->reconnectConfig->clear();
    }
    // Keep callback publication as the final adapter access. A callback may
    // synchronously release the last adapter owner; operationMutex remains
    // alive through the local shared owner until this stack unlocks it.
    disconnectInternal(true);
}

void VncAdapter::disconnectInternal(bool publishDisconnected) {
    const uint64_t serial = connectionSerial_.fetch_add(1, std::memory_order_acq_rel) + 1;
    impl_->callbackState->serial.store(serial, std::memory_order_release);
    std::shared_ptr<VncRfbEngine> engine;
    std::shared_ptr<VncRfbEngine> startingEngine;
    ConnectionStateCallback callback;
    {
        std::lock_guard<std::mutex> lifecycleLock(lifecycleMutex_);
        engine = detachEngineLocked(&callback);
        if (impl_->startingSlot) {
            impl_->startingSlot->cancelled.store(true, std::memory_order_release);
            if (impl_->startingSlot->startFinished.load(std::memory_order_acquire)) {
                startingEngine = impl_->startingSlot->engine;
                impl_->startingSlot.reset();
            }
        }
    }
    {
        std::lock_guard<std::mutex> stateLock(impl_->callbackState->mutex);
        impl_->callbackState->activeEngine.reset();
        impl_->callbackState->state = ConnectionState::DISCONNECTED;
    }
    if (engine) engine->requestStop();
    if (startingEngine) startingEngine->requestStop();
    if (engine || startingEngine) {
        NetworkRecoveryJob retirementJob;
        retirementJob.retiringEngine = std::move(engine);
        retirementJob.retiringStartingEngine =
            std::move(startingEngine);
        retirementJob.performRecovery = false;
        if (!enqueueNetworkRecovery(retirementJob)) {
            {
                std::lock_guard<std::mutex> lock(impl_->recoveryMutex);
                impl_->retirementFenceBroken = true;
            }
            if (retirementJob.retiringEngine) {
                VncRfbEngine::deferStopAndJoin(
                    std::move(retirementJob.retiringEngine));
            }
            if (retirementJob.retiringStartingEngine) {
                VncRfbEngine::deferStopAndJoin(
                    std::move(retirementJob.retiringStartingEngine));
            }
            impl_->recoveryCv.notify_all();
        }
    }
    if (publishDisconnected && callback) {
        try {
            callback(ConnectionState::DISCONNECTED, "VNC 已断开");
        } catch (...) {
            OH_LOG_ERROR(LOG_APP, "[VNC] disconnect callback threw");
        }
    }
}

void VncAdapter::onNetworkChanged(
    bool available, uint64_t networkGeneration) {
    // Public connect/disconnect, initial recovery-state publication and
    // recovery installation share this lane. The worker can retire engines
    // while this lock is held, but it cannot publish or reconnect before the
    // initial RECONNECTING state has been delivered.
    const auto operationMutex = impl_->operationMutex;
    std::lock_guard<std::recursive_mutex> operationLock(
        *operationMutex);
    const VncNetworkRecoveryAction action =
        impl_->networkRecovery->onNetworkChanged(
            available, networkGeneration);
    if (!action.accepted ||
        !impl_->networkRecovery->isCurrent(action.token)) {
        return;
    }
    if (!impl_->reconnectConfig->rebind(action.token)) {
        failNetworkRecoveryIfCurrent(
            action.token,
            "VNC reconnect configuration is unavailable "
            "[E-VNC-NETWORK-CONFIG]");
        return;
    }

    NetworkRecoveryJob job;
    job.action = action;
    const uint64_t serial = connectionSerial_.fetch_add(
        1, std::memory_order_acq_rel) + 1;
    impl_->callbackState->serial.store(serial, std::memory_order_release);
    {
        std::lock_guard<std::mutex> lifecycleLock(lifecycleMutex_);
        job.retiringEngine = detachEngineLocked(
            nullptr, ConnectionState::RECONNECTING);
        job.retiringStartingEngine = detachStartingEngineLocked();
    }
    {
        std::lock_guard<std::mutex> stateLock(
            impl_->callbackState->mutex);
        impl_->callbackState->activeEngine.reset();
        impl_->callbackState->state = ConnectionState::RECONNECTING;
    }
#ifdef RDP_NATIVE_CALLBACK_TESTING
    std::function<void()> afterDetachHook;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        afterDetachHook = impl_->afterNetworkDetachHook;
    }
    if (afterDetachHook) {
        afterDetachHook();
    }
#endif
    if (action.cancelTransport && job.retiringEngine) {
        job.retiringEngine->requestStop();
    }
    if (action.cancelTransport && job.retiringStartingEngine) {
        job.retiringStartingEngine->requestStop();
    }

    if (!enqueueNetworkRecovery(job)) {
        if (job.retiringEngine || job.retiringStartingEngine) {
            std::lock_guard<std::mutex> lock(impl_->recoveryMutex);
            // A live detached engine no longer has an adapter-local exact
            // retirement owner. Preserve it in the process owner, and prevent
            // this adapter from admitting a replacement transport.
            impl_->retirementFenceBroken = true;
        }
        if (job.retiringEngine) {
            VncRfbEngine::deferStopAndJoin(
                std::move(job.retiringEngine));
        }
        if (job.retiringStartingEngine) {
            VncRfbEngine::deferStopAndJoin(
                std::move(job.retiringStartingEngine));
        }
        impl_->recoveryCv.notify_all();
        failNetworkRecoveryIfCurrent(
            action.token,
            "VNC network recovery worker is unavailable "
            "[E-VNC-NETWORK-WORKER]");
        return;
    }
    publishNetworkStateIfCurrent(
        action.token, ConnectionState::RECONNECTING,
        action.networkAvailable
            ? "VNC network changed; retiring the previous transport"
            : "VNC is waiting for the default network");
}

bool VncAdapter::enqueueNetworkRecovery(NetworkRecoveryJob& job) {
    try {
        {
            std::lock_guard<std::mutex> lock(impl_->recoveryMutex);
            if (!impl_->recoveryWorkerReady ||
                impl_->recoveryWorkerStopping) {
                return false;
            }
            if (!impl_->pendingRecoveryJob.has_value()) {
                impl_->pendingRecoveryJob.emplace(std::move(job));
            } else {
                NetworkRecoveryJob& pending =
                    *impl_->pendingRecoveryJob;
                if ((pending.retiringEngine && job.retiringEngine) ||
                    (pending.retiringStartingEngine &&
                     job.retiringStartingEngine)) {
                    // The single-pending-job invariant means this can only be
                    // reached after an unexpected lifecycle re-entry. Refuse
                    // to drop either exact-retirement owner.
                    return false;
                }
                if (!pending.retiringEngine) {
                    pending.retiringEngine =
                        std::move(job.retiringEngine);
                }
                if (!pending.retiringStartingEngine) {
                    pending.retiringStartingEngine =
                        std::move(job.retiringStartingEngine);
                }
                if (job.performRecovery) {
                    // Network-event storms collapse to the newest accepted
                    // generation while retaining any engine already queued
                    // for exact retirement.
                    pending.action = job.action;
                    pending.performRecovery = true;
                } else {
                    // Explicit connection admission invalidates older recovery
                    // metadata but still preserves all detached engines.
                    pending.action = VncNetworkRecoveryAction {};
                    pending.performRecovery = false;
                }
            }
            impl_->maxPendingRecoveryJobs = std::max(
                impl_->maxPendingRecoveryJobs,
                static_cast<size_t>(1));
        }
        impl_->recoveryCv.notify_one();
        return true;
    } catch (...) {
        return false;
    }
}

void VncAdapter::publishNetworkStateIfCurrent(
    uint64_t token, ConnectionState state, const std::string& message,
    bool requireAvailable) {
    const auto operationMutex = impl_->operationMutex;
    std::lock_guard<std::recursive_mutex> operationLock(
        *operationMutex);
    if (!impl_->networkRecovery->isCurrent(token, requireAvailable)) {
        return;
    }
    const auto callbackState = impl_->callbackState;
    const auto stateCallbackCarrier = impl_->stateCallbackCarrier;
    const uint64_t serial = callbackState->serial.load(
        std::memory_order_acquire);
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->state = state;
    }
    {
        std::lock_guard<std::mutex> lock(callbackState->mutex);
        callbackState->state = state;
    }
    if (isNetworkRecoveryWorkerThread()) {
        if (!stateCallbackCarrier->enqueue(
                operationMutex, serial, state, message)) {
            OH_LOG_ERROR(
                LOG_APP, "[VNC] state callback carrier unavailable");
        }
        return;
    }
    (void)callbackState->dispatchState(serial, state, message);
}

void VncAdapter::failNetworkRecoveryIfCurrent(
    uint64_t token, const std::string& message) {
    const auto operationMutex = impl_->operationMutex;
    std::lock_guard<std::recursive_mutex> operationLock(
        *operationMutex);
    if (!impl_->networkRecovery->isCurrent(token)) {
        return;
    }
    const bool retired =
        impl_->networkRecovery->retireConnectionOwnerIfCurrent(token);
    if (!retired) {
        return;
    }
    impl_->reconnectConfig->clearIfOwnedBy(token);
    const auto callbackState = impl_->callbackState;
    const auto stateCallbackCarrier = impl_->stateCallbackCarrier;
    const uint64_t serial = callbackState->serial.load(
        std::memory_order_acquire);
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->state = ConnectionState::ERROR;
    }
    {
        std::lock_guard<std::mutex> lock(callbackState->mutex);
        callbackState->state = ConnectionState::ERROR;
    }
    if (isNetworkRecoveryWorkerThread()) {
        if (!stateCallbackCarrier->enqueue(
                operationMutex, serial, ConnectionState::ERROR, message)) {
            OH_LOG_ERROR(
                LOG_APP, "[VNC] failure callback carrier unavailable");
        }
        return;
    }
    (void)callbackState->dispatchState(
        serial, ConnectionState::ERROR, message);
}

bool VncAdapter::isNetworkRecoveryWorkerThread() const {
    return impl_->recoveryWorker.joinable() &&
        impl_->recoveryWorker.get_id() == std::this_thread::get_id();
}

void VncAdapter::runNetworkRecoveryWorker() {
    auto deferJobEngines = [](NetworkRecoveryJob& job) {
        if (job.retiringEngine) {
            VncRfbEngine::deferStopAndJoin(
                std::move(job.retiringEngine));
        }
        if (job.retiringStartingEngine) {
            VncRfbEngine::deferStopAndJoin(
                std::move(job.retiringStartingEngine));
        }
    };

    for (;;) {
        NetworkRecoveryJob job;
        std::optional<NetworkRecoveryJob> abandoned;
        bool requestedStop = false;
        {
            std::unique_lock<std::mutex> lock(impl_->recoveryMutex);
            impl_->recoveryCv.wait(lock, [this]() {
                return impl_->recoveryWorkerStopping ||
                    impl_->pendingRecoveryJob.has_value();
            });
            if (impl_->recoveryWorkerStopping) {
                requestedStop = true;
                if (impl_->pendingRecoveryJob.has_value()) {
                    abandoned.emplace(
                        std::move(*impl_->pendingRecoveryJob));
                    impl_->pendingRecoveryJob.reset();
                }
            } else {
                job = std::move(*impl_->pendingRecoveryJob);
                impl_->pendingRecoveryJob.reset();
                impl_->recoveryRetirementActive = true;
            }
        }
        impl_->recoveryCv.notify_all();
        if (requestedStop) {
            if (abandoned.has_value()) {
                deferJobEngines(*abandoned);
            }
            return;
        }

        bool stopWorker = false;
        std::shared_ptr<VncRfbEngine>* retiringEngines[] = {
            &job.retiringEngine,
            &job.retiringStartingEngine,
        };
        for (std::shared_ptr<VncRfbEngine>* engineSlot : retiringEngines) {
            std::shared_ptr<VncRfbEngine>& engine = *engineSlot;
            if (!engine) {
                continue;
            }
            engine->requestStop();
            while (!engine->stopWithin(std::chrono::milliseconds(50))) {
                std::lock_guard<std::mutex> lock(impl_->recoveryMutex);
                if (impl_->recoveryWorkerStopping) {
                    VncRfbEngine::deferStopAndJoin(std::move(engine));
                    stopWorker = true;
                    break;
                }
            }
            if (stopWorker) {
                break;
            }
            engine.reset();
        }

        std::optional<NetworkRecoveryJob> pendingAtStop;
        {
            std::lock_guard<std::mutex> lock(impl_->recoveryMutex);
            impl_->recoveryRetirementActive = false;
            if (impl_->recoveryWorkerStopping) {
                stopWorker = true;
                if (impl_->pendingRecoveryJob.has_value()) {
                    pendingAtStop.emplace(
                        std::move(*impl_->pendingRecoveryJob));
                    impl_->pendingRecoveryJob.reset();
                }
            }
        }
        impl_->recoveryCv.notify_all();
        if (stopWorker) {
            deferJobEngines(job);
            if (pendingAtStop.has_value()) {
                deferJobEngines(*pendingAtStop);
            }
            return;
        }

        if (!job.performRecovery) {
            continue;
        }
        if (!impl_->networkRecovery->isCurrent(job.action.token)) {
            continue;
        }
        if (!job.action.reconnectAfterRetirement) {
            publishNetworkStateIfCurrent(
                job.action.token, ConnectionState::RECONNECTING,
                "VNC is waiting for the default network");
            continue;
        }
        publishNetworkStateIfCurrent(
            job.action.token, ConnectionState::RECONNECTING,
            "VNC network changed; resolving the endpoint again", true);

        ConnectionConfig reconnectConfig;
        int result = -16;
        try {
            {
                const auto operationMutex = impl_->operationMutex;
                std::lock_guard<std::recursive_mutex> operationLock(
                    *operationMutex);
                if (!impl_->networkRecovery->isCurrent(
                        job.action.token, true)) {
                    continue;
                }
                const bool hasReconnectConfig =
                    impl_->reconnectConfig->snapshot(
                        job.action.token, reconnectConfig);
                if (hasReconnectConfig) {
                    result = connectInternal(
                        reconnectConfig, job.action.token,
                        job.action.networkGeneration);
                }
            }
        } catch (...) {
            secureClearString(reconnectConfig.password);
            secureClearString(reconnectConfig.privateKeyPem);
            secureClearString(reconnectConfig.privateKeyPassphrase);
            try {
                failNetworkRecoveryIfCurrent(
                    job.action.token,
                    "VNC network recovery failed unexpectedly "
                    "[E-VNC-NETWORK-EXCEPTION]");
            } catch (...) {
                OH_LOG_ERROR(LOG_APP,
                    "[VNC] network recovery exception publication failed");
            }
            continue;
        }
        secureClearString(reconnectConfig.password);
        secureClearString(reconnectConfig.privateKeyPem);
        secureClearString(reconnectConfig.privateKeyPassphrase);
        if (result != 0) {
            try {
                failNetworkRecoveryIfCurrent(
                    job.action.token,
                    "VNC network recovery could not start "
                    "[E-VNC-NETWORK-RECOVERY]");
            } catch (...) {
                OH_LOG_ERROR(LOG_APP,
                    "[VNC] network recovery failure publication failed");
            }
        }
    }
}

void VncAdapter::stopNetworkRecoveryWorker() {
    {
        std::lock_guard<std::mutex> lock(impl_->recoveryMutex);
        impl_->recoveryWorkerStopping = true;
        impl_->recoveryWorkerReady = false;
    }
    impl_->recoveryCv.notify_all();
    if (!impl_->recoveryWorker.joinable()) {
        return;
    }
    if (impl_->recoveryWorker.get_id() == std::this_thread::get_id()) {
        // The worker never invokes an owner-release callback. Reaching this
        // path would otherwise destroy a joinable thread and reclaim Impl
        // underneath it, so fail closed rather than detach a dangling owner.
        std::abort();
    }
    impl_->recoveryWorker.join();
}

std::shared_ptr<VncRfbEngine> VncAdapter::detachEngineLocked(
    ConnectionStateCallback* callback, ConnectionState detachedState) {
    std::shared_ptr<VncRfbEngine> engine;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        // A std::function copy may allocate. Complete it before moving the
        // sole active-engine owner so an exception cannot orphan a joinable
        // RFB worker outside either the adapter or deferred owner.
        if (callback != nullptr) {
            *callback = impl_->stateCallback;
        }
        engine = std::move(impl_->engine);
        impl_->state = detachedState;
        if (impl_->cursorGeneration != 0) {
            impl_->callbackState->cursorStore.setVisibleIfGeneration(
                impl_->cursorGeneration, false);
        }
    }
    return engine;
}

std::shared_ptr<VncRfbEngine> VncAdapter::detachStartingEngineLocked() {
    if (!impl_->startingSlot) {
        return nullptr;
    }
    impl_->startingSlot->cancelled.store(true, std::memory_order_release);
    if (!impl_->startingSlot->startFinished.load(std::memory_order_acquire)) {
        return nullptr;
    }
    const auto engine = impl_->startingSlot->engine;
    impl_->startingSlot.reset();
    return engine;
}

bool VncAdapter::acceptsStartingSlot(const std::shared_ptr<StartingSlot>& slot) {
    if (!slot || slot->cancelled.load(std::memory_order_acquire)) {
        return false;
    }
    std::lock_guard<std::mutex> lifecycleLock(lifecycleMutex_);
    if (connectionSerial_.load(std::memory_order_acquire) != slot->serial) {
        return false;
    }
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->startingSlot == slot) {
        return slot->state.load(std::memory_order_acquire) ==
            StartingSlot::State::ActiveWritable;
    }
    return impl_->engine && impl_->engine == slot->engine &&
        slot->state.load(std::memory_order_acquire) ==
            StartingSlot::State::ActiveWritable;
}

ConnectionState VncAdapter::getState() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->engine) return impl_->engine->state();
    return impl_->state;
}

void VncAdapter::sendKey(uint32_t scancode, bool pressed) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->engine) impl_->engine->sendKey(scancode, pressed);
}
void VncAdapter::sendMouse(int x, int y, MouseButton button, bool pressed) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->engine) {
        impl_->engine->sendMouse(x, y, button, pressed);
        if (!impl_->reconnectConfig->viewOnly() &&
            impl_->engine->state() == ConnectionState::CONNECTED &&
            impl_->cursorGeneration != 0) {
            impl_->callbackState->updatePredictedCursorPosition(
                impl_->cursorGeneration, x, y);
        }
    }
}
void VncAdapter::sendMouseWheel(int x, int y, int delta) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->engine) {
        impl_->engine->sendMouseWheel(x, y, delta);
        if (!impl_->reconnectConfig->viewOnly() &&
            impl_->engine->state() == ConnectionState::CONNECTED &&
            impl_->cursorGeneration != 0) {
            impl_->callbackState->updatePredictedCursorPosition(
                impl_->cursorGeneration, x, y);
        }
    }
}
void VncAdapter::sendText(const std::string& text) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->engine) impl_->engine->sendText(text);
}

void VncAdapter::sendClipboardData(const uint8_t* data, uint32_t len) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->engine) impl_->engine->sendClipboard(data, len);
}

bool VncAdapter::supportsCodec(CodecType codec) {
    return codec == CodecType::RAW_BGRA;
}
std::vector<CodecType> VncAdapter::supportedCodecs() {
    return {CodecType::RAW_BGRA};
}
void VncAdapter::setVideoCallback(VideoFrameCallback cb) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->videoCallback = cb;
    std::lock_guard<std::mutex> stateLock(impl_->callbackState->mutex);
    impl_->callbackState->videoCallback = std::move(cb);
}

void VncAdapter::dispatchVideoFrame(
    const VideoFrame& frame, const Render::DecoderSessionIdentity& capturedOwner) {
    (void)impl_->callbackState->dispatchVideo(frame, capturedOwner);
}

#ifdef RDP_NATIVE_CALLBACK_TESTING
void VncAdapter::InvokeVideoCallbackForTesting(const VideoFrame& frame) {
    Render::DecoderSessionIdentity owner;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        owner = impl_->owner;
    }
    dispatchVideoFrame(frame, owner);
}

bool VncAdapter::InvokeEngineVideoCallbackForTesting(
    const VideoFrame& frame, const Render::DecoderSessionIdentity& capturedOwner) {
    auto callbackState = impl_->callbackState;
    VncRfbEngine engine(
        ConnectionConfig {},
        [callbackState, capturedOwner](const VideoFrame& emitted) {
            callbackState->dispatchVideo(emitted, capturedOwner);
        },
        nullptr, nullptr);
    return engine.invokeFrameCallbackForTesting(frame);
}

bool VncAdapter::InvokeLateFrameAfterCallbackStateInvalidationForTesting(
    const VideoFrame& frame, const Render::DecoderSessionIdentity& capturedOwner) {
    auto state = impl_->callbackState;
    auto writes = std::make_shared<std::atomic<int>>(0);
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        state->videoCallback = [writes](const VideoFrame&) {
            writes->fetch_add(1, std::memory_order_relaxed);
        };
    }
    auto engine = std::make_shared<VncRfbEngine>(
        ConnectionConfig {},
        [state, capturedOwner](const VideoFrame& emitted) {
            (void)state->dispatchVideo(emitted, capturedOwner);
        },
        nullptr, nullptr);
    {
        std::lock_guard<std::mutex> lock(state->mutex);
        state->activeEngine = engine;
    }
    // This is the same invalidation performed before adapter destruction. The
    // engine then injects a late production frame entry while retaining only
    // the independent callback state.
    state->invalidate();
    (void)engine->invokeFrameCallbackForTesting(frame);
    return writes->load(std::memory_order_acquire) == 0;
}

bool VncAdapter::StartSelfStoppingEngineForTesting() {
    auto callbackRequested = std::make_shared<std::promise<void>>();
    std::future<void> request = callbackRequested->get_future();
    auto callbackCompleted = std::make_shared<std::promise<void>>();
    std::future<void> completion = callbackCompleted->get_future();
    auto releaseCallback = std::make_shared<std::atomic<bool>>(false);
    auto reentrantDisconnectCalled = std::make_shared<std::atomic<bool>>(false);
    auto releaseMutex = std::make_shared<std::mutex>();
    auto releaseCv = std::make_shared<std::condition_variable>();
    Render::DecoderSessionIdentity owner;
    VncRfbEngine* raw = nullptr;
    {
        std::lock_guard<std::mutex> lifecycleLock(lifecycleMutex_);
        std::lock_guard<std::mutex> lock(impl_->mutex);
        owner = impl_->owner;
        if (impl_->engine) return false;
        auto callbackState = impl_->callbackState;
        auto engine = std::make_shared<VncRfbEngine>(
            ConnectionConfig {},
            [callbackState, owner](const VideoFrame& frame) {
                callbackState->dispatchVideo(frame, owner);
            },
            nullptr, nullptr);
        raw = engine.get();
        impl_->engine = std::move(engine);
    }
    // Keep the lifecycle lock out of the production-engine start boundary.
    // The callback intentionally disconnects immediately, so this is also a
    // deterministic regression for the old lock -> engine callback cycle.
    if (raw->startWorkerForTesting(
            [this, callbackRequested, callbackCompleted, releaseCallback,
             reentrantDisconnectCalled, releaseMutex, releaseCv]() {
                callbackRequested->set_value();
                reentrantDisconnectCalled->store(true, std::memory_order_release);
                // Exercise the production worker -> adapter disconnect edge;
                // VncAdapter::disconnect must move the engine to the owned
                // reaper without trying to join this worker inline.
                this->disconnect();
                std::unique_lock<std::mutex> lock(*releaseMutex);
                releaseCv->wait_for(lock, std::chrono::seconds(1), [&]() {
                    return releaseCallback->load(std::memory_order_acquire);
                });
                callbackCompleted->set_value();
            }) != 0) {
        std::shared_ptr<VncRfbEngine> failedEngine;
        {
            std::lock_guard<std::mutex> lifecycleLock(lifecycleMutex_);
            std::lock_guard<std::mutex> lock(impl_->mutex);
            if (impl_->engine.get() == raw) {
                failedEngine = impl_->engine;
                impl_->engine.reset();
            }
        }
        if (failedEngine) {
            failedEngine->stop();
        }
        return false;
    }
    // The worker callback is a production-engine callback but deliberately
    // does not retain `this`. The caller races the real two-phase detach with
    // that callback, then a bounded releaser lets the worker finish. This
    // proves the lifecycle mutex is not held across stop/join without making
    // the test depend on an unbounded wait or a dangling adapter pointer.
    const bool callbackStarted =
        request.wait_for(std::chrono::seconds(1)) == std::future_status::ready;
    std::thread releaser([releaseCallback, releaseMutex, releaseCv]() {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        releaseCallback->store(true, std::memory_order_release);
        std::lock_guard<std::mutex> lock(*releaseMutex);
        releaseCv->notify_all();
    });
    disconnect();
    releaser.join();
    const bool callbackFinished =
        completion.wait_for(std::chrono::seconds(1)) == std::future_status::ready;
    return callbackStarted && callbackFinished &&
        reentrantDisconnectCalled->load(std::memory_order_acquire);
}

void VncAdapter::SetEngineStartHookForTesting(
    std::function<int(VncRfbEngine&)> hook) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->engineStartHook = std::move(hook);
}

void VncAdapter::SetBeforeNetworkRetirementWaitHookForTesting(
    std::function<void()> hook) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->beforeNetworkRetirementWaitHook = std::move(hook);
}

void VncAdapter::SetAfterNetworkDetachHookForTesting(
    std::function<void()> hook) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->afterNetworkDetachHook = std::move(hook);
}

bool VncAdapter::WaitForNetworkRecoveryActiveForTesting(
    std::chrono::milliseconds timeout) {
    std::unique_lock<std::mutex> lock(impl_->recoveryMutex);
    return impl_->recoveryCv.wait_for(lock, timeout, [this]() {
        return impl_->recoveryRetirementActive;
    });
}

bool VncAdapter::WaitForNetworkRecoveryIdleForTesting(
    std::chrono::milliseconds timeout) {
    return waitForNetworkRetirementWithin(timeout);
}

size_t VncAdapter::PendingNetworkRecoveryJobsForTesting() {
    std::lock_guard<std::mutex> lock(impl_->recoveryMutex);
    return impl_->pendingRecoveryJob.has_value() ? 1U : 0U;
}

size_t VncAdapter::MaxPendingNetworkRecoveryJobsForTesting() {
    std::lock_guard<std::mutex> lock(impl_->recoveryMutex);
    return impl_->maxPendingRecoveryJobs;
}

size_t VncAdapter::PendingStateCallbacksForTesting() {
    return impl_->stateCallbackCarrier->pendingCount();
}

size_t VncAdapter::MaxPendingStateCallbacksForTesting() {
    return impl_->stateCallbackCarrier->maxPendingCount();
}

void VncAdapter::SetBeforeStateCarrierOperationLockHookForTesting(
    std::function<void()> hook) {
    impl_->stateCallbackCarrier->setBeforeOperationLockHook(
        std::move(hook));
}

bool VncAdapter::WaitForStateCallbacksIdleForTesting(
    std::chrono::milliseconds timeout) {
    return impl_->stateCallbackCarrier->waitForIdle(timeout);
}

bool VncAdapter::IsNetworkRecoveryWorkerThreadForTesting() const {
    return isNetworkRecoveryWorkerThread();
}

bool VncAdapter::RetainsReconnectCredentialMaterialForTesting() {
    return impl_->reconnectConfig->retainsCredentialMaterial();
}

void VncAdapter::InvokeProtocolCursorCallbackForTesting(
    const VncCursorProtocol::DecodedCursor& cursor) {
    uint64_t generation = 0;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        generation = impl_->cursorGeneration;
    }
    impl_->callbackState->applyProtocolCursor(generation, cursor);
}

void VncAdapter::UpdatePredictedCursorPositionForTesting(int x, int y) {
    uint64_t generation = 0;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        generation = impl_->cursorGeneration;
    }
    impl_->callbackState->updatePredictedCursorPosition(generation, x, y);
}
#endif

void VncAdapter::setAudioCallback(AudioDataCallback cb) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->audioCallback = cb;
    std::lock_guard<std::mutex> stateLock(impl_->callbackState->mutex);
    impl_->callbackState->audioCallback = std::move(cb);
}
void VncAdapter::setConnectionStateCallback(ConnectionStateCallback cb) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->stateCallback = cb;
    std::lock_guard<std::mutex> stateLock(impl_->callbackState->mutex);
    impl_->callbackState->stateCallback = std::move(cb);
}
void VncAdapter::requestFrameRefresh() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->engine) impl_->engine->requestFrameRefresh();
}
std::string VncAdapter::getClipboardText() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return impl_->engine ? impl_->engine->clipboardText() : "";
}
bool VncAdapter::isClipboardReceiveReady() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return impl_->engine && impl_->engine->clipboardReady();
}
bool VncAdapter::supportsNatTraversal() { return false; }
bool VncAdapter::supportsFileTransfer() { return false; }

void registerVncAdapter() {
    ExtensionSystem::instance().protocols.registerExt("protocol", "vnc", std::shared_ptr<VncAdapter>(new VncAdapter()));
    OH_LOG_INFO(LOG_APP, "[VNC] VNC 适配器已注册到扩展系统");
}
