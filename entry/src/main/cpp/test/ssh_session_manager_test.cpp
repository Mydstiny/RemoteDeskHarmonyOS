#include "../ssh/ssh_session_manager.h"
#include "test_runner.h"

#include <cassert>

RDP_TEST_CASE(ssh_session_manager_lifecycle_and_generation) {
    SshSessionManager manager;
    SshNativeFacade facade(manager);
    const SshSessionHandle handle {42, "shell", 7};
    assert(facade.registerSession(handle, "example.test", 22) ==
        SshSessionManagerResult::Ok);
    assert(facade.accepts(handle));
    assert(facade.transition(handle, SshSessionLifecycleState::Connecting,
        "connecting") == SshSessionManagerResult::Ok);
    assert(facade.transition(handle, SshSessionLifecycleState::Authenticating,
        "authenticating") == SshSessionManagerResult::Ok);
    assert(facade.transition(handle, SshSessionLifecycleState::Ready,
        "ready") == SshSessionManagerResult::Ok);
    const SshSessionHandle stale {42, "shell", 8};
    assert(!facade.accepts(stale));
    assert(facade.transition(stale, SshSessionLifecycleState::Closed,
        "stale") == SshSessionManagerResult::StaleSession);
    SshSessionSnapshot snapshot;
    assert(facade.snapshot(handle, snapshot));
    assert(snapshot.state == SshSessionLifecycleState::Ready);
    assert(snapshot.eventSequence == 3);
    assert(facade.events(handle).size() == 3);
    assert(facade.closeSession(handle) == SshSessionManagerResult::Ok);
    assert(!facade.accepts(handle));
}

RDP_TEST_CASE(ssh_session_manager_concurrent_sessions_and_bounded_events) {
    SshSessionManager manager;
    SshNativeFacade facade(manager);
    for (uint64_t sessionId = 1; sessionId <= 8; ++sessionId) {
        const SshSessionHandle handle {sessionId, "shell", sessionId + 100};
        assert(facade.registerSession(handle, "host-" + std::to_string(sessionId), 22) ==
            SshSessionManagerResult::Ok);
        assert(facade.transition(handle, SshSessionLifecycleState::Connecting,
            "connecting") == SshSessionManagerResult::Ok);
        assert(facade.transition(handle, SshSessionLifecycleState::Authenticating,
            "authenticating") == SshSessionManagerResult::Ok);
        assert(facade.transition(handle, SshSessionLifecycleState::Ready,
            "ready") == SshSessionManagerResult::Ok);
        assert(facade.setBackgroundLimited(handle, true, "os-rejected") ==
            SshSessionManagerResult::Ok);
        assert(facade.events(handle, 0).size() == 4);
        const SshSessionHandle stale {sessionId, "shell", sessionId + 101};
        assert(facade.events(stale, 0).empty());
        SshSessionManagerResult snapshotResult = SshSessionManagerResult::Ok;
        SshSessionSnapshot snapshot;
        assert(!facade.snapshot(stale, snapshot, &snapshotResult));
        assert(snapshotResult == SshSessionManagerResult::StaleSession);
    }
    assert(manager.size() == 8);

    const SshSessionHandle bounded {1, "shell", 101};
    for (int index = 0; index < 140; ++index) {
        assert(facade.transition(bounded, SshSessionLifecycleState::Ready,
            "health") == SshSessionManagerResult::Ok);
    }
    const std::vector<SshEventEnvelope> events = facade.events(bounded, 0);
    assert(events.size() == SshSessionManager::kMaxEventsPerSession);
    assert(events.front().sequence > 1);
    assert(events.back().sequence == 144);
    assert(facade.events(bounded, events.front().sequence - 1).size() == events.size());
}

RDP_TEST_CASE(ssh_session_manager_recovery_and_mfa_state_sequence) {
    SshSessionManager manager;
    SshNativeFacade facade(manager);
    const SshSessionHandle handle {77, "shell", 9};
    assert(facade.registerSession(handle, "recovery.test", 22) ==
        SshSessionManagerResult::Ok);

    const std::vector<SshSessionLifecycleState> sequence {
        SshSessionLifecycleState::Connecting,
        SshSessionLifecycleState::Authenticating,
        SshSessionLifecycleState::Ready,
        SshSessionLifecycleState::NetworkLost,
        SshSessionLifecycleState::ReconnectScheduled,
        SshSessionLifecycleState::Reconnecting,
        SshSessionLifecycleState::NeedsAuthentication,
        SshSessionLifecycleState::Authenticating,
        SshSessionLifecycleState::Ready,
    };
    for (const SshSessionLifecycleState state : sequence) {
        assert(facade.transition(handle, state, "lifecycle") ==
            SshSessionManagerResult::Ok);
    }

    SshSessionSnapshot snapshot;
    assert(facade.snapshot(handle, snapshot));
    assert(snapshot.state == SshSessionLifecycleState::Ready);
    assert(snapshot.eventSequence == sequence.size());
    const std::vector<SshEventEnvelope> events = facade.events(handle);
    assert(events.size() == sequence.size());
    assert(events[3].type == "lifecycle");
    assert(events[4].sequence == 5);
}

RDP_TEST_CASE(ssh_session_manager_ready_session_can_require_fresh_authentication) {
    SshSessionManager manager;
    SshNativeFacade facade(manager);
    const SshSessionHandle handle {78, "shell", 10};
    assert(facade.registerSession(handle, "reauth.test", 22) ==
        SshSessionManagerResult::Ok);
    assert(facade.transition(handle, SshSessionLifecycleState::Connecting,
        "connecting") == SshSessionManagerResult::Ok);
    assert(facade.transition(handle, SshSessionLifecycleState::Authenticating,
        "authenticating") == SshSessionManagerResult::Ok);
    assert(facade.transition(handle, SshSessionLifecycleState::Ready,
        "ready") == SshSessionManagerResult::Ok);
    assert(facade.transition(handle, SshSessionLifecycleState::NeedsAuthentication,
        "reauthentication_required") == SshSessionManagerResult::Ok);

    SshSessionSnapshot snapshot;
    assert(facade.snapshot(handle, snapshot));
    assert(snapshot.state == SshSessionLifecycleState::NeedsAuthentication);
}
