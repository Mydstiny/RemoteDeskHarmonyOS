#include "test_runner.h"
#include "ssh/ssh_pending_connect_registry.h"

#include <cassert>
#include <thread>
#include <vector>

RDP_TEST_CASE(ssh_pending_connect_registry_supports_independent_identities) {
    SshPendingConnectRegistry registry;
    const SshPendingConnectIdentity first {101, 7001};
    const SshPendingConnectIdentity second {202, 7002};

    assert(registry.add(first));
    assert(registry.add(second));
    assert(!registry.add(first));
    assert(registry.size() == 2);
    assert(registry.contains(first));
    assert(registry.contains(second));
    assert(registry.firstSessionId() == 101);

    const auto snapshot = registry.snapshot();
    assert(snapshot.size() == 2);
    assert(snapshot[0].sessionId == 101 && snapshot[0].generation == 7001);
    assert(snapshot[1].sessionId == 202 && snapshot[1].generation == 7002);

    // A stale completion cannot remove a newer identity for the same id.
    assert(!registry.remove(SshPendingConnectIdentity {101, 7000}));
    assert(registry.contains(first));
    assert(registry.remove(first));
    assert(!registry.contains(first));
    assert(registry.contains(second));
}

RDP_TEST_CASE(ssh_pending_connect_registry_concurrent_admission_and_cleanup) {
    SshPendingConnectRegistry registry;
    std::vector<std::thread> workers;
    for (int index = 0; index < 8; ++index) {
        workers.emplace_back([&registry, index]() {
            const SshPendingConnectIdentity identity {
                1000 + index, static_cast<uint64_t>(8000 + index)};
            assert(registry.add(identity));
            assert(registry.contains(identity));
        });
    }
    for (auto& worker : workers) {
        worker.join();
    }
    assert(registry.size() == 8);

    const auto identities = registry.snapshot();
    for (const SshPendingConnectIdentity& identity : identities) {
        assert(registry.remove(identity));
    }
    assert(registry.size() == 0);
    assert(registry.firstSessionId() == -1);
}
