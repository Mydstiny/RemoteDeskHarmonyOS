#include "rustdesk/rustdesk_connection_continuity_owner.h"
#include "test_runner.h"

RDP_TEST_CASE(rustdesk_continuity_transport_loss_is_event_driven_and_fast_quiesces) {
    RustDeskConnectionContinuityOwner owner;
    owner.begin(7, 42, 1000);
    const auto action = owner.onTransportEvent({true, RustDeskTransportErrorClass::Reset,
                                                 42, false, true, 1200});
    RDP_ASSERT(action.visibleTransportLost);
    RDP_ASSERT(action.fastQuiesce);
    RDP_ASSERT(action.startAttempt);
    RDP_ASSERT_EQ(action.attempt, 1);
    RDP_ASSERT_EQ(owner.networkGeneration(), 42);
    RDP_ASSERT(owner.fastQuiesced());
    RDP_ASSERT_EQ(owner.state(), RustDeskContinuityState::RetryPending);
}

RDP_TEST_CASE(rustdesk_continuity_network_unavailable_waits_without_budget_consumption) {
    RustDeskConnectionContinuityOwner owner;
    owner.begin(8, 80, 0);
    const auto lost = owner.onTransportEvent({true, RustDeskTransportErrorClass::Timeout,
                                               80, false, false, 100});
    RDP_ASSERT(lost.visibleTransportLost);
    RDP_ASSERT(!lost.startAttempt);
    RDP_ASSERT_EQ(owner.attempts(), 0);
    const auto duplicate = owner.onNetworkChanged(false, 80, 200);
    RDP_ASSERT(!duplicate.startAttempt);
    const auto available = owner.onNetworkChanged(true, 80, 300);
    RDP_ASSERT(available.startAttempt);
    RDP_ASSERT_EQ(available.attempt, 1);
}

RDP_TEST_CASE(rustdesk_continuity_duplicate_network_generation_keeps_retry_budget) {
    RustDeskConnectionContinuityOwner owner;
    owner.begin(9, 90, 0);
    RDP_ASSERT(owner.onTransportEvent({true, RustDeskTransportErrorClass::BrokenPipe,
                                       90, false, true, 1}).startAttempt);
    RDP_ASSERT_EQ(owner.attempts(), 1);
    RDP_ASSERT(!owner.onNetworkChanged(true, 90, 2).startAttempt);
    RDP_ASSERT_EQ(owner.attempts(), 1);
    RDP_ASSERT(!owner.onNetworkChanged(true, 89, 3).startAttempt);
    RDP_ASSERT_EQ(owner.networkGeneration(), 90);
}

RDP_TEST_CASE(rustdesk_continuity_nonrecoverable_requires_reauth_or_terminal) {
    RustDeskConnectionContinuityOwner owner;
    owner.begin(10, 100, 0);
    const auto auth = owner.onTransportEvent({true, RustDeskTransportErrorClass::TwoFactor,
                                               100, false, true, 1});
    RDP_ASSERT(auth.terminal);
    RDP_ASSERT_EQ(owner.state(), RustDeskContinuityState::ReauthRequired);
    RDP_ASSERT(!owner.poll(100000).startAttempt);

    owner.begin(10, 101, 0);
    const auto user = owner.onTransportEvent({true, RustDeskTransportErrorClass::Reset,
                                               101, true, true, 1});
    RDP_ASSERT(user.terminal);
    RDP_ASSERT_EQ(owner.state(), RustDeskContinuityState::Terminal);
}

RDP_TEST_CASE(rustdesk_continuity_retry_schedule_is_bounded_and_cancelable) {
    RustDeskConnectionContinuityOwner owner;
    owner.begin(11, 110, 0);
    RDP_ASSERT(owner.onTransportEvent({true, RustDeskTransportErrorClass::NetworkDown,
                                       110, false, true, 0}).startAttempt);
    uint64_t now = 0;
    for (int i = 0; i < 4; ++i) {
        owner.recordAttemptResult(false, now + 100);
        const auto action = owner.poll(owner.nextRetryMs());
        RDP_ASSERT(action.startAttempt);
        now = owner.nextRetryMs();
    }
    owner.recordAttemptResult(false, now + 100);
    RDP_ASSERT_EQ(owner.attempts(), 5);
    RDP_ASSERT(!owner.poll(now + 100000).startAttempt);
    owner.cancel();
    RDP_ASSERT(!owner.poll(now + 200000).startAttempt);
}
