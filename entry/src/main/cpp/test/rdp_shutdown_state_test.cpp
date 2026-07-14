/**
 * rdp_shutdown_state_test.cpp - deterministic RDP teardown ordering contracts
 */

#include "test_runner.h"
#include "rdp/rdp_shutdown_state.h"

using RdpShutdown::Action;
using RdpShutdown::Phase;

RDP_TEST_CASE(rdp_shutdown_state_advances_once_and_rejects_regression) {
    RdpShutdown::State state;
    RDP_ASSERT_EQ(state.phase(), Phase::Running);
    RDP_ASSERT(state.requestDisconnect());
    RDP_ASSERT_EQ(state.phase(), Phase::Quiescing);
    RDP_ASSERT(!state.requestDisconnect());
    RDP_ASSERT(state.advance(Phase::Quiescing, Phase::TransportDisconnecting));
    RDP_ASSERT(!state.advance(Phase::TransportDisconnecting, Phase::Quiescing));
    RDP_ASSERT(state.advance(Phase::TransportDisconnecting, Phase::Releasing));
    RDP_ASSERT(state.advance(Phase::Releasing, Phase::Complete));
}

RDP_TEST_CASE(rdp_shutdown_actions_never_run_under_instance_mutex) {
    constexpr Action actions[] = {
        Action::JoinInputWorker,
        Action::JoinPresentationWorker,
        Action::JoinEventWorker,
        Action::JoinDriveWorker,
        Action::JoinConnectWorker,
        Action::DisconnectTransport,
        Action::ReleaseInstance,
    };
    for (const Action action : actions) {
        RDP_ASSERT(RdpShutdown::RequiresInstanceMutexReleased(action));
        RDP_ASSERT(!RdpShutdown::CanRun(action, true));
        RDP_ASSERT(RdpShutdown::CanRun(action, false));
    }
}

RDP_TEST_CASE(rdp_shutdown_sequence_quiesces_workers_before_transport) {
    constexpr auto sequence = RdpShutdown::OrderedActions();
    RDP_ASSERT_EQ(sequence[0], Action::RejectNewWork);
    RDP_ASSERT_EQ(sequence[1], Action::JoinInputWorker);
    RDP_ASSERT_EQ(sequence[2], Action::JoinPresentationWorker);
    // The connect thread can create event and drive workers, so its producer must stop first.
    RDP_ASSERT_EQ(sequence[3], Action::JoinConnectWorker);
    RDP_ASSERT_EQ(sequence[4], Action::JoinEventWorker);
    RDP_ASSERT_EQ(sequence[5], Action::JoinDriveWorker);
    RDP_ASSERT_EQ(sequence[6], Action::DisconnectTransport);
    RDP_ASSERT_EQ(sequence[7], Action::ReleaseInstance);
}
