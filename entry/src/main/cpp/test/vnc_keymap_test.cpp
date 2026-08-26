/** Native regression tests for the VNC HarmonyOS -> X11 KeySym contract. */
#include "test_runner.h"
#include "vnc/vnc_rfb_engine.h"

RDP_TEST_CASE(vnc_keymap_covers_extended_function_keys_and_system_controls) {
    RDP_ASSERT_EQ(VncRfbEngine::keySymForHarmonyCodeForTesting(2090), 0xFFBEU);
    RDP_ASSERT_EQ(VncRfbEngine::keySymForHarmonyCodeForTesting(2101), 0xFFC9U);
    RDP_ASSERT_EQ(VncRfbEngine::keySymForHarmonyCodeForTesting(2816), 0xFFCAU);
    RDP_ASSERT_EQ(VncRfbEngine::keySymForHarmonyCodeForTesting(2827), 0xFFD5U);
    RDP_ASSERT_EQ(VncRfbEngine::keySymForHarmonyCodeForTesting(2079), 0xFF61U);
    RDP_ASSERT_EQ(VncRfbEngine::keySymForHarmonyCodeForTesting(2080), 0xFF13U);
    RDP_ASSERT_EQ(VncRfbEngine::keySymForHarmonyCodeForTesting(2074), 0xFFE5U);
}

RDP_TEST_CASE(vnc_keymap_covers_numeric_keypad_controls) {
    RDP_ASSERT_EQ(VncRfbEngine::keySymForHarmonyCodeForTesting(2103), 0xFFB0U);
    RDP_ASSERT_EQ(VncRfbEngine::keySymForHarmonyCodeForTesting(2112), 0xFFB9U);
    RDP_ASSERT_EQ(VncRfbEngine::keySymForHarmonyCodeForTesting(2113), 0xFFAFU);
    RDP_ASSERT_EQ(VncRfbEngine::keySymForHarmonyCodeForTesting(2114), 0xFFAAU);
    RDP_ASSERT_EQ(VncRfbEngine::keySymForHarmonyCodeForTesting(2115), 0xFFADU);
    RDP_ASSERT_EQ(VncRfbEngine::keySymForHarmonyCodeForTesting(2116), 0xFFABU);
    RDP_ASSERT_EQ(VncRfbEngine::keySymForHarmonyCodeForTesting(2117), 0xFFAEU);
    RDP_ASSERT_EQ(VncRfbEngine::keySymForHarmonyCodeForTesting(2118), 0xFFACU);
    RDP_ASSERT_EQ(VncRfbEngine::keySymForHarmonyCodeForTesting(2119), 0xFF8DU);
    RDP_ASSERT_EQ(VncRfbEngine::keySymForHarmonyCodeForTesting(2120), 0xFFBDU);
    RDP_ASSERT_EQ(VncRfbEngine::keySymForHarmonyCodeForTesting(2121), 0xFF9DU);
    RDP_ASSERT_EQ(VncRfbEngine::keySymForHarmonyCodeForTesting(2122), 0xFF9EU);
}

RDP_TEST_CASE(vnc_keymap_keeps_unknown_and_fn_keys_fail_closed) {
    RDP_ASSERT_EQ(VncRfbEngine::keySymForHarmonyCodeForTesting(2078), 0U);
    RDP_ASSERT_EQ(VncRfbEngine::keySymForHarmonyCodeForTesting(0x20), 0x20U);
    RDP_ASSERT_EQ(VncRfbEngine::keySymForHarmonyCodeForTesting(0x10039), 0xFFE5U);
}
