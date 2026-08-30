#include "test_runner.h"

#include "vnc/vnc_adapter.h"

#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

using namespace std::chrono_literals;

class WorkerReleaseGuard final {
public:
    WorkerReleaseGuard(
        std::shared_ptr<std::atomic<bool>> release,
        std::shared_ptr<std::mutex> mutex,
        std::shared_ptr<std::condition_variable> condition)
        : release_(std::move(release)), mutex_(std::move(mutex)),
          condition_(std::move(condition)) {}

    ~WorkerReleaseGuard() {
        release_->store(true, std::memory_order_release);
        std::lock_guard<std::mutex> lock(*mutex_);
        condition_->notify_all();
    }

private:
    std::shared_ptr<std::atomic<bool>> release_;
    std::shared_ptr<std::mutex> mutex_;
    std::shared_ptr<std::condition_variable> condition_;
};

void ActivateOwner(const Render::DecoderSessionIdentity& owner) {
    auto& registry = Render::SharedSessionSinkOwnerLease();
    const auto active = registry.snapshot();
    if (active.valid()) {
        auto transition = registry.acquireExclusive();
        RDP_ASSERT(transition.beginDeactivate(active));
    }
    RDP_ASSERT(registry.activate(owner));
}

class OwnerCleanupGuard final {
public:
    explicit OwnerCleanupGuard(Render::DecoderSessionIdentity owner)
        : owner_(owner) {}

    ~OwnerCleanupGuard() {
        auto& registry = Render::SharedSessionSinkOwnerLease();
        if (registry.accepts(owner_)) {
            (void)registry.deactivateIfActive(owner_);
        }
    }

private:
    Render::DecoderSessionIdentity owner_;
};

} // namespace

RDP_TEST_CASE(vnc_explicit_connect_waits_for_network_exact_retirement) {
    VncAdapter adapter;
    auto release = std::make_shared<std::atomic<bool>>(false);
    auto workerEntered = std::make_shared<std::atomic<bool>>(false);
    auto mutex = std::make_shared<std::mutex>();
    auto condition = std::make_shared<std::condition_variable>();
    WorkerReleaseGuard releaseGuard(release, mutex, condition);
    std::atomic<int> startCalls {0};
    std::atomic<int> replacementResult {-99};
    std::atomic<bool> replacementReachedFence {false};

    adapter.SetEngineStartHookForTesting(
        [release, workerEntered, mutex, condition, &startCalls](
            VncRfbEngine& engine) {
            const int call = startCalls.fetch_add(
                1, std::memory_order_acq_rel) + 1;
            condition->notify_all();
            if (call != 1) return -1;
            return engine.startWorkerForTesting(
                [release, workerEntered, mutex, condition]() {
                    workerEntered->store(true, std::memory_order_release);
                    condition->notify_all();
                    std::unique_lock<std::mutex> lock(*mutex);
                    condition->wait(lock, [&]() {
                        return release->load(std::memory_order_acquire);
                    });
                });
        });

    ConnectionConfig config;
    config.host = "127.0.0.1";
    config.port = 5900;
    RDP_ASSERT_EQ(adapter.connect(config), 0);
    {
        std::unique_lock<std::mutex> lock(*mutex);
        RDP_ASSERT(condition->wait_for(lock, 1s, [&]() {
            return workerEntered->load(std::memory_order_acquire);
        }));
    }

    adapter.onNetworkChanged(true, 5001);
    RDP_ASSERT(adapter.WaitForNetworkRecoveryActiveForTesting(1s));
    adapter.SetBeforeNetworkRetirementWaitHookForTesting(
        [&replacementReachedFence, condition]() {
            replacementReachedFence.store(true, std::memory_order_release);
            condition->notify_all();
        });
    std::thread replacement([&]() {
        replacementResult.store(adapter.connect(config),
                                std::memory_order_release);
    });
    {
        std::unique_lock<std::mutex> lock(*mutex);
        RDP_ASSERT(condition->wait_for(lock, 1s, [&]() {
            return replacementReachedFence.load(std::memory_order_acquire);
        }));
        RDP_ASSERT(!condition->wait_for(lock, 100ms, [&]() {
            return startCalls.load(std::memory_order_acquire) > 1;
        }));
    }

    release->store(true, std::memory_order_release);
    condition->notify_all();
    replacement.join();
    RDP_ASSERT_EQ(startCalls.load(std::memory_order_acquire), 2);
    RDP_ASSERT(replacementResult.load(std::memory_order_acquire) != 0);
    RDP_ASSERT(adapter.WaitForNetworkRecoveryIdleForTesting(1s));
    adapter.SetBeforeNetworkRetirementWaitHookForTesting(nullptr);
    adapter.SetEngineStartHookForTesting(nullptr);
}

RDP_TEST_CASE(vnc_initial_network_state_precedes_recovery_connect) {
    VncAdapter adapter;
    auto release = std::make_shared<std::atomic<bool>>(false);
    auto workerEntered = std::make_shared<std::atomic<bool>>(false);
    auto mutex = std::make_shared<std::mutex>();
    auto condition = std::make_shared<std::condition_variable>();
    WorkerReleaseGuard releaseGuard(release, mutex, condition);
    std::atomic<int> startCalls {0};
    std::atomic<bool> initialStatePublished {false};
    std::atomic<bool> recoveryObservedInitialState {false};

    adapter.setConnectionStateCallback(
        [&initialStatePublished](ConnectionState state,
                                 const std::string& message) {
            if (state == ConnectionState::RECONNECTING &&
                message.find("retiring the previous transport") !=
                    std::string::npos) {
                initialStatePublished.store(true,
                                            std::memory_order_release);
            }
        });
    adapter.SetEngineStartHookForTesting(
        [release, workerEntered, mutex, condition, &startCalls,
         &recoveryObservedInitialState, &initialStatePublished](
            VncRfbEngine& engine) {
            const int call = startCalls.fetch_add(
                1, std::memory_order_acq_rel) + 1;
            if (call == 1) {
                engine.setStopObserverForTesting(
                    [release, condition]() {
                        release->store(true, std::memory_order_release);
                        condition->notify_all();
                    });
                return engine.startWorkerForTesting(
                    [release, workerEntered, mutex, condition]() {
                        workerEntered->store(true,
                                             std::memory_order_release);
                        condition->notify_all();
                        std::unique_lock<std::mutex> lock(*mutex);
                        condition->wait(lock, [&]() {
                            return release->load(
                                std::memory_order_acquire);
                        });
                    });
            }
            recoveryObservedInitialState.store(
                initialStatePublished.load(std::memory_order_acquire),
                std::memory_order_release);
            condition->notify_all();
            return -1;
        });

    ConnectionConfig config;
    config.host = "127.0.0.1";
    config.port = 5900;
    RDP_ASSERT_EQ(adapter.connect(config), 0);
    {
        std::unique_lock<std::mutex> lock(*mutex);
        RDP_ASSERT(condition->wait_for(lock, 1s, [&]() {
            return workerEntered->load(std::memory_order_acquire);
        }));
    }

    adapter.onNetworkChanged(true, 6001);
    {
        std::unique_lock<std::mutex> lock(*mutex);
        RDP_ASSERT(condition->wait_for(lock, 1s, [&]() {
            return startCalls.load(std::memory_order_acquire) >= 2;
        }));
    }
    RDP_ASSERT(initialStatePublished.load(std::memory_order_acquire));
    RDP_ASSERT(recoveryObservedInitialState.load(
        std::memory_order_acquire));
    RDP_ASSERT(adapter.WaitForNetworkRecoveryIdleForTesting(1s));
    adapter.SetEngineStartHookForTesting(nullptr);
    adapter.setConnectionStateCallback(nullptr);
}

RDP_TEST_CASE(vnc_network_event_storm_keeps_one_pending_recovery_job) {
    VncAdapter adapter;
    auto release = std::make_shared<std::atomic<bool>>(false);
    auto workerEntered = std::make_shared<std::atomic<bool>>(false);
    auto mutex = std::make_shared<std::mutex>();
    auto condition = std::make_shared<std::condition_variable>();
    WorkerReleaseGuard releaseGuard(release, mutex, condition);

    adapter.SetEngineStartHookForTesting(
        [release, workerEntered, mutex, condition](VncRfbEngine& engine) {
            return engine.startWorkerForTesting(
                [release, workerEntered, mutex, condition]() {
                    workerEntered->store(true, std::memory_order_release);
                    condition->notify_all();
                    std::unique_lock<std::mutex> lock(*mutex);
                    condition->wait(lock, [&]() {
                        return release->load(std::memory_order_acquire);
                    });
                });
        });

    ConnectionConfig config;
    config.host = "127.0.0.1";
    config.port = 5900;
    RDP_ASSERT_EQ(adapter.connect(config), 0);
    {
        std::unique_lock<std::mutex> lock(*mutex);
        RDP_ASSERT(condition->wait_for(lock, 1s, [&]() {
            return workerEntered->load(std::memory_order_acquire);
        }));
    }

    adapter.onNetworkChanged(true, 7001);
    RDP_ASSERT(adapter.WaitForNetworkRecoveryActiveForTesting(1s));
    for (uint64_t generation = 7002; generation < 7130; ++generation) {
        adapter.onNetworkChanged(generation + 1 < 7130, generation);
    }
    RDP_ASSERT_EQ(adapter.PendingNetworkRecoveryJobsForTesting(),
                  static_cast<size_t>(1));
    RDP_ASSERT_EQ(adapter.MaxPendingNetworkRecoveryJobsForTesting(),
                  static_cast<size_t>(1));

    release->store(true, std::memory_order_release);
    condition->notify_all();
    RDP_ASSERT(adapter.WaitForNetworkRecoveryIdleForTesting(1s));
    RDP_ASSERT_EQ(adapter.MaxPendingNetworkRecoveryJobsForTesting(),
                  static_cast<size_t>(1));
    adapter.SetEngineStartHookForTesting(nullptr);
}

RDP_TEST_CASE(vnc_network_detach_never_exposes_disconnected_state) {
    VncAdapter adapter;
    auto releaseEngine = std::make_shared<std::atomic<bool>>(false);
    auto workerEntered = std::make_shared<std::atomic<bool>>(false);
    auto detachEntered = std::make_shared<std::atomic<bool>>(false);
    auto releaseDetach = std::make_shared<std::atomic<bool>>(false);
    auto mutex = std::make_shared<std::mutex>();
    auto condition = std::make_shared<std::condition_variable>();
    WorkerReleaseGuard releaseGuard(releaseEngine, mutex, condition);

    adapter.SetEngineStartHookForTesting(
        [releaseEngine, workerEntered, mutex, condition](
            VncRfbEngine& engine) {
            return engine.startWorkerForTesting(
                [releaseEngine, workerEntered, mutex, condition]() {
                    workerEntered->store(true, std::memory_order_release);
                    condition->notify_all();
                    std::unique_lock<std::mutex> lock(*mutex);
                    condition->wait(lock, [&]() {
                        return releaseEngine->load(
                            std::memory_order_acquire);
                    });
                });
        });
    adapter.SetAfterNetworkDetachHookForTesting(
        [detachEntered, releaseDetach, mutex, condition]() {
            detachEntered->store(true, std::memory_order_release);
            condition->notify_all();
            std::unique_lock<std::mutex> lock(*mutex);
            condition->wait(lock, [&]() {
                return releaseDetach->load(std::memory_order_acquire);
            });
        });

    ConnectionConfig config;
    config.host = "127.0.0.1";
    config.port = 5900;
    RDP_ASSERT_EQ(adapter.connect(config), 0);
    {
        std::unique_lock<std::mutex> lock(*mutex);
        RDP_ASSERT(condition->wait_for(lock, 1s, [&]() {
            return workerEntered->load(std::memory_order_acquire);
        }));
    }

    std::thread networkThread([&adapter]() {
        adapter.onNetworkChanged(true, 8001);
    });
    {
        std::unique_lock<std::mutex> lock(*mutex);
        RDP_ASSERT(condition->wait_for(lock, 1s, [&]() {
            return detachEntered->load(std::memory_order_acquire);
        }));
    }
    RDP_ASSERT_EQ(adapter.getState(), ConnectionState::RECONNECTING);

    releaseDetach->store(true, std::memory_order_release);
    releaseEngine->store(true, std::memory_order_release);
    condition->notify_all();
    networkThread.join();
    RDP_ASSERT(adapter.WaitForNetworkRecoveryIdleForTesting(1s));
    adapter.SetAfterNetworkDetachHookForTesting(nullptr);
    adapter.SetEngineStartHookForTesting(nullptr);
}

RDP_TEST_CASE(vnc_carried_network_state_cannot_overtake_explicit_disconnect) {
    VncAdapter adapter;
    auto releaseEngine = std::make_shared<std::atomic<bool>>(false);
    auto workerEntered = std::make_shared<std::atomic<bool>>(false);
    auto carrierEntered = std::make_shared<std::atomic<bool>>(false);
    auto releaseCarrier = std::make_shared<std::atomic<bool>>(false);
    auto mutex = std::make_shared<std::mutex>();
    auto condition = std::make_shared<std::condition_variable>();
    WorkerReleaseGuard releaseGuard(releaseEngine, mutex, condition);
    std::vector<ConnectionState> deliveredStates;

    adapter.setConnectionStateCallback(
        [mutex, &deliveredStates](ConnectionState state,
                                  const std::string&) {
            std::lock_guard<std::mutex> lock(*mutex);
            deliveredStates.push_back(state);
        });
    adapter.SetEngineStartHookForTesting(
        [releaseEngine, workerEntered, mutex, condition](
            VncRfbEngine& engine) {
            engine.setStopObserverForTesting(
                [releaseEngine, condition]() {
                    releaseEngine->store(true, std::memory_order_release);
                    condition->notify_all();
                });
            return engine.startWorkerForTesting(
                [releaseEngine, workerEntered, mutex, condition]() {
                    workerEntered->store(true, std::memory_order_release);
                    condition->notify_all();
                    std::unique_lock<std::mutex> lock(*mutex);
                    condition->wait(lock, [&]() {
                        return releaseEngine->load(
                            std::memory_order_acquire);
                    });
                });
        });
    adapter.SetBeforeStateCarrierOperationLockHookForTesting(
        [carrierEntered, releaseCarrier, mutex, condition]() {
            carrierEntered->store(true, std::memory_order_release);
            condition->notify_all();
            std::unique_lock<std::mutex> lock(*mutex);
            condition->wait(lock, [&]() {
                return releaseCarrier->load(std::memory_order_acquire);
            });
        });

    ConnectionConfig config;
    config.host = "127.0.0.1";
    config.port = 5900;
    RDP_ASSERT_EQ(adapter.connect(config), 0);
    {
        std::unique_lock<std::mutex> lock(*mutex);
        RDP_ASSERT(condition->wait_for(lock, 1s, [&]() {
            return workerEntered->load(std::memory_order_acquire);
        }));
    }

    // An unavailable network queues the worker-carried S1 state without
    // starting a replacement engine. Hold S1 after dequeue but before the
    // shared operation lane, then let the explicit S2 disconnect retire it.
    adapter.onNetworkChanged(false, 8051);
    {
        std::unique_lock<std::mutex> lock(*mutex);
        RDP_ASSERT(condition->wait_for(lock, 1s, [&]() {
            return carrierEntered->load(std::memory_order_acquire);
        }));
    }
    adapter.disconnect();

    size_t deliveredAfterDisconnect = 0;
    {
        std::lock_guard<std::mutex> lock(*mutex);
        RDP_ASSERT(!deliveredStates.empty());
        RDP_ASSERT_EQ(deliveredStates.back(),
                      ConnectionState::DISCONNECTED);
        deliveredAfterDisconnect = deliveredStates.size();
    }
    releaseCarrier->store(true, std::memory_order_release);
    condition->notify_all();
    RDP_ASSERT(adapter.WaitForStateCallbacksIdleForTesting(1s));
    {
        std::lock_guard<std::mutex> lock(*mutex);
        RDP_ASSERT_EQ(deliveredStates.size(), deliveredAfterDisconnect);
        RDP_ASSERT_EQ(deliveredStates.back(),
                      ConnectionState::DISCONNECTED);
    }

    adapter.SetBeforeStateCarrierOperationLockHookForTesting(nullptr);
    adapter.SetEngineStartHookForTesting(nullptr);
    adapter.setConnectionStateCallback(nullptr);
}

RDP_TEST_CASE(vnc_recovery_failure_uses_owner_safe_callback_carrier) {
    std::atomic<VncAdapter*> owner {new VncAdapter()};
    VncAdapter* adapter = owner.load(std::memory_order_acquire);
    auto releaseEngine = std::make_shared<std::atomic<bool>>(false);
    auto workerEntered = std::make_shared<std::atomic<bool>>(false);
    auto mutex = std::make_shared<std::mutex>();
    auto condition = std::make_shared<std::condition_variable>();
    WorkerReleaseGuard releaseGuard(releaseEngine, mutex, condition);
    std::atomic<int> startCalls {0};
    std::atomic<int> terminalCallbacks {0};
    std::atomic<bool> callbackRanOnRecoveryWorker {true};
    std::atomic<bool> carrierStayedBounded {false};
    std::atomic<bool> destroyed {false};
    std::string terminalMessage;

    adapter->setConnectionStateCallback(
        [adapter, &owner, &terminalCallbacks,
         &callbackRanOnRecoveryWorker, &carrierStayedBounded, &destroyed,
         &terminalMessage, mutex, condition](ConnectionState state,
                                             const std::string& message) {
            if (state != ConnectionState::ERROR) return;
            callbackRanOnRecoveryWorker.store(
                adapter->IsNetworkRecoveryWorkerThreadForTesting(),
                std::memory_order_release);
            carrierStayedBounded.store(
                adapter->MaxPendingStateCallbacksForTesting() <= 1,
                std::memory_order_release);
            {
                std::lock_guard<std::mutex> lock(*mutex);
                terminalMessage = message;
            }
            terminalCallbacks.fetch_add(1, std::memory_order_acq_rel);
            VncAdapter* doomed = owner.exchange(
                nullptr, std::memory_order_acq_rel);
            delete doomed;
            destroyed.store(true, std::memory_order_release);
            condition->notify_all();
        });
    adapter->SetEngineStartHookForTesting(
        [releaseEngine, workerEntered, mutex, condition, &startCalls](
            VncRfbEngine& engine) {
            const int call = startCalls.fetch_add(
                1, std::memory_order_acq_rel) + 1;
            if (call != 1) return -1;
            engine.setStopObserverForTesting(
                [releaseEngine, condition]() {
                    releaseEngine->store(true, std::memory_order_release);
                    condition->notify_all();
                });
            return engine.startWorkerForTesting(
                [releaseEngine, workerEntered, mutex, condition]() {
                    workerEntered->store(true, std::memory_order_release);
                    condition->notify_all();
                    std::unique_lock<std::mutex> lock(*mutex);
                    condition->wait(lock, [&]() {
                        return releaseEngine->load(
                            std::memory_order_acquire);
                    });
                });
        });

    ConnectionConfig config;
    config.host = "127.0.0.1";
    config.port = 5900;
    RDP_ASSERT_EQ(adapter->connect(config), 0);
    {
        std::unique_lock<std::mutex> lock(*mutex);
        RDP_ASSERT(condition->wait_for(lock, 1s, [&]() {
            return workerEntered->load(std::memory_order_acquire);
        }));
    }
    adapter->onNetworkChanged(true, 8101);
    {
        std::unique_lock<std::mutex> lock(*mutex);
        RDP_ASSERT(condition->wait_for(lock, 2s, [&]() {
            return destroyed.load(std::memory_order_acquire);
        }));
    }
    RDP_ASSERT_EQ(terminalCallbacks.load(std::memory_order_acquire), 1);
    RDP_ASSERT(!callbackRanOnRecoveryWorker.load(std::memory_order_acquire));
    RDP_ASSERT(carrierStayedBounded.load(std::memory_order_acquire));
    RDP_ASSERT(terminalMessage.find("E-VNC-NETWORK-RECOVERY") !=
               std::string::npos);
    RDP_ASSERT(owner.load(std::memory_order_acquire) == nullptr);
}

RDP_TEST_CASE(vnc_async_terminal_error_retires_reconnect_credentials) {
    VncAdapter adapter;
    auto emitTerminal = std::make_shared<std::atomic<bool>>(false);
    auto workerEntered = std::make_shared<std::atomic<bool>>(false);
    auto terminalEmitted = std::make_shared<std::atomic<bool>>(false);
    auto mutex = std::make_shared<std::mutex>();
    auto condition = std::make_shared<std::condition_variable>();
    std::atomic<int> startCalls {0};
    std::atomic<VncRfbEngine*> activeEngine {nullptr};

    adapter.SetEngineStartHookForTesting(
        [emitTerminal, workerEntered, terminalEmitted, mutex, condition,
         &startCalls, &activeEngine](VncRfbEngine& engine) {
            startCalls.fetch_add(1, std::memory_order_acq_rel);
            VncRfbEngine* enginePtr = &engine;
            activeEngine.store(enginePtr, std::memory_order_release);
            return engine.startWorkerForTesting(
                [emitTerminal, workerEntered, terminalEmitted, mutex,
                 condition, enginePtr]() {
                    workerEntered->store(true, std::memory_order_release);
                    condition->notify_all();
                    {
                        std::unique_lock<std::mutex> lock(*mutex);
                        condition->wait(lock, [&]() {
                            return emitTerminal->load(
                                std::memory_order_acquire);
                        });
                    }
                    enginePtr->emitStateForTesting(
                        ConnectionState::ERROR,
                        "synthetic asynchronous authentication failure");
                    terminalEmitted->store(true, std::memory_order_release);
                    condition->notify_all();
                });
        });

    ConnectionConfig config;
    config.host = "127.0.0.1";
    config.port = 5900;
    config.password = "credential-must-be-retired";
    RDP_ASSERT_EQ(adapter.connect(config), 0);
    RDP_ASSERT(adapter.RetainsReconnectCredentialMaterialForTesting());
    {
        std::unique_lock<std::mutex> lock(*mutex);
        RDP_ASSERT(condition->wait_for(lock, 1s, [&]() {
            return workerEntered->load(std::memory_order_acquire);
        }));
    }
    const std::array<uint8_t, 4> pixels {{0, 1, 2, 3}};
    VideoFrame rejectedFrame;
    rejectedFrame.data = pixels.data();
    rejectedFrame.size = pixels.size();
    rejectedFrame.width = 1;
    rejectedFrame.height = 1;
    rejectedFrame.stride = 4;
    rejectedFrame.codec = CodecType::RAW_BGRA;
    RDP_ASSERT(activeEngine.load(std::memory_order_acquire) != nullptr);
    RDP_ASSERT(activeEngine.load(std::memory_order_acquire)
                   ->invokeFrameCallbackForTesting(rejectedFrame));
    emitTerminal->store(true, std::memory_order_release);
    condition->notify_all();
    {
        std::unique_lock<std::mutex> lock(*mutex);
        RDP_ASSERT(condition->wait_for(lock, 1s, [&]() {
            return terminalEmitted->load(std::memory_order_acquire);
        }));
    }
    RDP_ASSERT_EQ(adapter.getState(), ConnectionState::ERROR);
    RDP_ASSERT(!adapter.RetainsReconnectCredentialMaterialForTesting());

    adapter.onNetworkChanged(true, 8201);
    RDP_ASSERT_EQ(startCalls.load(std::memory_order_acquire), 1);
    adapter.SetEngineStartHookForTesting(nullptr);
}

RDP_TEST_CASE(vnc_engine_callback_can_release_adapter_owner) {
    const Render::DecoderSessionIdentity sessionOwner {8301, 1, 8301};
    ActivateOwner(sessionOwner);
    OwnerCleanupGuard ownerGuard(sessionOwner);

    std::atomic<VncAdapter*> owner {new VncAdapter()};
    VncAdapter* adapter = owner.load(std::memory_order_acquire);
    adapter->setSessionOwner(sessionOwner);
    auto emitTerminal = std::make_shared<std::atomic<bool>>(false);
    auto workerEntered = std::make_shared<std::atomic<bool>>(false);
    auto workerReturned = std::make_shared<std::atomic<bool>>(false);
    auto mutex = std::make_shared<std::mutex>();
    auto condition = std::make_shared<std::condition_variable>();
    std::atomic<bool> destroyed {false};

    adapter->setConnectionStateCallback(
        [&owner, &destroyed, condition](ConnectionState state,
                                        const std::string&) {
            if (state != ConnectionState::ERROR) return;
            VncAdapter* doomed = owner.exchange(
                nullptr, std::memory_order_acq_rel);
            delete doomed;
            destroyed.store(true, std::memory_order_release);
            condition->notify_all();
        });
    adapter->SetEngineStartHookForTesting(
        [emitTerminal, workerEntered, workerReturned, mutex, condition](
            VncRfbEngine& engine) {
            VncRfbEngine* enginePtr = &engine;
            return engine.startWorkerForTesting(
                [emitTerminal, workerEntered, workerReturned, mutex,
                 condition, enginePtr]() {
                    workerEntered->store(true, std::memory_order_release);
                    condition->notify_all();
                    {
                        std::unique_lock<std::mutex> lock(*mutex);
                        condition->wait(lock, [&]() {
                            return emitTerminal->load(
                                std::memory_order_acquire);
                        });
                    }
                    enginePtr->emitStateForTesting(
                        ConnectionState::ERROR,
                        "synthetic owner-release callback");
                    workerReturned->store(true, std::memory_order_release);
                    condition->notify_all();
                });
        });

    ConnectionConfig config;
    config.host = "127.0.0.1";
    config.port = 5900;
    RDP_ASSERT_EQ(adapter->connect(config), 0);
    {
        std::unique_lock<std::mutex> lock(*mutex);
        RDP_ASSERT(condition->wait_for(lock, 1s, [&]() {
            return workerEntered->load(std::memory_order_acquire);
        }));
    }
    emitTerminal->store(true, std::memory_order_release);
    condition->notify_all();
    {
        std::unique_lock<std::mutex> lock(*mutex);
        RDP_ASSERT(condition->wait_for(lock, 2s, [&]() {
            return destroyed.load(std::memory_order_acquire) &&
                workerReturned->load(std::memory_order_acquire);
        }));
    }
    RDP_ASSERT(owner.load(std::memory_order_acquire) == nullptr);
    RDP_ASSERT(VncRfbEngine::drainDeferredJoinsWithin(1s));
}

RDP_TEST_CASE(vnc_connect_callback_can_release_adapter_owner) {
    std::atomic<VncAdapter*> owner {new VncAdapter()};
    VncAdapter* adapter = owner.load(std::memory_order_acquire);
    std::atomic<bool> destroyed {false};

    adapter->SetEngineStartHookForTesting([](VncRfbEngine& engine) {
        return engine.startWorkerForTesting([]() {});
    });
    adapter->setConnectionStateCallback(
        [&owner, &destroyed](ConnectionState state, const std::string&) {
            if (state != ConnectionState::CONNECTING) return;
            VncAdapter* doomed = owner.exchange(
                nullptr, std::memory_order_acq_rel);
            delete doomed;
            destroyed.store(true, std::memory_order_release);
        });

    ConnectionConfig config;
    config.host = "127.0.0.1";
    config.port = 5900;
    RDP_ASSERT_EQ(adapter->connect(config), 0);
    RDP_ASSERT(destroyed.load(std::memory_order_acquire));
    RDP_ASSERT(owner.load(std::memory_order_acquire) == nullptr);
}

RDP_TEST_CASE(vnc_network_callback_can_release_adapter_owner) {
    std::atomic<VncAdapter*> owner {new VncAdapter()};
    VncAdapter* adapter = owner.load(std::memory_order_acquire);
    auto releaseEngine = std::make_shared<std::atomic<bool>>(false);
    auto workerEntered = std::make_shared<std::atomic<bool>>(false);
    auto mutex = std::make_shared<std::mutex>();
    auto condition = std::make_shared<std::condition_variable>();
    WorkerReleaseGuard releaseGuard(releaseEngine, mutex, condition);
    std::atomic<bool> destroyed {false};

    adapter->SetEngineStartHookForTesting(
        [releaseEngine, workerEntered, mutex, condition](
            VncRfbEngine& engine) {
            engine.setStopObserverForTesting(
                [releaseEngine, condition]() {
                    releaseEngine->store(true, std::memory_order_release);
                    condition->notify_all();
                });
            return engine.startWorkerForTesting(
                [releaseEngine, workerEntered, mutex, condition]() {
                    workerEntered->store(true, std::memory_order_release);
                    condition->notify_all();
                    std::unique_lock<std::mutex> lock(*mutex);
                    condition->wait(lock, [&]() {
                        return releaseEngine->load(
                            std::memory_order_acquire);
                    });
                });
        });
    adapter->setConnectionStateCallback(
        [&owner, &destroyed](ConnectionState state, const std::string&) {
            if (state != ConnectionState::RECONNECTING) return;
            VncAdapter* doomed = owner.exchange(
                nullptr, std::memory_order_acq_rel);
            delete doomed;
            destroyed.store(true, std::memory_order_release);
        });

    ConnectionConfig config;
    config.host = "127.0.0.1";
    config.port = 5900;
    RDP_ASSERT_EQ(adapter->connect(config), 0);
    {
        std::unique_lock<std::mutex> lock(*mutex);
        RDP_ASSERT(condition->wait_for(lock, 1s, [&]() {
            return workerEntered->load(std::memory_order_acquire);
        }));
    }
    adapter->onNetworkChanged(true, 8401);
    RDP_ASSERT(destroyed.load(std::memory_order_acquire));
    RDP_ASSERT(owner.load(std::memory_order_acquire) == nullptr);
    RDP_ASSERT(VncRfbEngine::drainDeferredJoinsWithin(1s));
}
