#include "test_runner.h"
#include "rustdesk/rustdesk_display_control_plane.h"
#include "rustdesk/rustdesk_display_switch_gate.h"
#include "rustdesk/rustdesk_multi_canvas_policy.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>

RDP_TEST_CASE(rustdesk_display_switch_requires_ack_then_target_keyframe) {
    RustDeskDisplaySwitchGate gate;
    const auto initial = gate.observeDisplay(0);
    RDP_ASSERT(initial.publishDisplay);
    RDP_ASSERT_EQ(initial.display, 0);

    const uint64_t generation = gate.begin(1);
    RDP_ASSERT_EQ(generation, 1);
    RDP_ASSERT(gate.snapshot().inputBlocked);

    RDP_ASSERT(!gate.observeDisplay(0).publishDisplay);
    RDP_ASSERT(!gate.observeFrame(1, true).acceptFrame);
    RDP_ASSERT(!gate.observeDisplay(1).publishDisplay);
    RDP_ASSERT(!gate.observeFrame(1, false).acceptFrame);

    const auto committed = gate.observeFrame(1, true);
    RDP_ASSERT(committed.acceptFrame);
    RDP_ASSERT(committed.publishDisplay);
    RDP_ASSERT_EQ(committed.display, 1);
    RDP_ASSERT_EQ(gate.snapshot().readyGeneration, generation);
    RDP_ASSERT(!gate.snapshot().inputBlocked);
}

RDP_TEST_CASE(rustdesk_display_switch_latest_generation_wins) {
    RustDeskDisplaySwitchGate gate;
    gate.observeDisplay(0);
    const uint64_t first = gate.begin(1);
    const uint64_t latest = gate.begin(2);
    RDP_ASSERT(latest > first);

    RDP_ASSERT(!gate.observeDisplay(1).publishDisplay);
    RDP_ASSERT(!gate.observeFrame(1, true).acceptFrame);
    RDP_ASSERT(!gate.observeFrame(2, true).acceptFrame);
    RDP_ASSERT(!gate.observeDisplay(2).publishDisplay);

    const auto committed = gate.observeFrame(2, true);
    RDP_ASSERT(committed.acceptFrame);
    RDP_ASSERT_EQ(gate.snapshot().readyGeneration, latest);
    RDP_ASSERT_EQ(gate.snapshot().confirmedDisplay, 2);

    RDP_ASSERT(gate.observeFrame(2, false).acceptFrame);
}

RDP_TEST_CASE(rustdesk_display_switch_accepts_authoritative_post_commit_fallback) {
    RustDeskDisplaySwitchGate gate;
    gate.observeDisplay(0);
    gate.begin(2);
    gate.observeDisplay(2);
    RDP_ASSERT(gate.observeFrame(2, true).acceptFrame);

    const auto fallback = gate.observeDisplay(1);
    RDP_ASSERT(fallback.publishDisplay);
    RDP_ASSERT_EQ(fallback.display, 1);
    RDP_ASSERT(gate.observeFrame(1, true).acceptFrame);
    RDP_ASSERT(!gate.observeFrame(2, true).acceptFrame);
}

RDP_TEST_CASE(rustdesk_display_switch_can_return_to_the_confirmed_display) {
    RustDeskDisplaySwitchGate gate;
    gate.observeDisplay(0);
    gate.begin(1);
    const uint64_t returnGeneration = gate.begin(0);

    gate.observeDisplay(0);
    const auto committed = gate.observeFrame(0, true);
    RDP_ASSERT(committed.acceptFrame);
    RDP_ASSERT_EQ(gate.snapshot().readyGeneration, returnGeneration);
    RDP_ASSERT_EQ(gate.snapshot().confirmedDisplay, 0);
}

RDP_TEST_CASE(rustdesk_multi_canvas_budget_keeps_focus_and_one_preview) {
    const std::vector<RustDeskMultiCanvasDisplayBudgetInput> catalog {
        {0, 1920, 1080, true},
        {1, 2560, 1440, true},
        {2, 1080, 1920, true},
    };
    const auto decision = RustDeskSelectMultiCanvasDisplays(
        1, {2, 0, 2}, catalog);
    RDP_ASSERT(decision.accepted);
    RDP_ASSERT(decision.degraded);
    RDP_ASSERT_EQ(decision.displays.size(), 2U);
    RDP_ASSERT_EQ(decision.displays[0], 1);
    RDP_ASSERT_EQ(decision.displays[1], 2);
    RDP_ASSERT(decision.reason == "resource_budget");
}

RDP_TEST_CASE(rustdesk_multi_canvas_budget_rejects_offline_focus) {
    const std::vector<RustDeskMultiCanvasDisplayBudgetInput> catalog {
        {0, 1920, 1080, false},
        {1, 1920, 1080, true},
    };
    const auto decision = RustDeskSelectMultiCanvasDisplays(0, {1}, catalog);
    RDP_ASSERT(!decision.accepted);
    RDP_ASSERT(decision.reason == "focused_display_unavailable");
}

RDP_TEST_CASE(rustdesk_multi_canvas_preview_never_duplicates_first_or_switch_frame) {
    RDP_ASSERT(!RustDeskShouldRouteMultiCanvasPreview(0, -1, -1, false, true));
    RDP_ASSERT(!RustDeskShouldRouteMultiCanvasPreview(0, 0, -1, false, true));
    RDP_ASSERT(!RustDeskShouldRouteMultiCanvasPreview(1, 0, 1, true, true));
    RDP_ASSERT(!RustDeskShouldRouteMultiCanvasPreview(1, 0, -1, false, false));
    RDP_ASSERT(RustDeskShouldRouteMultiCanvasPreview(1, 0, -1, false, true));
}

RDP_TEST_CASE(rustdesk_display_switch_dispatch_does_not_pin_generation_during_callback) {
    RustDeskDisplayControlPlane control;
    int fakeHandle = 7;
    RDP_ASSERT(control.attachHandle(&fakeHandle));
    control.dispatchDisplay(0, []() { return true; }, [](const auto&) {});
    const auto first = control.beginDisplaySwitch(
        1,
        []() { return true; },
        [](void*, int) { return true; });
    RDP_ASSERT(first.accepted);
    control.dispatchDisplay(1, []() { return true; }, [](const auto&) {});

    std::mutex stateMutex;
    std::condition_variable stateChanged;
    bool dispatchEntered = false;
    bool releaseDispatch = false;
    bool beginStarted = false;
    bool beginCompleted = false;
    uint64_t latestGeneration = 0;

    std::thread frameThread([&]() {
        const bool accepted = control.dispatchFrame(
            1,
            true,
            []() { return true; },
            [&](const auto&) {
                {
                    std::lock_guard<std::mutex> lock(stateMutex);
                    dispatchEntered = true;
                }
                stateChanged.notify_all();

                std::unique_lock<std::mutex> lock(stateMutex);
                RDP_ASSERT(stateChanged.wait_for(
                    lock, std::chrono::seconds(1), [&]() {
                        return releaseDispatch;
                    }));
            });
        RDP_ASSERT(accepted);
    });

    {
        std::unique_lock<std::mutex> lock(stateMutex);
        RDP_ASSERT(stateChanged.wait_for(lock, std::chrono::seconds(1), [&]() {
            return dispatchEntered;
        }));
    }

    std::thread beginThread([&]() {
        {
            std::lock_guard<std::mutex> lock(stateMutex);
            beginStarted = true;
        }
        stateChanged.notify_all();
        const auto request = control.beginDisplaySwitch(
            2,
            []() { return true; },
            [](void*, int) { return true; });
        RDP_ASSERT(request.accepted);
        latestGeneration = request.generation;
        {
            std::lock_guard<std::mutex> lock(stateMutex);
            beginCompleted = true;
        }
        stateChanged.notify_all();
    });

    {
        std::unique_lock<std::mutex> lock(stateMutex);
        RDP_ASSERT(stateChanged.wait_for(lock, std::chrono::seconds(1), [&]() {
            return beginStarted;
        }));
        RDP_ASSERT(stateChanged.wait_for(lock, std::chrono::milliseconds(250), [&]() {
            return beginCompleted;
        }));
        releaseDispatch = true;
    }
    stateChanged.notify_all();
    frameThread.join();
    beginThread.join();

    RDP_ASSERT(beginCompleted);
    RDP_ASSERT(latestGeneration > 1);
    const auto snapshot = control.snapshot();
    RDP_ASSERT_EQ(snapshot.generation, latestGeneration);
    RDP_ASSERT_EQ(snapshot.pendingDisplay, 2);
    RDP_ASSERT(snapshot.inputBlocked);
}

RDP_TEST_CASE(rustdesk_display_dispatch_pressure_disconnect_watchdog) {
    RustDeskDisplayControlPlane control;
    int fakeHandle = 17;
    RDP_ASSERT(control.attachHandle(&fakeHandle));
    control.dispatchDisplay(0, []() { return true; }, [](const auto&) {});

    std::atomic<bool> callbackEntered {false};
    std::atomic<bool> pressureLeaseAcquired {false};
    std::atomic<bool> disconnected {false};
    std::thread dispatchThread([&]() {
        const bool accepted = control.dispatchFrame(
            0,
            true,
            []() { return true; },
            [&](const auto&) {
                callbackEntered.store(true, std::memory_order_release);
                // This models ReportVideoPressureForSession taking the same
                // display boundary synchronously from the frame callback.
                auto pressureLease = control.acquireDisplayLease();
                (void)pressureLease;
                pressureLeaseAcquired.store(true, std::memory_order_release);
                control.detachHandle();
                disconnected.store(true, std::memory_order_release);
            });
        RDP_ASSERT(accepted);
    });

    dispatchThread.join();
    RDP_ASSERT(callbackEntered.load(std::memory_order_acquire));
    RDP_ASSERT(pressureLeaseAcquired.load(std::memory_order_acquire));
    RDP_ASSERT(disconnected.load(std::memory_order_acquire));
    RDP_ASSERT(!control.hasHandle());
}

RDP_TEST_CASE(rustdesk_display_control_plane_reset_clears_pending_ready_and_input_block) {
    RustDeskDisplayControlPlane control;
    int fakeHandle = 23;
    RDP_ASSERT(control.attachHandle(&fakeHandle));
    control.dispatchDisplay(0, []() { return true; }, [](const auto&) {});
    const auto request = control.beginDisplaySwitch(
        1,
        []() { return true; },
        [](void*, int) { return true; });
    RDP_ASSERT(request.accepted);
    const auto before = control.snapshot();
    RDP_ASSERT(before.inputBlocked);
    RDP_ASSERT_EQ(before.pendingDisplay, 1);

    control.resetDisplayState();
    const auto after = control.snapshot();
    RDP_ASSERT_EQ(after.generation, 0ULL);
    RDP_ASSERT_EQ(after.readyGeneration, 0ULL);
    RDP_ASSERT_EQ(after.pendingDisplay, -1);
    RDP_ASSERT_EQ(after.confirmedDisplay, -1);
    RDP_ASSERT(!after.inputBlocked);
    RDP_ASSERT(control.hasHandle());
    control.detachHandle();
}

RDP_TEST_CASE(rustdesk_display_capability_query_pins_handle_through_ffi_query) {
    RustDeskDisplayControlPlane control;
    int fakeHandle = 11;
    RDP_ASSERT(control.attachHandle(&fakeHandle));
    const auto pendingRequest = control.beginDisplaySwitch(
        4,
        []() { return true; },
        [](void*, int) { return true; });
    RDP_ASSERT(pendingRequest.accepted);

    std::mutex stateMutex;
    std::condition_variable stateChanged;
    bool queryEntered = false;
    bool releaseQuery = false;
    bool detachStarted = false;
    bool detachCompleted = false;
    void* detached = nullptr;
    RustDeskDisplaySwitchGateSnapshot snapshot;

    std::thread queryThread([&]() {
        const bool queried = control.queryDisplayState(
            []() { return true; },
            [&](void* handle) {
                RDP_ASSERT_EQ(handle, static_cast<void*>(&fakeHandle));
                {
                    std::lock_guard<std::mutex> lock(stateMutex);
                    queryEntered = true;
                }
                stateChanged.notify_all();
                std::unique_lock<std::mutex> lock(stateMutex);
                RDP_ASSERT(stateChanged.wait_for(
                    lock, std::chrono::seconds(1), [&]() {
                        return releaseQuery;
                    }));
                return true;
            },
            snapshot);
        RDP_ASSERT(queried);
    });

    {
        std::unique_lock<std::mutex> lock(stateMutex);
        RDP_ASSERT(stateChanged.wait_for(lock, std::chrono::seconds(1), [&]() {
            return queryEntered;
        }));
    }
    std::thread detachThread([&]() {
        {
            std::lock_guard<std::mutex> lock(stateMutex);
            detachStarted = true;
        }
        stateChanged.notify_all();
        detached = control.detachHandle();
        {
            std::lock_guard<std::mutex> lock(stateMutex);
            detachCompleted = true;
        }
        stateChanged.notify_all();
    });
    {
        std::unique_lock<std::mutex> lock(stateMutex);
        RDP_ASSERT(stateChanged.wait_for(lock, std::chrono::seconds(1), [&]() {
            return detachStarted;
        }));
        RDP_ASSERT(!stateChanged.wait_for(
            lock, std::chrono::milliseconds(50), [&]() {
                return detachCompleted;
            }));
        releaseQuery = true;
    }
    stateChanged.notify_all();
    queryThread.join();
    detachThread.join();

    RDP_ASSERT_EQ(detached, static_cast<void*>(&fakeHandle));
    RDP_ASSERT(detachCompleted);
    RDP_ASSERT(!control.hasHandle());
    RDP_ASSERT_EQ(snapshot.generation, pendingRequest.generation);
    RDP_ASSERT_EQ(snapshot.readyGeneration, 0);
    RDP_ASSERT_EQ(snapshot.pendingDisplay, 4);
    RDP_ASSERT(snapshot.inputBlocked);
}

RDP_TEST_CASE(rustdesk_display_capability_query_releases_handle_before_snapshot) {
    RustDeskDisplayControlPlane control;
    int fakeHandle = 12;
    RDP_ASSERT(control.attachHandle(&fakeHandle));
    const auto pendingRequest = control.beginDisplaySwitch(
        5,
        []() { return true; },
        [](void*, int) { return true; });
    RDP_ASSERT(pendingRequest.accepted);

    std::mutex stateMutex;
    std::condition_variable stateChanged;
    bool queryEntered = false;
    bool releaseQuery = false;
    bool detachStarted = false;
    bool detachCompleted = false;
    void* detached = nullptr;
    RustDeskDisplaySwitchGateSnapshot snapshot;

    std::thread queryThread([&]() {
        const bool queried = control.queryDisplayState(
            []() { return true; },
            [&](void* handle) {
                RDP_ASSERT_EQ(handle, static_cast<void*>(&fakeHandle));
                {
                    std::lock_guard<std::mutex> lock(stateMutex);
                    queryEntered = true;
                }
                stateChanged.notify_all();
                std::unique_lock<std::mutex> lock(stateMutex);
                RDP_ASSERT(stateChanged.wait_for(
                    lock, std::chrono::seconds(1), [&]() {
                        return releaseQuery;
                    }));
                return true;
            },
            snapshot);
        RDP_ASSERT(queried);
    });

    {
        std::unique_lock<std::mutex> lock(stateMutex);
        RDP_ASSERT(stateChanged.wait_for(lock, std::chrono::seconds(1), [&]() {
            return queryEntered;
        }));
    }

    bool detachedWhileDisplayHeld = false;
    std::thread detachThread;
    {
        // Production retirement owns this display boundary before it asks
        // for the exclusive handle gate. Keeping the lease in this thread
        // lets the test break a regression-induced cycle instead of hanging.
        auto retirementDisplayLease = control.acquireDisplayLease();
        (void)retirementDisplayLease;
        detachThread = std::thread([&]() {
            {
                std::lock_guard<std::mutex> lock(stateMutex);
                detachStarted = true;
            }
            stateChanged.notify_all();
            detached = control.detachHandle();
            {
                std::lock_guard<std::mutex> lock(stateMutex);
                detachCompleted = true;
            }
            stateChanged.notify_all();
        });

        {
            std::unique_lock<std::mutex> lock(stateMutex);
            RDP_ASSERT(stateChanged.wait_for(lock, std::chrono::seconds(1), [&]() {
                return detachStarted;
            }));
            RDP_ASSERT(!stateChanged.wait_for(
                lock, std::chrono::milliseconds(50), [&]() {
                    return detachCompleted;
                }));
            releaseQuery = true;
        }
        stateChanged.notify_all();
        {
            std::unique_lock<std::mutex> lock(stateMutex);
            detachedWhileDisplayHeld = stateChanged.wait_for(
                lock, std::chrono::seconds(1), [&]() {
                    return detachCompleted;
                });
        }
        // If queryDisplayState still held the shared handle while requesting
        // this display lock, the exclusive detach above could not finish
        // until this scope ended. Releasing the lease keeps a failing test
        // recoverable and allows both worker threads to join below.
    }

    detachThread.join();
    queryThread.join();
    RDP_ASSERT(detachedWhileDisplayHeld);
    RDP_ASSERT_EQ(detached, static_cast<void*>(&fakeHandle));
    RDP_ASSERT(!control.hasHandle());
    RDP_ASSERT_EQ(snapshot.generation, pendingRequest.generation);
    RDP_ASSERT_EQ(snapshot.pendingDisplay, 5);
    RDP_ASSERT(snapshot.inputBlocked);
}

RDP_TEST_CASE(rustdesk_display_switch_ffi_call_pins_handle_until_result) {
    RustDeskDisplayControlPlane control;
    int fakeHandle = 13;
    RDP_ASSERT(control.attachHandle(&fakeHandle));

    std::mutex stateMutex;
    std::condition_variable stateChanged;
    bool switchEntered = false;
    bool releaseSwitch = false;
    bool detachStarted = false;
    bool detachCompleted = false;
    RustDeskDisplayControlRequest request;
    void* detached = nullptr;

    std::thread switchThread([&]() {
        request = control.beginDisplaySwitch(
            3,
            []() { return true; },
            [&](void* handle, int display) {
                RDP_ASSERT_EQ(handle, static_cast<void*>(&fakeHandle));
                RDP_ASSERT_EQ(display, 3);
                // A switch callback may synchronously report pressure or
                // disconnect. The display lease must be re-entrant from this
                // external boundary even while the FFI call is still pinned.
                auto pressureLease = control.acquireDisplayLease();
                RDP_ASSERT(pressureLease.snapshot().inputBlocked);
                {
                    std::lock_guard<std::mutex> lock(stateMutex);
                    switchEntered = true;
                }
                stateChanged.notify_all();
                std::unique_lock<std::mutex> lock(stateMutex);
                RDP_ASSERT(stateChanged.wait_for(
                    lock, std::chrono::seconds(1), [&]() {
                        return releaseSwitch;
                    }));
                return true;
            });
    });

    {
        std::unique_lock<std::mutex> lock(stateMutex);
        RDP_ASSERT(stateChanged.wait_for(lock, std::chrono::seconds(1), [&]() {
            return switchEntered;
        }));
    }
    std::thread detachThread([&]() {
        {
            std::lock_guard<std::mutex> lock(stateMutex);
            detachStarted = true;
        }
        stateChanged.notify_all();
        detached = control.detachHandle();
        {
            std::lock_guard<std::mutex> lock(stateMutex);
            detachCompleted = true;
        }
        stateChanged.notify_all();
    });
    {
        std::unique_lock<std::mutex> lock(stateMutex);
        RDP_ASSERT(stateChanged.wait_for(lock, std::chrono::seconds(1), [&]() {
            return detachStarted;
        }));
        RDP_ASSERT(!stateChanged.wait_for(
            lock, std::chrono::milliseconds(50), [&]() {
                return detachCompleted;
            }));
        releaseSwitch = true;
    }
    stateChanged.notify_all();
    switchThread.join();
    detachThread.join();

    RDP_ASSERT(request.accepted);
    RDP_ASSERT(request.generation > 0);
    RDP_ASSERT_EQ(detached, static_cast<void*>(&fakeHandle));
    RDP_ASSERT(detachCompleted);
    RDP_ASSERT(!control.hasHandle());
}

RDP_TEST_CASE(rustdesk_outbound_lanes_fail_closed_behind_network_retirement) {
    RustDeskDisplayControlPlane control;
    int fakeHandle = 29;
    RDP_ASSERT(control.attachHandle(&fakeHandle));

    std::mutex admissionMutex;
    bool streamActive = true;
    std::atomic<int> started {0};
    std::atomic<int> inputCalls {0};
    std::atomic<int> fileCalls {0};
    std::atomic<int> clipboardCalls {0};
    std::atomic<bool> inputAccepted {true};
    std::atomic<bool> fileAccepted {true};
    std::atomic<bool> clipboardAccepted {true};

    // Model a network action after it owns admission but before it retires
    // the handle. Outbound callers may queue behind the action, but none may
    // reach the old FFI pointer once the action closes admission.
    std::unique_lock<std::mutex> networkAction(admissionMutex);
    const auto launch = [&](std::atomic<int>& calls,
                            std::atomic<bool>& accepted) {
        auto* callsPtr = &calls;
        auto* acceptedPtr = &accepted;
        return std::thread([&, callsPtr, acceptedPtr]() {
            started.fetch_add(1, std::memory_order_acq_rel);
            acceptedPtr->store(control.dispatchOutbound(
                admissionMutex,
                [&]() { return streamActive; },
                [&](void* handle) {
                    RDP_ASSERT_EQ(handle, static_cast<void*>(&fakeHandle));
                    callsPtr->fetch_add(1, std::memory_order_acq_rel);
                    return true;
                }), std::memory_order_release);
        });
    };
    std::thread inputThread = launch(inputCalls, inputAccepted);
    std::thread fileThread = launch(fileCalls, fileAccepted);
    std::thread clipboardThread = launch(clipboardCalls, clipboardAccepted);
    const auto deadline = std::chrono::steady_clock::now() +
        std::chrono::seconds(1);
    while (started.load(std::memory_order_acquire) != 3 &&
           std::chrono::steady_clock::now() < deadline) {
        std::this_thread::yield();
    }
    RDP_ASSERT_EQ(started.load(std::memory_order_acquire), 3);
    streamActive = false;
    networkAction.unlock();

    inputThread.join();
    fileThread.join();
    clipboardThread.join();
    RDP_ASSERT(!inputAccepted.load(std::memory_order_acquire));
    RDP_ASSERT(!fileAccepted.load(std::memory_order_acquire));
    RDP_ASSERT(!clipboardAccepted.load(std::memory_order_acquire));
    RDP_ASSERT_EQ(inputCalls.load(std::memory_order_acquire), 0);
    RDP_ASSERT_EQ(fileCalls.load(std::memory_order_acquire), 0);
    RDP_ASSERT_EQ(clipboardCalls.load(std::memory_order_acquire), 0);
    RDP_ASSERT_EQ(control.detachHandle(), static_cast<void*>(&fakeHandle));
}
