#include "test_runner.h"
#include "rustdesk/rustdesk_ffi_lifetime_policy.h"

RDP_TEST_CASE(rustdesk_ffi_context_retirement_waits_for_handle_join) {
    RDP_ASSERT(!RustDeskFfiLifetime::CanRetireCallbackContext(1, 0, false, 0, false));
    RDP_ASSERT(RustDeskFfiLifetime::HasHandleJoinReservation(1));
    RDP_ASSERT(!RustDeskFfiLifetime::HasHandleJoinReservation(0));
}

RDP_TEST_CASE(rustdesk_ffi_context_retirement_requires_all_fences) {
    RDP_ASSERT(!RustDeskFfiLifetime::CanRetireCallbackContext(0, 1, false, 0, false));
    RDP_ASSERT(!RustDeskFfiLifetime::CanRetireCallbackContext(0, 0, true, 0, false));
    RDP_ASSERT(!RustDeskFfiLifetime::CanRetireCallbackContext(0, 0, false, 1, false));
    RDP_ASSERT(!RustDeskFfiLifetime::CanRetireCallbackContext(0, 0, false, 0, true));
    RDP_ASSERT(RustDeskFfiLifetime::CanRetireCallbackContext(0, 0, false, 0, false));
}

RDP_TEST_CASE(rustdesk_ffi_callback_registry_keeps_entered_callback_alive) {
    struct TestContext {
        int value = 7;
    };
    RustDeskFfiLifetime::CallbackContextRegistry<TestContext> registry;
    auto context = std::make_shared<TestContext>();
    void* token = context.get();

    RDP_ASSERT(registry.publish(context));
    auto entered = registry.acquire(token);
    RDP_ASSERT(entered == context);
    RDP_ASSERT(registry.retire(context));
    RDP_ASSERT(registry.acquire(token) == nullptr);
    RDP_ASSERT(entered != nullptr);
    RDP_ASSERT_EQ(entered->value, 7);
}
