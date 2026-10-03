#include "test_runner.h"
#include "rdp/rdp_gfx_wire_evidence.h"

#include <cstring>
#include <string>

RDP_TEST_CASE(rdp_gfx_wire_evidence_names_wire_codecs_without_guessing) {
    RDP_ASSERT(std::strcmp(RdpGfxWireCodecName(0x0003u), "remotefx") == 0);
    RDP_ASSERT(std::strcmp(RdpGfxWireCodecName(0x000Bu), "avc420") == 0);
    RDP_ASSERT(std::strcmp(RdpGfxWireCodecName(0x000Eu), "avc444") == 0);
    RDP_ASSERT(std::strcmp(RdpGfxWireCodecName(0x000Au), "planar") == 0);
    RDP_ASSERT(std::strcmp(RdpGfxWireCodecName(0x0002u), "unknown") == 0);
    RDP_ASSERT(std::strcmp(RdpGfxWireCodecName(0x0100u), "unknown") == 0);
}

RDP_TEST_CASE(rdp_gfx_caps_avc_rules_follow_capability_version) {
    RDP_ASSERT(!RdpGfxCapsAllowAvc(kRdpGfxCapsVersion8, 0));
    RDP_ASSERT(!RdpGfxCapsAllowAvc(kRdpGfxCapsVersion81, 0));
    RDP_ASSERT(RdpGfxCapsAllowAvc(kRdpGfxCapsVersion81, kRdpGfxCapsFlagAvc420Enabled));
    RDP_ASSERT(RdpGfxCapsAllowAvc(kRdpGfxCapsVersion10, 0));
    RDP_ASSERT(!RdpGfxCapsAllowAvc(kRdpGfxCapsVersion10, kRdpGfxCapsFlagAvcDisabled));
    RDP_ASSERT(!RdpGfxCapsAllowAvc(0x000A0701u, kRdpGfxCapsFlagAvcDisabled | 0x80u));
    RDP_ASSERT(std::strcmp(RdpGfxCapsVersionName(0x000A0701u), "10.7") == 0);
    RDP_ASSERT(std::strcmp(RdpGfxCapsVersionName(0x12345678u), "unknown") == 0);
}

RDP_TEST_CASE(rdp_gfx_wire_evidence_separates_requested_and_observed_codecs) {
    RdpGfxWireEvidence evidence;
    RdpGfxRequestedSettings requested;
    requested.applied = true;
    requested.compiledGfx = true;
    requested.compiledH264 = true;
    requested.supportGraphicsPipeline = true;
    requested.remoteFxCodec = true;
    requested.gfxH264 = false;
    evidence.reset(requested);

    RdpGfxWireEvidenceSnapshot empty = evidence.snapshot();
    RDP_ASSERT(empty.requested.applied);
    RDP_ASSERT(!empty.requested.gfxH264);
    RDP_ASSERT(!empty.capsConfirmed);
    RDP_ASSERT_EQ(empty.surfaceCommands, 0ULL);
    RDP_ASSERT_EQ(empty.dominantCodecId, kRdpGfxCodecSlots);

    evidence.recordCapsAdvertise(6, 0x000A0701u, false);
    evidence.recordCapsConfirm(0x000A0701u, kRdpGfxCapsFlagAvcDisabled);
    evidence.recordSurfaceCommand(0x0003u, 1000);
    evidence.recordSurfaceCommand(0x0003u, 500);
    evidence.recordSurfaceCommand(0x000Au, 200);
    evidence.recordSurfaceCommand(0x7777u, 10);

    const RdpGfxWireEvidenceSnapshot snapshot = evidence.snapshot();
    RDP_ASSERT(snapshot.capsConfirmed);
    RDP_ASSERT(!snapshot.capsConfirmedAvc);
    RDP_ASSERT(!snapshot.capsAdvertisedAvc);
    RDP_ASSERT_EQ(snapshot.capsAdvertisedCount, 6U);
    RDP_ASSERT_EQ(snapshot.surfaceCommands, 4ULL);
    RDP_ASSERT_EQ(snapshot.unknownCodecCommands, 1ULL);
    RDP_ASSERT_EQ(snapshot.surfaceCommandBytes, 1710ULL);
    RDP_ASSERT_EQ(snapshot.avcSurfaceCommands, 0ULL);
    RDP_ASSERT_EQ(snapshot.dominantCodecId, 0x0003U);
    RDP_ASSERT_EQ(snapshot.dominantCodecCommands, 2ULL);
    RDP_ASSERT_EQ(snapshot.codecMask, (1U << 0x3) | (1U << 0xA));
}

RDP_TEST_CASE(rdp_gfx_wire_evidence_counts_avc_and_resets_per_connection) {
    RdpGfxWireEvidence evidence;
    RdpGfxRequestedSettings requested;
    requested.applied = true;
    requested.gfxH264 = true;
    evidence.reset(requested);
    evidence.recordCapsConfirm(kRdpGfxCapsVersion81, kRdpGfxCapsFlagAvc420Enabled);
    evidence.recordSurfaceCommand(0x000Bu, 4096);
    evidence.recordSurfaceCommand(0x000Eu, 4096);
    RdpGfxWireEvidenceSnapshot first = evidence.snapshot();
    RDP_ASSERT(first.capsConfirmedAvc);
    RDP_ASSERT_EQ(first.avcSurfaceCommands, 2ULL);

    evidence.reset(RdpGfxRequestedSettings());
    RdpGfxWireEvidenceSnapshot second = evidence.snapshot();
    RDP_ASSERT(!second.requested.applied);
    RDP_ASSERT(!second.capsConfirmed);
    RDP_ASSERT_EQ(second.surfaceCommands, 0ULL);
    RDP_ASSERT_EQ(second.codecMask, 0U);
    RDP_ASSERT_EQ(second.surfaceCommandBytes, 0ULL);
}

RDP_TEST_CASE(rdp_scoped_gfx_fallback_does_not_cross_hosts) {
    RdpScopedGfxFallback fallback;
    const std::string hostA = RdpGfxFallbackScopeKey("Host-A.example", 3389);
    const std::string hostB = RdpGfxFallbackScopeKey("host-b.example", 3389);
    RDP_ASSERT(hostA != hostB);
    RDP_ASSERT(RdpGfxFallbackScopeKey("HOST-A.EXAMPLE", 3389) == hostA);
    RDP_ASSERT(RdpGfxFallbackScopeKey("host-a.example", 3390) != hostA);
    RDP_ASSERT(RdpGfxFallbackScopeKey(nullptr, 3389).empty());

    fallback.mark(hostA, "gfx-init");
    RDP_ASSERT(fallback.pending(hostA));
    RDP_ASSERT(!fallback.pending(hostB));
    RDP_ASSERT(!fallback.consume(hostB));

    std::string reason;
    RDP_ASSERT(fallback.consume(hostA, &reason));
    RDP_ASSERT(reason == "gfx-init");
    RDP_ASSERT(!fallback.consume(hostA));
    fallback.mark(std::string(), "ignored");
    RDP_ASSERT_EQ(fallback.size(), static_cast<size_t>(0));
}

RDP_TEST_CASE(rdp_scoped_gfx_fallback_is_bounded_and_keeps_latest_reason) {
    RdpScopedGfxFallback fallback;
    for (int index = 0; index < 40; ++index) {
        fallback.mark("scope-" + std::to_string(index), "resize-failed");
    }
    RDP_ASSERT_EQ(fallback.size(), RdpScopedGfxFallback::kMaxScopes);
    RDP_ASSERT(!fallback.pending("scope-0"));
    RDP_ASSERT(fallback.pending("scope-39"));

    fallback.mark("scope-39", "gfx-conflict");
    RDP_ASSERT_EQ(fallback.size(), RdpScopedGfxFallback::kMaxScopes);
    std::string reason;
    RDP_ASSERT(fallback.consume("scope-39", &reason));
    RDP_ASSERT(reason == "gfx-conflict");
}
