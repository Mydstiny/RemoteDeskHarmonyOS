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
